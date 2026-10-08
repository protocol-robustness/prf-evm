// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOnchainShortfallReserveV2} from "../../src/interfaces/IOnchainShortfallReserveV2.sol";
import {IShortfallAllocatorV2} from "../../src/interfaces/IShortfallAllocatorV2.sol";

contract V2RatificationReserveMock is IOnchainShortfallReserveV2 {
    bytes32 public expectedCommitment;
    bool public shouldRevert;
    uint256 public fundedAmount = 70;
    uint64 public revision = 18;
    IERC20 private _tokenIdentity;
    IShortfallAllocatorV2 private _allocatorIdentity;

    function configureDeploymentIdentity(IERC20 token_, IShortfallAllocatorV2 allocator_) external {
        _tokenIdentity = token_;
        _allocatorIdentity = allocator_;
    }

    function token() external view returns (IERC20) {
        return _tokenIdentity;
    }

    function allocator() external view returns (IShortfallAllocatorV2) {
        return _allocatorIdentity;
    }

    function configure(bytes32 commitment_, bool shouldRevert_, uint256 amount_, uint64 revision_) external {
        expectedCommitment = commitment_;
        shouldRevert = shouldRevert_;
        fundedAmount = amount_;
        revision = revision_;
    }

    function cancelAndRefund(bytes32) external pure {
        revert("NOT_IMPLEMENTED");
    }

    function ratifyAndFund(RatificationRequest calldata request)
        external
        view
        returns (RatificationResult memory result)
    {
        if (shouldRevert || request.expectedReserveStateCommitment != expectedCommitment) {
            revert("RESERVE_RATIFICATION_REVERT");
        }
        result = RatificationResult(
            keccak256(abi.encode(request.preparedOperationRoot, request.expectedReserveStateCommitment)),
            1,
            fundedAmount,
            revision
        );
    }
}
