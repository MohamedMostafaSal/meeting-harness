"""Scores the iPhone app's Egyptian Arabic Core ML model on a YouTube test set made by
youtube_fetch.py, through WhisperKit's CLI with the app's decoding settings (forced Arabic,
non-speech tokens suppressed). The CLI cuts long audio at pauses, standing in for the
app's speaker turns; language routing isn't involved, so English speech is forced to Arabic.

    python eval/youtube_coreml.py yt --cli path/to/argmax-cli
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
from score_models import char_errors, word_errors  # noqa: E402
from verify_coreml import download_release  # noqa: E402


def suppress_tokens(model_id):
    url = f"https://huggingface.co/{model_id}/resolve/main/generation_config.json"
    return [str(t) for t in json.load(urllib.request.urlopen(url)).get("suppress_tokens") or []]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dir")
    parser.add_argument("--cli", required=True)
    parser.add_argument("--release", default="egyptian-arabic-v1")
    args = parser.parse_args()

    info = json.load(open(os.path.join(args.dir, "info.json"), encoding="utf-8"))
    cues = json.load(open(os.path.join(args.dir, "cues.json"), encoding="utf-8"))
    work = tempfile.mkdtemp()
    model_dir = os.path.join(work, "model")
    model_id = download_release(args.release, model_dir)

    report_dir = os.path.join(work, "report")
    cmd = [args.cli, "transcribe", "--model-path", model_dir, "--audio-path", os.path.join(args.dir, "audio.wav"),
           "--language", "ar", "--task", "transcribe", "--use-prefill-prompt", "--skip-special-tokens",
           "--temperature-fallback-count", "3", "--chunking-strategy", "vad",
           "--report", "--report-path", report_dir, "--suppress-tokens", *suppress_tokens(model_id)]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    result = json.load(open(os.path.join(report_dir, "audio.json"), encoding="utf-8"))
    segments = [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in result.get("segments", [])]
    hyp_all = result.get("text") or " ".join(s["text"] for s in segments)

    seconds = info["seconds"]
    ref_all = " ".join(c["text"] for c in cues if c["start"] < seconds)
    ce, cn = char_errors(ref_all, hyp_all)
    we, wn = word_errors(ref_all, hyp_all)

    rows = []
    for start in range(0, int(seconds), 60):
        end = min(seconds, start + 60)
        mid = lambda x: start <= (x["start"] + x["end"]) / 2 < end  # noqa: E731
        r = " ".join(c["text"] for c in cues if mid(c))
        h = " ".join(s["text"] for s in segments if mid(s))
        e, n = char_errors(r, h) if r else (0, 0)
        rows.append(f"| {start // 60:02d}:00 | {f'{e / n * 100:.0f}%' if n else '–'} | {len(r.split())} | {len(h.split())} |")

    lines = [
        f"## iPhone Egyptian Arabic model (`{model_id}`, Core ML, release `{args.release}`)", "",
        "| | |", "|---|---|",
        f"| Character error rate vs captions | **{ce / max(1, cn) * 100:.1f}%** |",
        f"| Word error rate vs captions | {we / max(1, wn) * 100:.1f}% |", "",
        "| Minute | CER | Caption words | Model words |", "|---|---|---|---|", *rows,
    ]
    text = "\n".join(lines) + "\n"
    print(text)
    open(os.path.join(args.dir, "score-coreml.md"), "w", encoding="utf-8").write(text)
    open(os.path.join(args.dir, "coreml.txt"), "w", encoding="utf-8").write(hyp_all + "\n")


if __name__ == "__main__":
    main()
