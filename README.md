<h1 align="center">SimpleRing</h1>

<p align="center">
  <strong>An unofficial, privacy-focused macOS menu bar app for Ring doorbells and cameras</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

SimpleRing puts your Ring devices in the Mac menu bar: live video, two-way audio, recent events and notifications, without a browser or your phone.

It's a stripped-down fork of [open-ring](https://github.com/abracadabra50/open-ring) with one rule: **the app only talks to Ring.** No AI services, no analytics, no third-party servers — including for WebRTC, which uses Ring's own STUN server only.

## Features

- **Live video** — WebRTC streams from every camera, with instant switching (swipe, arrows or ⌘1–4)
- **Sound and talk** — sound is off by default; the speaker and mic buttons toggle instantly, and the microphone is only open while you're talking
- **Zoom** — scroll, +/−, or the zoom buttons (up to 4×); 0 resets
- **Device controls** — floodlight and siren, where the device has them
- **Events** — recent rings and motion grouped by day, filterable; click one to play its recording full size and save it as MP4
- **Notifications** — native alerts for new rings and motion, checked every 15 s – 2 min
- **Sized to the video** — the window matches each camera's aspect ratio (no black bars) and keeps it while you drag an edge

## Install

Build the `.dmg` and drag SimpleRing to Applications:

```bash
./scripts/build-dmg.sh
```

The app is ad-hoc signed, so the first time you open it: right-click SimpleRing in Applications → **Open** → **Open**.

**Requirements:** macOS 14+, Xcode 15+.

## First launch

1. Sign in with your Ring email and password (macOS can autofill saved passwords)
2. Enter the verification code Ring sends you
3. Allow notifications and, when you first use push-to-talk, the microphone

Your session is stored in a single macOS Keychain item and refreshed automatically.

> **Keychain prompt after rebuilding:** each locally built copy is ad-hoc signed with a different signature, so macOS asks once whether the new build may read SimpleRing's Keychain item. Choose **Always Allow**. Signing with a stable identity (e.g. a free Apple Development certificate) makes the prompt go away for good.

## Network access

| Host | Why |
|------|-----|
| `oauth.ring.com` | Sign in and refresh the session |
| `api.ring.com` | Devices, events, recordings, device controls, live view signalling |
| `stun.ring.com` | WebRTC NAT traversal for live video |
| Ring media servers | The live video/audio stream itself (addresses supplied by Ring) |

## Project layout

```
app/
├── SimpleRing/                  # App shell: status item, panel, settings, app state
│   └── SimpleRingApp.swift
├── SimpleRingPackage/
│   └── Sources/
│       ├── RingClient/          # Ring API, Keychain session, WebRTC live view
│       ├── SimpleRingFeature/   # SwiftUI views, stream manager, Metal video renderer
│       └── DesignSystem/        # Colors, fonts, spacing
└── Config/                      # xcconfig + entitlements
scripts/
├── build-dmg.sh                 # Release build → .dmg
└── make-icon.swift              # Renders the app icon
```

## Disclaimer

**This is an unofficial app.** SimpleRing is not affiliated with, endorsed by, or connected to Ring LLC or Amazon.com, Inc. Ring is a trademark of Ring LLC. It uses Ring's private, undocumented API, which may change or be blocked at any time. Use at your own risk.

## License

MIT — see [LICENSE](LICENSE).
