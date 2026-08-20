// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPrfVerifierRegistry
/// @notice Versioned, immutable verifier-registry snapshots keyed by canonical
///         registry root. The registry root is the exact SHA-256 domain-separated
///         commitment to the snapshot's verifier entries.
interface IPrfVerifierRegistry is IERC165 {
    struct VerifierEntry {
        address adapter;
        bytes32 programVKey;
        bytes32 programElfSha256;
        string programId;
        bytes32 statementSchemaVersionHash;
        bytes32 publicValuesSchema;
        bool active;
    }

    error ZeroRoot();
    error ZeroAddress();
    error ZeroVerifierCount();
    error NotSealed(bytes32 registryRoot);
    error AlreadySealed(bytes32 registryRoot);
    error VerifierNotFound(bytes32 registryRoot, bytes32 verifierId);
    error VerifierAlreadyRegistered(bytes32 registryRoot, bytes32 verifierId);
    error OnlyGovernor(address caller, address expected);
    error RegistryRootMismatch(bytes32 expected, bytes32 actual);

    function verifierCount(bytes32 registryRoot) external view returns (uint256);
    function verifiers(bytes32 registryRoot, uint256 index)
        external
        view
        returns (
            VerifierEntry memory
        );
    function getVerifier(bytes32 registryRoot, bytes32 verifierId)
        external
        view
        returns (VerifierEntry memory);
    function isSealed(bytes32 registryRoot) external view returns (bool);

    function registerVerifier(
        bytes32 registryRoot,
        bytes32 verifierId,
        address adapter,
        bytes32 programVKey,
        bytes32 programElfSha256,
        string calldata programId,
        bytes32 statementSchemaVersionHash,
        bytes32 publicValuesSchema
    ) external;

    function activateVerifier(bytes32 registryRoot, bytes32 verifierId) external;
    function deactivateVerifier(bytes32 registryRoot, bytes32 verifierId) external;
    function sealRegistry(bytes32 registryRoot) external;

    /// @notice Compute the canonical SHA-256 domain-separated commitment to the
    ///         verifier entries under a given registry root.
    function canonicalRoot(bytes32 registryRoot) external view returns (bytes32);

    /// @notice Compute the canonical registry root from entry data without
    ///         requiring entries to be stored. Used by governance to determine
    ///         the correct registryRoot before registering verifiers.
    function computeCanonicalRoot(
        bytes32[] memory verifierIds,
        address[] memory adapters,
        bytes32[] memory programVKeys,
        bytes32[] memory programElfSha256s,
        string[] memory programIds,
        bytes32[] memory statementSchemaVersionHashes,
        bytes32[] memory publicValuesSchemas,
        bool[] memory actives
    ) external pure returns (bytes32);

    /// @notice Check whether the committed registry root matches the actual
    ///         canonical root computed from entries.
    function canonicalRootMatches(bytes32 registryRoot) external view returns (bool);
}
