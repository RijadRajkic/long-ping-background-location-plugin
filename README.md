# Long Ping

Background location for React Native that reports on a clock you set: every 5 seconds, every minute, every
10 minutes, whatever your product needs. Separate intervals for moving and parked. Native upload queue that
survives dead zones, app kills and reboots. Built for fleets, deliveries and field teams, where "the phone went
quiet for three hours" is not acceptable.

- **Any interval, from 1 second.** Fixes come from a fixed clock, not from a motion classifier that can get
  stuck in the wrong state on some phones.
- **Native end to end.** Taking fixes, deciding moving/parked, storing and uploading all run in native code.
  JavaScript can be frozen, killed or never started; tracking carries on.
- **Uploads that don't give up or give in.** SQLite queue, batching, exponential backoff, token refresh. A 401
  pauses uploads until you hand over a new token; it never stops tracking.
- **Your server, your format.** Default JSON, or your own template per record. Change intervals from your
  server by adding a field to the upload response; no app release needed.
- **Recovers on its own.** Android restarts after reboots, app updates and service kills. iOS relaunches after
  termination on significant movement or leaving the parked area.
- **Explains its silences.** An on-device log of every state change, restart and upload, readable from JS.

Requires React Native 0.76+ (New Architecture), iOS 15.1+, Android 7.0+ (API 24).

## Install

```sh
npm install react-native-long-ping
cd ios && pod install
```

### iOS

`Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Your location is shared with dispatch while you are on duty.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Your location is shared with dispatch while you are on duty, including when the app is closed.</string>
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
</array>
```

### Android

Nothing to add: the plugin's manifest brings the location, foreground-service and boot permissions. On Android
13+ ask for `POST_NOTIFICATIONS` so the tracking notification is visible. If your Play listing qualifies, also
declare `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` to use the direct exemption prompt.

## Quick start

```ts
import LongPing from 'react-native-long-ping';

await LongPing.configure({
  licenseKey: 'LP1.…',             // release builds only; debug builds run without one
  movingIntervalSec: 30,
  parkedIntervalSec: 180,
  http: {
    url: 'https://api.example.com/locations',
    batch: true,
    uploadIntervalSec: 60,
  },
  notification: { title: 'On duty', text: 'Sharing your location with dispatch' },
});

await LongPing.setAuthorization({ accessToken: token });

// Your own rationale screen first, then:
await LongPing.requestPermission('always');
await LongPing.start();

const sub = LongPing.onLocation((location) => console.log(location.coords));
```

`configure()` is safe to call on every launch: it never starts, stops or shows a prompt. If tracking was
running when the app was killed, it is already running again by the time your JS loads.

## What your server receives

`POST` (or `PUT`) with `Content-Type: application/json`. Batch mode:

```json
{
  "locations": [
    {
      "uuid": "6f1c2a1e-8b9e-4c1a-9a43-0d6c1d1a7f10",
      "timestamp": "2026-10-26T12:00:00.123Z",
      "event": "interval",
      "is_moving": true,
      "coords": { "latitude": 43.85, "longitude": 18.41, "accuracy": 4.8, "speed": 12.3, "heading": 181, "altitude": 520.4 },
      "battery": { "level": 0.82, "is_charging": false },
      "mock": false
    }
  ]
}
```

`uuid` is unique per fix, so a retried upload can be de-duplicated. Reply with any 2xx to accept the batch.
Need a different shape? Set `http.locationTemplate`, e.g. `'{"lat":{{latitude}},"lng":{{longitude}},"at":"{{timestamp}}"}'`.

### Steering devices from your server

Include a `long_ping` object in any 2xx reply:

```json
{ "long_ping": { "config": { "movingIntervalSec": 5, "http": { "uploadIntervalSec": 15 } } } }
```

The device merges the config immediately, even while the app is in the background. `{"long_ping": {"stop": true}}`
stops tracking.

## Events

`onLocation`, `onMotionChange`, `onHttp`, `onProviderChange`, `onAuthorization`, `onEnabledChange`,
`onConfigChange`, `onError`. Each returns a subscription with `remove()`.

## Platform limits worth knowing

- **iOS** only keeps a background app alive while location updates are running, so Long Ping keeps them running
  for as long as tracking is on. Between fixes it drops to a low-power mode when the interval is a minute or more.
  If the user swipes the app away, iOS stops it until the device moves a few hundred meters.
- **Android** OEM battery managers (Samsung "sleeping apps", Xiaomi, Huawei and others) can freeze any app.
  `LongPing.deviceSettings.openPowerManagerSettings()` takes the user to the right screen; see dontkillmyapp.com.

## License

Commercial. A license key is tied to your app's bundle id / application id and covers every release published
up to its update date; it never stops working at runtime. Debug builds, simulators and emulators run without a
key. See `LICENSE.md`.
