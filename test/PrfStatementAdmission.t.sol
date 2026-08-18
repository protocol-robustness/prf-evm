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
///         from the realized-statement SP1 guest.
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

    bytes32 internal constant FIXTURE_VKEY =
        0x00bf7b7a6e763c20322fbe237c9e2939f943df111ddbfa9c57f522f1add55ce2;
    bytes32 internal constant FIXTURE_ELF_SHA256 =
        0x8500a9db5819733eb06129290b1ac4a54ca149e3a5a2ed7444b34b7b26f59b64;
    bytes32 internal constant FIXTURE_STATEMENT_ROOT =
        0xc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81;

    bytes internal constant FIXTURE_PUBLIC_VALUES = hex"7b22616c6c2d616374697665223a747275652c22616c6c6f636174696f6e2d636f6e746578742d726f6f74223a2235313535646534646535386635356331343337643532643833316364336337343765656133306538343535633361373934356463373135613639303761306235222c22616c6c6f636174696f6e2d706f6c6963792d726f6f74223a2237393833393964373530343735353339626235313836353731323131303463336334646465613933346362306436316330343436393966363637316236346362222c226661696c2d616374696f6e2d706f6c6963792d726f6f74223a22313066663932336530353137633265316466626262323038393436666530383334613839393232373365626439383363326332636435393635386330386537222c227265616c697a65642d726573756c74732d726f6f74223a2266306261396465383361363931363030633733646530646464653466386431616236373362613439343261376333343063373832613561333530323738623833222c22726571756573742d7365742d726f6f74223a2239633439356533376539383434303335626435323733646163333036383262666239393239336331663338303033346136393130376538373635303736313134222c22726573756c742f737461747573223a2270617373696e67222c22726f756e642d6c6966656379636c652d726f6f74223a2231653764343137393363653432346633396532623261666338336462623563353238636464393661373436643061343839343966316462353834356234613461222c22736368656d612d76657273696f6e223a227265616c697a65642d616c6c6f636174696f6e2d73746174656d656e742e7631222c2273746174656d656e742d726f6f74223a2263323233333361313664663163316566613335326539646161623432636362643738663461316437353330656533656433636637353237626136326362643831227d";

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
        PV_DIGEST = sha256(FIXTURE_PUBLIC_VALUES);

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
        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.ProofVerificationFailed.selector));
        admission.admitStatement(
            WRONG_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
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

        vm.expectRevert(abi.encodeWithSelector(PrfStatementAdmission.NoVerifiersRegistered.selector));
        admission.admitStatement(
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES,
            PV_DIGEST
        );
    }

    /// @notice Negative: tampered public values → ProofVerificationFailed
    ///         (mock SP1 verifier commitment mismatch is caught by try/catch).
    function test_AdmitStatement_TamperedPublicValues_Reverts() public {
        bytes memory tampered = hex"0000deadbeef";
        bytes32 tamperedDigest = sha256(tampered);

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
    ///         The wrong adapter pins wrongVkey; the mock was configured for FIXTURE_VKEY.
    ///         When admitStatement calls the wrong adapter, the mock verifier commitment
    ///         fails (keccak256(proof || wrongVkey || pubValues) ≠ commitment), and
    ///         the try/catch converts it to ProofVerificationFailed.
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
