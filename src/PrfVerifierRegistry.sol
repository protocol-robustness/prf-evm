// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrfVerifierRegistry} from "./interfaces/IPrfVerifierRegistry.sol";

/// @title PrfVerifierRegistry
/// @notice Versioned, immutable verifier-registry snapshots keyed by registry root.
///         Mirrors the canonical `:verifier-registry/root` field of
///         chain-configuration.v1: each configuration commits a verifier-registry
///         root R, and the Solidity registry maintains immutable snapshots under R.
///
///         The registry root R is NOT an opaque namespace key — it is the exact
///         canonical SHA-256 domain-separated commitment to the snapshot's
///         verifier entries (see canonicalRoot below). Sealing verifies that
///         the committed root matches the canonical root computed from actual
///         entries, using the same domain tag "PRF_VERIFIER_REGISTRY_V1" and
///         SHA-256 semantics as Clojure's canonical encoding.
///
///         Authority model:
///         - onlyGovernor: the exact configured governor contract.
///         - Deployer, EOA, authority adapter, and timelock-by-itself have NO
///           ongoing registry-admin capability.
contract PrfVerifierRegistry is ERC165, IPrfVerifierRegistry {
    bytes32 private constant REGISTRY_DOMAIN =
        keccak256("PRF_VERIFIER_REGISTRY_V1");

    address public immutable governor;

    mapping(bytes32 registryRoot => uint256) public verifierCount;
    mapping(bytes32 registryRoot => mapping(uint256 => IPrfVerifierRegistry.VerifierEntry)) private _verifiers;
    mapping(bytes32 registryRoot => mapping(bytes32 verifierId => uint256)) private _verifierIndex;
    mapping(bytes32 registryRoot => bool) private _sealed;
    mapping(bytes32 registryRoot => bytes32[]) private _verifierIds;

    event RegistrySealed(bytes32 indexed registryRoot, uint256 verifierCount);
    event VerifierRegistered(
        bytes32 indexed registryRoot,
        bytes32 indexed verifierId,
        address indexed adapter,
        bytes32 programVKey,
        bytes32 programElfSha256,
        string programId
    );
    event VerifierActivated(bytes32 indexed registryRoot, bytes32 indexed verifierId);
    event VerifierDeactivated(bytes32 indexed registryRoot, bytes32 indexed verifierId);

    constructor(address governor_) {
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor(msg.sender, governor);
        _;
    }

    modifier onlyUnsealed(bytes32 registryRoot) {
        if (_sealed[registryRoot]) revert AlreadySealed(registryRoot);
        _;
    }

    modifier onlySealed(bytes32 registryRoot) {
        if (!_sealed[registryRoot]) revert NotSealed(registryRoot);
        _;
    }

    function registerVerifier(
        bytes32 registryRoot,
        bytes32 verifierId,
        address adapter,
        bytes32 programVKey,
        bytes32 programElfSha256,
        string calldata programId,
        bytes32 statementSchemaVersionHash,
        bytes32 publicValuesSchema
    ) external override onlyGovernor onlyUnsealed(registryRoot) {
        if (registryRoot == bytes32(0)) revert ZeroRoot();
        if (adapter == address(0)) revert ZeroAddress();
        if (programVKey == bytes32(0)) revert ZeroRoot();
        if (programElfSha256 == bytes32(0)) revert ZeroRoot();
        if (verifierId == bytes32(0)) revert ZeroRoot();
        if (statementSchemaVersionHash == bytes32(0)) revert ZeroRoot();
        if (publicValuesSchema == bytes32(0)) revert ZeroRoot();
        if (_verifierIndex[registryRoot][verifierId] != 0)
            revert VerifierAlreadyRegistered(registryRoot, verifierId);

        uint256 index = verifierCount[registryRoot]++;
        _verifiers[registryRoot][index] = IPrfVerifierRegistry.VerifierEntry({
            adapter: adapter,
            programVKey: programVKey,
            programElfSha256: programElfSha256,
            programId: programId,
            statementSchemaVersionHash: statementSchemaVersionHash,
            publicValuesSchema: publicValuesSchema,
            active: true
        });
        _verifierIndex[registryRoot][verifierId] = index + 1;
        _verifierIds[registryRoot].push(verifierId);

        emit VerifierRegistered(
            registryRoot,
            verifierId,
            adapter,
            programVKey,
            programElfSha256,
            programId
        );
    }

    function activateVerifier(bytes32 registryRoot, bytes32 verifierId)
        external
        override
        onlyGovernor
        onlyUnsealed(registryRoot)
    {
        uint256 idx = _verifierIndex[registryRoot][verifierId];
        if (idx == 0) revert VerifierNotFound(registryRoot, verifierId);
        _verifiers[registryRoot][idx - 1].active = true;
        emit VerifierActivated(registryRoot, verifierId);
    }

    function deactivateVerifier(bytes32 registryRoot, bytes32 verifierId)
        external
        override
        onlyGovernor
        onlyUnsealed(registryRoot)
    {
        uint256 idx = _verifierIndex[registryRoot][verifierId];
        if (idx == 0) revert VerifierNotFound(registryRoot, verifierId);
        _verifiers[registryRoot][idx - 1].active = false;
        emit VerifierDeactivated(registryRoot, verifierId);
    }

    function sealRegistry(bytes32 registryRoot) external override onlyGovernor {
        if (registryRoot == bytes32(0)) revert ZeroRoot();
        if (_sealed[registryRoot]) revert AlreadySealed(registryRoot);

        bytes32 computed = canonicalRoot(registryRoot);
        if (computed != registryRoot) revert RegistryRootMismatch(registryRoot, computed);

        _sealed[registryRoot] = true;
        emit RegistrySealed(registryRoot, verifierCount[registryRoot]);
    }

    function isSealed(bytes32 registryRoot) external view override returns (bool) {
        return _sealed[registryRoot];
    }

    function verifiers(bytes32 registryRoot, uint256 index)
        external
        view
        override
        returns (IPrfVerifierRegistry.VerifierEntry memory)
    {
        IPrfVerifierRegistry.VerifierEntry storage v = _verifiers[registryRoot][index];
        return IPrfVerifierRegistry.VerifierEntry({
            adapter: v.adapter,
            programVKey: v.programVKey,
            programElfSha256: v.programElfSha256,
            programId: v.programId,
            statementSchemaVersionHash: v.statementSchemaVersionHash,
            publicValuesSchema: v.publicValuesSchema,
            active: v.active
        });
    }

    function getVerifier(bytes32 registryRoot, bytes32 verifierId)
        external
        view
        override
        returns (IPrfVerifierRegistry.VerifierEntry memory)
    {
        uint256 idx = _verifierIndex[registryRoot][verifierId];
        if (idx == 0) revert VerifierNotFound(registryRoot, verifierId);
        IPrfVerifierRegistry.VerifierEntry storage v = _verifiers[registryRoot][idx - 1];
        return IPrfVerifierRegistry.VerifierEntry({
            adapter: v.adapter,
            programVKey: v.programVKey,
            programElfSha256: v.programElfSha256,
            programId: v.programId,
            statementSchemaVersionHash: v.statementSchemaVersionHash,
            publicValuesSchema: v.publicValuesSchema,
            active: v.active
        });
    }

    /// @notice Compute the canonical SHA-256 domain-separated commitment to the
    ///         verifier entries under a given registry root.
    ///
    /// Encoding (must match Clojure canonical-verifier-registry.root):
    ///   entry_hash_i = SHA256(
    ///     verifierId      (32 bytes)
    ///     || adapter      (32 bytes, address as uint256 big-endian)
    ///     || programVKey  (32 bytes)
    ///     || elfSha256    (32 bytes)
    ///     || programIdHash (32 bytes, SHA256 of UTF-8 programId)
    ///     || schemaHash   (32 bytes)
    ///     || active       (32 bytes, 0x00..01 or 0x00..00)
    ///   )
    ///
    ///   registryRoot = SHA256(
    ///     "PRF_VERIFIER_REGISTRY_V1" (25 bytes UTF-8)
    ///     || uint256(entry_count) (32 bytes, big-endian)
    ///     || sorted_by_verifierId(entry_hash_0, ..., entry_hash_{n-1})
    ///   )
    /// @notice Compute the canonical registry root from a list of verifier entries.
    ///         This is a pure function usable before entries are stored on-chain,
    ///         so callers can compute the root and use it as the registryRoot
    ///         parameter when calling registerVerifier.
    ///
    ///         Parameters are parallel arrays of equal length. Entries are
    ///         automatically sorted by verifierId before hashing.
    ///
    ///         Encoding (must match Clojure canonical-verifier-registry.root):
    ///   entry_hash_i = SHA256(
    ///     verifierId          (32 bytes)
    ///     || adapter          (20 bytes, address)
    ///     || programVKey      (32 bytes)
    ///     || elfSha256        (32 bytes)
    ///     || programIdHash     (32 bytes, SHA256 of UTF-8 programId)
    ///     || schemaHash        (32 bytes, statement schema version hash)
    ///     || publicValuesSchema (32 bytes, public-values schema hash)
    ///     || active            (32 bytes, 0x00..01 or 0x00..00)
    ///   )
    ///
    ///   registryRoot = SHA256(
    ///     "PRF_VERIFIER_REGISTRY_V1" (25 bytes UTF-8)
    ///     || uint256(entry_count) (32 bytes, big-endian)
    ///     || sorted_by_verifierId(entry_hash_0, ..., entry_hash_{n-1})
    ///   )
     function computeCanonicalRoot(
         bytes32[] memory verifierIds,
         address[] memory adapters,
         bytes32[] memory programVKeys,
         bytes32[] memory programElfSha256s,
         string[] memory programIds,
         bytes32[] memory statementSchemaVersionHashes,
         bytes32[] memory publicValuesSchemas,
         bool[] memory actives
     ) external pure returns (bytes32) {
         uint256 n = verifierIds.length;
         if (n == 0) {
             return sha256(abi.encodePacked("PRF_VERIFIER_REGISTRY_V1", uint256(0)));
         }

         bytes32[] memory ids = new bytes32[](n);
         bytes32[] memory hashes = new bytes32[](n);

         for (uint256 i = 0; i < n; i++) {
             ids[i] = verifierIds[i];
             hashes[i] = sha256(abi.encodePacked(
                 verifierIds[i],
                 uint256(uint160(adapters[i])),
                 programVKeys[i],
                 programElfSha256s[i],
                 sha256(bytes(programIds[i])),
                 statementSchemaVersionHashes[i],
                 publicValuesSchemas[i],
                 actives[i] ? uint256(1) : uint256(0)
             ));
         }

         _sortPairs(ids, hashes);

         bytes memory payload = abi.encodePacked(
             "PRF_VERIFIER_REGISTRY_V1",
             uint256(n)
         );
         for (uint256 i = 0; i < n; i++) {
             payload = abi.encodePacked(payload, hashes[i]);
         }

         return sha256(payload);
     }

    function canonicalRoot(bytes32 registryRoot) public view override returns (bytes32) {
        uint256 n = verifierCount[registryRoot];
        if (n == 0) {
            return sha256(abi.encodePacked("PRF_VERIFIER_REGISTRY_V1", uint256(0)));
        }

        bytes32[] memory ids = new bytes32[](n);
        bytes32[] memory hashes = new bytes32[](n);

        for (uint256 i = 0; i < n; i++) {
            bytes32 vid = _verifierIds[registryRoot][i];
            ids[i] = vid;

            IPrfVerifierRegistry.VerifierEntry storage v = _verifiers[registryRoot][i];
            hashes[i] = sha256(abi.encodePacked(
                vid,
                uint256(uint160(v.adapter)),
                v.programVKey,
                v.programElfSha256,
                sha256(bytes(v.programId)),
                v.statementSchemaVersionHash,
                v.publicValuesSchema,
                v.active ? uint256(1) : uint256(0)
            ));
        }

        _sortPairs(ids, hashes);

        bytes memory payload = abi.encodePacked(
            "PRF_VERIFIER_REGISTRY_V1",
            uint256(n)
        );
        for (uint256 i = 0; i < n; i++) {
            payload = abi.encodePacked(payload, hashes[i]);
        }

        return sha256(payload);
    }

    /// @notice Check whether the committed registry root matches the canonical
    ///         root computed from actual entries.
    function canonicalRootMatches(bytes32 registryRoot) external view override returns (bool) {
        return canonicalRoot(registryRoot) == registryRoot;
    }

    function _sortPairs(bytes32[] memory ids, bytes32[] memory hashes)
        private
        pure
    {
        uint256 n = ids.length;
        for (uint256 i = 1; i < n; i++) {
            for (uint256 j = i; j > 0; j--) {
                if (ids[j] < ids[j - 1]) {
                    (ids[j], ids[j - 1]) = (ids[j - 1], ids[j]);
                    (hashes[j], hashes[j - 1]) = (hashes[j - 1], hashes[j]);
                } else {
                    break;
                }
            }
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IPrfVerifierRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
