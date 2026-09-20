// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProductionProRataAllocatorV1} from "../pro-rata/ProductionProRataAllocatorV1.sol";

/// @notice A non-upgradeable, single-token source of authoritative Shortfall
///         availability. It records actual custody and explicit reservations;
///         it does not implement allocation or claims.
contract OnchainShortfallReserveV1 {
    bytes32 public constant SNAPSHOT_DOMAIN =
        keccak256("prf.onchain-shortfall-reserve.snapshot.v1");

    IERC20 public immutable token;
    address public immutable applicationAuthority;
    uint256 public immutable protectedCapital;

    ProductionProRataAllocatorV1 public allocator;
    bool public allocatorBound;
    uint64 public nextSnapshotId = 1;
    uint256 public totalReserved;
    bytes32 public activeShortfallOperationId;

    enum OrdinaryReservationState { None, Active, Released }
    struct OrdinaryReservation {
        OrdinaryReservationState state;
        uint256 amount;
    }

    enum ShortfallOperationState { None, Active, Funded }
    struct ShortfallOperation {
        ShortfallOperationState state;
        uint64 snapshotId;
        uint256 amount;
        bool allocatorConfigured;
        bool allocatorActivated;
    }

    struct AvailabilitySnapshot {
        bytes32 operationId;
        address allocator;
        uint256 grossAmount;
        uint256 reservedAmountBefore;
        uint256 protectedAmount;
        uint256 availableAmount;
        uint256 createdAtBlock;
        bytes32 snapshotHash;
    }

    mapping(bytes32 => OrdinaryReservation) public ordinaryReservations;
    mapping(bytes32 => ShortfallOperation) public shortfallOperations;
    mapping(uint64 => AvailabilitySnapshot) public availabilitySnapshots;
    mapping(bytes32 => uint64) public snapshotIdForOperation;

    error OnlyApplicationAuthority(address caller);
    error ZeroValue();
    error AllocatorAlreadyBound();
    error InvalidAllocator();
    error InvalidReservation();
    error InvalidOperation();
    error ActiveShortfallOperation(bytes32 operationId);
    error AccountingInconsistent();
    error NoAllocableCapital();
    error InvalidState();
    error AllocatorMismatch();
    error TokenDeltaMismatch();
    error AllowanceMismatch();
    error Reentrant();

    modifier onlyApplicationAuthority() {
        if (msg.sender != applicationAuthority) {
            revert OnlyApplicationAuthority(msg.sender);
        }
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrant();
        _entered = true;
        _;
        _entered = false;
    }

    bool private _entered;

    event AllocatorBound(address indexed allocator);
    event Deposited(address indexed from, uint256 amount);
    event OrdinaryReservationCreated(bytes32 indexed reservationId, uint256 amount);
    event OrdinaryReservationReleased(bytes32 indexed reservationId, uint256 amount);
    event ShortfallLocked(
        bytes32 indexed operationId,
        uint64 indexed snapshotId,
        uint256 grossAmount,
        uint256 reservedAmountBefore,
        uint256 protectedAmount,
        uint256 availableAmount,
        bytes32 snapshotHash
    );
    event AllocatorOperationCreated(bytes32 indexed operationId);
    event AllocatorOperationActivated(bytes32 indexed operationId, bytes32 indexed receiptId);
    event ShortfallFunded(bytes32 indexed operationId, uint256 amount);

    constructor(IERC20 token_, address applicationAuthority_, uint256 protectedCapital_) {
        if (address(token_) == address(0) || applicationAuthority_ == address(0)) {
            revert ZeroValue();
        }
        token = token_;
        applicationAuthority = applicationAuthority_;
        protectedCapital = protectedCapital_;
    }

    function bindAllocator(ProductionProRataAllocatorV1 allocator_) external onlyApplicationAuthority {
        if (allocatorBound) revert AllocatorAlreadyBound();
        if (address(allocator_) == address(0) || allocator_.operationAuthority() != address(this)) {
            revert InvalidAllocator();
        }
        allocator = allocator_;
        allocatorBound = true;
        emit AllocatorBound(address(allocator_));
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        uint256 sourceBefore = token.balanceOf(msg.sender);
        uint256 reserveBefore = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TokenDeltaMismatch();
        _requireDecrease(sourceBefore, token.balanceOf(msg.sender), amount);
        _requireIncrease(reserveBefore, token.balanceOf(address(this)), amount);
        emit Deposited(msg.sender, amount);
    }

    function reserveForOtherObligation(bytes32 reservationId, uint256 amount)
        external
        onlyApplicationAuthority
    {
        if (reservationId == bytes32(0) || amount == 0) revert InvalidReservation();
        if (ordinaryReservations[reservationId].state != OrdinaryReservationState.None) {
            revert InvalidReservation();
        }
        uint256 gross = token.balanceOf(address(this));
        _requireAllocableAccounting(gross);
        if (totalReserved + protectedCapital + amount > gross) revert InvalidReservation();
        ordinaryReservations[reservationId] = OrdinaryReservation(
            OrdinaryReservationState.Active,
            amount
        );
        totalReserved += amount;
        emit OrdinaryReservationCreated(reservationId, amount);
    }

    function releaseOtherObligationReservation(bytes32 reservationId)
        external
        onlyApplicationAuthority
    {
        OrdinaryReservation storage reservation = ordinaryReservations[reservationId];
        if (reservation.state != OrdinaryReservationState.Active) revert InvalidReservation();
        uint256 amount = reservation.amount;
        reservation.state = OrdinaryReservationState.Released;
        totalReserved -= amount;
        emit OrdinaryReservationReleased(reservationId, amount);
    }

    function lockAvailableFor(bytes32 operationId)
        external
        onlyApplicationAuthority
        returns (uint64 snapshotId)
    {
        if (!allocatorBound || operationId == bytes32(0)) revert InvalidOperation();
        if (shortfallOperations[operationId].state != ShortfallOperationState.None) {
            revert InvalidOperation();
        }
        if (activeShortfallOperationId != bytes32(0)) {
            revert ActiveShortfallOperation(activeShortfallOperationId);
        }

        uint256 gross = token.balanceOf(address(this));
        _requireAllocableAccounting(gross);
        uint256 available = gross - totalReserved - protectedCapital;
        if (available == 0) revert NoAllocableCapital();

        snapshotId = nextSnapshotId++;
        uint256 reservedBefore = totalReserved;
        uint256 createdAtBlock = block.number;
        bytes32 computedSnapshotHash = _snapshotHash(
            snapshotId,
            operationId,
            gross,
            reservedBefore,
            protectedCapital,
            available,
            createdAtBlock
        );

        availabilitySnapshots[snapshotId] = AvailabilitySnapshot(
            operationId,
            address(allocator),
            gross,
            reservedBefore,
            protectedCapital,
            available,
            createdAtBlock,
            computedSnapshotHash
        );
        snapshotIdForOperation[operationId] = snapshotId;
        shortfallOperations[operationId] = ShortfallOperation(
            ShortfallOperationState.Active,
            snapshotId,
            available,
            false,
            false
        );
        activeShortfallOperationId = operationId;
        totalReserved += available;

        emit ShortfallLocked(
            operationId,
            snapshotId,
            gross,
            reservedBefore,
            protectedCapital,
            available,
            computedSnapshotHash
        );
    }

    function createAllocatorOperation(
        bytes32 operationId,
        bytes32 statementRoot,
        bytes32 configurationRoot,
        uint64 configurationEpoch,
        address residualRecipient
    ) external onlyApplicationAuthority nonReentrant {
        if (!allocatorBound || operationId != activeShortfallOperationId) revert InvalidOperation();
        ShortfallOperation storage operation = shortfallOperations[operationId];
        if (operation.state != ShortfallOperationState.Active || operation.allocatorConfigured) {
            revert InvalidState();
        }
        if (statementRoot == bytes32(0) || configurationRoot == bytes32(0) || residualRecipient == address(0)) {
            revert InvalidOperation();
        }

        AvailabilitySnapshot storage snapshot = availabilitySnapshots[operation.snapshotId];
        allocator.create(
            operationId,
            statementRoot,
            configurationRoot,
            configurationEpoch,
            token,
            snapshot.availableAmount,
            residualRecipient
        );

        ProductionProRataAllocatorV1.Operation memory created = allocator.operation(operationId);
        if (
            address(created.token) != address(token) ||
            created.availableAmount != snapshot.availableAmount ||
            created.state != ProductionProRataAllocatorV1.State.Created
        ) revert AllocatorMismatch();
        operation.allocatorConfigured = true;
        emit AllocatorOperationCreated(operationId);
    }

    function activateAllocatorOperation(
        bytes32 operationId,
        bytes32 receiptId,
        bytes calldata publicValues
    ) external onlyApplicationAuthority nonReentrant {
        if (!allocatorBound || operationId != activeShortfallOperationId) revert InvalidOperation();
        ShortfallOperation storage operation = shortfallOperations[operationId];
        if (operation.state != ShortfallOperationState.Active || !operation.allocatorConfigured || operation.allocatorActivated) {
            revert InvalidState();
        }
        ProductionProRataAllocatorV1.Operation memory beforeOperation = allocator.operation(operationId);
        if (
            address(beforeOperation.token) != address(token) ||
            beforeOperation.availableAmount != operation.amount ||
            beforeOperation.state != ProductionProRataAllocatorV1.State.Funded
        ) revert AllocatorMismatch();

        allocator.activate(operationId, receiptId, publicValues);
        ProductionProRataAllocatorV1.Operation memory activated = allocator.operation(operationId);
        if (activated.state != ProductionProRataAllocatorV1.State.Activated) revert AllocatorMismatch();
        operation.allocatorActivated = true;
        emit AllocatorOperationActivated(operationId, receiptId);
    }

    function fundOperation(bytes32 operationId) external nonReentrant {
        if (!allocatorBound || operationId != activeShortfallOperationId) revert InvalidOperation();
        ShortfallOperation storage operation = shortfallOperations[operationId];
        if (operation.state != ShortfallOperationState.Active || !operation.allocatorConfigured) {
            revert InvalidState();
        }
        ProductionProRataAllocatorV1.Operation memory allocatorOperation = allocator.operation(operationId);
        if (
            address(allocatorOperation.token) != address(token) ||
            allocatorOperation.availableAmount != operation.amount ||
            allocatorOperation.state != ProductionProRataAllocatorV1.State.Created
        ) revert AllocatorMismatch();

        uint256 gross = token.balanceOf(address(this));
        _requireAllocableAccounting(gross);
        uint256 amount = operation.amount;
        uint256 reserveBefore = gross;
        uint256 allocatorBefore = token.balanceOf(address(allocator));
        if (token.allowance(address(this), address(allocator)) != 0) revert AllowanceMismatch();

        operation.state = ShortfallOperationState.Funded;
        totalReserved -= amount;
        if (!token.approve(address(allocator), amount)) revert AllowanceMismatch();
        allocator.fund(operationId);
        _requireDecrease(reserveBefore, token.balanceOf(address(this)), amount);
        _requireIncrease(allocatorBefore, token.balanceOf(address(allocator)), amount);
        if (token.allowance(address(this), address(allocator)) != 0) revert AllowanceMismatch();
        activeShortfallOperationId = bytes32(0);
        emit ShortfallFunded(operationId, amount);
    }

    function snapshotHash(uint64 snapshotId) external view returns (bytes32) {
        return availabilitySnapshots[snapshotId].snapshotHash;
    }

    function _snapshotHash(
        uint64 snapshotId,
        bytes32 operationId,
        uint256 gross,
        uint256 reservedBefore,
        uint256 protectedAmount,
        uint256 available,
        uint256 createdAtBlock
    ) private view returns (bytes32) {
        return keccak256(abi.encode(
            SNAPSHOT_DOMAIN,
            block.chainid,
            address(this),
            address(token),
            snapshotId,
            operationId,
            address(allocator),
            createdAtBlock,
            gross,
            reservedBefore,
            protectedAmount,
            available
        ));
    }

    function _requireAllocableAccounting(uint256 gross) private view {
        if (totalReserved > gross) revert AccountingInconsistent();
        if (totalReserved + protectedCapital > gross) revert AccountingInconsistent();
    }

    function _requireDecrease(uint256 beforeBalance, uint256 afterBalance, uint256 amount) private pure {
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert TokenDeltaMismatch();
    }

    function _requireIncrease(uint256 beforeBalance, uint256 afterBalance, uint256 amount) private pure {
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert TokenDeltaMismatch();
    }
}
