// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice Present-tense, governance-controlled withdrawal enforcement mode.
interface IEntitlementProofModeSource {
    /// @return mode 0 = Requested, 1 = Required. No other value is defined.
    function currentEntitlementProofMode() external view returns (uint8 mode);
}
