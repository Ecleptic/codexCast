#!/usr/bin/env python3
"""Validate the hand-labeled boundary files and publish them as canonical
corpus fixtures under Fixtures/corpus/<show-slug>/<episode-slug>.json.

The labeler's export is already nearly the corpus format; this script is the
gate that catches mistakes before they poison evaluation:
- unknown segment kinds
- segments out of bounds or inverted
- missing or untimed transcripts
It also normalizes the transcript `source` field, which the labeler hardcodes.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS_DIR = os.path.join(ROOT, "Spike", "humanLabeled Boundaries")
CORPUS_DIR = os.path.join(ROOT, "Fixtures", "corpus")

VALID_KINDS = {"ad", "sponsorRead", "selfPromo", "intro", "outro"}

# Shows whose feed transcripts desync under dynamic ad insertion, or that have
# no usable feed transcript: their embedded transcripts came from on-device
# transcription of the actual audio.
ON_DEVICE_SHOWS = {"linux-unplugged", "tech-brew-ride-home", "coder-radio", "the-nextlander-podcast", "the-changelog"}


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def validate(doc, name):
    errors = []
    duration = doc.get("durationMs") or 0
    if duration <= 0:
        errors.append("missing durationMs")

    for i, segment in enumerate(doc.get("segments", [])):
        label = f"segment {i} ({segment.get('kind')})"
        if segment.get("kind") not in VALID_KINDS:
            errors.append(f"{label}: unknown kind")
        if not (0 <= segment["startMs"] < segment["endMs"] <= duration + 2000):
            errors.append(f"{label}: bounds {segment['startMs']}..{segment['endMs']} outside 0..{duration}")

    transcript = doc.get("transcript")
    if not transcript or not transcript.get("segments"):
        errors.append("no embedded transcript")
    else:
        cues = transcript["segments"]
        if any(c["endMs"] < c["startMs"] for c in cues):
            errors.append("transcript has inverted cue timings")
        if cues != sorted(cues, key=lambda c: c["startMs"]):
            errors.append("transcript cues not sorted")

    return errors


def main():
    files = sorted(
        f for f in os.listdir(LABELS_DIR) if f.endswith(".json")
    )
    if not files:
        print("no label files found")
        sys.exit(1)

    all_ok = True
    for name in files:
        doc = json.load(open(os.path.join(LABELS_DIR, name)))
        errors = validate(doc, name)
        if errors:
            all_ok = False
            print(f"INVALID {name}")
            for error in errors:
                print(f"   - {error}")
            continue

        show_slug = slugify(doc["show"])
        episode_slug = slugify(doc["episodeTitle"])
        if show_slug in ON_DEVICE_SHOWS:
            doc["transcript"]["source"] = "onDevice"

        out_dir = os.path.join(CORPUS_DIR, show_slug)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, episode_slug + ".json")
        json.dump(doc, open(out_path, "w"), indent=2)

        kinds = {}
        for segment in doc["segments"]:
            kinds[segment["kind"]] = kinds.get(segment["kind"], 0) + 1
        summary = ", ".join(f"{count} {kind}" for kind, count in sorted(kinds.items())) or "no segments"
        print(f"ok  {show_slug}/{episode_slug}.json  ({summary})")

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
