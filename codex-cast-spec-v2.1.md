# Codex Cast — Implementation Spec

**Author:** Cam Green
**Target agent:** Claude Code
**Spec version:** 2.1
**Date:** 2026-08-13
**Supersedes:** v2.0, v1.0

---

## 0. How to use this document

This is a build spec, not a tutorial. It assumes the implementing agent is comfortable with
modern Swift concurrency, SwiftUI, AVFoundation, and SQLite.

Sections 1–4 are context and must be read before writing code. Sections 5–13 are the
implementable surface. Section 15 defines the phased delivery order — **build in that order**,
and do not start a later phase until the earlier phase's acceptance criteria pass.

Where this spec says **MUST**, treat it as a hard requirement. Where it says **SHOULD**,
deviate only with a written justification in the PR description. Where it says **OPEN**, stop
and ask before choosing.

### 0.1 Changelog

**v2.0** replaced v1.0's Claude API architecture with a fully on-device design.

**v2.1** adds, on top of v2.0:

- The app is named **Codex Cast**.
- **Implicit corrections** (§6.8) — rewind and manual-skip behavior harvested as weak learning
  signal. New, and one of the more valuable additions.
- **Processing pipeline settings** (§9) — per-stage toggles with three-state inheritance,
  trigger modes, dependency enforcement, and event-keyed notifications. This was entirely absent
  from v2.0 and is a substantial new section.
- **Video podcast support** (§8.3) via `<podcast:alternateEnclosure>`. Detection remains
  audio-only regardless of playback rendition.
- **Chapter generation** (§5.8) for feeds that don't supply chapters.
- **Ad chunking** — 5s minimum duration, adjacent segments merged into contiguous skip blocks.
- Stage 3 relaxed substantially (§5.4) per the SponsorBlock framing.
- Stage 1 window fragmentation policy (§5.3.2), confidence fallback via window agreement
  (§5.7), post-hoc boundary snapping (§5.3.4).
- Validation-gate fix (§5.6): the 40% guard no longer overrides user instructions.
- Phase 0 dependency fix (§14, §15).

### 0.2 Design posture

The mental model for Codex Cast is **SponsorBlock for podcasts, without the crowd.** Where
SponsorBlock relies on many users submitting timestamps, Codex Cast relies on one user's
corrections plus an on-device model, accumulating into a personal database that gets better every
week.

Two consequences follow, and they relax requirements rather than tighten them:

1. **Detected segments are conceptually chapter markers.** Many feeds already ship
   `<podcast:chapters>`; ad segments are the same kind of object, inferred rather than authored.
   Boundary precision on the order of a second is fine. Do not over-engineer boundary detection.
2. **Audio is never modified.** Skipping is a playback behavior, exactly like a chapter skip.

---

## 1. Problem statement

Existing iOS podcast ad-skippers (Skipper, drea, Herd, PurerPodcasts, Podgy, AdSkipPro) all do
roughly the same thing: transcribe on-device, classify the transcript, skip the flagged spans.
They share three deficiencies:

1. **They do not learn from the user.** At best a correction is telemetry sent to the developer.
   Nothing changes on the device for the next episode.
2. **They have no cross-episode memory.** A sponsor read appearing in every episode of a show is
   re-detected from scratch every time, and re-missed every time if the model is weak on it.
3. **They have no structural priors.** A show whose pre-roll is always the first 75 seconds is
   treated identically to a show with no pre-roll.

The core thesis: **the learning layer matters more than the model.** A mediocre classifier with a
good memory beats a good classifier with no memory, because podcast advertising is extraordinarily
repetitive — the same sponsors, the same read scripts, the same structural positions, week after
week.

This matters *more* under the on-device architecture, not less. The on-device model is not going
to out-reason a frontier model on an ambiguous host read. It does not need to. It needs to
classify novel ads often enough that the pattern database can absorb them, after which the model
is not consulted at all.

**Podcasts recur.** Most subscriptions are daily or weekly. A correction made today improves
tomorrow's episode of the same show. The system does not need to be right immediately; it needs to
converge, in perpetuity, across every episode the user hears.

### 1.1 The one-sentence version

A native iOS podcast player that transcribes episodes on-device, classifies ad segments through a
four-stage pipeline (structural priors → learned patterns → on-device LLM → refinement), skips
them during playback like chapter markers, and treats every user correction — explicit *and*
implicit — as durable training data persisting across episodes and shows, with no server, no
account, and no API key.

---

## 2. Non-goals

- **Any required network service.** Feeds and media are fetched over HTTP; that is the only
  network dependency. Detection is entirely local.
- **Audio modification.** Codex Cast never cuts, re-encodes, or redistributes media. The file on
  disk is byte-identical to what the host served.
- **Accounts, sync, or crowdsourced timestamps.** The pattern database is local and personal.
- **YouTube- or Spotify-exclusive shows.** No public RSS, permanently out of scope. YouTube does
  not permit third-party playback clients.
- **Non-English detection** in v1. Architecture must not preclude it; do not build it.
- **watchOS.** `SpeechAnalyzer` is unavailable there in the current SDK.
- **Custom LoRA adapters.** Version-locked to a base model and require retraining on every Apple
  update. Unacceptable maintenance burden for v1.
- **Visual ad detection.** AFM 3 accepts image input, so sampling video frames for visual-only ad
  overlays is technically possible. Out of scope — it multiplies inference cost for a case that
  barely exists in RSS video podcasts, where sponsor content is spoken anyway.

---

## 3. Platform, tooling, and constraints

| Item | Decision |
|---|---|
| **Minimum OS** | **iOS 27.0** — hard floor, no back-deployment |
| Develop against | iOS 27 SDK, latest Xcode |
| Language | Swift 6, strict concurrency, no `@unchecked Sendable` without justification |
| UI | SwiftUI with native system components throughout — see §3.2 |
| Persistence | **GRDB.swift**, not SwiftData — see §6.0 |
| Networking | `URLSession` + `async/await`, no third-party HTTP layer |
| Feed parsing | `XMLParser` wrapper, hand-rolled — see §8.2 |
| Transcription | `SpeechAnalyzer` / `SpeechTranscriber` (Speech framework) |
| Classification | `FoundationModels` — `SystemLanguageModel` + `LanguageModelSession` |
| Dependency policy | Minimize. GRDB is the only mandatory third-party dependency. |
| Architecture | MV(VM-lite): SwiftUI views observing `@Observable` models. No Redux, no TCA, no coordinator layer. |

### 3.1 Why iOS 27 minimum

This is the conservative choice, not the aggressive one.

On iOS 26 both critical frameworks are first-generation: `SpeechAnalyzer` shipped with timing
attributes and presets subsequently refined, and Foundation Models exposed the older, smaller
model with weaker tool calling and a fixed 4,096-token context. Supporting iOS 26 means
maintaining availability ladders and degraded-mode branches through the entire detection
pipeline — precisely the surface area that fails quietly and is miserable to debug.

An iOS 27 floor gives one coherent platform: AFM 3 (including the larger Core Advanced tier where
hardware permits), the mature `SpeechAnalyzer` surface, and the any-provider protocol layer, all
present unconditionally.

The tradeoff is addressable market, which for a personal daily driver is irrelevant.

### 3.2 Native components mandate

Codex Cast **MUST** feel like an Apple app:

- System `List`, `NavigationSplitView` / `NavigationStack`, `.searchable`, `.refreshable`
- SF Symbols throughout; no custom icon set
- Standard `Menu`, `ContextMenu`, `.swipeActions`, `ConfirmationDialog`
- Native `Slider` / `Stepper` / `Toggle` / `Picker` in settings; no bespoke controls
- Dynamic Type respected at every size; no fixed font sizes
- Full VoiceOver labeling, especially the segment timeline (§11.3)
- Dark mode and tinting via the system palette; app accent color only
- Standard `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`
- Live Activity for the current episode
- `AVPlayerViewController` for video playback, including Picture-in-Picture

Custom drawing is permitted **only** for the segment timeline and waveform.

---

## 4. Architecture overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Discovery & feed layer (§8)                                    │
│  iTunes Search API (directory) → RSS feed URL → subscribe       │
│  RSS fetch → episode metadata → rendition selection → download  │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  Processing pipeline (§9) — every stage independently toggleable│
│  download → transcribe → chapters → ad scan                     │
│  global defaults, per-show overrides, trigger modes             │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  Transcript layer                                               │
│  a) <podcast:transcript> if present                    (free!)  │
│  b) SpeechAnalyzer on the AUDIO rendition             (default) │
│  → TimedTranscript: [(text, startMs, endMs)]                    │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  Detection pipeline (§5) — ALL ON DEVICE                        │
│   Stage 0  Structural priors     per-show position rules        │
│   Stage 1  Pattern matching      learned sponsor fingerprints   │
│   Stage 2  AFM 3 classification  unresolved windows only        │
│   Stage 3  Refinement            chunk merge, cheap boundary fit│
│  → [DetectedSegment] with confidence, provenance, rationale     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  Playback layer (§10, §11)                                      │
│  AVPlayer + boundary observers → skip with undo                 │
│  Audio or video rendition; segments identical either way        │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  Learning layer (§6) ← THE POINT OF THE APP                     │
│  Explicit corrections + implicit playback signals →             │
│  patterns, sponsors, position rules → back into Stages 0 and 1  │
└─────────────────────────────────────────────────────────────────┘
```

**The critical invariant:** every stage records *provenance* on every segment it produces. When
the user corrects a segment, the system must know which stage produced it and on what evidence, so
the correction routes to the right repair. A false positive from a learned pattern demotes that
pattern. A false positive from the model creates a negative exemplar. Different repairs; never
conflate them.

### 4.1 On dynamic ad insertion

Most large podcasts stitch ads in at download time, so different listeners receive different ads
at different offsets, and a re-download may differ from the original.

**This is a non-issue for Codex Cast, and it is one of the strongest arguments for the on-device
architecture.** Detection runs against the exact file on this device. Whatever ads that file
contains are the ads that get detected.

Two consequences to implement:

- Store a content hash (or `<podcast:integrity>` value where the feed supplies one, §8.2) on the
  downloaded media. If a re-download produces a different hash, invalidate that episode's
  segments and requeue detection. One column and one check — not a subsystem.
- Learned **patterns** are unaffected by DAI, because they are text, not timestamps. A sponsor
  read inserted at 4:12 today and 7:45 next week matches the same pattern both times. Say this
  explicitly in code comments; it is the core reason the design uses text patterns rather than
  cached timestamps.

---

## 5. Detection pipeline

### 5.0 Output type

```swift
struct DetectedSegment: Identifiable, Codable, Sendable {
    let id: UUID
    let episodeID: Episode.ID
    var startMs: Int
    var endMs: Int
    var kind: SegmentKind          // .ad, .sponsorRead, .selfPromo, .intro, .outro
    var confidence: Double         // 0.0...1.0, calibrated — see §5.7
    var provenance: Provenance
    var rationale: String?
    var sponsorID: Sponsor.ID?
    var userState: UserState       // .unreviewed, .confirmed, .rejected, .adjusted
    var chunkID: UUID?             // adjacent segments merged into one skip block, §5.5
}

enum Provenance: Codable, Sendable {
    case positionPrior(ruleID: PositionRule.ID)
    case patternMatch(patternID: AdPattern.ID, score: Double)
    case onDeviceModel(windowIndex: Int, modelTier: String)
    case acoustic(signal: AcousticSignal)      // Phase 0 outcome dependent
    case externalModel(providerID: String)     // §7.6, off by default
    case manual
}
```

`kind` matters because the user will want different skip policies per kind — host-read sponsor
segments skipped but the show's own Patreon plug left alone, or vice versa. **MUST** be a per-show
setting with a global default.

### 5.1 Stage 0 — Structural priors

Runs first, costs nothing, resolves a large fraction of segments on regularly-heard shows.

For each `PositionRule` attached to this podcast (§6.3), evaluate whether its region should be
proposed. Rules anchor to one of:

- `.fromStart(offsetMs:)` — pre-roll
- `.fromEnd(offsetMs:)` — post-roll
- `.afterMarker(text:)` — e.g. a show that always says "we'll be right back"
- `.proportional(fraction:)` — mid-roll at a stable point through the episode

A rule carries a duration *distribution* (mean, variance, sample count), not a fixed length.
Propose at mean duration; Stage 3 fits the boundary.

**A Stage 0 proposal is not final.** It is a strong prior Stage 2 can override. If the model says
confidently that the first 90 seconds is content, believe it and record a counter-observation
(§6.3) — unless the rule is user-created, in which case the user wins (§6.3).

**This is the explicitly-requested feature:** "the beginning of this show is always an ad" must be
expressible in one gesture and must then hold.

### 5.2 Stage 1 — Learned pattern matching

Match the transcript against the local `AdPattern` table. Three tiers, cheapest first:

1. **Exact / near-exact.** SQLite FTS5 over the normalized pattern corpus. Catches identical read
   scripts — the common case for dynamically inserted ads and scripted host reads.
2. **Fuzzy.** Normalized token overlap (Jaccard over 3-grams) above threshold. Catches the same
   script with host improvisation.
3. **Semantic.** `NLEmbedding.sentenceEmbedding(for: .english)` cosine similarity against stored
   pattern embeddings. Catches the same sponsor in different words. Gate at a high threshold — an
   episode genuinely *about* mattresses must not match a mattress ad.

Each tier yields a score; combine per §5.7.

**Sponsor registry cross-check:** independently scan for known sponsor entity names (§6.2). A hit
alone is insufficient — hosts mention brands conversationally — but it raises the regional prior
and is passed to Stage 2 as a hint.

### 5.3 Stage 2 — On-device classification with AFM 3

Only regions unresolved by Stages 0 and 1 reach here. On a well-learned show this may be nothing,
and the episode classifies with zero model inference.

#### 5.3.1 Availability handling

```swift
import FoundationModels

let model = SystemLanguageModel.default
switch model.availability {
case .available:
    // proceed
case .unavailable(.deviceNotEligible):
    // Apple Intelligence unsupported hardware
case .unavailable(.appleIntelligenceNotEnabled):
    // user must enable in Settings — deep link them
case .unavailable(.modelNotReady):
    // assets still downloading — defer, retry later
default:
    break
}
```

**Codex Cast MUST remain fully functional when the model is unavailable.** Stages 0, 1, and 3
continue to work. Detection quality degrades; the app does not break, does not nag, does not block
playback. Surface one dismissible explanation in Settings, not a modal.

Availability facts for onboarding copy:

- Hardware floor is the Apple Intelligence device list — unavailable on iPhone 15 (standard),
  iPhone 14 series, and older iPads.
- The Advanced tier (AFM 3 Core Advanced, the 20B sparse model) requires newer hardware than the
  base tier. Query, never hardcode device lists.
- Apple Intelligence is unavailable in the EU on iPhone/iPad initially and in mainland China
  pending approval. Handle absence gracefully rather than detecting region.

#### 5.3.2 Context window and windowing

**This is the dominant implementation constraint.**

iOS 26's on-device model shipped a **4,096-token context covering instructions, prompt, and output
combined**. Apple has not published a figure for the iOS 27 on-device model. Therefore:

- **MUST** query `try await model.contextSize` at runtime and derive window sizing from it. Never
  hardcode a token budget.
- **MUST** use the token-counting APIs (introduced 26.4) to measure instructions, prompt, and
  overhead before dispatch, verifying the prompt fits with output headroom.
- **MUST** handle context overflow explicitly per Apple's TN3193 rather than letting it propagate.

Sizing:

- Target window: **3–5 minutes of transcript**, computed dynamically to fill the budget remaining
  after fixed costs.
- Overlap: **60–90 seconds**, so an ad straddling a boundary is fully visible in one window.
- Deduplicate across windows by interval overlap: segments overlapping >50% merge, taking the
  union of bounds and max confidence.
- Fixed prompt costs (instructions, sponsor list, negative exemplars) **MUST** be budgeted and
  capped. Inject only the top-N sponsors relevant to this show, never the whole table.

**Fragmentation policy.** When Stage 1 resolves a region mid-window, do **not** excise it and
re-window around the hole — with 3–5 minute windows that produces unusable fragments. Instead:

- Keep resolved regions **in** the window, marked in the prompt as already-classified context
  (`[AD — already identified: Squarespace]`). This preserves surrounding context and helps the
  model recognize adjacent ads in a stacked break.
- Skip a window entirely only when **every** region within it is already resolved.
- Define a minimum viable window (**90 seconds**); below that, merge with the neighbouring window
  rather than dispatching a stub.

Create a **new `LanguageModelSession` per window.** Apple's guidance is one session per distinct
single-turn interaction; reusing a session accumulates transcript context and exhausts the window.

Prefer **AFM 3 Core Advanced** where available (§7.2). The larger model is a principal reason the
iOS 27 floor is worth the cost.

#### 5.3.3 Structured output via guided generation

Do **not** prompt for JSON and parse strings. Use `@Generable` — the framework constrains decoding
to the schema, eliminating malformed-output failures while improving accuracy and inference speed.

```swift
@Generable
struct WindowClassification {
    @Guide(description: "Every advertising or promotional segment found in this window.")
    var segments: [AdSegmentCandidate]
}

@Generable
struct AdSegmentCandidate {
    @Guide(description: "Start time in milliseconds.")
    var startMs: Int

    @Guide(description: "End time in milliseconds.")
    var endMs: Int

    @Guide(.anyOf(["ad", "sponsor_read", "self_promo", "intro", "outro"]))
    var kind: String

    @Guide(description: "Confidence from 0.0 to 1.0.")
    var confidence: Double

    @Guide(description: "Brand or advertiser name if identifiable, otherwise empty.")
    var sponsor: String

    @Guide(description: "One sentence, at most 20 words, explaining the classification.")
    var rationale: String
}
```

Property ordering matters: guided generation fills in declaration order and later properties
condition on earlier ones. Keep `rationale` last so it follows the decision rather than steering
it.

Keep the schema **minimal**. Every field costs output tokens. Do not add fields "for future use."

**`kind` mapping.** `AdSegmentCandidate.kind` is a `String`; `DetectedSegment.kind` is
`SegmentKind`. Map explicitly with a failable initializer. An unrecognized value maps to `.ad` with
confidence multiplied by 0.8 and a note in `rationale` — never crash, never drop the segment.

#### 5.3.4 Boundary snapping is post-processing, not a prompt instruction

Do **not** rely on the model to emit timestamps aligned to transcript boundaries. It will not do
so reliably. Instead, **snap every model-emitted boundary to the nearest transcript segment
boundary in post-processing**, before anything downstream sees it. Reject segments where
`endMs <= startMs` after snapping.

#### 5.3.5 Instructions

The instructions block is a first-class artifact; version it at
`Resources/Prompts/classify_v1.md` and treat changes as reviewable.

Requirements:

- State the task: identify advertising and promotional content in a timestamped transcript window.
- Supply a **bounded** sponsor list relevant to this show ("these advertisers have appeared
  before; presence is evidence, not proof").
- Supply per-show context: show name, structure notes, user-written notes (§6.5).
- Note that **ads commonly run back-to-back in blocks of two to four**, each roughly 30 seconds.
  Finding one ad raises the prior for an adjacent one.
- **Emphasize precision over recall.** A false positive cuts real content and is far more annoying
  than a missed ad. When uncertain, report with low confidence rather than omitting.
- Define the sponsor-read vs. organic-product-discussion distinction. This is the hard case.

Write instructions in English regardless of content language — Apple's models are tuned for it.
Keep them tight; every token here is a token unavailable for transcript.

**Few-shot examples are a luxury this context window may not afford.** Measure. If two short
examples fit without shrinking the window below 3 minutes, include them. Otherwise rely on
instruction clarity and let the learning layer compensate.

#### 5.3.6 Performance and thermal budget

Cost is measured in battery and heat, not dollars.

- **MUST** run classification on a background actor, never blocking UI.
- **MUST** call `session.prewarm()` before a batch to avoid per-window model load.
- **MUST** process at most one episode at a time; never parallelize model inference.
- **MUST** check `ProcessInfo.processInfo.thermalState` before each window. At `.serious` or above,
  pause and resume when it drops. At `.critical`, stop.
- **SHOULD** respect Low Power Mode by deferring all non-urgent classification.
- Log per-window wall-clock and window count to `inference_log`. If a 60-minute episode exceeds
  ~5 minutes of device time in steady state, window sizing is wrong.

#### 5.3.7 Failure handling

- Model unavailable → episode retains Stage 0/1 results, marked `.modelUnavailable`. Playback
  works. Retry opportunistically.
- Context overflow → shrink the window and retry once; if it fails again, split and process halves.
- Guided generation failure or nonsensical output → one retry, then mark the window
  `.unclassified`. Never crash, never silently drop.
- Thermal or Low Power pause → requeue, do not fail.

### 5.4 Stage 3 — Refinement

Per §0.2, segments are chapter markers, not surgical edits. Boundary precision on the order of a
second is acceptable. **Keep this stage cheap.**

For each proposed edge:

1. If a `<podcast:chapters>` boundary lies within 2s, snap to it. Authored boundaries beat
   inferred ones.
2. Otherwise extract ±2s of audio, run energy-based VAD (RMS over 20ms frames — do not pull in a
   neural VAD), and snap to the nearest silence gap ≥180ms.
3. If no gap exists, keep the transcript boundary and widen the *content* side by 150ms. Better to
   include a fragment of ad than to clip speech.

Stage 3 also hosts whatever acoustic signals survive the Phase 0 spike (§14). Implement nothing
beyond the above until that spike reports.

### 5.5 Ad chunking

Ads run in blocks — typically two to four spots of about 30 seconds each, back to back. Handle
this explicitly:

- **Merge adjacent segments** separated by less than 5 seconds into a single skip block sharing a
  `chunkID`. Without this the user gets skip-play-skip stutter across four consecutive spots.
- The merged block is what gets skipped, indicated, and undone as a unit.
- **Corrections still apply per-segment**, so rejecting one spot in a block does not discard the
  learning from the other three. The UI presents the block, the database keeps the components.

### 5.6 Validation gate

Before a segment is eligible for auto-skip:

- Duration ≥ **5s** and ≤ 6 min. (5s, not 8s — short DAI spots like "this episode is sponsored by
  X" are real and were being excluded.) Outside that range, keep but never auto-skip; surface for
  review.
- Confidence ≥ user threshold (default 0.75; Conservative 0.85 / Balanced 0.75 / Aggressive 0.60).
- Not overlapping a user `.rejected` region for this episode or a `NeverSkipRule` for this show.
- **Runaway guard:** total flagged duration from *non-user-originated* provenance ≤ 40% of episode
  length. Above that, suppress auto-skip for those segments and flag the episode for review.

**The runaway guard MUST exclude user-created position rules, `.manual` segments, and
`.confirmed` segments from both the numerator and the suppression.** A user who has explicitly
said "always skip the first 90 seconds" must never have that instruction overridden because a
heuristic got nervous. The guard exists to catch a runaway classifier, not to second-guess the
user.

### 5.7 Confidence calibration

Raw scores across stages are not comparable. Maintain per-stage calibration from the user's own
correction history:

- Per stage and score decile, track (proposals, confirmations, rejections).
- Calibrated confidence = smoothed empirical precision for that decile, using a Beta(2,2) prior so
  early estimates are not wild.
- Recompute lazily — at most daily, or after every 20 corrections.

Combine multi-stage evidence with a naive-Bayes log-odds sum, capped at 0.98. Never report 1.0.

**Fallback for degenerate self-reported confidence.** Small models frequently emit near-identical
confidence for everything, leaving nothing to calibrate. Detect this: if the standard deviation of
model-reported confidence over the last 200 segments is below 0.05, switch that stage to
**agreement-derived confidence** — the fraction of overlapping windows that independently proposed
the segment. The overlap in §5.3.2 generates this signal for free. Log which method is active.

### 5.8 Chapter generation

When a feed does not supply `<podcast:chapters>`, Codex Cast can generate them. This is a
user-facing feature in its own right and a pipeline stage in §9.

- Runs after transcription, before or independently of ad scan.
- Segment the transcript into topical sections and generate a short title for each, using the same
  on-device model and the same windowing discipline as §5.3.
- Generated chapters are marked as such in the UI and are never confused with authored ones.
- Detected ad segments appear alongside chapters in the same timeline. Conceptually they are the
  same object type.
- Where a feed *does* supply chapters, use them and skip generation.

---

## 6. The learning layer

**This is the differentiating feature and it is load-bearing. If schedule pressure forces cuts, cut
from §8 and §10 before cutting anything here.**

### 6.0 Why GRDB and not SwiftData

The learning layer needs FTS5 full-text search, custom SQL for calibration aggregates,
deterministic migrations, and out-of-app database inspection. SwiftData provides none cleanly. Use
GRDB with explicit migrations in `Database/Migrations/`.

### 6.1 Schema

```
podcasts            id, feedURL, itunesCollectionID?, title, author, imageURL, addedAt,
                    skipPolicy (JSON), confidenceThresholdOverride,
                    pipelineSettings (JSON, §9), playbackSettings (JSON),
                    notificationSettings (JSON), preferredRendition, notes

episodes            id, podcastID, guid, title, publishedAt, durationMs,
                    renditions (JSON, §8.3), selectedRenditionID,
                    localPath, mediaHash, transcriptSource, processingState

transcripts         episodeID, source (.podcasting20 | .onDevice), createdAt
transcript_segments episodeID, idx, startMs, endMs, text

chapters            id, episodeID, startMs, title, source (.feed | .generated)

detected_segments   (as §5.0), plus createdAt, reviewedAt

sponsors            id, canonicalName, aliases (JSON), firstSeenAt, lastSeenAt,
                    occurrenceCount, embedding (BLOB)

ad_patterns         id, sponsorID?, podcastID? (null = global),
                    text, normalizedText, embedding (BLOB),
                    confirmCount, falsePositiveCount, lastMatchedAt, createdFrom

position_rules      id, podcastID, anchor (enum + params),
                    meanDurationMs, m2 (Welford), sampleCount,
                    hitCount, missCount, enabled, userCreated

never_skip_rules    id, podcastID?, episodeID?, startMs, endMs, reason

corrections         id, episodeID, segmentID?, type, source (.explicit | .implicit),
                    previousValue (JSON), newValue (JSON), createdAt
                    -- append-only, never delete

playback_signals    id, episodeID, segmentID?, kind, positionMs, createdAt, weight

suggestions         id, podcastID, kind, payload (JSON), evidenceCount,
                    createdAt, dismissedAt?

calibration_bins    stage, decile, proposals, confirms, rejects, updatedAt

inference_log       id, timestamp, episodeID, windowIndex, windowTokens,
                    outputTokens, wallClockMs, thermalState
```

`ad_patterns` **MUST** have an FTS5 virtual table mirror over `normalizedText`.

**Embedding growth.** Embeddings are stored per pattern and per sponsor. Prune patterns with zero
confirmations and no match in 180 days, and merge patterns whose mutual cosine similarity exceeds
0.95, summing their counts. Run during the background sweep (§6.9).

### 6.2 Sponsor registry

A sponsor is an entity, not a string. Extract from confirmed segments:

- Prefer the `sponsor` field the model returned.
- Fall back to `NLTagger` named-entity extraction (organization tags).
- Deduplicate by normalized-name match, then embedding similarity above 0.9, else create new.

Store a representative embedding per sponsor. When the same sponsor appears in a different show,
Stage 1 catches it immediately — the "ad repeated across podcasts" requirement.

Surface the registry as a browsable list: name, occurrence count, which shows they advertise on,
first and last seen. It makes the learning legible, which builds trust in the skipping.

### 6.3 Position rules and their statistics

Every confirmed segment updates position statistics for its show:

- Determine which anchor the segment fits.
- Update the rule's duration distribution using **Welford's online algorithm** (store mean and M2;
  never the sample list).
- Increment `hitCount`.

When a rule proposes a region the user rejects, or Stage 2 confidently contradicts, increment
`missCount`. Reliability = `hitCount / (hitCount + missCount)`, smoothed. A rule below 0.5
reliability with ≥6 samples auto-disables and notifies once.

**User-created rules** start at high confidence, **never auto-disable**, and are never overridden
by Stage 2. They appear separately in show settings for editing. A rule the user drew by hand is an
instruction, not a hypothesis.

**`.afterMarker` creation.** No correction action produces these automatically. They are created
either by the user in show settings, or promoted from a suggestion (§6.8) when the same
transcript phrase precedes a confirmed ad in ≥4 episodes of one show.

### 6.4 Explicit correction actions

The user-facing verbs. Implement all six.

| Action | Effect |
|---|---|
| **Confirm** | `userState = .confirmed`. Extract pattern → `ad_patterns` (or increment `confirmCount`). Extract/link sponsor. Update position stats. Calibration bin += confirm. |
| **Adjust boundaries** | As Confirm, but pattern extracted from the *corrected* span — critical, since the wrong span teaches the wrong text. Log old/new to `corrections`. |
| **Not an ad** | `userState = .rejected`. If `patternMatch`, increment `falsePositiveCount`; above 0.3 FP rate demote below auto-accept, above 0.5 disable. If `positionPrior`, increment `missCount`. If `onDeviceModel`, store a negative exemplar (§6.6). Create an episode-scoped `never_skip_rule`. Calibration bin += reject. |
| **Mark missed ad** | User drags an unflagged region. Creates `.confirmed` segment with `provenance = .manual`, full pattern and sponsor extraction, position stats update. **Highest-value correction in the system** — make it easy. |
| **Always skip this position** | Creates a user `position_rule` from the segment's anchor. One tap from a confirmed segment. |
| **Never skip this show's intro** | Creates a podcast-scoped `never_skip_rule` with a start-anchored region. |

**Every correction MUST apply optimistically and instantly.** Pattern extraction and embedding
computation happen on a background actor afterward. The user never waits on learning.

### 6.5 Per-show notes

Free text on each podcast, injected into Stage 2 instructions. An escape hatch for what the
structured system cannot express: *"The host's partner runs a bakery and he plugs it constantly —
treat that as self-promo, not content."*

**Cap at 300 characters** and count against the token budget (§5.3.2). Under a tight context this
is not free, and the UI should say so.

### 6.6 Negative exemplars

When the user rejects a model-produced segment, store its text as a negative exemplar scoped to
that show. Inject up to **2** into Stage 2 instructions: *"These passages from this show were
previously misclassified as ads; they are content."*

Prefer **diversity over recency** — choose exemplars with low mutual embedding similarity.
Truncate each to its most distinctive 100 characters. If the token budget is strained, drop
exemplars before shrinking the transcript window.

### 6.7 Explicit vs implicit signal

Explicit corrections (§6.4) are **authoritative**: they create, modify, and disable rules directly.

Implicit signals (§6.8) are **weak**: they adjust confidence and accumulate toward suggestions.
They **MUST NOT** create, modify, or disable any rule on their own.

This distinction is a hard invariant. Record `source` on every row in `corrections`.

### 6.8 Implicit corrections from playback behavior

Users correct the app constantly without meaning to. Harvesting that is free accuracy, because it
costs the user nothing.

**Signals to capture** into `playback_signals`:

| Signal | Interpretation |
|---|---|
| Rewind landing at or just before an auto-skip start, within ~10s of the skip | Weak false-positive evidence for that segment |
| Manual fast-forward across an unflagged region | Weak missed-ad evidence for that region |
| Manual fast-forward at a consistent position across multiple episodes of one show | Candidate position rule |
| Repeated transcript phrase immediately preceding manual skips in one show | Candidate `.afterMarker` rule |
| Episode abandoned within seconds of an auto-skip | Weak false-positive evidence |

**Mandatory guards.** These signals are noisy — people rewind because they missed a sentence, not
only because a skip was wrong.

- A single signal **never** changes a rule. It adjusts the affected segment's confidence by a
  bounded amount (**≤0.1**) and logs evidence.
- A pattern reaching **≥3 consistent occurrences across ≥2 episodes** graduates into a
  `suggestions` row.
- Suggestions are surfaced non-intrusively — a badge on the show screen, never a modal, never a
  notification. The user confirms or dismisses; only confirmation creates a rule.
- Dismissed suggestions are not re-raised for 90 days.
- A global "learn from my playback behavior" toggle, **on by default**, with a clear explanation
  that it is local-only.

Do not overfit the heuristics. Start with the first two signals; add the rest only if the eval
harness shows they help.

### 6.9 Background sweep

Podcast recurrence handles most of the learning payoff: a correction today improves tomorrow's
episode of the same show. No expensive reprocessing is needed.

One cheap sweep is still worth running, because it costs almost nothing:

- When patterns or sponsors change, re-run **Stage 1 only** over stored transcripts of
  downloaded-but-unplayed episodes.
- No transcription, no model inference — FTS5 and embedding matching against existing transcripts.
- Also performs embedding pruning (§6.1).
- Runs during `BGProcessingTask`, never in the foreground.

### 6.10 Export and inspection

Ship "Export learning data" producing JSON: patterns, sponsors, position rules, corrections,
suggestions. This is the user's data, it represents real accumulated effort, and it must be
portable. Accept the same file as import.

---

## 7. Model layer abstraction

### 7.1 Protocol boundary

```swift
protocol AdClassifier: Sendable {
    var identifier: String { get }
    var isAvailable: Bool { get async }
    var contextBudget: Int { get async }
    func classify(window: TranscriptWindow,
                  context: ClassificationContext) async throws -> WindowClassification
}
```

Implementations:

- `OnDeviceClassifier` — `SystemLanguageModel` + `LanguageModelSession`. **Default, and the only
  one enabled at ship.**
- `StubClassifier` — replays recorded fixtures for the eval harness (§13).
- `ExternalClassifier` — §7.6, disabled by default.

This boundary exists so the harness can run deterministically, not to hedge on architecture. Do
not over-engineer it.

### 7.2 Model tier selection

AFM 3 ships as Core (3B dense) and Core Advanced (20B sparse, higher hardware floor). Query
availability; **prefer Advanced where present** — the accuracy delta on ambiguous host reads is
exactly where this app is weakest, and it is a primary justification for the iOS 27 floor. Record
the tier in `Provenance.onDeviceModel(modelTier:)` so the harness reports separately; detection
quality will differ across devices and that must be visible.

### 7.3 No adapters in v1

Version-locked; require retraining on every Apple model update.

### 7.4 Private Cloud Compute

`PrivateCloudComputeLanguageModel` offers a 32K context behind a managed entitlement. **Not in
v1** — it requires an entitlement and violates the on-device-only property that is a core product
claim. Documented future option.

### 7.5 Multimodal

AFM 3 Core Advanced supports text, image, and audio input. Audio is the subject of the Phase 0
spike (§14). Do not build multimodal paths into the main pipeline before that spike reports.

### 7.6 Any-provider escape hatch

iOS 27 opened `LanguageModelSession` to any conforming provider. Implement `ExternalClassifier`
against it, but:

- **Disabled by default**, no entry point in the main settings flow.
- Configurable **per-show**, not globally — the use case is one stubborn show.
- Credentials in Keychain with `kSecAttrAccessibleAfterFirstUnlock`, never `UserDefaults`, never
  logged.
- If enabled, privacy copy (§12.1) **MUST** change automatically and visibly.

Build the seam; do not build a product around it.

---

## 8. Discovery, feeds, and media

### 8.1 Discovery

**There is no Apple Podcasts content API.** Apple Podcasts is a *directory* over the same open RSS
feeds every podcast app uses. Do not look for a subscription API; it does not exist.

What is public and free is the **iTunes Search API**:

- `https://itunes.apple.com/search?media=podcast&term=…` for search
- `https://itunes.apple.com/lookup?id=…` for a specific show
- Responses include `feedUrl` — the show's real RSS endpoint — plus `collectionId`, artwork at
  multiple sizes, genre, and episode counts

Flow: **search the directory → get `feedUrl` → subscribe to the RSS feed directly.** After that
Codex Cast never talks to Apple again for that show.

Requirements:

- `.searchable` with debounce, artwork and author in results
- Top-charts browsing by genre via the iTunes RSS generator endpoints
- **Add-by-URL**, first-class and not buried — Patreon-private feeds, self-hosted feeds, etc.
- **OPML import and export.** Non-negotiable for migration.
- Graceful handling of directory rate limiting; cache lookups.

### 8.2 Feed parsing

- RSS 2.0 + iTunes namespace + **Podcasting 2.0 namespace**
- `<podcast:transcript>` — if the feed ships a transcript (VTT, SRT, JSON), fetch it and **skip
  on-device transcription entirely.** Free, instant, often more accurate, and it removes the most
  expensive pipeline step. Check first, always.
- `<podcast:chapters>` — use directly; suppresses chapter generation (§5.8)
- `<podcast:integrity>` — where present, use for the media-hash check in §4.1
- `<podcast:alternateEnclosure>` — see §8.3
- HTTP caching via ETag / `Last-Modified` to avoid refetching unchanged feeds
- **Tolerate malformed XML.** Podcast feeds are frequently broken. Never crash; mark the feed
  errored and keep other subscriptions working.

### 8.3 Video podcasts and renditions

Video podcasts in RSS are handled through `<podcast:alternateEnclosure>`. The standard
`<enclosure>` remains the primary media file, and alternate enclosures attach additional versions
of the same episode — a video stream, a lower-bitrate audio file, a different codec, or a
different language. Each contains one or more `<podcast:source>` elements giving URIs, plus an
optional `<podcast:integrity>`. Attributes include `type`, `bitrate`, `height`, `codecs`, `lang`,
`title`, `rel` (groups alternatives), and `default` (marks the preferred rendition).

The emerging convention is **audio-first**: audio as the primary enclosure with an HLS video
stream as an alternate, so existing apps use audio, capable apps offer video, and listeners switch
between modes. The namespace also supports the reverse — an audio-only alternate on a video
podcast, explicitly so apps can switch.

**Architectural consequence, and it is a clean one:**

> **Detection always runs on the audio rendition, regardless of what the user plays.** The
> renditions are the same content, so ad timestamps are identical across them. Codex Cast
> transcribes the small audio file even when the user watches video. **No video decoding enters
> the detection pipeline at all.**

Implementation:

- Parse all renditions into `episodes.renditions`. Model as a list with type, bitrate, height,
  codecs, `rel` group, and `default` flag.
- **Rendition selection**: per-show preference (Audio / Video / Auto), defaulting to Audio.
  Bandwidth-aware — never auto-select a 1080p HLS stream on cellular.
- **Always download or cache the audio rendition** for analysis, even when the user's playback
  preference is video. It is small, and it is what the pipeline consumes.
- Video may be **streamed** (HLS) rather than downloaded, so a local video file may not exist.
  This is fine — detection never needed it.
- Where a video podcast offers **no** separate audio rendition, download the video file and extract
  the audio track via `AVAsset` for transcription. Playback still uses the video file.
- **Audio-only playback of video feeds** is a first-class per-show toggle. Most people subscribed
  to a video podcast listen rather than watch most of the time; this saves substantial bandwidth
  and battery.
- Storage management matters far more with video — episodes go from tens of megabytes to
  gigabytes. Per-show retention limits and a storage screen are required, not optional.
- Video playback uses `AVPlayerViewController` with Picture-in-Picture, fullscreen, and rotation.
  **Skip logic is unchanged** — the same boundary observers on the same timeline.

### 8.4 Downloads

- `URLSession` background configuration so downloads survive suspension
- Per-show auto-download with keep-latest-N retention
- Wi-Fi-only option, on by default, and separately configurable for video
- Storage screen with per-show usage and bulk delete

---

## 9. Processing pipeline and settings

This section covers what happens between "a new episode appeared in the feed" and "it is ready to
listen to," and how the user controls it.

### 9.1 Stages

| Stage | Produces | Requires |
|---|---|---|
| **Fetch** | Episode metadata from RSS | — |
| **Download** | Local media file | Fetch |
| **Transcribe** | `TimedTranscript` | Download (or a feed transcript, which skips this) |
| **Chapters** | `chapters` rows | Transcript |
| **Ad scan** | `detected_segments` | Transcript |

Fetch always runs. The other four are **independently toggleable** with global defaults and
per-show overrides.

### 9.2 Three-state inheritance

Every per-show pipeline setting is **Inherit / On / Off**, defaulting to Inherit, resolving against
the global value.

Do not use plain booleans at two levels — "I haven't decided" must be distinguishable from "I chose
off," or the UI cannot show the user what is actually happening. The show settings screen displays
the resolved value alongside the inherited source ("Off — inherited from global").

### 9.3 Trigger modes

Each enabled stage has a trigger:

- **On publish** — immediately when the episode appears
- **Wi-Fi only** — when on Wi-Fi
- **Overnight** — during `BGProcessingTask` with external power
- **Manual** — only when the user asks

Global default: Download on Wi-Fi, Transcribe and Ad scan overnight. Chapters off by default —
useful, but the least essential and not free.

The **just-in-time path** overrides all of it: if the user hits play on an unprocessed episode,
transcribe and scan the first 3 minutes immediately (pre-roll is the common case), start playback,
and continue ahead of the playhead in the background. **Never make the user wait on a full-episode
pass.**

### 9.4 Dependency enforcement

Dependencies are enforced in the UI, not merely implied:

- Enabling a downstream stage **offers to enable its prerequisites** in the same interaction.
- Disabling an upstream stage **greys out everything below it** with a visible reason ("Ad scan
  requires a transcript").
- A show configured to scan with nothing to scan is a bug, not a user choice. Make it
  unrepresentable.

### 9.5 Notifications

Notifications are keyed to **pipeline events**, not just publication:

| Trigger | Use case |
|---|---|
| On publish | Time-sensitive shows the user wants to know about immediately |
| On download complete | Ready to listen now, ads not yet scanned — news, daily shows |
| On fully processed | Ready to listen clean; the default where enabled |
| Never | Default |

Per-show, with a global default. **On download complete** is the important one: for a time-sensitive
daily show, waiting for a scan defeats the purpose, and the user would rather listen immediately
and let ad detection catch up on the next episode.

### 9.6 Surfacing unset settings

When a show is newly subscribed, **inherit globals silently** — do not interrogate the user with
four questions they will dismiss reflexively.

Instead, show a **dismissible setup card** on the show screen displaying the inherited settings
with one-tap customize. Same discoverability, no modal tax. The card auto-dismisses once the user
customizes anything for that show, and is dismissible permanently.

Global defaults are set once during onboarding, in a single screen with sensible pre-selections.

### 9.7 Job queue

Durable, SQLite-backed. Jobs: `download`, `transcribe`, `chapters`, `scan`, `sweep`. Each has
state, attempt count, last error, and priority.

- **One transcription at a time.** `SpeechAnalyzer` is memory-hungry; concurrent transcription of
  two long episodes will get the app jetsammed.
- **One classification at a time** (§5.3.6).
- Jobs stuck in `running` at launch reset to `pending` — the app was killed mid-job.
- The queue survives termination and resumes on next launch.
- `BGProcessingTask` for overnight work with `requiresNetworkConnectivity` and
  `requiresExternalPower`; `BGAppRefreshTask` for feed refresh.

### 9.8 Untranscribable episodes

Music shows, non-English audio, and corrupt files must not retry forever. After two transcription
failures, or a transcript whose confidence or word density falls below threshold, mark the episode
`.notTranscribable` with a reason, stop retrying, and surface a one-line explanation on the episode
row. Playback continues normally without detection.

### 9.9 Transcription implementation

```swift
guard SpeechTranscriber.isAvailable else { /* fall back to DictationTranscriber */ }
guard let locale = SpeechTranscriber.supportedLocale(equivalentTo: .current) else { … }

let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)

if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()   // surface progress
}
```

- **Request the `audioTimeRange` attribute explicitly.** The default `.transcription` preset returns
  an `AttributedString` without reliable timing, and this entire app depends on millisecond
  timings. Use a time-indexed preset and verify the attribute is present.
- Use `analyzeSequence(from:)` with an `AVAudioFile`.
- Model assets are downloaded, not bundled. Handle the not-yet-available state gracefully on first
  run with clear progress. Handled badly, this is the worst possible first-run experience.
- **Persist transcripts. Never re-transcribe an episode.**

---

## 10. Playback features

Overcast-class table stakes. These are why someone uses Codex Cast daily; ad detection is why they
chose it. **These land in Phase 1**, not late — they are independent of detection and they make
the app a usable daily driver immediately.

### 10.1 Voice Boost

**OPEN — awaiting reference documentation from the author. Replace this section wholesale when it
arrives.**

Interim specification: voice boost is not a volume increase. It is a dynamics chain raising
intelligibility of speech recorded at inconsistent levels — two co-hosts on wildly different
microphones, or a phone-in guest.

`AVAudioEngine` chain on the playback path:

1. **High-pass** ~80Hz to remove rumble and handling noise
2. **Parametric EQ** — presence lift around 2–4kHz where consonant intelligibility lives, gentle
   cut around 200–400Hz to reduce muddiness (`AVAudioUnitEQ`)
3. **Compression** — moderate ratio, fast attack, to level inter-speaker differences
4. **Makeup gain with limiting** to prevent clipping

Expose as Off / Low / High, not DSP sliders. Per-show with a global default.

### 10.2 Smart speed / silence trimming

Shorten silences dynamically without pitch artifacts. Distinct from ad skipping, independently
toggleable. Share the RMS VAD implementation with §5.4. Report time saved, cumulatively and per
episode — it is a satisfying number.

### 10.3 Variable speed

0.5×–3× via `AVAudioUnitTimePitch` for pitch-corrected playback. Per-show default with per-episode
override, in 0.05 increments.

### 10.4 Everything else

- Sleep timer, including "end of episode" and shake-to-extend
- Configurable skip forward/back intervals, independently set
- Mono downmix for single-earbud listening
- Volume normalization across episodes
- Per-show playback settings inheriting from global defaults, using the same three-state pattern as
  §9.2

### 10.5 System integration

- `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` with **accurate elapsed time when segments
  have been skipped** (§11.4)
- **CarPlay** — competing apps get dinged for skip behavior failing from car controls; verify
  explicitly
- Lock screen, Control Center, Live Activity, Home Screen widgets
- **App Intents / Siri**: play show, skip ad, and — most valuable — *mark that as an ad*.
  Correcting a missed ad hands-free while driving is the highest-friction moment in the entire
  correction loop.

---

## 11. Playback and skip behavior

### 11.1 Mechanics

`AVPlayer` with `addBoundaryTimeObserver` at each skip-block start. On trigger, seek to block end.
Do not poll a timer.

Use `seek(to:toleranceBefore:.zero, toleranceAfter:.zero)`. A tolerant seek lands mid-ad or clips
content.

Identical for audio and video renditions.

### 11.2 UX around a skip

- Brief, non-modal indicator: "Skipped 2 ads · 68s" with an **Undo** affordance persisting 8
  seconds.
- Undo seeks back to block start, marks the constituent segments `.rejected`, routes corrections
  per §6.4. **This is the single most important correction entry point** — one tap, at exactly the
  moment the user noticed.
- Never skip while the user is actively scrubbing.
- Skipped blocks render as distinct regions on the progress bar, tappable to review or play through.

### 11.3 Timeline review UI

Full-width timeline showing chapters and detected segments together:

- Segments colored by kind, opacity by confidence; chapters as markers
- Long-press-and-drag to create a segment (the "mark missed ad" flow)
- Drag edges to adjust boundaries
- Tap for a sheet: rationale, provenance, sponsor, and the six correction actions

This is where the app's thesis is either legible or invisible. **Design it first**, on paper, before
implementing. It is the one place custom drawing is sanctioned, which means explicit VoiceOver
support including an accessible representation of segment positions and a non-gestural path to
every correction action.

### 11.4 Elapsed-time correctness

With segments skipped, reported position and duration must stay coherent. Competing apps have
well-documented bugs here — episodes reporting complete while still playing, scrubbing landing in
dead zones. **True media time is the source of truth**; compute a display timeline excluding
skipped regions. Never let two representations drift.

---

## 12. Screens

| Screen | Contents |
|---|---|
| Library | Subscribed shows, unplayed counts |
| Show detail | Episodes, setup card (§9.6), per-show settings: pipeline, skip policy, threshold, playback, notifications, rendition preference, position rules, notes |
| Episode detail | Description, transcript, chapters, detected segments |
| Player | Artwork or video, transport, speed, voice boost, timeline (§11.3) |
| Queue | Reorderable Up Next |
| Discover | iTunes Search, top charts, add-by-URL, OPML import |
| Review | Cross-episode inbox of unreviewed segments and pending suggestions. **Optional — never nag.** |
| Sponsors | Browsable registry (§6.2) |
| Patterns | Learned patterns with confirm/FP counts, manual delete |
| Storage | Per-show usage, bulk delete — matters much more with video |
| Settings | Global pipeline defaults, thresholds, playback, notifications, implicit-learning toggle, export/import, diagnostics |

### 12.1 Privacy copy

State plainly in onboarding and Settings: **everything happens on this device.** Transcription is
on-device. Ad detection is on-device. No account, no server, no API key, no telemetry. Audio,
video, and transcripts never leave the phone. Feeds and media are downloaded from the podcast hosts
themselves, exactly as any podcast app does.

If the §7.6 escape hatch is enabled for a show, this copy **MUST** change automatically and visibly.

---

## 13. Evaluation harness

**Build in Phase 1.** Without it, every change to instructions or confidence math is a guess — and
with an on-device model Apple updates silently, drift detection is not optional.

- **Labeled corpus: 10 episodes across 5 shows**, hand-labeled ground-truth ad boundaries, stored
  as JSON fixtures with their transcripts. (Created in Phase 0, §14.)
- Test target running the full pipeline against fixtures with `StubClassifier`, reporting
  precision, recall, F1, and boundary error in milliseconds.
- Separate manually-invoked integration test against the real on-device model, reporting the same
  metrics plus wall-clock and thermal state, and **recording which model tier ran** (§7.2).
- **Regression gate:** F1 must not decrease on the fixture set. A change that improves one show and
  breaks two is a regression, and without this it is invisible.
- **Drift canary:** re-run the on-device integration test after every iOS point release and record
  results over time. Apple updates the model; the app must notice.

Expectation-setting: a comparable self-hosted project benchmarked 32 *cloud* models over a
7-episode corpus and saw F1 from 0.00 to 0.65. A small on-device model will not lead that pack. The
learning layer carries the product; the harness exists to prove it does.

---

## 14. Phase 0 — Audio signal spike

**Timebox: one week. Runs first. Produces a written finding and a labeled corpus — not production
code.**

### 14.1 Rationale

The transcript discards nearly everything that makes an ad obvious to a human ear: a different
voice, a music bed under the read, stingers on either side, and mastering that is typically louder
and more compressed than surrounding conversation. AFM 3 Core Advanced accepts audio input, which
makes this cheap to test.

### 14.2 Deliverable 1 — the labeled corpus

**Build the §13 corpus here**, since every arm needs it: 10 episodes across 5 shows, hand-labeled
ad boundaries, committed as JSON fixtures with transcripts. This is a Phase 0 output, not a
Phase 1 one — Phase 1's harness consumes it.

### 14.3 Deliverable 2 — four-arm comparison

All arms run against the same corpus with the same metrics. **Arms are throwaway scripts, not
production pipeline code** — the production pipeline does not exist yet.

1. **Transcript-only baseline** — a minimal script implementing §5.3's prompt and windowing.
   Establishes the number to beat.
2. **Audio-only** — feed AFM 3 short audio windows (start at 30s; find the practical ceiling) and
   ask it to flag ad content.
3. **Fused** — transcript window plus matching audio clip in one prompt.
4. **Classical audio features, no LLM** — short-term loudness (LUFS) deltas, spectral flux at
   candidate boundaries, and `SoundAnalysis`'s speech-vs-music classifier.

**Arm 4 matters most for the decision. If a loudness jump plus music-bed detection delivers most of
the lift at a thousandth of the compute, that is the answer** and the LLM never touches audio.

### 14.4 Required reporting

- **Practical audio duration limit per prompt.** Unknown, and it determines whether arms 2–3 are
  viable at all.
- **Latency and thermal cost per arm.** If fused is 4% better and 10× slower, it loses.
- **Where the lift lands.** Hypothesis: audio helps most with *boundary precision* and
  *confirmation* rather than primary detection — snapping to the exact sting, and disambiguating
  "host genuinely likes this product" from "host is reading copy." That is a far cheaper
  integration, and it slots into Stage 3 rather than Stage 2.

### 14.5 Pass criterion

Audio earns a place only if fused beats transcript-only by **≥0.05 F1** or materially reduces
boundary error, at acceptable battery and thermal cost. Otherwise document as tried, shelve it, and
proceed transcript-only. Whatever survives lands in Stage 3 as an `AcousticSignal` provenance.

---

## 15. Phased delivery

Each phase must be shippable and independently useful. Do not begin a phase until the prior phase's
acceptance criteria pass.

### Phase 0 — Audio spike and corpus
Per §14. One week, timeboxed.

*Acceptance:* labeled corpus committed. Decision document with the four-arm comparison and a
go/no-go on acoustic signals.

### Phase 1 — Player and evidence
iTunes Search discovery, RSS + Podcasting 2.0 parsing including renditions, subscriptions,
downloads, queue, on-device transcription, transcript display. **Full playback feature set (§10):
voice boost, smart speed, variable speed, sleep timer.** Pipeline settings model (§9) with
inheritance, triggers, dependencies, notifications, setup cards. Evaluation harness consuming the
Phase 0 corpus. **No ad detection.**

*Acceptance:* subscribe to 5 feeds via search and by URL, download, play, view an accurate
timestamped transcript. OPML import works. Playback features functional. Pipeline settings
demonstrably control what runs. Harness runs and reports zeros. **The app is a usable daily-driver
podcast player at the end of this phase**, minus its differentiating feature.

### Phase 2 — Detection and skipping
Stages 2 and 3. Chunk merging. Validation gate. Skip with undo. Timeline UI. Availability and
thermal handling. Chapter generation (§5.8). Inference logging.

*Acceptance:* F1 ≥ 0.55 on the fixture corpus with the on-device model. Boundaries acceptable in
manual listening (chapter-marker precision, not surgical). Elapsed time coherent across skips.
Stacked ad breaks skip as one block. A 60-minute episode classifies in under ~5 minutes of device
time without reaching `.serious` thermal state.

### Phase 3 — The learning layer
All six explicit correction actions. Pattern extraction, FTS5, fuzzy and semantic tiers. Sponsor
registry. Position rules with Welford stats. Negative exemplars. Calibration with the
agreement-derived fallback. Stages 0 and 1 wired ahead of Stage 2. Implicit signals (§6.8) and
suggestions. Background sweep. Sponsors and Patterns screens. Export/import.

*Acceptance* — directional rather than statistical, because this is a personal daily driver and the
system is designed to converge in perpetuity rather than hit a benchmark:

- Over four weeks of real listening across ≥5 subscribed shows, the fraction of transcript reaching
  Stage 2 **drops by ≥50%**.
- The rate of explicit "not an ad" corrections **trends down** week over week.
- On the fixture corpus, replaying the user's accumulated corrections improves F1 measurably over
  Phase 2. Exact threshold not specified; the trend is what matters.
- At least one sponsor learned on one show is caught on a **different** show without further
  correction. This is the single most convincing demonstration that the design works.

### Phase 4 — Video and depth
Video playback (`AVPlayerViewController`, PiP, rendition switching, audio-only toggle). Storage
management at video scale. CarPlay, widgets, Live Activity, App Intents/Siri including hands-free
ad marking. Whatever Phase 0 sanctioned. Any-provider seam (§7.6).

*Acceptance:* daily-driver quality. Author has not opened another podcast app in two weeks.

---

## 16. Legal and ethical posture

Include in the README and reflect in the product:

- Codex Cast skips during playback and never alters or redistributes media. The downloaded file is
  unmodified. This is closer to a chapter skip than an edit.
- Episodes download normally, so shows still receive their download statistics.
- Skipping is always optional and overridable; any segment can be played through.
- **Sponsor cards, not just skips:** when a sponsor segment is detected, surface brand, promo code,
  and offer as a tappable card. Someone who wants to support a show can act on an offer without
  listening to sixty seconds of copy. A better answer to the creator-revenue objection than a
  disclaimer, and nearly free — the model already extracts the sponsor.
- The learning database is local and personal. No telemetry, of any kind, ever.

---

## 17. Deferred questions

Parked by agreement; revisit during implementation.

1. **`kind` granularity.** Are five kinds right? Does "intro" (theme music, cold open) belong in
   skipping at all, or in a separate trim feature alongside silence skipping?
2. **Review inbox.** Genuinely wanted, or is in-flow correction the only path anyone will use?
3. **Sponsor cards.** Full feature with promo-code extraction and tap-through, or a minimal
   "detected sponsor: X" line?
4. **Transcript export to Obsidian.** The author maintains a vault; searchable podcast transcripts
   in it is a real feature and cheap to add.

---

## Appendix A — Reference implementations

- `ttlequals0/MinusPod` — closest existing system: Whisper → LLM → pattern learning from user
  corrections, three-stage detection, published multi-model benchmark. Server-side and
  audio-cutting rather than on-device and skipping, but the learning-layer design is directly
  relevant.
- `jdrbc/podly_pure_podcasts` — simpler, single-provider, minimal reference.
- `jdcb4/podcast-ad-remover` — intro/outro detection and per-podcast feed handling.
- **SponsorBlock** — the closest conceptual analogue. Same product shape, crowdsourced instead of
  personal. Worth studying for UX around skip indication and undo.

## Appendix B — Key API references

- **Foundation Models:** WWDC26 session 241; WWDC25 sessions 286 and 301 for the base framework and
  guided generation
- **Context window management:** Apple TN3193 — **required reading before implementing §5.3.2**
- **SpeechAnalyzer:** WWDC25 session 277
- **AFM 3 model family:** Apple Machine Learning Research, "Introducing the Third Generation of
  Apple's Foundation Models"
- **Any-provider protocol:** WWDC26 session 339
- **Podcast namespace:** https://podcastindex.org/namespace/1.0
- **alternateEnclosure tag:** https://podcasting2.org/docs/podcast-namespace/tags/alternate-enclosure
- **HLS video in alternateEnclosure:** https://github.com/Podcast-Standards-Project/hls-video
- **iTunes Search API:** Apple's Search API documentation
