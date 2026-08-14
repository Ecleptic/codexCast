#!/usr/bin/env python3
"""Download the latest N episodes (audio + transcript where available) from
each test feed into Spike/media/<show>/, ready for the labeler.

Media is gitignored: the repo is public and episode audio is copyrighted.
"""

import os
import re
import subprocess
import sys

FEEDS = {
    "ridehome": "https://feeds.megaphone.fm/ridehome",
    "nextlander": "https://audioboom.com/channels/5116059.rss",
    "linuxunplugged": "https://feeds.fireside.fm/linuxunplugged/rss",
    "pc20": "https://mp3s.nashownotes.com/pc20rss.xml",
    "podnews": "https://podnews.net/rss",
    "changelog": "https://changelog.com/podcast/feed",
    "coderradio": "https://feeds.fireside.fm/coder/rss",
    "podnewsweekly": "https://feeds.buzzsprout.com/1538779.rss",
}

EPISODES_PER_FEED = 2
MEDIA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "media")


def curl(url, dest):
    """Download url to dest, skipping if it already exists and is non-empty."""
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print(f"    exists  {os.path.basename(dest)}")
        return True
    result = subprocess.run(
        ["curl", "-sL", "--max-time", "600", "-A", "CodexCast/0.1", url, "-o", dest],
        check=False,
    )
    ok = result.returncode == 0 and os.path.exists(dest) and os.path.getsize(dest) > 0
    size = os.path.getsize(dest) if os.path.exists(dest) else 0
    print(f"    {'ok' if ok else 'FAIL':6}  {os.path.basename(dest)}  {size/1e6:.1f}MB")
    return ok


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:60]


def first(pattern, text, group=1):
    match = re.search(pattern, text, re.S)
    return match.group(group) if match else None


def parse_items(xml):
    """Latest items with title, enclosure, and transcript URL (VTT preferred)."""
    items = []
    for block in re.findall(r"<item>.*?</item>", xml, re.S):
        title = first(r"<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>", block)
        enclosure = first(r'<enclosure[^>]*url="([^"]+)"', block)
        if not title or not enclosure:
            continue

        # Prefer VTT (keeps speaker names), then SRT, then JSON.
        transcripts = re.findall(r'<podcast:transcript[^>]*url="([^"]+)"[^>]*type="([^"]+)"', block)
        transcripts += re.findall(r'<podcast:transcript[^>]*type="([^"]+)"[^>]*url="([^"]+)"', block)
        transcript = None
        for want in ("vtt", "srt", "json"):
            for a, b in transcripts:
                url, mime = (a, b) if a.startswith("http") else (b, a)
                if want in mime.lower() or url.lower().endswith("." + want):
                    transcript = (url, want)
                    break
            if transcript:
                break

        items.append({"title": title.strip(), "enclosure": enclosure, "transcript": transcript})
        if len(items) >= EPISODES_PER_FEED:
            break
    return items


def main():
    os.makedirs(MEDIA_DIR, exist_ok=True)
    failures = []

    for show, feed_url in FEEDS.items():
        print(f"\n== {show}")
        show_dir = os.path.join(MEDIA_DIR, show)
        os.makedirs(show_dir, exist_ok=True)

        feed_path = os.path.join(show_dir, "_feed.xml")
        if not curl(feed_url, feed_path):
            failures.append(f"{show}: feed fetch failed")
            continue
        xml = open(feed_path, encoding="utf-8", errors="replace").read()

        for index, item in enumerate(parse_items(xml), 1):
            slug = f"{index:02d}-{slugify(item['title'])}"
            print(f"  [{index}] {item['title'][:70]}")

            ext = os.path.splitext(item["enclosure"].split("?")[0])[1] or ".mp3"
            if not curl(item["enclosure"], os.path.join(show_dir, slug + ext)):
                failures.append(f"{show}/{slug}: audio failed")

            if item["transcript"]:
                url, kind = item["transcript"]
                if not curl(url, os.path.join(show_dir, slug + "." + kind)):
                    failures.append(f"{show}/{slug}: transcript failed")
            else:
                print("    no transcript in feed (will transcribe locally)")

    print("\n== done")
    if failures:
        print("FAILURES:")
        for failure in failures:
            print(" -", failure)
        sys.exit(1)


if __name__ == "__main__":
    main()
