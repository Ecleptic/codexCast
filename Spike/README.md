# Phase 0 — Audio signal spike

Timeboxed to one week. **Throwaway by design**: nothing in this directory
graduates into the app. Only two things survive Phase 0 — the labeled corpus and
the written finding.

## Deliverable 1 — the labeled corpus

10 episodes across 5 shows, hand-labeled, committed to `Fixtures/corpus/`.
Phase 1's evaluation harness consumes this, so it gates that work.

### Labeling

Open `labeler.html` in a browser. No build step, no server.

1. **Audio…** — pick the downloaded episode file
2. **Transcript…** — pick a `.vtt`, `.srt`, or `.json` transcript, if the feed
   ships one
3. Fill in the show name and episode title
4. Label, then **Export JSON** into `Fixtures/corpus/<show>/`

| Key | Action |
|---|---|
| `space` | play / pause |
| `←` `→` | ±5 seconds |
| `shift` + `←` `→` | ±30 seconds |
| `i` | mark segment start |
| `o` | mark segment end |
| `1`–`5` | set the kind of the most recent segment |
| `z` | undo the last segment |
| `-` `=` | playback speed |

Clicking a transcript line seeks to it. That is the fast path: ads are found by
reading, not by listening to a whole episode.

### Choosing episodes

Three of the five shows should ship transcripts, so no transcription pass is
needed before labeling can start:

- LINUX Unplugged — `https://feeds.fireside.fm/linuxunplugged/rss`
- The Changelog — `https://changelog.com/podcast/feed`
- Podnews Daily — `https://podnews.net/rss`

The remaining two are the shows the system actually has to get right:

- Tech Brew Ride Home — `https://feeds.megaphone.fm/ridehome`
- The Nextlander Podcast — `https://audioboom.com/channels/5116059.rss`

Neither ships a transcript, so those episodes need transcribing before the text
column is available. They are still worth labeling: they are the daily listening
the app is being built for.

### Corpus format

```jsonc
{
  "show": "LINUX Unplugged",
  "episodeTitle": "679: The Last Shutdown",
  "audioFileName": "lup-0679.mp3",
  "durationMs": 3925000,
  "labeledAt": "2026-08-13",
  "segments": [
    { "startMs": 61200, "endMs": 118400, "kind": "sponsorRead", "sponsor": "Tailscale" }
  ],
  "transcript": {
    "source": "podcasting20",
    "segments": [
      { "startMs": 31752, "endMs": 35961, "text": "Why not make it…", "speaker": "Chris" }
    ]
  }
}
```

`kind` uses the same vocabulary as `SegmentKind` in `CodexCastCore`: `ad`,
`sponsorRead`, `selfPromo`, `intro`, `outro`. Ground truth has to speak the same
language as the app or the harness compares apples to oranges.

**Media files are gitignored.** The repo is public and episode audio is
copyrighted; only the labels and transcripts are committed.

## Deliverable 2 — the four-arm comparison

Not yet built. Runs as an on-device XCTest target rather than a Mac CLI: this
machine's toolchain targets macOS 26, so benchmarking Foundation Models here
would measure the previous-generation model — exactly what the iOS 27 floor
exists to avoid. Running on device also produces the latency and thermal numbers
§14.4 asks for.

Arms, per §14.3:

1. Transcript-only baseline — the number to beat
2. Audio-only — AFM 3 over short audio windows
3. Fused — transcript window plus the matching audio clip
4. Classical audio features, no LLM — loudness deltas, spectral flux,
   `SoundAnalysis` speech-versus-music

**Arm 4 matters most.** If a loudness jump plus music-bed detection delivers most
of the lift at a thousandth of the compute, that is the answer, and the LLM never
touches audio.

## Deliverable 3 — the finding

`FINDINGS.md`: the four-arm table, the practical audio-duration-per-prompt limit,
where the lift lands, and an explicit go/no-go against §14.5's bar — audio earns
a place only if fused beats transcript-only by ≥0.05 F1 or materially reduces
boundary error, at acceptable battery and thermal cost.

Otherwise: document as tried, shelve it, proceed transcript-only.
