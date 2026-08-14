# Codex Cast — Spec Addenda

Decisions and features added after spec v2.1, recorded here rather than by
editing the original. Discovered during Phase 0 corpus work, 2026-08-14.

---

## A1. Feed transcripts cannot be trusted when ads are dynamically inserted

**The problem, found in the wild (LINUX Unplugged 678):** the show publishes a
transcript made from the ad-free master recording. The audio we download has
ads stitched in. Result: every timestamp in the transcript is correct until the
first inserted ad, then runs early by that ad's length, drifting further after
each additional ad. A "free" transcript that silently disagrees with the audio
is worse than no transcript, because everything downstream (labeling, ad
detection, tap-the-transcript navigation) trusts those timestamps.

**Measured (2026-08-14, `Spike/check_transcript_drift.py`):** matching the same
sentences in the feed transcript and a transcription of the actual audio, LUP
678's offset is ~0 for the first 23 minutes, jumps to **+90 s**, holds, then
jumps to **+183 s** around minute 43 — two inserted ~90-second ads, invisible
in the feed transcript. The human labeler missed the first insertion precisely
because the transcript being read contained no trace of it: the desync problem
demonstrably causes missed ads, not just misaligned text. The matching
technique itself (token-overlap between sampled sentences, offset per anchor)
worked cleanly and is a candidate implementation for the in-app check.

**What the app must do:**

1. **Detect the drift before trusting a feed transcript.** Cheap check:
   transcribe a few short samples of the actual audio (say 15 seconds at the
   25%, 50%, 75% marks) on-device and look for that text in the feed
   transcript. If it's found but at a noticeably different time, the transcript
   is desynced. If the sampled text isn't in the feed transcript at all, we're
   probably sitting inside an inserted ad — also a strong signal.
2. **If drift is detected, prefer our own transcription** of the file we
   actually have. Correct timestamps beat prettier text.
3. **Optionally re-sync instead of discarding:** the drift is piecewise — the
   transcript is right, then uniformly late, then later still. Matching a
   handful of anchor points gives the offsets, and the *gaps between anchors
   are themselves ad candidates* — the inserted material is exactly what the
   transcript doesn't contain. This turns a nuisance into a detection signal.
4. The spec's existing rule stands: detection always runs against the exact
   file on this device (§4.1). This addendum extends that principle to
   transcripts: *timestamps must come from, or be verified against, the actual
   downloaded audio.*

**Corpus consequence:** ground-truth labels made against a desynced feed
transcript are wrong. Labeling for shows with dynamic insertion must use the
locally-made transcript.

**Survey of the 8 test shows (2026-08-14):** all shows offering usable feed
transcripts were checked against transcriptions of the actual downloaded
audio. LINUX Unplugged desynced on both episodes checked (ep 679 was 21 s off
from the first second — an ad inserted before the content starts). Podcasting
2.0, Podnews Daily, and Podnews Weekly were in sync throughout. So roughly one
in four transcript-publishing shows in even this tiny sample needs the
verification path: it is not an edge case.

---

## A2. Per-show badges for what we detect

On the library and show screens, each podcast shows small badges summarizing
what kind of promotional content we've found in its episodes, e.g.:

- **Ads** — inserted/third-party advertising
- **Sponsor reads** — host-read sponsorships
- **Self-promo** — the show promoting its own products/events
- **Membership plugs** — generic term for "support us on …" segments
  (Patreon-style memberships, donations, boosts). Deliberately vague wording;
  never name a specific platform in the UI.

Badges are derived from confirmed/detected segment kinds per show, and give an
at-a-glance answer to "what does this app actually do for this show?"

Related idea from labeling Podcasting 2.0: some segments are worth *flagging
without skipping* — e.g. a listener-mail/donation-reading section that is
really part of the show. A future "flagged, not skipped" state would let the
timeline mark these so the listener can jump past them by choice, without the
app ever auto-skipping them. This may
add a `membershipPlug` kind (or fold into `selfPromo` with a sub-tag) — decide
when implementing; the existing `SegmentKind` enum was built to be extended.

---

## A3. In-app labeling, end-of-episode review, and bulk learning export

The author will run the app personally for a few weeks before sharing it.
During that period the app is also the labeling tool:

1. **Quick mark during playback** — mark an ad's start and end in one or two
   taps while listening, and drag-adjust boundaries on the player timeline,
   like the Phase 0 web labeler. (Extends §6.4 "Mark missed ad" and the §11.3
   timeline; the drag interaction from the labeler is the model.)
2. **End-of-episode feedback card** — when an episode finishes, show a short
   summary: "We found these ads … is this right?" / "We skipped these … look
   correct?" with one-tap confirm/reject per item. This is a batch version of
   the §11.2 undo affordance, catching corrections the listener didn't make in
   the moment.
3. **Bulk learning export** — one button that dumps everything the app has
   accumulated (segments, corrections, patterns, playback signals) as a single
   large file. The author feeds that to a frontier model (Opus/Fable) offline,
   which distills it — deduplicate patterns, name sponsors, propose position
   rules — and the distilled result ships back into the next app build as
   bundled starting knowledge. Extends §6.10 export; the import side must
   accept the distilled format, not just the raw dump.

None of this replaces on-device learning; it's a manual fast lane for the
author's own testing period.

---

## A4. Music beds are evidence, not verdicts (labeling observation)

From labeling Tech Brew Ride Home (the author's daily show, and the single
most important one for detection quality): the host plays music under his ad
reads — but the show also uses music for the intro, the outro, and topic
transitions. So "music under speech" separates *structure* from *content*, not
ads from content.

Consequences for the Phase 0 acoustic arm and for Stage 3:

- Treat music-bed detection as a **prior-raiser and boundary-finder**, never a
  classifier on its own. Music starting mid-episode marks *something* —
  transcript content decides what.
- The corpus labels intros and outros as their own kinds, so the eval can
  measure whether an acoustic signal confuses them with ads. A music-triggered
  detector that flags every Tech Brew transition would be worse than useless.

Also observed across both Tech Brew episodes: the first ad starts ~33 s in,
immediately after the intro, and is the same sponsor (Vanguard) with a similar
script. One show, two episodes, and already position rules (§6.3) and text
patterns (§5.2) would have caught the next episode's opening ad with no model
inference. The design's core bet, visible in the first four labeled episodes.
