# GovGovernor Migration Notes

The supplied SEW `GovGovernor.sol` was used as the base.

## Intentional changes

### Constructor

Adds:

```solidity
bytes32 prfProtocolGenesisRoot_
```

No mainnet deployment exists, so this is intentionally a breaking constructor change.

### Governance-only mutation

These functions now use OpenZeppelin `onlyGovernance`:

```text
addNonCirculatingAddress
removeNonCirculatingAddress
setAbsoluteQuorum
```

The supplied contract checked only that `msg.sender == timelock`. With a TimelockController, an additional timelock proposer can potentially schedule calls that did not pass through the Governor voting path. `onlyGovernance` is the narrower intended boundary.

### `proposalNeedsQueuing`

Supplied implementation:

```solidity
function proposalNeedsQueuing(uint256)
    public view override(Governor, GovernorTimelockControl)
    returns (bool)
{
    return super.proposalNeedsQueuing(0);
}
```

Generated implementation forwards the actual proposal id:

```solidity
function proposalNeedsQueuing(uint256 proposalId)
    public view override(Governor, GovernorTimelockControl)
    returns (bool)
{
    return super.proposalNeedsQueuing(proposalId);
}
```

With current `GovernorTimelockControl` the result is always `true`, so this bug is currently observationally masked, but forwarding the real id is the correct compatibility behavior.

### Reporting-only circulating supply

The supplied implementation used `unchecked` subtraction.

Historical values use `getPastVotes`, not historical balances, so delegated voting power can make the value only an approximation. The generated version clamps to zero instead of permitting uint256 wraparound.

## PRF bridge

New `onlyGovernance` functions:

```text
authorisePrfDecision
revokePrfDecision
updatePrfAuthorityStateRoot
```

These are the only intended route from SEW proposal execution into the PRF authority adapter.
