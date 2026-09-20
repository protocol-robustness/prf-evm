// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ISP1Verifier} from "../../src/verification/interfaces/ISP1Verifier.sol";

/// @title MockSP1Verifier
/// @notice Deterministic mock SP1 verifier for tests and development only.
/// @dev Mirrors the SP1 `verifyProof(programVKey, publicValues, proofBytes)`
///      contract with a deterministic commitment: it accepts only when
///      keccak256(proofBytes || programVKey || publicValues) equals the deployment
///      commitment. It does NOT return true unconditionally.
///
///      The mock is suitable only for tests. It is NOT a real cryptographic
///      verifier and must never be used in production or misrepresented as a
///      real proof.
contract MockSP1Verifier is ISP1Verifier {
    /// @notice The only accepted commitment.
    bytes32 public immutable mockProofCommitment;

    /// @notice Hash of the SP1 verifier (mirrors SP1's VERIFIER_HASH).
    bytes32 public immutable verifierHash;

    constructor(bytes32 mockProofCommitment_, bytes32 verifierHash_) {
        mockProofCommitment = mockProofCommitment_;
        verifierHash = verifierHash_;
    }

    /// @notice Deterministic mock verification.
    /// @dev Reverts when the commitment does not match, matching the real SP1
    ///      verifier's revert-on-invalid behavior.
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata proofBytes
    ) external view {
        bytes32 commitment = keccak256(abi.encodePacked(proofBytes, programVKey, publicValues));
        require(commitment == mockProofCommitment, "MockSP1Verifier: invalid proof");
    }
}
