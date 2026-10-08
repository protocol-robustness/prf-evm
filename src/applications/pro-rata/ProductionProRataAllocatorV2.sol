// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShortfallAllocatorV2} from "../../interfaces/IShortfallAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../../interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IEntitlementRepresentationV1} from "../../interfaces/IEntitlementRepresentationV1.sol";

/// @notice V2 custody successor used by atomic Shortfall ratification.
/// @dev Create/fund is atomic at the reserve boundary. Funded capital can be
/// returned before downstream reliance; allocation claims remain separate.
contract ProductionProRataAllocatorV2 is IShortfallAllocatorV2, IShortfallEntitlementAllocatorV1 {
    address public immutable operationAuthority;
    address public fundingAuthority;
    bool public fundingAuthorityBound;
    mapping(bytes32 => Operation) private _operations;
    mapping(bytes32 => IShortfallEntitlementAllocatorV1.EntitlementOperation) private _entitlementOperations;
    mapping(bytes32 => address) public override(IShortfallAllocatorV2, IShortfallEntitlementAllocatorV1) fundingSource;
    bool private _entered;

    error OnlyOperationAuthority(address caller);
    error InvalidOperation();
    error InvalidState(State actual);
    error TokenDeltaMismatch();
    error Reentrant();
    error FundingAuthorityAlreadyBound();
    error InvalidFundingAuthority();
    error EntitlementRepresentationMismatch();
    error InvalidFundingSource();

    modifier onlyAuthority() {
        if (msg.sender != fundingAuthority) revert OnlyOperationAuthority(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrant();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address authority_) {
        if (authority_ == address(0)) revert InvalidOperation();
        operationAuthority = authority_;
        fundingAuthority = authority_;
    }

    /// @notice Permanently binds the reserve/controller that may create and fund operations.
    function bindFundingAuthority(address authority_) external {
        if (msg.sender != operationAuthority) revert OnlyOperationAuthority(msg.sender);
        if (fundingAuthorityBound) revert FundingAuthorityAlreadyBound();
        if (authority_ == address(0)) revert InvalidFundingAuthority();
        fundingAuthority = authority_;
        fundingAuthorityBound = true;
    }

    function create(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 realizedStatementRoot,
        IERC20 token,
        uint256 amount,
        address residualRecipient
    ) external onlyAuthority {
        if (
            operationId == bytes32(0) || allocationBindingRoot == bytes32(0) || realizedStatementRoot == bytes32(0)
                || address(token) == address(0) || amount == 0 || residualRecipient == address(0)
        ) revert InvalidOperation();
        if (_operations[operationId].state != State.None || _entitlementOperations[operationId].state != State.None) {
            revert InvalidState(_operations[operationId].state);
        }
        _operations[operationId] =
            Operation(State.Created, allocationBindingRoot, realizedStatementRoot, token, amount, residualRecipient);
    }

    function fund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage current = _operations[operationId];
        if (current.state != State.Created) revert InvalidState(current.state);
        uint256 reserveBefore = current.token.balanceOf(msg.sender);
        uint256 allocatorBefore = current.token.balanceOf(address(this));
        if (!current.token.transferFrom(msg.sender, address(this), current.amount)) revert TokenDeltaMismatch();
        if (
            reserveBefore < current.token.balanceOf(msg.sender)
                || reserveBefore - current.token.balanceOf(msg.sender) != current.amount
                || current.token.balanceOf(address(this)) < allocatorBefore
                || current.token.balanceOf(address(this)) - allocatorBefore != current.amount
        ) {
            revert TokenDeltaMismatch();
        }
        current.state = State.Funded;
        fundingSource[operationId] = msg.sender;
    }

    /// @notice Returns funded legacy capital to the reserve that supplied it.
    /// @dev Funding is cancellable only before any downstream reliance transition.
    function cancelAndRefund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage current = _operations[operationId];
        if (current.state != State.Funded) revert InvalidState(current.state);
        address source = fundingSource[operationId];
        if (source == address(0)) revert InvalidFundingSource();

        uint256 allocatorBefore = current.token.balanceOf(address(this));
        uint256 sourceBefore = current.token.balanceOf(source);
        current.state = State.Cancelled;
        if (!current.token.transfer(source, current.amount)) revert TokenDeltaMismatch();
        if (
            allocatorBefore < current.token.balanceOf(address(this))
                || allocatorBefore - current.token.balanceOf(address(this)) != current.amount
                || current.token.balanceOf(source) < sourceBefore
                || current.token.balanceOf(source) - sourceBefore != current.amount
        ) revert TokenDeltaMismatch();
    }

    function operation(bytes32 operationId) external view returns (Operation memory) {
        return _operations[operationId];
    }

    /// @notice Creates the successor funding record from an admitted entitlement
    ///         tuple, keeping those roots distinct from the V2 statement-root ABI.
    function createEntitlement(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 descriptorRoot,
        bytes32 evmEntitlementTableRoot,
        uint256 entitlementCount,
        uint256 entitlementTotal,
        bytes32 allocationClaimRoot,
        IERC20 token,
        uint256 amount,
        address residualRecipient
    ) external onlyAuthority {
        if (
            operationId == bytes32(0) || allocationBindingRoot == bytes32(0) || descriptorRoot == bytes32(0)
                || evmEntitlementTableRoot == bytes32(0) || entitlementCount == 0 || entitlementTotal == 0
                || allocationClaimRoot == bytes32(0) || address(token) == address(0) || amount == 0
                || residualRecipient == address(0) || entitlementTotal != amount
        ) revert InvalidOperation();
        if (_operations[operationId].state != State.None || _entitlementOperations[operationId].state != State.None) {
            revert InvalidState(_entitlementOperations[operationId].state);
        }
        _entitlementOperations[operationId] = IShortfallEntitlementAllocatorV1.EntitlementOperation(
            State.Created,
            allocationBindingRoot,
            descriptorRoot,
            evmEntitlementTableRoot,
            entitlementCount,
            entitlementTotal,
            allocationClaimRoot,
            token,
            amount,
            residualRecipient,
            address(0)
        );
    }

    function fundEntitlement(bytes32 operationId) external onlyAuthority nonReentrant {
        IShortfallEntitlementAllocatorV1.EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Created) revert InvalidState(current.state);
        uint256 reserveBefore = current.token.balanceOf(msg.sender);
        uint256 allocatorBefore = current.token.balanceOf(address(this));
        if (!current.token.transferFrom(msg.sender, address(this), current.amount)) revert TokenDeltaMismatch();
        if (
            reserveBefore < current.token.balanceOf(msg.sender)
                || reserveBefore - current.token.balanceOf(msg.sender) != current.amount
                || current.token.balanceOf(address(this)) < allocatorBefore
                || current.token.balanceOf(address(this)) - allocatorBefore != current.amount
        ) revert TokenDeltaMismatch();
        current.state = State.Funded;
        fundingSource[operationId] = msg.sender;
    }

    /// @notice Returns a funded pre-activation operation to the exact source that funded it.
    function cancelAndRefundEntitlement(bytes32 operationId) external onlyAuthority nonReentrant {
        IShortfallEntitlementAllocatorV1.EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Funded) revert InvalidState(current.state);
        address source = fundingSource[operationId];
        if (source == address(0)) revert InvalidFundingSource();

        uint256 allocatorBefore = current.token.balanceOf(address(this));
        uint256 sourceBefore = current.token.balanceOf(source);
        current.state = State.Cancelled;
        if (!current.token.transfer(source, current.amount)) revert TokenDeltaMismatch();
        if (
            allocatorBefore < current.token.balanceOf(address(this))
                || allocatorBefore - current.token.balanceOf(address(this)) != current.amount
                || current.token.balanceOf(source) < sourceBefore
                || current.token.balanceOf(source) - sourceBefore != current.amount
        ) revert TokenDeltaMismatch();
    }

    function entitlementOperation(bytes32 operationId)
        external
        view
        returns (IShortfallEntitlementAllocatorV1.EntitlementOperation memory)
    {
        return _entitlementOperations[operationId];
    }

    /// @notice Makes a funded successor allocation executable only after its
    ///         deployed logical representation matches the admitted tuple.
    function activateEntitlement(bytes32 operationId, IEntitlementRepresentationV1 representation)
        external
        onlyAuthority
    {
        IShortfallEntitlementAllocatorV1.EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Funded) revert InvalidState(current.state);
        if (
            address(representation).code.length == 0 || representation.logicalRoot() != current.evmEntitlementTableRoot
                || representation.entitlementCount() != current.entitlementCount
                || representation.entitlementTotal() != current.entitlementTotal
                || current.amount != current.entitlementTotal
        ) revert EntitlementRepresentationMismatch();
        current.representation = address(representation);
        current.state = State.Activated;
    }
}
