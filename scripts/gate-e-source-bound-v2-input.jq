$manifest[0] as $m | $identity[0] as $i |
{
  schema: "prf/onchain-shortfall-v2-assurance-fixture.v1",
  "prepared-operation": {
    "operation-id": $m.operationId,
    initiator: $m.deployer,
    "chain-id": ($m.chainId | tostring),
    reserve: $m.contracts.reserve,
    token: $m.contracts.token,
    allocator: $m.contracts.allocator,
    "configuration-root": $m.configurationRoot,
    "configuration-epoch": ($m.configurationEpoch | tostring),
    "source-verifier-id": $m.localOnly.sourceVerifierId,
    "execution-verifier-id": $m.localOnly.executionVerifierId,
    "source-program-vkey": $i.vkey,
    "source-program-elf-sha256": $i.elf_sha256,
    "source-statement-schema": $sourceStatementSchema,
    "source-public-values-schema": $sourcePublicValuesSchema,
    "execution-statement-schema": $m.localOnly.executionStatementSchema,
    "execution-public-values-schema": $m.localOnly.executionPublicValuesSchema,
    "policy-root": $m.policyRoot,
    "residual-recipient": $m.localOnly.residualRecipient
  },
  "economic-reserve-state": {
    "gross-balance": ($m.economicReserveState.grossBalance | tostring),
    "reserved-before": ($m.economicReserveState.reservedBefore | tostring),
    "protected-capital": ($m.economicReserveState.protectedAmount | tostring),
    "available-amount": ($m.economicReserveState.availableAmount | tostring),
    "availability-revision": ($m.economicReserveState.revision | tostring)
  },
  "allocation-binding-root": $m.allocationBindingRoot,
  "realized-statement-root": $m.realizedStatementRoot
}
