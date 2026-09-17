// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IPrfStatementVerifierAdapter} from "./interfaces/IPrfStatementVerifierAdapter.sol";
import {PrfVerifierRegistry} from "./PrfVerifierRegistry.sol";
import {SewConfigurationExecutor} from "./SewConfigurationExecutor.sol";
import {IPrfChainInstanceGenesis} from "./interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfStatementAdmission} from "./interfaces/IPrfStatementAdmission.sol";
import {IPrfVerifierRegistry} from "./interfaces/IPrfVerifierRegistry.sol";

/// @title PrfStatementAdmission
/// @notice Generic admission gateway for registered PRF statement proofs.
///         Binds together:
///         - The chain-instance genesis root (immutable identity).
///         - The current configuration root (from SewConfigurationExecutor).
///         - The current configuration epoch (from SewConfigurationExecutor).
///         - The current verifier registry root (from SewConfigurationExecutor).
///         - The verifier entry resolved from the active registry snapshot.
///
///         Admission is fail-closed: any verification failure reverts.
contract PrfStatementAdmission is ERC165, IPrfStatementAdmission {
    bytes32 private constant ADMISSION_DOMAIN =
        keccak256("PRF_STATEMENT_ADMISSION_V1");

    bytes32 public immutable protocolGenesisRoot;
    bytes32 public immutable chainInstanceGenesisRoot;

    IPrfChainInstanceGenesis public immutable genesis;
    SewConfigurationExecutor public immutable configurationExecutor;
    PrfVerifierRegistry public immutable verifierRegistry;

    bytes32 public immutable expectedConfigurationRoot;
    uint64 public immutable expectedConfigurationEpoch;

    uint256 public admittedCount;

    mapping(bytes32 receiptId => IPrfStatementAdmission.AdmissionReceipt) private _admissionReceipts;

    event StatementAdmitted(
        bytes32 indexed statementRoot,
        bytes32 indexed admissionReceiptId,
        bytes32 indexed publicValuesDigest,
        bytes32 verifierId,
        address verifierAdapter,
        uint256 admissionIndex
    );

    error GenesisNotSealed();
    error WrongExecutionChain(uint256 expected, uint256 actual);
    error ConfigurationMismatch(bytes32 expected, bytes32 actual);
    error EpochMismatch(uint64 expected, uint64 actual);
    error RegistryRootMismatch(bytes32 committed, bytes32 computed);
    error NotSealedRegistry(bytes32 registryRoot);
    error NoVerifiersRegistered();
    error ProofVerificationFailed();
    error StatementRootMismatch(bytes32 expected, bytes32 actual);
    error ZeroRoot();
    error InvalidEpoch(uint64 epoch);
    error AdapterIdentityMismatch(address adapter);

    constructor(
        IPrfChainInstanceGenesis genesis_,
        SewConfigurationExecutor configurationExecutor_,
        PrfVerifierRegistry verifierRegistry_,
        bytes32 expectedConfigurationRoot_,
        uint64 expectedConfigurationEpoch_
    ) {
        if (!genesis_.isSealedState()) revert GenesisNotSealed();
        if (genesis_.executionChainId() != block.chainid)
            revert WrongExecutionChain(genesis_.executionChainId(), block.chainid);
        if (expectedConfigurationRoot_ == bytes32(0)) revert ZeroRoot();
        if (expectedConfigurationEpoch_ > type(uint64).max) revert InvalidEpoch(expectedConfigurationEpoch_);

        protocolGenesisRoot = genesis_.protocolGenesisRoot();
        chainInstanceGenesisRoot = genesis_.chainInstanceGenesisRoot();
        genesis = genesis_;
        configurationExecutor = configurationExecutor_;
        verifierRegistry = verifierRegistry_;
        expectedConfigurationRoot = expectedConfigurationRoot_;
        expectedConfigurationEpoch = expectedConfigurationEpoch_;
    }

    /// @notice Admit a realized-allocation statement backed by an SP1 proof.
    /// @param verifierId The verifier identifier within the active registry snapshot.
    /// @param statementRoot The expected statement root (canonical SHA-256 root).
    /// @param proof The SP1 proof bytes.
    /// @param publicValues The public values bytes (fixed-width EVM bytes32).
    /// @return receiptId A durable, configuration-specific admission receipt ID.
    function admitStatement(
        bytes32 verifierId,
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) external override returns (bytes32 receiptId) {
        if (verifierId == bytes32(0)) revert ZeroRoot();
        if (statementRoot == bytes32(0)) revert ZeroRoot();

        _checkConfigurationBinding();

        bytes32 activeRegistryRoot = configurationExecutor.currentVerifierRegistryRoot();
        IPrfVerifierRegistry.VerifierEntry memory entry =
            verifierRegistry.getVerifier(activeRegistryRoot, verifierId);
        if (entry.adapter == address(0) || !entry.active) revert NoVerifiersRegistered();

        _checkAdapterIdentity(entry.adapter, entry);
        _verifyProof(entry.adapter, statementRoot, proof, publicValues);

        bytes32 publicValuesDigest = sha256(publicValues);
        receiptId = _admissionReceiptId(
            activeRegistryRoot,
            verifierId,
            entry,
            statementRoot,
            publicValuesDigest
        );

        _admissionReceipts[receiptId] = IPrfStatementAdmission.AdmissionReceipt({
            exists: true,
            protocolGenesisRoot: protocolGenesisRoot,
            chainInstanceGenesisRoot: chainInstanceGenesisRoot,
            configurationRoot: expectedConfigurationRoot,
            configurationEpoch: expectedConfigurationEpoch,
            verifierRegistryRoot: activeRegistryRoot,
            verifierId: verifierId,
            verifierAdapter: entry.adapter,
            programVKey: entry.programVKey,
            programElfSha256: entry.programElfSha256,
            statementSchemaVersionHash: entry.statementSchemaVersionHash,
            publicValuesSchema: entry.publicValuesSchema,
            statementRoot: statementRoot,
            publicValuesDigest: publicValuesDigest
        });

        uint256 index = admittedCount++;
        emit StatementAdmitted(
            statementRoot,
            receiptId,
            publicValuesDigest,
            verifierId,
            entry.adapter,
            index
        );
    }

    function admissionReceipt(bytes32 receiptId)
        external
        view
        override
        returns (IPrfStatementAdmission.AdmissionReceipt memory)
    {
        return _admissionReceipts[receiptId];
    }

    function _checkConfigurationBinding() private view {
        if (configurationExecutor.currentConfigurationRoot() != expectedConfigurationRoot)
            revert ConfigurationMismatch(
                expectedConfigurationRoot,
                configurationExecutor.currentConfigurationRoot()
            );

        if (configurationExecutor.currentEpoch() != expectedConfigurationEpoch)
            revert EpochMismatch(
                expectedConfigurationEpoch,
                configurationExecutor.currentEpoch()
            );

        bytes32 activeRegistryRoot = configurationExecutor.currentVerifierRegistryRoot();

        if (activeRegistryRoot == bytes32(0)) revert ZeroRoot();

        if (!verifierRegistry.isSealed(activeRegistryRoot))
            revert NotSealedRegistry(activeRegistryRoot);

        bytes32 computedRoot = verifierRegistry.canonicalRoot(activeRegistryRoot);
        if (computedRoot != activeRegistryRoot)
            revert RegistryRootMismatch(activeRegistryRoot, computedRoot);
    }


    function _checkAdapterIdentity(
        address adapterAddr,
        IPrfVerifierRegistry.VerifierEntry memory entry
    ) private view {
        IPrfStatementVerifierAdapter adapter = IPrfStatementVerifierAdapter(adapterAddr);
        if (
            adapter.programVKey() != entry.programVKey ||
            adapter.programElfSha256() != entry.programElfSha256 ||
            adapter.statementSchemaVersion() != entry.statementSchemaVersionHash ||
            adapter.publicValuesSchema() != entry.publicValuesSchema
        ) revert AdapterIdentityMismatch(adapterAddr);
    }

    function _verifyProof(
        address adapterAddr,
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) private view returns (bytes32) {
        IPrfStatementVerifierAdapter adapter =
            IPrfStatementVerifierAdapter(adapterAddr);

        bytes32 extractedRoot;
        try adapter.verifyStatementProof(statementRoot, proof, publicValues)
        returns (bytes32 root)
        {
            extractedRoot = root;
        } catch {
            revert ProofVerificationFailed();
        }

        if (extractedRoot != statementRoot)
            revert StatementRootMismatch(statementRoot, extractedRoot);

        return extractedRoot;
    }

    /// @dev This is an EVM-local admission identity, not a proof-bytes identity.
    ///      It binds the successful admission to the immutable contract instance and
    ///      every verifier/configuration fact captured in the durable receipt.
    function _admissionReceiptId(
        bytes32 registryRoot,
        bytes32 verifierId,
        IPrfVerifierRegistry.VerifierEntry memory entry,
        bytes32 statementRoot,
        bytes32 publicValuesDigest
    ) private view returns (bytes32) {
        bytes32 authoritySnapshot = keccak256(abi.encode(
            protocolGenesisRoot,
            chainInstanceGenesisRoot,
            expectedConfigurationRoot,
            expectedConfigurationEpoch,
            registryRoot
        ));
        bytes32 verifierSnapshot = keccak256(abi.encode(
            verifierId,
            entry.adapter,
            entry.programVKey,
            entry.programElfSha256,
            entry.statementSchemaVersionHash,
            entry.publicValuesSchema
        ));
        return keccak256(abi.encode(
            ADMISSION_DOMAIN,
            address(this),
            block.chainid,
            authoritySnapshot,
            verifierSnapshot,
            statementRoot,
            publicValuesDigest
        ));
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IPrfStatementAdmission).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
