// Runs once per JS start (imported from index.js): subscribe to every plugin event, configure, hand over the
// upload token, then accept deep-link commands. Never calls start(): tracking that was on resumes natively.
import { AppState } from 'react-native';
import LongPing from 'react-native-long-ping';
import { listenForCommandLinks } from './commands';
import { AUTH, CONFIG } from './config';
import { describeError, report } from './report';

const subscribeAll = () => {
  LongPing.onLocation((p) => report('event', 'location', true, p));
  LongPing.onMotionChange((p) => report('event', 'motionchange', true, p));
  LongPing.onHttp((p) => report('event', 'http', p.ok, p));
  LongPing.onProviderChange((p) => report('event', 'providerchange', true, p));
  LongPing.onAuthorization((p) => report('event', 'authorization', false, p));
  LongPing.onEnabledChange((p) => report('event', 'enabledchange', true, p));
  LongPing.onConfigChange((p) => report('event', 'configchange', true, p));
  LongPing.onError((p) => report('event', 'error', false, p));
};

async function setUp(): Promise<void> {
  try {
    report('cmd', 'configure', true, await LongPing.configure(CONFIG));
  } catch (error) {
    report('cmd', 'configure', false, describeError(error));
  }
  try {
    await LongPing.setAuthorization(AUTH);
    report('cmd', 'setAuthorization', true, null);
  } catch (error) {
    report('cmd', 'setAuthorization', false, describeError(error));
  }
}

report('app', 'launch', true, { appState: AppState.currentState });
AppState.addEventListener('change', (state) => report('app', 'appState', true, { appState: state }));
subscribeAll();

/** Settles once configure() and setAuthorization() have run. */
export const ready: Promise<void> = setUp();

listenForCommandLinks(ready);
