// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {PrfSourceBoundStatementVerifierAdapterV2} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {SourceBoundProRataAssuranceV2} from "../src/applications/shortfall/SourceBoundProRataAssuranceV2.sol";
import {SourceBoundProRataRatificationControllerV2} from "../src/applications/shortfall/SourceBoundProRataRatificationControllerV2.sol";
import {ISourceBoundProRataAssuranceV2} from "../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IOnchainShortfallReserveV2} from "../src/interfaces/IOnchainShortfallReserveV2.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {V2RatificationReserveMock} from "./mocks/V2RatificationReserveMock.sol";

contract AssuranceV2TokenMock is ERC20 {
    constructor() ERC20("V2 Integration", "V2I") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
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

    function supportsInterface(bytes4) external pure returns (bool) { return true; }
    function protocolGenesisRoot() external pure returns (bytes32) { return bytes32(0); }
    function chainInstanceGenesisRoot() external pure returns (bytes32) { return bytes32(0); }
    function expectedConfigurationRoot() external pure returns (bytes32) { return bytes32(0); }
    function expectedConfigurationEpoch() external pure returns (uint64) { return 0; }
    function admittedCount() external pure returns (uint256) { return 0; }
    function admitStatement(bytes32, bytes32, bytes calldata, bytes calldata) external pure returns (bytes32) {
        revert("NOT_IN_FIXTURE");
    }
}

contract AssuranceV2CallerMock {
    function consume(SourceBoundProRataAssuranceV2 assurance, bytes32 operationId, bytes32 preparedRoot, bytes32 commitment)
        external returns (ISourceBoundProRataAssuranceV2.RatificationPayload memory)
    {
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

        publicValuesBytes = abi.encode(
            adapter.PUBLIC_VALUES_DOMAIN(), preparedRoot, commitment, ALLOCATION, REALIZED, OPERATION);
        admission.setReceipt(RECEIPT, IPrfStatementAdmission.AdmissionReceipt({
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
        }));
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
        SourceBoundProRataAssuranceV2 integratedAssurance =
            new SourceBoundProRataAssuranceV2(admission, adapter, preparedController, address(this));
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        SourceBoundProRataRatificationControllerV2 ratificationController =
            new SourceBoundProRataRatificationControllerV2(preparedController, integratedAssurance, reserve);
        integratedAssurance.bindRatificationController(address(ratificationController));
        ratificationController.registerPrepared(OPERATION);
        reserve.configure(commitment, false, 70, 18);
        integratedAssurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValuesBytes);

        ratificationController.ratifyAndFund(OPERATION, commitment, bytes32(uint256(4)), 1, address(0x2222));

        assertEq(uint8(ratificationController.state(OPERATION)), uint8(SourceBoundProRataRatificationControllerV2.State.Funded));
        assertTrue(integratedAssurance.consumedAssurance(RECEIPT));
        (,, uint256 funded,) = ratificationController.result(OPERATION);
        assertEq(funded, 70);
    }

    function test_RealAssuranceRollbackKeepsPreparedOnReserveFailure() public {
        SourceBoundProRataAssuranceV2 integratedAssurance =
            new SourceBoundProRataAssuranceV2(admission, adapter, preparedController, address(this));
        V2RatificationReserveMock reserve = new V2RatificationReserveMock();
        SourceBoundProRataRatificationControllerV2 ratificationController =
            new SourceBoundProRataRatificationControllerV2(preparedController, integratedAssurance, reserve);
        integratedAssurance.bindRatificationController(address(ratificationController));
        ratificationController.registerPrepared(OPERATION);
        reserve.configure(commitment, true, 70, 18);
        integratedAssurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValuesBytes);

        vm.expectRevert(bytes("RESERVE_RATIFICATION_REVERT"));
        ratificationController.ratifyAndFund(OPERATION, commitment, bytes32(uint256(4)), 1, address(0x2222));

        assertEq(uint8(ratificationController.state(OPERATION)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
        assertFalse(integratedAssurance.consumedAssurance(RECEIPT));
        SourceBoundProRataAssuranceV2.PreparedSourceAssurance memory prepared = integratedAssurance.preparedAssurance(OPERATION);
        assertEq(uint8(prepared.state), uint8(SourceBoundProRataAssuranceV2.AssuranceState.Prepared));
    }

    function test_RealReserveAndV2AllocatorCompleteAtomicFunding() public {
        AssuranceV2TokenMock token = new AssuranceV2TokenMock();
        ProductionProRataAllocatorV2 allocator = new ProductionProRataAllocatorV2(address(this));
        OnchainShortfallReserveV2 reserve = new OnchainShortfallReserveV2(token, address(this), 10, allocator);
        allocator.bindFundingAuthority(address(reserve));

        SourceBoundProRataAssuranceV2 integratedAssurance =
            new SourceBoundProRataAssuranceV2(admission, adapter, preparedController, address(this));
        SourceBoundProRataRatificationControllerV2 ratificationController =
            new SourceBoundProRataRatificationControllerV2(preparedController, integratedAssurance, reserve);
        integratedAssurance.bindRatificationController(address(ratificationController));
        reserve.bindRatificationAuthority(address(ratificationController));
        ratificationController.registerPrepared(OPERATION);

        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(preparedRoot);
        publicValuesBytes = abi.encode(adapter.PUBLIC_VALUES_DOMAIN(), preparedRoot, state.commitment, ALLOCATION, REALIZED, OPERATION);
        admission.setReceipt(RECEIPT, IPrfStatementAdmission.AdmissionReceipt({
            exists: true, protocolGenesisRoot: bytes32(0), chainInstanceGenesisRoot: bytes32(0),
            configurationRoot: bytes32(0), configurationEpoch: 0, verifierRegistryRoot: bytes32(0),
            verifierId: keccak256("source-bound-v2"), verifierAdapter: address(adapter),
            programVKey: adapter.programVKey(), programElfSha256: adapter.programElfSha256(),
            statementSchemaVersionHash: adapter.statementSchemaVersion(), publicValuesSchema: adapter.publicValuesSchema(),
            statementRoot: ALLOCATION, publicValuesDigest: sha256(publicValuesBytes)
        }));
        integratedAssurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValuesBytes);

        ratificationController.ratifyAndFund(OPERATION, state.commitment, bytes32(uint256(4)), 1, address(0x2222));

        IShortfallAllocatorV2.Operation memory operation = allocator.operation(OPERATION);
        assertEq(uint8(operation.state), uint8(IShortfallAllocatorV2.State.Funded));
        assertEq(operation.amount, 90);
        assertEq(token.balanceOf(address(reserve)), 10);
        assertEq(token.balanceOf(address(allocator)), 90);
        assertEq(token.allowance(address(reserve), address(allocator)), 0);
    }

    function test_BindingIsPermanentAndPreparationRejectsInvalidDigest() public {
        vm.expectRevert();
        assurance.bindRatificationController(address(0xBEEF));

        bytes memory corrupted = publicValuesBytes;
        corrupted[31] = bytes1(uint8(corrupted[31]) ^ 1);
        vm.expectRevert();
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, corrupted);
    }

    function _operation(address initiator) internal view returns (ShortfallV2Commitments.PreparedOperation memory operation) {
        operation = ShortfallV2Commitments.PreparedOperation({
            operationId: OPERATION,
            initiator: bytes32(uint256(uint160(initiator))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(1)), token: bytes32(uint256(2)), allocator: bytes32(uint256(3)),
            configurationRoot: bytes32(uint256(4)), configurationEpoch: 1,
            sourceVerifierId: bytes32(uint256(5)), executionVerifierId: bytes32(uint256(6)),
            sourceProgramVKey: bytes32(uint256(7)), sourceProgramElfSha256: bytes32(uint256(8)),
            sourceStatementSchema: bytes32(uint256(9)), sourcePublicValuesSchema: bytes32(uint256(10)),
            executionStatementSchema: bytes32(uint256(11)), executionPublicValuesSchema: bytes32(uint256(12)),
            policyRoot: bytes32(uint256(13)), residualRecipient: bytes32(uint256(uint160(address(0x2222))))
        });
    }
}
