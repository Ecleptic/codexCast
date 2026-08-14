# Codex Cast

A native iOS podcast player that detects and skips ads entirely on device, and learns from every
correction you make.

The mental model is **SponsorBlock for podcasts, without the crowd.** Where SponsorBlock relies on
many users submitting timestamps, Codex Cast relies on one listener's corrections plus an
on-device model, accumulating into a personal database that gets better every week.

No account. No server. No API key. No telemetry.

See [`codex-cast-spec-v2.1.md`](codex-cast-spec-v2.1.md) for the full specification.

## Requirements

- iOS 27.0 or later — a hard floor, with no back-deployment
- Apple Intelligence–capable hardware for ad classification (the app remains fully functional
  without it; detection quality degrades, nothing breaks)
- Xcode 27 / Swift 6.4 to build

## Structure

```
App/                       thin SwiftUI app target
Packages/CodexCastKit/     all logic, one module per subsystem
Spike/                     Phase 0 audio-signal spike — throwaway by design
Fixtures/                  labeled corpus and feed fixtures
Resources/Prompts/         versioned model instructions
```

`CodexCastKit` modules depend downward only: `CodexCastCore` depends on nothing, and nothing
depends on the app target. GRDB is the only third-party dependency.

## Building

```sh
cd Packages/CodexCastKit && swift test
```

Core, Feeds, and Persistence test on macOS without a simulator. Transcription, playback, and
classification require a device.

## Legal and ethical posture

- **Audio is never modified.** Codex Cast never cuts, re-encodes, or redistributes media. The file
  on disk is byte-identical to what the host served. Skipping is a playback behavior, closer to a
  chapter skip than an edit.
- **Shows still get their download statistics.** Episodes download normally.
- **Skipping is always optional and overridable.** Any segment can be played through.
- **Sponsor cards, not just skips.** When a sponsor segment is detected, the brand, promo code, and
  offer surface as a tappable card — so someone who wants to support a show can act on an offer
  without listening to sixty seconds of copy.
- **The learning database is local and personal.** No telemetry, of any kind, ever.
