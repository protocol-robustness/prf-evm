$manifest[0] as $m
| $bundle[0]["base-input"] as $base
| $base
| .["prepared-operation"] |= (. + {
    "operation-id": $m.operationId,
    initiator: $m.deployer,
    "chain-id": ($m.chainId | tostring),
    reserve: $m.contracts.reserve,
    token: $m.contracts.token,
    allocator: $m.contracts.allocator,
    "configuration-root": $m.configurationRoot,
    "configuration-epoch": ($m.configurationEpoch | tostring),
    "source-verifier-id": $m.localOnly.sourceVerifierId,
    "source-program-vkey": $m.programVKey,
    "source-program-elf-sha256": $m.programElfSha256,
    "source-statement-schema": $m.sourceStatementSchema,
    "source-public-values-schema": $m.publicValuesSchema,
    "execution-verifier-id": $m.localOnly.executionVerifierId,
    "execution-statement-schema": $m.localOnly.executionStatementSchema,
    "execution-public-values-schema": $m.localOnly.executionPublicValuesSchema,
    "policy-root": $m.policyRoot,
    "beneficiary-profile": $m.beneficiaryProfile,
    "residual-recipient": $m.localOnly.residualRecipient
  })
| .["economic-reserve-state"] = {
    "gross-balance": ($m.economicReserveState.grossBalance | tostring),
    "reserved-before": ($m.economicReserveState.reservedBefore | tostring),
    "protected-capital": ($m.economicReserveState.protectedCapital | tostring),
    "available-amount": ($m.economicReserveState.availableAmount | tostring),
    "availability-revision": ($m.economicReserveState.availabilityRevision | tostring)
  }
| .["reserve-binding-root"] = ("sha256:" + ($m.reserveBindingRoot | sub("^0x"; "")))
