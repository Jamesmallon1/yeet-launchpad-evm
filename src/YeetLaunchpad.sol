// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {YeetToken} from "./YeetToken.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {IYeetGraduator, IYeetBuyback} from "./interfaces/IYeetGraduator.sol";

/// @title YeetLaunchpad
/// @notice Singleton launchpad: creates YeetTokens, runs every bonding curve in native USDC, takes the 0.3%
///         protocol fee (100% of which goes to the protocol buyback contract, forever) and the token's dividend
///         on every trade, applies the launch snipe tax, and graduates completed curves into Uniswap v4.
///
///         Dividend split ("green candle"): each token chooses at launch what share of its dividend USDC is paid to
///         holders and what share buys the token back and burns it. On the curve the buyback runs inside the trade.
///
///         Snipe tax: buys in the first SNIPE_TAX_SECONDS after creation pay a tax that starts at 99% and quarters
///         every second (99% -> 24.75% -> 6.19% -> 1.55% -> 0). The creator's dev buy is exempt. The tax is paid
///         into the token's own dividend split.
contract YeetLaunchpad is Ownable2Step, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint16 public constant PROTOCOL_FEE_BPS = 30;
    uint16 public constant MAX_DEV_BUY_BPS = 5_000;
    uint256 public constant SNIPE_TAX_SECONDS = 3;
    uint256 public constant SNIPE_TAX_START_BPS = 9_900;
    uint256 public constant SNIPE_DECAY_SHIFT = 2; // tax >>= 2 per second (÷4)
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
        uint16 burnShareBps;
        bool complete; // curve sold out, graduation pending or done
        bool graduated;
        address creator;
        uint64 createdAt;
        bytes32 poolId;
        uint128 burnedTokens;
        uint128 burnedUsdc;
    }

    mapping(address => Curve) public curves;
    address[] public allTokens;

    IYeetGraduator public graduator;
    IYeetBuyback public buyback;
    address public hook;
    address public poolManager;
    bool public initialized;

    uint256 public accruedFees; // protocol fees not yet swept to the buyback contract
    bool public creationPaused;

    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string metadataURI,
        uint16 taxBps,
        uint16 burnShareBps
    );
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 usdcAmount, // net USDC into/out of the curve
        uint256 tokenAmount,
        uint256 protocolFee,
        uint256 dividend, // paid to holders (USDC)
        uint256 burnUsdc, // used to buy back + burn this token
        uint256 snipeTax, // part of the gross that was the launch snipe tax (already inside dividend/burnUsdc)
        uint256 vUsdc,
        uint256 vToken,
        uint256 price
    );
    event Buyback(address indexed token, uint256 usdcIn, uint256 tokensBurned);
    event CurveComplete(address indexed token, uint256 realUsdc);
    event Graduated(address indexed token, bytes32 indexed poolId);
    event GraduationDeferred(address indexed token, bytes reason);
    event FeesSwept(uint256 amount);
    event CreationPaused(bool paused);

    error AlreadyInitialized();
    error NotInitialized();
    error CreationIsPaused();
    error InvalidTax();
    error InvalidSplit();
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
    error NotBuyback();

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

    function initialize(address graduator_, address hook_, address poolManager_, address buyback_) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        graduator = IYeetGraduator(graduator_);
        hook = hook_;
        poolManager = poolManager_;
        buyback = IYeetBuyback(buyback_);
        initialized = true;
    }

    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPaused(paused);
    }

    /// @notice Permissionless: move accrued protocol fees to the buyback contract (their only possible destination).
    function sweepFees() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) return;
        accruedFees = 0;
        buyback.deposit{value: amount}();
        emit FeesSwept(amount);
    }

    // ---------------------------------------------------------------- create

    /// @param taxBps 0, 100 or 300: USDC dividend on every trade, forever.
    /// @param burnShareBps 0..10000: share of the dividend that buys the token back and burns it; the rest goes to holders.
    /// @param devBuyBps share of total supply the creator buys in this tx with msg.value (0..5000). Snipe-tax exempt.
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint16 taxBps,
        uint16 burnShareBps,
        uint16 devBuyBps
    ) external payable nonReentrant returns (address token) {
        if (!initialized) revert NotInitialized();
        if (creationPaused) revert CreationIsPaused();
        if (!(taxBps == 0 || taxBps == 100 || taxBps == 300)) revert InvalidTax();
        if (burnShareBps > BPS) revert InvalidSplit();
        if (devBuyBps > MAX_DEV_BUY_BPS) revert DevBuyTooLarge();
        if (bytes(name).length == 0 || bytes(name).length > 32 || bytes(symbol).length == 0 || bytes(symbol).length > 10) {
            revert BadName();
        }

        address[] memory excluded = new address[](3);
        excluded[0] = address(graduator);
        excluded[1] = poolManager;
        excluded[2] = address(buyback);
        token = address(new YeetToken(name, symbol, metadataURI, taxBps, burnShareBps, address(this), hook, excluded));

        curves[token] = Curve({
            realUsdc: 0,
            tokensSold: 0,
            taxBps: taxBps,
            burnShareBps: burnShareBps,
            complete: false,
            graduated: false,
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            poolId: bytes32(0),
            burnedTokens: 0,
            burnedUsdc: 0
        });
        allTokens.push(token);
        YeetToken(token).approve(address(graduator), LP_SUPPLY);

        emit TokenCreated(token, msg.sender, name, symbol, metadataURI, taxBps, burnShareBps);

        if (devBuyBps > 0) {
            uint256 out = _buy(token, msg.sender, msg.value, 0, true, false);
            if (out < CurveMath.SUPPLY * devBuyBps / BPS) revert DevBuyShortfall();
        } else if (msg.value > 0) {
            _send(msg.sender, msg.value);
        }
    }

    // ---------------------------------------------------------------- trade

    function buy(address token, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        return _buy(token, msg.sender, msg.value, minTokensOut, false, false);
    }

    /// @notice Buy on behalf of `recipient`. Used by the protocol buyback contract (no protocol fee on itself).
    function buyFor(address token, address recipient, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        bool isProtocol = msg.sender == address(buyback);
        return _buy(token, recipient, msg.value, minTokensOut, isProtocol, isProtocol);
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
        uint256 totalDiv = gross * c.taxBps / BPS;
        usdcOut = gross - protocolFee - totalDiv;
        if (usdcOut < minUsdcOut) revert Slippage();

        c.realUsdc -= uint128(gross);
        c.tokensSold -= uint128(tokensIn);
        accruedFees += protocolFee;

        (uint256 holders, uint256 burnUsdc) = _split(c, totalDiv);
        _emitTrade(TradeEv(token, msg.sender, false, gross, tokensIn, protocolFee, holders, burnUsdc, 0), c, p);

        // seller's balance is already reduced, so they do not earn on their own exit
        if (holders > 0) YeetToken(token).notifyDividend{value: holders}();
        if (burnUsdc > 0) _curveBuyback(token, c, p, burnUsdc);
        _send(msg.sender, usdcOut);
        if (c.complete) _afterComplete(token, c);
    }

    struct BuyCalc {
        uint256 taxable; // gross minus snipe tax
        uint256 snipe;
        uint256 protocolFee;
        uint256 totalDiv;
        uint256 net; // USDC that enters the curve
        uint256 out;
        uint256 refund;
        bool completes;
    }

    function _calcBuy(Curve storage c, CurveMath.Params memory p, address token, uint256 gross, bool snipeExempt, bool protocolExempt)
        internal
        view
        returns (BuyCalc memory k)
    {
        k.snipe = snipeExempt ? 0 : gross * snipeTaxBps(token) / BPS;
        k.taxable = gross - k.snipe;
        uint256 pfBps = protocolExempt ? 0 : PROTOCOL_FEE_BPS;
        k.protocolFee = k.taxable * pfBps / BPS;
        k.totalDiv = k.taxable * c.taxBps / BPS;
        k.net = k.taxable - k.protocolFee - k.totalDiv;
        k.out = CurveMath.tokensOut(p, c.realUsdc, c.tokensSold, k.net);
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        if (k.out >= remaining) {
            // final buy: clamp to what is left, charge only for that, refund the rest
            k.out = remaining;
            k.net = CurveMath.usdcIn(p, c.realUsdc, c.tokensSold, k.out);
            uint256 needed = Math.ceilDiv(k.net * BPS, BPS - pfBps - c.taxBps);
            if (needed > k.taxable) needed = k.taxable; // rounding by a wei: absorb, never revert the completing buy
            k.refund = k.taxable - needed;
            k.taxable = needed;
            k.protocolFee = k.taxable * pfBps / BPS;
            k.totalDiv = k.taxable * c.taxBps / BPS;
            k.net = k.taxable - k.protocolFee - k.totalDiv;
            k.completes = true;
        }
    }

    function _buy(address token, address buyer, uint256 value, uint256 minTokensOut, bool snipeExempt, bool protocolExempt)
        internal
        returns (uint256 out)
    {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.complete) revert CurveClosed();
        if (value == 0) revert ZeroAmount();
        CurveMath.Params memory p = curveParams();

        BuyCalc memory k = _calcBuy(c, p, token, value, snipeExempt, protocolExempt);
        out = k.out;
        if (out < minTokensOut) revert Slippage();
        if (k.completes) c.complete = true;

        c.realUsdc += uint128(k.net);
        c.tokensSold += uint128(out);
        accruedFees += k.protocolFee;

        YeetToken(token).transfer(buyer, out);

        // the snipe tax is paid into this token's own reward split
        (uint256 holders, uint256 burnUsdc) = _split(c, k.totalDiv + k.snipe);
        _emitTrade(TradeEv(token, buyer, true, k.net, out, k.protocolFee, holders, burnUsdc, k.snipe), c, p);

        // buyer already holds the tokens, so they share in their own dividend
        if (holders > 0) YeetToken(token).notifyDividend{value: holders}();
        if (burnUsdc > 0 && !c.complete) _curveBuyback(token, c, p, burnUsdc);
        else if (burnUsdc > 0) YeetToken(token).notifyDividend{value: burnUsdc}(); // curve full: nothing left to buy, pay holders instead
        if (k.refund > 0) _send(buyer, k.refund);

        if (c.complete) _afterComplete(token, c);
    }

    /// @dev Buy `usdc` worth of the token from its own curve and burn it. Moves the curve like any other buy.
    function _curveBuyback(address token, Curve storage c, CurveMath.Params memory p, uint256 usdc) internal {
        uint256 out = CurveMath.tokensOut(p, c.realUsdc, c.tokensSold, usdc);
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        if (out >= remaining) {
            out = remaining;
            uint256 needed = CurveMath.usdcIn(p, c.realUsdc, c.tokensSold, out);
            if (needed < usdc) {
                // burn buy completes the curve; leftover USDC goes to holders
                YeetToken(token).notifyDividend{value: usdc - needed}();
                usdc = needed;
            }
            c.complete = true;
        }
        c.realUsdc += uint128(usdc);
        c.tokensSold += uint128(out);
        c.burnedTokens += uint128(out);
        c.burnedUsdc += uint128(usdc);
        YeetToken(token).transfer(DEAD, out);
        emit Buyback(token, usdc, out);
    }

    function _split(Curve storage c, uint256 totalDiv) internal view returns (uint256 holders, uint256 burnUsdc) {
        burnUsdc = totalDiv * c.burnShareBps / BPS;
        holders = totalDiv - burnUsdc;
    }

    struct TradeEv {
        address token;
        address trader;
        bool isBuy;
        uint256 usdcAmount;
        uint256 tokenAmount;
        uint256 protocolFee;
        uint256 dividend;
        uint256 burnUsdc;
        uint256 snipe;
    }

    function _emitTrade(TradeEv memory e, Curve storage c, CurveMath.Params memory p) internal {
        (uint256 vU, uint256 vT) = CurveMath.reserves(p, c.realUsdc, c.tokensSold);
        emit Trade(e.token, e.trader, e.isBuy, e.usdcAmount, e.tokenAmount, e.protocolFee, e.dividend, e.burnUsdc, e.snipe, vU, vT, vU * 1e18 / vT);
    }

    function _afterComplete(address token, Curve storage c) internal {
        emit CurveComplete(token, c.realUsdc);
        _tryGraduate(token, c);
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

    /// @notice Snipe tax in bps for a buy of `token` right now: 9900 at creation, ÷4 per elapsed second, 0 after SNIPE_TAX_SECONDS.
    function snipeTaxBps(address token) public view returns (uint256) {
        uint256 elapsed = block.timestamp - curves[token].createdAt;
        if (elapsed >= SNIPE_TAX_SECONDS) return 0;
        return SNIPE_TAX_START_BPS >> (elapsed * SNIPE_DECAY_SHIFT);
    }

    function snipeTaxSeconds() external pure returns (uint256) {
        return SNIPE_TAX_SECONDS;
    }

    function curveOf(address token) external view returns (Curve memory) {
        return curves[token];
    }

    function isGraduated(address token) external view returns (bool) {
        return curves[token].graduated;
    }

    function quoteBuy(address token, uint256 usdcIn)
        external
        view
        returns (uint256 tokensOut, uint256 protocolFee, uint256 dividend, uint256 burnUsdc, uint256 snipeTax, uint256 refund)
    {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        CurveMath.Params memory p = curveParams();
        snipeTax = usdcIn * snipeTaxBps(token) / BPS;
        uint256 taxable = usdcIn - snipeTax;
        protocolFee = taxable * PROTOCOL_FEE_BPS / BPS;
        uint256 totalDiv = taxable * c.taxBps / BPS;
        uint256 net = taxable - protocolFee - totalDiv;
        tokensOut = CurveMath.tokensOut(p, c.realUsdc, c.tokensSold, net);
        uint256 remaining = CURVE_SUPPLY - c.tokensSold;
        if (tokensOut >= remaining) {
            tokensOut = remaining;
            net = CurveMath.usdcIn(p, c.realUsdc, c.tokensSold, tokensOut);
            uint256 needed = Math.ceilDiv(net * BPS, BPS - PROTOCOL_FEE_BPS - c.taxBps);
            if (needed > taxable) needed = taxable;
            refund = taxable - needed;
            protocolFee = needed * PROTOCOL_FEE_BPS / BPS;
            totalDiv = needed * c.taxBps / BPS;
        }
        totalDiv += snipeTax;
        burnUsdc = totalDiv * c.burnShareBps / BPS;
        dividend = totalDiv - burnUsdc;
    }

    function quoteSell(address token, uint256 tokensIn)
        external
        view
        returns (uint256 usdcOut, uint256 protocolFee, uint256 dividend, uint256 burnUsdc)
    {
        Curve storage c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        CurveMath.Params memory p = curveParams();
        uint256 gross = CurveMath.usdcOut(p, c.realUsdc, c.tokensSold, tokensIn);
        protocolFee = gross * PROTOCOL_FEE_BPS / BPS;
        uint256 totalDiv = gross * c.taxBps / BPS;
        usdcOut = gross - protocolFee - totalDiv;
        burnUsdc = totalDiv * c.burnShareBps / BPS;
        dividend = totalDiv - burnUsdc;
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
