import { parseCommandUrl, runCommand } from '../src/commands';

jest.mock('react-native-long-ping', () => ({
  __esModule: true,
  default: { getQueueCount: jest.fn(async () => 3) },
}));
jest.mock('../src/config', () => ({
  HOST: 'http://127.0.0.1:8787',
  CONFIG: {},
  AUTH: { accessToken: 't', refreshToken: 'r', refreshUrl: 'http://127.0.0.1:8787/refresh' },
  REPORT_URL: null,
  URL_SCHEME: 'longping-example',
}));

describe('parseCommandUrl', () => {
  it('reads the command name and decoded arguments', () => {
    expect(parseCommandUrl('longping-example://cmd/changePace?moving=0')).toEqual({
      name: 'changePace',
      args: { moving: '0' },
    });
    expect(parseCommandUrl('longping-example://cmd/setConfig?json=%7B%22movingIntervalSec%22%3A1%7D')).toEqual({
      name: 'setConfig',
      args: { json: '{"movingIntervalSec":1}' },
    });
    expect(parseCommandUrl('longping-example://cmd/start')).toEqual({ name: 'start', args: {} });
  });

  it('ignores other URLs', () => {
    expect(parseCommandUrl('https://example.com/cmd/start')).toBeNull();
    expect(parseCommandUrl('longping-example://other/start')).toBeNull();
  });
});

describe('runCommand', () => {
  it('resolves known commands and reports unknown ones without throwing', async () => {
    await expect(runCommand('queue')).resolves.toEqual({ ok: true, payload: 3 });
    await expect(runCommand('nope')).resolves.toMatchObject({ ok: false, payload: { code: 'UNKNOWN_COMMAND' } });
  });
});
