// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {PrfRealizedAllocationVerifierAdapter} from "./PrfRealizedAllocationVerifierAdapter.sol";
import {PrfVerifierRegistry} from "./PrfVerifierRegistry.sol";
import {SewConfigurationExecutor} from "./SewConfigurationExecutor.sol";
import {IPrfChainInstanceGenesis} from "./interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfStatementAdmission} from "./interfaces/IPrfStatementAdmission.sol";
import {IPrfVerifierRegistry} from "./interfaces/IPrfVerifierRegistry.sol";

/// @title PrfStatementAdmission
/// @notice Admission gateway for realized-allocation-statement.v1 proofs.
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

    event StatementAdmitted(
        bytes32 indexed statementRoot,
        bytes32 indexed proofArtifactId,
        bytes32 indexed publicValuesDigest,
        address verifier,
        bytes32 programVKey,
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
    /// @param publicValuesDigest SHA-256 of public values (for off-chain audit).
    function admitStatement(
        bytes32 verifierId,
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues,
        bytes32 publicValuesDigest
    ) external override returns (uint256) {
        if (verifierId == bytes32(0)) revert ZeroRoot();
        if (statementRoot == bytes32(0)) revert ZeroRoot();
        if (publicValuesDigest == bytes32(0)) revert ZeroRoot();

        _checkConfigurationBinding();

        bytes32 activeRegistryRoot = configurationExecutor.currentVerifierRegistryRoot();

        address adapterAddr = _resolveAdapter(
            activeRegistryRoot,
            verifierId
        );

        bytes32 vkey = _resolveVkey(activeRegistryRoot, verifierId);

        bytes32 extractedRoot = _verifyProof(
            adapterAddr,
            statementRoot,
            proof,
            publicValues
        );

        _emitAdmission(
            adapterAddr,
            vkey,
            statementRoot,
            publicValuesDigest
        );

        return admittedCount - 1;
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

    function _resolveAdapter(bytes32 registryRoot, bytes32 vid)
        private view returns (address)
    {
        IPrfVerifierRegistry.VerifierEntry memory entry =
            verifierRegistry.getVerifier(registryRoot, vid);
        if (entry.adapter == address(0)) revert NoVerifiersRegistered();
        if (!entry.active) revert NoVerifiersRegistered();
        return entry.adapter;
    }

    function _resolveVkey(bytes32 registryRoot, bytes32 vid)
        private view returns (bytes32)
    {
        return verifierRegistry.getVerifier(registryRoot, vid).programVKey;
    }

    function _verifyProof(
        address adapterAddr,
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) private view returns (bytes32) {
        PrfRealizedAllocationVerifierAdapter adapter =
            PrfRealizedAllocationVerifierAdapter(adapterAddr);

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

    function _emitAdmission(
        address adapterAddr,
        bytes32 vkey,
        bytes32 statementRoot,
        bytes32 publicValuesDigest
    ) private {
        bytes32 domainSender = keccak256(abi.encodePacked(ADMISSION_DOMAIN, msg.sender));
        bytes32 proofArtifactId = keccak256(abi.encodePacked(domainSender, statementRoot, publicValuesDigest));
        uint256 index = admittedCount++;

        emit StatementAdmitted(
            statementRoot,
            proofArtifactId,
            publicValuesDigest,
            adapterAddr,
            vkey,
            index
        );
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
