// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {
    PrfSourceBoundStatementVerifierAdapterV2
} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {SourceBoundProRataAssuranceV2} from "../src/applications/shortfall/SourceBoundProRataAssuranceV2.sol";
import {
    SourceBoundProRataRatificationControllerV2
} from "../src/applications/shortfall/SourceBoundProRataRatificationControllerV2.sol";
import {ISourceBoundProRataAssuranceV2} from "../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IOnchainShortfallReserveV2} from "../src/interfaces/IOnchainShortfallReserveV2.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {MockEntitlementProofModeSource} from "./mocks/MockEntitlementProofModeSource.sol";
import {V2RatificationReserveMock} from "./mocks/V2RatificationReserveMock.sol";

contract AssuranceV2TokenMock is ERC20 {
    constructor() ERC20("V2 Integration", "V2I") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AssuranceV2VerifierMock is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

contract AssuranceV2AdmissionMock is IPrfStatementAdmission {
    mapping(bytes32 => AdmissionReceipt) private receipts;

    function setReceipt(bytes32 id, AdmissionReceipt calldata receipt) external {
        receipts[id] = receipt;
    }

    function admissionReceipt(bytes32 id) external view returns (AdmissionReceipt memory) {
        return receipts[id];
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function protocolGenesisRoot() external pure returns (bytes32) {
        return bytes32(0);
    }

    function chainInstanceGenesisRoot() external pure returns (bytes32) {
        return bytes32(0);
    }

    function expectedConfigurationRoot() external pure returns (bytes32) {
        return bytes32(0);
    }

    function expectedConfigurationEpoch() external pure returns (uint64) {
        return 0;
    }

    function admittedCount() external pure returns (uint256) {
        return 0;
    }

    function admitStatement(bytes32, bytes32, bytes calldata, bytes calldata) external pure returns (bytes32) {
        revert("NOT_IN_FIXTURE");
    }
}

contract AssuranceV2CallerMock {
    function consume(
        SourceBoundProRataAssuranceV2 assurance,
        bytes32 operationId,
        bytes32 preparedRoot,
        bytes32 commitment
    ) external returns (ISourceBoundProRataAssuranceV2.RatificationPayload memory) {
        return assurance.consumeForRatification(operationId, preparedRoot, commitment);
    }
}

contract SourceBoundProRataAssuranceV2Test is Test {
    bytes32 constant OPERATION = keccak256("assurance-v2-operation");
    bytes32 constant RECEIPT = keccak256("assurance-v2-receipt");
    bytes32 constant ALLOCATION = keccak256("assurance-v2-allocation");
    bytes32 constant REALIZED = keccak256("assurance-v2-realized");

    AssuranceV2AdmissionMock admission;
    AssuranceV2VerifierMock verifier;
    PrfSourceBoundStatementVerifierAdapterV2 adapter;
    SourceBoundProRataControllerV2 preparedController;
    SourceBoundProRataAssuranceV2 assurance;
    AssuranceV2CallerMock controller;
    bytes32 preparedRoot;
    bytes32 commitment = keccak256("assurance-v2-commitment");
    bytes32 publicValues;
    bytes publicValuesBytes;

    struct IntegratedFixture {
        SourceBoundProRataControllerV2 prepared;
        SourceBoundProRataAssuranceV2 assurance;
        SourceBoundProRataRatificationControllerV2 ratification;
        bytes32 operationId;
        bytes32 preparedRoot;
        bytes32 receiptId;
    }

    function setUp() public {
        admission = new AssuranceV2AdmissionMock();
        verifier = new AssuranceV2VerifierMock();
        adapter = new PrfSourceBoundStatementVerifierAdapterV2(verifier, keccak256("v2-vkey"), keccak256("v2-elf"));
        preparedController = new SourceBoundProRataControllerV2();
        assurance = new SourceBoundProRataAssuranceV2(admission, adapter, preparedController, address(this));
        controller = new AssuranceV2CallerMock();

        ShortfallV2Commitments.PreparedOperation memory operation = _operation(address(this));
        preparedRoot = ShortfallV2Commitments.preparedOperationRoot(operation);
        vm.prank(address(this));
        preparedController.prepareOperation(operation);
        assurance.bindRatificationController(address(controller));

        publicValuesBytes =
            abi.encode(adapter.PUBLIC_VALUES_DOMAIN(), preparedRoot, commitment, ALLOCATION, REALIZED, OPERATION);
        admission.setReceipt(
            RECEIPT,
            IPrfStatementAdmission.AdmissionReceipt({
                exists: true,
                protocolGenesisRoot: bytes32(0),
                chainInstanceGenesisRoot: bytes32(0),
                configurationRoot: bytes32(0),
                configurationEpoch: 0,
                verifierRegistryRoot: bytes32(0),
                verifierId: keccak256("source-bound-v2"),
                verifierAdapter: address(adapter),
                programVKey: adapter.programVKey(),
                programElfSha256: adapter.programElfSha256(),
                statementSchemaVersionHash: adapter.statementSchemaVersion(),
                publicValuesSchema: adapter.publicValuesSchema(),
                statementRoot: ALLOCATION,
                publicValuesDigest: sha256(publicValuesBytes)
            })
        );
    }

    function test_PrepareFreezesValidatedV2RecordWithoutConsumption() public {
        SourceBoundProRataAssuranceV2.PreparedSourceAssurance memory prepared =
            assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValuesBytes);

        assertEq(uint8(prepared.state), uint8(SourceBoundProRataAssuranceV2.AssuranceState.Prepared));
        assertEq(prepared.preparedOperationRoot, preparedRoot);
        assertEq(prepared.reserveStateCommitment, commitment);
        assertEq(prepared.allocationBindingRoot, ALLOCATION);
        assertEq(prepared.realizedStatementRoot, REALIZED);
        assertFalse(assurance.consumedAssurance(RECEIPT));
        assertEq(assurance.operationForReceipt(RECEIPT), OPERATION);
    }

    function test_ConsumptionIsControllerOnlyAndOneShot() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValuesBytes);

        vm.expectRevert();
        assurance.consumeForRatification(OPERATION, preparedRoot, commitment);

        ISourceBoundProRataAssuranceV2.RatificationPayload memory payload =
            controller.consume(assurance, OPERATION, preparedRoot, commitment);
        assertEq(payload.receiptId, RECEIPT);
        assertTrue(assurance.consumedAssurance(RECEIPT));
        assertEq(assurance.assuranceForOperation(OPERATION), RECEIPT);

        vm.expectRevert();
        controller.consume(assurance, OPERATION, preparedRoot, commitment);
    }

    function test_RealAssuranceRatifiesThroughControllerAndReserve() public {
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(0x2222), address(0x3333));
        reserve.configure(commitment, false, 70, 18);
        _prepareIntegratedAssurance(f, commitment);

        f.ratification.ratifyAndFund(OPERATION, commitment, bytes32(uint256(4)), 1, address(0x2222));

        assertEq(uint8(f.ratification.state(OPERATION)), uint8(SourceBoundProRataRatificationControllerV2.State.Funded));
        assertTrue(f.assurance.consumedAssurance(f.receiptId));
        (,, uint256 funded,) = f.ratification.result(OPERATION);
        assertEq(funded, 70);
    }

    function test_RealAssuranceRollbackKeepsPreparedOnReserveFailure() public {
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(0x2222), address(0x3333));
        reserve.configure(commitment, true, 70, 18);
        _prepareIntegratedAssurance(f, commitment);

        vm.expectRevert(bytes("RESERVE_RATIFICATION_REVERT"));
        f.ratification.ratifyAndFund(OPERATION, commitment, bytes32(uint256(4)), 1, address(0x2222));

        assertEq(
            uint8(f.ratification.state(OPERATION)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared)
        );
        assertFalse(f.assurance.consumedAssurance(f.receiptId));
        SourceBoundProRataAssuranceV2.PreparedSourceAssurance memory prepared = f.assurance.preparedAssurance(OPERATION);
        assertEq(uint8(prepared.state), uint8(SourceBoundProRataAssuranceV2.AssuranceState.Prepared));
    }

    function test_StaleAssuranceCanBeRecoveredOnlyByBoundCallerAndOnlyOncePerGeneration() public {
        bytes32 stale = keccak256("stale-reserve");
        bytes32 live1 = keccak256("live-reserve-one");
        bytes32 live2 = keccak256("live-reserve-two");
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(0x2222), address(0x3333));
        reserve.configure(stale, false, 70, 18);
        _prepareIntegratedAssurance(f, stale);

        bytes32 replacement1 = keccak256("replacement-receipt-one");
        bytes memory values1 = _registerIntegratedReceipt(f, replacement1, live1);
        reserve.configure(live1, false, 70, 19);
        bytes32 oldAssurance = f.assurance.assuranceCommitment(OPERATION);
        bytes32 replacementCommitment1 =
            f.assurance.assuranceCommitmentFor(OPERATION, replacement1, keccak256(values1), 2);

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataRatificationControllerV2.OnlyExecutionCaller.selector, address(0xBAD)
            )
        );
        f.ratification.replaceStaleAssurance(OPERATION, oldAssurance, replacementCommitment1, 1, replacement1, values1);
        assertEq(f.assurance.preparedAssurance(OPERATION).receiptId, f.receiptId);

        f.ratification.replaceStaleAssurance(OPERATION, oldAssurance, replacementCommitment1, 1, replacement1, values1);
        assertEq(f.assurance.preparedAssurance(OPERATION).generation, 2);

        bytes32 replacement2 = keccak256("replacement-receipt-two");
        bytes memory values2 = _registerIntegratedReceipt(f, replacement2, live2);
        reserve.configure(live2, false, 70, 20);
        bytes32 generation2Commitment = f.assurance.assuranceCommitment(OPERATION);
        bytes32 replacementCommitment2 =
            f.assurance.assuranceCommitmentFor(OPERATION, replacement2, keccak256(values2), 3);
        f.ratification
            .replaceStaleAssurance(OPERATION, generation2Commitment, replacementCommitment2, 2, replacement2, values2);
        assertEq(f.assurance.preparedAssurance(OPERATION).generation, 3);

        vm.expectRevert(SourceBoundProRataAssuranceV2.GenerationMismatch.selector);
        f.ratification
            .replaceStaleAssurance(OPERATION, generation2Commitment, replacementCommitment2, 2, replacement2, values2);
        f.ratification.ratifyAndFund(OPERATION, live2, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(f.ratification.state(OPERATION)), uint8(SourceBoundProRataRatificationControllerV2.State.Funded));
        assertTrue(f.assurance.consumedAssurance(replacement2));
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataRatificationControllerV2.InvalidState.selector,
                SourceBoundProRataRatificationControllerV2.State.Funded
            )
        );
        f.ratification.replaceStaleAssurance(OPERATION, bytes32(0), bytes32(0), 3, keccak256("late"), "");
    }

    function test_ReplacementRejectsAbandonedPreparedOperation() public {
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(0x2222), address(0x3333));
        reserve.configure(commitment, false, 70, 18);
        _prepareIntegratedAssurance(f, commitment);
        bytes32 originalAssurance = f.assurance.assuranceCommitment(OPERATION);

        f.prepared.abandonPreparedOperation(OPERATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataRatificationControllerV2.InvalidPreparedOperation.selector,
                SourceBoundProRataControllerV2.State.Abandoned
            )
        );
        f.ratification.replaceStaleAssurance(OPERATION, bytes32(0), bytes32(0), 1, bytes32(0), "");

        assertEq(uint8(f.prepared.state(OPERATION)), uint8(SourceBoundProRataControllerV2.State.Abandoned));
        assertEq(f.assurance.assuranceCommitment(OPERATION), originalAssurance);
        assertFalse(f.assurance.consumedAssurance(f.receiptId));
    }

    function test_CurrentOrInvalidReplacementPreservesOriginalAssurance() public {
        bytes32 stale = keccak256("stale-reserve-current-check");
        bytes32 live = keccak256("live-reserve-current-check");
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(0x2222), address(0x3333));
        reserve.configure(stale, false, 70, 18);
        _prepareIntegratedAssurance(f, stale);
        bytes32 replacement = keccak256("replacement-current-check");
        bytes memory values = _registerIntegratedReceipt(f, replacement, stale);
        bytes32 oldAssurance = f.assurance.assuranceCommitment(OPERATION);
        bytes32 expectedReplacement = f.assurance.assuranceCommitmentFor(OPERATION, replacement, keccak256(values), 2);

        vm.expectRevert(SourceBoundProRataAssuranceV2.AssuranceNotStale.selector);
        f.ratification.replaceStaleAssurance(OPERATION, oldAssurance, expectedReplacement, 1, replacement, values);

        reserve.configure(live, false, 70, 19);
        values[0] = bytes1(uint8(values[0]) ^ 1);
        bytes32 invalidExpectedReplacement =
            f.assurance.assuranceCommitmentFor(OPERATION, replacement, keccak256(values), 2);
        vm.expectRevert(SourceBoundProRataAssuranceV2.InvalidIdentity.selector);
        f.ratification
            .replaceStaleAssurance(OPERATION, oldAssurance, invalidExpectedReplacement, 1, replacement, values);
        assertEq(f.assurance.preparedAssurance(OPERATION).receiptId, f.receiptId);
        assertEq(f.assurance.assuranceCommitment(OPERATION), oldAssurance);
    }

    function test_RealReserveAndV2AllocatorCompleteAtomicFunding() public {
        AssuranceV2TokenMock token = new AssuranceV2TokenMock();
        ProductionProRataAllocatorV2 allocator =
            new ProductionProRataAllocatorV2(address(this), new MockEntitlementProofModeSource());
        OnchainShortfallReserveV2 reserve = new OnchainShortfallReserveV2(token, address(this), 10, allocator);
        allocator.bindFundingAuthority(address(reserve));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(token), address(allocator));
        reserve.bindRatificationAuthority(address(f.ratification));

        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(f.preparedRoot);
        _prepareIntegratedAssurance(f, state.commitment);

        f.ratification.ratifyAndFund(OPERATION, state.commitment, bytes32(uint256(4)), 1, address(0x2222));

        IShortfallAllocatorV2.Operation memory operation = allocator.operation(OPERATION);
        assertEq(uint8(operation.state), uint8(IShortfallAllocatorV2.State.Funded));
        assertEq(operation.amount, 90);
        assertEq(token.balanceOf(address(reserve)), 10);
        assertEq(token.balanceOf(address(allocator)), 90);
        assertEq(token.allowance(address(reserve), address(allocator)), 0);
    }

    function test_StaleRealReserveRatificationRollsBackAssuranceAndCapital() public {
        AssuranceV2TokenMock token = new AssuranceV2TokenMock();
        ProductionProRataAllocatorV2 allocator =
            new ProductionProRataAllocatorV2(address(this), new MockEntitlementProofModeSource());
        OnchainShortfallReserveV2 reserve = new OnchainShortfallReserveV2(token, address(this), 10, allocator);
        allocator.bindFundingAuthority(address(reserve));
        IntegratedFixture memory f = _integratedFixture(OPERATION, address(reserve), address(token), address(allocator));
        reserve.bindRatificationAuthority(address(f.ratification));

        token.mint(address(this), 101);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        bytes32 stale = reserve.economicState(f.preparedRoot).commitment;
        _prepareIntegratedAssurance(f, stale);
        token.approve(address(reserve), 1);
        reserve.deposit(1);
        bytes32 live = reserve.economicState(f.preparedRoot).commitment;

        vm.expectRevert(abi.encodeWithSelector(OnchainShortfallReserveV2.CommitmentMismatch.selector, stale, live));
        f.ratification.ratifyAndFund(OPERATION, stale, bytes32(uint256(4)), 1, address(0x2222));

        assertEq(
            uint8(f.ratification.state(OPERATION)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared)
        );
        assertEq(uint8(f.prepared.state(OPERATION)), uint8(SourceBoundProRataControllerV2.State.Prepared));
        assertEq(
            uint8(f.assurance.preparedAssurance(OPERATION).state),
            uint8(SourceBoundProRataAssuranceV2.AssuranceState.Prepared)
        );
        assertFalse(f.assurance.consumedAssurance(f.receiptId));
        assertEq(token.balanceOf(address(reserve)), 101);
        assertEq(token.balanceOf(address(allocator)), 0);
        assertEq(reserve.totalReserved(), 0);
        assertEq(token.allowance(address(reserve), address(allocator)), 0);
    }

    function _integratedFixture(bytes32 operationId, address reserve, address token, address allocator)
        internal
        returns (IntegratedFixture memory f)
    {
        f.operationId = operationId;
        f.receiptId = keccak256(abi.encode("assurance-v2-integrated-receipt", operationId));
        f.prepared = new SourceBoundProRataControllerV2();
        f.assurance = new SourceBoundProRataAssuranceV2(admission, adapter, f.prepared, address(this));
        f.ratification = new SourceBoundProRataRatificationControllerV2(
            f.prepared, f.assurance, IOnchainShortfallReserveV2(reserve)
        );
        f.prepared.bindRatificationController(address(f.ratification));
        f.ratification.bindExecutionCaller(address(this));
        f.assurance.bindRatificationController(address(f.ratification));

        ShortfallV2Commitments.PreparedOperation memory operation = _operation(address(this));
        operation.operationId = operationId;
        operation.reserve = bytes32(uint256(uint160(reserve)));
        operation.token = bytes32(uint256(uint160(token)));
        operation.allocator = bytes32(uint256(uint160(allocator)));
        f.preparedRoot = ShortfallV2Commitments.preparedOperationRoot(operation);
        f.prepared.prepareOperation(operation);
        f.ratification.registerPrepared(operationId);
    }

    function _prepareIntegratedAssurance(IntegratedFixture memory f, bytes32 reserveCommitment) internal {
        bytes memory values = _registerIntegratedReceipt(f, f.receiptId, reserveCommitment);
        f.assurance.prepareSourceAssurance(f.operationId, f.receiptId, values);
    }

    function _registerIntegratedReceipt(IntegratedFixture memory f, bytes32 receiptId, bytes32 reserveCommitment)
        internal
        returns (bytes memory values)
    {
        values = abi.encode(
            adapter.PUBLIC_VALUES_DOMAIN(), f.preparedRoot, reserveCommitment, ALLOCATION, REALIZED, f.operationId
        );
        admission.setReceipt(
            receiptId,
            IPrfStatementAdmission.AdmissionReceipt({
                exists: true,
                protocolGenesisRoot: bytes32(0),
                chainInstanceGenesisRoot: bytes32(0),
                configurationRoot: bytes32(0),
                configurationEpoch: 0,
                verifierRegistryRoot: bytes32(0),
                verifierId: keccak256("source-bound-v2"),
                verifierAdapter: address(adapter),
                programVKey: adapter.programVKey(),
                programElfSha256: adapter.programElfSha256(),
                statementSchemaVersionHash: adapter.statementSchemaVersion(),
                publicValuesSchema: adapter.publicValuesSchema(),
                statementRoot: ALLOCATION,
                publicValuesDigest: sha256(values)
            })
        );
    }

    function test_BindingIsPermanentAndPreparationRejectsInvalidDigest() public {
        vm.expectRevert();
        assurance.bindRatificationController(address(0xBEEF));

        bytes memory corrupted = publicValuesBytes;
        corrupted[31] = bytes1(uint8(corrupted[31]) ^ 1);
        vm.expectRevert();
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, corrupted);
    }

    function _operation(address initiator)
        internal
        view
        returns (ShortfallV2Commitments.PreparedOperation memory operation)
    {
        operation = ShortfallV2Commitments.PreparedOperation({
            operationId: OPERATION,
            initiator: bytes32(uint256(uint160(initiator))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(1)),
            token: bytes32(uint256(2)),
            allocator: bytes32(uint256(3)),
            configurationRoot: bytes32(uint256(4)),
            configurationEpoch: 1,
            sourceVerifierId: bytes32(uint256(5)),
            executionVerifierId: bytes32(uint256(6)),
            sourceProgramVKey: bytes32(uint256(7)),
            sourceProgramElfSha256: bytes32(uint256(8)),
            sourceStatementSchema: bytes32(uint256(9)),
            sourcePublicValuesSchema: bytes32(uint256(10)),
            executionStatementSchema: bytes32(uint256(11)),
            executionPublicValuesSchema: bytes32(uint256(12)),
            policyRoot: bytes32(uint256(13)),
            residualRecipient: bytes32(uint256(uint160(address(0x2222))))
        });
    }
}
