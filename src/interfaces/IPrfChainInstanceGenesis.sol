// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPrfChainInstanceGenesis
/// @notice Immutable/sealed identity boundary for one PRF/SEW EVM execution instance.
/// @dev PRF canonical roots are externally computed SHA-256 roots represented as bytes32.
///      The EVM does not redefine the PRF canonical hash scheme.
interface IPrfChainInstanceGenesis is IERC165 {
    function protocolGenesisRoot() external view returns (bytes32);
    function chainInstanceGenesisRoot() external view returns (bytes32);

    function executionChainId() external view returns (uint256);
    function settlementChainId() external view returns (uint256);

    function authorityAdapter() external view returns (address);
    function initialAuthorityStateRoot() external view returns (bytes32);
    function initialConfigurationRoot() external view returns (bytes32);

    function genesisRuntimeCodeHash() external view returns (bytes32);
    function authorityAdapterRuntimeCodeHash() external view returns (bytes32);

    function isSealedState() external view returns (bool);

    /// @notice EVM-native digest binding the locally observable genesis projection.
    /// @dev This is NOT the PRF canonical chain-instance-genesis-root.
    function localProjectionHash() external view returns (bytes32);
}
