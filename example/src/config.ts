// Everything environment-specific lives here. For a phone build, point HOST at a machine the phone can reach
// (your laptop's LAN address running tools/e2e/receiver.mjs, or a real server) and rebuild.
import { Platform } from 'react-native';
import type { Authorization, Config } from 'react-native-long-ping';

/** Upload + report server. Simulator: the Mac itself. Emulator: the host loopback alias 10.0.2.2. */
export const HOST: string = Platform.select({
  android: 'http://10.0.2.2:8787',
  default: 'http://127.0.0.1:8787',
});

/** Applied with configure() on every launch (tools/e2e/E2E.md, "E2E config"). */
export const CONFIG: Config = {
  movingIntervalSec: 10,
  parkedIntervalSec: 30,
  stopTimeoutSec: 60,
  stopRadiusM: 50,
  movingSpeedMps: 3,
  minAccuracyM: 100,
  http: {
    url: `${HOST}/locations`,
    batch: true,
    uploadIntervalSec: 20,
    maxBatchSize: 100,
  },
  logLevel: 'debug',
};

/** Stored with setAuthorization() on every launch. */
export const AUTH: Authorization = {
  accessToken: 'test-token-1',
  refreshToken: 'ref-1',
  refreshUrl: `${HOST}/refresh`,
};

/** Every plugin event and command result is POSTed here as one JSON line. null = on-screen only. */
export const REPORT_URL: string | null = `${HOST}/log`;

/** Deep-link command channel: longping-example://cmd/<name>?<args> */
export const URL_SCHEME = 'longping-example';
