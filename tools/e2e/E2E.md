# End-to-end test plan (simulator / emulator)

Runs the real plugin inside a real React Native app (`example/`), built the way a customer builds it, with
simulated GPS and `tools/e2e/receiver.mjs` as the upload server. Native behaviour is judged from what reaches the
receiver; JS-side results come back through the app's command channel.

## Rig

- **Example app** `example/`: RN 0.81.5, New Architecture, bundle id / applicationId `com.longping.example`,
  depends on the plugin via `file:..`. Release-type build with the JS bundle embedded (no Metro, ever).
- **On launch** the app calls `configure()` with the e2e config below, `setAuthorization()` with
  `{accessToken: 'test-token-1', refreshToken: 'ref-1', refreshUrl: <host>/refresh}`, and subscribes to every event.
  It never calls `start()` by itself.
- **Command channel**: deep links `longping-example://cmd/<name>?<args>` (iOS `xcrun simctl openurl`, Android
  `adb shell am start -a android.intent.action.VIEW -d <url>`). Commands: `start`, `stop`, `changePace?moving=1|0`,
  `sync`, `getCurrentPosition?persist=1|0`, `setConfig?json=<urlencoded>`, `setAuthorization?token=<t>`,
  `state`, `queue`, `uploadLog`. Every command result and every plugin event is POSTed to `<host>/log` as one JSON
  line `{at, kind: 'cmd'|'event', name, ok, payload}`.
- **The app's screen** shows state, last fix, queue count and buttons for the same commands, so the app doubles
  as the product's example app for phone testing.
- **Host**: iOS simulator `http://127.0.0.1:8787`, Android emulator `http://10.0.2.2:8787` (cleartext allowed for
  that host only, debug network-security config / ATS `NSAllowsLocalNetworking`).
- **E2E config**:
  `movingIntervalSec 10, parkedIntervalSec 30, stopTimeoutSec 60, stopRadiusM 50, movingSpeedMps 3,
  minAccuracyM 100, http {url <host>/locations, batch true, uploadIntervalSec 20, maxBatchSize 100},
  logLevel 'debug', licenseKey <example key>`.
- **GPS**: iOS `xcrun simctl location <udid> start --speed=<m/s> --interval=1 <lat,lon> ...` / `set` / `clear`.
  Android emulator console `geo fix` / `geo nmea` (RMC with speed) driven at 1 Hz by a script.
  Route: a straight-ish road segment, ~15 m/s, plus a parking point.
- **Resource rules** (16 GB machine): one platform at a time; simulator/emulator shut down at the end; receiver
  always started with a `--ttl`; Gradle only `--no-daemon`; never Metro. Verify no leftover processes at the end.

## Scenarios and pass criteria

Gaps = differences between consecutive record timestamps of the same event type, as received.

| # | Scenario | Pass when |
|---|---|---|
| S1 | Install, grant location (always), launch, `cmd/start` | `start` ok; a `motionchange` record (`is_moving: true`) reaches the receiver within 30 s |
| S2 | Drive 5 min at ~15 m/s | `interval` records every 10 s: >= 90 % of gaps in 8-13 s, none > 25 s; coordinates follow the route |
| S3 | Park (fixed position) > 60 s | one `motionchange` `is_moving: false` 60-100 s after stopping; then `interval` records with gaps in 25-40 s |
| S4 | Drive again | `motionchange` `is_moving: true` within 40 s of moving off; gaps back to ~10 s |
| S5 | Uploads | requests carry several records (batch); every `uuid` unique (duplicates 0); records arrive in timestamp order within a request |
| S6 | Receiver `drop` mode 2 min (network failure) | after it clears, every record from the outage arrives; no timestamp hole > 25 s across the outage while moving |
| S7 | Receiver `500` × 3 | records retried and delivered after the errors; nothing lost; backoff visible in the app log |
| S8 | `enforceToken` with tokens rotated server-side | upload gets 401 → app POSTs `/refresh` → following uploads carry `Bearer tok-N`; tracking never stopped (no record gap); then with refresh also failing (`401` mode on `/locations` and refresh rejected): `authorization` event, uploads paused, fixes still recorded; `cmd/setAuthorization` with a valid token → backlog delivered |
| S9 | Remote config: `long_ping.config {movingIntervalSec: 5}` | `configchange` event; `interval` gaps drop to ~5 s (>= 80 % in 4-7 s) |
| S10 | `cmd/changePace?moving=0`, then `getCurrentPosition?persist=1`, `sync`, `queue`, `state` | each command ok; `motionchange` false recorded; a `current` record arrives; queue count 0 after sync |
| S11 | Background: send the app to background (iOS launch another app; Android HOME) for 5 min while driving | `interval` records continue at ~10 s throughout |
| S12 | Process death | iOS: `simctl terminate`, keep driving, relaunch app — records resume within 30 s of relaunch without `cmd/start`. Android: kill the process (`adb root` + `kill`, or `am kill` when backgrounded) — the service comes back on its own (START_STICKY / watchdog) and records resume; note how long it took |
| S13 | Android only: `adb reboot` | after boot, without opening the app, records resume (boot receiver) |
| S14 | Android only: Doze (`dumpsys deviceidle force-idle`, screen off) 10 min | fixes keep being recorded; uploads may batch up in maintenance windows but all arrive |
| S15 | Remote stop: `long_ping.stop: true` | `enabledchange` false; no further `interval` records; queued records still delivered |
| S16 | `cmd/uploadLog` | log has lines for start, motion changes, uploads, errors/backoff from the scenarios above |
| S17 | Stability: 10 min at `movingIntervalSec: 1` | gaps ~1 s; app memory not climbing steadily (sample 3×); no crash; queue bounded |

Each run writes to `e2e-runs/<platform>-<timestamp>/` (gitignored): receiver output, app log, a `results.md`
with PASS/FAIL per scenario and the numbers behind it.
