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
    order = list(range(len(ds)))
    random.Random(seed).shuffle(order)
    picked = []
    for i in order:
        row = ds[i]
        audio, text = row["audio"]["array"], (row.get("sentence") or "").strip()
        if not text or not 2 <= len(audio) / 16000 <= 28:
            continue
        path = os.path.join(out, f"clip{len(picked):02d}.wav")
        sf.write(path, audio, 16000)
        picked.append({"path": path, "text": text, "audio": audio.astype("float32")})
        if len(picked) == n:
            return picked
    return picked


def coreml(cli, model_dir, clip, report_dir):
    cmd = [cli, "transcribe", "--model-path", model_dir, "--audio-path", clip["path"], "--language", "ar",
           "--task", "transcribe", "--use-prefill-prompt", "--skip-special-tokens", "--without-timestamps",
           "--report", "--report-path", report_dir]
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

    totals = {"coreml": [0, 0], "pytorch": [0, 0]}
    lines = []
    for k, clip in enumerate(samples):
        ml = coreml(args.cli, model_dir, clip, work)
        pt = torch_asr({"raw": clip["audio"], "sampling_rate": 16000}, generate_kwargs={"language": "arabic", "task": "transcribe"})["text"]
        for key, text in (("coreml", ml), ("pytorch", pt)):
            e, n = char_errors(clip["text"], text)
            totals[key][0] += e
            totals[key][1] += n
        if k < 4:
            lines += [f"**Clip {k + 1}**", f"- Reference: {clip['text']}", f"- Core ML: {ml}", f"- PyTorch: {pt}", ""]

    cer = {k: e / max(1, n) for k, (e, n) in totals.items()}
    summary = [
        f"# Core ML conversion check: `{model_id}`", "",
        f"{len(samples)} Egyptian Arabic clips from {DATASET} (train split, used only to compare the two formats).", "",
        "| Format | CER |", "|---|---|",
        f"| Core ML (WhisperKit, as shipped to the app) | {cer['coreml'] * 100:.1f}% |",
        f"| PyTorch (original) | {cer['pytorch'] * 100:.1f}% |", "", "## Examples", "", *lines,
    ]
    text = "\n".join(summary)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(text + "\n")
    os.makedirs("eval/results", exist_ok=True)
    open("eval/results/coreml-check.md", "w").write(text + "\n")
    if cer["coreml"] > cer["pytorch"] + 0.05:
        sys.exit(f"Core ML is worse than PyTorch by {(cer['coreml'] - cer['pytorch']) * 100:.1f} points")


if __name__ == "__main__":
    main()
