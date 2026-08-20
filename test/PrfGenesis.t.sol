// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {PrfVerifierRegistry} from "../src/PrfVerifierRegistry.sol";
import {PrfEvidenceAnchor} from "../src/PrfEvidenceAnchor.sol";
import {IPrfEvidenceAnchor} from "../src/interfaces/IPrfEvidenceAnchor.sol";

contract PrfGenesisTest is Test {
    bytes32 internal constant PROTOCOL_ROOT =
        0xbf97c43c04b285dc2c37610603af5b263658b3d254d08573d29be4d67d0f1922;
    bytes32 internal constant AUTHORITY_STATE_ROOT =
        0xf43f8d60231851c7c8848acb0a5d1bd31f6b7bb03af99e5a234a22a57b8120c8;
    bytes32 internal constant CONFIG_ROOT_0 =
        0x1998ff05134c921c52794a1fa18bcc9abf8dab1d9c0f3e9710a07bab26ab0224;
    bytes32 internal constant CHAIN_ROOT =
        0x33515d22795e6b303065d36da3f352e4f141117fb81393eb7fe5e2b864f6b580;
    bytes32 internal constant FIXTURE_VKEY =
        0x00b9325e81961e4b6dfbe6fa7806796a15c018116225c85f5ef0811afc331d3f;
    bytes32 internal constant FIXTURE_ELF_SHA256 =
        0xdeed502019f2cc920aa92e36e15d429c8ace7406cce925195709dc353b3e2495;
    bytes32 internal constant FIXTURE_SCHEMA_HASH =
        keccak256("realized-allocation-statement.v1");
    bytes32 internal constant FIXTURE_PV_SCHEMA_HASH =
        keccak256("evm-bytes32-v1");

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    SewConfigurationExecutor internal executor;
    PrfVerifierRegistry internal registry;
    PrfEvidenceAnchor internal evidence;

    bytes32 internal VERIFIER_REGISTRY_ROOT_0;

    function _seedRegistryWithOneVerifier(bytes32 verifierId)
        internal
        returns (bytes32)
    {
        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfHashes = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory schemaHashes = new bytes32[](1);
        bytes32[] memory pvSchemas = new bytes32[](1);
        bool[] memory actives = new bool[](1);

        ids[0] = verifierId;
        adapters[0] = address(this);
        vkeys[0] = FIXTURE_VKEY;
        elfHashes[0] = FIXTURE_ELF_SHA256;
        programIds[0] = "test-verifier.v1";
        schemaHashes[0] = FIXTURE_SCHEMA_HASH;
        pvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        actives[0] = true;

        bytes32 root = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds, schemaHashes, pvSchemas, actives
        );

        registry.registerVerifier(
            root,
            verifierId,
            address(this),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "test-verifier.v1",
            FIXTURE_SCHEMA_HASH,
            FIXTURE_PV_SCHEMA_HASH
        );
        registry.sealRegistry(root);
        return root;
    }

    function _emptyCanonicalRoot() internal view returns (bytes32) {
        return registry.computeCanonicalRoot(
            new bytes32[](0),
            new address[](0),
            new bytes32[](0),
            new bytes32[](0),
            new string[](0),
            new bytes32[](0),
            new bytes32[](0),
            new bool[](0)
        );
    }

    function setUp() public {
        authority = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT,
            address(this),
            AUTHORITY_STATE_ROOT
        );

        genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT,
            block.chainid,
            1,
            address(authority),
            AUTHORITY_STATE_ROOT,
            CONFIG_ROOT_0,
            address(this)
        );

        genesis.sealGenesis(
            CHAIN_ROOT,
            address(genesis).codehash,
            address(authority).codehash
        );

        registry = new PrfVerifierRegistry(address(this));

        VERIFIER_REGISTRY_ROOT_0 = _emptyCanonicalRoot();
        registry.sealRegistry(VERIFIER_REGISTRY_ROOT_0);

        executor = new SewConfigurationExecutor(
            genesis,
            authority,
            registry,
            VERIFIER_REGISTRY_ROOT_0
        );
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

    function testInitialExecutorState() public {
        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_0);
        assertEq(executor.currentVerifierRegistryRoot(), VERIFIER_REGISTRY_ROOT_0);
        assertEq(executor.currentEpoch(), 0);
    }

    function testDirectConfigurationTransition() public {
        bytes32 decisionRoot = 0xe031d461072b6d47eb45e7cd0f15f0a65e717da62363d564c234d7f7e8713208;
        bytes32 configRoot1 = 0x5772ee58a15e9714c6fbf8d5851952e545dd05135276af001f70e5d1fd0bf661;

        bytes32 registryRoot1 = _seedRegistryWithOneVerifier(keccak256("dummy-direct-transition"));

        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            configRoot1,
            VERIFIER_REGISTRY_ROOT_0,
            registryRoot1,
            1
        );

        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            registryRoot1,
            1,
            0,
            CHAIN_ROOT,
            new bytes32[](0)
        );

        assertEq(executor.currentConfigurationRoot(), configRoot1);
        assertEq(executor.currentVerifierRegistryRoot(), registryRoot1);
        assertEq(executor.currentEpoch(), 1);
        assertTrue(executor.consumedDecisionRoots(decisionRoot));
    }

    function testTargetSetTransition() public {
        bytes32 decisionRoot = 0xa2b3c651d82d4331f98d3476d60338d38a26cbb169c907c093e99b485523e36f;
        bytes32 configRoot1 = 0xc1b2b67f85e7ea126f7818e27b3c28de0be57c722a3f54f13b06c0956e569acd;

        bytes32 registryRoot1 = _seedRegistryWithOneVerifier(keccak256("dummy-target-set"));

        bytes32 leaf = executor.targetSetLeaf();

        authority.authoriseDecision(
            decisionRoot,
            1,
            leaf,
            CONFIG_ROOT_0,
            configRoot1,
            VERIFIER_REGISTRY_ROOT_0,
            registryRoot1,
            1
        );

        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            registryRoot1,
            1,
            1,
            leaf,
            new bytes32[](0)
        );

        assertEq(executor.currentConfigurationRoot(), configRoot1);
        assertEq(executor.currentVerifierRegistryRoot(), registryRoot1);
    }

    function testStaleParentConfigurationRejects() public {
        bytes32 decisionRoot = 0x22b0a665d7f755bb7dd1a48945145b54a055c6529fcca6871a821b01f91b1a25;
        bytes32 configRoot1 = 0x1e9dd0fe316a457442039e775e029ad660361ce8ceb15e0401a1ddb42bf081ef;
        bytes32 configRoot2 = 0xa03f2386ae06b21109577020844df367857b72c2fcce384c1896fed98a89c82b;

        bytes32 registryRoot1 = _seedRegistryWithOneVerifier(keccak256("dummy-stale-r1"));
        bytes32 registryRoot2 = _seedRegistryWithOneVerifier(keccak256("dummy-stale-r2"));

        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            configRoot1,
            VERIFIER_REGISTRY_ROOT_0,
            registryRoot1,
            1
        );
        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            registryRoot1,
            1,
            0,
            CHAIN_ROOT,
            new bytes32[](0)
        );

        bytes32 staleDecision = 0xb23a6a8439c0dde5515893e7c90c1e3233b8616e634470f20dc4928bcf3609bc;

        authority.authoriseDecision(
            staleDecision,
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            configRoot2,
            VERIFIER_REGISTRY_ROOT_0,
            registryRoot2,
            2
        );

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionNotAuthorised.selector,
            staleDecision
        ));
        executor.applyConfiguration(
            staleDecision,
            configRoot2,
            registryRoot2,
            2,
            0,
            CHAIN_ROOT,
            new bytes32[](0)
        );
    }

    function testDecisionAlreadyConsumedRejects() public {
        bytes32 decisionRoot = 0xe89303f170371ee78c31a54fe4ef6c686cc7b98aa1a9cec1825558acbd34d3b6;
        bytes32 configRoot1 = 0x6487747cb0c41f5106a7b91dac54b464ecf2a9e0ca06b46ba5990a98009f35b9;

        bytes32 registryRoot1 = _seedRegistryWithOneVerifier(keccak256("dummy-decision-consumed"));

        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            configRoot1,
            VERIFIER_REGISTRY_ROOT_0,
            registryRoot1,
            1
        );

        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            registryRoot1,
            1,
            0,
            CHAIN_ROOT,
            new bytes32[](0)
        );

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionAlreadyConsumed.selector,
            decisionRoot
        ));
        executor.applyConfiguration(
            decisionRoot,
            configRoot1,
            registryRoot1,
            1,
            0,
            CHAIN_ROOT,
            new bytes32[](0)
        );
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
