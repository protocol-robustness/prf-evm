// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ProductionProRataAllocatorV1} from "../src/ProductionProRataAllocatorV1.sol";
import {OnchainShortfallReserveV1} from "../src/OnchainShortfallReserveV1.sol";

contract ReserveTestToken is ERC20 {
    constructor() ERC20("Reserve Test", "RST") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract OnchainShortfallReserveV1Test is Test {
    ReserveTestToken token;
    OnchainShortfallReserveV1 reserve;
    ProductionProRataAllocatorV1 allocator;
    address authority = address(0xA11CE);
    bytes32 constant OP = keccak256("shortfall-operation");
    bytes32 constant OTHER_OP = keccak256("other-shortfall-operation");
    bytes32 constant STATEMENT = keccak256("statement");
    bytes32 constant CONFIG = keccak256("configuration");
    uint256 constant PROTECTED = 10;

    function setUp() public {
        token = new ReserveTestToken();
        reserve = new OnchainShortfallReserveV1(token, authority, PROTECTED);
        allocator = new ProductionProRataAllocatorV1(
            IPrfStatementAdmission(address(1)),
            address(reserve)
        );
        vm.prank(authority);
        reserve.bindAllocator(allocator);
    }

    function test_ProtectedFloorDoesNotBlockDeposits() public {
        token.mint(address(this), 5);
        token.approve(address(reserve), 5);
        reserve.deposit(5);
        assertEq(token.balanceOf(address(reserve)), 5);
        assertEq(reserve.totalReserved(), 0);
    }

    function test_LockDerivesAndRetainsImmutableSnapshot() public {
        _deposit(100);
        vm.prank(authority);
        uint64 snapshotId = reserve.lockAvailableFor(OP);

        (bytes32 operationId, address snapshotAllocator, uint256 gross, uint256 reservedBefore,
            uint256 protectedAmount, uint256 available, uint256 createdAtBlock, bytes32 snapshotHash) =
            reserve.availabilitySnapshots(snapshotId);
        assertEq(operationId, OP);
        assertEq(snapshotAllocator, address(allocator));
        assertEq(gross, 100);
        assertEq(reservedBefore, 0);
        assertEq(protectedAmount, PROTECTED);
        assertEq(available, 90);
        assertGt(createdAtBlock, 0);
        assertEq(reserve.totalReserved(), 90);
        assertEq(reserve.activeShortfallOperationId(), OP);
        assertEq(snapshotHash, reserve.snapshotHash(snapshotId));
        assertEq(token.balanceOf(address(reserve)), 100);
    }

    function test_OrdinaryReservationReducesAvailability() public {
        _deposit(100);
        vm.prank(authority);
        reserve.reserveForOtherObligation(keccak256("ordinary"), 20);
        vm.prank(authority);
        uint64 snapshotId = reserve.lockAvailableFor(OP);
        assertEq(_snapshotAvailable(snapshotId), 70);
        assertEq(reserve.totalReserved(), 90);
    }

    function test_LockRejectsSecondActiveShortfallOperation() public {
        _deposit(100);
        vm.prank(authority);
        reserve.lockAvailableFor(OP);
        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(
                OnchainShortfallReserveV1.ActiveShortfallOperation.selector,
                OP
            )
        );
        reserve.lockAvailableFor(OTHER_OP);
    }

    function test_CreateForwardingUsesSnapshotTokenAndAmount() public {
        _deposit(100);
        vm.prank(authority);
        reserve.lockAvailableFor(OP);
        vm.prank(authority);
        reserve.createAllocatorOperation(OP, STATEMENT, CONFIG, 7, address(0xBEEF));

        ProductionProRataAllocatorV1.Operation memory operation = allocator.operation(OP);
        assertEq(uint256(operation.state), uint256(ProductionProRataAllocatorV1.State.Created));
        assertEq(address(operation.token), address(token));
        assertEq(operation.availableAmount, 90);
        assertTrue(_allocatorConfigured(OP));
    }

    function test_PermissionlessFundingUsesExactReservedAmount() public {
        _deposit(100);
        vm.prank(authority);
        reserve.lockAvailableFor(OP);
        vm.prank(authority);
        reserve.createAllocatorOperation(OP, STATEMENT, CONFIG, 7, address(0xBEEF));

        reserve.fundOperation(OP);

        assertEq(token.balanceOf(address(reserve)), 10);
        assertEq(token.balanceOf(address(allocator)), 90);
        assertEq(reserve.totalReserved(), 0);
        assertEq(reserve.activeShortfallOperationId(), bytes32(0));
        assertEq(uint8(_shortfallState(OP)), uint8(OnchainShortfallReserveV1.ShortfallOperationState.Funded));
        assertEq(uint256(allocator.operation(OP).state), uint256(ProductionProRataAllocatorV1.State.Funded));
        assertEq(allocator.operation(OP).funder, address(reserve));
    }

    function test_FundingCannotBeRepeated() public {
        _deposit(100);
        vm.prank(authority);
        reserve.lockAvailableFor(OP);
        vm.prank(authority);
        reserve.createAllocatorOperation(OP, STATEMENT, CONFIG, 7, address(0xBEEF));
        reserve.fundOperation(OP);

        vm.expectRevert(OnchainShortfallReserveV1.InvalidOperation.selector);
        reserve.fundOperation(OP);
    }

    function test_AllocatorBindingCannotChange() public {
        vm.prank(authority);
        vm.expectRevert(OnchainShortfallReserveV1.AllocatorAlreadyBound.selector);
        reserve.bindAllocator(allocator);
    }

    function test_LockRejectsZeroAvailability() public {
        _deposit(10);
        vm.prank(authority);
        vm.expectRevert(OnchainShortfallReserveV1.NoAllocableCapital.selector);
        reserve.lockAvailableFor(OP);
    }

    function _allocatorConfigured(bytes32 operationId) internal view returns (bool configured) {
        (,,, configured,) = reserve.shortfallOperations(operationId);
    }

    function _shortfallState(bytes32 operationId) internal view returns (OnchainShortfallReserveV1.ShortfallOperationState state) {
        (state,,,,) = reserve.shortfallOperations(operationId);
    }

    function _snapshotAvailable(uint64 snapshotId) internal view returns (uint256 available) {
        (,,,,, available,,) = reserve.availabilitySnapshots(snapshotId);
    }

    function _deposit(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(reserve), amount);
        reserve.deposit(amount);
    }
}
