// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPrfConfigurationExecutor
/// @notice Expected-parent, once-only configuration transition surface.
///         Also tracks the active verifier-registry root, binding configuration root C
///         to verifier-registry root R through governance authorization.
interface IPrfConfigurationExecutor is IERC165 {
    function chainInstanceGenesisRoot() external view returns (bytes32);
    function currentConfigurationRoot() external view returns (bytes32);
    function currentVerifierRegistryRoot() external view returns (bytes32);
    function currentEpoch() external view returns (uint64);
    function consumedDecisionRoots(bytes32 decisionRoot) external view returns (bool);

    function applyConfiguration(
        bytes32 decisionRoot,
        bytes32 newConfigurationRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 nextEpoch,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32[] calldata targetProof
    ) external;
}
