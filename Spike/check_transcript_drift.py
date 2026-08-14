#!/usr/bin/env python3
"""Measure clock drift between a feed-supplied transcript and one made from the
actual downloaded audio.

If the feed transcript was made from an ad-free master and the audio has ads
stitched in, the feed timestamps run increasingly EARLY after each inserted ad.
This script finds matching sentences in both transcripts and prints the offset
(actual audio time minus feed time) across the episode.

Usage: check_transcript_drift.py <feed.vtt> <local.vtt>
"""

import re
import sys


def parse_vtt(path):
    cues = []
    text = open(path, encoding="utf-8", errors="replace").read().replace("\r", "")
    for block in text.split("\n\n"):
        lines = [l for l in block.split("\n") if l.strip()]
        timing = next((l for l in lines if "-->" in l), None)
        if not timing:
            continue
        start = to_ms(timing.split("-->")[0])
        if start is None:
            continue
        body = " ".join(lines[lines.index(timing) + 1:])
        body = re.sub(r"<[^>]+>", "", body).strip()
        if body:
            cues.append((start, body))
    return cues


def to_ms(raw):
    parts = raw.strip().replace(",", ".").split(":")
    try:
        parts = [float(p) for p in parts]
    except ValueError:
        return None
    if len(parts) == 3:
        return int((parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000)
    if len(parts) == 2:
        return int((parts[0] * 60 + parts[1]) * 1000)
    return None


def tokens(text):
    return set(re.findall(r"[a-z0-9']+", text.lower()))


def main():
    feed = parse_vtt(sys.argv[1])
    local = parse_vtt(sys.argv[2])
    local_tokens = [(start, tokens(body)) for start, body in local]

    # Sample distinctive feed cues (long ones) evenly through the episode.
    candidates = [(s, b) for s, b in feed if len(b) > 60]
    step = max(1, len(candidates) // 30)
    anchors = candidates[::step]

    print(f"feed cues: {len(feed)}   local cues: {len(local)}")
    print(f"{'feed time':>10}  {'audio time':>10}  {'offset':>8}   match confidence")

    for feed_start, body in anchors:
        want = tokens(body)
        if len(want) < 8:
            continue
        best_score, best_start = 0.0, None
        for local_start, have in local_tokens:
            union = want | have
            if not union:
                continue
            score = len(want & have) / len(union)
            if score > best_score:
                best_score, best_start = score, local_start
        if best_score >= 0.5 and best_start is not None:
            offset = (best_start - feed_start) / 1000
            print(f"{feed_start/1000:>9.1f}s {best_start/1000:>9.1f}s {offset:>+7.1f}s   {best_score:.2f}")
        else:
            print(f"{feed_start/1000:>9.1f}s {'—':>10}  {'—':>8}   no match ({best_score:.2f})")


if __name__ == "__main__":
    main()
