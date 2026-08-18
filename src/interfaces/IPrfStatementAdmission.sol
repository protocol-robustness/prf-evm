// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IPrfStatementAdmission is IERC165 {
    function protocolGenesisRoot() external view returns (bytes32);
    function chainInstanceGenesisRoot() external view returns (bytes32);
    function expectedConfigurationRoot() external view returns (bytes32);
    function admittedCount() external view returns (uint256);

    function admitStatement(
        bytes32 statementRoot,
        bytes calldata proof,
        bytes calldata publicValues,
        bytes32 publicValuesDigest
    ) external returns (uint256);
}
