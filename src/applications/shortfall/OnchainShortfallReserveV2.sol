// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShortfallV2Commitments} from "../../verification/ShortfallV2Commitments.sol";
import {IOnchainShortfallReserveV2} from "../../interfaces/IOnchainShortfallReserveV2.sol";
import {IShortfallAllocatorV2} from "../../interfaces/IShortfallAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../../interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IOnchainShortfallEntitlementReserveV1} from "../../interfaces/IOnchainShortfallEntitlementReserveV1.sol";
import {IEntitlementRepresentationV1} from "../../interfaces/IEntitlementRepresentationV1.sol";

/// @notice V2 reserve accounting successor. This contract exposes deterministic
/// economic-state commitments but does not yet ratify, create, or fund operations.
contract OnchainShortfallReserveV2 is IOnchainShortfallReserveV2, IOnchainShortfallEntitlementReserveV1 {
    bytes32 public constant ECONOMIC_STATE_DOMAIN = keccak256("prf.economic-reserve-state.v2");
    bytes32 public constant OBSERVATION_DOMAIN = keccak256("prf.authoritative-reserve-observation.v2");

    IERC20 public immutable override token;
    address public immutable applicationAuthority;
    address public ratificationAuthority;
    bool public ratificationAuthorityBound;
    uint256 public immutable protectedCapital;
    IShortfallAllocatorV2 public immutable override allocator;

    uint64 public availabilityRevision;
    uint64 public nextSnapshotId = 1;
    uint256 public totalReserved;

    enum ReservationState {
        None,
        Active,
        Released
    }

    struct Reservation {
        ReservationState state;
        uint256 amount;
    }

    struct EconomicState {
        bytes32 preparedOperationRoot;
        bytes32 reserve;
        bytes32 token;
        uint256 grossBalance;
        uint256 reservedBefore;
        uint256 protectedAmount;
        uint256 availableAmount;
        uint64 revision;
        bytes32 commitment;
    }

    struct AuthoritativeObservation {
        bytes32 preparedOperationRoot;
        bytes32 reserveStateCommitment;
        uint64 snapshotId;
        uint256 createdAtBlock;
        bytes32 observationRoot;
    }

    mapping(bytes32 => Reservation) public reservations;
    bool public ratifying;
    bool private _entered;

    error ZeroValue();
    error InvalidReservation();
    error AccountingInconsistent();
    error InsufficientAvailability();
    error TokenDeltaMismatch();
    error OnlyApplicationAuthority(address caller);
    error OnlyRatificationAuthority(address caller);
    error RatificationAuthorityAlreadyBound();
    error InvalidRatificationAuthority();
    error CommitmentMismatch(bytes32 expected, bytes32 actual);
    error AllocatorMismatch();
    error Reentrant();
    error AllowanceMismatch();

    event Deposited(address indexed from, uint256 amount);
    event ReservationCreated(bytes32 indexed reservationId, uint256 amount, uint64 revision);
    event ReservationReleased(bytes32 indexed reservationId, uint256 amount, uint64 revision);
    event RatificationAuthorityBound(address indexed controller);
    event RatifiedAndFunded(
        bytes32 indexed operationId, bytes32 indexed observationRoot, uint256 amount, uint64 revision
    );

    modifier nonReentrant() {
        if (_entered) revert Reentrant();
        _entered = true;
        _;
        _entered = false;
    }

    modifier onlyApplicationAuthority() {
        if (msg.sender != applicationAuthority) revert OnlyApplicationAuthority(msg.sender);
        _;
    }

    modifier onlyRatificationAuthority() {
        if (msg.sender != ratificationAuthority) revert OnlyRatificationAuthority(msg.sender);
        _;
    }

    /// @notice Permanently binds the controller used for atomic V2 ratification.
    /// Ordinary reserve administration remains owned by applicationAuthority.
    function bindRatificationAuthority(address controller_) external onlyApplicationAuthority {
        if (ratificationAuthorityBound) revert RatificationAuthorityAlreadyBound();
        if (controller_ == address(0)) revert InvalidRatificationAuthority();
        ratificationAuthority = controller_;
        ratificationAuthorityBound = true;
        emit RatificationAuthorityBound(controller_);
    }

    constructor(
        IERC20 token_,
        address applicationAuthority_,
        uint256 protectedCapital_,
        IShortfallAllocatorV2 allocator_
    ) {
        if (address(token_) == address(0) || applicationAuthority_ == address(0) || address(allocator_) == address(0)) revert ZeroValue();
        token = token_;
        applicationAuthority = applicationAuthority_;
        ratificationAuthority = applicationAuthority_;
        protectedCapital = protectedCapital_;
        allocator = allocator_;
    }

    /// @dev V2 reference token policy is standard, non-rebasing, non-fee-on-transfer ERC-20.
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroValue();
        uint256 sourceBefore = token.balanceOf(msg.sender);
        uint256 reserveBefore = token.balanceOf(address(this));
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TokenDeltaMismatch();
        if (sourceBefore < token.balanceOf(msg.sender) || sourceBefore - token.balanceOf(msg.sender) != amount) {
            revert TokenDeltaMismatch();
        }
        if (token.balanceOf(address(this)) < reserveBefore || token.balanceOf(address(this)) - reserveBefore != amount) revert TokenDeltaMismatch();
        emit Deposited(msg.sender, amount);
    }

    function reserveForOtherObligation(bytes32 reservationId, uint256 amount) external onlyApplicationAuthority {
        if (reservationId == bytes32(0) || amount == 0 || reservations[reservationId].state != ReservationState.None) {
            revert InvalidReservation();
        }
        uint256 gross = token.balanceOf(address(this));
        uint256 available = _available(gross);
        if (amount > available) revert InsufficientAvailability();
        reservations[reservationId] = Reservation(ReservationState.Active, amount);
        totalReserved += amount;
        ++availabilityRevision;
        emit ReservationCreated(reservationId, amount, availabilityRevision);
    }

    function releaseOtherObligationReservation(bytes32 reservationId) external onlyApplicationAuthority {
        Reservation storage reservation = reservations[reservationId];
        if (reservation.state != ReservationState.Active) revert InvalidReservation();
        uint256 amount = reservation.amount;
        reservation.state = ReservationState.Released;
        totalReserved -= amount;
        ++availabilityRevision;
        emit ReservationReleased(reservationId, amount, availabilityRevision);
    }

    function ratifyAndFund(RatificationRequest calldata request)
        external
        onlyRatificationAuthority
        nonReentrant
        returns (RatificationResult memory result)
    {
        if (ratifying) revert Reentrant();
        uint256 gross = token.balanceOf(address(this));
        uint256 available = _available(gross);
        bytes32 actual = _commitment(request.preparedOperationRoot, gross, totalReserved, available);
        if (actual != request.expectedReserveStateCommitment) {
            revert CommitmentMismatch(request.expectedReserveStateCommitment, actual);
        }
        if (available == 0) revert InsufficientAvailability();

        ratifying = true;
        ++availabilityRevision;
        uint256 reservedAmount = available;
        totalReserved += reservedAmount;
        uint64 snapshotId = nextSnapshotId++;
        bytes32 observationRoot = keccak256(
            abi.encode(
                OBSERVATION_DOMAIN,
                request.preparedOperationRoot,
                request.expectedReserveStateCommitment,
                snapshotId,
                block.number
            )
        );

        allocator.create(
            request.operationId,
            request.allocationBindingRoot,
            request.realizedStatementRoot,
            token,
            reservedAmount,
            request.residualRecipient
        );
        IShortfallAllocatorV2.Operation memory created = allocator.operation(request.operationId);
        if (
            created.state != IShortfallAllocatorV2.State.Created || address(created.token) != address(token)
                || created.amount != reservedAmount || created.allocationBindingRoot != request.allocationBindingRoot
                || created.realizedStatementRoot != request.realizedStatementRoot
        ) revert AllocatorMismatch();

        uint256 reserveBefore = token.balanceOf(address(this));
        uint256 allocatorBefore = token.balanceOf(address(allocator));
        if (token.allowance(address(this), address(allocator)) != 0) revert AllowanceMismatch();
        if (!token.approve(address(allocator), reservedAmount)) revert AllowanceMismatch();
        allocator.fund(request.operationId);
        if (
            reserveBefore < token.balanceOf(address(this))
                || reserveBefore - token.balanceOf(address(this)) != reservedAmount
                || token.balanceOf(address(allocator)) < allocatorBefore
                || token.balanceOf(address(allocator)) - allocatorBefore != reservedAmount
                || token.allowance(address(this), address(allocator)) != 0
        ) revert TokenDeltaMismatch();
        IShortfallAllocatorV2.Operation memory funded = allocator.operation(request.operationId);
        if (funded.state != IShortfallAllocatorV2.State.Funded) revert AllocatorMismatch();

        totalReserved -= reservedAmount;
        ratifying = false;
        result = RatificationResult(observationRoot, snapshotId, reservedAmount, availabilityRevision);
        emit RatifiedAndFunded(request.operationId, observationRoot, reservedAmount, availabilityRevision);
    }

    /// @notice Additive successor funding handoff for the beneficiary-entitlement
    ///         proof profile. The existing V2 ratification ABI is unchanged.
    function ratifyAndFundEntitlement(
        IOnchainShortfallEntitlementReserveV1.EntitlementRatificationRequest calldata request
    )
        external
        override
        onlyRatificationAuthority
        nonReentrant
        returns (IOnchainShortfallEntitlementReserveV1.EntitlementRatificationResult memory result)
    {
        if (ratifying) revert Reentrant();
        if (
            request.operationId == bytes32(0) || request.preparedOperationRoot == bytes32(0)
                || request.allocationBindingRoot == bytes32(0) || request.descriptorRoot == bytes32(0)
                || request.evmEntitlementTableRoot == bytes32(0) || request.entitlementCount == 0
                || request.entitlementTotal == 0 || request.allocationClaimRoot == bytes32(0)
                || request.residualRecipient == address(0)
        ) revert ZeroValue();

        uint256 gross = token.balanceOf(address(this));
        uint256 available = _available(gross);
        bytes32 actual = _commitment(request.preparedOperationRoot, gross, totalReserved, available);
        if (actual != request.expectedReserveStateCommitment) {
            revert CommitmentMismatch(request.expectedReserveStateCommitment, actual);
        }
        if (available == 0 || request.entitlementTotal != available) {
            revert InsufficientAvailability();
        }

        ratifying = true;
        ++availabilityRevision;
        totalReserved += available;
        uint64 snapshotId = nextSnapshotId++;
        bytes32 observationRoot = keccak256(
            abi.encode(
                OBSERVATION_DOMAIN,
                request.preparedOperationRoot,
                request.expectedReserveStateCommitment,
                snapshotId,
                block.number
            )
        );

        IShortfallEntitlementAllocatorV1 entitlementAllocator = IShortfallEntitlementAllocatorV1(address(allocator));
        entitlementAllocator.createEntitlement(
            request.operationId,
            request.allocationBindingRoot,
            request.descriptorRoot,
            request.evmEntitlementTableRoot,
            request.entitlementCount,
            request.entitlementTotal,
            request.allocationClaimRoot,
            token,
            available,
            request.residualRecipient
        );
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory created =
            entitlementAllocator.entitlementOperation(request.operationId);
        if (
            created.state != IShortfallAllocatorV2.State.Created || address(created.token) != address(token)
                || created.amount != available || created.allocationBindingRoot != request.allocationBindingRoot
                || created.descriptorRoot != request.descriptorRoot
                || created.evmEntitlementTableRoot != request.evmEntitlementTableRoot
                || created.entitlementCount != request.entitlementCount
                || created.entitlementTotal != request.entitlementTotal
                || created.allocationClaimRoot != request.allocationClaimRoot
        ) revert AllocatorMismatch();

        uint256 reserveBefore = token.balanceOf(address(this));
        uint256 allocatorBefore = token.balanceOf(address(allocator));
        if (token.allowance(address(this), address(allocator)) != 0) revert AllowanceMismatch();
        if (!token.approve(address(allocator), available)) revert AllowanceMismatch();
        entitlementAllocator.fundEntitlement(request.operationId);
        if (
            reserveBefore < token.balanceOf(address(this))
                || reserveBefore - token.balanceOf(address(this)) != available
                || token.balanceOf(address(allocator)) < allocatorBefore
                || token.balanceOf(address(allocator)) - allocatorBefore != available
                || token.allowance(address(this), address(allocator)) != 0
        ) revert TokenDeltaMismatch();
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory funded =
            entitlementAllocator.entitlementOperation(request.operationId);
        if (funded.state != IShortfallAllocatorV2.State.Funded) revert AllocatorMismatch();

        totalReserved -= available;
        ratifying = false;
        result = IOnchainShortfallEntitlementReserveV1.EntitlementRatificationResult(
            observationRoot, snapshotId, available, availabilityRevision
        );
        emit RatifiedAndFunded(request.operationId, observationRoot, available, availabilityRevision);
    }

    /// @notice Forwards activation after comparing the deployed logical table
    ///         with the roots admitted and funded for this operation.
    function activateEntitlement(bytes32 operationId, IEntitlementRepresentationV1 representation)
        external
        onlyRatificationAuthority
    {
        IShortfallEntitlementAllocatorV1(address(allocator)).activateEntitlement(operationId, representation);
    }

    function economicState(bytes32 preparedOperationRoot) public view returns (EconomicState memory state) {
        uint256 gross = token.balanceOf(address(this));
        if (totalReserved > gross || totalReserved + protectedCapital > gross) revert AccountingInconsistent();
        uint256 available = gross - totalReserved - protectedCapital;
        state = EconomicState(
            preparedOperationRoot,
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(uint160(address(token)))),
            gross,
            totalReserved,
            protectedCapital,
            available,
            availabilityRevision,
            _commitment(preparedOperationRoot, gross, totalReserved, available)
        );
    }

    function authoritativeObservation(
        bytes32 preparedOperationRoot,
        bytes32 reserveStateCommitment,
        uint64 snapshotId,
        uint256 createdAtBlock
    ) external pure returns (AuthoritativeObservation memory observation) {
        observation = AuthoritativeObservation(
            preparedOperationRoot,
            reserveStateCommitment,
            snapshotId,
            createdAtBlock,
            keccak256(
                abi.encode(
                    OBSERVATION_DOMAIN, preparedOperationRoot, reserveStateCommitment, snapshotId, createdAtBlock
                )
            )
        );
    }

    function _available(uint256 gross) private view returns (uint256) {
        if (totalReserved > gross || totalReserved + protectedCapital > gross) revert AccountingInconsistent();
        return gross - totalReserved - protectedCapital;
    }

    function _commitment(bytes32 preparedOperationRoot, uint256 gross, uint256 reservedBefore, uint256 available)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                ECONOMIC_STATE_DOMAIN,
                preparedOperationRoot,
                bytes32(uint256(uint160(address(this)))),
                bytes32(uint256(uint160(address(token)))),
                gross,
                reservedBefore,
                protectedCapital,
                available,
                availabilityRevision
            )
        );
    }
}
