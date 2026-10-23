// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPrfAuthorityTransitionValidator} from "../interfaces/IPrfAuthorityTransitionValidator.sol";

/// @title PrfEcdsaAuthorityTransitionValidator
/// @notice Immutable EVM signature checker for a policy-v3 transition key.
/// @dev This contract authenticates an attestation over an execution commitment;
///      it does not recompute authority-state semantics. The trusted signer and
///      independent PRF semantic verifier remain explicit qualification inputs.
contract PrfEcdsaAuthorityTransitionValidator is IPrfAuthorityTransitionValidator {
    bytes32 public immutable override localAuthorityPolicyRoot;
    address public immutable transitionValidatorAddress;

    error ZeroPolicyRoot();
    error ZeroValidatorAddress();

    constructor(bytes32 localAuthorityPolicyRoot_, address transitionValidatorAddress_) {
        if (localAuthorityPolicyRoot_ == bytes32(0)) revert ZeroPolicyRoot();
        if (transitionValidatorAddress_ == address(0)) revert ZeroValidatorAddress();
        localAuthorityPolicyRoot = localAuthorityPolicyRoot_;
        transitionValidatorAddress = transitionValidatorAddress_;
    }

    /// @notice Check an EIP-191 personal-sign signature over the bytes32 PRF
    ///         authority transition execution commitment.
    function isValidTransition(bytes32 executionCommitment, bytes calldata attestation)
        external
        view
        override
        returns (bool)
    {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(
            MessageHashUtils.toEthSignedMessageHash(executionCommitment), attestation
        );
        return err == ECDSA.RecoverError.NoError && recovered == transitionValidatorAddress;
    }
}
