// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IOnchainShortfallReserveV2} from "../../src/interfaces/IOnchainShortfallReserveV2.sol";

contract V2RatificationReserveMock is IOnchainShortfallReserveV2 {
    bytes32 public expectedCommitment;
    bool public shouldRevert;
    uint256 public fundedAmount = 70;
    uint64 public revision = 18;

    function configure(bytes32 commitment_, bool shouldRevert_, uint256 amount_, uint64 revision_) external {
        expectedCommitment = commitment_;
        shouldRevert = shouldRevert_;
        fundedAmount = amount_;
        revision = revision_;
    }

    function ratifyAndFund(RatificationRequest calldata request)
        external returns (RatificationResult memory result)
    {
        if (shouldRevert || request.expectedReserveStateCommitment != expectedCommitment) revert("RESERVE_RATIFICATION_REVERT");
        result = RatificationResult(keccak256(abi.encode(request.preparedOperationRoot, request.expectedReserveStateCommitment)), 1, fundedAmount, revision);
    }
}
