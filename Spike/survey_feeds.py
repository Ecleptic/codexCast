#!/usr/bin/env python3
"""Survey a real subscription list for two things the detection design cares
about:

1. How many shows publish <podcast:transcript> — i.e. how often the §8.2 "free
   transcript" fast path actually fires in a real library.
2. How many name their sponsors in the episode description or show notes — a
   free, no-transcription signal for who to look for (addendum A6).

Reads an OPML file; fetches a bounded prefix of each feed. Prints a summary and
writes per-feed detail to Spike/out/feed_survey.json (gitignored).

Usage: survey_feeds.py <opml-path> [max-feeds]
"""

import concurrent.futures
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Spike", "out")

# Phrases that indicate a description is naming sponsors, not merely mentioning
# a brand in passing. Deliberately conservative.
SPONSOR_PATTERNS = [
    r"sponsored by",
    r"brought to you by",
    r"our sponsors?:",
    r"this (?:week|episode)'?s? sponsors?",
    r"thanks to .{0,40} for sponsoring",
    r"sponsors?\s*:",
    r"member(?:ship)?s? support",
    r"支持",  # noise guard: non-English shows shouldn't match the above anyway
]
SPONSOR_RE = re.compile("|".join(SPONSOR_PATTERNS), re.I)

# Sponsor links very often carry a tracking path, which is a strong secondary
# signal and gives the brand name for free.
SPONSOR_LINK_RE = re.compile(
    r"https?://[^\s\"'<>]*(?:/(?:podcast|pod|atp|acast|sponsor)[^\s\"'<>]*)", re.I
)


def parse_opml(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    entries = []
    for match in re.finditer(r"<outline\b[^>]*>", text):
        tag = match.group(0)
        url = re.search(r'xmlUrl="([^"]+)"', tag)
        title = re.search(r'text="([^"]*)"', tag)
        if url:
            entries.append({
                "title": unescape(title.group(1)) if title else "?",
                "url": unescape(url.group(1)),
            })
    return entries


def unescape(value):
    for entity, char in [("&amp;", "&"), ("&apos;", "'"), ("&quot;", '"'),
                         ("&lt;", "<"), ("&gt;", ">")]:
        value = value.replace(entity, char)
    return value


def fetch(url, max_bytes=400_000):
    """Fetch a bounded prefix — enough for the channel head and early items."""
    try:
        result = subprocess.run(
            ["curl", "-sL", "--max-time", "35", "-A", "CodexCast/0.1", url],
            capture_output=True, timeout=45,
        )
        return result.stdout[:max_bytes].decode("utf-8", "replace")
    except Exception:
        return ""


def first_items(xml, count=3):
    return re.findall(r"<item>.*?</item>", xml, re.S)[:count]


def survey(entry):
    xml = fetch(entry["url"])
    if not xml:
        return {**entry, "ok": False}

    items = first_items(xml)
    blob = "\n".join(items)

    # Descriptions and show notes, where sponsors get named.
    descriptions = re.findall(
        r"<(?:description|itunes:summary|content:encoded)>(.*?)</(?:description|itunes:summary|content:encoded)>",
        blob, re.S,
    )
    description_text = " ".join(descriptions)

    return {
        **entry,
        "ok": True,
        "hasTranscriptTag": "podcast:transcript" in xml,
        "hasChapters": "podcast:chapters" in xml,
        "namesSponsors": bool(SPONSOR_RE.search(description_text)),
        "sponsorPhrase": (SPONSOR_RE.search(description_text) or [None])
                         and (SPONSOR_RE.search(description_text).group(0)
                              if SPONSOR_RE.search(description_text) else None),
        "descriptionChars": len(description_text),
        "itemsSeen": len(items),
    }


def main():
    opml = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    entries = parse_opml(opml)[:limit]
    print(f"surveying {len(entries)} feeds…\n")

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for index, result in enumerate(pool.map(survey, entries), 1):
            results.append(result)
            if index % 10 == 0:
                print(f"  {index}/{len(entries)}")

    reachable = [r for r in results if r.get("ok")]
    transcripts = [r for r in reachable if r.get("hasTranscriptTag")]
    chapters = [r for r in reachable if r.get("hasChapters")]
    sponsors = [r for r in reachable if r.get("namesSponsors")]

    print(f"\n{'='*60}")
    print(f"reachable feeds:            {len(reachable)}/{len(results)}")
    print(f"publish <podcast:transcript>: {len(transcripts)}  ({100*len(transcripts)/max(1,len(reachable)):.0f}%)")
    print(f"publish <podcast:chapters>:   {len(chapters)}  ({100*len(chapters)/max(1,len(reachable)):.0f}%)")
    print(f"name sponsors in description: {len(sponsors)}  ({100*len(sponsors)/max(1,len(reachable)):.0f}%)")

    if transcripts:
        print("\nshows with transcripts:")
        for r in transcripts:
            print(f"  - {r['title']}")

    print("\nshows naming sponsors in the description (first 20):")
    for r in sponsors[:20]:
        print(f"  - {r['title']}  [\"{r['sponsorPhrase']}\"]")

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "feed_survey.json")
    json.dump(results, open(path, "w"), indent=2)
    print(f"\ndetail written to {path}")


if __name__ == "__main__":
    main()
