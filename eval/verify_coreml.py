"""Checks that a model converted to WhisperKit Core ML still transcribes like the original.

Downloads the release the way the iPhone app does (manifest + flat assets), runs the
Core ML model through WhisperKit's CLI and the original PyTorch model through
transformers on the same Egyptian Arabic clips, and compares character error rates.

    python eval/verify_coreml.py --release egyptian-arabic-v1 --cli path/to/argmax-cli
"""

import argparse
import json
import os
import random
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
from score_models import DATASET, char_errors, normalize  # noqa: E402

REPO = "MohamedMostafaSal/meeting-harness"


def download_release(tag, folder):
    base = f"https://github.com/{REPO}/releases/download/{tag}/"
    manifest = json.load(urllib.request.urlopen(base + "manifest.json"))
    for f in manifest["files"]:
        path = os.path.join(folder, f["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        urllib.request.urlretrieve(base + f["asset"], path)
        assert os.path.getsize(path) == f["bytes"], f"size mismatch for {f['path']}"
    print(f"downloaded {len(manifest['files'])} files of {manifest['model']}")
    return manifest["model"]


def clips(n, seed, out):
    import soundfile as sf
    from datasets import Audio, load_dataset

    ds = load_dataset(DATASET, split="train").cast_column("audio", Audio(sampling_rate=16000))
    text_column = "sentence" if "sentence" in ds.column_names else [c for c in ds.column_names if c != "audio"][0]
    print(f"columns {ds.column_names}, text from '{text_column}'")
    order = list(range(len(ds)))
    random.Random(seed).shuffle(order)
    picked = []
    for i in order:
        row = ds[i]
        audio, text = row["audio"]["array"], (row[text_column] or "").strip()
        if not text or not 2 <= len(audio) / 16000 <= 28:
            continue
        path = os.path.join(out, f"clip{len(picked):02d}.wav")
        sf.write(path, audio, 16000)
        picked.append({"path": path, "text": text, "audio": audio.astype("float32")})
        if len(picked) == n:
            return picked
    return picked


# Decoding setups to compare. "app" is exactly what the iPhone app's WhisperRecognizer
# uses: whole utterances (no VAD chunking), forced language, 3 temperature fallbacks.
SETUPS = {
    "app": ["--chunking-strategy", "none", "--temperature-fallback-count", "3"],
    "greedy": ["--chunking-strategy", "none", "--temperature-fallback-count", "0"],
    "cli default (VAD chunks)": [],
}


def coreml(cli, model_dir, clip, report_dir, extra):
    os.makedirs(report_dir, exist_ok=True)
    cmd = [cli, "transcribe", "--model-path", model_dir, "--audio-path", clip["path"], "--language", "ar",
           "--task", "transcribe", "--use-prefill-prompt", "--skip-special-tokens", "--without-timestamps",
           "--report", "--report-path", report_dir, *extra]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    name = os.path.splitext(os.path.basename(clip["path"]))[0]
    return json.load(open(os.path.join(report_dir, name + ".json")))["text"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", default="egyptian-arabic-v1")
    parser.add_argument("--cli", required=True)
    parser.add_argument("--clips", type=int, default=12)
    parser.add_argument("--seed", type=int, default=3)
    args = parser.parse_args()

    work = tempfile.mkdtemp()
    model_dir = os.path.join(work, "model")
    model_id = download_release(args.release, model_dir)
    samples = clips(args.clips, args.seed, work)
    print(f"{len(samples)} clips")

    import torch
    from transformers import pipeline
    torch_asr = pipeline("automatic-speech-recognition", model=model_id, device="cpu")

    keys = [*SETUPS, "pytorch"]
    totals = {k: [0, 0] for k in keys}
    rows = []
    for k, clip in enumerate(samples):
        texts = {name: coreml(args.cli, model_dir, clip, os.path.join(work, f"report{i}"), extra)
                 for i, (name, extra) in enumerate(SETUPS.items())}
        texts["pytorch"] = torch_asr({"raw": clip["audio"], "sampling_rate": 16000},
                                     generate_kwargs={"language": "arabic", "task": "transcribe"})["text"]
        row = {"clip": k + 1, "seconds": len(clip["audio"]) / 16000, "reference": clip["text"], "text": texts, "cer": {}}
        for key, text in texts.items():
            e, n = char_errors(clip["text"], text)
            totals[key][0] += e
            totals[key][1] += n
            row["cer"][key] = e / max(1, n)
        rows.append(row)

    cer = {k: e / max(1, n) for k, (e, n) in totals.items()}
    # Per clip, so one bad clip (a repetition loop, a cut-off ending) stands out from a general drift.
    per_clip = ["| Clip | Seconds | " + " | ".join(keys) + " |", "|---|---|" + "---|" * len(keys)]
    per_clip += [f"| {r['clip']} | {r['seconds']:.1f} | " + " | ".join(f"{r['cer'][k] * 100:.1f}%" for k in keys) + " |" for r in rows]
    lines = []
    for r in sorted(rows, key=lambda r: r["cer"]["pytorch"] - r["cer"]["app"])[:3]:
        lines += [f"**Clip {r['clip']}** (app setup {r['cer']['app'] * 100:.0f}%, PyTorch {r['cer']['pytorch'] * 100:.0f}%)",
                  f"- Reference: {r['reference']}", f"- Core ML, app setup: {r['text']['app']}", f"- PyTorch: {r['text']['pytorch']}", ""]
    summary = [
        f"# Core ML conversion check: `{model_id}`", "",
        f"{len(samples)} Egyptian Arabic clips from {DATASET} (train split, used only to compare formats and decoding setups).", "",
        "| Setup | CER |", "|---|---|",
        *[f"| {'Core ML, ' + k if k != 'pytorch' else 'PyTorch (original)'} | {cer[k] * 100:.1f}% |" for k in keys], "",
        "## Per clip", "", *per_clip, "",
        "## Where the app setup differs most from PyTorch", "", *lines,
    ]
    text = "\n".join(summary)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(text + "\n")
    os.makedirs("eval/results", exist_ok=True)
    open("eval/results/coreml-check.md", "w").write(text + "\n")
    if cer["app"] > cer["pytorch"] + 0.05:
        sys.exit(f"Core ML with the app's setup is worse than PyTorch by {(cer['app'] - cer['pytorch']) * 100:.1f} points")


if __name__ == "__main__":
    main()
