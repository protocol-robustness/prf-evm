// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @title IPrfProofVerifier
/// @notice Prover-neutral interface for verifying a proof statement.
/// @dev The proof system (SP1, RISC Zero, etc.) is selected by the
///      implementing adapter; callers depend only on this abstraction.
interface IPrfProofVerifier {
    /// @notice Verify a proof against a program verification key and the
    ///         committed public values, returning the statement root extracted
    ///         from the public values when verification succeeds.
    /// @param proof The proof bytes (provider-specific encoding).
    /// @param programVKey The program verification key.
    /// @param publicValues The public values committed by the program.
    /// @return The statement root extracted from the verified public values.
    ///         Reverts on verification failure.
    function verifyStatementProof(
        bytes calldata proof,
        bytes32 programVKey,
        bytes calldata publicValues
    ) external view returns (bytes32);
}
