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

## Open, pending hardware

1. Arm 1 on an iOS 27 device with guided generation — the real baseline.
2. Arms 2 and 3 (audio-only, and transcript+audio fused), which need the
   device's model and answer §14.4's unknown: the practical audio duration per
   prompt.
3. Loudness-delta features to complete arm 4.
4. The §14.5 go/no-go: audio earns a place only if fused beats transcript-only
   by ≥0.05 F1 or materially reduces boundary error, at acceptable thermal cost.
