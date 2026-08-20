// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {PrfVerifierRegistry} from "../src/PrfVerifierRegistry.sol";
import {PrfRealizedAllocationVerifierAdapter} from "../src/PrfRealizedAllocationVerifierAdapter.sol";
import {MockSP1Verifier} from "../src/MockSP1Verifier.sol";
import {PrfStatementAdmission} from "../src/PrfStatementAdmission.sol";
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
        bytes32[] memory ids = new bytes32[](2);
        address[] memory adapters = new address[](2);
        bytes32[] memory vkeys = new bytes32[](2);
        bytes32[] memory elfHashes = new bytes32[](2);
        string[] memory programIds = new string[](2);
        bytes32[] memory schemaHashes = new bytes32[](2);
        bytes32[] memory pvSchemas = new bytes32[](2);
        bool[] memory actives = new bool[](2);

        ids[0] = REALIZED_ALLOC_VERIFIER_ID;
        adapters[0] = address(adapter);
        vkeys[0] = FIXTURE_VKEY;
        elfHashes[0] = FIXTURE_ELF_SHA256;
        programIds[0] = "realized-allocation-proof.v1";
        schemaHashes[0] = keccak256("realized-allocation-statement.v1");
        pvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        actives[0] = true;

        ids[1] = LEGACY_R0_ONLY_VERIFIER_ID;
        adapters[1] = address(adapter);
        vkeys[1] = FIXTURE_VKEY;
        elfHashes[1] = FIXTURE_ELF_SHA256;
        programIds[1] = "legacy-r0-only-proof.v1";
        schemaHashes[1] = keccak256("legacy-r0-only-statement.v1");
        pvSchemas[1] = FIXTURE_PV_SCHEMA_HASH;
        actives[1] = true;

        bytes32 root = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds,
            schemaHashes, pvSchemas, actives
        );

        for (uint256 i = 0; i < 2; i++) {
            registry.registerVerifier(
                root, ids[i], adapters[i], vkeys[i], elfHashes[i],
                programIds[i], schemaHashes[i], pvSchemas[i]
            );
        }
        registry.sealRegistry(root);

        return root;
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

        bytes32[] memory ids = new bytes32[](2);
        address[] memory adapters = new address[](2);
        bytes32[] memory vkeys = new bytes32[](2);
        bytes32[] memory elfHashes = new bytes32[](2);
        string[] memory programIds = new string[](2);
        bytes32[] memory schemaHashes = new bytes32[](2);
        bytes32[] memory pvSchemas = new bytes32[](2);
        bool[] memory actives = new bool[](2);

        ids[0] = REALIZED_ALLOC_VERIFIER_ID;
        adapters[0] = address(adapter);
        vkeys[0] = FIXTURE_VKEY;
        elfHashes[0] = FIXTURE_ELF_SHA256;
        programIds[0] = "realized-allocation-proof.v1";
        schemaHashes[0] = keccak256("realized-allocation-statement.v1");
        pvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        actives[0] = true;

        ids[1] = SYNTHETIC_TEST_VERIFIER_ID;
        adapters[1] = address(syntheticAdapter);
        vkeys[1] = FIXTURE_VKEY;
        elfHashes[1] = FIXTURE_ELF_SHA256;
        programIds[1] = "synthetic-test-verifier.v1";
        schemaHashes[1] = keccak256("synthetic-test-statement.v1");
        pvSchemas[1] = FIXTURE_PV_SCHEMA_HASH;
        actives[1] = true;

        bytes32 root = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds,
            schemaHashes, pvSchemas, actives
        );

        for (uint256 i = 0; i < 2; i++) {
            registry.registerVerifier(
                root, ids[i], adapters[i], vkeys[i], elfHashes[i],
                programIds[i], schemaHashes[i], pvSchemas[i]
            );
        }
        registry.sealRegistry(root);

        return root;
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
        bytes32 publicValuesDigest = sha256(publicValues);

        uint256 index = admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            statementRoot,
            "",
            publicValues,
            publicValuesDigest
        );
        assertEq(index, 0);
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

        bytes32[] memory r1Ids = new bytes32[](1);
        address[] memory r1Adapters = new address[](1);
        bytes32[] memory r1Vkeys = new bytes32[](1);
        bytes32[] memory r1ElfHashes = new bytes32[](1);
        string[] memory r1ProgramIds = new string[](1);
        bytes32[] memory r1SchemaHashes = new bytes32[](1);
        bytes32[] memory r1PvSchemas = new bytes32[](1);
        bool[] memory r1Actives = new bool[](1);

        r1Ids[0] = keccak256("verifier-r1-1");
        r1Adapters[0] = address(adapter);
        r1Vkeys[0] = FIXTURE_VKEY;
        r1ElfHashes[0] = FIXTURE_ELF_SHA256;
        r1ProgramIds[0] = "realized-allocation-proof.v1";
        r1SchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        r1PvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        r1Actives[0] = true;

        bytes32 registryRoot1 = registry.computeCanonicalRoot(
            r1Ids, r1Adapters, r1Vkeys, r1ElfHashes, r1ProgramIds, r1SchemaHashes, r1PvSchemas, r1Actives
        );

        for (uint256 i = 0; i < r1Ids.length; i++) {
            registry.registerVerifier(
                registryRoot1, r1Ids[i], r1Adapters[i], r1Vkeys[i],
                r1ElfHashes[i], r1ProgramIds[i], r1SchemaHashes[i], r1PvSchemas[i]
            );
        }
        registry.sealRegistry(registryRoot1);

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

        bytes32[] memory r2Ids = new bytes32[](1);
        address[] memory r2Adapters = new address[](1);
        bytes32[] memory r2Vkeys = new bytes32[](1);
        bytes32[] memory r2ElfHashes = new bytes32[](1);
        string[] memory r2ProgramIds = new string[](1);
        bytes32[] memory r2SchemaHashes = new bytes32[](1);
        bytes32[] memory r2PvSchemas = new bytes32[](1);
        bool[] memory r2Actives = new bool[](1);

        r2Ids[0] = keccak256("verifier-r2-1");
        r2Adapters[0] = address(adapter);
        r2Vkeys[0] = FIXTURE_VKEY;
        r2ElfHashes[0] = FIXTURE_ELF_SHA256;
        r2ProgramIds[0] = "realized-allocation-proof.v1";
        r2SchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        r2PvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        r2Actives[0] = true;

        bytes32 registryRoot2 = registry.computeCanonicalRoot(
            r2Ids, r2Adapters, r2Vkeys, r2ElfHashes, r2ProgramIds, r2SchemaHashes, r2PvSchemas, r2Actives
        );

        for (uint256 i = 0; i < r2Ids.length; i++) {
            registry.registerVerifier(
                registryRoot2, r2Ids[i], r2Adapters[i], r2Vkeys[i],
                r2ElfHashes[i], r2ProgramIds[i], r2SchemaHashes[i], r2PvSchemas[i]
            );
        }
        registry.sealRegistry(registryRoot2);

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
        bytes32[] memory r1Ids = new bytes32[](1);
        address[] memory r1Adapters = new address[](1);
        bytes32[] memory r1Vkeys = new bytes32[](1);
        bytes32[] memory r1ElfHashes = new bytes32[](1);
        string[] memory r1ProgramIds = new string[](1);
        bytes32[] memory r1SchemaHashes = new bytes32[](1);
        bytes32[] memory r1PvSchemas = new bytes32[](1);
        bool[] memory r1Actives = new bool[](1);

        r1Ids[0] = keccak256("verifier-unsealed-1");
        r1Adapters[0] = address(adapter);
        r1Vkeys[0] = FIXTURE_VKEY;
        r1ElfHashes[0] = FIXTURE_ELF_SHA256;
        r1ProgramIds[0] = "realized-allocation-proof.v1";
        r1SchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        r1PvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        r1Actives[0] = true;

        bytes32 unsealedRegistry = registry.computeCanonicalRoot(
            r1Ids, r1Adapters, r1Vkeys, r1ElfHashes, r1ProgramIds, r1SchemaHashes, r1PvSchemas, r1Actives
        );

        registry.registerVerifier(
            unsealedRegistry,
            r1Ids[0],
            r1Adapters[0],
            r1Vkeys[0],
            r1ElfHashes[0],
            r1ProgramIds[0],
            r1SchemaHashes[0],
            FIXTURE_PV_SCHEMA_HASH
        );

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
        bytes32 publicValuesDigest = sha256(publicValues);

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
            publicValues,
            publicValuesDigest
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
        bytes32 publicValuesDigest = sha256(publicValues);

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            wrongRoot,
            "",
            publicValues,
            publicValuesDigest
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
        bytes32 publicValuesDigest = sha256(shortPv);

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            shortPv,
            publicValuesDigest
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

        bytes32[] memory forgedIds = new bytes32[](1);
        address[] memory forgedAdapters = new address[](1);
        bytes32[] memory forgedVkeys = new bytes32[](1);
        bytes32[] memory forgedElfHashes = new bytes32[](1);
        string[] memory forgedProgramIds = new string[](1);
        bytes32[] memory forgedSchemaHashes = new bytes32[](1);
        bytes32[] memory forgedPvSchemas = new bytes32[](1);
        bool[] memory forgedActives = new bool[](1);

        forgedIds[0] = keccak256("attacker-verifier");
        forgedAdapters[0] = eoa;
        forgedVkeys[0] = FIXTURE_VKEY;
        forgedElfHashes[0] = FIXTURE_ELF_SHA256;
        forgedProgramIds[0] = "realized-allocation-proof.v1";
        forgedSchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        forgedPvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        forgedActives[0] = true;

        bytes32 attackerRoot = registry.computeCanonicalRoot(
            forgedIds, forgedAdapters, forgedVkeys, forgedElfHashes,
            forgedProgramIds, forgedSchemaHashes, forgedPvSchemas, forgedActives
        );

        registry.registerVerifier(
            attackerRoot,
            forgedIds[0],
            forgedAdapters[0],
            forgedVkeys[0],
            forgedElfHashes[0],
            forgedProgramIds[0],
            forgedSchemaHashes[0],
            FIXTURE_PV_SCHEMA_HASH
        );
        registry.sealRegistry(attackerRoot);

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
        bytes32 publicValuesDigest = sha256(publicValues);

        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector,
            CONFIG_ROOT_1,
            CONFIG_ROOT_0
        ));
        attackerAdmission.admitStatement(
            forgedIds[0],
            statementRoot,
            "",
            publicValues,
            publicValuesDigest
        );
    }

    function test_D1_FakeStoredRegistryRootWithRealEntriesRejects() public {
        bytes32[] memory r0Ids = new bytes32[](1);
        address[] memory r0Adapters = new address[](1);
        bytes32[] memory r0Vkeys = new bytes32[](1);
        bytes32[] memory r0ElfHashes = new bytes32[](1);
        string[] memory r0ProgramIds = new string[](1);
        bytes32[] memory r0SchemaHashes = new bytes32[](1);
        bytes32[] memory r0PvSchemas = new bytes32[](1);
        bool[] memory r0Actives = new bool[](1);

        r0Ids[0] = keccak256("fake-root-verifier");
        r0Adapters[0] = address(adapter);
        r0Vkeys[0] = FIXTURE_VKEY;
        r0ElfHashes[0] = FIXTURE_ELF_SHA256;
        r0ProgramIds[0] = "realized-allocation-proof.v1";
        r0SchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        r0PvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        r0Actives[0] = true;

        bytes32 realRoot = registry.computeCanonicalRoot(
            r0Ids, r0Adapters, r0Vkeys, r0ElfHashes, r0ProgramIds, r0SchemaHashes, r0PvSchemas, r0Actives
        );

        bytes32 fakeRoot = keccak256("fake-registry-root-not-canonical");

        registry.registerVerifier(
            fakeRoot,
            r0Ids[0],
            r0Adapters[0],
            r0Vkeys[0],
            r0ElfHashes[0],
            r0ProgramIds[0],
            r0SchemaHashes[0],
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
        bytes32[] memory modifiedIds = new bytes32[](1);
        address[] memory modifiedAdapters = new address[](1);
        bytes32[] memory modifiedVkeys = new bytes32[](1);
        bytes32[] memory modifiedElfHashes = new bytes32[](1);
        string[] memory modifiedProgramIds = new string[](1);
        bytes32[] memory modifiedSchemaHashes = new bytes32[](1);
        bytes32[] memory modifiedPvSchemas = new bytes32[](1);
        bool[] memory modifiedActives = new bool[](1);

        modifiedIds[0] = REALIZED_ALLOC_VERIFIER_ID;
        modifiedAdapters[0] = address(0xDEAD);
        modifiedVkeys[0] = FIXTURE_VKEY;
        modifiedElfHashes[0] = FIXTURE_ELF_SHA256;
        modifiedProgramIds[0] = "realized-allocation-proof.v1";
        modifiedSchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        modifiedPvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        modifiedActives[0] = true;

        bytes32 modifiedRoot = registry.computeCanonicalRoot(
            modifiedIds, modifiedAdapters, modifiedVkeys, modifiedElfHashes,
            modifiedProgramIds, modifiedSchemaHashes, modifiedPvSchemas, modifiedActives
        );

        assertGt(uint256(uint160(address(0xDEAD))), 0);
        assertEq(modifiedRoot != VERIFIER_REGISTRY_ROOT_0, true);
        assertEq(registry.canonicalRootMatches(VERIFIER_REGISTRY_ROOT_0), true);

        bytes32[] memory r0Ids = new bytes32[](2);
        address[] memory r0Adapters = new address[](2);
        bytes32[] memory r0Vkeys = new bytes32[](2);
        bytes32[] memory r0ElfHashes = new bytes32[](2);
        string[] memory r0ProgramIds = new string[](2);
        bytes32[] memory r0SchemaHashes = new bytes32[](2);
        bytes32[] memory r0PvSchemas = new bytes32[](2);
        bool[] memory r0Actives = new bool[](2);

        r0Ids[0] = REALIZED_ALLOC_VERIFIER_ID;
        r0Adapters[0] = address(adapter);
        r0Vkeys[0] = FIXTURE_VKEY;
        r0ElfHashes[0] = FIXTURE_ELF_SHA256;
        r0ProgramIds[0] = "realized-allocation-proof.v1";
        r0SchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        r0PvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        r0Actives[0] = true;

        r0Ids[1] = LEGACY_R0_ONLY_VERIFIER_ID;
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
        r0Adapters[1] = address(legacyAdapter);
        r0Vkeys[1] = FIXTURE_VKEY;
        r0ElfHashes[1] = FIXTURE_ELF_SHA256;
        r0ProgramIds[1] = "legacy-r0-only-proof.v1";
        r0SchemaHashes[1] = keccak256("legacy-r0-only-statement.v1");
        r0PvSchemas[1] = FIXTURE_PV_SCHEMA_HASH;
        r0Actives[1] = true;

        bytes32 realR0Root = registry.computeCanonicalRoot(
            r0Ids, r0Adapters, r0Vkeys, r0ElfHashes, r0ProgramIds, r0SchemaHashes, r0PvSchemas, r0Actives
        );

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
        bytes32[] memory emptyIds = new bytes32[](0);
        address[] memory emptyAddrs = new address[](0);
        bytes32[] memory emptyHashes = new bytes32[](0);
        string[] memory emptyStrings = new string[](0);
        bool[] memory emptyBools = new bool[](0);

        bytes32 emptyRoot = registry.computeCanonicalRoot(
            emptyIds, emptyAddrs, emptyHashes, emptyHashes, emptyStrings, emptyHashes, emptyHashes, emptyBools
        );

        registry.sealRegistry(emptyRoot);

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
        bytes32 publicValuesDigest = sha256(publicValues);

        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector,
            keccak256("forged-config-root"),
            CONFIG_ROOT_0
        ));
        wrongConfigAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            statementRoot,
            "",
            publicValues,
            publicValuesDigest
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
        bytes32 publicValuesDigest = sha256(publicValues);

        uint256 index = admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            statementRoot,
            "",
            publicValues,
            publicValuesDigest
        );
        assertEq(index, 0);
        assertEq(admission.admittedCount(), 1);
    }
}
