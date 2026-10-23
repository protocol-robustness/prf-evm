// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice Trusted validator for one fully specified PRF authority transition.
/// @dev The validator must authenticate the policy-pinned transition key and
///      attest that the canonical authority-state.v1 predecessor/successor,
///      capability checks, decision preimages and EVM mutation payload all
///      derive the supplied execution commitment. Its runtime and key binding
///      are deployment qualification inputs, not implied by this interface.
interface IPrfAuthorityTransitionValidator {
    function localAuthorityPolicyRoot() external view returns (bytes32);

    function isValidTransition(bytes32 executionCommitment, bytes calldata attestation)
        external
        view
        returns (bool);
}
