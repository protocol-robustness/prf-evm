// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPrfConfigurationExecutor
/// @notice Expected-parent, once-only configuration transition surface.
interface IPrfConfigurationExecutor is IERC165 {
    function chainInstanceGenesisRoot() external view returns (bytes32);
    function currentConfigurationRoot() external view returns (bytes32);
    function currentEpoch() external view returns (uint64);
    function consumedDecisionRoots(bytes32 decisionRoot) external view returns (bool);

    function applyConfiguration(
        bytes32 decisionRoot,
        bytes32 newConfigurationRoot,
        uint64 nextEpoch,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32[] calldata targetProof
    ) external;
}
