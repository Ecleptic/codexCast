# Codex Cast — roadmap (2026-08-14)

Synthesized from three parallel investigations: a full audit of this codebase
against `codex-cast-spec-v2.1.md` + addenda, a feature survey of Overcast /
Apple Podcasts (iOS 26.2) / Pocket Casts, and a pattern-mining pass over
codexReader (the sibling app).

## Where we stand

Phase 1 (the player) is solid and daily-drivable. Phase 2 (detection) works
end to end but is missing three spec items. Phase 3 (the learning layer — the
whole reason this app exists) is the largest gap: the database tables are all
there, but most of the learning behaviors that should write to them are not.
Phase 0's device-measurement arms and the final go/no-go are still open.
Phase 4 video plays but in a separate player with no ad skipping.

## Tier 1 — finish the phases (spec debt, in order)

1. **Smart Speed + Voice Boost actually change the sound.** The settings
   exist and do nothing — the highest trust-cost gap in the app. Voice Boost
   via an audio tap on the player; Smart Speed by pre-scanning downloaded
   audio for silence gaps and easing the playback rate up inside them.
2. **Learning-layer depth (§6):** Stage 0 position rules with per-show
   running stats ("this show's first 90 seconds is always an ad"), the
   remaining correction verbs (adjust boundaries, always skip here, never
   skip this show's intro), a real persisted sponsor registry linked to
   segments, and feeding rejected segments back into scans as negative
   examples (classifier already accepts them; nothing supplies them).
3. **Confidence calibration (§5.7)** — directly explains the
   zero-length-90%-confidence segment we already saw in the field. Cheap.
4. **Addenda:** A1 transcript-desync auto-check (technique already proven in
   `Spike/check_transcript_drift.py`), A2 per-show badges, A3 end-of-episode
   review card + bulk learning export.
5. **Detection polish:** Stage 3 silence-gap boundary snap in the live scan
   path; dynamic context-window sizing instead of the hardcoded 240s (a spec
   MUST); chapter generation from detections when feeds ship none.
6. **Phase 0 close-out:** arms 2/3 (audio into the on-device model) + the
   written §14.5 go/no-go; corpus to 10 episodes (labels come from Cam via
   the in-app tools).
7. **Phase 4:** route video through the shared playback engine so ad skipping
   and the timeline work there too.

## Tier 2 — borrowed features, ranked by value ÷ effort

From the competitor survey and codexReader mining. The baseline already
covers most "table stakes"; these are the standouts:

1. **Listening stats + "time saved"** (Pocket Casts' most-shared screen;
   codexReader already has the derivation pattern) — pairs perfectly with ad
   skipping: *time saved by skipped ads* is a stat no competitor can show.
2. **Auto-archive / auto-delete played downloads** with a grace period
   (codexReader has the exact policy UI: immediate vs 24h delay).
3. **Persistent, searchable listening history** — Apple Podcasts' single
   most-complained-about gap; we already have the data.
4. **Timestamped bookmarks** — cheap; Pocket Casts charges for it.
5. **Live Activities**: sleep-timer countdown + now-playing with chapter
   progress in the Dynamic Island. codexReader's Swift patterns (countdown
   text, custom app badge) port almost directly. Nobody has nailed this.
6. **Home-screen "Continue" widget** + interactive play/pause widget.
7. **Siri / App Intents**: play, sleep timer, "mark that as an ad" by voice —
   that last one is unique to us. codexReader solved the packaging gotchas.
8. **Sleep timer shake-to-extend** (small, delightful).
9. **Storage footprint screen** with per-category breakdown (codexReader
   pattern; a downloads-heavy app earns it).
10. **CarPlay** (natural fit; codexReader has the scene-lifecycle blueprint).
11. **Clip sharing** with transcript captions (bigger lift; growth feature —
    Overcast/Pocket Casts both invested here).
12. **Standalone Watch playback** (large lift; defer until the core learning
    loop is finished).

## Explicitly not doing

Streaming removal (Overcast's choice; we keep streaming), folders (playlists
cover it), parametric EQ (niche), cross-device sync (single-device app for
now — revisit with codexReader's encrypted-iCloud pattern if ever needed).
