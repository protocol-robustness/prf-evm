// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IPrfChainInstanceGenesis} from "./interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfConfigurationExecutor} from "./interfaces/IPrfConfigurationExecutor.sol";
import {ISewGovernanceAuthority} from "./interfaces/ISewGovernanceAuthority.sol";

/// @title SewConfigurationExecutor
/// @notice Applies expected-parent PRF configuration-root transitions authorised by SEW governance.
/// @dev
/// - Anyone may relay an already authorised transition.
/// - Authority is checked against the exact parent/new root + epoch + target.
/// - Each decision root is consumable once.
/// - A stale parent cannot be applied.
///
/// Target modes:
/// 0: targetRoot must equal this chain-instance-genesis-root.
/// 1: targetRoot is a sorted-pair keccak Merkle root containing this instance.
///    Leaf = keccak256(abi.encode(TARGET_SET_LEAF_DOMAIN, chainInstanceGenesisRoot)).
contract SewConfigurationExecutor is ERC165, IPrfConfigurationExecutor {
    uint8 public constant TARGET_DIRECT = 0;
    uint8 public constant TARGET_SET = 1;

    bytes32 public constant TARGET_SET_LEAF_DOMAIN =
        keccak256("PRF_EEZ_TARGET_INSTANCE_LEAF_V1");

    IPrfChainInstanceGenesis public immutable genesis;
    ISewGovernanceAuthority public immutable authority;

    bytes32 public immutable override chainInstanceGenesisRoot;
    bytes32 public override currentConfigurationRoot;
    uint64 public override currentEpoch;

    mapping(bytes32 decisionRoot => bool) public override consumedDecisionRoots;

    event ConfigurationApplied(
        bytes32 indexed decisionRoot,
        bytes32 indexed previousConfigurationRoot,
        bytes32 indexed newConfigurationRoot,
        uint64 epoch,
        uint8 targetMode,
        bytes32 targetRoot
    );

    error GenesisNotSealed();
    error WrongExecutionChain(uint256 expected, uint256 actual);
    error ProtocolGenesisMismatch(bytes32 expected, bytes32 actual);
    error AuthorityAdapterMismatch(address expected, address actual);
    error InitialConfigurationMismatch(bytes32 expected, bytes32 actual);
    error ZeroRoot();
    error InvalidTargetMode(uint8 targetMode);
    error DirectTargetMismatch(bytes32 expected, bytes32 actual);
    error TargetSetMembershipInvalid(bytes32 targetRoot, bytes32 instanceRoot);
    error InvalidNextEpoch(uint64 expected, uint64 actual);
    error DecisionAlreadyConsumed(bytes32 decisionRoot);
    error DecisionNotAuthorised(bytes32 decisionRoot);

    constructor(
        IPrfChainInstanceGenesis genesis_,
        ISewGovernanceAuthority authority_
    ) {
        if (!genesis_.isSealedState()) revert GenesisNotSealed();
        if (genesis_.executionChainId() != block.chainid) {
            revert WrongExecutionChain(genesis_.executionChainId(), block.chainid);
        }
        if (authority_.protocolGenesisRoot() != genesis_.protocolGenesisRoot()) {
            revert ProtocolGenesisMismatch(
                genesis_.protocolGenesisRoot(),
                authority_.protocolGenesisRoot()
            );
        }
        if (address(authority_) != genesis_.authorityAdapter()) {
            revert AuthorityAdapterMismatch(
                genesis_.authorityAdapter(),
                address(authority_)
            );
        }

        bytes32 initialRoot = genesis_.initialConfigurationRoot();
        if (initialRoot == bytes32(0)) revert ZeroRoot();

        genesis = genesis_;
        authority = authority_;
        chainInstanceGenesisRoot = genesis_.chainInstanceGenesisRoot();
        currentConfigurationRoot = initialRoot;
        currentEpoch = 0;
    }

    /// @inheritdoc IPrfConfigurationExecutor
    function applyConfiguration(
        bytes32 decisionRoot,
        bytes32 newConfigurationRoot,
        uint64 nextEpoch,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32[] calldata targetProof
    ) external override {
        if (genesis.executionChainId() != block.chainid) {
            revert WrongExecutionChain(genesis.executionChainId(), block.chainid);
        }
        if (
            decisionRoot == bytes32(0) ||
            newConfigurationRoot == bytes32(0) ||
            targetRoot == bytes32(0)
        ) revert ZeroRoot();
        if (consumedDecisionRoots[decisionRoot]) {
            revert DecisionAlreadyConsumed(decisionRoot);
        }

        uint64 expectedEpoch = currentEpoch + 1;
        if (nextEpoch != expectedEpoch) {
            revert InvalidNextEpoch(expectedEpoch, nextEpoch);
        }

        _verifyTarget(targetMode, targetRoot, targetProof);

        bytes32 parentRoot = currentConfigurationRoot;

        if (
            !authority.isAuthorisedDecision(
                decisionRoot,
                targetMode,
                targetRoot,
                parentRoot,
                newConfigurationRoot,
                nextEpoch
            )
        ) {
            revert DecisionNotAuthorised(decisionRoot);
        }

        // Effects before any external work; this function has no external calls after this point.
        consumedDecisionRoots[decisionRoot] = true;
        currentConfigurationRoot = newConfigurationRoot;
        currentEpoch = nextEpoch;

        emit ConfigurationApplied(
            decisionRoot,
            parentRoot,
            newConfigurationRoot,
            nextEpoch,
            targetMode,
            targetRoot
        );
    }

    function targetSetLeaf() external view returns (bytes32) {
        return keccak256(
            abi.encode(TARGET_SET_LEAF_DOMAIN, chainInstanceGenesisRoot)
        );
    }

    function _verifyTarget(
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32[] calldata targetProof
    ) private view {
        if (targetMode == TARGET_DIRECT) {
            if (targetRoot != chainInstanceGenesisRoot) {
                revert DirectTargetMismatch(chainInstanceGenesisRoot, targetRoot);
            }
            return;
        }

        if (targetMode == TARGET_SET) {
            bytes32 leaf = keccak256(
                abi.encode(TARGET_SET_LEAF_DOMAIN, chainInstanceGenesisRoot)
            );
            if (!MerkleProof.verifyCalldata(targetProof, targetRoot, leaf)) {
                revert TargetSetMembershipInvalid(
                    targetRoot,
                    chainInstanceGenesisRoot
                );
            }
            return;
        }

        revert InvalidTargetMode(targetMode);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IPrfConfigurationExecutor).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
