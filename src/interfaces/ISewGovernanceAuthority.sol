// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title ISewGovernanceAuthority
/// @notice Read-only compatibility surface from SEW governance into PRF execution.
/// @dev targetMode: 0 = one chain-instance root, 1 = Merkle root of permitted chain-instance roots.
///
///     The DecisionAuthorization struct now also binds the verifier-registry roots
///     so that a governance authorisation cannot decouple configuration root C
///     from verifier-registry root R during a configuration transition.
interface ISewGovernanceAuthority is IERC165, IERC1271 {
    struct DecisionAuthorization {
        uint8 targetMode;
        bytes32 targetRoot;
        bytes32 parentConfigurationRoot;
        bytes32 newConfigurationRoot;
        bytes32 parentVerifierRegistryRoot;
        bytes32 newVerifierRegistryRoot;
        uint64 epoch;
        bool exists;
        bool revoked;
    }

    function protocolGenesisRoot() external view returns (bytes32);
    function governor() external view returns (address);
    function authorityStateRoot() external view returns (bytes32);

    function getDecisionAuthorization(bytes32 decisionRoot)
        external
        view
        returns (DecisionAuthorization memory);

    function isAuthorisedDecision(
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    ) external view returns (bool);
}

/// @title ISewGovernanceAuthorityAdmin
/// @notice Mutation surface callable only by the SEW Governor contract.
/// @dev The Governor itself should expose these calls under OpenZeppelin onlyGovernance.
interface ISewGovernanceAuthorityAdmin is ISewGovernanceAuthority {
    function authoriseDecision(
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    ) external;

    function revokeDecision(bytes32 decisionRoot) external;

    function updateAuthorityStateRoot(bytes32 newAuthorityStateRoot) external;
}
