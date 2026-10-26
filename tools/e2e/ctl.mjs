#!/usr/bin/env node
// Drives an e2e run: receiver control, app commands over the deep-link channel, simulated GPS.
// Platform via --platform ios|android (default ios). Everything is one-shot except `feed` (Android only).
//
//   node tools/e2e/ctl.mjs control '{"mode":"500","times":3}'      POST /control on the receiver
//   node tools/e2e/ctl.mjs stats                                   GET /stats
//   node tools/e2e/ctl.mjs cmd start                               longping-example://cmd/start
//   node tools/e2e/ctl.mjs cmd changePace moving=0
//   node tools/e2e/ctl.mjs cmd setConfig json='{"movingIntervalSec":1}'
//   node tools/e2e/ctl.mjs drive [--speed 15] [--from <m>]        drive along ROUTE from where the car is
//   node tools/e2e/ctl.mjs park                                    park where the car is (1 Hz jittered fixes)
//   node tools/e2e/ctl.mjs set [lat,lon]                           one fixed position
//   node tools/e2e/ctl.mjs gps-clear                               no more fixes
//   node tools/e2e/ctl.mjs feed [--ttl 3600] [--port 5554]        Android: the 1 Hz GPS feeder (see below)
//   node tools/e2e/ctl.mjs feed-stop                               Android: stop the feeder (pid in <out>/feed.pid)
//   node tools/e2e/ctl.mjs approve-scheme                          iOS: skip the "Open in…?" prompt for deep links
//   node tools/e2e/ctl.mjs mark <label>                            append a timestamped marker to <out>/marks.jsonl
//
// Options: --host http://127.0.0.1:8787  --udid <simulator udid> (default: booted)  --serial <adb serial>
//          --out <runDir> (needed by drive/park/set/gps-clear/feed: the car state lives in <out>/drive.json)
//
// iOS: drive/park/set/gps-clear call `simctl location`, which plays the route inside the simulator.
// Android: the emulator has no route playback. drive/park/set/gps-clear only write the car state, and `feed` (the
// one long-running piece, always bounded by --ttl) reads it every second and sends `geo fix` with the speed over
// the emulator console. Same road, same speeds, same parking square on both platforms (route.mjs).
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { ROUTE, PARK, pointAlong, parkLoop, parkLoopAt, knots } from './route.mjs';

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
const PARK_SPEED = 0.5;

const sh = (cmd, cmdArgs) => execFileSync(cmd, cmdArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const adb = (...adbArgs) => sh('adb', [...(opts.serial ? ['-s', opts.serial] : []), ...adbArgs]);

const openUrl = (url) => {
  if (platform === 'ios') return sh('xcrun', ['simctl', 'openurl', udid, url]);
  // adb joins the arguments into one device-shell command line: single-quote the URL (and keep quotes out of it).
  return adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', `'${url.replace(/'/g, '%27')}'`);
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

/** Where the simulated car is: {drivingSince, fromM, speed} | {parkedAtM, parkedSince} | {fixed} | {off}. Needs --out. */
const carFile = () => join(opts.out ?? '.', 'drive.json');
const readCar = () => {
  try {
    return existsSync(carFile()) ? JSON.parse(readFileSync(carFile(), 'utf8')) : {};
  } catch {
    return {}; // read while being rewritten: the feeder tries again next second
  }
};
const writeCar = (car) => writeFileSync(carFile(), JSON.stringify(car));
const carMeters = (car, now = Date.now()) =>
  car.drivingSince ? car.fromM + (car.speed * (now - car.drivingSince)) / 1000 : (car.parkedAtM ?? 0);

/** The fix the car reports now (Android feeder): {lat, lon, speed} or null for no fix. */
const carFix = (car, now = Date.now()) => {
  if (car.off) return null;
  if (car.fixed) return { lat: car.fixed[0], lon: car.fixed[1], speed: 0 };
  if (car.drivingSince) {
    const [lat, lon] = pointAlong(carMeters(car, now));
    return { lat, lon, speed: car.speed };
  }
  const spot = pointAlong(car.parkedAtM ?? 0);
  const [lat, lon] = parkLoopAt(spot, ((now - (car.parkedSince ?? now)) / 1000), PARK_SPEED);
  return { lat, lon, speed: PARK_SPEED };
};

const mark = (label, extra = {}) => {
  const entry = { at: new Date().toISOString(), label, ...extra };
  if (opts.out) appendFileSync(join(opts.out, 'marks.jsonl'), JSON.stringify(entry) + '\n');
  return entry;
};

/** Android: 1 Hz `geo fix` over the emulator console until --ttl, SIGTERM or feed-stop. Reconnects across reboots. */
async function feed() {
  if (!opts.out) throw new Error('feed needs --out (the car state is <out>/drive.json)');
  const port = Number(opts.port ?? 5554);
  const ttlSec = Number(opts.ttl ?? 3600);
  const token = readFileSync(join(homedir(), '.emulator_console_auth_token'), 'utf8').trim();
  const pidFile = join(opts.out, 'feed.pid');
  const logFile = join(opts.out, 'feed.log');
  const flog = (line) => appendFileSync(logFile, `${new Date().toISOString()} ${line}\n`);
  writeFileSync(pidFile, String(process.pid));

  let socket = null;
  let connecting = false;
  let sent = 0;
  let lastLogged = 0;
  const open = () => {
    if (connecting) return;
    connecting = true;
    const s = connect(port, '127.0.0.1');
    s.setEncoding('utf8');
    s.on('connect', () => {
      s.write(`auth ${token}\r\n`);
      socket = s;
      connecting = false;
      flog(`console connected on ${port}`);
    });
    s.on('data', (d) => {
      if (/KO/.test(d)) flog(`console: ${d.trim()}`);
    });
    const drop = (why) => {
      if (socket === s) socket = null;
      connecting = false;
      flog(`console ${why}`);
    };
    s.on('error', (e) => drop(`error ${e.code ?? e.message}`));
    s.on('close', () => drop('closed'));
  };

  const stop = (why) => {
    flog(`feeder exiting (${why}), ${sent} fixes sent`);
    try {
      unlinkSync(pidFile);
    } catch {
      /* already gone */
    }
    socket?.end('quit\r\n');
    process.exit(0);
  };
  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('SIGINT', () => stop('SIGINT'));
  setTimeout(() => stop('ttl'), ttlSec * 1000).unref();

  open();
  flog(`feeder started (pid ${process.pid}, ttl ${ttlSec} s)`);
  setInterval(() => {
    if (!socket) return open();
    const fix = carFix(readCar());
    if (!fix) return;
    // geo fix <longitude> <latitude> [<altitude> [<satellites> [<velocity in knots>]]]
    socket.write(`geo fix ${fix.lon.toFixed(7)} ${fix.lat.toFixed(7)} 520 9 ${knots(fix.speed).toFixed(3)}\r\n`);
    sent++;
    if (Date.now() - lastLogged > 60_000) {
      lastLogged = Date.now();
      flog(`fix ${fix.lat.toFixed(6)},${fix.lon.toFixed(6)} ${fix.speed} m/s (${sent} sent)`);
    }
  }, 1000);
}

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
    // Resumes from where the car was parked (drive.json in --out) unless --from (meters along ROUTE) is given.
    const speed = Number(opts.speed ?? 15);
    const startAt = Number(opts.from ?? readCar().parkedAtM ?? 0);
    if (platform === 'ios') {
      const wps = [pointAlong(startAt), ROUTE.b].map(([lat, lon]) => `${lat.toFixed(6)},${lon.toFixed(6)}`);
      sh('xcrun', ['simctl', 'location', udid, 'start', `--speed=${speed}`, '--interval=1', ...wps]);
    }
    writeCar({ drivingSince: Date.now(), fromM: startAt, speed });
    console.log(JSON.stringify(mark('drive', { speed, fromM: startAt })));
    break;
  }
  case 'park': {
    // Park where the car is now. A parked phone keeps reporting ~1 fix/s with a few meters of jitter: walk a
    // tiny loop around the spot at 0.5 m/s (see route.mjs).
    const atM = carMeters(readCar());
    const spot = pointAlong(atM);
    if (platform === 'ios') {
      const wps = parkLoop(spot).map(([lat, lon]) => `${lat.toFixed(6)},${lon.toFixed(6)}`);
      sh('xcrun', ['simctl', 'location', udid, 'start', `--speed=${PARK_SPEED}`, '--interval=1', ...wps]);
    }
    writeCar({ parkedAtM: atM, parkedSince: Date.now() });
    console.log(JSON.stringify(mark('park', { atM: Math.round(atM), spot })));
    break;
  }
  case 'set': {
    const [lat, lon] = (args[0] ?? `${PARK[0]},${PARK[1]}`).split(',').map(Number);
    if (platform === 'ios') sh('xcrun', ['simctl', 'location', udid, 'set', `${lat},${lon}`]);
    else writeCar({ fixed: [lat, lon] });
    console.log(JSON.stringify(mark('set', { lat, lon })));
    break;
  }
  case 'gps-clear': {
    if (platform === 'ios') sh('xcrun', ['simctl', 'location', udid, 'clear']);
    else writeCar({ ...readCar(), off: true });
    console.log(JSON.stringify(mark('gps-clear')));
    break;
  }
  case 'feed': {
    if (platform !== 'android') throw new Error('feed: Android only (iOS plays routes inside the simulator)');
    await feed();
    break;
  }
  case 'feed-stop': {
    const pidFile = join(opts.out ?? '.', 'feed.pid');
    if (!existsSync(pidFile)) {
      console.log('feed-stop: no feeder running');
      break;
    }
    const pid = Number(readFileSync(pidFile, 'utf8'));
    try {
      process.kill(pid, 'SIGTERM');
      console.log(`feed-stop: sent SIGTERM to ${pid}`);
    } catch (e) {
      console.log(`feed-stop: ${pid} not running (${e.code})`);
    }
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
    console.error('actions: control | stats | cmd | drive | park | set | gps-clear | feed | feed-stop | approve-scheme | mark');
    process.exit(2);
}
