// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
import {IPrfStatementVerifierAdapter} from "../../interfaces/IPrfStatementVerifierAdapter.sol";

/// @notice Verifies and decodes the source-bound entitlement V1 public values.
/// @dev This is an additive profile. The historical 192-byte source-bound V2
///      adapter and its verifier identity remain unchanged.
contract PrfSourceBoundEntitlementVerifierAdapterV1 is IPrfStatementVerifierAdapter {
    bytes32 public constant PUBLIC_VALUES_SCHEMA = keccak256("prf/source-bound-entitlement-public-values.v1");
    bytes32 public constant EXPECTED_DESCRIPTOR_ROOT =
        0x0e8b6d0eb8a46279fee6697366b2bdfa0b4aa514dacf17e9e264744d90d91c1f;
    uint256 public constant PUBLIC_VALUES_LENGTH = 9 * 32;

    bytes32 public immutable override statementSchemaVersion;
    bytes32 public immutable override publicValuesSchema;
    ISP1Verifier public immutable sp1Verifier;
    bytes32 public immutable override programVKey;
    bytes32 public immutable override programElfSha256;

    struct SourceBoundEntitlementPublicValuesV1 {
        bytes32 schema;
        bytes32 preparedOperationRoot;
        bytes32 reserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 entitlementRepresentationDescriptorRoot;
        bytes32 evmEntitlementTableRoot;
        uint256 entitlementCount;
        uint256 entitlementTotal;
        bytes32 allocationClaimRoot;
    }

    error InvalidPublicValuesLength(uint256 actualLength);
    error PublicValuesSchemaMismatch(bytes32 actual);
    error DescriptorRootMismatch(bytes32 expected, bytes32 actual);
    error StatementRootMismatch(bytes32 expected, bytes32 actual);

    constructor(ISP1Verifier verifier_, bytes32 vkey_, bytes32 elfSha256_) {
        require(address(verifier_) != address(0) && vkey_ != bytes32(0) && elfSha256_ != bytes32(0), "PSE1: zero value");
        sp1Verifier = verifier_;
        programVKey = vkey_;
        programElfSha256 = elfSha256_;
        statementSchemaVersion = keccak256("prf/onchain-shortfall-allocation-binding.v1");
        publicValuesSchema = PUBLIC_VALUES_SCHEMA;
    }

    function verifyStatementProof(bytes32 expectedStatementRoot, bytes calldata proof, bytes calldata publicValues)
        external
        view
        override
        returns (bytes32)
    {
        SourceBoundEntitlementPublicValuesV1 memory values = decodePublicValues(publicValues);
        sp1Verifier.verifyProof(programVKey, publicValues, proof);
        if (values.allocationBindingRoot != expectedStatementRoot) {
            revert StatementRootMismatch(expectedStatementRoot, values.allocationBindingRoot);
        }
        return values.allocationBindingRoot;
    }

    /// @notice Decode exactly nine static ABI words (288 bytes) for this profile.
    function decodePublicValues(bytes calldata publicValues)
        public
        pure
        returns (SourceBoundEntitlementPublicValuesV1 memory values)
    {
        if (publicValues.length != PUBLIC_VALUES_LENGTH) revert InvalidPublicValuesLength(publicValues.length);
        values = abi.decode(publicValues, (SourceBoundEntitlementPublicValuesV1));
        if (values.schema != PUBLIC_VALUES_SCHEMA) revert PublicValuesSchemaMismatch(values.schema);
        if (values.entitlementRepresentationDescriptorRoot != EXPECTED_DESCRIPTOR_ROOT) {
            revert DescriptorRootMismatch(EXPECTED_DESCRIPTOR_ROOT, values.entitlementRepresentationDescriptorRoot);
        }
    }
}
