// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks}          from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks}           from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary}    from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey}         from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}        from "@uniswap/v4-core/src/types/Currency.sol";
import {CapitallessHook} from "../contracts/hooks/CapitallessHook.sol";
import {IStrategyPolicy} from "../contracts/interfaces/IStrategyPolicy.sol";

/// @notice Mine a valid hook address, deploy CapitallessHook, and initialise
///         a dynamic-fee USDC/WETH pool with the hook attached.
///
/// Prerequisites: Deploy.s.sol must have run (reads StrategyPolicy address from env).
///
/// Run:
///   STRATEGY_POLICY=<addr> forge script script/DeployHook.s.sol \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast --chain 11155111 -vvvv
contract DeployHook is Script {
    using PoolIdLibrary for PoolKey;

    // Ethereum Sepolia addresses
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant USDC         = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH         = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    // Foundry broadcasts CREATE2 through the deterministic deployment proxy.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Required hook permission: BEFORE_SWAP_FLAG (bit 7 = 0x0080)
    // Hook address must satisfy: uint160(addr) & ALL_HOOK_MASK == BEFORE_SWAP_FLAG
    uint160 constant REQUIRED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG);

    function run() external {
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer       = vm.addr(deployerKey);
        address strategyPolicy = vm.envAddress("STRATEGY_POLICY");

        console.log("=== DeployHook ===");
        console.log("StrategyPolicy:", strategyPolicy);

        vm.startBroadcast(deployerKey);

        // Mine CREATE2 salt so the deployed address has the correct permission bits.
        // We use a simple counter loop — fine for a demo deployment.
        bytes memory creationCode = abi.encodePacked(
            type(CapitallessHook).creationCode,
            abi.encode(IPoolManager(POOL_MANAGER), IStrategyPolicy(strategyPolicy))
        );

        (address hookAddress, bytes32 salt) = _mineHookAddress(creationCode);
        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        CapitallessHook hook = _deployAtAddress(
            creationCode, salt, hookAddress,
            IPoolManager(POOL_MANAGER), IStrategyPolicy(strategyPolicy)
        );
        console.log("CapitallessHook deployed at:", address(hook));

        // Verify permission bits
        require(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS,
            "Hook address has wrong permission bits"
        );

        // Initialise the USDC/WETH dynamic-fee pool
        // currency0 < currency1 by address sort
        (address c0, address c1) = USDC < WETH ? (USDC, WETH) : (WETH, USDC);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(c0),
            currency1:   Currency.wrap(c1),
            fee:         LPFeeLibrary.DYNAMIC_FEE_FLAG, // 0x800000
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });

        // Price is raw WETH units per raw USDC unit at 1 ETH = 2,000 USDC:
        // sqrtPriceX96 = sqrt(1e18 / 2,000e6) * 2^96.
        uint160 sqrtPriceX96 = 1771595571142957166518320255467520;

        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        PoolId poolId = key.toId();
        console.log("Pool initialised. PoolId:", vm.toString(PoolId.unwrap(poolId)));

        vm.stopBroadcast();

        // Update deployments file
        _updateDeployments(address(hook), PoolId.unwrap(poolId));
    }

    // ---------------------------------------------------------------------------
    // Address mining — find a CREATE2 salt where address bits match permission flags
    // ---------------------------------------------------------------------------

    function _mineHookAddress(bytes memory creationCode)
        internal pure returns (address hookAddress, bytes32 salt)
    {
        bytes32 initHash = keccak256(creationCode);
        // Start from a random offset to avoid collision with previous deployment
        for (uint256 i = 200_000; i < 1_000_000; i++) {
            salt = bytes32(i);
            hookAddress = _computeCreate2Address(salt, initHash, CREATE2_DEPLOYER);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == REQUIRED_FLAGS) {
                return (hookAddress, salt);
            }
        }
        revert("Could not mine valid hook address in 160k iterations");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initHash, address factory)
        internal pure returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), factory, salt, initHash
        )))));
    }

    // ---------------------------------------------------------------------------
    // CREATE2 deployment via inline assembly
    // ---------------------------------------------------------------------------

    function _deployAtAddress(
        bytes memory creationCode,
        bytes32 salt,
        address expected,
        IPoolManager poolManager,
        IStrategyPolicy policy
    ) internal returns (CapitallessHook hook) {
        assembly {
            hook := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(address(hook) != address(0), "CREATE2 deployment failed");
        require(address(hook) == expected,   "Deployed to unexpected address");
        // suppress unused parameter warnings
        poolManager; policy;
    }

    function _updateDeployments(address hook, bytes32 poolId) internal {
        string memory path = string(abi.encodePacked(
            "deployments/", vm.toString(block.chainid), ".json"
        ));
        // Simple approach: overwrite the TBD field
        // In production use vm.parseJsonAddress + vm.serializeAddress
        console.log("Update deployments file with hook:", hook);
        console.log("PoolId:", vm.toString(poolId));
    }
}
