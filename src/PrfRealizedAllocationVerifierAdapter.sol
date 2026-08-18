// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISP1Verifier} from "./ISP1Verifier.sol";

/// @title PrfRealizedAllocationVerifierAdapter
/// @notice Binds the realized-allocation-statement.v1 SP1 program to the
///         EVM verification gateway and performs structural validation of the
///         guest's UTF-8 JSON public values.
///
///         Two duties:
///         1. Pins the SP1 program verification key for the
///            `realized-statement-sp1-program.v1` guest and delegates
///            cryptographic proof verification to an `ISP1Verifier`
///            (canonical SP1 Groth16 verifier, or MockSP1Verifier for tests).
///         2. Extracts the `statement-root` from the guest's UTF-8 JSON
///            public values and verifies structural fields: `result/status`
///            must be "passing" and `schema-version` must be
///            "realized-allocation-statement.v1".
contract PrfRealizedAllocationVerifierAdapter {
    /// @notice The statement schema version committed by the SP1 guest.
    string public constant STATEMENT_SCHEMA_VERSION = "realized-allocation-statement.v1";

    ISP1Verifier public immutable sp1Verifier;
    bytes32 public immutable programVKey;
    bytes32 public immutable programElfSha256;

    error NotPassingStatus();
    error SchemaVersionMismatch(string expected, string actual);
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

    /// @notice Verify that the SP1 proof is valid AND the public values contain
    ///         the expected statement root.
    /// @dev Reverts (fail-closed) if the SP1 proof is invalid or the public
    ///      values do not structurally match the realized-allocation-statement.
    ///      Returns the extracted statement root on success.
    function verifyStatementProof(
        bytes32 expectedStatementRoot,
        bytes calldata proof,
        bytes calldata publicValues
    ) external view returns (bytes32) {
        if (expectedStatementRoot == bytes32(0))
            revert StatementRootMismatch(bytes32(0), bytes32(0));

        sp1Verifier.verifyProof(programVKey, publicValues, proof);

        bytes32 extractedRoot = _extractAndVerifyStatementRoot(publicValues);
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
        return _extractAndVerifyStatementRoot(publicValues);
    }

    function _extractAndVerifyStatementRoot(bytes calldata publicValues)
        internal
        pure
        returns (bytes32)
    {
        if (!_contains(publicValues, "passing")) revert NotPassingStatus();

        if (!_contains(publicValues, "realized-allocation-statement.v1"))
            revert SchemaVersionMismatch(
                STATEMENT_SCHEMA_VERSION,
                "not-found-in-public-values"
            );

        return _extractRootField(publicValues, "statement-root");
    }

    function _contains(bytes calldata haystack, string memory needle)
        internal
        pure
        returns (bool)
    {
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || haystack.length < needleBytes.length)
            return false;
        for (uint256 i = 0; i <= haystack.length - needleBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystack[i + j] != needleBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    /// @notice Extract a 32-byte hex root from a JSON key like `"field": "0x..."`.
    ///         Returns bytes32(0) if the field is not found or malformed.
    function _extractRootField(bytes calldata json, string memory fieldName)
        internal
        pure
        returns (bytes32)
    {
        bytes memory key = bytes(fieldName);

        for (uint256 i = 0; i + key.length + 3 <= json.length; i++) {
            if (json[i] != 0x22) continue;
            bool matchFound = true;
            for (uint256 j = 0; j < key.length; j++) {
                if (json[i + 1 + j] != key[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (!matchFound) continue;
            uint256 pos = i + 1 + key.length;
            if (json[pos] != 0x22) continue;
            pos++;

            while (pos < json.length && (json[pos] == 0x20 || json[pos] == 0x09)) {
                pos++;
            }
            if (pos >= json.length || json[pos] != 0x3a) continue;
            pos++;

            while (pos < json.length && (json[pos] == 0x20 || json[pos] == 0x09)) {
                pos++;
            }
            if (pos >= json.length || json[pos] != 0x22) continue;
            pos++;

            uint256 valueStart = pos;
            while (pos < json.length && json[pos] != 0x22) {
                pos++;
            }
            if (pos == valueStart) continue;

            bytes memory value = _slice(json, valueStart, pos - valueStart);
            if (
                value.length >= 2 &&
                value[0] == 0x30 &&
                (value[1] == 0x78 || value[1] == 0x58)
            ) {
                value = _slice(json, valueStart + 2, pos - valueStart - 2);
            }
            if (value.length != 64) continue;

            bytes32 result = _decodeHexBytes32(value);
            return result;
        }
        return bytes32(0);
    }

    function _hexNibble(bytes1 c) internal pure returns (uint8) {
        if (uint8(c) >= 0x30 && uint8(c) <= 0x39) return uint8(c) - 0x30;
        if (uint8(c) >= 0x61 && uint8(c) <= 0x66) return uint8(c) - 0x61 + 10;
        if (uint8(c) >= 0x41 && uint8(c) <= 0x46) return uint8(c) - 0x41 + 10;
        return 0xff;
    }

    function _slice(bytes calldata data, uint256 start, uint256 len)
        internal pure returns (bytes memory)
    {
        bytes memory result = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = data[start + i];
        }
        return result;
    }

    function _decodeHexBytes32(bytes memory hexStr)
        internal
        pure
        returns (bytes32)
    {
        if (hexStr.length != 64) return bytes32(0);
        bytes memory decoded = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            uint8 hi = _hexNibble(hexStr[i * 2]);
            uint8 lo = _hexNibble(hexStr[i * 2 + 1]);
            if (hi == 0xff || lo == 0xff) return bytes32(0);
            decoded[i] = bytes1((hi << 4) | lo);
        }
        return bytes32(decoded);
    }
}
