// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISourceBoundProRataAssuranceV2} from "../../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IShortfallAllocatorV2} from "../../src/interfaces/IShortfallAllocatorV2.sol";
import {IOnchainShortfallReserveV2} from "../../src/interfaces/IOnchainShortfallReserveV2.sol";

interface IV2ReentryTarget {
    function reenter() external;
}

contract V2RatificationAssuranceMock is ISourceBoundProRataAssuranceV2 {
    RatificationPayload public payload;
    bool public shouldRevert;
    mapping(bytes32 => bool) public consumed;

    function configure(RatificationPayload calldata payload_) external { payload = payload_; }
    function setShouldRevert(bool value) external { shouldRevert = value; }

    function consumeForRatification(bytes32 operationId, bytes32 preparedRoot, bytes32 commitment)
        external returns (RatificationPayload memory result)
    {
        if (shouldRevert) revert("ASSURANCE_REVERT");
        if (consumed[payload.receiptId]) revert("ASSURANCE_REPLAY");
        if (payload.operationId != operationId || payload.preparedOperationRoot != preparedRoot || payload.reserveStateCommitment != commitment) revert("ASSURANCE_MISMATCH");
        consumed[payload.receiptId] = true;
        result = payload;
    }
}

contract V2RatificationAllocatorMock is IShortfallAllocatorV2 {
    mapping(bytes32 => Operation) private _operations;
    bool public revertCreate;
    bool public revertFund;
    // 0: none, 1: allocation root, 2: amount, 3: token, 4: state, 5: operation id.
    uint8 public createFault;
    bool public malformedFundState;
    address public reentryTarget;
    IOnchainShortfallReserveV2 public reserveTarget;
    IOnchainShortfallReserveV2.RatificationRequest private _reentryRequest;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    function configureReserveReentry(
        IOnchainShortfallReserveV2 reserve_,
        IOnchainShortfallReserveV2.RatificationRequest calldata request
    ) external {
        reserveTarget = reserve_;
        _reentryRequest = request;
    }

    function startRatification(
        IOnchainShortfallReserveV2 reserve_,
        IOnchainShortfallReserveV2.RatificationRequest calldata request
    ) external returns (IOnchainShortfallReserveV2.RatificationResult memory) {
        return reserve_.ratifyAndFund(request);
    }

    function setModes(bool revertCreate_, bool revertFund_, bool malformedCreate_) external {
        revertCreate = revertCreate_;
        revertFund = revertFund_;
        // Preserve the legacy malformed-create mode as an amount mismatch.
        createFault = malformedCreate_ ? 2 : 0;
    }

    function setCreateFault(uint8 value) external {
        createFault = value;
    }

    function setMalformedFundState(bool value) external {
        malformedFundState = value;
    }
    function setReentryTarget(address target) external { reentryTarget = target; }

    function create(bytes32 operationId, bytes32 allocationBindingRoot, bytes32 realizedStatementRoot,
        IERC20 token, uint256 amount, address residualRecipient) external {
        if (revertCreate) revert("ALLOCATOR_CREATE_REVERT");
        if (reentryTarget != address(0)) IV2ReentryTarget(reentryTarget).reenter();
        if (address(reserveTarget) != address(0)) {
            reentryAttempted = true;
            try reserveTarget.ratifyAndFund(_reentryRequest) {
                reentrySucceeded = true;
            } catch {}
        }
        if (_operations[operationId].state != State.None) revert("ALLOCATOR_ALREADY_EXISTS");
        bytes32 storedOperationId = createFault == 5 ? bytes32(uint256(0xBAD)) : operationId;
        _operations[storedOperationId] = Operation(
            createFault == 4 ? State.Funded : State.Created,
            createFault == 1 ? bytes32(uint256(0xBAD)) : allocationBindingRoot,
            realizedStatementRoot,
            createFault == 3 ? IERC20(address(1)) : token,
            createFault == 2 ? amount + 1 : amount,
            residualRecipient
        );
    }

    function fund(bytes32 operationId) external {
        if (revertFund) revert("ALLOCATOR_FUND_REVERT");
        Operation storage operation_ = _operations[operationId];
        if (operation_.state != State.Created) revert("ALLOCATOR_BAD_STATE");
        if (address(operation_.token) != address(1)) {
            if (!operation_.token.transferFrom(msg.sender, address(this), operation_.amount)) revert("ALLOCATOR_TRANSFER_REVERT");
        }
        operation_.state = malformedFundState ? State.Created : State.Funded;
    }

    function operation(bytes32 operationId) external view returns (Operation memory) { return _operations[operationId]; }
}

contract V2ReentrantCallerMock is IV2ReentryTarget {
    address public target;
    bool public attempted;
    function setTarget(address target_) external { target = target_; }
    function reenter() external {
        attempted = true;
        if (target != address(0)) target.call(abi.encodeWithSignature("ratifyAndFund(uint256)", 70));
    }
}
