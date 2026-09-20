// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISourceBoundProRataAssuranceV2} from "../../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IShortfallAllocatorV2} from "../../src/interfaces/IShortfallAllocatorV2.sol";

contract V2RatificationHarness {
    enum State { None, Prepared, Ratifying, Funded }
    State public state;
    bytes32 public immutable operationId;
    bytes32 public immutable preparedRoot;
    bytes32 public immutable commitment;
    bytes32 public immutable allocationRoot;
    bytes32 public immutable realizedRoot;
    bytes32 public immutable receiptId;
    ISourceBoundProRataAssuranceV2 public immutable assurance;
    IShortfallAllocatorV2 public immutable allocator;

    error InvalidState(State actual);
    error AllocatorPostcondition();

    constructor(
        bytes32 operationId_, bytes32 preparedRoot_, bytes32 commitment_, bytes32 allocationRoot_,
        bytes32 realizedRoot_, bytes32 receiptId_, ISourceBoundProRataAssuranceV2 assurance_,
        IShortfallAllocatorV2 allocator_
    ) {
        operationId = operationId_; preparedRoot = preparedRoot_; commitment = commitment_;
        allocationRoot = allocationRoot_; realizedRoot = realizedRoot_; receiptId = receiptId_;
        assurance = assurance_; allocator = allocator_; state = State.Prepared;
    }

    function ratifyAndFund(uint256 amount) external {
        if (state != State.Prepared) revert InvalidState(state);
        state = State.Ratifying;
        ISourceBoundProRataAssuranceV2.RatificationPayload memory payload =
            assurance.consumeForRatification(operationId, preparedRoot, commitment);
        if (payload.allocationBindingRoot != allocationRoot || payload.realizedStatementRoot != realizedRoot || payload.receiptId != receiptId) revert AllocatorPostcondition();
        allocator.create(operationId, allocationRoot, realizedRoot, IERC20(address(1)), amount, address(2));
        IShortfallAllocatorV2.Operation memory created = allocator.operation(operationId);
        if (created.state != IShortfallAllocatorV2.State.Created || created.amount != amount || created.allocationBindingRoot != allocationRoot || created.realizedStatementRoot != realizedRoot) revert AllocatorPostcondition();
        allocator.fund(operationId);
        IShortfallAllocatorV2.Operation memory funded = allocator.operation(operationId);
        if (funded.state != IShortfallAllocatorV2.State.Funded) revert AllocatorPostcondition();
        state = State.Funded;
    }
}
