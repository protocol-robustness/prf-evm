// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrfChainInstanceGenesis} from "../interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfAuthority} from "../interfaces/IPrfAuthority.sol";

/// @title PrfChainInstanceGenesis
/// @notice Sealed anchor for a concrete EVM execution instance of one PRF/SEW protocol genesis.
/// @dev
/// Hash boundary:
/// - `chainInstanceGenesisRoot` is the authoritative PRF canonical SHA-256 root computed off-chain.
/// - `localProjectionHash` is a distinct EVM-native keccak256 digest over observable local fields.
/// - deployment transaction/block/timestamp/sealer are deliberately NOT part of either semantic root.
///
/// Deployment is two-stage to avoid a CREATE2/self-code-hash cycle:
/// 1. Deploy this contract and the authority adapter.
/// 2. Compute the canonical chain-instance genesis root off-chain using their final addresses/code hashes.
/// 3. Call `sealGenesis` once.
contract PrfChainInstanceGenesis is ERC165, IPrfChainInstanceGenesis {
    bytes32 private constant LOCAL_PROJECTION_DOMAIN =
        keccak256("PRF_CHAIN_INSTANCE_LOCAL_PROJECTION_V1");

    bytes32 public immutable override protocolGenesisRoot;
    uint256 public immutable override executionChainId;
    uint256 public immutable override settlementChainId;

    address public immutable override authorityAdapter;
    bytes32 public immutable override initialAuthorityStateRoot;
    bytes32 public immutable override initialConfigurationRoot;

    address public sealer;

    bytes32 public override chainInstanceGenesisRoot;
    bytes32 public override genesisRuntimeCodeHash;
    bytes32 public override authorityAdapterRuntimeCodeHash;
    bool public isSealedState;

    event GenesisSealed(
        bytes32 indexed protocolGenesisRoot,
        bytes32 indexed chainInstanceGenesisRoot,
        uint256 indexed executionChainId,
        uint256 settlementChainId,
        address authorityAdapter,
        bytes32 genesisRuntimeCodeHash,
        bytes32 authorityAdapterRuntimeCodeHash,
        bytes32 localProjectionHash
    );

    error ZeroRoot();
    error ZeroAddress();
    error ExecutionChainMismatch(uint256 declaredChainId, uint256 actualChainId);
    error AuthorityAdapterHasNoCode(address adapter);
    error AuthorityProtocolMismatch(bytes32 expected, bytes32 actual);
    error AuthorityStateMismatch(bytes32 expected, bytes32 actual);
    error OnlySealer(address caller, address expected);
    error AlreadySealed();
    error RuntimeCodeHashMismatch(address account, bytes32 expected, bytes32 actual);

    constructor(
        bytes32 protocolGenesisRoot_,
        uint256 executionChainId_,
        uint256 settlementChainId_,
        address authorityAdapter_,
        bytes32 initialAuthorityStateRoot_,
        bytes32 initialConfigurationRoot_,
        address sealer_
    ) {
        if (
            protocolGenesisRoot_ == bytes32(0) ||
            initialAuthorityStateRoot_ == bytes32(0) ||
            initialConfigurationRoot_ == bytes32(0)
        ) revert ZeroRoot();

        if (authorityAdapter_ == address(0) || sealer_ == address(0)) revert ZeroAddress();
        if (authorityAdapter_.code.length == 0) revert AuthorityAdapterHasNoCode(authorityAdapter_);

        IPrfAuthority authority = IPrfAuthority(authorityAdapter_);
        if (authority.protocolGenesisRoot() != protocolGenesisRoot_) {
            revert AuthorityProtocolMismatch(
                protocolGenesisRoot_,
                authority.protocolGenesisRoot()
            );
        }
        if (authority.authorityStateRoot() != initialAuthorityStateRoot_) {
            revert AuthorityStateMismatch(
                initialAuthorityStateRoot_,
                authority.authorityStateRoot()
            );
        }

        if (executionChainId_ != block.chainid) {
            revert ExecutionChainMismatch(executionChainId_, block.chainid);
        }
        if (settlementChainId_ == 0) revert ZeroRoot();

        protocolGenesisRoot = protocolGenesisRoot_;
        executionChainId = executionChainId_;
        settlementChainId = settlementChainId_;
        authorityAdapter = authorityAdapter_;
        initialAuthorityStateRoot = initialAuthorityStateRoot_;
        initialConfigurationRoot = initialConfigurationRoot_;
        sealer = sealer_;
    }

    /// @notice Permanently seals the canonical chain-instance root and runtime code identities.
    /// @dev `canonicalChainInstanceGenesisRoot` is computed by PRF canonical hashing off-chain.
    ///      The contract verifies the two runtime code hashes against live EVM state.
    function sealGenesis(
        bytes32 canonicalChainInstanceGenesisRoot,
        bytes32 expectedGenesisRuntimeCodeHash,
        bytes32 expectedAuthorityAdapterRuntimeCodeHash
    ) external {
        if (msg.sender != sealer) revert OnlySealer(msg.sender, sealer);
        if (isSealedState) revert AlreadySealed();
        if (canonicalChainInstanceGenesisRoot == bytes32(0)) revert ZeroRoot();

        bytes32 actualGenesisCodeHash = address(this).codehash;
        bytes32 actualAuthorityCodeHash = authorityAdapter.codehash;

        if (actualGenesisCodeHash != expectedGenesisRuntimeCodeHash) {
            revert RuntimeCodeHashMismatch(
                address(this),
                expectedGenesisRuntimeCodeHash,
                actualGenesisCodeHash
            );
        }
        if (actualAuthorityCodeHash != expectedAuthorityAdapterRuntimeCodeHash) {
            revert RuntimeCodeHashMismatch(
                authorityAdapter,
                expectedAuthorityAdapterRuntimeCodeHash,
                actualAuthorityCodeHash
            );
        }

        genesisRuntimeCodeHash = actualGenesisCodeHash;
        authorityAdapterRuntimeCodeHash = actualAuthorityCodeHash;
        chainInstanceGenesisRoot = canonicalChainInstanceGenesisRoot;
        isSealedState = true;
        // Deployment authority is provenance, not continuing protocol authority.
        // Clearing it also prevents any later sealing authority from surviving genesis.
        sealer = address(0);

        emit GenesisSealed(
            protocolGenesisRoot,
            canonicalChainInstanceGenesisRoot,
            executionChainId,
            settlementChainId,
            authorityAdapter,
            actualGenesisCodeHash,
            actualAuthorityCodeHash,
            localProjectionHash()
        );
    }

    /// @inheritdoc IPrfChainInstanceGenesis
    function localProjectionHash() public view override returns (bytes32) {
        bytes32 selfCodeHash = isSealedState ? genesisRuntimeCodeHash : address(this).codehash;
        bytes32 adapterCodeHash =
            isSealedState ? authorityAdapterRuntimeCodeHash : authorityAdapter.codehash;

        return keccak256(
            abi.encode(
                LOCAL_PROJECTION_DOMAIN,
                protocolGenesisRoot,
                executionChainId,
                settlementChainId,
                address(this),
                selfCodeHash,
                authorityAdapter,
                adapterCodeHash,
                initialAuthorityStateRoot,
                initialConfigurationRoot
            )
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IPrfChainInstanceGenesis).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
