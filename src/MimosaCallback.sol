// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

/// @notice Minimal interface for MimosaHook policy execution.
interface IMimosaHookCallback {
    function executePolicy(uint256 policyId) external;
}

/// @title MimosaCallback
/// @notice Destination-chain contract that receives Reactive Network callbacks
///         and forwards policy execution to MimosaHook.
///
/// @dev Deployed on the same chain as MimosaHook. The Callback Proxy delivers
///      callback transactions here. Authorization:
///        • msg.sender must be the Callback Proxy (authorizedSenderOnly)
///        • the embedded ReactVM ID must match the deployer (rvmIdOnly)
///
///      Uses try/catch so that failed executions (expired, already executed,
///      condition no longer met) don't revert the callback transaction.
contract MimosaCallback is AbstractCallback {
    IMimosaHookCallback public immutable hook;

    event ExecutionForwarded(uint256 indexed policyId, bool success);

    /// @param _hook          Address of the MimosaHook contract.
    /// @param _callbackProxy Address of the Reactive Network Callback Proxy on this chain.
    constructor(address _hook, address _callbackProxy) AbstractCallback(_callbackProxy) {
        hook = IMimosaHookCallback(_hook);
    }

    /// @notice Called by the Callback Proxy when Reactive Network delivers a callback.
    /// @dev The first argument (_rvmId) is automatically replaced by Reactive
    ///      Network with the deployer's ReactVM ID.
    /// @param _rvmId   ReactVM identifier (injected by Reactive Network).
    /// @param policyId Policy to execute on MimosaHook.
    function executeCallback(address _rvmId, uint256 policyId) external authorizedSenderOnly rvmIdOnly(_rvmId) {
        bool success = _tryExecute(policyId);
        emit ExecutionForwarded(policyId, success);
    }

    /// @dev Attempt execution; return false on any revert so the callback
    ///      doesn't fail (which would waste gas without useful effect).
    function _tryExecute(uint256 policyId) internal returns (bool) {
        try hook.executePolicy(policyId) {
            return true;
        } catch {
            return false;
        }
    }
}
