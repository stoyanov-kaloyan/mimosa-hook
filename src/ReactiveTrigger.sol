// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal interface exposed by MimosaHook for external triggering.
interface IMimosaHook {
    function executePolicy(uint256 policyId) external;
    function getCurrentPrice(bytes32 poolId) external view returns (uint160 sqrtPriceX96);
}

/// @title ReactiveTrigger
/// @notice Reactive Network contract that bridges off-chain event detection
///         to on-chain policy execution on MimosaHook.
///
/// @dev Architecture:
///   The Reactive Network monitors on-chain state (e.g., pool Swap
///   events that move price).  When it detects that a policy's trigger
///   condition *may* be satisfied, it calls `react()` on this contract.
///
///   This contract does NOT perform the condition check – that is the
///   responsibility of MimosaHook.executePolicy(), which re-validates the
///   price threshold on-chain.  This separation ensures:
///     • Detection  = Reactive Network (off-chain monitoring, fast)
///     • Validation = MimosaHook      (on-chain, trustless)
///
///   If execution fails (condition not actually met, already executed, etc.)
///   the call is silently caught so the reactive subscription continues.
///
/// @custom:reactive-subscription
///   In a production Reactive Network deployment, this contract would
///   register an event subscription like:
///     subscribe(poolManagerAddress, SWAP_EVENT_TOPIC, chainId)
///   The runtime invokes `react()` with the relevant policyId whenever
///   the subscribed event fires and the off-chain condition filter matches.
contract ReactiveTrigger {
    /// @notice The MimosaHook instance this trigger is wired to.
    IMimosaHook public immutable hook;

    /// @notice Address authorised as the Reactive Network callback origin.
    ///         In production this is the Reactive runtime entry-point.
    ///         For testing / demo, it can be any EOA.
    address public immutable reactiveOrigin;

    event ReactionAttempted(uint256 indexed policyId, bool success);
    event ReactionBatchCompleted(uint256 attempted, uint256 succeeded);

    error UnauthorizedOrigin();

    /// @param _hook           Address of the deployed MimosaHook.
    /// @param _reactiveOrigin Authorised caller (Reactive runtime / demo EOA).
    constructor(address _hook, address _reactiveOrigin) {
        hook = IMimosaHook(_hook);
        reactiveOrigin = _reactiveOrigin;
    }

    modifier onlyReactive() {
        if (msg.sender != reactiveOrigin) revert UnauthorizedOrigin();
        _;
    }

    /// @notice Called by the Reactive Network runtime when an event matching
    ///         a policy's trigger is detected.
    /// @param policyId The policy whose condition was detected off-chain.
    function react(uint256 policyId) external onlyReactive {
        bool success = _tryExecute(policyId);
        emit ReactionAttempted(policyId, success);
    }

    /// @notice Batch variant – trigger multiple policies in one tx.
    function reactBatch(uint256[] calldata policyIds) external onlyReactive {
        uint256 succeeded;
        for (uint256 i; i < policyIds.length; ++i) {
            bool success = _tryExecute(policyIds[i]);
            if (success) ++succeeded;
            emit ReactionAttempted(policyIds[i], success);
        }
        emit ReactionBatchCompleted(policyIds.length, succeeded);
    }

    /// @dev Attempt execution; return false on any revert so the reactive
    ///      subscription isn't interrupted.
    function _tryExecute(uint256 policyId) internal returns (bool) {
        try hook.executePolicy(policyId) {
            return true;
        } catch {
            return false;
        }
    }
}
