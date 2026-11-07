// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {StrategyPolicy}    from "../contracts/StrategyPolicy.sol";
import {RFQExecutor}       from "../contracts/RFQExecutor.sol";
import {UniswapV4Adapter}  from "../contracts/adapters/UniswapV4Adapter.sol";
import {IPoolManager}      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStrategyPolicy}   from "../contracts/interfaces/IStrategyPolicy.sol";

/// @notice Deploy core contracts in dependency order:
///   1. StrategyPolicy
///   2. RFQExecutor  (reads StrategyPolicy)
///   3. UniswapV4Adapter (reads StrategyPolicy, calls PoolManager)
///
/// Run on Anvil (local):
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
///
/// Run on Ethereum Sepolia:
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL \
///     --private-key $DEPLOYER_PRIVATE_KEY --broadcast --chain 11155111 -vvvv
contract Deploy is Script {
    // Ethereum Sepolia PoolManager
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("=== CAPITLESS Deploy ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerKey);

        // 1 — StrategyPolicy
        StrategyPolicy policy = new StrategyPolicy(deployer);
        console.log("StrategyPolicy:   ", address(policy));

        // 2 — RFQExecutor
        RFQExecutor executor = new RFQExecutor(address(policy), deployer);
        console.log("RFQExecutor:      ", address(executor));

        // 3 — UniswapV4Adapter
        UniswapV4Adapter adapter = new UniswapV4Adapter(
            IPoolManager(POOL_MANAGER),
            IStrategyPolicy(address(policy)),
            address(executor)
        );
        console.log("UniswapV4Adapter: ", address(adapter));

        vm.stopBroadcast();

        // Write addresses to environment so subsequent scripts can read them
        _writeAddresses(address(policy), address(executor), address(adapter));
    }

    function _writeAddresses(address policy, address executor, address adapter) internal {
        string memory json = string(abi.encodePacked(
            '{\n',
            '  "chainId": ', vm.toString(block.chainid), ',\n',
            '  "StrategyPolicy":   "', vm.toString(policy),   '",\n',
            '  "RFQExecutor":      "', vm.toString(executor), '",\n',
            '  "UniswapV4Adapter": "', vm.toString(adapter),  '",\n',
            '  "CapitallessHook":  "TBD",\n',
            '  "CREPolicyConsumer":"TBD"\n',
            '}\n'
        ));
        vm.writeFile(
            string(abi.encodePacked("deployments/", vm.toString(block.chainid), ".json")),
            json
        );
        console.log("Addresses written to deployments/", vm.toString(block.chainid), ".json");
    }
}
