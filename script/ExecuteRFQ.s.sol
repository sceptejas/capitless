// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {RFQExecutor}     from "../contracts/RFQExecutor.sol";
import {IRFQExecutor}    from "../contracts/interfaces/IRFQExecutor.sol";
import {IExecutionAdapter} from "../contracts/interfaces/IExecutionAdapter.sol";
import {IStrategyPolicy}   from "../contracts/interfaces/IStrategyPolicy.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}         from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}           from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary}     from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice End-to-end RFQ execution on Sepolia.
/// Maker signs the order; Taker (deployer wallet) submits and pays USDC, receives WETH.
contract ExecuteRFQ is Script {
    function run() external {
        // Addresses from deployments/11155111.json
        address rfqExecutor = vm.envAddress("RFQ_EXECUTOR");
        address adapter     = vm.envAddress("ADAPTER");
        bytes32 strategyId  = vm.envBytes32("STRATEGY_ID");
        address usdc        = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        address weth        = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        address hook        = vm.envAddress("HOOK");

        uint256 makerKey    = vm.envUint("MAKER_PRIVATE_KEY");
        uint256 takerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY"); // deployer acts as taker
        address maker       = vm.addr(makerKey);
        address taker       = vm.addr(takerKey);

        // Build the pool key and route
        (address c0, address c1) = usdc < weth ? (usdc, weth) : (weth, usdc);
        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });

        // Single leg: buy 100 wei WETH exact out — sized to match testnet pool depth
        IExecutionAdapter.Leg[] memory legs = new IExecutionAdapter.Leg[](1);
        legs[0] = IExecutionAdapter.Leg({
            poolKey:           poolKey,
            legAmountOut:      100,          // 100 wei WETH exact output
            sqrtPriceLimitX96: 0,
            hookData:          ""
        });
        IExecutionAdapter.Route memory route = IExecutionAdapter.Route({legs: legs});
        bytes memory routeData = abi.encode(route);
        bytes32 routeHash = keccak256(routeData);

        // Approve pool key hash in strategy (only needed if not already approved)
        // (Already done in ConfigureStrategy but we re-approve this specific routeHash)
        vm.startBroadcast(makerKey);
        IStrategyPolicy(vm.envAddress("STRATEGY_POLICY")).setPoolApproval(strategyId, routeHash, true);
        vm.stopBroadcast();

        // Build the order
        IRFQExecutor.RFQOrder memory order = IRFQExecutor.RFQOrder({
            strategyId:       strategyId,
            maker:            maker,
            taker:            taker,
            tokenIn:          usdc,
            tokenOut:         weth,
            quoteAmountIn:    1_000,         // 0.001 USDC
            exactAmountOut:   100,           // 100 wei WETH
            minMakerProceeds: 1,
            expiry:           block.timestamp + 1 hours,
            nonce:            0,
            policyVersion:    0,
            adapter:          adapter,
            routeHash:        routeHash
        });

        // Sign as Maker
        bytes32 digest = RFQExecutor(rfqExecutor).hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        console.log("=== ExecuteRFQ ===");
        console.log("Maker:", maker);
        console.log("Taker:", taker);
        console.log("Quote USDC:", order.quoteAmountIn);
        console.log("Exact WETH out:", order.exactAmountOut);

        uint256 takerUsdcBefore = IERC20(usdc).balanceOf(taker);
        uint256 takerWethBefore = IERC20(weth).balanceOf(taker);
        uint256 makerUsdcBefore = IERC20(usdc).balanceOf(maker);

        // Taker approves and submits
        vm.startBroadcast(takerKey);
        IERC20(usdc).approve(rfqExecutor, type(uint256).max);
        RFQExecutor(rfqExecutor).executeRFQ(order, sig, routeData);
        vm.stopBroadcast();

        uint256 takerUsdcAfter = IERC20(usdc).balanceOf(taker);
        uint256 takerWethAfter = IERC20(weth).balanceOf(taker);
        uint256 makerUsdcAfter = IERC20(usdc).balanceOf(maker);

        console.log("=== Result ===");
        console.log("Taker USDC spent:", takerUsdcBefore - takerUsdcAfter);
        console.log("Taker WETH received:", takerWethAfter - takerWethBefore);
        console.log("Maker USDC earned:", makerUsdcAfter - makerUsdcBefore);
        console.log("=== SUCCESS ===");
    }
}
