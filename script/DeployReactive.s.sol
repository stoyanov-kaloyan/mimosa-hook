// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MimosaReactive} from "../src/MimosaReactive.sol";

/// @title DeployReactive
/// @notice Deploys MimosaReactive on the Reactive Network.
///         Reads the origin-chain deployment manifest and deploys the contract.
///         Subscription activation can be done separately for easier diagnosis.
///
/// @dev Must be run AFTER DeployOrigin (needs the hook + callback addresses).
///
///   Usage (option A — env vars):
///     ORIGIN_CHAIN_ID=11155111 POOL_MANAGER=0x... \
///     HOOK=0x... CALLBACK=0x... REACTIVE_DEPOSIT=0.1 \
///       forge script script/DeployReactive.s.sol \
///       --rpc-url $REACTIVE_RPC --broadcast
///
///   Usage (option B — read from deployment manifest):
///     ORIGIN_CHAIN_ID=11155111 REACTIVE_DEPOSIT=0.1 \
///       forge script script/DeployReactive.s.sol \
///       --rpc-url $REACTIVE_RPC --broadcast
contract DeployReactive is Script {
    function run() external {
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");

        address poolManagerAddr;
        address hookAddr;
        address callbackAddr;

        poolManagerAddr = _tryEnvOrManifest(originChainId, "POOL_MANAGER", "poolManager");
        hookAddr = _tryEnvOrManifest(originChainId, "HOOK", "hook");
        callbackAddr = _tryEnvOrManifest(originChainId, "CALLBACK", "callback");

        require(poolManagerAddr != address(0), "DeployReactive: poolManager not set");
        require(hookAddr != address(0), "DeployReactive: hook not set");
        require(callbackAddr != address(0), "DeployReactive: callback not set");

        uint256 deposit = vm.envOr("REACTIVE_DEPOSIT_WEI", uint256(0));
        bool activateAll = vm.envOr("ACTIVATE_SUBSCRIPTIONS", false);

        console2.log("Origin chain ID:", originChainId);
        console2.log("PoolManager:", poolManagerAddr);
        console2.log("MimosaHook:", hookAddr);
        console2.log("MimosaCallback:", callbackAddr);
        console2.log("Initial deposit:", deposit);
        console2.log("Activate subscriptions:", activateAll);

        vm.startBroadcast();

        MimosaReactive reactive =
            new MimosaReactive{value: deposit}(originChainId, poolManagerAddr, hookAddr, callbackAddr);
        if (activateAll) reactive.activateSubscriptions();

        vm.stopBroadcast();

        console2.log("MimosaReactive deployed to:", address(reactive));

        string memory json = "reactive";
        vm.serializeUint(json, "reactiveChainId", block.chainid);
        vm.serializeUint(json, "originChainId", originChainId);
        vm.serializeAddress(json, "poolManager", poolManagerAddr);
        vm.serializeAddress(json, "hook", hookAddr);
        vm.serializeAddress(json, "callback", callbackAddr);
        vm.serializeAddress(json, "reactive", address(reactive));
        string memory output = vm.serializeUint(json, "deployedAt", block.timestamp);

        string memory path = string.concat("deployments/reactive-", vm.toString(block.chainid), ".json");
        vm.writeJson(output, path);
        console2.log("Manifest written to:", path);
    }

    /// @dev Try to read an address from an env var; if not set, read from the
    ///      JSON manifest file at `deployments/<chainId>.json`.
    function _tryEnvOrManifest(uint256 chainId, string memory envKey, string memory jsonKey)
        internal
        view
        returns (address)
    {
        // Try environment variable first
        address val = vm.envOr(envKey, address(0));
        if (val != address(0)) return val;

        // Fall back to JSON manifest
        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        try vm.readFile(path) returns (string memory contents) {
            return vm.parseJsonAddress(contents, string.concat(".", jsonKey));
        } catch {
            return address(0);
        }
    }
}
