# Nightjar

A clean iOS client for Vicohome cameras. No ads, no upsell screens, just your cameras and what they saw.

## Features

- **Cameras** with the latest motion snapshot, online status, battery (and charging) and Wi-Fi strength.
- **Event timeline** grouped by day, filterable by what the camera detected (Person, Vehicle, Pet, Package, Bird, Motion), with "Load earlier" going back as far as your cloud plan keeps.
- **Clip playback** from Vicohome cloud recordings, with Save to Photos (MP4 or HLS) and share.
- **Camera details**: model, firmware, IP, network, serial and stream protocol.
- **Widget**: small and medium home screen widgets with the last event's snapshot, time and battery, plus lock screen widgets.
- **Diagnostics**: raw JSON for any camera or event, copyable, for poking at the API.

## Live view

Not in this build. Vicohome streams live video over WebRTC with its own signaling server, and the API hands out a signaling URL and TURN credentials per session. What's missing is the signaling message format, which needs a one time capture of the Vicohome app's traffic. The camera page shows whether your camera uses WebRTC (`streamProtocol`).

## Account

Vicohome can kick an account offline when it logs in somewhere else, so signing in here with your main account may sign the Vicohome app out. Make a second Vicohome account, share your cameras to it from your main account, and use that in Nightjar. The password is kept in the Keychain for automatic re-login; the token sits in the App Group so the widget can refresh.

## Setup

1. Sideload the IPA from [Releases](https://github.com/soum91/nightjar/releases) (AltStore, SideStore, Sideloadly or FlareStore), keeping app extensions on so the widget comes along. The sideloading source is `https://raw.githubusercontent.com/soum91/nightjar/source/source.json`.
2. Sign in, pick the region your account is on (Americas = `api-us.vicohome.io`, Europe = `api-eu.vicoo.tech`, or a custom base URL).

## Build

Every push to `main` builds `Nightjar-<version>-build-<N>.ipa` on GitHub Actions and publishes it as release `build-N` with a changelog since the previous build. The app and widget are ad-hoc signed with the `group.com.soum91.nightjar` App Group.

Local: `brew install xcodegen && xcodegen generate`, open `Nightjar.xcodeproj`.

## API

Reverse engineered by [dydx/vico-cli](https://github.com/dydx/vico-cli). JSON POSTs with the token in `Authorization`:

| Endpoint | Body | Used for |
| --- | --- | --- |
| `/account/login` | `email`, `password`, `loginType: 0` | token (`data.token.token`) |
| `/device/listuserdevices` | `language`, `countryNo` | cameras |
| `/device/selectsingledevice` | `serialNumber` | camera details |
| `/library/newselectlibrary` | `startTimestamp`, `endTimestamp` (unix seconds, as strings) | events |
| `/library/newselectsinglelibrary` | `traceId` | one event with fresh media links |

Errors come back as `result` (or `code`) != 0; -1024 to -1027 are session errors.

Unofficial. Not affiliated with Vicohome.
