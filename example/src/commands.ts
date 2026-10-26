// One command runner for the on-screen buttons and the deep-link channel
// (longping-example://cmd/<name>?<args>, see tools/e2e/E2E.md). Every result is reported.
import { Linking, PermissionsAndroid, Platform } from 'react-native';
import LongPing from 'react-native-long-ping';
import { AUTH, CONFIG, URL_SCHEME } from './config';
import { describeError, report } from './report';

export type Args = Record<string, string>;

const flag = (value: string | undefined) => value === '1' || value === 'true';
const num = (value: string | undefined) => (value === undefined || value === '' ? undefined : Number(value));

const handlers: Record<string, (args: Args) => Promise<unknown>> = {
  start: () => LongPing.start(),
  stop: () => LongPing.stop(),
  changePace: (a) => LongPing.changePace(flag(a.moving)),
  sync: () => LongPing.sync(),
  getCurrentPosition: (a) =>
    LongPing.getCurrentPosition({
      persist: flag(a.persist),
      timeoutSec: num(a.timeoutSec),
      maximumAgeSec: num(a.maximumAgeSec),
    }),
  configure: (a) => LongPing.configure(a.json ? JSON.parse(a.json) : CONFIG),
  setConfig: (a) => LongPing.setConfig(JSON.parse(a.json ?? '{}')),
  setAuthorization: (a) =>
    LongPing.setAuthorization(
      flag(a.noRefresh)
        ? { accessToken: a.token ?? '' }
        : { accessToken: a.token ?? '', refreshToken: a.refresh ?? AUTH.refreshToken, refreshUrl: AUTH.refreshUrl },
    ),
  clearAuthorization: () => LongPing.clearAuthorization(),
  state: () => LongPing.getState(),
  queue: () => LongPing.getQueueCount(),
  clearQueue: () => LongPing.clearQueue(),
  provider: () => LongPing.getProviderState(),
  requestPermission: async (a) => {
    const status = await LongPing.requestPermission(a.level === 'whenInUse' ? 'whenInUse' : 'always');
    // Android 13+: the tracking notification is only visible with POST_NOTIFICATIONS (the app's to ask).
    if (Platform.OS === 'android' && Platform.Version >= 33) {
      await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS);
    }
    return status;
  },
  uploadLog: async (a) => {
    const text = await LongPing.logger.getLog({ limit: num(a.limit) ?? 100000, sinceMs: num(a.sinceMs) });
    return { lines: text ? text.split('\n').length : 0, text };
  },
  clearLog: () => LongPing.logger.clear(),
  openSettings: () => LongPing.deviceSettings.openAppSettings(),
};

export const commandNames = Object.keys(handlers);

/** Runs a command and reports `{kind: 'cmd', name, ok, payload}`. Never throws. */
export async function runCommand(name: string, args: Args = {}): Promise<{ ok: boolean; payload: unknown }> {
  const handler = handlers[name];
  if (!handler) {
    const payload = { code: 'UNKNOWN_COMMAND', message: `unknown command '${name}'` };
    report('cmd', name, false, payload);
    return { ok: false, payload };
  }
  try {
    const result = await handler(args);
    report('cmd', name, true, result ?? null);
    return { ok: true, payload: result ?? null };
  } catch (error) {
    const payload = describeError(error);
    report('cmd', name, false, payload);
    return { ok: false, payload };
  }
}

/** `longping-example://cmd/<name>?a=1&b=2` → {name, args}; null for any other URL. */
export function parseCommandUrl(url: string): { name: string; args: Args } | null {
  const match = new RegExp(`^${URL_SCHEME}://cmd/([A-Za-z]+)/?(?:\\?(.*))?$`).exec(url);
  if (!match) return null;
  const args: Args = {};
  for (const part of (match[2] ?? '').split('&')) {
    if (!part) continue;
    const eq = part.indexOf('=');
    const key = decodeURIComponent(eq < 0 ? part : part.slice(0, eq));
    args[key] = eq < 0 ? '' : decodeURIComponent(part.slice(eq + 1).replace(/\+/g, ' '));
  }
  return { name: match[1], args };
}

/** Deep links run in arrival order, after `ready` (configure + setAuthorization) has settled. */
export function listenForCommandLinks(ready: Promise<unknown>): () => void {
  let chain: Promise<unknown> = ready.catch(() => undefined);
  const handle = (url: string | null) => {
    if (!url) return;
    const command = parseCommandUrl(url);
    if (!command) return;
    chain = chain.then(() => runCommand(command.name, command.args));
  };
  Linking.getInitialURL().then(handle, () => undefined);
  const subscription = Linking.addEventListener('url', ({ url }) => handle(url));
  return () => subscription.remove();
}
