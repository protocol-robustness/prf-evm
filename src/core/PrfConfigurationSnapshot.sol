// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IPrfChainInstanceGenesis} from "../interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfConfigurationExecutor} from "../interfaces/IPrfConfigurationExecutor.sol";

/// @title PrfConfigurationSnapshot
/// @notice Minimal example of the SEW prospective-governance pattern.
/// @dev A stateful protocol object can snapshot these values at creation and remain
///      insulated from later configuration epochs unless its own semantics explicitly allow change.
contract PrfConfigurationSnapshot {
    bytes32 public immutable protocolGenesisRoot;
    bytes32 public immutable chainInstanceGenesisRoot;
    bytes32 public immutable configurationRoot;
    uint64 public immutable configurationEpoch;

    error GenesisNotSealed();
    error ChainInstanceMismatch(bytes32 expected, bytes32 actual);

    constructor(
        IPrfChainInstanceGenesis genesis,
        IPrfConfigurationExecutor configuration
    ) {
        if (!genesis.isSealedState()) revert GenesisNotSealed();

        bytes32 instanceRoot = genesis.chainInstanceGenesisRoot();
        bytes32 executorInstanceRoot = configuration.chainInstanceGenesisRoot();
        if (instanceRoot != executorInstanceRoot) {
            revert ChainInstanceMismatch(instanceRoot, executorInstanceRoot);
        }

        protocolGenesisRoot = genesis.protocolGenesisRoot();
        chainInstanceGenesisRoot = instanceRoot;
        configurationRoot = configuration.currentConfigurationRoot();
        configurationEpoch = configuration.currentEpoch();
    }
}
