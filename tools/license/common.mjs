// Shared by issue.mjs and verify.mjs. Format and rules: DESIGN.md, "License".
import { createPublicKey } from 'node:crypto';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const PUBLIC_KEY_SPKI_B64 =
  'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfz4a/OgAm9wr//FwRGIEJr+t4l2Mbj7E7b0jaVLwb0x+f+YUg6XZCBmzW6x2zF9sy4yVqBKSj8v0dt9lC9xLhQ==';

export const DEFAULT_PRIVATE_KEY_PATH = join(homedir(), '.long-ping', 'license-signing-key.pem');

export const publicKey = () =>
  createPublicKey({ key: Buffer.from(PUBLIC_KEY_SPKI_B64, 'base64'), format: 'der', type: 'spki' });

export const b64url = (buf) => Buffer.from(buf).toString('base64url');
export const fromB64url = (str) => Buffer.from(str, 'base64url');

// Minimal --flag value parser; repeated flags are not supported (pass comma lists).
export const parseArgs = (argv) => {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const name = arg.slice(2);
    const next = argv[i + 1];
    out[name] = next === undefined || next.startsWith('--') ? true : (i++, next);
  }
  return out;
};

export const appMatches = (patterns, appId) =>
  patterns.some((p) => (p.endsWith('.*') ? appId.startsWith(p.slice(0, -1)) : p === appId));
