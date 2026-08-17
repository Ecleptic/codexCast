# Pitfalls — bugs this project has made more than once

Every entry here was shipped, found in the field, fixed, and then made
*again* somewhere else. Check this list before writing code in these areas.

## 1. Never dereference a stored file path

Episodes store `localPath` as an absolute path containing the app's
container UUID — **iOS changes that UUID on every install**. The file
survives; the address does not. A stale path silently fails every
`fileExists` check, so features quietly do nothing (the waveform never
appeared; Storage read 0 KB on a phone full of downloads; episodes
re-downloaded and streamed instead of playing locally).

Always resolve through `AppModel.localFileURL(for:)` (matches by
**filename** against today's media directory), or pass `mediaDirectory`
into layers that can't reach the app model. Delete the `SilenceMap`
sidecar wherever the media file is deleted.

## 2. Views in detached hosts must be self-contained

`@Environment(AppModel.self)` and `@Environment(Router.self)` **trap** —
a hard crash — when the value isn't in scope. SwiftUI renders some
content in a *detached* host that does not inherit the surrounding
environment:

- `.contextMenu(preview:)` previews (crashed on long press)
- sheets attached above the level where the value was injected (the
  player sheet crashed because the router was injected inside the tabs)

Rule: any view that can be rendered detached takes **plain values**, or
the presenting side re-injects what it needs. Watch nested views too —
`EpisodeArtwork` reads the model, so putting it in a preview crashes.

## 3. A database write is not a UI update

Views observe in-memory arrays (`library`, `nowPlayingSegments`,
`playlists`). Writing to the database without refreshing them means the
user taps a button and *nothing happens* — reported verbatim twice.

Every mutating method finishes by refreshing what shows it:
`refreshSegmentsIfPlaying(episode)`, `reloadLibrary()`, or the caller's
own reload.

## 4. System containers own their contents

Inside a `List` row, the row — not your subview — owns hit-testing and
context menus:

- `.buttonStyle(.plain)` on a small control in a row loses its taps to
  the row (the genre chips were dead). Use `.borderless` with an
  explicit `.contentShape`.
- `.contextMenu` attached inside a row whose children are buttons makes
  the system pick a *button* as the lift source (long-press magnified
  only the play circle).
- **One context menu per row.** A horizontal shelf of cards inside one
  row can only have one, so the first card's menu answers for all of
  them — long-pressing card two acted on card one. A shelf inside a
  `List` cannot have per-card context menus; give each card its own
  `Menu` button instead.
- `.gesture` inside a `ScrollView` loses to the scroll pan; the scroll
  view claims the touch first.

## 5. `Label` drops its icon inside prominent button styles

`Label("Play", systemImage: "play.fill")` inside `.glassProminent` /
`.borderedProminent` renders text only. Compose explicitly:

```swift
HStack(spacing: 6) { Image(systemName: "play.fill"); Text("Play") }
```

## 6. Persisted settings must decode leniently

Swift's synthesized `Decodable` **throws on a missing key** rather than
using the property's default. Settings blobs load with `try?` and fall
back to a fresh instance — so adding one field silently resets every
preference the listener chose. Give each persisted struct a custom
`init(from:)` using `decodeIfPresent(...) ?? default`.

## 7. Long-lived views need `.task(id:)`

The player sheet outlives the episode inside it. A bare `.task` never
re-runs, so after auto-advance the Script, Info, and Up Next tabs showed
the *previous* episode. Key per-subject loads on the subject:
`.task(id: model.nowPlaying?.id)`.

## 8. Background tasks get ~30 seconds, and iOS remembers

A `BGAppRefreshTask` that overruns is killed; kills teach iOS to stop
granting time (we fell to once or twice a day). Rules: submit the next
request **first thing in the handler**, always set `expirationHandler`,
always `setTaskCompleted` exactly once, and keep the work inside the
budget. Heavy work (downloads, transcription, scanning) belongs to the
processing task.

## 9. A hand-written Info.plist needs the identity keys

Setting `INFOPLIST_FILE` means Xcode uses the file verbatim and injects
nothing. Omit `CFBundleExecutable`/`CFBundleIdentifier`/`CFBundleName`
and installs fail with an unhelpful "Please try again later" — hit once
on the app (missing bundle ID) and again on the share extension
(`MissingBundleExecutable`). Use build variables:
`$(EXECUTABLE_NAME)`, `$(PRODUCT_BUNDLE_IDENTIFIER)`, `$(PRODUCT_NAME)`.

## 10. Read the WHOLE response before concluding it is not there

Resolving a YouTube handle "failed" three times because the probe read
only the first 600 KB of a 1.2 MB page and the channel ID sits past the
first megabyte. Same family as trusting a fix without measuring: the
data was there, the look was too short.

## 11. Measure before believing a fix

Three separate sessions were spent "fixing" a waveform that was
rendering fine but drawing flat, then computing too slowly to appear,
then unable to find its file. Each round of guessing cost a build.
Timing the decode and pulling the app container off the phone found the
real causes in minutes.
