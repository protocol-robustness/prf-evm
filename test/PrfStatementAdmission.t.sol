// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {PrfRealizedAllocationVerifierAdapter} from "../src/PrfRealizedAllocationVerifierAdapter.sol";
import {MockSP1Verifier} from "../src/MockSP1Verifier.sol";
import {PrfVerifierRegistry} from "../src/PrfVerifierRegistry.sol";
import {PrfStatementAdmission} from "../src/PrfStatementAdmission.sol";
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

    bytes32 internal PV_DIGEST;

    function setUp() public {
        PV_DIGEST = sha256(abi.encodePacked(FIXTURE_PUBLIC_VALUES));

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
        uint256 index = admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
        assertEq(index, 0);
        assertEq(admission.admittedCount(), 1);
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
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
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

        bytes32 pvDigest = sha256(abi.encodePacked(FIXTURE_PUBLIC_VALUES));
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector,
            CONFIG_ROOT_0,
            newConfig
        ));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            pvDigest
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

        bytes32 pvDigest = sha256(abi.encodePacked(FIXTURE_PUBLIC_VALUES));
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.EpochMismatch.selector,
            uint64(999),
            uint64(0)
        ));
        wrongEpochAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            pvDigest
        );
    }

    function test_AdmitStatement_ZeroStatementRoot_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ZeroRoot.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            bytes32(0),
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
    }

    function test_AdmitStatement_TamperedPublicValues_Reverts() public {
        bytes memory tampered = new bytes(32);
        tampered[0] = 0xde;
        bytes32 tamperedDigest = sha256(abi.encodePacked(tampered));

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            tampered,
            tamperedDigest
        );
    }

    function test_AdmitStatement_MalformedPublicValues_Reverts() public {
        bytes memory shortPv = new bytes(16);
        bytes32 shortDigest = sha256(shortPv);

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            shortPv,
            shortDigest
        );
    }

    function test_AdmitStatement_WrongStatementRoot_Reverts() public {
        bytes32 wrongPvDigest = sha256(abi.encodePacked(FIXTURE_PUBLIC_VALUES));

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            WRONG_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            wrongPvDigest
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

        bytes32[] memory r0Ids = new bytes32[](1);
        address[] memory r0Adapters = new address[](1);
        bytes32[] memory r0Vkeys = new bytes32[](1);
        bytes32[] memory r0ElfHashes = new bytes32[](1);
        string[] memory r0ProgramIds = new string[](1);
        bytes32[] memory r0SchemaHashes = new bytes32[](1);
        bytes32[] memory r0PvSchemas = new bytes32[](1);
        bool[] memory r0Actives = new bool[](1);

        r0Ids[0] = REALIZED_ALLOC_VERIFIER_ID;
        r0Adapters[0] = address(wrongSchemaAdapter);
        r0Vkeys[0] = FIXTURE_VKEY;
        r0ElfHashes[0] = FIXTURE_ELF_SHA256;
        r0ProgramIds[0] = "realized-allocation-proof.v1";
        r0SchemaHashes[0] = keccak256("realized-allocation-statement.v1");
        r0PvSchemas[0] = keccak256("evm-bytes64-v1");
        r0Actives[0] = true;

        bytes32 wrongRegistryRoot = registry.computeCanonicalRoot(
            r0Ids, r0Adapters, r0Vkeys, r0ElfHashes, r0ProgramIds,
            r0SchemaHashes, r0PvSchemas, r0Actives
        );

        assertTrue(wrongRegistryRoot != VERIFIER_REGISTRY_ROOT_0);
        assertTrue(!registry.isSealed(wrongRegistryRoot));
    }
}
