// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISP1Verifier} from "./ISP1Verifier.sol";
import {IPrfStatementVerifierAdapter} from "./interfaces/IPrfStatementVerifierAdapter.sol";

/// @notice SP1 adapter for the frozen realized-allocation execution projection.
contract PrfRealizedExecutionVerifierAdapter is IPrfStatementVerifierAdapter {
    bytes32 public constant PUBLIC_VALUES_DOMAIN = keccak256("realized-allocation-execution-public-values.v1");
    bytes32 public immutable override statementSchemaVersion;
    bytes32 public immutable override publicValuesSchema;
    ISP1Verifier public immutable sp1Verifier;
    bytes32 public immutable override programVKey;
    bytes32 public immutable override programElfSha256;

    struct ExecutionPublicValues {
        bytes32 domain;
        bytes32 statementRoot;
        bytes32 operationBinding;
        bytes32 claimRoot;
        address token;
        address allocator;
        uint256 chainId;
        bytes32 operationId;
        uint256 availableAmount;
        uint256 allocationCount;
        uint256 totalAllocated;
        uint256 residualAmount;
    }

    error InvalidPublicValuesLength(uint256 actualLength);
    error PublicValuesDomainMismatch(bytes32 actual);
    error StatementRootMismatch(bytes32 expected, bytes32 actual);

    constructor(ISP1Verifier verifier_, bytes32 vkey_, bytes32 elfSha256_) {
        require(address(verifier_) != address(0) && vkey_ != bytes32(0) && elfSha256_ != bytes32(0), "PREA: zero value");
        sp1Verifier = verifier_;
        programVKey = vkey_;
        programElfSha256 = elfSha256_;
        statementSchemaVersion = keccak256("realized-allocation-statement.v1");
        publicValuesSchema = PUBLIC_VALUES_DOMAIN;
    }

    function verifyStatementProof(bytes32 expectedStatementRoot, bytes calldata proof, bytes calldata publicValues)
        external view override returns (bytes32)
    {
        sp1Verifier.verifyProof(programVKey, publicValues, proof);
        ExecutionPublicValues memory values = decodePublicValues(publicValues);
        if (values.statementRoot != expectedStatementRoot) revert StatementRootMismatch(expectedStatementRoot, values.statementRoot);
        return values.statementRoot;
    }

    function extractStatementRoot(bytes calldata publicValues) external pure returns (bytes32) {
        return decodePublicValues(publicValues).statementRoot;
    }

    function decodePublicValues(bytes calldata publicValues) public pure returns (ExecutionPublicValues memory values) {
        if (publicValues.length != 384) revert InvalidPublicValuesLength(publicValues.length);
        values = abi.decode(publicValues, (ExecutionPublicValues));
        if (values.domain != PUBLIC_VALUES_DOMAIN) revert PublicValuesDomainMismatch(values.domain);
    }
}
