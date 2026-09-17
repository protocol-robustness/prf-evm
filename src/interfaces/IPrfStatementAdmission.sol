// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IPrfStatementAdmission is IERC165 {
    /// @notice Immutable admission-time record. The statement root is proof-bound;
    ///         the remaining fields describe the configuration under which it was admitted.
    struct AdmissionReceipt {
        bool exists;
        bytes32 protocolGenesisRoot;
        bytes32 chainInstanceGenesisRoot;
        bytes32 configurationRoot;
        uint64 configurationEpoch;
        bytes32 verifierRegistryRoot;
        bytes32 verifierId;
        address verifierAdapter;
        bytes32 programVKey;
        bytes32 programElfSha256;
        bytes32 statementSchemaVersionHash;
        bytes32 publicValuesSchema;
        bytes32 statementRoot;
        bytes32 publicValuesDigest;
    }

    function protocolGenesisRoot() external view returns (bytes32);
    function chainInstanceGenesisRoot() external view returns (bytes32);
    function expectedConfigurationRoot() external view returns (bytes32);
    function expectedConfigurationEpoch() external view returns (uint64);
    function admittedCount() external view returns (uint256);
    function admissionReceipt(bytes32 receiptId) external view returns (AdmissionReceipt memory);

    function admitStatement(
        bytes32 verifierId,
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) external returns (bytes32 receiptId);
}
