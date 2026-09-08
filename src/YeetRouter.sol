// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YeetHook} from "./YeetHook.sol";

/// @title YeetRouter
/// @notice Thin swap router for graduated pools, used by the yeet.family UI: native USDC in / out.
contract YeetRouter is IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant BPS = 10_000;
    int24 public constant TICK_SPACING = 60;

    IPoolManager public immutable poolManager;
    YeetHook public immutable hook;

    enum Action {
        Buy,
        Sell
    }

    struct Call {
        Action action;
        address token;
        address user;
        uint256 amountIn;
        uint256 minOut;
    }

    event Swapped(address indexed token, address indexed user, bool isBuy, uint256 amountIn, uint256 amountOut);

    error NotPoolManager();
    error Slippage();
    error ZeroAmount();
    error TransferFailed();

    constructor(IPoolManager poolManager_, YeetHook hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    receive() external payable {}

    function poolKey(address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @notice Spend msg.value USDC, receive at least `minOut` tokens.
    function buy(address token, uint256 minOut) external payable nonReentrant returns (uint256 out) {
        if (msg.value == 0) revert ZeroAmount();
        bytes memory r = poolManager.unlock(abi.encode(Call(Action.Buy, token, msg.sender, msg.value, minOut)));
        out = abi.decode(r, (uint256));
        emit Swapped(token, msg.sender, true, msg.value, out);
    }

    /// @notice Sell `amountIn` tokens (needs approval), receive at least `minOut` USDC.
    function sell(address token, uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        bytes memory r = poolManager.unlock(abi.encode(Call(Action.Sell, token, msg.sender, amountIn, minOut)));
        out = abi.decode(r, (uint256));
        emit Swapped(token, msg.sender, false, amountIn, out);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Call memory c = abi.decode(data, (Call));
        PoolKey memory key = poolKey(c.token);

        if (c.action == Action.Buy) {
            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(c.amountIn),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            uint256 owed0 = uint256(uint128(-delta.amount0()));
            uint256 out = uint256(uint128(delta.amount1()));
            if (out < c.minOut) revert Slippage();
            poolManager.settle{value: owed0}();
            poolManager.take(key.currency1, c.user, out);
            if (c.amountIn > owed0) _send(c.user, c.amountIn - owed0); // price limit hit: refund unspent USDC
            return abi.encode(out);
        } else {
            poolManager.sync(key.currency1);
            IERC20(c.token).transfer(address(poolManager), c.amountIn);
            poolManager.settle();
            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(c.amountIn),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            uint256 spent1 = uint256(uint128(-delta.amount1()));
            uint256 out = uint256(uint128(delta.amount0()));
            if (out < c.minOut) revert Slippage();
            poolManager.take(key.currency0, c.user, out);
            if (c.amountIn > spent1) poolManager.take(key.currency1, c.user, c.amountIn - spent1);
            return abi.encode(out);
        }
    }

    /// @notice Exact quote for a single full-range position pool (fee 0 + hook fee on the USDC side).
    function quote(address token, bool isBuy, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 fee, uint160 sqrtPriceX96, uint128 liquidity)
    {
        PoolId id = poolKey(token).toId();
        (sqrtPriceX96,,,) = poolManager.getSlot0(id);
        liquidity = poolManager.getLiquidity(id);
        uint256 feeBps = hook.feeBpsOf(token);
        if (isBuy) {
            fee = amountIn * feeBps / BPS;
            uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn - fee, true);
            amountOut = SqrtPriceMath.getAmount1Delta(next, sqrtPriceX96, liquidity, false);
        } else {
            uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, false);
            uint256 gross = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, next, liquidity, false);
            fee = gross * feeBps / BPS;
            amountOut = gross - fee;
        }
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
