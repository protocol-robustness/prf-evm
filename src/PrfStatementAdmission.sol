// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {PrfRealizedAllocationVerifierAdapter} from "./PrfRealizedAllocationVerifierAdapter.sol";
import {PrfVerifierRegistry} from "./PrfVerifierRegistry.sol";
import {SewConfigurationExecutor} from "./SewConfigurationExecutor.sol";
import {IPrfChainInstanceGenesis} from "./interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfStatementAdmission} from "./interfaces/IPrfStatementAdmission.sol";

/// @title PrfStatementAdmission
/// @notice Admission gateway for realized-allocation-statement.v1 proofs.
///         Binds together:
///         - The chain-instance genesis root (immutable identity).
///         - The current configuration root (from SewConfigurationExecutor).
///         - The verifier registry (approved SP1 programs + adapters).
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

    bytes32 public expectedConfigurationRoot;

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
    error NoVerifiersRegistered();
    error ProofVerificationFailed();
    error StatementRootMismatch(bytes32 expected, bytes32 actual);
    error ZeroRoot();

    constructor(
        IPrfChainInstanceGenesis genesis_,
        SewConfigurationExecutor configurationExecutor_,
        PrfVerifierRegistry verifierRegistry_,
        bytes32 expectedConfigurationRoot_
    ) {
        if (!genesis_.isSealedState()) revert GenesisNotSealed();
        if (genesis_.executionChainId() != block.chainid)
            revert WrongExecutionChain(genesis_.executionChainId(), block.chainid);
        if (expectedConfigurationRoot_ == bytes32(0)) revert ZeroRoot();

        protocolGenesisRoot = genesis_.protocolGenesisRoot();
        chainInstanceGenesisRoot = genesis_.chainInstanceGenesisRoot();
        genesis = genesis_;
        configurationExecutor = configurationExecutor_;
        verifierRegistry = verifierRegistry_;
        expectedConfigurationRoot = expectedConfigurationRoot_;
    }

    /// @notice Admit a realized-allocation statement backed by an SP1 proof.
    /// @param statementRoot The expected statement root (canonical SHA-256 root).
    /// @param proof The SP1 proof bytes.
    /// @param publicValues The public values bytes (UTF-8 JSON from the guest).
    /// @param publicValuesDigest SHA-256 of public values (for off-chain audit).
    function admitStatement(
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues,
        bytes32 publicValuesDigest
    ) external override returns (uint256) {
        if (statementRoot == bytes32(0)) revert ZeroRoot();
        if (publicValuesDigest == bytes32(0)) revert ZeroRoot();

        if (configurationExecutor.currentConfigurationRoot() != expectedConfigurationRoot)
            revert ConfigurationMismatch(
                expectedConfigurationRoot,
                configurationExecutor.currentConfigurationRoot()
            );

        (address adapterAddr, bytes32 vkey) = _findActiveVerifier();
        if (adapterAddr == address(0)) revert NoVerifiersRegistered();

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

        bytes32 proofArtifactId =
            keccak256(abi.encodePacked(ADMISSION_DOMAIN, msg.sender, statementRoot, publicValuesDigest));

        uint256 index = admittedCount++;
        emit StatementAdmitted(
            statementRoot,
            proofArtifactId,
            publicValuesDigest,
            adapterAddr,
            vkey,
            index
        );

        return index;
    }

    function _findActiveVerifier() internal view returns (address adapterAddr, bytes32 vkey) {
        uint256 vcount = verifierRegistry.verifierCount();
        for (uint256 i = 0; i < vcount; i++) {
            (address a, bytes32 k, , , , bool active) =
                verifierRegistry.verifiers(i);
            if (active) {
                return (a, k);
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
            interfaceId == type(IPrfStatementAdmission).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
