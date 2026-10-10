#!/usr/bin/env python3
"""Read-only, block-pinned evidence capture for a completed local funding run.

File hashes and RPC observations are forensic evidence, never PRF semantic roots.
"""
import argparse
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path


def sha(data):
    return '0x' + hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('manifest', 'witness', 'fixture', 'broadcast', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--rpc-url', default='http://127.0.0.1:8545')
    args = parser.parse_args()
    require(not args.output.exists(), 'refusing to overwrite evidence')
    artifacts = {}
    objects = {}
    for name in ('manifest', 'witness', 'fixture', 'broadcast'):
        data = getattr(args, name).read_bytes()
        artifacts[name] = {'sha256': sha(data), 'bytes': len(data)}
        objects[name] = json.loads(data)
    manifest, fixture, broadcast = (objects[n] for n in ('manifest', 'fixture', 'broadcast'))
    require(fixture['proof_system'] == 'groth16', 'expected Groth16 fixture')
    require(fixture['gate_e']['manifest_digest'] == manifest['manifestDigest'], 'manifest mismatch')
    require(fixture['source']['witness_sha256'] == artifacts['witness']['sha256'], 'witness mismatch')
    require(fixture['vkey'] == manifest['programVKey'], 'VKey mismatch')
    require(fixture['elf_sha256'] == manifest['programElfSha256'], 'ELF mismatch')
    require(fixture['gate_e']['operation_id'] == manifest['operationId'], 'operation mismatch')
    values = bytes.fromhex(fixture['public_values'].removeprefix('0x'))
    require(len(values) == 288, 'public values must be 288 bytes')
    words = ['0x' + values[i:i + 32].hex() for i in range(0, 288, 32)]
    require(words[0] == '0x876f2aea9124d79f41dbdd389d498430987fa33bbb34408989849c478a7c2bde', 'schema mismatch')
    require(words[1] == manifest['preparedOperationRoot'].lower(), 'prepared root mismatch')
    require(words[2] == manifest['reserveStateCommitment'].lower(), 'reserve commitment mismatch')
    total = int(words[7], 16)
    count = int(words[6], 16)

    def rpc(method, params):
        payload = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
        request = urllib.request.Request(args.rpc_url, payload, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
        require('error' not in result, f'RPC error: {result.get("error")}')
        return result['result']

    chain = int(rpc('eth_chainId', []), 16)
    require(chain == 31337 == int(manifest['chainId']), 'local chain required')
    signatures = ['bindExecutionCaller(address)', 'admitStatement(bytes32,bytes32,bytes,bytes)',
                  'prepareSourceAssurance(bytes32,bytes32,bytes)', 'registerPrepared(bytes32)',
                  'fund(bytes32,address)']
    selectors = {subprocess.check_output(['cast', 'sig', signature], text=True).strip(): signature
                 for signature in signatures}
    receipts = []
    for tx in broadcast['transactions']:
        receipt = rpc('eth_getTransactionReceipt', [tx['hash']])
        require(receipt is not None and int(receipt['status'], 16) == 1, 'missing/failed receipt')
        transaction = rpc('eth_getTransactionByHash', [tx['hash']])
        require(transaction is not None and transaction['blockHash'] == receipt['blockHash'], 'transaction/block mismatch')
        recorded = next(r for r in broadcast['receipts'] if r['transactionHash'] == tx['hash'])
        require(recorded['blockHash'] == receipt['blockHash'], 'deployment reset or reorg')
        actual = 'constructor' if transaction['to'] is None else selectors.get(transaction['input'][:10])
        require(actual is not None, 'unknown transaction selector')
        receipts.append({'function': actual, 'broadcast_function': tx.get('function') or 'constructor',
                         'metadata_matches': actual == (tx.get('function') or 'constructor'),
                         'transaction': transaction, 'receipt': receipt})
    fund = [r for r in receipts if r['function'] == 'fund(bytes32,address)']
    require(len(fund) == 1, 'expected exactly one funding transaction')
    block = int(fund[0]['receipt']['blockNumber'], 16)
    contracts = manifest['contracts']
    op = manifest['operationId'].removeprefix('0x')

    def read(address, signature, arguments, at):
        selector = subprocess.check_output(['cast', 'sig', signature], text=True).strip()
        data = selector + ''.join(arguments)
        encoded = rpc('eth_call', [{'to': address, 'data': data}, hex(at)]).removeprefix('0x')
        require(len(encoded) % 64 == 0, 'non-static return')
        return ['0x' + encoded[i:i + 64] for i in range(0, len(encoded), 64)]

    def snapshot(at):
        def uint(address, signature, arguments=[]):
            return int(read(address, signature, arguments, at)[0], 16)
        return {
            'block': rpc('eth_getBlockByNumber', [hex(at), False]),
            'reserve_balance': uint(contracts['token'], 'balanceOf(address)', [contracts['reserve'][2:].rjust(64, '0')]),
            'allocator_balance': uint(contracts['token'], 'balanceOf(address)', [contracts['allocator'][2:].rjust(64, '0')]),
            'total_reserved': uint(contracts['reserve'], 'totalReserved()'),
            'protected_capital': uint(contracts['reserve'], 'protectedCapital()'),
            'outstanding_liability': uint(contracts['allocator'], 'outstandingLiability(bytes32)', [op]),
            'prepared_state': uint(contracts['preparedController'], 'state(bytes32)', [op]),
            'operation_words': read(contracts['allocator'], 'entitlementOperation(bytes32)', [op], at),
            'execution_caller_word': read(contracts['ratificationController'], 'executionCaller()', [], at)[0],
        }
    before, after = snapshot(block - 1), snapshot(block)
    expected_targets = {
        'bindExecutionCaller(address)': contracts['ratificationController'],
        'admitStatement(bytes32,bytes32,bytes,bytes)': contracts['admission'],
        'prepareSourceAssurance(bytes32,bytes32,bytes)': contracts['assurance'],
        'registerPrepared(bytes32)': contracts['ratificationController'],
        'fund(bytes32,address)': '0x' + after['execution_caller_word'][-40:],
    }
    require(len(receipts) == 6 and len({r['function'] for r in receipts}) == 6,
            'expected six distinct execution steps')
    for entry in receipts:
        target = expected_targets.get(entry['function'])
        if target:
            require(entry['transaction']['to'].lower() == target.lower(), 'wrong transaction target')
    ordered = sorted(receipts, key=lambda r: (int(r['receipt']['blockNumber'], 16),
                                             int(r['receipt']['transactionIndex'], 16)))
    require([r['function'] for r in ordered] == ['constructor'] + signatures,
            'unexpected execution order')
    receipts = ordered
    require(before['reserve_balance'] - after['reserve_balance'] == total, 'reserve delta mismatch')
    require(after['allocator_balance'] - before['allocator_balance'] == total, 'allocator delta mismatch')
    require(after['total_reserved'] + after['protected_capital'] <= after['reserve_balance'], 'protected capital invariant')
    require(after['outstanding_liability'] == 0, 'pre-activation liability must be zero')
    require(after['prepared_state'] == 3, 'prepared operation not ratified')
    state = after['operation_words']
    require(int(state[0], 16) == 2, 'allocator not Funded')
    require(state[1:4] == words[3:6], 'funded binding/descriptor/table mismatch')
    require(int(state[4], 16) == count and int(state[5], 16) == total and int(state[9], 16) == total, 'funded count/total mismatch')
    require(state[6] == words[8], 'funded claim root mismatch')
    evidence = {
        'schema': 'prf-evm.gate-e-entitlement-forensic.v1',
        'classification': 'forensic-observation; not a canonical economic artifact',
        'chain_id': chain, 'operation_id': manifest['operationId'],
        'artifacts': artifacts,
        'proof_identity': {k: fixture[k] for k in ('program_id', 'vkey', 'elf_sha256', 'proof_system', 'public_values_schema')},
        'proof_bytes_sha256': sha(bytes.fromhex(fixture['proof'][2:])),
        'public_values_sha256': sha(values), 'public_words': words,
        'source': fixture['source'], 'gate_e': fixture['gate_e'],
        'contracts': contracts, 'transactions': receipts,
        'before_funding': before, 'after_funding': after,
        'limitations': ['RPC observations are unsigned; receipts/logs are not a state proof.',
                        'Snapshots bracket the funding block, not an individual transaction within that block.',
                        'SDK proof verification is reported by the producer; on-chain admission receipt is retained.',
                        'Activation, withdrawal and closure are not claimed by this funding record.'],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as output:
        json.dump(evidence, output, indent=2, sort_keys=True)
        output.write('\n')
    print(f'evidence: {args.output}')
    print(f'evidence_sha256: {sha(args.output.read_bytes())}')
    print(f'funding_block: {block}; exact funding: {total}; entitlements: {count}')


if __name__ == '__main__':
    main()
