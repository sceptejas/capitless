// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console}  from "forge-std/Script.sol";
import {IPoolManager}     from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks}           from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary}     from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}         from "@uniswap/v4-core/src/types/Currency.sol";
import {IUnlockCallback}  from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta}     from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Deployed by the script; holds tokens and executes the unlock callback.
contract LiquidityAdder is IUnlockCallback {
    IPoolManager public pm;
    constructor(address _pm) { pm = IPoolManager(_pm); }

    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityAmount,
        address token0,
        address token1
    ) external {
        // Approve PM to pull tokens during settle
        IERC20(token0).approve(address(pm), type(uint256).max);
        IERC20(token1).approve(address(pm), type(uint256).max);
        pm.unlock(abi.encode(key, tickLower, tickUpper, liquidityAmount, token0, token1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not PM");
        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidityAmount,
            address token0,
            address token1
        ) = abi.decode(data, (PoolKey, int24, int24, uint128, address, address));

        (BalanceDelta delta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      tickLower,
                tickUpper:      tickUpper,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt:           bytes32(0)
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 < 0) {
            pm.sync(key.currency0);
            IERC20(token0).transfer(address(pm), uint256(uint128(-d0)));
            pm.settle();
        }
        if (d1 < 0) {
            pm.sync(key.currency1);
            IERC20(token1).transfer(address(pm), uint256(uint128(-d1)));
            pm.settle();
        }
        return "";
    }
}

contract SeedPools is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 lpKey    = vm.envUint("LP_PRIVATE_KEY");
        address pm       = vm.envAddress("POOL_MANAGER");
        address hook     = vm.envAddress("HOOK");
        address usdc     = vm.envAddress("USDC");
        address weth     = vm.envAddress("WETH");
        uint128 liq      = uint128(vm.envOr("LIQUIDITY", uint256(1e17)));
        int24 tickLower  = int24(int256(vm.envOr("TICK_LOWER", int256(-887220))));
        int24 tickUpper  = int24(int256(vm.envOr("TICK_UPPER", int256(887220))));

        (address c0, address c1) = usdc < weth ? (usdc, weth) : (weth, usdc);

        PoolKey memory poolA = PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });
        PoolKey memory poolB = PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });

        console.log("=== SeedPools ===");
        console.log("Pool A:", vm.toString(PoolId.unwrap(poolA.toId())));
        console.log("Pool B:", vm.toString(PoolId.unwrap(poolB.toId())));

        vm.startBroadcast(lpKey);

        // Deploy LiquidityAdder helper
        LiquidityAdder adder = new LiquidityAdder(pm);

        // Fund the adder with tokens
        uint256 usdcBal = IERC20(usdc).balanceOf(vm.addr(lpKey));
        uint256 wethBal = IERC20(weth).balanceOf(vm.addr(lpKey));
        console.log("LP USDC:", usdcBal);
        console.log("LP WETH:", wethBal);

        IERC20(usdc).transfer(address(adder), usdcBal / 2);
        IERC20(weth).transfer(address(adder), wethBal / 2);

        // Approve PM from adder
        // (adder does internal transfers directly in unlockCallback)

        // Seed Pool A
        adder.addLiquidity(poolA, tickLower, tickUpper, liq, c0, c1);
        console.log("Pool A liquidity added");

        // Seed Pool B
        adder.addLiquidity(poolB, tickLower, tickUpper, liq, c0, c1);
        console.log("Pool B liquidity added");

        vm.stopBroadcast();
        console.log("=== SeedPools complete ===");
    }
}
