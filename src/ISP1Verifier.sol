// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice SP1 Verifier Interface (mirrors sp1-contracts ISP1Verifier).
interface ISP1Verifier {
    /// @notice Verifies a proof with given public values and vkey.
    /// @dev The first 4 bytes of proofBytes must match the first 4 bytes of
    ///      the target verifier's VERIFIER_HASH.
    /// @param programVKey The verification key for the RISC-V program.
    /// @param publicValues The public values encoded as bytes.
    /// @param proofBytes The proof of the program execution encoded as bytes.
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata proofBytes
    ) external view;
}

interface ISP1VerifierWithHash is ISP1Verifier {
    /// @notice Returns the hash of the verifier.
    function VERIFIER_HASH() external pure returns (bytes32);
}
