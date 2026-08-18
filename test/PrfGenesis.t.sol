// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {PrfEvidenceAnchor} from "../src/PrfEvidenceAnchor.sol";
import {IPrfEvidenceAnchor} from "../src/interfaces/IPrfEvidenceAnchor.sol";

contract PrfGenesisTest is Test {
    bytes32 internal constant PROTOCOL_ROOT = sha256(bytes("protocol-genesis"));
    bytes32 internal constant AUTHORITY_ROOT = sha256(bytes("authority-state-0"));
    bytes32 internal constant CONFIG_ROOT_0 = sha256(bytes("configuration-0"));
    bytes32 internal constant CHAIN_ROOT = sha256(bytes("chain-instance-genesis"));

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    SewConfigurationExecutor internal executor;
    PrfEvidenceAnchor internal evidence;

    function setUp() public {
        // This test contract stands in for GovGovernor so adapter mutations can
        // exercise the same `only governor` boundary without constructing a token DAO.
        authority = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT,
            address(this),
            AUTHORITY_ROOT
        );

        genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT,
            block.chainid,
            1,
            address(authority),
            AUTHORITY_ROOT,
            CONFIG_ROOT_0,
            address(this)
        );

        genesis.sealGenesis(
            CHAIN_ROOT,
            address(genesis).codehash,
            address(authority).codehash
        );

        executor = new SewConfigurationExecutor(genesis, authority);
        evidence = new PrfEvidenceAnchor(genesis);
    }

    function testGenesisSealedAndBound() public {
        assertTrue(genesis.isSealedState());
        assertEq(genesis.protocolGenesisRoot(), PROTOCOL_ROOT);
        assertEq(genesis.chainInstanceGenesisRoot(), CHAIN_ROOT);
        assertEq(genesis.executionChainId(), block.chainid);
        assertEq(genesis.authorityAdapter(), address(authority));
        assertTrue(genesis.localProjectionHash() != bytes32(0));
    }

    function testDirectConfigurationTransition() public {
        bytes32 decisionRoot = sha256(bytes("decision-1"));
        bytes32 configRoot1 = sha256(bytes("configuration-1"));

        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            configRoot1,
            1
        );

        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            1,
            0,
            CHAIN_ROOT,
            new bytes32[](0)
        );

        assertEq(executor.currentConfigurationRoot(), configRoot1);
        assertEq(executor.currentEpoch(), 1);
        assertTrue(executor.consumedDecisionRoots(decisionRoot));
    }

    function testTargetSetTransition() public {
        bytes32 decisionRoot = sha256(bytes("decision-set-1"));
        bytes32 configRoot1 = sha256(bytes("configuration-set-1"));

        // A one-member Merkle tree has root == leaf, so no proof elements are required.
        bytes32 leaf = executor.targetSetLeaf();

        authority.authoriseDecision(
            decisionRoot,
            1,
            leaf,
            CONFIG_ROOT_0,
            configRoot1,
            1
        );

        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            1,
            1,
            leaf,
            new bytes32[](0)
        );

        assertEq(executor.currentConfigurationRoot(), configRoot1);
    }

    function testEvidenceAnchorIsImmutableFact() public {
        IPrfEvidenceAnchor.EvidenceCommitment memory commitment =
            IPrfEvidenceAnchor.EvidenceCommitment({
                subjectRoot: sha256(bytes("subject")),
                statementRoot: sha256(bytes("statement")),
                evidenceRoot: sha256(bytes("evidence")),
                verificationPolicyRoot: sha256(bytes("verification-policy")),
                verifierRoot: sha256(bytes("verifier")),
                sequence: 1
            });

        bytes32 anchorId = evidence.anchorEvidence(commitment);

        assertEq(evidence.anchorBlock(anchorId), block.number);
        assertEq(evidence.anchorTimestamp(anchorId), block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                PrfEvidenceAnchor.AnchorAlreadyExists.selector,
                anchorId
            )
        );
        evidence.anchorEvidence(commitment);
    }
}
