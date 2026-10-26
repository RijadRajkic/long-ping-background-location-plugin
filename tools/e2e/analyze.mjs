#!/usr/bin/env node
// Reads a receiver run directory (requests.jsonl + applog.txt) and answers the E2E.md questions: gaps per event
// type, duplicates, batch sizes and ordering, motion changes, request/status timelines, app log entries.
// Platform-neutral: works the same for the iOS and Android rounds.
//
//   node tools/e2e/analyze.mjs <runDir> summary
//   node tools/e2e/analyze.mjs <runDir> gaps     [--from ISO] [--to ISO] [--event interval] [--in 8,13] [--max 25]
//   node tools/e2e/analyze.mjs <runDir> timeline [--from ISO] [--to ISO] [--event interval]
//   node tools/e2e/analyze.mjs <runDir> requests [--from ISO] [--to ISO]        (receiver time)
//   node tools/e2e/analyze.mjs <runDir> applog   [--from ISO] [--to ISO] [--name http] [--kind event]
//   node tools/e2e/analyze.mjs <runDir> route    [--from ISO] [--to ISO] --a lat,lon --b lat,lon
//   node tools/e2e/analyze.mjs <runDir> hole     --from ISO --to ISO           (largest timestamp hole, any event)
//
// --from/--to filter on RECORD timestamps (fix time) for record views, on receiver time for requests/applog.
// Add --json for machine-readable output.
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [, , runDir, view = 'summary', ...rest] = process.argv;
if (!runDir) {
  console.error('usage: analyze.mjs <runDir> <view> [options]');
  process.exit(2);
}
const opts = {};
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) {
    const key = rest[i].slice(2);
    const next = rest[i + 1];
    if (next === undefined || next.startsWith('--')) opts[key] = true;
    else opts[key] = rest[++i];
  }
}
const ms = (iso) => (iso === undefined ? undefined : Date.parse(iso));
const from = ms(opts.from) ?? -Infinity;
const to = ms(opts.to) ?? Infinity;

export const readJsonl = (file) =>
  existsSync(file)
    ? readFileSync(file, 'utf8')
        .split('\n')
        .filter(Boolean)
        .map((line) => {
          try {
            return JSON.parse(line);
          } catch {
            return null;
          }
        })
        .filter(Boolean)
    : [];

const requests = readJsonl(join(runDir, 'requests.jsonl'));
const uploads = requests.filter((r) => (r.path ?? '').startsWith('/locations'));
const recordsOf = (body) => (body && Array.isArray(body.locations) ? body.locations : body?.location ? [body.location] : []);

/** Every record the receiver accepted (2xx), first delivery per uuid, sorted by fix time. */
const accepted = [];
const seen = new Map();
let duplicates = 0;
const orderViolations = [];
for (const [index, req] of uploads.entries()) {
  if (!(req.status >= 200 && req.status < 300)) continue;
  const recs = recordsOf(req.body);
  for (let i = 1; i < recs.length; i++) {
    if (ms(recs[i].timestamp) < ms(recs[i - 1].timestamp)) orderViolations.push({ request: index, at: req.at, i });
  }
  for (const r of recs) {
    const n = (seen.get(r.uuid) ?? 0) + 1;
    seen.set(r.uuid, n);
    if (n > 1) {
      duplicates++;
      continue;
    }
    accepted.push({ ...r, t: ms(r.timestamp), receivedAt: req.at, token: req.token });
  }
}
accepted.sort((a, b) => a.t - b.t);

const inWindow = (r) => r.t >= from && r.t <= to;
const pct = (n, d) => (d ? Math.round((1000 * n) / d) / 10 : 0);
const quantile = (sorted, q) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : null);
const round1 = (x) => Math.round(x * 10) / 10;
const iso = (t) => new Date(t).toISOString();

const R = 6371008.8;
const rad = (d) => (d * Math.PI) / 180;
export const haversine = (a, b) => {
  const dLat = rad(b[0] - a[0]);
  const dLon = rad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
};

function gapStats(records, inRange, maxGap) {
  const gaps = [];
  for (let i = 1; i < records.length; i++) gaps.push({ s: (records[i].t - records[i - 1].t) / 1000, at: records[i].timestamp });
  const values = gaps.map((g) => g.s).sort((a, b) => a - b);
  const [lo, hi] = inRange ?? [-Infinity, Infinity];
  const within = gaps.filter((g) => g.s >= lo && g.s <= hi).length;
  return {
    records: records.length,
    gaps: gaps.length,
    min: values.length ? round1(values[0]) : null,
    p50: values.length ? round1(quantile(values, 0.5)) : null,
    p90: values.length ? round1(quantile(values, 0.9)) : null,
    max: values.length ? round1(values[values.length - 1]) : null,
    mean: values.length ? round1(values.reduce((a, b) => a + b, 0) / values.length) : null,
    inRange: inRange ? `${lo}-${hi}` : null,
    withinRange: within,
    withinPct: pct(within, gaps.length),
    overMax: maxGap === undefined ? null : gaps.filter((g) => g.s > maxGap).map((g) => `${round1(g.s)}s@${g.at}`),
  };
}

const out = (value, text) => {
  if (opts.json) console.log(JSON.stringify(value, null, 2));
  else console.log(text ?? JSON.stringify(value, null, 2));
};

const statusCounts = (list) =>
  list.reduce((acc, r) => {
    acc[r.status] = (acc[r.status] ?? 0) + 1;
    return acc;
  }, {});

switch (view) {
  case 'summary': {
    const okUploads = uploads.filter((r) => r.status >= 200 && r.status < 300);
    const sizes = okUploads.map((r) => recordsOf(r.body).length);
    const byEvent = accepted.reduce((acc, r) => ((acc[r.event] = (acc[r.event] ?? 0) + 1), acc), {});
    out({
      uploadRequests: uploads.length,
      statuses: statusCounts(uploads),
      acceptedRecords: accepted.length,
      byEvent,
      duplicates,
      orderViolations: orderViolations.length,
      batchSizes: { min: Math.min(...sizes), max: Math.max(...sizes), mean: round1(sizes.reduce((a, b) => a + b, 0) / (sizes.length || 1)), multi: sizes.filter((n) => n > 1).length, requests: sizes.length },
      first: accepted[0]?.timestamp,
      last: accepted.at(-1)?.timestamp,
      refreshRequests: requests.filter((r) => r.path === '/refresh').length,
      tokens: [...new Set(uploads.map((r) => r.token))],
    });
    break;
  }
  case 'gaps': {
    const event = opts.event ?? 'interval';
    const recs = accepted.filter((r) => inWindow(r) && (event === 'any' || r.event === event));
    const range = typeof opts.in === 'string' ? opts.in.split(',').map(Number) : undefined;
    const maxGap = opts.max === undefined ? undefined : Number(opts.max);
    out(gapStats(recs, range, maxGap));
    break;
  }
  case 'hole': {
    const recs = accepted.filter(inWindow);
    let worst = { s: 0 };
    for (let i = 1; i < recs.length; i++) {
      const s = (recs[i].t - recs[i - 1].t) / 1000;
      if (s > worst.s) worst = { s: round1(s), after: recs[i - 1].timestamp, before: recs[i].timestamp };
    }
    out({ records: recs.length, largestHole: worst });
    break;
  }
  case 'timeline': {
    const recs = accepted.filter((r) => inWindow(r) && (!opts.event || r.event === opts.event));
    const rows = recs.map((r, i) => ({
      ts: r.timestamp,
      gap: i ? round1((r.t - recs[i - 1].t) / 1000) : null,
      event: r.event,
      moving: r.is_moving,
      lat: r.coords?.latitude,
      lon: r.coords?.longitude,
      acc: r.coords?.accuracy,
      spd: r.coords?.speed,
      rx: r.receivedAt,
    }));
    out(
      rows,
      rows
        .map((x) => `${x.ts}  +${String(x.gap ?? '-').padStart(5)}s  ${x.event.padEnd(12)} ${x.moving ? 'M' : 'P'}  ${x.lat?.toFixed(5)},${x.lon?.toFixed(5)} ±${Math.round(x.acc)} v${round1(x.spd)}  rx ${x.rx.slice(11, 19)}`)
        .join('\n'),
    );
    break;
  }
  case 'requests': {
    const rows = requests
      .filter((r) => ms(r.at) >= from && ms(r.at) <= to)
      .map((r) => {
        const recs = recordsOf(r.body);
        return {
          at: r.at,
          path: r.path,
          status: r.status,
          mode: r.mode,
          token: r.token,
          count: recs.length,
          first: recs[0]?.timestamp,
          last: recs.at(-1)?.timestamp,
        };
      });
    out(rows, rows.map((x) => `${x.at}  ${x.path.padEnd(10)} ${String(x.status).padEnd(4)} ${String(x.mode ?? '').padEnd(4)} tok=${x.token ?? '-'} n=${x.count} ${x.first ?? ''}..${x.last ?? ''}`).join('\n'));
    break;
  }
  case 'applog': {
    const entries = readJsonl(join(runDir, 'applog.txt')).filter(
      (e) =>
        ms(e.at) >= from &&
        ms(e.at) <= to &&
        (!opts.name || e.name === opts.name) &&
        (!opts.kind || e.kind === opts.kind),
    );
    const brief = (e) => {
      const p = e.payload;
      if (e.name === 'location') return `${p?.event} ${p?.timestamp} moving=${p?.is_moving}`;
      if (e.name === 'uploadLog') return `${p?.lines} lines`;
      if (p && typeof p === 'object' && 'config' in p) return `enabled=${p.enabled} moving=${p.isMoving} queue=${p.queueCount} license=${p.license} authReq=${p.authorizationRequired}`;
      const text = JSON.stringify(p);
      return text && text.length > 220 ? text.slice(0, 220) + '…' : text;
    };
    out(entries, entries.map((e) => `${e.at}  ${e.kind.padEnd(5)} ${e.name.padEnd(16)} ${e.ok ? 'ok ' : 'ERR'} ${brief(e)}`).join('\n'));
    break;
  }
  case 'route': {
    // Cross-track distance of every record from the straight segment a→b, and along-track progress.
    const a = String(opts.a).split(',').map(Number);
    const b = String(opts.b).split(',').map(Number);
    const recs = accepted.filter(inWindow);
    const ab = haversine(a, b);
    const bearing = (p, q) => {
      const y = Math.sin(rad(q[1] - p[1])) * Math.cos(rad(q[0]));
      const x = Math.cos(rad(p[0])) * Math.sin(rad(q[0])) - Math.sin(rad(p[0])) * Math.cos(rad(q[0])) * Math.cos(rad(q[1] - p[1]));
      return Math.atan2(y, x);
    };
    let maxCross = 0;
    let backwards = 0;
    let prevAlong = -Infinity;
    const speeds = [];
    let prev = null;
    for (const r of recs) {
      const p = [r.coords.latitude, r.coords.longitude];
      const d13 = haversine(a, p) / R;
      const cross = Math.abs(Math.asin(Math.sin(d13) * Math.sin(bearing(a, p) - bearing(a, b))) * R);
      const along = Math.acos(Math.min(1, Math.cos(d13) / Math.cos(cross / R))) * R;
      maxCross = Math.max(maxCross, cross);
      if (along < prevAlong - 5) backwards++;
      if (prev && r.t > prev.t) speeds.push(haversine([prev.coords.latitude, prev.coords.longitude], p) / ((r.t - prev.t) / 1000));
      prevAlong = along;
      prev = r;
    }
    speeds.sort((x, y) => x - y);
    out({
      records: recs.length,
      segmentM: Math.round(ab),
      maxCrossTrackM: round1(maxCross),
      backwardSteps: backwards,
      impliedSpeedMps: { p10: round1(quantile(speeds, 0.1) ?? 0), p50: round1(quantile(speeds, 0.5) ?? 0), p90: round1(quantile(speeds, 0.9) ?? 0) },
      lastAlongM: recs.length ? Math.round(prevAlong) : null,
    });
    break;
  }
  default:
    console.error(`unknown view ${view}`);
    process.exit(2);
}
