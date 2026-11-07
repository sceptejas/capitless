// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console}    from "forge-std/Script.sol";
import {CREPolicyConsumer}  from "../contracts/CREPolicyConsumer.sol";
import {StrategyPolicy}     from "../contracts/StrategyPolicy.sol";

/// @notice Deploy CREPolicyConsumer and grant it CRE_CONSUMER_ROLE in StrategyPolicy.
///
/// Prerequisites: Deploy.s.sol must have run.
///
/// Run:
///   STRATEGY_POLICY=<addr> forge script script/DeployCRE.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast --chain 11155111 -vvvv
contract DeployCRE is Script {
    // MockKeystoneForwarder on Ethereum Sepolia (simulation mode)
    address constant MOCK_FORWARDER = 0x15fC6ae953E024d975e77382eEeC56A9101f9F88;

    function run() external {
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer       = vm.addr(deployerKey);
        address strategyPolicy = vm.envAddress("STRATEGY_POLICY");

        console.log("=== DeployCRE ===");
        console.log("StrategyPolicy:", strategyPolicy);
        console.log("Forwarder (mock):", MOCK_FORWARDER);

        vm.startBroadcast(deployerKey);

        // Deploy CREPolicyConsumer pointed at the mock forwarder (simulation mode)
        CREPolicyConsumer consumer = new CREPolicyConsumer(
            MOCK_FORWARDER,
            strategyPolicy
        );
        console.log("CREPolicyConsumer:", address(consumer));

        // Grant CRE_CONSUMER_ROLE to the consumer so it can call applyCREPolicyUpdate
        StrategyPolicy policy = StrategyPolicy(strategyPolicy);
        bytes32 creRole = policy.CRE_CONSUMER_ROLE();
        policy.grantRole(creRole, address(consumer));
        console.log("CRE_CONSUMER_ROLE granted to consumer");

        vm.stopBroadcast();

        console.log("=== DeployCRE complete ===");
        console.log("Set CONSUMER_ADDRESS =", address(consumer), "in the CRE workflow env");
    }
}
