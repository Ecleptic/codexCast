# Codex Cast — Player UX Architecture

What Apple Podcasts, Overcast, and Pocket Casts converged on, distilled to the
structure Codex Cast adopts. Researched 2026-08-14; sources at the end.

The three disagree on chrome and vocabulary. They agree, almost completely, on
architecture — and that consensus is what makes a podcast app feel like one.

## The eight invariants

1. **A global mini player.** Present on every screen while anything is playing,
   floating above the tab bar. Tap opens the full player. Never scoped to one
   tab (our first shell got this wrong).
2. **Up Next is the spine of playback.** Every episode row can enqueue
   (play next / play last). When an episode ends, the next queued one starts.
   The queue is reachable from the player itself. Listening is a *session*,
   not a series of one-off plays.
3. **Home surfaces resumables.** The first screen is "Continue Listening"
   (in-progress episodes with visible progress) plus new releases — not the
   subscription list. Opening the app mid-episode and finding your place is
   the single most common user journey.
4. **The library is an artwork grid.** Shows are recognized by cover art, not
   read as text rows.
5. **The show page is a hero + managed list.** Artwork, author, follow state,
   settings up top; then newest-first episodes, each row carrying its full
   state: progress bar, played dimming, downloaded icon, duration remaining.
   Swipe actions for queue and played/archive.
6. **The full player is paged.** Swipeable panes — Pocket Casts tabs and
   Overcast cards are the same idea: **Queue | Now Playing | Notes/Chapters**.
   Transport, scrubber, speed, sleep timer live on the center pane.
   (Ours adds the ad timeline and mark-ad controls here — our §11.3.)
7. **Progress and played-state are universal.** Every list that shows an
   episode shows its state. Positions persist continuously and resume
   anywhere, including after relaunch.
8. **System integration is table stakes.** Lock screen / Control Center
   transport with correct elapsed time, AirPlay from the player, background
   audio. (Spec §10.5 — and competing apps get *dinged* in reviews for skip
   handling failing from car controls.)

## Codex Cast routing

```
TabView (global mini player floats above)
├── Home            Continue Listening · Up Next preview · New Releases
├── Podcasts        artwork grid → Show page
│                     └── Show page: hero + episode rows (state, swipes)
│                           └── Episode page: tabs Notes|Transcript|Ads|Info
├── Discover        search · top charts · add-by-URL
└── Settings        audio · limits · import/export · privacy
Full player (sheet): pages  Up Next | Now Playing | Notes
```

Playlists remain (Overcast's signature, our A5.2) — surfaced on Home rather
than as their own tab, with Up Next as the always-present first playlist.

## What this replaced

The first shell had: Library-as-list for a root, a mini player that existed
only inside two screens, no queue advancement, no position persistence, no
played state, no Home. Functional for testing detection; not a podcast player.

Sources:
- [Pocket Casts: Podcasts tab](https://support.pocketcasts.com/knowledge-base/podcasts-tab/) · [Up Next & queue](https://support.pocketcasts.com/knowledge-base/playing-episodes-and-managing-your-queue/) · [archiving/swipes](https://support.pocketcasts.com/knowledge-base/archiving-episodes/) · [Liquid Glass update](https://blog.pocketcasts.com/2026/06/11/liquid-glass/)
- [Overcast 5 review — MacStories](https://www.macstories.net/reviews/overcast-5-redesigned-now-playing-screen-search-siri-media-shortcuts-and-more/) · [2022 redesign — 9to5Mac](https://9to5mac.com/2022/03/25/overcast-podcast-update-new-design-more/) · [playlist-first navigation — MacStories](https://www.macstories.net/reviews/overcast-redesign-enhances-podcast-navigation-with-an-emphasis-on-playlists-and-recent-episodes/)
- [Apple Podcasts: follow & play](https://support.apple.com/en-us/118668) · [queue behavior](https://support.apple.com/en-lk/guide/iphone/iph3a22707a5/ios) · [Continue Playing improvements — 9to5Mac](https://9to5mac.com/2025/04/03/ios-18-4-has-apples-best-solution-yet-for-this-podcasts-app-flaw/)
