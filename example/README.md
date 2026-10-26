# Long Ping example

React Native 0.81 (New Architecture) app for trying Long Ping on a phone and for the end-to-end rig in
`tools/e2e/`. Bundle id / applicationId `com.longping.example`.

The screen shows tracking state, the last fix, the upload queue and an activity log, with buttons for the
main commands. Every plugin event and command result is also POSTed as a JSON line to `REPORT_URL`.

## Setup

The plugin is installed from a tarball, the way customers get it. Build the tarball first:

```sh
(cd .. && npm pack)               # creates ../react-native-long-ping-0.1.0.tgz
npm install
cd ios && pod install && cd ..
```

After changing plugin code, run `npm pack` at the repo root again, then
`npm install ../react-native-long-ping-0.1.0.tgz`.

## Where it uploads

Everything environment-specific is in `src/config.ts`: `HOST` (simulator `127.0.0.1`, emulator `10.0.2.2`, both
port 8787 for `tools/e2e/receiver.mjs`), the tracking config and the upload token. For a phone, point `HOST` at a
machine the phone can reach. An `http://` host other than the local ones needs ATS (iOS) or
`network_security_config.xml` (Android) changes; an `https://` server needs none.

## Build without Metro

iOS simulator, Release (the JS bundle is embedded):

```sh
cd ios
xcodebuild -workspace LongPingExample.xcworkspace -scheme LongPingExample -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Release-iphonesimulator/LongPingExample.app
xcrun simctl privacy booted grant location-always com.longping.example
```

For a phone, open `ios/LongPingExample.xcworkspace` in Xcode, set a signing team and run the Release scheme.

## Command channel

`longping-example://cmd/<name>?<args>` runs the same commands as the buttons: `start`, `stop`,
`changePace?moving=1|0`, `sync`, `getCurrentPosition?persist=1|0`, `setConfig?json=<urlencoded>`,
`setAuthorization?token=<t>`, `state`, `queue`, `uploadLog`, plus `configure`, `clearQueue`, `provider`,
`requestPermission?level=always|whenInUse`, `clearLog`, `openSettings`. `tools/e2e/ctl.mjs cmd <name> k=v` sends
them (`ctl.mjs approve-scheme` first on a fresh simulator, to skip iOS's "Open in…?" prompt).
