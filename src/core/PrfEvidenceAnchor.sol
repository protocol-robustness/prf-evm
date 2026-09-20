// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrfChainInstanceGenesis} from "../interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfEvidenceAnchor} from "../interfaces/IPrfEvidenceAnchor.sol";

/// @title PrfEvidenceAnchor
/// @notice Permissionless immutable anchoring of PRF evidence commitments.
/// @dev
/// The anchor records that a commitment existed on this chain instance.
/// It does not assert that the evidence is correct, signed, canonical, or currently usable.
/// Mutable forensic/status projections are deliberately excluded.
contract PrfEvidenceAnchor is ERC165, IPrfEvidenceAnchor {
    bytes32 private constant ANCHOR_DOMAIN =
        keccak256("PRF_EVIDENCE_ANCHOR_V1");

    IPrfChainInstanceGenesis public immutable genesis;
    bytes32 public immutable override chainInstanceGenesisRoot;

    mapping(bytes32 anchorId => uint256) public override anchorBlock;
    mapping(bytes32 anchorId => uint256) public override anchorTimestamp;

    event EvidenceAnchored(
        bytes32 indexed anchorId,
        bytes32 indexed chainInstanceGenesisRoot,
        bytes32 indexed subjectRoot,
        bytes32 statementRoot,
        bytes32 evidenceRoot,
        bytes32 verificationPolicyRoot,
        bytes32 verifierRoot,
        uint64 sequence,
        address submitter
    );

    error GenesisNotSealed();
    error WrongExecutionChain(uint256 expected, uint256 actual);
    error ZeroRoot();
    error AnchorAlreadyExists(bytes32 anchorId);

    constructor(IPrfChainInstanceGenesis genesis_) {
        if (!genesis_.isSealedState()) revert GenesisNotSealed();
        if (genesis_.executionChainId() != block.chainid) {
            revert WrongExecutionChain(genesis_.executionChainId(), block.chainid);
        }

        genesis = genesis_;
        chainInstanceGenesisRoot = genesis_.chainInstanceGenesisRoot();
    }

    /// @inheritdoc IPrfEvidenceAnchor
    function computeAnchorId(EvidenceCommitment calldata commitment)
        public
        view
        override
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                ANCHOR_DOMAIN,
                genesis.protocolGenesisRoot(),
                chainInstanceGenesisRoot,
                commitment.subjectRoot,
                commitment.statementRoot,
                commitment.evidenceRoot,
                commitment.verificationPolicyRoot,
                commitment.verifierRoot,
                commitment.sequence
            )
        );
    }

    /// @inheritdoc IPrfEvidenceAnchor
    function anchorEvidence(EvidenceCommitment calldata commitment)
        external
        override
        returns (bytes32 anchorId)
    {
        if (genesis.executionChainId() != block.chainid) {
            revert WrongExecutionChain(genesis.executionChainId(), block.chainid);
        }
        if (
            commitment.subjectRoot == bytes32(0) ||
            commitment.evidenceRoot == bytes32(0) ||
            commitment.verificationPolicyRoot == bytes32(0)
        ) revert ZeroRoot();

        anchorId = computeAnchorId(commitment);
        if (anchorBlock[anchorId] != 0) revert AnchorAlreadyExists(anchorId);

        // Block/time are observation metadata, not part of anchor identity.
        anchorBlock[anchorId] = block.number;
        anchorTimestamp[anchorId] = block.timestamp;

        emit EvidenceAnchored(
            anchorId,
            chainInstanceGenesisRoot,
            commitment.subjectRoot,
            commitment.statementRoot,
            commitment.evidenceRoot,
            commitment.verificationPolicyRoot,
            commitment.verifierRoot,
            commitment.sequence,
            msg.sender
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IPrfEvidenceAnchor).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
