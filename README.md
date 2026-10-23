# health-ios

HealthKit spike: can a sideloaded app on a **free Apple ID** read HealthKit and
receive **background delivery**? (Release 2, item 2.)

- App: **Health Sync** — SwiftUI, iOS 17+. Requests read access (steps, heart
  rate, sleep, workouts), shows today's step count, registers an
  `HKObserverQuery` + `enableBackgroundDelivery` for steps, and appends every
  background wake (timestamped) to an on-screen log.
- CI: GitHub Actions macOS runner builds an **unsigned .ipa** on every push to
  `main` and attaches it to the [`latest` release](https://github.com/cjwillin/health-ios/releases/latest)
  (workflow has `contents: write`, so release assets work — artifacts too).
- First commit gate: `scripts/scan-secrets.sh` — CI fails on any tracked file
  whose name or content matches token/secret/key patterns. No secrets and no
  health data ever go in this repo.

## Sideload on iPhone (free Apple ID, no paid dev account)

1. On the PC: install AltServer for Windows (already done) — it runs from the
   system tray with iTunes + iCloud (Apple.com versions) installed.
2. On the iPhone: install **AltStore** from AltServer (same Wi-Fi as the PC,
   AltServer tray icon → phone name → Install AltStore).
3. In Safari on the phone, open the
   [latest release](https://github.com/cjwillin/health-ios/releases/latest) and
   download `HealthSync-unsigned.ipa`, then in AltStore tap `+` → open the .ipa
   → sign in with the Apple ID when asked.
4. Trust the developer profile: Settings → General → VPN & Device Management →
   Apple ID → Trust. First launch: allow **Health** access to steps/heart rate/
   sleep/workouts.
5. Report back: the step count shown, and after ~1 h of normal use, how many
   lines appear in the "Background wake log".

Project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`project.yml`) — the `.xcodeproj` is created in CI, never committed.
