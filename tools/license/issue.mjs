#!/usr/bin/env node
// Issue a license key.
//
//   node tools/license/issue.mjs --sub acme-logistics --apps com.acme.driver,com.acme.driver.* \
//     --plan pro --upd 2027-10-26 [--key ~/.long-ping/license-signing-key.pem]
//
// --upd is the updates-until date: the key covers every plugin release up to that day and never
// stops working at runtime. Leave it out for a key with no update limit.
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { DEFAULT_PRIVATE_KEY_PATH, b64url, parseArgs } from './common.mjs';

const args = parseArgs(process.argv.slice(2));
const fail = (msg) => {
  console.error(`issue: ${msg}`);
  process.exit(1);
};

if (!args.sub || args.sub === true) fail('--sub <customer id> is required');
if (!args.apps || args.apps === true) fail('--apps <bundle id[,bundle id...]> is required');
if (args.upd !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(String(args.upd))) fail('--upd must be YYYY-MM-DD');

const payload = {
  v: 1,
  sub: String(args.sub),
  apps: String(args.apps)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),
  plan: args.plan && args.plan !== true ? String(args.plan) : 'pro',
  ...(args.upd ? { upd: String(args.upd) } : {}),
};

const keyPath = args.key && args.key !== true ? String(args.key) : DEFAULT_PRIVATE_KEY_PATH;
const privateKey = createPrivateKey(readFileSync(keyPath));

const signed = `LP1.${b64url(JSON.stringify(payload))}`;
const signature = sign('sha256', Buffer.from(signed, 'ascii'), { key: privateKey, dsaEncoding: 'der' });

console.log(`${signed}.${b64url(signature)}`);
