// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {V2RatificationAllocatorMock} from "./mocks/V2RatificationMocks.sol";
import {IOnchainShortfallReserveV2} from "../src/interfaces/IOnchainShortfallReserveV2.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";

contract V2ReserveToken is ERC20 {
    enum TransferFromMode { Normal, Revert, ReturnFalse, ShortTransfer }

    TransferFromMode public transferFromMode;

    constructor() ERC20("V2 Reserve", "V2R") {}

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function setTransferFromMode(TransferFromMode mode) external {
        transferFromMode = mode;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (transferFromMode == TransferFromMode.Revert) revert("TOKEN_TRANSFER_FROM_REVERT");
        if (transferFromMode == TransferFromMode.ReturnFalse) return false;
        if (transferFromMode == TransferFromMode.ShortTransfer) {
            return super.transferFrom(from, to, value - 1);
        }
        return super.transferFrom(from, to, value);
    }
}

contract OnchainShortfallReserveV2Test is Test {
    V2ReserveToken token;
    OnchainShortfallReserveV2 reserve;
    V2RatificationAllocatorMock allocator;
    address authority = address(0xA11CE);
    bytes32 constant RESERVATION = keccak256("ordinary");
        bytes32 constant OPERATION = keccak256("operation");
    bytes32 constant PREPARED = keccak256("prepared");

    function setUp() public {
        token = new V2ReserveToken();
        allocator = new V2RatificationAllocatorMock();
        reserve = new OnchainShortfallReserveV2(token, authority, 10, allocator);
    }

    function test_EconomicStateDerivesLiveAvailabilityAndRevision() public {
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);

        OnchainShortfallReserveV2.EconomicState memory beforeState = reserve.economicState(PREPARED);
        assertEq(beforeState.revision, 0);

        vm.prank(authority);
        reserve.reserveForOtherObligation(RESERVATION, 20);
        OnchainShortfallReserveV2.EconomicState memory afterState = reserve.economicState(PREPARED);
        assertEq(afterState.reservedBefore, 20);
        assertEq(afterState.revision, 1);
    }

    function test_RevisionChangesWhenReservationIsReleased() public {
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        vm.prank(authority);
        reserve.reserveForOtherObligation(RESERVATION, 20);
        vm.prank(authority);
        reserve.releaseOtherObligationReservation(RESERVATION);
        assertEq(reserve.availabilityRevision(), 2);
    }

    function test_RatifyAndFundComparesCommitmentAndClearsEphemeralReservation() public {
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(PREPARED);
        vm.prank(authority);
        OnchainShortfallReserveV2.RatificationResult memory result = reserve.ratifyAndFund(
            IOnchainShortfallReserveV2.RatificationRequest(
                OPERATION, PREPARED, state.commitment, bytes32(uint256(1)), bytes32(uint256(2)),
                bytes32(uint256(3)), 1, address(0x2222)
            )
        );
        assertEq(result.fundedAmount, 90);
        assertEq(reserve.totalReserved(), 0);
        assertEq(reserve.availabilityRevision(), 1);
        assertFalse(reserve.ratifying());
        assertEq(token.balanceOf(address(allocator)), 90);
    }

    function test_StaleCommitmentRevertsWithoutReservation() public {
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(PREPARED);
        vm.prank(authority);
        reserve.reserveForOtherObligation(RESERVATION, 1);
        vm.prank(authority);
        vm.expectRevert();
        reserve.ratifyAndFund(
            IOnchainShortfallReserveV2.RatificationRequest(
                OPERATION, PREPARED, state.commitment, bytes32(uint256(1)), bytes32(uint256(2)),
                bytes32(uint256(3)), 1, address(0x2222)
            )
        );
        assertEq(reserve.totalReserved(), 1);
        assertEq(reserve.availabilityRevision(), 1);
    }

    function test_PreparedStateDoesNotReserveCapital() public {
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(PREPARED);
        assertEq(state.availableAmount, 90);
        assertEq(reserve.totalReserved(), 0);
    }

    function test_CreateFailuresLeaveNoObservableRatificationState() public {
        for (uint8 fault = 0; fault <= 5; ++fault) {
            if (fault == 0) {
                allocator.setModes(true, false, false);
            } else {
                allocator.setModes(false, false, false);
                allocator.setCreateFault(fault);
            }
            _assertRatificationRevertsAndRollsBack();
            allocator.setCreateFault(0);
        }
    }

    function test_FundFailuresLeaveNoObservableRatificationState() public {
        allocator.setModes(false, true, false);
        _assertRatificationRevertsAndRollsBack();

        allocator.setModes(false, false, false);
        allocator.setMalformedFundState(true);
        _assertRatificationRevertsAndRollsBack();
    }

    function test_TokenFundingFailuresLeaveNoObservableRatificationState() public {
        _deposit100();
        token.setTransferFromMode(V2ReserveToken.TransferFromMode.Revert);
        _assertCurrentRatificationRevertsAndRollsBack();

        token.setTransferFromMode(V2ReserveToken.TransferFromMode.Normal);
        _deposit100();
        token.setTransferFromMode(V2ReserveToken.TransferFromMode.ReturnFalse);
        _assertCurrentRatificationRevertsAndRollsBack();

        token.setTransferFromMode(V2ReserveToken.TransferFromMode.Normal);
        _deposit100();
        token.setTransferFromMode(V2ReserveToken.TransferFromMode.ShortTransfer);
        _assertCurrentRatificationRevertsAndRollsBack();
    }

    function test_RatificationAuthorityCanBeBoundOnlyOnce() public {
        vm.prank(authority);
        reserve.bindRatificationAuthority(address(0xBEEF));
        assertTrue(reserve.ratificationAuthorityBound());
        assertEq(reserve.ratificationAuthority(), address(0xBEEF));

        vm.prank(authority);
        vm.expectRevert();
        reserve.bindRatificationAuthority(address(0xCAFE));
    }

    function test_EachSuccessfulAvailabilityMutationAdvancesRevisionExactlyOnce() public {
        _deposit100();
        vm.prank(authority);
        reserve.reserveForOtherObligation(RESERVATION, 20);
        assertEq(reserve.availabilityRevision(), 1, "ordinary reservation");

        vm.prank(authority);
        reserve.releaseOtherObligationReservation(RESERVATION);
        assertEq(reserve.availabilityRevision(), 2, "ordinary release");

        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(PREPARED);
        vm.prank(authority);
        reserve.ratifyAndFund(_request(state.commitment));
        assertEq(reserve.availabilityRevision(), 3, "atomic ratification/funding");
    }

    function test_AllocatorReentryIsRejectedWhileOuterRatificationCompletes() public {
        V2RatificationAllocatorMock reentrantAllocator = new V2RatificationAllocatorMock();
        OnchainShortfallReserveV2 reentrantReserve =
            new OnchainShortfallReserveV2(token, address(reentrantAllocator), 10, reentrantAllocator);
        token.mint(address(this), 100);
        token.approve(address(reentrantReserve), 100);
        reentrantReserve.deposit(100);
        OnchainShortfallReserveV2.EconomicState memory state = reentrantReserve.economicState(PREPARED);
        IOnchainShortfallReserveV2.RatificationRequest memory request = _request(state.commitment);
        reentrantAllocator.configureReserveReentry(reentrantReserve, request);

        reentrantAllocator.startRatification(reentrantReserve, request);

        assertTrue(reentrantAllocator.reentryAttempted());
        assertFalse(reentrantAllocator.reentrySucceeded());
        assertFalse(reentrantReserve.ratifying());
        assertEq(reentrantReserve.totalReserved(), 0);
        assertEq(reentrantReserve.availabilityRevision(), state.revision + 1);
        assertEq(token.allowance(address(reentrantReserve), address(reentrantAllocator)), 0);
        assertEq(uint8(reentrantAllocator.operation(OPERATION).state), uint8(IShortfallAllocatorV2.State.Funded));
    }

    function test_SuccessClearsAllocatorAllowanceAndObservationBindsPredecessor() public {
        _deposit100();
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(PREPARED);
        vm.prank(authority);
        OnchainShortfallReserveV2.RatificationResult memory result = reserve.ratifyAndFund(_request(state.commitment));

        assertEq(token.allowance(address(reserve), address(allocator)), 0);
        assertEq(result.snapshotId, 1);
        assertEq(result.successorAvailabilityRevision, state.revision + 1);
        OnchainShortfallReserveV2.AuthoritativeObservation memory observation =
            reserve.authoritativeObservation(PREPARED, state.commitment, result.snapshotId, block.number);
        assertEq(observation.observationRoot, result.authoritativeObservationRoot);
        assertEq(observation.reserveStateCommitment, state.commitment);
    }

    function _assertRatificationRevertsAndRollsBack() internal {
        _deposit100();
        _assertCurrentRatificationRevertsAndRollsBack();
    }

    function _assertCurrentRatificationRevertsAndRollsBack() internal {
        OnchainShortfallReserveV2.EconomicState memory state = reserve.economicState(PREPARED);
        uint256 reserveBalance = token.balanceOf(address(reserve));
        uint256 allocatorBalance = token.balanceOf(address(allocator));
        uint64 revision = reserve.availabilityRevision();
        uint64 snapshotId = reserve.nextSnapshotId();

        vm.prank(authority);
        vm.expectRevert();
        reserve.ratifyAndFund(_request(state.commitment));

        assertEq(reserve.availabilityRevision(), revision, "revision");
        assertEq(reserve.nextSnapshotId(), snapshotId, "snapshot id");
        assertEq(reserve.totalReserved(), 0, "temporary reservation");
        assertFalse(reserve.ratifying(), "ratification state");
        assertEq(token.balanceOf(address(reserve)), reserveBalance, "reserve balance");
        assertEq(token.balanceOf(address(allocator)), allocatorBalance, "allocator balance");
        assertEq(token.allowance(address(reserve), address(allocator)), 0, "allowance");
        assertEq(uint8(allocator.operation(OPERATION).state), uint8(IShortfallAllocatorV2.State.None), "allocator operation");
    }

    function _deposit100() internal {
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
    }

    function _request(bytes32 commitment) internal pure returns (IOnchainShortfallReserveV2.RatificationRequest memory) {
        return IOnchainShortfallReserveV2.RatificationRequest(
            OPERATION, PREPARED, commitment, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), 1, address(0x2222)
        );
    }
}
