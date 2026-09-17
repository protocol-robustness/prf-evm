// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISP1Verifier} from "./ISP1Verifier.sol";
import {IPrfStatementVerifierAdapter} from "./interfaces/IPrfStatementVerifierAdapter.sol";

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
contract PrfRealizedAllocationVerifierAdapter is IPrfStatementVerifierAdapter {
    /// @notice The statement schema version committed by the SP1 guest (hash of string).
    bytes32 public immutable override statementSchemaVersion;

    /// @notice The public-values schema hash (e.g. keccak256("evm-bytes32-v1")).
    bytes32 public immutable override publicValuesSchema;

    ISP1Verifier public immutable sp1Verifier;
    bytes32 public immutable override programVKey;
    bytes32 public immutable override programElfSha256;

    error StatementRootMismatch(bytes32 expected, bytes32 actual);
    error InvalidPublicValuesLength(uint256 actualLength);
    error PublicValuesSchemaMismatch(bytes32 expected, bytes32 actual);

    event StatementVerified(
        bytes32 indexed statementRoot,
        bytes32 programVKey,
        address verifier
    );

    constructor(
        ISP1Verifier sp1Verifier_,
        bytes32 programVKey_,
        bytes32 programElfSha256_,
        string memory statementSchemaVersion_,
        string memory publicValuesSchema_
    ) {
        require(address(sp1Verifier_) != address(0), "PRA: zero verifier");
        require(programVKey_ != bytes32(0), "PRA: zero vkey");
        require(programElfSha256_ != bytes32(0), "PRA: zero ELF hash");
        statementSchemaVersion = keccak256(bytes(statementSchemaVersion_));
        publicValuesSchema = keccak256(bytes(publicValuesSchema_));
        sp1Verifier = sp1Verifier_;
        programVKey = programVKey_;
        programElfSha256 = programElfSha256_;
    }

    /// @notice Returns the verifier identity hash committed by this adapter.
    ///         Encodes programVKey + elfSha256 + statementSchemaVersion +
    ///         publicValuesSchema + verifier address.
    function verifierIdentityHash() external view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    address(sp1Verifier),
                    programVKey,
                    programElfSha256,
                    statementSchemaVersion,
                    publicValuesSchema
                )
            );
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
    ) external view override returns (bytes32) {
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
        view
        returns (bytes32)
    {
        return _decodeStatementRoot(publicValues);
    }

    /// @notice Decode the fixed-width EVM projection from public values.
    /// @dev Public values are raw committed bytes from the SP1 guest. The schema
    ///      is pinned at construction time as `publicValuesSchema`
    ///      (e.g. keccak256("evm-bytes32-v1")). For the current `evm-bytes32-v1`
    ///      schema, public values must be exactly 32 bytes, decoded as a
    ///      fixed bytes32 (the statement root hash, big-endian).
    ///
    ///      The schema check is explicit at runtime: the public-values length
    ///      is validated against the pinned `publicValuesSchema`, not an
    ///      implicit constant. The evm-bytes32-v1 schema requires 32 bytes.
    function _decodeStatementRoot(bytes calldata publicValues)
        internal
        view
        returns (bytes32)
    {
        if (publicValues.length != _expectedSchemaLength()) {
            revert InvalidPublicValuesLength(publicValues.length);
        }
        return abi.decode(publicValues, (bytes32));
    }

    /// @notice Returns the expected public-values length for the pinned schema.
    /// @dev Currently only `evm-bytes32-v1` (keccak256("evm-bytes32-v1")) is
    ///      supported, which maps to 32 bytes. This makes the schema check
    ///      explicit rather than implicit.
    function _expectedSchemaLength() internal view returns (uint256) {
        bytes32 expectedSchema = keccak256("evm-bytes32-v1");
        if (publicValuesSchema != expectedSchema) {
            revert PublicValuesSchemaMismatch(expectedSchema, publicValuesSchema);
        }
        return 32;
    }
}
