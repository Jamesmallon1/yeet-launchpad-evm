// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {YeetToken} from "./YeetToken.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {IYeetGraduator} from "./interfaces/IYeetGraduator.sol";

/// @title YeetLaunchpad
/// @notice Singleton launchpad: creates YeetTokens, runs every bonding curve in native USDC, takes the 0.3%
///         protocol fee and the token's USDC dividend on every trade, and graduates completed curves into
///         Uniswap v4 through the YeetGraduator.
contract YeetLaunchpad is Ownable2Step, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint16 public constant PROTOCOL_FEE_BPS = 30;
    uint16 public constant MAX_DEV_BUY_BPS = 5_000;

    // curve parameters, fixed at deployment (production: 3,500 / 10,000 USDC)
    uint256 public immutable V_USDC0;
    uint256 public immutable TARGET_USDC;
    uint256 public immutable CURVE_SUPPLY;
    uint256 public immutable LP_SUPPLY;
    uint256 public immutable V_TOKEN0;

    struct Curve {
        uint128 realUsdc; // net USDC held for this curve
        uint128 tokensSold;
        uint16 taxBps;
        bool complete; // curve sold out, graduation pending or done
        bool graduated;
        address creator;
        uint64 createdAt;
        bytes32 poolId;
    }

    mapping(address => Curve) public curves;
    address[] public allTokens;

    IYeetGraduator public graduator;
    address public hook;
    address public poolManager;
    bool public initialized;

    uint256 public accruedFees;
    bool public creationPaused;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string metadataURI,
        uint16 taxBps
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 usdcAmount, // net USDC into/out of the curve
        uint256 tokenAmount,
        uint256 protocolFee,
        uint256 dividend,
        uint256 vUsdc,
        uint256 vToken,
        uint256 price
    );
    event CurveComplete(address indexed token, uint256 realUsdc);
    event Graduated(address indexed token, bytes32 indexed poolId);
    event GraduationDeferred(address indexed token, bytes reason);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event CreationPaused(bool paused);

    error AlreadyInitialized();
    error NotInitialized();
    error CreationIsPaused();
    error InvalidTax();
    error DevBuyTooLarge();
    error DevBuyShortfall();
    error UnknownToken();
    error CurveClosed();
    error CurveNotComplete();
    error AlreadyGraduated();
    error ZeroAmount();
    error Slippage();
    error TransferFailed();
    error BadName();

    constructor(address owner_, uint256 vUsdc0, uint256 targetUsdc) Ownable(owner_) {
        CurveMath.Params memory p = CurveMath.params(vUsdc0, targetUsdc);
        V_USDC0 = p.vUsdc0;
        TARGET_USDC = p.target;
        CURVE_SUPPLY = p.curveSupply;
        LP_SUPPLY = p.lpSupply;
        V_TOKEN0 = p.vToken0;
    }

    function curveParams() public view returns (CurveMath.Params memory p) {
        p.vUsdc0 = V_USDC0;
        p.target = TARGET_USDC;
        p.curveSupply = CURVE_SUPPLY;
        p.lpSupply = LP_SUPPLY;
        p.vToken0 = V_TOKEN0;
    }

    // ---------------------------------------------------------------- admin

    function initialize(address graduator_, address hook_, address poolManager_) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        graduator = IYeetGraduator(graduator_);
        hook = hook_;
        poolManager = poolManager_;
        initialized = true;
    }

    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPaused(paused);
    }

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        accruedFees = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------- create

    /// @param taxBps 0, 100 or 300: USDC dividend on every trade, forever.
    /// @param devBuyBps share of total supply the creator buys in this tx with msg.value (0..5000).
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint16 taxBps,
        uint16 devBuyBps
    ) external payable nonReentrant returns (address token) {
        if (!initialized) revert NotInitialized();
        if (creationPaused) revert CreationIsPaused();
        if (!(taxBps == 0 || taxBps == 100 || taxBps == 300)) revert InvalidTax();
        if (devBuyBps > MAX_DEV_BUY_BPS) revert DevBuyTooLarge();
        if (bytes(name).length == 0 || bytes(name).length > 32 || bytes(symbol).length == 0 || bytes(symbol).length > 10) {
            revert BadName();
        }

        address[] memory excluded = new address[](2);
        excluded[0] = address(graduator);
        excluded[1] = poolManager;
        token = address(new YeetToken(name, symbol, metadataURI, taxBps, address(this), hook, excluded));

        curves[token] = Curve({
            realUsdc: 0,
            tokensSold: 0,
            taxBps: taxBps,
            complete: false,
            graduated: false,
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            poolId: bytes32(0)
        });
        allTokens.push(token);
        YeetToken(token).approve(address(graduator), LP_SUPPLY);

        emit TokenCreated(token, msg.sender, name, symbol, metadataURI, taxBps);

        if (devBuyBps > 0) {
            uint256 out = _buy(token, msg.sender, msg.value, 0);
            if (out < CurveMath.SUPPLY * devBuyBps / BPS) revert DevBuyShortfall();
        } else if (msg.value > 0) {
            _send(msg.sender, msg.value);
        }
    }

    // ---------------------------------------------------------------- trade

    function buy(address token, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        return _buy(token, msg.sender, msg.value, minTokensOut);
    }

    function sell(address token, uint256 tokensIn, uint256 minUsdcOut) external nonReentrant returns (uint256 usdcOut) {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.complete) revert CurveClosed();
        if (tokensIn == 0) revert ZeroAmount();
        CurveMath.Params memory p = curveParams();

        YeetToken(token).transferFrom(msg.sender, address(this), tokensIn);

        uint256 gross = CurveMath.usdcOut(p, c.realUsdc, c.tokensSold, tokensIn);
        uint256 protocolFee = gross * PROTOCOL_FEE_BPS / BPS;
        uint256 dividend = gross * c.taxBps / BPS;
        usdcOut = gross - protocolFee - dividend;
        if (usdcOut < minUsdcOut) revert Slippage();

        c.realUsdc -= uint128(gross);
        c.tokensSold -= uint128(tokensIn);
        accruedFees += protocolFee;

        (uint256 vU, uint256 vT) = CurveMath.reserves(p, c.realUsdc, c.tokensSold);
        emit Trade(token, msg.sender, false, gross, tokensIn, protocolFee, dividend, vU, vT, vU * 1e18 / vT);

        // seller's balance is already reduced, so they do not earn on their own exit
        if (dividend > 0) YeetToken(token).notifyDividend{value: dividend}();
        _send(msg.sender, usdcOut);
    }

    function _buy(address token, address buyer, uint256 value, uint256 minTokensOut) internal returns (uint256 out) {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.complete) revert CurveClosed();
        if (value == 0) revert ZeroAmount();
        CurveMath.Params memory p = curveParams();

        uint256 gross = value;
        uint256 protocolFee = gross * PROTOCOL_FEE_BPS / BPS;
        uint256 dividend = gross * c.taxBps / BPS;
        uint256 net = gross - protocolFee - dividend;

        out = CurveMath.tokensOut(p, c.realUsdc, c.tokensSold, net);
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        uint256 refund;

        if (out >= remaining) {
            // final buy: clamp to what is left, charge only for that, refund the rest
            out = remaining;
            net = CurveMath.usdcIn(p, c.realUsdc, c.tokensSold, out);
            uint256 feeBps = PROTOCOL_FEE_BPS + c.taxBps;
            uint256 needed = Math.ceilDiv(net * BPS, BPS - feeBps);
            if (needed > gross) needed = gross; // rounding by a wei: absorb, never revert the completing buy
            refund = gross - needed;
            gross = needed;
            protocolFee = gross * PROTOCOL_FEE_BPS / BPS;
            dividend = gross * c.taxBps / BPS;
            net = gross - protocolFee - dividend;
            c.complete = true;
        }
        if (out < minTokensOut) revert Slippage();

        c.realUsdc += uint128(net);
        c.tokensSold += uint128(out);
        accruedFees += protocolFee;

        YeetToken(token).transfer(buyer, out);

        (uint256 vU, uint256 vT) = CurveMath.reserves(p, c.realUsdc, c.tokensSold);
        emit Trade(token, buyer, true, net, out, protocolFee, dividend, vU, vT, vU * 1e18 / vT);

        // buyer already holds the tokens, so they share in their own dividend
        if (dividend > 0) YeetToken(token).notifyDividend{value: dividend}();
        if (refund > 0) _send(buyer, refund);

        if (c.complete) {
            emit CurveComplete(token, c.realUsdc);
            _tryGraduate(token, c);
        }
    }

    // ---------------------------------------------------------------- graduation

    /// @notice Permissionless retry if the atomic graduation in the final buy was deferred.
    function graduate(address token) external nonReentrant {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (!c.complete) revert CurveNotComplete();
        if (c.graduated) revert AlreadyGraduated();
        _tryGraduate(token, c);
    }

    function _tryGraduate(address token, Curve storage c) internal {
        uint256 usdc = c.realUsdc;
        try graduator.graduate{value: usdc}(token, LP_SUPPLY) returns (bytes32 poolId) {
            c.graduated = true;
            c.poolId = poolId;
            c.realUsdc = 0;
            emit Graduated(token, poolId);
        } catch (bytes memory reason) {
            emit GraduationDeferred(token, reason);
        }
    }

    // ---------------------------------------------------------------- views

    function quoteBuy(address token, uint256 usdcIn)
        external
        view
        returns (uint256 tokensOut, uint256 protocolFee, uint256 dividend, uint256 refund)
    {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        CurveMath.Params memory p = curveParams();
        protocolFee = usdcIn * PROTOCOL_FEE_BPS / BPS;
        dividend = usdcIn * c.taxBps / BPS;
        uint256 net = usdcIn - protocolFee - dividend;
        tokensOut = CurveMath.tokensOut(p, c.realUsdc, c.tokensSold, net);
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        if (tokensOut >= remaining) {
            tokensOut = remaining;
            net = CurveMath.usdcIn(p, c.realUsdc, c.tokensSold, tokensOut);
            uint256 needed = Math.ceilDiv(net * BPS, BPS - PROTOCOL_FEE_BPS - c.taxBps);
            if (needed > usdcIn) needed = usdcIn;
            refund = usdcIn - needed;
            protocolFee = needed * PROTOCOL_FEE_BPS / BPS;
            dividend = needed * c.taxBps / BPS;
        }
    }

    function quoteSell(address token, uint256 tokensIn)
        external
        view
        returns (uint256 usdcOut, uint256 protocolFee, uint256 dividend)
    {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        CurveMath.Params memory p = curveParams();
        uint256 gross = CurveMath.usdcOut(p, c.realUsdc, c.tokensSold, tokensIn);
        protocolFee = gross * PROTOCOL_FEE_BPS / BPS;
        dividend = gross * c.taxBps / BPS;
        usdcOut = gross - protocolFee - dividend;
    }

    function price(address token) external view returns (uint256) {
        Curve storage c = curves[token];
        return CurveMath.price(curveParams(), c.realUsdc, c.tokensSold);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    // ---------------------------------------------------------------- internal

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
