// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice Minimal immutable identity and verification surface required by
///         generic PRF statement admission.
interface IPrfStatementVerifierAdapter {
    function programVKey() external view returns (bytes32);
    function programElfSha256() external view returns (bytes32);
    function statementSchemaVersion() external view returns (bytes32);
    function publicValuesSchema() external view returns (bytes32);

    function verifyStatementProof(
        bytes32 expectedStatementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) external view returns (bytes32);
}
