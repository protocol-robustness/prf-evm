// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IEntitlementProofModeSource} from "../../src/interfaces/IEntitlementProofModeSource.sol";

contract MockEntitlementProofModeSource is IEntitlementProofModeSource {
    uint8 public override currentEntitlementProofMode;

    function setMode(uint8 mode) external {
        require(mode <= 1, "invalid mode");
        currentEntitlementProofMode = mode;
    }
}
