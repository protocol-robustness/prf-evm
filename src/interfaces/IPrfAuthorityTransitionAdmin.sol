// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IPrfChainInstanceGenesis} from "./IPrfChainInstanceGenesis.sol";
import {IPrfAuthorityTransitionValidator} from "./IPrfAuthorityTransitionValidator.sol";

/// @notice Atomic update path for the canonical PRF local authority-state.v1.
interface IPrfAuthorityTransitionAdmin {
    struct AuthorityMutation {
        uint8 kind; // 0 = authorise, 1 = revoke, 2 = assign proof mode
        bytes32 decisionRoot;
        uint8 targetMode;
        bytes32 targetRoot;
        bytes32 parentConfigurationRoot;
        bytes32 newConfigurationRoot;
        bytes32 parentVerifierRegistryRoot;
        bytes32 newVerifierRegistryRoot;
        uint64 epoch;
        uint8 proofMode;
    }

    function enableAuthorityTransitions(
        IPrfChainInstanceGenesis genesis,
        bytes32 localAuthorityPolicyRoot,
        IPrfAuthorityTransitionValidator validator
    ) external;

    function applyAuthorityStateTransition(
        bytes32 expectedPreviousRoot,
        bytes32 successorRoot,
        uint64 previousRevision,
        uint64 successorRevision,
        bytes32 decisionPreimagesRoot,
        AuthorityMutation[] calldata mutations,
        bytes calldata attestation
    ) external returns (bytes32 executionCommitment);
}
