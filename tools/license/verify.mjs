#!/usr/bin/env node
// Check a license key the same way the engines do.
//
//   node tools/license/verify.mjs --key-string LP1.xxx.yyy [--app com.acme.driver] [--release 2026-10-26]
import { verify } from 'node:crypto';
import { appMatches, fromB64url, parseArgs, publicKey } from './common.mjs';

const args = parseArgs(process.argv.slice(2));
const key = String(args['key-string'] ?? '');
const parts = key.split('.');
if (parts.length !== 3 || parts[0] !== 'LP1') {
  console.error('verify: not an LP1 key');
  process.exit(1);
}

const ok = verify(
  'sha256',
  Buffer.from(`${parts[0]}.${parts[1]}`, 'ascii'),
  { key: publicKey(), dsaEncoding: 'der' },
  fromB64url(parts[2]),
);
const payload = JSON.parse(fromB64url(parts[1]).toString('utf8'));
console.log(JSON.stringify(payload, null, 2));
console.log(`signature: ${ok ? 'valid' : 'INVALID'}`);

let valid = ok && payload.v === 1;
if (args.app && args.app !== true) {
  const match = appMatches(payload.apps ?? [], String(args.app));
  console.log(`app ${args.app}: ${match ? 'covered' : 'NOT covered'}`);
  valid &&= match;
}
if (args.release && args.release !== true && payload.upd) {
  const covered = String(args.release) <= payload.upd;
  console.log(`release ${args.release}: ${covered ? 'covered' : 'NOT covered'} (updates until ${payload.upd})`);
  valid &&= covered;
}
process.exit(valid ? 0 : 1);
