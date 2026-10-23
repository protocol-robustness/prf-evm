// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
import {PrfRealizedAllocationVerifierAdapter} from "../src/verification/adapters/PrfRealizedAllocationVerifierAdapter.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {IPrfVerifierRegistry} from "../src/interfaces/IPrfVerifierRegistry.sol";

/// @title PrfStatementAdmissionTest
/// @notice Tests the proof-admission path: realized-allocation-statement.v1
///         SP1 proof -> EVM verification -> statement admission.
///
///         Uses MockSP1Verifier configured with the real vkey and public values
///         from the realized-statement SP1 guest (mock Groth16 proof).
///         Public values are a fixed bytes32 (EVM projection), not JSON.
contract PrfStatementAdmissionTest is Test {
    bytes32 internal constant PROTOCOL_ROOT =
        0xd77429dd50bd7fe18d5f41d55e53ccbd4c67d18c4f00b266f86dbaede01f9343;
    bytes32 internal constant AUTHORITY_STATE_ROOT =
        0x150c28318e27fffacd9233c7ace128f7639f16c47d1c844e5440a07db39867cd;
    bytes32 internal constant CHAIN_INSTANCE_ROOT =
        0xf6c0f226998ebecb1123f78c2b30347d24c6e7ca2131f44f880b8a43c052cf86;

    bytes32 internal constant CONFIG_ROOT_0 =
        0xa3b808fa66ad9b9c4f35de5590ad95213cf0de76190db5980ced743f39f97f57;

    bytes32 internal constant VERIFIER_HASH = keccak256("SP1Groth16Verifier");

    bytes32 internal constant FIXTURE_VKEY =
        0x00b9325e81961e4b6dfbe6fa7806796a15c018116225c85f5ef0811afc331d3f;
    bytes32 internal constant FIXTURE_ELF_SHA256 =
        0xdeed502019f2cc920aa92e36e15d429c8ace7406cce925195709dc353b3e2495;

    bytes32 internal constant FIXTURE_STATEMENT_ROOT =
        0xc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81;

    bytes internal constant FIXTURE_PUBLIC_VALUES =
        hex"c22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81";

    bytes32 internal constant WRONG_STATEMENT_ROOT =
        0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;

    bytes32 internal constant REALIZED_ALLOC_VERIFIER_ID =
        keccak256("realized-allocation-statement.v1");
    bytes32 internal constant FIXTURE_PV_SCHEMA_HASH =
        keccak256("evm-bytes32-v1");

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    SewConfigurationExecutor internal executor;
    MockSP1Verifier internal sp1Mock;
    PrfRealizedAllocationVerifierAdapter internal adapter;
    PrfVerifierRegistry internal registry;
    PrfStatementAdmission internal admission;
    bytes32 internal VERIFIER_REGISTRY_ROOT_0;

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

        VERIFIER_REGISTRY_ROOT_0 = registry.computeCanonicalRoot(
            new bytes32[](1),
            new address[](1),
            new bytes32[](1),
            new bytes32[](1),
            new string[](1),
            new bytes32[](1),
            new bytes32[](1),
            new bool[](1)
        );

        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfHashes = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory schemaHashes = new bytes32[](1);
        bytes32[] memory pvSchemas = new bytes32[](1);
        bool[] memory actives = new bool[](1);

        ids[0] = REALIZED_ALLOC_VERIFIER_ID;
        adapters[0] = address(adapter);
        vkeys[0] = FIXTURE_VKEY;
        elfHashes[0] = FIXTURE_ELF_SHA256;
        programIds[0] = "realized-allocation-proof.v1";
        schemaHashes[0] = keccak256("realized-allocation-statement.v1");
        pvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        actives[0] = true;

        VERIFIER_REGISTRY_ROOT_0 = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds, schemaHashes, pvSchemas, actives
        );

        registry.registerVerifier(
            VERIFIER_REGISTRY_ROOT_0,
            REALIZED_ALLOC_VERIFIER_ID,
            address(adapter),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "realized-allocation-proof.v1",
            keccak256("realized-allocation-statement.v1"),
            FIXTURE_PV_SCHEMA_HASH
        );
        registry.sealRegistry(VERIFIER_REGISTRY_ROOT_0);

        executor = new SewConfigurationExecutor(
            genesis,
            authority,
            registry,
            VERIFIER_REGISTRY_ROOT_0
        );

        admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_0,
            0
        );
    }

    function test_AdmitStatement_Success() public {
        bytes32 receiptId = admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
        assertTrue(receiptId != bytes32(0));
        assertEq(admission.admittedCount(), 1);
    }

    function test_Constructor_RejectsConfigurationExecutorFromAnotherInstance() public {
        bytes32 otherInstance = keccak256("other-chain-instance");
        vm.mockCall(
            address(executor),
            abi.encodeWithSelector(bytes4(keccak256("chainInstanceGenesisRoot()"))),
            abi.encode(otherInstance)
        );
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationInstanceMismatch.selector,
            CHAIN_INSTANCE_ROOT,
            otherInstance
        ));
        new PrfStatementAdmission(genesis, executor, registry, CONFIG_ROOT_0, 0);
    }

    function test_Admission_RechecksConfigurationExecutorInstanceBinding() public {
        bytes32 otherInstance = keccak256("other-chain-instance");
        vm.mockCall(
            address(executor),
            abi.encodeWithSelector(bytes4(keccak256("chainInstanceGenesisRoot()"))),
            abi.encode(otherInstance)
        );
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationInstanceMismatch.selector,
            CHAIN_INSTANCE_ROOT,
            otherInstance
        ));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_ExtractStatementRoot_RealFixture() public {
        bytes32 root = adapter.extractStatementRoot(FIXTURE_PUBLIC_VALUES);
        assertEq(root, FIXTURE_STATEMENT_ROOT);
    }

    function test_AdmitStatement_UnknownVerifier_Reverts() public {
        bytes32 unknownId = keccak256("unknown-verifier");

        vm.expectRevert(abi.encodeWithSelector(
            IPrfVerifierRegistry.VerifierNotFound.selector,
            VERIFIER_REGISTRY_ROOT_0,
            unknownId
        ));
        admission.admitStatement(
            unknownId,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_AdmitStatement_WrongConfigRoot_Reverts() public {
        bytes32 newConfig = sha256(bytes("config-new"));

        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfHashes = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory schemaHashes = new bytes32[](1);
        bytes32[] memory pvSchemas = new bytes32[](1);
        bool[] memory actives = new bool[](1);

        ids[0] = keccak256("dummy-wrong-config");
        adapters[0] = address(this);
        vkeys[0] = FIXTURE_VKEY;
        elfHashes[0] = FIXTURE_ELF_SHA256;
        programIds[0] = "test-verifier.v1";
        schemaHashes[0] = keccak256("realized-allocation-statement.v1");
        pvSchemas[0] = FIXTURE_PV_SCHEMA_HASH;
        actives[0] = true;

        bytes32 newRegistry = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds, schemaHashes, pvSchemas, actives
        );

        registry.registerVerifier(
            newRegistry,
            ids[0],
            address(this),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "test-verifier.v1",
            keccak256("realized-allocation-statement.v1"),
            FIXTURE_PV_SCHEMA_HASH
        );
        registry.sealRegistry(newRegistry);

        bytes32 decisionRoot = sha256(bytes("decision-config-mismatch"));

        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            newConfig,
            VERIFIER_REGISTRY_ROOT_0,
            newRegistry,
            1
        );

        vm.startPrank(address(this));
        executor.applyConfiguration(
            decisionRoot,
            newConfig,
            newRegistry,
            1,
            0,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector,
            CONFIG_ROOT_0,
            newConfig
        ));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_AdmitStatement_WrongEpoch_Reverts() public {
        PrfStatementAdmission wrongEpochAdmission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_0,
            999
        );
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.EpochMismatch.selector,
            uint64(999),
            uint64(0)
        ));
        wrongEpochAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_AdmitStatement_ZeroStatementRoot_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ZeroRoot.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            bytes32(0),
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_AdmitStatement_TamperedPublicValues_Reverts() public {
        bytes memory tampered = new bytes(32);
        tampered[0] = 0xde;

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            tampered
        );
    }

    function test_AdmitStatement_MalformedPublicValues_Reverts() public {
        bytes memory shortPv = new bytes(16);

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            shortPv
        );
    }

    function test_AdmitStatement_WrongStatementRoot_Reverts() public {

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            WRONG_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_Adapter_VerifierIdentityHash_IncludesSchema() public {
        bytes32 expected = keccak256(abi.encodePacked(
            address(sp1Mock),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            keccak256("realized-allocation-statement.v1"),
            keccak256("evm-bytes32-v1")
        ));
        assertEq(adapter.verifierIdentityHash(), expected);
    }

    function test_Adapter_PublicValuesSchemaIsPinned() public {
        assertEq(adapter.publicValuesSchema(), keccak256("evm-bytes32-v1"));
        assertEq(adapter.statementSchemaVersion(), keccak256("realized-allocation-statement.v1"));
    }

    function test_Adapter_ExtractStatementRoot_ValidatesSchema() public {
        bytes32 root = adapter.extractStatementRoot(FIXTURE_PUBLIC_VALUES);
        assertEq(root, FIXTURE_STATEMENT_ROOT);
    }

    function test_Adapter_ExtractStatementRoot_RejectsShortPublicValues() public {
        bytes memory shortPv = new bytes(16);
        vm.expectRevert(abi.encodeWithSelector(
            PrfRealizedAllocationVerifierAdapter.InvalidPublicValuesLength.selector,
            uint256(16)
        ));
        adapter.extractStatementRoot(shortPv);
    }

    function test_Adapter_ExtractStatementRoot_RejectsLongPublicValues() public {
        bytes memory longPv = new bytes(64);
        vm.expectRevert(abi.encodeWithSelector(
            PrfRealizedAllocationVerifierAdapter.InvalidPublicValuesLength.selector,
            uint256(64)
        ));
        adapter.extractStatementRoot(longPv);
    }

    function test_CanonicalRootMatchesRegistry() public {
        assertTrue(registry.canonicalRootMatches(VERIFIER_REGISTRY_ROOT_0));
    }

    function test_Adversarial_SameProof_DifferentSchemaIdentity_CannotReused() public {
        PrfRealizedAllocationVerifierAdapter wrongSchemaAdapter =
            new PrfRealizedAllocationVerifierAdapter(
                sp1Mock,
                FIXTURE_VKEY,
                FIXTURE_ELF_SHA256,
                "realized-allocation-statement.v1",
                "evm-bytes64-v1"
            );

        assertEq(adapter.publicValuesSchema(), keccak256("evm-bytes32-v1"));
        assertEq(wrongSchemaAdapter.publicValuesSchema(), keccak256("evm-bytes64-v1"));

        bytes32 correctIdentityHash = keccak256(abi.encodePacked(
            address(sp1Mock),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            keccak256("realized-allocation-statement.v1"),
            keccak256("evm-bytes32-v1")
        ));
        bytes32 wrongIdentityHash = keccak256(abi.encodePacked(
            address(sp1Mock),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            keccak256("realized-allocation-statement.v1"),
            keccak256("evm-bytes64-v1")
        ));

        assertEq(adapter.verifierIdentityHash(), correctIdentityHash);
        assertEq(wrongSchemaAdapter.verifierIdentityHash(), wrongIdentityHash);
        assertTrue(correctIdentityHash != wrongIdentityHash);

        // Same verifierId, same vkey/elf/SP1 verifier, different public-values schema.
        bytes32[] memory wIds = new bytes32[](1);
        address[] memory wAdapters = new address[](1);
        bytes32[] memory wVkeys = new bytes32[](1);
        bytes32[] memory wElfHashes = new bytes32[](1);
        string[] memory wProgramIds = new string[](1);
        bytes32[] memory wSchemaHashes = new bytes32[](1);
        bytes32[] memory wPvSchemas = new bytes32[](1);
        bool[] memory wActives = new bool[](1);

        wIds[0] = REALIZED_ALLOC_VERIFIER_ID;
        wAdapters[0] = address(wrongSchemaAdapter);
        wVkeys[0] = FIXTURE_VKEY;
        wElfHashes[0] = FIXTURE_ELF_SHA256;
        wProgramIds[0] = "realized-allocation-proof.v1";
        wSchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        wPvSchemas[0] = keccak256("evm-bytes64-v1");
        wActives[0] = true;

        bytes32 wrongRegistryRoot = registry.computeCanonicalRoot(
            wIds, wAdapters, wVkeys, wElfHashes, wProgramIds,
            wSchemaHashes, wPvSchemas, wActives
        );

        assertTrue(wrongRegistryRoot != VERIFIER_REGISTRY_ROOT_0);

        registry.registerVerifier(
            wrongRegistryRoot, wIds[0], wAdapters[0], wVkeys[0],
            wElfHashes[0], wProgramIds[0], wSchemaHashes[0], wPvSchemas[0]
        );
        registry.sealRegistry(wrongRegistryRoot);
        assertTrue(registry.isSealed(wrongRegistryRoot));
        assertTrue(registry.canonicalRootMatches(wrongRegistryRoot));

        SewConfigurationExecutor wrongRegistryExecutor = new SewConfigurationExecutor(
            genesis, authority, registry, wrongRegistryRoot
        );

        PrfStatementAdmission wrongSchemaAdmission = new PrfStatementAdmission(
            genesis, wrongRegistryExecutor, registry,
            CONFIG_ROOT_0, 0
        );

        // The proof/public-values are valid for schema A (32-byte PV), but the
        // active adapter under the wrong registry expects schema B (64-byte PV).
        vm.expectRevert(PrfStatementAdmission.ProofVerificationFailed.selector);
        wrongSchemaAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function test_Adversarial_SameWidthSchemaReplay_RejectedByConfigBinding() public {
        PrfRealizedAllocationVerifierAdapter wrongSemAdapter =
            new PrfRealizedAllocationVerifierAdapter(
                sp1Mock,
                FIXTURE_VKEY,
                FIXTURE_ELF_SHA256,
                "realized-allocation-statement.v1",
                "evm-bytes32-v2"
            );

        assertEq(adapter.publicValuesSchema(), keccak256("evm-bytes32-v1"));
        assertEq(wrongSemAdapter.publicValuesSchema(), keccak256("evm-bytes32-v2"));
        assertTrue(adapter.publicValuesSchema() != wrongSemAdapter.publicValuesSchema());

        // Both adapters use the same SP1 verifier, vkey, ELF, statement schema.
        // Only the public-values schema string differs, at identical 32-byte width.
        assertTrue(adapter.verifierIdentityHash() != wrongSemAdapter.verifierIdentityHash());

        bytes32[] memory wIds = new bytes32[](1);
        address[] memory wAdapters = new address[](1);
        bytes32[] memory wVkeys = new bytes32[](1);
        bytes32[] memory wElfHashes = new bytes32[](1);
        string[] memory wProgramIds = new string[](1);
        bytes32[] memory wSchemaHashes = new bytes32[](1);
        bytes32[] memory wPvSchemas = new bytes32[](1);
        bool[] memory wActives = new bool[](1);

        wIds[0] = REALIZED_ALLOC_VERIFIER_ID;
        wAdapters[0] = address(wrongSemAdapter);
        wVkeys[0] = FIXTURE_VKEY;
        wElfHashes[0] = FIXTURE_ELF_SHA256;
        wProgramIds[0] = "realized-allocation-proof.v1";
        wSchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        wPvSchemas[0] = keccak256("evm-bytes32-v2");
        wActives[0] = true;

        bytes32 semRegistryRoot = registry.computeCanonicalRoot(
            wIds, wAdapters, wVkeys, wElfHashes, wProgramIds,
            wSchemaHashes, wPvSchemas, wActives
        );

        assertTrue(semRegistryRoot != VERIFIER_REGISTRY_ROOT_0);

        registry.registerVerifier(
            semRegistryRoot, wIds[0], wAdapters[0], wVkeys[0],
            wElfHashes[0], wProgramIds[0], wSchemaHashes[0], wPvSchemas[0]
        );
        registry.sealRegistry(semRegistryRoot);
        assertTrue(registry.canonicalRootMatches(semRegistryRoot));

        // The existing (v1-bound) admission is NOT affected by the v2 registry.
        assertFalse(registry.isSealed(VERIFIER_REGISTRY_ROOT_0) == false);

        SewConfigurationExecutor semExecutor = new SewConfigurationExecutor(
            genesis, authority, registry, semRegistryRoot
        );
        PrfStatementAdmission semAdmission = new PrfStatementAdmission(
            genesis, semExecutor, registry,
            CONFIG_ROOT_0, 0
        );

        // The v2 adapter rejects the 32-byte PV because its pinned schema is v2,
        // not v1. The admission catches this and reverts ProofVerificationFailed.
        vm.expectRevert(PrfStatementAdmission.ProofVerificationFailed.selector);
        semAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }
}
