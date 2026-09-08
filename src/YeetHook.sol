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

/// @title YeetHook
/// @notice One Uniswap v4 hook per chain, attached to every graduated pool. On every swap, through ANY router,
///         it takes the 0.3% protocol fee plus the token's dividend rate from the USDC (native, currency0) side
///         and forwards the dividend to the token's ledger. Refuses to be attached to pools it did not authorise.
/// @dev USDC is always currency0 (native, address(0)). Fee is taken in beforeSwap when USDC is the specified
///      currency and in afterSwap when it is the unspecified one, so all four swap shapes are covered.
contract YeetHook is IHooks, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint16 public constant PROTOCOL_FEE_BPS = 30;

    IPoolManager public immutable poolManager;
    address public owner;
    address public pendingOwner;
    address public graduator;
    uint256 public accruedFees;

    mapping(address => bool) public registered; // token => authorised for a pool
    mapping(address => uint16) public taxBpsOf; // token => dividend bps

    event FeesTaken(PoolId indexed poolId, address indexed token, bool isBuy, uint256 protocolFee, uint256 dividend);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event GraduatorSet(address graduator);
    event TokenRegistered(address indexed token, uint16 taxBps);

    error NotPoolManager();
    error NotOwner();
    error NotGraduator();
    error GraduatorAlreadySet();
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

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 amount = accruedFees;
        accruedFees = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    /// @notice Called by the graduator right before it initialises the token's pool.
    function register(address token) external {
        if (msg.sender != graduator) revert NotGraduator();
        uint16 tax = YeetToken(token).taxBps();
        registered[token] = true;
        taxBpsOf[token] = tax;
        emit TokenRegistered(token, tax);
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

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_usdcIsSpecified(params)) {
            uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            (uint256 protocolFee, uint256 dividend) = _fees(Currency.unwrap(key.currency1), amount);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(protocolFee + dividend)), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        address token = Currency.unwrap(key.currency1);
        uint256 usdcAmount;
        int128 hookDeltaUnspecified;

        if (_usdcIsSpecified(params)) {
            // fee already carved out of the specified amount in beforeSwap; recompute to settle it here
            usdcAmount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        } else {
            int128 a0 = delta.amount0();
            usdcAmount = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
        }
        (uint256 protocolFee, uint256 dividend) = _fees(token, usdcAmount);
        uint256 fee = protocolFee + dividend;
        if (!_usdcIsSpecified(params)) hookDeltaUnspecified = int128(int256(fee));

        if (fee > 0) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
            accruedFees += protocolFee;
            if (dividend > 0) YeetToken(token).notifyDividend{value: dividend}();
            emit FeesTaken(key.toId(), token, params.zeroForOne, protocolFee, dividend);
        }
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
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
