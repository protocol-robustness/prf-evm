// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShortfallAllocatorV2} from "../../interfaces/IShortfallAllocatorV2.sol";

/// @notice V2 custody successor used by atomic Shortfall ratification.
/// @dev This deliberately exposes only create/fund. Allocation activation and
/// claims remain separate from the V2 reserve ratification boundary.
contract ProductionProRataAllocatorV2 is IShortfallAllocatorV2 {
    address public immutable operationAuthority;
    address public fundingAuthority;
    bool public fundingAuthorityBound;
    mapping(bytes32 => Operation) private _operations;
    bool private _entered;

    error OnlyOperationAuthority(address caller);
    error InvalidOperation();
    error InvalidState(State actual);
    error TokenDeltaMismatch();
    error Reentrant();
    error FundingAuthorityAlreadyBound();
    error InvalidFundingAuthority();

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
        if (operationId == bytes32(0) || allocationBindingRoot == bytes32(0)
            || realizedStatementRoot == bytes32(0) || address(token) == address(0)
            || amount == 0 || residualRecipient == address(0)) revert InvalidOperation();
        if (_operations[operationId].state != State.None) revert InvalidState(_operations[operationId].state);
        _operations[operationId] = Operation(
            State.Created, allocationBindingRoot, realizedStatementRoot, token, amount, residualRecipient
        );
    }

    function fund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage current = _operations[operationId];
        if (current.state != State.Created) revert InvalidState(current.state);
        uint256 reserveBefore = current.token.balanceOf(msg.sender);
        uint256 allocatorBefore = current.token.balanceOf(address(this));
        if (!current.token.transferFrom(msg.sender, address(this), current.amount)) revert TokenDeltaMismatch();
        if (reserveBefore < current.token.balanceOf(msg.sender)
            || reserveBefore - current.token.balanceOf(msg.sender) != current.amount
            || current.token.balanceOf(address(this)) < allocatorBefore
            || current.token.balanceOf(address(this)) - allocatorBefore != current.amount) {
            revert TokenDeltaMismatch();
        }
        current.state = State.Funded;
    }

    function operation(bytes32 operationId) external view returns (Operation memory) {
        return _operations[operationId];
    }
}
