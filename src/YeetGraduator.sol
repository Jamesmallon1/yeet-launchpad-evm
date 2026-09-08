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
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {YeetHook} from "./YeetHook.sol";
import {IYeetGraduator} from "./interfaces/IYeetGraduator.sol";

/// @title YeetGraduator
/// @notice Moves a completed curve into a Uniswap v4 pool: native USDC / token, fee 0, our hook. Seeds a
///         full-range position with ALL the raised USDC and ALL the reserved tokens at the curve's final price,
///         and holds that position forever (there is no function to remove it).
contract YeetGraduator is IUnlockCallback, IYeetGraduator {
    using PoolIdLibrary for PoolKey;

    int24 public constant TICK_SPACING = 60;
    int24 public constant TICK_LOWER = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING; // -887220
    int24 public constant TICK_UPPER = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING; // 887220
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    YeetHook public immutable hook;
    address public immutable launchpad;

    mapping(address => PoolId) public poolOf;
    mapping(address => uint128) public liquidityOf;

    event Graduated(
        address indexed token,
        PoolId indexed poolId,
        uint256 usdcIn,
        uint256 tokensIn,
        uint160 sqrtPriceX96,
        uint128 liquidity
    );

    error NotLaunchpad();
    error NotPoolManager();
    error AlreadyGraduated();
    error NoUsdc();

    constructor(IPoolManager poolManager_, YeetHook hook_, address launchpad_) {
        poolManager = poolManager_;
        hook = hook_;
        launchpad = launchpad_;
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

    /// @notice msg.value = raised USDC. Pulls `tokens` (the launchpad's LP_SUPPLY, pre-approved at creation).
    function graduate(address token, uint256 tokens) external payable returns (bytes32) {
        if (msg.sender != launchpad) revert NotLaunchpad();
        if (PoolId.unwrap(poolOf[token]) != bytes32(0)) revert AlreadyGraduated();
        if (msg.value == 0) revert NoUsdc();

        uint256 usdc = msg.value;
        IERC20(token).transferFrom(launchpad, address(this), tokens);

        hook.register(token);
        PoolKey memory key = poolKey(token);
        uint160 sqrtPriceX96 = _sqrtPriceX96(usdc, tokens);
        poolManager.initialize(key, sqrtPriceX96);

        bytes memory result = poolManager.unlock(abi.encode(key, usdc, tokens, sqrtPriceX96));
        (uint128 liquidity, uint256 used0, uint256 used1) = abi.decode(result, (uint128, uint256, uint256));

        PoolId id = key.toId();
        poolOf[token] = id;
        liquidityOf[token] = liquidity;

        // tick-rounding dust: burn leftover tokens, leftover USDC (wei) stays here
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).transfer(DEAD, dust);

        emit Graduated(token, id, used0, used1, sqrtPriceX96, liquidity);
        return PoolId.unwrap(id);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 usdc, uint256 tokens, uint160 sqrtPriceX96) =
            abi.decode(data, (PoolKey, uint256, uint256, uint160));

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            usdc,
            tokens
        );

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        uint256 owed0 = uint256(uint128(-delta.amount0()));
        uint256 owed1 = uint256(uint128(-delta.amount1()));

        poolManager.settle{value: owed0}();
        poolManager.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), owed1);
        poolManager.settle();

        return abi.encode(liquidity, owed0, owed1);
    }

    /// @dev sqrt(tokens / usdc) * 2^96, both 18-dec. currency0 = USDC, currency1 = token.
    function _sqrtPriceX96(uint256 usdc, uint256 tokens) internal pure returns (uint160) {
        uint256 ratioX192 = FullMath.mulDiv(tokens, 1 << 192, usdc);
        uint256 sqrtP = Math.sqrt(ratioX192);
        require(sqrtP > TickMath.MIN_SQRT_PRICE && sqrtP < TickMath.MAX_SQRT_PRICE, "price out of range");
        return uint160(sqrtP);
    }
}
