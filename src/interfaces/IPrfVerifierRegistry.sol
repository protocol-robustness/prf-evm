// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPrfVerifierRegistry
/// @notice Interface for the verifier registry. The struct and getter for
///         `verifiers` are defined in the implementing contract; this
///         interface declares only the mutation and query functions.
interface IPrfVerifierRegistry is IERC165 {
    function verifierCount() external view returns (uint256);
    function verifiers(uint256 index)
        external
        view
        returns (
            address adapter,
            bytes32 programVKey,
            bytes32 programElfSha256,
            string memory programId,
            bytes32 statementSchemaVersionHash,
            bool active
        );
    function adapterToIndex(address adapter) external view returns (uint256);
    function vkeyToVerifierIndex(bytes32 programVKey) external view returns (uint256);
    function addVerifier(
        address adapter,
        bytes32 programVKey,
        bytes32 programElfSha256,
        string calldata programId,
        bytes32 statementSchemaVersionHash
    ) external;
    function activateVerifier(uint256 index) external;
    function deactivateVerifier(uint256 index) external;
    function removeVerifier(uint256 index) external;
    function registryRoot() external view returns (bytes32);
}
