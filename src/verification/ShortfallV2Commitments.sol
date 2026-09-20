// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice Canonical word-level commitments for the assurance-only Shortfall V2 surface.
/// @dev All address-like inputs are supplied as left-padded bytes32 EVM words.
library ShortfallV2Commitments {
    bytes32 internal constant PREPARED_OPERATION_DOMAIN = keccak256("prf.prepared-operation.v2");
    bytes32 internal constant ECONOMIC_STATE_DOMAIN = keccak256("prf.economic-reserve-state.v2");
    bytes32 internal constant OBSERVATION_DOMAIN = keccak256("prf.authoritative-reserve-observation.v2");

    struct PreparedOperation {
        bytes32 operationId; bytes32 initiator; uint64 chainId; bytes32 reserve; bytes32 token; bytes32 allocator;
        bytes32 configurationRoot; uint64 configurationEpoch; bytes32 sourceVerifierId; bytes32 executionVerifierId;
        bytes32 sourceProgramVKey; bytes32 sourceProgramElfSha256; bytes32 sourceStatementSchema;
        bytes32 sourcePublicValuesSchema; bytes32 executionStatementSchema; bytes32 executionPublicValuesSchema;
        bytes32 policyRoot; bytes32 residualRecipient;
    }

    struct EconomicReserveState {
        bytes32 preparedOperationRoot; bytes32 reserve; bytes32 token; uint128 grossBalance;
        uint128 reservedBefore; uint128 protectedCapital; uint128 availableAmount; uint64 availabilityRevision;
    }

    function preparedOperationRoot(PreparedOperation memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            PREPARED_OPERATION_DOMAIN, p.operationId, p.initiator, p.chainId, p.reserve, p.token, p.allocator,
            p.configurationRoot, p.configurationEpoch, p.sourceVerifierId, p.executionVerifierId, p.sourceProgramVKey,
            p.sourceProgramElfSha256, p.sourceStatementSchema, p.sourcePublicValuesSchema,
            p.executionStatementSchema, p.executionPublicValuesSchema, p.policyRoot, p.residualRecipient));
    }

    function reserveStateCommitment(EconomicReserveState memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            ECONOMIC_STATE_DOMAIN, s.preparedOperationRoot, s.reserve, s.token, s.grossBalance, s.reservedBefore,
            s.protectedCapital, s.availableAmount, s.availabilityRevision));
    }

    function authoritativeObservationRoot(bytes32 commitment, uint64 snapshotId, uint256 createdAtBlock)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(OBSERVATION_DOMAIN, commitment, snapshotId, createdAtBlock));
    }
}
