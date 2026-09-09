// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IYeetBuyback} from "./interfaces/IYeetGraduator.sol";

interface ILaunchpadForBuyback {
    function isGraduated(address token) external view returns (bool);
    function buyFor(address token, address recipient, uint256 minTokensOut) external payable returns (uint256);
}

/// @title YeetBuyback
/// @notice Receives every protocol fee (native USDC). A fixed 85% can do exactly one thing: buy the protocol token
///         and burn it (no withdraw path exists for it). The remaining 15% accrues to the treasury, which pulls it.
///         The token is set once and is immutable afterwards. Buys from the bonding curve while the token is on
///         it, from its Uniswap v4 pool after graduation.
contract YeetBuyback is IYeetBuyback, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant BPS = 10_000;
    uint256 public constant BURN_SHARE_BPS = 8_500; // immutable: 85% of every protocol fee is bought back and burned

    IPoolManager public immutable poolManager;
    address public immutable hook;
    ILaunchpadForBuyback public immutable launchpad;

    address public token; // set once
    address public treasury;
    uint256 public totalReceived;
    uint256 public totalSpent;
    uint256 public totalBurned;
    uint256 public burnBalance; // USDC reserved for buybacks (85%)
    uint256 public treasuryAccrued; // USDC the treasury may pull (15%)
    uint256 public treasuryTotal;

    event Deposited(address indexed from, uint256 amount, uint256 toBurn, uint256 toTreasury);
    event TokenSet(address indexed token);
    event TreasurySet(address indexed treasury);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event ProtocolBuyback(address indexed token, uint256 usdcIn, uint256 tokensBurned, bool onCurve);

    error TokenAlreadySet();
    error TokenNotSet();
    error NothingToSpend();
    error NotPoolManager();
    error NotTreasury();
    error TransferFailed();

    constructor(IPoolManager poolManager_, address hook_, address launchpad_, address owner_) Ownable(owner_) {
        poolManager = poolManager_;
        hook = hook_;
        launchpad = ILaunchpadForBuyback(launchpad_);
        treasury = owner_;
    }

    receive() external payable {
        _deposit();
    }

    function deposit() external payable {
        _deposit();
    }

    function _deposit() internal {
        uint256 toBurn = msg.value * BURN_SHARE_BPS / BPS;
        uint256 toTreasury = msg.value - toBurn;
        totalReceived += msg.value;
        burnBalance += toBurn;
        treasuryAccrued += toTreasury;
        emit Deposited(msg.sender, msg.value, toBurn, toTreasury);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Treasury pulls its 15%. Pull, not push, because native sends to a blocklisted address revert on Arc.
    function withdrawTreasury() external nonReentrant {
        if (msg.sender != treasury) revert NotTreasury();
        uint256 amount = treasuryAccrued;
        treasuryAccrued = 0;
        treasuryTotal += amount;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit TreasuryWithdrawn(treasury, amount);
    }

    /// @notice One-shot. After this the destination of every protocol fee is fixed forever.
    function setToken(address token_) external onlyOwner {
        if (token != address(0)) revert TokenAlreadySet();
        token = token_;
        emit TokenSet(token_);
    }

    /// @notice Permissionless: spend up to `maxUsdc` of the burn balance buying the protocol token and burning it.
    function execute(uint256 maxUsdc) external nonReentrant returns (uint256 usdcIn, uint256 burned) {
        address t = token;
        if (t == address(0)) revert TokenNotSet();
        usdcIn = burnBalance;
        if (maxUsdc < usdcIn) usdcIn = maxUsdc;
        if (usdcIn == 0) revert NothingToSpend();
        burnBalance -= usdcIn;
        bool onCurve = !launchpad.isGraduated(t);
        if (onCurve) {
            burned = launchpad.buyFor{value: usdcIn}(t, DEAD, 0);
        } else {
            bytes memory r = poolManager.unlock(abi.encode(t, usdcIn));
            uint256 spent;
            (burned, spent) = abi.decode(r, (uint256, uint256));
            if (spent < usdcIn) burnBalance += usdcIn - spent; // price-limit leftover stays reserved for burns
            usdcIn = spent;
        }
        totalSpent += usdcIn;
        totalBurned += burned;
        emit ProtocolBuyback(t, usdcIn, burned, onCurve);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address t, uint256 usdcIn) = abi.decode(data, (address, uint256));
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(t),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        BalanceDelta d = poolManager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(usdcIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 owed0 = uint256(uint128(-d.amount0()));
        uint256 out = uint256(uint128(d.amount1()));
        poolManager.settle{value: owed0}();
        poolManager.take(key.currency1, DEAD, out);
        return abi.encode(out, owed0);
    }
}
