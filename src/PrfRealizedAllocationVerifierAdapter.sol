// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @title PrfRealizedAllocationVerifierAdapter
/// @notice Binds the realized-allocation-statement.v1 SP1 program to the
///         EVM verification gateway.
///
///         Two duties:
///         1. Pins the SP1 program verification key for the
///            `realized-statement-sp1-program.v1` guest and delegates
///            cryptographic proof verification to an `ISP1Verifier`
///            (canonical SP1 Groth16 verifier, or MockSP1Verifier for tests).
///         2. Extracts the `statementRoot` from the guest's fixed-width EVM
///            public values (a single `bytes32`, ABI-decoded). No JSON parsing.
///
///         EVM boundary:
///           canonical statement
///             → SHA-256
///             → 32-byte root
///             → SP1 public value (bytes32)
///             → abi.decode(publicValues, (bytes32))
contract PrfRealizedAllocationVerifierAdapter {
    /// @notice The statement schema version committed by the SP1 guest.
    string public constant STATEMENT_SCHEMA_VERSION = "realized-allocation-statement.v1";

    ISP1Verifier public immutable sp1Verifier;
    bytes32 public immutable programVKey;
    bytes32 public immutable programElfSha256;

    error StatementRootMismatch(bytes32 expected, bytes32 actual);

    event StatementVerified(
        bytes32 indexed statementRoot,
        bytes32 programVKey,
        address verifier
    );

    constructor(
        ISP1Verifier sp1Verifier_,
        bytes32 programVKey_,
        bytes32 programElfSha256_
    ) {
        require(address(sp1Verifier_) != address(0), "PRA: zero verifier");
        require(programVKey_ != bytes32(0), "PRA: zero vkey");
        sp1Verifier = sp1Verifier_;
        programVKey = programVKey_;
        programElfSha256 = programElfSha256_;
    }

    /// @notice Verify that the SP1 proof is valid AND the public values yield
    ///         the expected statement root.
    /// @dev Reverts (fail-closed) if the SP1 proof is invalid or the public
    ///      values do not decode to the expected statement root.
    ///      Returns the extracted statement root on success.
    function verifyStatementProof(
        bytes32 expectedStatementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) external view returns (bytes32) {
        if (expectedStatementRoot == bytes32(0))
            revert StatementRootMismatch(bytes32(0), bytes32(0));

        sp1Verifier.verifyProof(programVKey, publicValues, proof);

        bytes32 extractedRoot = _decodeStatementRoot(publicValues);
        if (extractedRoot != expectedStatementRoot) {
            revert StatementRootMismatch(expectedStatementRoot, extractedRoot);
        }

        return extractedRoot;
    }

    /// @notice Extract only the statement root from public values (no proof verification).
    function extractStatementRoot(bytes calldata publicValues)
        external
        pure
        returns (bytes32)
    {
        return _decodeStatementRoot(publicValues);
    }

    /// @notice Decode the fixed-width EVM projection from public values.
    /// @dev Public values are raw committed bytes from the SP1 guest. The guest
    ///      commits exactly one `bytes32` (the statement root hash, big-endian).
    ///      We require length == 32 and decode as a fixed bytes32. The invariant
    ///      is: decoded root must equal the canonical SHA-256 statement root.
    function _decodeStatementRoot(bytes calldata publicValues)
        internal
        pure
        returns (bytes32)
    {
        if (publicValues.length != 32) revert InvalidPublicValuesLength(publicValues.length);
        return abi.decode(publicValues, (bytes32));
    }

    error InvalidPublicValuesLength(uint256 actualLength);
}
