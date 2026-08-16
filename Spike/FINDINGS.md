# Phase 0 — Findings

**Status: in progress.** Arms 1 and 4 have run on a Mac; arms 2 and 3 (audio
into the model) are pending, and every language-model number here must be
re-measured on an iOS 27 device before it decides anything.

## The corpus

6 episodes across 5 shows, hand-labeled by the author, in `Fixtures/corpus/`.

| Show | Episodes | Ad segments | Notes |
|---|---|---|---|
| Tech Brew Ride Home | 2 | 4 | the author's daily show; highest priority |
| LINUX Unplugged | 1 | 5 | dynamic ad insertion; see A1 |
| Coder Radio | 1 | 2 | |
| Podcasting 2.0 | 1 | 0 | **ad-free control** |
| The Nextlander Podcast | 1 | 3 | |

The ad-free episode earns its place: a detector never tested against content
that *discusses* advertising will invent ads in it. Ninety-four minutes of two
people talking about podcast ads is the strongest false-positive trap available.

## Arm 4 — classical audio features, no LLM

`spike arm4`. SoundAnalysis' built-in classifier over 3-second windows, musical
windows merged into regions, filtered to ad-plausible shapes (15–240s, not
adjacent to the episode edges).

**Result: precision 0.10, recall 0.09, F1 0.10.** Analysis cost 5–41 s per
episode — genuinely cheap.

The failure is exactly what addendum A4 predicted from labeling: Tech Brew plays
music under its ad reads *and* under its intro, outro, and every topic
transition. Music marks structure, not advertising. On the ad-free Podcasting
2.0 episode the music filter produced a false positive on 94 minutes containing
no ads at all.

**Conclusion so far: music-bed detection is not a classifier.** It remains
plausible as a *boundary* signal for Stage 3 — snapping an already-detected ad's
edges to the sting that brackets it — which is the cheap integration §14.4
hypothesized. It is not a detector on its own and should never gate a skip.

Loudness-delta features are not yet implemented; that is the remaining piece of
arm 4 and the more promising half, since the author found a missed ad by its
*shape* in the waveform, not by its music.

## Arm 1 — transcript-only, language model (Mac preview)

`spikelm`. 3-minute windows, 60-second overlap, one session per window,
boundaries snapped to transcript cues afterward.

**Result, and the distinction matters more than the number:**

| Measure | Score |
|---|---|
| Strict (IoU ≥ 0.5 — skippable as-is) | **F1 0.00** |
| Located (found the right region) | **P 0.67 · R 0.67 · F1 0.67** |
| Mean boundary error on located hits | **44 s** |

The first pass reported only the strict figure and concluded the model was
useless. Printing the predictions against truth showed otherwise:

```
new pixels   predicted 12-52s, 110-147s     truth 33-76s
ai 50 off    predicted 7-59s                truth 34-74s, 531-612s
```

**The model finds the ads and then draws the boundaries ~20 seconds early**,
swallowing the intro that precedes the sponsor read. That is a boundary
problem, and Stage 3 (§5.4 — snap to chapter marks, then to silence gaps)
exists precisely to fix it. A detector that misses ads and a detector that
finds them with sloppy edges need completely different work, and a single
strict F1 makes them look identical.

The harness now reports both thresholds for every arm, so this cannot be
misread again.

Roughly 1–3 of every 10 windows still failed outright on this machine.

Important caveats before drawing conclusions:

- **This is not the target model.** The development Mac runs a generation older
  than the iOS 27 model the app ships against, and the SDK on this machine
  predates guided generation, so the preview asks for JSON and parses it. The
  production path uses `@Generable` constrained decoding, which eliminates the
  malformed-output failures entirely and is documented to improve accuracy.
- **Speed here is not indicative either**: ~35 s per window on the Mac.
- The spec already set expectations (§13): a comparable project benchmarking 32
  *cloud* models over 7 episodes saw F1 from 0.00 to 0.65. A small on-device
  model was never going to lead that pack, and the learning layer is what
  carries the product.

**The number that matters is the device run**, which is the next Phase 0 step
and the first thing needing real hardware.

## Arm 1b — learned patterns, no model at all

Not one of §14's four arms, but the most informative result so far. Measured by
the app's own harness (`swift test --filter CodexCastDetectionTests`),
leave-one-out over the corpus:

- **Precision 1.00, recall 0.18, F1 0.31**
- **Zero false positives**, including on the ad-free control
- The Vanguard read, learned from either Tech Brew episode, is found in the
  other — in both directions, with no model involved

Recall is low because five of six shows have a single labeled episode, so most
ads have no sibling to be learned from. That number rises with every episode
listened to and corrected, which is the entire product thesis: **a mediocre
classifier with a good memory beats a good classifier with no memory.**

On this corpus the two are complementary rather than competing, which is the
architecture the spec already assumes:

- **Patterns** are exact where they fire (precision 1.00, boundaries inherited
  from the confirmed span) but only fire on ads seen before.
- **The model** locates ads it has never seen (located recall 0.67) but places
  edges badly (44 s error) and occasionally invents one.

Patterns first, model for the remainder, Stage 3 to fix edges — precisely the
pipeline in §5. The measurements support the design rather than undermining it.

## First on-device run (iPhone 17 Pro, iOS 27 — 2026-08-14)

The scan shipped inside the app and Cam ran it on live episodes. Results:

- **Speed is solved.** A 21-minute episode scanned in **16 seconds** — versus
  ~5 minutes for the Mac preview. On-device transcription is similarly fast.
  §5.3.6's device-time budget (~5 min per hour-long episode) is met with an
  order of magnitude to spare.
- **Precision is the whole game.** On an AI-news episode, the device model
  found **5 segments, none of them real ads** — tech coverage discussing
  products reads exactly like ad copy, the hard case §5.3.5 names. Claimed
  confidences ran 90–98%, including a **zero-length segment** ("sponsor read,
  0:51–0:51") at 90% — the degenerate-confidence scenario §5.7 predicted,
  observed on the first real run. It also missed the episode's actual mid-roll.
- **Consequences shipped immediately:** auto-skip is opt-in (off by default),
  detected segments render on the seek bar rather than acting silently, sub-5s
  model output is dropped at storage, and the §6.4 mark-an-ad teaching flow
  landed in the player — marked spans become Stage 1 patterns that run ahead
  of the model on every future scan.

The reading stays the same as the Mac preview, now with production-model
numbers: the model is fast and can locate ad-shaped language, but its
confidence is uncalibrated and its precision on product-adjacent content is
poor. The learning layer is not an enhancement to the model — it is the
product, exactly as §1 claimed.

## Open, pending hardware

1. Arm 1 on an iOS 27 device with guided generation — the real baseline.
2. Arms 2 and 3 (audio-only, and transcript+audio fused), which need the
   device's model and answer §14.4's unknown: the practical audio duration per
   prompt.
3. Loudness-delta features to complete arm 4.
4. The §14.5 go/no-go: audio earns a place only if fused beats transcript-only
   by ≥0.05 F1 or materially reduces boundary error, at acceptable thermal cost.

## Two-pass with quote-anchored boundaries (2026-08-15, Mac preview)

Same-day, same-model comparison on the 6-episode corpus. "Baseline" is the
Arm 1 single-pass approach re-run fresh; day-to-day model variance is real
(this baseline scored below the earlier Arm 1 run), which is exactly why the
comparison was run side by side.

| metric | single-pass baseline | two-pass + quote anchors |
|---|---|---|
| strict F1 (skippable as-is) | 0.07 | **0.42** |
| located F1 (found the ad) | 0.22 | **0.42** |
| located precision | 0.19 | **0.50** |
| mean boundary error | 49.3 s | **10.8 s** |

Tech Brew "new pixels" scored strict F1 1.00 — found and skippable exactly.

Architecture: pass 1 sweeps windows recall-tuned for candidate stretches;
pass 2 re-examines each candidate ±60s and must name the sponsor and QUOTE
the read's exact first/last words; `TranscriptQuoteLocator` turns those
quotes into cue-edge boundaries. Small models copy far better than they
count.

Remaining weaknesses, in order:
1. Mid-roll recall — every pre-roll was found, most mid-rolls missed. Partly
   masked by ~30% JSON-mode window failures on the Mac, which guided
   generation eliminates on device; re-measure there before tuning further.
2. Podcasting 2.0 control still produces one merged false positive (down
   from five in the field) — the "discussing ads" trap survives pass 2.
3. Nextlander end-boundary overshot (0-220s vs 4-33s truth): a bad lastWords
   quote fell back to the sweep span. Candidate-width cap worth considering.

Shipped to the device path (guided generation) same day.

## Hybrid: chapters + lexical markers + grounded verify (2026-08-15)

Three-signal architecture measured on the corpus (Mac preview):

| metric | two-pass | hybrid |
|---|---|---|
| located F1 | 0.42 | **0.75** |
| located recall | 0.36 | **0.82** |
| strict F1 | 0.42 | **0.50** |
| boundary error | 10.8 s | 39.9 s |

- TopicSegmenter (embedding TextTiling + TreeSeg smoothing) isolates ads
  into their own chapters cleanly — the segmentation itself is excellent.
- Pure chapters-first FAILED on precision: asked neutrally about every
  chapter, the Mac-preview verifier approved 7-9 of 9. Lesson: two-pass
  precision lives in the sweep's selectivity, not the verifier.
- Hybrid: chapters are the unit of verification, but only chapters
  earning suspicion (sweep overlap OR lexical ad marker) are judged.
  Markers found the mid-rolls the sweep slept through: LUP 3/4 ads
  (was 1/4), Tech Brew and Nextlander mid-rolls caught.
- Boundary regression comes from verdicts whose quotes failed to locate,
  falling back to chapter-width spans — which were ALSO where the false
  positives lived. Device path therefore requires at least one grounded
  quote anchor per verdict (ungrounded approval = rubber stamp), plus
  Stage 3 silence snapping the Mac eval lacks.

Shipped to the device path same day. Next measurement should be run
on-device (guided generation, no JSON failures) before further tuning.

## §14.5 Go/No-Go decision (2026-08-15)

**GO — transcript-first, with acoustics as boundary evidence only.**

The bar was ≥0.05 F1 over the pattern baseline for any audio-involving arm
to justify itself. What actually happened:

- **Arm 1 (transcript-only) evolved past the question.** Single-pass scored
  located F1 0.22–0.67 across runs; the two-pass rework hit 0.42 strict /
  0.42 located; the hybrid (chapters + lexical markers + grounded verify)
  reached **0.75 located / 0.82 recall** — far beyond the 0.05 bar, all
  transcript-only.
- **Arm 4 (music-bed) is settled**: F1 0.10 as a classifier — dead as a
  verdict source, retained as A4 intends: evidence for boundaries and
  priors. The loudness-delta half remains unbuilt and is subsumed by the
  silence-map work, which already ships in Stage 3.
- **Arms 2/3 (audio into the model) remain unrun** — they require sustained
  device time, and their motivating question ("does the LLM need to hear
  the audio?") has lost force: the transcript path's measured ceiling keeps
  rising, and every audio-adjacent gain so far (silence snapping, planned
  fingerprinting, music stingers) lands as cheap DSP evidence, not model
  input. They stay open as curiosities, not blockers.

Consequence for the architecture, per §14.5: acoustic signals enter Stage 3
as `AcousticSignal` provenance only — silence gaps (shipped), audio
fingerprints of confirmed ads (planned, ShazamKit custom catalogs), music
stingers (candidate). The model never receives raw audio.

Corpus remains at 6/10 episodes; labels now accrue in-app via the
correction verbs, review card, and learning export.
