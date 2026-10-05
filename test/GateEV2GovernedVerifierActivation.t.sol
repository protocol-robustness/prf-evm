// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {SP1Verifier} from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
import {PrfSourceBoundStatementVerifierAdapterV2} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";
import {IPrfVerifierRegistry} from "../src/interfaces/IPrfVerifierRegistry.sol";

/// @notice V2 governed verifier activation for the source-bound shortfall program.
///
/// This exercises the exact governed transition that the deployed local V2
/// topology has NOT yet performed (its `SewConfigurationExecutor` still points at
/// placeholder roots `0x3333…`/`0x4444…`, its `PrfVerifierRegistry` is empty and
/// unsealed, and its `PrfStatementAdmission` was constructed for config epoch 0).
///
/// It uses the canonical source-bound V2 program identity — the same VKey/ELF
/// that is pinned in the deployed adapter and in
/// `fixtures/source-bound-v2-identity.json`:
///
///   VKey 0x0089abceac18acb8d0686b81ea542b933339353807924bc021a9fe3820888127
///   ELF  0x1994d8b67004de3d5dfffc176434ae63f3d7ac32ae875d72093943ff8e82247b
///   SP1 release 6.3.1 / sp1-contracts v6.1.0 / Groth16
///
/// Because `applyConfiguration` forces `nextEpoch == currentEpoch + 1` and the
/// deployed `PrfStatementAdmission` holds epoch 0 as an immutable binding, a real
/// activation must (a) transition the executor to the sealed registry at epoch 1
/// and (b) instantiate a fresh `PrfStatementAdmission` bound to the post-transition
/// configuration. This test performs both steps and asserts the resulting topology.
///
/// The final real-proof admission step is intentionally gated: it can only pass
/// once an SP1 proof generated from the canonical program (source-bound-v2,
/// SP1 6.3.1) exists. No matching proof fixture is currently committed, so this
/// test documents that boundary rather than fabricating closure. See
/// `PrfStatementAdmissionRealProof.t.sol` for a passing real-Groth16 admission
/// path on the realized-allocation program.
contract GateEV2GovernedVerifierActivationTest is Test {
    // --- Canonical source-bound V2 program identity (fixtures/source-bound-v2-identity.json) ---
    bytes32 internal constant V2_VKEY =
        0x0089abceac18acb8d0686b81ea542b933339353807924bc021a9fe3820888127;
    bytes32 internal constant V2_ELF_SHA256 =
        0x1994d8b67004de3d5dfffc176434ae63f3d7ac32ae875d72093943ff8e82247b;

    bytes32 internal constant V2_VERIFIER_ID = keccak256("source-bound-shortfall.v2");
    string internal constant V2_PROGRAM_ID = "source-bound-v2-sp1-program.v2";

    // --- Coherent local configuration lineage (mirrors PrfStatementAdmissionRealProof) ---
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

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    PrfVerifierRegistry internal registry;
    SewConfigurationExecutor internal executor;
    SP1Verifier internal sp1Groth16;
    PrfSourceBoundStatementVerifierAdapterV2 internal sourceAdapter;

    bytes32 internal REGISTRY_ROOT_0;
    bytes32 internal REGISTRY_ROOT_1;

    function setUp() public {
        authority = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT, address(this), AUTHORITY_STATE_ROOT
        );
        genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT, block.chainid, 1, address(authority), AUTHORITY_STATE_ROOT,
            CONFIG_ROOT_0, address(this)
        );
        genesis.sealGenesis(CHAIN_INSTANCE_ROOT, address(genesis).codehash, address(authority).codehash);

        registry = new PrfVerifierRegistry(address(this));
        sp1Groth16 = new SP1Verifier();
        sourceAdapter = new PrfSourceBoundStatementVerifierAdapterV2(
            ISP1Verifier(address(sp1Groth16)), V2_VKEY, V2_ELF_SHA256
        );

        // Single real V2 adapter entry -> canonical R1.
        bytes32[] memory ids = new bytes32[](1);
        address[] memory addrs = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfs = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory schemas = new bytes32[](1);
        bytes32[] memory pvSchemas = new bytes32[](1);
        bool[] memory actives = new bool[](1);
        ids[0] = V2_VERIFIER_ID;
        addrs[0] = address(sourceAdapter);
        vkeys[0] = sourceAdapter.programVKey();
        elfs[0] = sourceAdapter.programElfSha256();
        programIds[0] = V2_PROGRAM_ID;
        schemas[0] = sourceAdapter.statementSchemaVersion();
        pvSchemas[0] = sourceAdapter.publicValuesSchema();
        actives[0] = true;

        REGISTRY_ROOT_1 = registry.computeCanonicalRoot(ids, addrs, vkeys, elfs, programIds, schemas, pvSchemas, actives);

        // Empty registry -> canonical R0 (parent snapshot used by executor at epoch 0).
        bytes32[] memory emptyIds = new bytes32[](0);
        address[] memory emptyAddrs = new address[](0);
        bytes32[] memory emptyWords = new bytes32[](0);
        string[] memory emptyStrings = new string[](0);
        bool[] memory emptyBools = new bool[](0);
        REGISTRY_ROOT_0 = registry.computeCanonicalRoot(emptyIds, emptyAddrs, emptyWords, emptyWords, emptyStrings, emptyWords, emptyWords, emptyBools);

        registry.sealRegistry(REGISTRY_ROOT_0);
        registry.registerVerifier(REGISTRY_ROOT_1, ids[0], addrs[0], vkeys[0], elfs[0], programIds[0], schemas[0], pvSchemas[0]);
        registry.sealRegistry(REGISTRY_ROOT_1);

        executor = new SewConfigurationExecutor(genesis, authority, registry, REGISTRY_ROOT_0);
    }

    // ------------------------------------------------------------------
    // Positive: the governed transition activates the real V2 verifier.
    // ------------------------------------------------------------------
    function test_V2GovernedActivation_RegistersSealsAndSelectsRealAdapter() public {
        assertEq(executor.currentVerifierRegistryRoot(), REGISTRY_ROOT_0, "epoch0 root");
        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_0, "epoch0 config");
        assertEq(executor.currentEpoch(), 0, "epoch0");

        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            REGISTRY_ROOT_0,
            REGISTRY_ROOT_1,
            1
        );
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        assertEq(executor.currentVerifierRegistryRoot(), REGISTRY_ROOT_1, "activated registry root");
        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_1, "activated config root");
        assertEq(executor.currentEpoch(), 1, "activated epoch");

        assertTrue(registry.isSealed(REGISTRY_ROOT_1), "R1 sealed");
        IPrfVerifierRegistry.VerifierEntry memory entry = registry.getVerifier(REGISTRY_ROOT_1, V2_VERIFIER_ID);
        assertEq(entry.adapter, address(sourceAdapter), "registered adapter");
        assertEq(entry.programVKey, V2_VKEY, "registered vkey");
        assertEq(entry.programElfSha256, V2_ELF_SHA256, "registered elf");
        assertTrue(entry.active, "registered active");
    }

    // ------------------------------------------------------------------
    // Negative: activation cannot skip the governing authorization.
    // ------------------------------------------------------------------
    function test_V2GovernedActivation_UnauthorizedTransitionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionNotAuthorised.selector, DECISION_ROOT
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    // ------------------------------------------------------------------
    // Negative: proxy the deployed binding mismatch — a governed transition
    // changes the epoch, so an admission bound to epoch 0 must be re-instantiated.
    // ------------------------------------------------------------------
    function test_V2Admission_MustBeBoundToPostTransitionConfig() public {
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            REGISTRY_ROOT_0,
            REGISTRY_ROOT_1,
            1
        );
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            REGISTRY_ROOT_1,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        // An admission still bound to epoch 0 (the deployed topology's binding)
        // must reject the post-transition executor state.
        PrfStatementAdmission staleAdmission = new PrfStatementAdmission(
            genesis, executor, registry, CONFIG_ROOT_0, 0
        );
        bytes32 fakeStatementRoot = keccak256("not-reached");
        vm.expectRevert(abi.encodeWithSelector(
            PrfStatementAdmission.ConfigurationMismatch.selector, CONFIG_ROOT_0, CONFIG_ROOT_1
        ));
        staleAdmission.admitStatement(V2_VERIFIER_ID, fakeStatementRoot, new bytes(0), new bytes(192));

        // A fresh admission bound to the post-transition config is the correct
        // successor and resolves the real sealed adapter.
        PrfStatementAdmission freshAdmission = new PrfStatementAdmission(
            genesis, executor, registry, CONFIG_ROOT_1, 1
        );
        assertEq(freshAdmission.expectedConfigurationRoot(), CONFIG_ROOT_1);
        assertEq(freshAdmission.expectedConfigurationEpoch(), 1);
        assertEq(address(freshAdmission.verifierRegistry()), address(registry));
        // It reads the activated registry root from the executor.
        assertTrue(registry.isSealed(REGISTRY_ROOT_1));
    }
}
