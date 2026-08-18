// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {PrfRealizedAllocationVerifierAdapter} from "../src/PrfRealizedAllocationVerifierAdapter.sol";
import {PrfVerifierRegistry} from "../src/PrfVerifierRegistry.sol";
import {PrfStatementAdmission} from "../src/PrfStatementAdmission.sol";
import {MockSP1Verifier} from "../src/MockSP1Verifier.sol";

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
    bytes32 internal constant CONFIG_ROOT_0 = sha256(bytes("configuration-0"));
    bytes32 internal constant CONFIG_ROOT_1 = sha256(bytes("configuration-1"));

    bytes32 internal constant VERIFIER_HASH = keccak256("SP1Groth16Verifier");

    // From realized-statement-proof-fixture.json (regenerated with bytes32 PV).
    bytes32 internal constant FIXTURE_VKEY =
        0x00b9325e81961e4b6dfbe6fa7806796a15c018116225c85f5ef0811afc331d3f;
    bytes32 internal constant FIXTURE_ELF_SHA256 =
        0xdeed502019f2cc920aa92e36e15d429c8ace7406cce925195709dc353b3e2495;
    bytes32 internal constant FIXTURE_STATEMENT_ROOT =
        0xc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81;

    // Public values are a fixed bytes32 (EVM projection), not UTF-8 JSON.
    bytes internal constant FIXTURE_PUBLIC_VALUES =
        hex"c22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81";

    bytes32 internal constant WRONG_STATEMENT_ROOT =
        0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef;

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    SewConfigurationExecutor internal executor;
    MockSP1Verifier internal sp1Mock;
    PrfRealizedAllocationVerifierAdapter internal adapter;
    PrfVerifierRegistry internal registry;
    PrfStatementAdmission internal admission;

    bytes32 internal PV_DIGEST;

    function setUp() public {
        // Public values digest: sha256(bytes32) = sha256(32-byte root)
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

        executor = new SewConfigurationExecutor(genesis, authority);

        bytes32 commitment = keccak256(abi.encodePacked(FIXTURE_VKEY, FIXTURE_PUBLIC_VALUES));
        sp1Mock = new MockSP1Verifier(commitment, VERIFIER_HASH);

        adapter = new PrfRealizedAllocationVerifierAdapter(
            sp1Mock,
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256
        );

        registry = new PrfVerifierRegistry(genesis, authority);
        registry.addVerifier(
            address(adapter),
            FIXTURE_VKEY,
            FIXTURE_ELF_SHA256,
            "realized-allocation-proof.v1",
            keccak256("realized-allocation-statement.v1")
        );

        admission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            CONFIG_ROOT_0
        );
    }

    /// @notice Positive: valid SP1 proof with correct statement root is admitted.
    function test_AdmitStatement_Success() public {
        uint256 index = admission.admitStatement(
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
        assertEq(index, 0);
        assertEq(admission.admittedCount(), 1);
    }

    /// @notice The extracted statement root from the public values matches
    ///         the canonical statement root.
    function test_ExtractStatementRoot_RealFixture() public {
        bytes32 root = adapter.extractStatementRoot(FIXTURE_PUBLIC_VALUES);
        assertEq(root, FIXTURE_STATEMENT_ROOT);
    }

    /// @notice Negative: wrong statement root → caught by try/catch → ProofVerificationFailed.
    function test_AdmitStatement_WrongStatementRoot_Reverts() public {
        bytes32 wrongPvDigest = sha256(abi.encodePacked(FIXTURE_PUBLIC_VALUES));

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            WRONG_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            wrongPvDigest
        );
    }

    /// @notice Negative: configuration root mismatch.
    function test_AdmitStatement_WrongConfigRoot_Reverts() public {
        bytes32 decisionRoot = sha256(bytes("decision-config-mismatch"));
        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            1
        );
        executor.applyConfiguration(
            decisionRoot,
            CONFIG_ROOT_1,
            1,
            0,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PrfStatementAdmission.ConfigurationMismatch.selector,
                CONFIG_ROOT_0,
                CONFIG_ROOT_1
            )
        );
        admission.admitStatement(
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
    }

    /// @notice Negative: verifier deactivated → NoVerifiersRegistered.
    function test_AdmitStatement_InactiveVerifier_Reverts() public {
        registry.deactivateVerifier(0);

        bytes32 pvDigest = sha256(abi.encodePacked(FIXTURE_PUBLIC_VALUES));
        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.NoVerifiersRegistered.selector));
        admission.admitStatement(
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            pvDigest
        );
    }

    /// @notice Negative: tampered public values → ProofVerificationFailed
    ///         (mock SP1 verifier commitment mismatch is caught by try/catch).
    function test_AdmitStatement_TamperedPublicValues_Reverts() public {
        bytes memory tampered = new bytes(32);
        tampered[0] = 0xde;
        bytes32 tamperedDigest = sha256(abi.encodePacked(tampered));

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            FIXTURE_STATEMENT_ROOT,
            "",
            tampered,
            tamperedDigest
        );
    }

    /// @notice Negative: zero statement root → ZeroRoot.
    function test_AdmitStatement_ZeroStatementRoot_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ZeroRoot.selector));
        admission.admitStatement(
            bytes32(0),
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
    }

    /// @notice Negative: wrong program vkey in adapter.
    ///         The wrong adapter pins wrongVkey; the mock was configured for
    ///         FIXTURE_VKEY. When admitStatement calls the wrong adapter, the
    ///         mock verifier commitment fails, and the try/catch converts it
    ///         to ProofVerificationFailed.
    function test_AdmitStatement_WrongProgramVKey_Reverts() public {
        bytes32 wrongVkey = keccak256("wrong-program-vkey");

        PrfRealizedAllocationVerifierAdapter wrongAdapter =
            new PrfRealizedAllocationVerifierAdapter(
                sp1Mock,
                wrongVkey,
                FIXTURE_ELF_SHA256
            );

        registry.deactivateVerifier(0);
        registry.addVerifier(
            address(wrongAdapter),
            wrongVkey,
            FIXTURE_ELF_SHA256,
            "realized-allocation-proof.v1",
            keccak256("realized-allocation-statement.v1")
        );

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
    }
}
