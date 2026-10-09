// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISewGovernanceAuthorityAdmin} from "./ISewGovernanceAuthority.sol";

/// @notice Additive governance authorization for live entitlement proof-mode transitions.
/// @dev Mode is attached to the same configuration decision roots/epoch; it is not
///      an allocator owner setting and does not alter historical entitlement identity.
interface ISewGovernanceProofModeAuthority is ISewGovernanceAuthorityAdmin {
    function authoriseDecisionProofMode(bytes32 decisionRoot, uint8 proofMode) external;
    function hasDecisionProofMode(bytes32 decisionRoot) external view returns (bool);
    function isAuthorisedDecisionProofMode(
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch,
        uint8 proofMode
    ) external view returns (bool);
}
