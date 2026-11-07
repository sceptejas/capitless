// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console}   from "forge-std/Script.sol";
import {StrategyPolicy}    from "../contracts/StrategyPolicy.sol";
import {IStrategyPolicy}   from "../contracts/interfaces/IStrategyPolicy.sol";
import {LPFeeLibrary}      from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey}           from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}          from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}            from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Create the demo strategy and configure all permissions.
///
/// Must be called by the MAKER wallet (the strategy owner).
///
/// Prerequisites: Deploy.s.sol, DeployHook.s.sol must have run.
///
/// Run:
///   STRATEGY_POLICY=<addr> ADAPTER=<addr> HOOK=<addr> \
///   forge script script/ConfigureStrategy.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $MAKER_PRIVATE_KEY \
///     --broadcast --chain 11155111 -vvvv
contract ConfigureStrategy is Script {
    using PoolIdLibrary for PoolKey;

    // Tokens — Ethereum Sepolia
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Circle USDC Sepolia
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // WETH Sepolia

    // Demo strategy ID — deterministic, used across all scripts and tests
    bytes32 constant STRATEGY_ID = keccak256("CAPITLESS_DEMO_STRATEGY_V1");

    // Fee params (v4 units: hundredths of a bip)
    uint24 constant MIN_FEE      = 500;    // 0.05%
    uint24 constant MAX_FEE      = 10_000; // 1.00%
    uint24 constant INITIAL_FEE  = 3_000;  // 0.30% — CRE will update this

    // Execution limits
    uint256 constant MAX_ORDER_SIZE  = 100_000e6;  // 100k USDC max per order
    uint256 constant MAX_SLIPPAGE_BPS = 100;        // 1% max slippage

    function run() external {
        uint256 makerKey       = vm.envUint("MAKER_PRIVATE_KEY");
        address maker          = vm.addr(makerKey);
        address strategyPolicy = vm.envAddress("STRATEGY_POLICY");
        address adapter        = vm.envAddress("ADAPTER");
        address hook           = vm.envAddress("HOOK");

        StrategyPolicy policy = StrategyPolicy(strategyPolicy);

        console.log("=== ConfigureStrategy ===");
        console.log("Maker:          ", maker);
        console.log("StrategyPolicy: ", strategyPolicy);
        console.log("Adapter:        ", adapter);
        console.log("Hook:           ", hook);
        console.log("Strategy ID:    ", vm.toString(STRATEGY_ID));

        vm.startBroadcast(makerKey);

        // 1. Create strategy
        policy.createStrategy(STRATEGY_ID, MIN_FEE, MAX_FEE, MAX_ORDER_SIZE, MAX_SLIPPAGE_BPS);
        console.log("Strategy created");

        // 2. Activate strategy
        policy.setStrategyActive(STRATEGY_ID, true);
        console.log("Strategy activated");

        // 3. Approve USDC (tokenIn) and WETH (tokenOut)
        policy.setTokenApproval(STRATEGY_ID, USDC, true);
        policy.setTokenApproval(STRATEGY_ID, WETH, true);
        console.log("Tokens approved: USDC, WETH");

        // 4. Approve the adapter
        policy.setAdapterApproval(STRATEGY_ID, adapter, true);
        console.log("Adapter approved:", adapter);

        // 5. Approve the USDC/WETH dynamic-fee pool
        //    PoolKey must match the one initialised in DeployHook.s.sol exactly
        (address c0, address c1) = USDC < WETH ? (USDC, WETH) : (WETH, USDC);
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });
        bytes32 poolKeyHash = keccak256(abi.encode(key));
        policy.setPoolApproval(STRATEGY_ID, poolKeyHash, true);
        console.log("Pool approved. PoolKeyHash:", vm.toString(poolKeyHash));

        vm.stopBroadcast();

        console.log("=== ConfigureStrategy complete ===");
        console.log("Set STRATEGY_ID =", vm.toString(STRATEGY_ID), "in maker-engine and CRE workflow env");
    }
}
