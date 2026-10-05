// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice EVM-local prepared-operation commitment for the source-bound
/// entitlement V1 successor profile.
/// @dev This is intentionally separate from ShortfallV2Commitments: the frozen
/// `prf.prepared-operation.v2` identity does not include beneficiary profile.
library SourceBoundEntitlementV1Commitments {
    bytes32 internal constant PREPARED_OPERATION_DOMAIN = keccak256("prf.prepared-operation.v2");
    bytes32 internal constant SMART_ACCOUNT_PROFILE = keccak256("smart-account-v1");
    bytes32 internal constant IMMUTABLE_ADDRESS_PROFILE = keccak256("immutable-address-v1");

    enum BeneficiaryProfile {
        SmartAccountV1,
        ImmutableAddressV1
    }

    struct PreparedOperation {
        bytes32 operationId;
        address initiator;
        uint128 chainId;
        address reserve;
        address token;
        address allocator;
        bytes32 configurationRoot;
        uint128 configurationEpoch;
        bytes32 sourceVerifierId;
        bytes32 executionVerifierId;
        bytes32 sourceProgramVKey;
        bytes32 sourceProgramElfSha256;
        bytes32 sourceStatementSchema;
        bytes32 sourcePublicValuesSchema;
        bytes32 executionStatementSchema;
        bytes32 executionPublicValuesSchema;
        bytes32 policyRoot;
        BeneficiaryProfile beneficiaryProfile;
        address residualRecipient;
    }

    function beneficiaryProfileWord(BeneficiaryProfile profile) internal pure returns (bytes32) {
        if (profile == BeneficiaryProfile.SmartAccountV1) return SMART_ACCOUNT_PROFILE;
        if (profile == BeneficiaryProfile.ImmutableAddressV1) return IMMUTABLE_ADDRESS_PROFILE;
        revert("SBE1: invalid profile");
    }

    function preparedOperationRoot(PreparedOperation memory p) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PREPARED_OPERATION_DOMAIN,
                p.operationId,
                p.initiator,
                uint256(p.chainId),
                p.reserve,
                p.token,
                p.allocator,
                p.configurationRoot,
                uint256(p.configurationEpoch),
                p.sourceVerifierId,
                p.executionVerifierId,
                p.sourceProgramVKey,
                p.sourceProgramElfSha256,
                p.sourceStatementSchema,
                p.sourcePublicValuesSchema,
                p.executionStatementSchema,
                p.executionPublicValuesSchema,
                p.policyRoot,
                beneficiaryProfileWord(p.beneficiaryProfile),
                p.residualRecipient
            )
        );
    }
}
