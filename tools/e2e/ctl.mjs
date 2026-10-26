#!/usr/bin/env node
// Drives an e2e run: receiver control, app commands over the deep-link channel, simulated GPS.
// One-shot commands only (no daemons). Platform via --platform ios|android (default ios).
//
//   node tools/e2e/ctl.mjs control '{"mode":"500","times":3}'      POST /control on the receiver
//   node tools/e2e/ctl.mjs stats                                   GET /stats
//   node tools/e2e/ctl.mjs cmd start                               longping-example://cmd/start
//   node tools/e2e/ctl.mjs cmd changePace moving=0
//   node tools/e2e/ctl.mjs cmd setConfig json='{"movingIntervalSec":1}'
//   node tools/e2e/ctl.mjs drive [--speed 15] [--from <m>]        iOS: simctl location start along ROUTE
//   node tools/e2e/ctl.mjs park                                    iOS: park where the car is (1 Hz jittered fixes)
//   node tools/e2e/ctl.mjs set [lat,lon]                           iOS: simctl location set
//   node tools/e2e/ctl.mjs gps-clear
//   node tools/e2e/ctl.mjs approve-scheme                          iOS: skip the "Open in…?" prompt for deep links
//   node tools/e2e/ctl.mjs mark <label>                            append a timestamped marker to <out>/marks.jsonl
//
// Options: --host http://127.0.0.1:8787  --udid <simulator udid> (default: booted)  --out <runDir>
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROUTE, PARK, pointAlong, parkLoop } from './route.mjs';

const argv = process.argv.slice(2);
const opts = {};
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) opts[argv[i].slice(2)] = argv[++i];
  else positional.push(argv[i]);
}
const [action, ...args] = positional;
const platform = opts.platform ?? 'ios';
const host = opts.host ?? 'http://127.0.0.1:8787';
const udid = opts.udid ?? 'booted';

const sh = (cmd, cmdArgs) => execFileSync(cmd, cmdArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

const openUrl = (url) => {
  if (platform === 'ios') return sh('xcrun', ['simctl', 'openurl', udid, url]);
  return sh('adb', ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', `'${url}'`]);
};

const commandUrl = (name, kv) => {
  const query = kv
    .map((pair) => {
      const eq = pair.indexOf('=');
      return eq < 0 ? encodeURIComponent(pair) : `${encodeURIComponent(pair.slice(0, eq))}=${encodeURIComponent(pair.slice(eq + 1))}`;
    })
    .join('&');
  return `longping-example://cmd/${name}${query ? `?${query}` : ''}`;
};

/** Where the simulated car is: {drivingSince, fromM, speed} or {parkedAtM}. Needs --out. */
const carFile = () => join(opts.out ?? '.', 'drive.json');
const readCar = () => (existsSync(carFile()) ? JSON.parse(readFileSync(carFile(), 'utf8')) : {});
const writeCar = (car) => writeFileSync(carFile(), JSON.stringify(car));

const mark = (label, extra = {}) => {
  const entry = { at: new Date().toISOString(), label, ...extra };
  if (opts.out) appendFileSync(join(opts.out, 'marks.jsonl'), JSON.stringify(entry) + '\n');
  return entry;
};

switch (action) {
  case 'control': {
    const res = await fetch(`${host}/control`, { method: 'POST', body: args[0] ?? '{}' });
    const body = await res.json();
    mark(`control ${args[0]}`);
    console.log(JSON.stringify({ mode: body.mode, enforceToken: body.enforceToken, validTokens: body.validTokens, records: body.records, requests: body.requests }));
    break;
  }
  case 'stats': {
    const res = await fetch(`${host}/stats`);
    console.log(JSON.stringify(await res.json(), null, 2));
    break;
  }
  case 'cmd': {
    const url = commandUrl(args[0], args.slice(1));
    openUrl(url);
    console.log(JSON.stringify(mark(`cmd ${args.join(' ')}`, { url })));
    break;
  }
  case 'drive': {
    if (platform !== 'ios') throw new Error('drive: Android uses its own NMEA script');
    // Resumes from where the car was parked (drive.json in --out) unless --from (meters along ROUTE) is given.
    const speed = Number(opts.speed ?? 15);
    const startAt = Number(opts.from ?? readCar().parkedAtM ?? 0);
    const wps = [pointAlong(startAt), ROUTE.b].map(([lat, lon]) => `${lat.toFixed(6)},${lon.toFixed(6)}`);
    sh('xcrun', ['simctl', 'location', udid, 'start', `--speed=${speed}`, '--interval=1', ...wps]);
    writeCar({ drivingSince: Date.now(), fromM: startAt, speed });
    console.log(JSON.stringify(mark('drive', { speed, fromM: startAt, waypoints: wps })));
    break;
  }
  case 'park': {
    if (platform !== 'ios') throw new Error('park: Android uses its own NMEA script');
    // Park where the car is now. A parked phone keeps reporting ~1 fix/s with a few meters of jitter: walk a
    // tiny loop around the spot at 0.5 m/s (see route.mjs).
    const car = readCar();
    const atM = car.drivingSince ? car.fromM + (car.speed * (Date.now() - car.drivingSince)) / 1000 : (car.parkedAtM ?? 0);
    const spot = pointAlong(atM);
    const wps = parkLoop(spot).map(([lat, lon]) => `${lat.toFixed(6)},${lon.toFixed(6)}`);
    sh('xcrun', ['simctl', 'location', udid, 'start', '--speed=0.5', '--interval=1', ...wps]);
    writeCar({ parkedAtM: atM });
    console.log(JSON.stringify(mark('park', { atM: Math.round(atM), spot })));
    break;
  }
  case 'set': {
    const [lat, lon] = (args[0] ?? `${PARK[0]},${PARK[1]}`).split(',').map(Number);
    sh('xcrun', ['simctl', 'location', udid, 'set', `${lat},${lon}`]);
    console.log(JSON.stringify(mark('set', { lat, lon })));
    break;
  }
  case 'gps-clear': {
    sh('xcrun', ['simctl', 'location', udid, 'clear']);
    console.log(JSON.stringify(mark('gps-clear')));
    break;
  }
  case 'approve-scheme': {
    // iOS asks "Open in 'Long Ping'?" for every simctl openurl. Pre-approving the scheme for the simulator
    // bridge (what Detox/Maestro do) makes deep links go straight through. Needs a booted simulator.
    if (platform !== 'ios') throw new Error('approve-scheme: iOS only');
    sh('xcrun', ['simctl', 'spawn', udid, 'defaults', 'write', 'com.apple.launchservices.schemeapproval',
      'com.apple.CoreSimulator.CoreSimulatorBridge-->longping-example', '-string', 'com.longping.example']);
    console.log(JSON.stringify(mark('approve-scheme')));
    break;
  }
  case 'mark': {
    console.log(JSON.stringify(mark(args.join(' '))));
    break;
  }
  default:
    console.error('actions: control | stats | cmd | drive | park | set | gps-clear | approve-scheme | mark');
    process.exit(2);
}
