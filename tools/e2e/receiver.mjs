#!/usr/bin/env node
// Test receiver for end-to-end runs: stands in for a customer's upload endpoint, records every request
// and lets the test script change how it answers. It is a test fixture, not a dev server: it exits on
// its own after --ttl seconds (default 3600) or on POST /control {"shutdown": true}.
//
//   node tools/e2e/receiver.mjs --port 8787 --out /path/to/run-dir [--ttl 3600]
//
// Endpoints
//   POST|PUT /locations   upload target. Answers per the current mode (see /control).
//   POST /refresh         token refresh: {"refresh_token": "..."} → {"access_token": "tok-N", "refresh_token": "ref-N"}
//                         (401 while refreshMode is "401")
//   POST /log             app log dump (text or JSON), appended to applog.txt
//   GET  /stats           counts, duplicates, per-request batch sizes, last record
//   POST /control         {"mode": "ok"|"500"|"401"|"413"|"drop", "times": N, "enforceToken": bool,
//                          "longPing": {...} (sent once in the next 2xx), "refreshMode": "ok"|"401",
//                          "validTokens": [...], "shutdown": true}
//
// Every request is appended to requests.jsonl as {at, method, path, headers, status, body}.
import { createServer } from 'node:http';
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
const port = Number(args.port ?? 8787);
const out = args.out ?? join(process.cwd(), 'e2e-run');
const ttlSec = Number(args.ttl ?? 3600);
mkdirSync(out, { recursive: true });

const state = {
  mode: 'ok',
  modeTimes: Infinity,
  enforceToken: false,
  refreshMode: 'ok',
  validTokens: new Set(['test-token-1']),
  tokenSerial: 1,
  pendingLongPing: null,
  seen: new Map(), // uuid -> count
  requests: 0,
  records: 0,
  batchSizes: [],
  lastRecord: null,
};

const log = (entry) => appendFileSync(join(out, 'requests.jsonl'), JSON.stringify({ at: new Date().toISOString(), ...entry }) + '\n');

const readBody = (req) =>
  new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
  });

const send = (res, status, body) => {
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(text);
  return status;
};

const recordsIn = (json) => {
  if (!json || typeof json !== 'object') return [];
  if (Array.isArray(json.locations)) return json.locations;
  if (json.location && typeof json.location === 'object') return [json.location];
  if (json.uuid || json.lat !== undefined) return [json];
  return [];
};

const takeMode = () => {
  const mode = state.mode;
  if (mode !== 'ok' && --state.modeTimes <= 0) {
    state.mode = 'ok';
    state.modeTimes = Infinity;
  }
  return mode;
};

const handleUpload = async (req, res) => {
  const raw = await readBody(req);
  let json = null;
  try {
    json = JSON.parse(raw);
  } catch {
    /* logged as raw below */
  }
  state.requests += 1;
  const auth = String(req.headers.authorization ?? '');
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;

  let status;
  const mode = takeMode();
  if (mode === 'drop') {
    req.socket.destroy();
    status = 0;
  } else if (mode === '500') {
    status = send(res, 500, { error: 'scripted 500' });
  } else if (mode === '413') {
    status = send(res, 413, { error: 'scripted 413' });
  } else if (mode === '401' || (state.enforceToken && !state.validTokens.has(token))) {
    status = send(res, 401, { error: 'unauthorized' });
  } else {
    const records = recordsIn(json);
    for (const r of records) {
      const id = r.uuid ?? `${r.lat},${r.lng},${r.timestamp}`;
      state.seen.set(id, (state.seen.get(id) ?? 0) + 1);
    }
    state.records += records.length;
    state.batchSizes.push(records.length);
    if (records.length) state.lastRecord = records[records.length - 1];
    const reply = { ok: true, received: records.length };
    if (state.pendingLongPing) {
      reply.long_ping = state.pendingLongPing;
      state.pendingLongPing = null;
    }
    status = send(res, 200, reply);
  }
  log({ method: req.method, path: req.url, token, status, mode, body: json ?? raw });
};

const handleRefresh = async (req, res) => {
  const raw = await readBody(req);
  if (state.refreshMode === '401') {
    const status = send(res, 401, { error: 'refresh rejected' });
    log({ method: req.method, path: req.url, status, body: raw });
    return;
  }
  state.tokenSerial += 1;
  const access = `tok-${state.tokenSerial}`;
  state.validTokens = new Set([access]);
  const status = send(res, 200, { access_token: access, refresh_token: `ref-${state.tokenSerial}` });
  log({ method: req.method, path: req.url, status, body: raw });
};

const stats = () => {
  const dupes = [...state.seen.values()].filter((n) => n > 1).length;
  return {
    requests: state.requests,
    records: state.records,
    uniqueRecords: state.seen.size,
    duplicateRecords: dupes,
    batchSizes: state.batchSizes.slice(-50),
    mode: state.mode,
    enforceToken: state.enforceToken,
    refreshMode: state.refreshMode,
    validTokens: [...state.validTokens],
    lastRecord: state.lastRecord,
  };
};

const server = createServer(async (req, res) => {
  try {
    const path = (req.url ?? '').split('?')[0];
    if (path === '/locations' && (req.method === 'POST' || req.method === 'PUT')) return await handleUpload(req, res);
    if (path === '/refresh' && req.method === 'POST') return await handleRefresh(req, res);
    if (path === '/log' && req.method === 'POST') {
      appendFileSync(join(out, 'applog.txt'), (await readBody(req)) + '\n');
      return send(res, 200, { ok: true });
    }
    if (path === '/stats' && req.method === 'GET') return send(res, 200, stats());
    if (path === '/control' && req.method === 'POST') {
      const body = JSON.parse((await readBody(req)) || '{}');
      if (body.mode) {
        state.mode = body.mode;
        state.modeTimes = body.times ?? Infinity;
      }
      if (body.enforceToken !== undefined) state.enforceToken = !!body.enforceToken;
      if (body.refreshMode) state.refreshMode = body.refreshMode;
      if (body.validTokens) state.validTokens = new Set(body.validTokens);
      if (body.longPing) state.pendingLongPing = body.longPing;
      send(res, 200, stats());
      if (body.shutdown) shutdown('control');
      return;
    }
    send(res, 404, { error: 'not found' });
  } catch (err) {
    send(res, 500, { error: String(err) });
  }
});

const shutdown = (why) => {
  writeFileSync(join(out, 'stats.json'), JSON.stringify(stats(), null, 2));
  console.log(`receiver: exiting (${why})`);
  server.close();
  process.exit(0);
};
setTimeout(() => shutdown('ttl'), ttlSec * 1000).unref();
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

server.listen(port, '127.0.0.1', () => {
  writeFileSync(join(out, 'receiver.pid'), String(process.pid));
  console.log(`receiver: listening on 127.0.0.1:${port}, writing to ${out}, exits in ${ttlSec}s`);
});
