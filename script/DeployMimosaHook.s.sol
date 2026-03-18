// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {MimosaHook} from "../src/MimosaHook.sol";
import {MimosaCallback} from "../src/MimosaCallback.sol";

/// @title DeployOrigin
/// @notice Deploys MimosaHook + MimosaCallback on the origin chain (e.g. Ethereum / Sepolia).
///         Mines a CREATE2 salt so the hook address has the AFTER_INITIALIZE permission flag.
///         Writes a JSON deployment manifest to `deployments/<chainId>.json` for use by
///         the Reactive deploy script and the web front-end.
///
/// @dev Usage:
///   POOL_MANAGER=0x... CALLBACK_PROXY=0x... \
///     forge script script/DeployMimosaHook.s.sol \
///     --rpc-url $ORIGIN_RPC --broadcast --verify
contract DeployOrigin is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        // ── Read configuration from environment ──────────────────────
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address callbackProxy = vm.envAddress("CALLBACK_PROXY");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        // ── Mine hook address with AFTER_INITIALIZE flag ─────────────
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(MimosaHook).creationCode, constructorArgs);

        console2.log("Mined hook address:", hookAddress);
        console2.log("Salt:", vm.toString(salt));

        // ── Deploy ───────────────────────────────────────────────────
        vm.startBroadcast();

        MimosaHook hook = new MimosaHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "DeployOrigin: address mismatch");

        MimosaCallback callback = new MimosaCallback(address(hook), callbackProxy);

        vm.stopBroadcast();

        console2.log("MimosaHook deployed to:", address(hook));
        console2.log("MimosaCallback deployed to:", address(callback));

        // ── Write deployment manifest ────────────────────────────────
        string memory json = "origin";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "poolManager", poolManagerAddr);
        vm.serializeAddress(json, "callbackProxy", callbackProxy);
        vm.serializeAddress(json, "hook", address(hook));
        vm.serializeAddress(json, "callback", address(callback));
        vm.serializeBytes32(json, "hookSalt", salt);
        string memory output = vm.serializeUint(json, "deployedAt", block.timestamp);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(output, path);
        console2.log("Manifest written to:", path);
    }
}
