// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISewGovernanceAuthority} from "./ISewGovernanceAuthority.sol";

/// @title IPrfAuthority
/// @notice Neutral PRF authority read surface.
/// @dev Extends the existing SEW-compatible ABI during the compatibility period.
///      PRF core code depends on this name; SEW integrations may continue using
///      ISewGovernanceAuthority without changing deployed selectors.
interface IPrfAuthority is ISewGovernanceAuthority {}
