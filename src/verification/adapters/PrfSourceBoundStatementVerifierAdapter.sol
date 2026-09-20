// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISP1Verifier} from "../interfaces/ISP1Verifier.sol";
import {IPrfStatementVerifierAdapter} from "../../interfaces/IPrfStatementVerifierAdapter.sol";

contract PrfSourceBoundStatementVerifierAdapter is IPrfStatementVerifierAdapter {
    bytes32 public constant PUBLIC_VALUES_DOMAIN =
        keccak256("prf/onchain-shortfall-allocation-binding-public-values.v1");
    bytes32 public immutable override statementSchemaVersion;
    bytes32 public immutable override publicValuesSchema;
    ISP1Verifier public immutable sp1Verifier;
    bytes32 public immutable override programVKey;
    bytes32 public immutable override programElfSha256;

    struct SourceBoundPublicValues {
        bytes32 schema;
        bytes32 allocationBindingRoot;
        bytes32 realizedStatementRoot;
        bytes32 operationId;
        bytes32 reserveSnapshotHash;
    }

    error InvalidPublicValuesLength(uint256 actualLength);
    error PublicValuesSchemaMismatch(bytes32 actual);
    error StatementRootMismatch(bytes32 expected, bytes32 actual);

    constructor(ISP1Verifier verifier_, bytes32 vkey_, bytes32 elfSha256_) {
        require(address(verifier_) != address(0) && vkey_ != bytes32(0) && elfSha256_ != bytes32(0), "PSBA: zero value");
        sp1Verifier = verifier_;
        programVKey = vkey_;
        programElfSha256 = elfSha256_;
        statementSchemaVersion = keccak256("prf/onchain-shortfall-allocation-binding.v1");
        publicValuesSchema = PUBLIC_VALUES_DOMAIN;
    }

    function verifyStatementProof(bytes32 expectedStatementRoot, bytes calldata proof, bytes calldata publicValues)
        external view override returns (bytes32)
    {
        sp1Verifier.verifyProof(programVKey, publicValues, proof);
        SourceBoundPublicValues memory values = decodePublicValues(publicValues);
        if (values.allocationBindingRoot != expectedStatementRoot) {
            revert StatementRootMismatch(expectedStatementRoot, values.allocationBindingRoot);
        }
        return values.allocationBindingRoot;
    }

    function decodePublicValues(bytes calldata publicValues)
        public pure returns (SourceBoundPublicValues memory values)
    {
        if (publicValues.length != 160) revert InvalidPublicValuesLength(publicValues.length);
        values = abi.decode(publicValues, (SourceBoundPublicValues));
        if (values.schema != PUBLIC_VALUES_DOMAIN) revert PublicValuesSchemaMismatch(values.schema);
        if (values.allocationBindingRoot == bytes32(0) || values.realizedStatementRoot == bytes32(0)
            || values.operationId == bytes32(0) || values.reserveSnapshotHash == bytes32(0)) revert PublicValuesSchemaMismatch(values.schema);
    }
}
