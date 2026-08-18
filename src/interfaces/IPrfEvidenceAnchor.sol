// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPrfEvidenceAnchor
/// @notice Immutable evidence-root anchoring for one chain instance.
interface IPrfEvidenceAnchor is IERC165 {
    struct EvidenceCommitment {
        bytes32 subjectRoot;
        bytes32 statementRoot;
        bytes32 evidenceRoot;
        bytes32 verificationPolicyRoot;
        bytes32 verifierRoot;
        uint64 sequence;
    }

    function chainInstanceGenesisRoot() external view returns (bytes32);

    function computeAnchorId(EvidenceCommitment calldata commitment)
        external
        view
        returns (bytes32);

    function anchorEvidence(EvidenceCommitment calldata commitment)
        external
        returns (bytes32 anchorId);

    function anchorBlock(bytes32 anchorId) external view returns (uint256);
    function anchorTimestamp(bytes32 anchorId) external view returns (uint256);
}
