// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {YeetToken} from "./YeetToken.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IYeetBuyback} from "./interfaces/IYeetGraduator.sol";

/// @title YeetHook
/// @notice One Uniswap v4 hook per chain, attached to every graduated pool. On every swap, through ANY router,
///         it takes the 0.3% protocol fee plus the token's dividend rate from the USDC (native, currency0) side
///         and forwards the dividend to the token's ledger. Refuses to be attached to pools it did not authorise.
/// @dev USDC is always currency0 (native, address(0)). Fee is taken in beforeSwap when USDC is the specified
///      currency and in afterSwap when it is the unspecified one, so all four swap shapes are covered.
contract YeetHook is IHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint16 public constant PROTOCOL_FEE_BPS = 30;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    address public owner;
    address public pendingOwner;
    address public graduator;
    address public buyback; // protocol buyback contract: the only destination for protocol fees
    uint256 public accruedFees; // protocol fees not yet swept to `buyback`

    mapping(address => bool) public registered; // token => authorised for a pool
    mapping(address => uint16) public taxBpsOf; // token => dividend bps
    mapping(address => uint16) public burnShareOf; // token => share of dividend that buys back + burns
    mapping(address => uint256) public pendingBurn; // token => USDC waiting to buy the token back and burn it
    mapping(address => uint256) public totalBurned; // token => tokens burned by pool buybacks
    bool private _inBuyback;

    event FeesTaken(PoolId indexed poolId, address indexed token, bool isBuy, uint256 protocolFee, uint256 dividend, uint256 burnUsdc);
    event FeesSwept(uint256 amount);
    event Buyback(address indexed token, uint256 usdcIn, uint256 tokensBurned);
    event GraduatorSet(address graduator);
    event BuybackSet(address buyback);
    event TokenRegistered(address indexed token, uint16 taxBps, uint16 burnShareBps);

    error NotPoolManager();
    error NotOwner();
    error NotGraduator();
    error GraduatorAlreadySet();
    error BuybackAlreadySet();
    error NothingPending();
    error UnauthorisedPool();
    error HookNotImplemented();
    error TransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager poolManager_, address owner_) {
        poolManager = poolManager_;
        owner = owner_;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    receive() external payable {}

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- admin

    function setGraduator(address graduator_) external onlyOwner {
        if (graduator != address(0)) revert GraduatorAlreadySet();
        graduator = graduator_;
        emit GraduatorSet(graduator_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setBuyback(address buyback_) external onlyOwner {
        if (buyback != address(0)) revert BuybackAlreadySet();
        buyback = buyback_;
        emit BuybackSet(buyback_);
    }

    /// @notice Permissionless: move accrued protocol fees to the buyback contract (their only possible destination).
    function sweepFees() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) return;
        accruedFees = 0;
        IYeetBuyback(buyback).deposit{value: amount}();
        emit FeesSwept(amount);
    }

    /// @notice Called by the graduator right before it initialises the token's pool.
    function register(address token) external {
        if (msg.sender != graduator) revert NotGraduator();
        YeetToken t = YeetToken(token);
        registered[token] = true;
        taxBpsOf[token] = t.taxBps();
        burnShareOf[token] = t.burnShareBps();
        emit TokenRegistered(token, t.taxBps(), t.burnShareBps());
    }

    /// @notice Permissionless: spend the token's pending burn USDC buying it from its own pool and burning it.
    ///         (A swap cannot re-enter its own pool from inside the hook callback, so this runs as a separate call;
    ///         the backend keeper triggers it after trades.)
    function executeBuyback(address token) external nonReentrant returns (uint256 usdcIn, uint256 burned) {
        usdcIn = pendingBurn[token];
        if (usdcIn == 0) revert NothingPending();
        pendingBurn[token] = 0;
        _inBuyback = true;
        bytes memory r = poolManager.unlock(abi.encode(token, usdcIn));
        _inBuyback = false;
        (burned, usdcIn) = abi.decode(r, (uint256, uint256));
        totalBurned[token] += burned;
        emit Buyback(token, usdcIn, burned);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, uint256 usdcIn) = abi.decode(data, (address, uint256));
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
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

    /// @notice Total swap fee in bps taken on the USDC side for `token`'s pool.
    function feeBpsOf(address token) public view returns (uint256) {
        return PROTOCOL_FEE_BPS + taxBpsOf[token];
    }

    // ---------------------------------------------------------------- hooks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != graduator) revert UnauthorisedPool();
        if (!key.currency0.isAddressZero()) revert UnauthorisedPool();
        if (!registered[Currency.unwrap(key.currency1)]) revert UnauthorisedPool();
        if (key.fee != 0) revert UnauthorisedPool();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_feeExempt(sender)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (_usdcIsSpecified(params)) {
            uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            (uint256 protocolFee, uint256 dividend) = _fees(Currency.unwrap(key.currency1), amount);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(protocolFee + dividend)), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (_feeExempt(sender)) return (IHooks.afterSwap.selector, 0);
        bool usdcSpecified = _usdcIsSpecified(params);
        uint256 usdcAmount;
        if (usdcSpecified) {
            // fee already carved out of the specified amount in beforeSwap; recompute to settle it here
            usdcAmount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        } else {
            int128 a0 = delta.amount0();
            usdcAmount = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
        }
        uint256 fee = _distribute(key, params.zeroForOne, usdcAmount);
        return (IHooks.afterSwap.selector, usdcSpecified ? int128(0) : int128(int256(fee)));
    }

    /// @dev take the fee from the PoolManager and split it: protocol -> accrued (sweepable only to the buyback
    ///      contract), dividend -> holders now and/or pending buyback-and-burn per the token's split
    function _distribute(PoolKey calldata key, bool isBuy, uint256 usdcAmount) internal returns (uint256 fee) {
        address token = Currency.unwrap(key.currency1);
        (uint256 protocolFee, uint256 dividend) = _fees(token, usdcAmount);
        fee = protocolFee + dividend;
        if (fee == 0) return 0;
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
        accruedFees += protocolFee;
        uint256 burnUsdc = dividend * burnShareOf[token] / BPS;
        uint256 holders = dividend - burnUsdc;
        if (holders > 0) YeetToken(token).notifyDividend{value: holders}();
        if (burnUsdc > 0) pendingBurn[token] += burnUsdc;
        emit FeesTaken(key.toId(), token, isBuy, protocolFee, holders, burnUsdc);
    }

    /// @dev our own buyback swaps and the protocol buyback contract pay no hook fees (they would be fees on fees)
    function _feeExempt(address sender) internal view returns (bool) {
        return _inBuyback || sender == address(this) || sender == buyback;
    }

    // ---------------------------------------------------------------- internal

    /// @dev specified currency is currency0 (USDC) for exact-in buys and exact-out sells.
    function _usdcIsSpecified(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _fees(address token, uint256 usdcAmount) internal view returns (uint256 protocolFee, uint256 dividend) {
        protocolFee = usdcAmount * PROTOCOL_FEE_BPS / BPS;
        dividend = usdcAmount * taxBpsOf[token] / BPS;
    }

    // ---------------------------------------------------------------- unused hooks

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
