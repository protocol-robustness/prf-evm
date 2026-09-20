// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {PrfRealizedAllocationVerifierAdapter} from "../src/verification/adapters/PrfRealizedAllocationVerifierAdapter.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {IPrfVerifierRegistry} from "../src/interfaces/IPrfVerifierRegistry.sol";

/// @title PrfConfigurationAuthorizationConformanceTest
contract PrfConfigurationAuthorizationConformanceTest is Test {
    bytes32 internal constant PROTOCOL_ROOT =
        0xd77429dd50bd7fe18d5f41d55e53ccbd4c67d18c4f00b266f86dbaede01f9343;

    bytes32 internal constant AUTHORITY_STATE_ROOT =
        0x150c28318e27fffacd9233c7ace128f7639f16c47d1c844e5440a07db39867cd;

    bytes32 internal constant CHAIN_INSTANCE_ROOT =
        0xf6c0f226998ebecb1123f78c2b30347d24c6e7ca2131f44f880b8a43c052cf86;

    bytes32 internal constant CONFIG_ROOT_0 =
        0xa3b808fa66ad9b9c4f35de5590ad95213cf0de76190db5980ced743f39f97f57;

    bytes32 internal constant CONFIG_ROOT_1 =
        0x785f9b5c1a92ba54bd8f6dcaef3e416f4ab8e3b7f708310e92535c640ddbbc6d;

    bytes32 internal constant DECISION_ROOT =
        0x2db92fa9655c0fb44cf984c4ebcda53885f7812db3b5368b937821f3c223c66b;

    uint8 internal constant TARGET_MODE_DIRECT = 0;

    bytes32 internal constant REALIZED_ALLOC_VERIFIER_ID =
        keccak256("realized-allocation-statement.v1");
    bytes32 internal constant SYNTHETIC_TEST_VERIFIER_ID =
        keccak256("synthetic-test-verifier.v1");
    bytes32 internal constant LEGACY_R0_ONLY_VERIFIER_ID =
        keccak256("legacy-r0-only-verifier.v1");

    bytes32 internal constant FIXTURE_VKEY =
        0x00b9325e81961e4b6dfbe6fa7806796a15c018116225c85f5ef0811afc331d3f;
    bytes32 internal constant FIXTURE_ELF_SHA256 =
        0xdeed502019f2cc920aa92e36e15d429c8ace7406cce925195709dc353b3e2495;
    bytes32 internal constant FIXTURE_PV_SCHEMA_HASH =
        keccak256("evm-bytes32-v1");
    bytes32 internal constant VERIFIER_HASH = keccak256("SP1Groth16Verifier");

    bytes32 internal constant FIXTURE_STATEMENT_ROOT =
        0xc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81;

    bytes internal constant FIXTURE_PUBLIC_VALUES =
        hex"c22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81";

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    SewConfigurationExecutor internal executor;
    PrfVerifierRegistry internal registry;
    MockSP1Verifier internal sp1Mock;
    PrfRealizedAllocationVerifierAdapter internal adapter;

    bytes32 internal VERIFIER_REGISTRY_ROOT_0;
    bytes32 internal VERIFIER_REGISTRY_ROOT_1;

    struct VerifierSeed {
        bytes32 id;
        address adapter;
        bytes32 vkey;
        bytes32 elfHash;
        string programId;
        bytes32 schemaHash;
        bytes32 pvSchema;
        bool active;
    }

    function _customSeed(bytes32 id, address adapterAddr)
        internal view returns (VerifierSeed memory)
    {
        return VerifierSeed({
            id: id,
            adapter: adapterAddr,
            vkey: FIXTURE_VKEY,
            elfHash: FIXTURE_ELF_SHA256,
            programId: "realized-allocation-proof.v1",
            schemaHash: keccak256("realized-allocation-statement.v1"),
            pvSchema: FIXTURE_PV_SCHEMA_HASH,
            active: true
        });
    }

    function _allocSeed(address adapterAddr) internal view returns (VerifierSeed memory) {
        return _customSeed(REALIZED_ALLOC_VERIFIER_ID, adapterAddr);
    }

    function _legacySeed(address adapterAddr) internal view returns (VerifierSeed memory) {
        return VerifierSeed({
            id: LEGACY_R0_ONLY_VERIFIER_ID,
            adapter: adapterAddr,
            vkey: FIXTURE_VKEY,
            elfHash: FIXTURE_ELF_SHA256,
            programId: "legacy-r0-only-proof.v1",
            schemaHash: keccak256("legacy-r0-only-statement.v1"),
            pvSchema: FIXTURE_PV_SCHEMA_HASH,
            active: true
        });
    }

    function _syntheticSeed(address adapterAddr) internal view returns (VerifierSeed memory) {
        return VerifierSeed({
            id: SYNTHETIC_TEST_VERIFIER_ID,
            adapter: adapterAddr,
            vkey: FIXTURE_VKEY,
            elfHash: FIXTURE_ELF_SHA256,
            programId: "synthetic-test-verifier.v1",
            schemaHash: keccak256("synthetic-test-statement.v1"),
            pvSchema: FIXTURE_PV_SCHEMA_HASH,
            active: true
        });
    }

    function _computeRoot(VerifierSeed[] memory seeds) internal returns (bytes32 root) {
        bytes32[] memory ids = new bytes32[](seeds.length);
        address[] memory adapters = new address[](seeds.length);
        bytes32[] memory vkeys = new bytes32[](seeds.length);
        bytes32[] memory elfHashes = new bytes32[](seeds.length);
        string[] memory programIds = new string[](seeds.length);
        bytes32[] memory schemaHashes = new bytes32[](seeds.length);
        bytes32[] memory pvSchemas = new bytes32[](seeds.length);
        bool[] memory actives = new bool[](seeds.length);

        for (uint256 i = 0; i < seeds.length; i++) {
            ids[i] = seeds[i].id;
            adapters[i] = seeds[i].adapter;
            vkeys[i] = seeds[i].vkey;
            elfHashes[i] = seeds[i].elfHash;
            programIds[i] = seeds[i].programId;
            schemaHashes[i] = seeds[i].schemaHash;
            pvSchemas[i] = seeds[i].pvSchema;
            actives[i] = seeds[i].active;
        }

        root = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds, schemaHashes, pvSchemas, actives
        );
    }

    function _commitRegistry(VerifierSeed[] memory seeds, bool seal)
        internal returns (bytes32 root)
    {
        root = _computeRoot(seeds);
        for (uint256 i = 0; i < seeds.length; i++) {
            registry.registerVerifier(
                root, seeds[i].id, seeds[i].adapter, seeds[i].vkey,
                seeds[i].elfHash, seeds[i].programId, seeds[i].schemaHash, seeds[i].pvSchema
            );
        }
        if (seal) {
            registry.sealRegistry(root);
        }
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
            CHAIN_INSTANCE_ROOT,
            address(genesis).codehash,
            address(authority).codehash
        );

        registry = new PrfVerifierRegistry(address(this));

        bytes32 commitment = keccak256(abi.encodePacked(FIXTURE_VKEY, FIXTURE_PUBLIC_VALUES));
        sp1Mock = new MockSP1Verifier(commitment, VERIFIER_HASH);

        adapter = new PrfRealizedAllocationVerifierAdapter(
            sp1Mock,
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "realized-allocation-statement.v1",
            "evm-bytes32-v1"
        );

        VERIFIER_REGISTRY_ROOT_0 = _seedR0Registry();
        VERIFIER_REGISTRY_ROOT_1 = _seedR1Registry(commitment);

        executor = new SewConfigurationExecutor(
            genesis, authority, registry, VERIFIER_REGISTRY_ROOT_0
        );
    }

    function _seedR0Registry() internal returns (bytes32) {
        VerifierSeed[] memory seeds = new VerifierSeed[](2);
        seeds[0] = _allocSeed(address(adapter));
        seeds[1] = _legacySeed(address(adapter));
        return _commitRegistry(seeds, true);
    }

    function _seedR1Registry(bytes32 commitment) internal returns (bytes32) {
        MockSP1Verifier syntheticMock = new MockSP1Verifier(commitment, VERIFIER_HASH);
        PrfRealizedAllocationVerifierAdapter syntheticAdapter =
            new PrfRealizedAllocationVerifierAdapter(
                syntheticMock,
                FIXTURE_VKEY,
                FIXTURE_ELF_SHA256,
                "realized-allocation-statement.v1",
                "evm-bytes32-v1"
            );

        VerifierSeed[] memory seeds = new VerifierSeed[](2);
        seeds[0] = _allocSeed(address(adapter));
        seeds[1] = _syntheticSeed(address(syntheticAdapter));
        return _commitRegistry(seeds, true);
    }

    function test_P1_InitialExecutorState_ExposesExactC0R0() public {
        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_0);
        assertEq(executor.currentVerifierRegistryRoot(), VERIFIER_REGISTRY_ROOT_0);
        assertEq(executor.currentEpoch(), 0);
    }

    function test_P2_R0IsSealed() public {
        assertTrue(registry.isSealed(VERIFIER_REGISTRY_ROOT_0));
    }

    function test_P2b_R1IsSealed() public {
        assertTrue(registry.isSealed(VERIFIER_REGISTRY_ROOT_1));
    }

    function test_P3_VerifierVIsResolvableUnderR0() public {
        IPrfVerifierRegistry.VerifierEntry memory v =
            registry.getVerifier(VERIFIER_REGISTRY_ROOT_0, REALIZED_ALLOC_VERIFIER_ID);
        assertEq(v.adapter, address(adapter));
        assertEq(v.programVKey, FIXTURE_VKEY);
        assertEq(v.programElfSha256, FIXTURE_ELF_SHA256);
        assertTrue(v.active);
    }

    function test_P4_ExactAuthorisedTransition_Succeeds() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_1);
        assertEq(executor.currentVerifierRegistryRoot(), VERIFIER_REGISTRY_ROOT_1);
        assertEq(executor.currentEpoch(), 1);
        assertTrue(executor.consumedDecisionRoots(DECISION_ROOT));
    }

    function test_P5_ExecutorStateBecomesExactlyC1R1Epoch1() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_1);
        assertEq(executor.currentVerifierRegistryRoot(), VERIFIER_REGISTRY_ROOT_1);
        assertEq(executor.currentEpoch(), 1);
    }

    function test_P6_VerifierResolutionAfterTransition_UsesR1() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        assertEq(executor.currentVerifierRegistryRoot(), VERIFIER_REGISTRY_ROOT_1);

        IPrfVerifierRegistry.VerifierEntry memory v =
            registry.getVerifier(VERIFIER_REGISTRY_ROOT_1, REALIZED_ALLOC_VERIFIER_ID);
        assertEq(v.adapter, address(adapter));
        assertTrue(v.active);
    }

    function test_P7_StatementAdmission_SucceedsUsingExactConfigRootEpochAndR1Verifier() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        PrfStatementAdmission admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_1,
            1
        );

        bytes32 statementRoot = FIXTURE_STATEMENT_ROOT;
        bytes memory publicValues = new bytes(32);
        publicValues = abi.encodePacked(statementRoot);

        bytes32 receiptId = admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            statementRoot,
            "",
            publicValues
        );
        assertTrue(receiptId != bytes32(0));
        assertEq(admission.admittedCount(), 1);
    }

    function test_N8_CorrectEpochWrongConfigRootRejects() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        bytes32 wrongNewConfig = keccak256("wrong-new-config");

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionNotAuthorised.selector,
            DECISION_ROOT
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            wrongNewConfig,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function test_N9_CorrectConfigRootWrongEpochRejects() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.InvalidNextEpoch.selector,
            uint64(1),
            uint64(2)
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            2,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function test_N10_ApplyC1WithWrongNewRegistryRootRejects() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        bytes32 wrongRegistryRoot = keccak256("wrong-registry");

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionNotAuthorised.selector,
            DECISION_ROOT
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            wrongRegistryRoot,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function test_N11_StaleParentRegistryRootRejects() public {
        bytes32 firstDecision = sha256(bytes("first-decision"));
        bytes32 configRoot1 = sha256(bytes("config-1"));

        VerifierSeed[] memory r1Seeds = new VerifierSeed[](1);
        r1Seeds[0] = _customSeed(keccak256("verifier-r1-1"), address(adapter));
        bytes32 registryRoot1 = _commitRegistry(r1Seeds, true);

        authority.authoriseDecision(
            firstDecision,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            configRoot1,
            VERIFIER_REGISTRY_ROOT_0,
            registryRoot1,
            1
        );
        executor.applyConfiguration(
            firstDecision,
            configRoot1,
            registryRoot1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        bytes32 staleDecision = sha256(bytes("stale-decision"));
        bytes32 configRoot2 = sha256(bytes("config-2"));

        VerifierSeed[] memory r2Seeds = new VerifierSeed[](1);
        r2Seeds[0] = _customSeed(keccak256("verifier-r2-1"), address(adapter));
        bytes32 registryRoot2 = _commitRegistry(r2Seeds, true);

        authority.authoriseDecision(
            staleDecision,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            configRoot1,
            configRoot2,
            keccak256("wrong-parent-registry"),
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
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function test_N12_UnsealedNewRegistryRootRejects() public {
        VerifierSeed[] memory r1Seeds = new VerifierSeed[](1);
        r1Seeds[0] = _customSeed(keccak256("verifier-unsealed-1"), address(adapter));
        bytes32 unsealedRegistry = _commitRegistry(r1Seeds, false);

        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            unsealedRegistry,
            1
        );

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.NewRegistryNotSealed.selector,
            unsealedRegistry
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            unsealedRegistry,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function test_N13_VerifierExistingOnlyInR0CannotBeUsedUnderR1() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        IPrfVerifierRegistry.VerifierEntry memory v =
            registry.getVerifier(VERIFIER_REGISTRY_ROOT_0, LEGACY_R0_ONLY_VERIFIER_ID);
        assertEq(v.active, true);

        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.VerifierNotFound.selector,
            VERIFIER_REGISTRY_ROOT_1,
            LEGACY_R0_ONLY_VERIFIER_ID
        ));
        registry.getVerifier(VERIFIER_REGISTRY_ROOT_1, LEGACY_R0_ONLY_VERIFIER_ID);
    }

    function test_N14_AddingVerifierToSealedR0Rejects() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.AlreadySealed.selector,
            VERIFIER_REGISTRY_ROOT_0
        ));
        registry.registerVerifier(
            VERIFIER_REGISTRY_ROOT_0,
            keccak256("new-verifier-r0"),
            address(adapter),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "test",
            keccak256("test-statement.v1"),
            FIXTURE_PV_SCHEMA_HASH
        );
    }

    function test_N15_ModifyingVerifierInSealedR0Rejects() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.AlreadySealed.selector,
            VERIFIER_REGISTRY_ROOT_0
        ));
        registry.activateVerifier(VERIFIER_REGISTRY_ROOT_0, REALIZED_ALLOC_VERIFIER_ID);
    }

    function test_N16_DeactivatingVerifierInSealedR0Rejects() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.AlreadySealed.selector,
            VERIFIER_REGISTRY_ROOT_0
        ));
        registry.deactivateVerifier(VERIFIER_REGISTRY_ROOT_0, REALIZED_ALLOC_VERIFIER_ID);
    }

    function test_N17_DirectEOARegistryMutationRejects() public {
        address eoa = makeAddr("random_eoa");
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.OnlyGovernor.selector,
            eoa,
            address(this)
        ));
        registry.registerVerifier(
            keccak256("new-registry-eoa"),
            keccak256("verifier"),
            address(adapter),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "test",
            keccak256("test-statement.v1"),
            FIXTURE_PV_SCHEMA_HASH
        );
    }

    function test_N18_AuthorityAdapterDirectRegistryMutationRejects() public {
        address authorityAddr = address(authority);
        vm.prank(authorityAddr);
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.OnlyGovernor.selector,
            authorityAddr,
            address(this)
        ));
        registry.registerVerifier(
            keccak256("new-registry-auth"),
            keccak256("verifier"),
            address(adapter),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "test",
            keccak256("test-statement.v1"),
            FIXTURE_PV_SCHEMA_HASH
        );
    }

    function test_N20_AdmissionRejectsVerifierFromNonCurrentRegistryRoot() public {
        PrfStatementAdmission admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_0,
            0
        );

        bytes32 statementRoot = FIXTURE_STATEMENT_ROOT;
        bytes memory publicValues = new bytes(32);
        publicValues = abi.encodePacked(statementRoot);

        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        PrfStatementAdmission admissionR1 = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_1,
            1
        );

        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.VerifierNotFound.selector,
            VERIFIER_REGISTRY_ROOT_1,
            LEGACY_R0_ONLY_VERIFIER_ID
        ));
        admissionR1.admitStatement(
            LEGACY_R0_ONLY_VERIFIER_ID,
            statementRoot,
            "",
            publicValues
        );
    }

    function test_N21_StatementRootMismatchRemainsRejected() public {
        PrfStatementAdmission admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_0,
            0
        );

        bytes32 wrongRoot = 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;
        bytes memory publicValues = new bytes(32);
        publicValues = abi.encodePacked(FIXTURE_STATEMENT_ROOT);

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            wrongRoot,
            "",
            publicValues
        );
    }

    function test_N22_MalformedPublicValuesLengthRemainsRejected() public {
        PrfStatementAdmission admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_0,
            0
        );

        bytes memory shortPv = new bytes(16);

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            shortPv
        );
    }

    function test_ExistingDirectTransitionConformance() public {
        bytes32 oldDecisionRoot = 0xabb2aa2c77e78f5b5633eb645bd05816c97214ad0a2901df4d3e662ae35b7f22;
        bytes32 oldConfigParent = 0x12025a7e7948edfa9319ca31c2a8c81b57b8ad066c05aa2e79b5db9497e53035;
        bytes32 oldConfigNew = 0xeeabcdeca12cc86143032758cdf069751b47546dd69a94efeb008f4f2ae2b39c;
        bytes32 oldVerifierRegistry = VERIFIER_REGISTRY_ROOT_0;

        authority.authoriseDecision(
            oldDecisionRoot,
            0,
            CHAIN_INSTANCE_ROOT,
            oldConfigParent,
            oldConfigNew,
            oldVerifierRegistry,
            oldVerifierRegistry,
            1
        );

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionNotAuthorised.selector,
            oldDecisionRoot
        ));
        executor.applyConfiguration(
            oldDecisionRoot,
            oldConfigNew,
            oldVerifierRegistry,
            1,
            0,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function test_C1_ConfigRootMismatchRejectsAdmission() public {
        address eoa = makeAddr("attacker");

        VerifierSeed[] memory forged = new VerifierSeed[](1);
        forged[0] = _customSeed(keccak256("attacker-verifier"), eoa);
        bytes32 attackerRoot = _commitRegistry(forged, true);

        PrfStatementAdmission attackerAdmission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_1,
            1
        );

        bytes32 statementRoot = FIXTURE_STATEMENT_ROOT;
        bytes memory publicValues = new bytes(32);
        publicValues = abi.encodePacked(statementRoot);

        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector,
            CONFIG_ROOT_1,
            CONFIG_ROOT_0
        ));
        attackerAdmission.admitStatement(
            forged[0].id,
            statementRoot,
            "",
            publicValues
        );
    }

    function test_D1_FakeStoredRegistryRootWithRealEntriesRejects() public {
        VerifierSeed[] memory r0 = new VerifierSeed[](1);
        r0[0] = _customSeed(keccak256("fake-root-verifier"), address(adapter));

        bytes32 realRoot = _computeRoot(r0);
        bytes32 fakeRoot = keccak256("fake-registry-root-not-canonical");

        registry.registerVerifier(
            fakeRoot,
            r0[0].id,
            r0[0].adapter,
            r0[0].vkey,
            r0[0].elfHash,
            r0[0].programId,
            r0[0].schemaHash,
            FIXTURE_PV_SCHEMA_HASH
        );

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.RegistryRootMismatch.selector,
            fakeRoot,
            realRoot
        ));
        registry.sealRegistry(fakeRoot);
    }

    function test_D2_ReplaceVerifierUnderExistingIdRequiresNewRoot() public {
        VerifierSeed[] memory modified = new VerifierSeed[](1);
        modified[0] = VerifierSeed({
            id: REALIZED_ALLOC_VERIFIER_ID,
            adapter: address(0xDEAD),
            vkey: FIXTURE_VKEY,
            elfHash: FIXTURE_ELF_SHA256,
            programId: "realized-allocation-proof.v1",
            schemaHash: keccak256("realized-allocation-statement.v1"),
            pvSchema: FIXTURE_PV_SCHEMA_HASH,
            active: true
        });
        bytes32 modifiedRoot = _computeRoot(modified);

        assertGt(uint256(uint160(address(0xDEAD))), 0);
        assertEq(modifiedRoot != VERIFIER_REGISTRY_ROOT_0, true);
        assertEq(registry.canonicalRootMatches(VERIFIER_REGISTRY_ROOT_0), true);

        MockSP1Verifier legacyMock = new MockSP1Verifier(
            keccak256(abi.encodePacked(FIXTURE_VKEY, FIXTURE_PUBLIC_VALUES)),
            VERIFIER_HASH
        );
        PrfRealizedAllocationVerifierAdapter legacyAdapter =
            new PrfRealizedAllocationVerifierAdapter(
                legacyMock,
                FIXTURE_VKEY,
                FIXTURE_ELF_SHA256,
                "realized-allocation-statement.v1",
                "evm-bytes32-v1"
            );

        VerifierSeed[] memory r0 = new VerifierSeed[](2);
        r0[0] = _allocSeed(address(adapter));
        r0[1] = _legacySeed(address(legacyAdapter));
        bytes32 realR0Root = _computeRoot(r0);

        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.AlreadySealed.selector,
            VERIFIER_REGISTRY_ROOT_0
        ));
        registry.registerVerifier(
            VERIFIER_REGISTRY_ROOT_0,
            REALIZED_ALLOC_VERIFIER_ID,
            address(legacyAdapter),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "tampered-proof.v1",
            keccak256("realized-allocation-statement.v1"),
            FIXTURE_PV_SCHEMA_HASH
        );
    }

    function test_E1_DeactivatingVerifierRequiresUnsealing() public {
        vm.prank(address(this));
        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.AlreadySealed.selector,
            VERIFIER_REGISTRY_ROOT_0
        ));
        registry.deactivateVerifier(VERIFIER_REGISTRY_ROOT_0, REALIZED_ALLOC_VERIFIER_ID);

        assertEq(
            registry.getVerifier(VERIFIER_REGISTRY_ROOT_0, REALIZED_ALLOC_VERIFIER_ID).active,
            true
        );
    }

    function test_F1_FakeStoredRootRejectsAtSeal() public {
        bytes32 emptyRoot = _commitRegistry(new VerifierSeed[](0), true);

        assertTrue(registry.isSealed(emptyRoot));
        assertTrue(registry.canonicalRootMatches(emptyRoot));
    }

    function test_F2_LegitimateRegistryRootForgedConfigRootRejects() public {
        PrfStatementAdmission wrongConfigAdmission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            keccak256("forged-config-root"),
            0
        );

        bytes32 statementRoot = FIXTURE_STATEMENT_ROOT;
        bytes memory publicValues = new bytes(32);
        publicValues = abi.encodePacked(statementRoot);

        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector,
            keccak256("forged-config-root"),
            CONFIG_ROOT_0
        ));
        wrongConfigAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            statementRoot,
            "",
            publicValues
        );
    }

    function test_G1_RealProofAdmissionRegression() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_1,
            1
        );

        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            VERIFIER_REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        PrfStatementAdmission admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_1,
            1
        );

        assertTrue(registry.canonicalRootMatches(VERIFIER_REGISTRY_ROOT_1));
        assertTrue(registry.canonicalRootMatches(VERIFIER_REGISTRY_ROOT_0));

        bytes32 statementRoot = FIXTURE_STATEMENT_ROOT;
        bytes memory publicValues = new bytes(32);
        publicValues = abi.encodePacked(statementRoot);

        bytes32 receiptId = admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            statementRoot,
            "",
            publicValues
        );
        assertTrue(receiptId != bytes32(0));
        assertEq(admission.admittedCount(), 1);
    }
}
