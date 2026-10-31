"""Downloads a YouTube video's audio and captions as a test set.

Writes, into --out:
  audio.wav   16 kHz mono, the first --minutes of the video
  cues.json   [{"start", "end", "text"}] caption cues inside that span
  info.json   title, duration, which captions were used (uploaded or YouTube's automatic ones)

Uploaded captions are preferred: automatic ones are YouTube's own speech recognition,
so scoring against them measures agreement with another model, not accuracy.
Audio and captions stay on the machine that runs this; only scores get published.

    python eval/youtube_fetch.py URL --out yt --minutes 10
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.request

PREFERRED = ["ar", "en"]


def pick_captions(info):
    """Returns (source, language, url) for the best json3 caption track."""
    def json3(tracks):
        return next((t["url"] for t in tracks if t.get("ext") == "json3"), None)

    manual = info.get("subtitles") or {}
    for lang in [info.get("language"), *PREFERRED, *manual.keys()]:
        if lang and lang in manual and json3(manual[lang]):
            return "uploaded", lang, json3(manual[lang])
    auto = info.get("automatic_captions") or {}
    # Automatic captions list every translation too; the original is the video's language
    # (sometimes keyed "<lang>-orig").
    for lang in [info.get("language"), *PREFERRED]:
        for key in (f"{lang}-orig", lang):
            if lang and key in auto and json3(auto[key]):
                return "automatic", lang, json3(auto[key])
    return None, None, None


def cues_from_json3(data, limit):
    cues = []
    for event in data.get("events", []):
        segs = event.get("segs")
        if not segs:
            continue
        text = "".join(s.get("utf8", "") for s in segs).replace("\n", " ").strip()
        start = event.get("tStartMs", 0) / 1000
        end = start + event.get("dDurationMs", 0) / 1000
        if text and start < limit:
            cues.append({"start": round(start, 3), "end": round(min(end, limit), 3), "text": text})
    return cues


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--out", default="yt")
    parser.add_argument("--minutes", type=float, default=10)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    import yt_dlp

    with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True}) as ydl:
        info = ydl.extract_info(args.url, download=False)
    print(f"{info.get('title')} ({info.get('duration')} s, language {info.get('language')})")
    print(f"uploaded captions: {sorted((info.get('subtitles') or {}).keys())}")

    source, lang, url = pick_captions(info)
    if not url:
        sys.exit("This video has no Arabic or English captions to test against.")
    print(f"using {source} captions in '{lang}'")

    limit = args.minutes * 60
    data = json.load(urllib.request.urlopen(url))
    cues = cues_from_json3(data, limit)
    json.dump(cues, open(os.path.join(args.out, "cues.json"), "w"), ensure_ascii=False, indent=1)

    with yt_dlp.YoutubeDL({"quiet": True, "format": "bestaudio/best", "outtmpl": os.path.join(args.out, "source.%(ext)s")}) as ydl:
        downloaded = ydl.prepare_filename(ydl.extract_info(args.url, download=True))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", downloaded, "-t", str(limit),
                    "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", os.path.join(args.out, "audio.wav")], check=True)
    os.remove(downloaded)

    span = min(limit, info.get("duration") or limit)
    json.dump({"title": info.get("title"), "url": args.url, "duration": info.get("duration"), "seconds": span,
               "captions": source, "language": lang, "cues": len(cues)},
              open(os.path.join(args.out, "info.json"), "w"), ensure_ascii=False, indent=1)
    print(f"{len(cues)} caption cues in the first {span / 60:.1f} min")


if __name__ == "__main__":
    main()
