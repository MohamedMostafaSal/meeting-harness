"""Scores speech-to-text models on Egyptian Arabic, to choose the Arabic specialist.

Every model transcribes the same clips; scoring uses the same Arabic-aware
normalization as the app (web/harness.js, Sources/HarnessCore/Evaluation), so
spelling variants (أ/ا, ة/ه, ى/ي, diacritics, tatweel, Arabic-Indic digits)
don't count as errors.

    python eval/score_models.py --limit 100 --models openai/whisper-base,openai/whisper-small
    python eval/score_models.py --self-test

Results go to --out (Markdown and JSON) and, in GitHub Actions, the job summary.
"""

import argparse
import json
import os
import random
import statistics
import sys
import time
import unicodedata

DATASET = "MightyStudent/Egyptian-ASR-MGB-3"

# Candidates: general Whisper (what the web prototype runs) and Egyptian fine-tunes.
# `trained_on_mgb3` marks a home-field advantage on this test set.
DEFAULT_MODELS = [
    "openai/whisper-base",
    "openai/whisper-small",
    "rahafvii/STT-EGY",
    "tawreck-hasaballah/whisper-small-eg",
    "xlpy/whisper-small-egyptian",
    "alexstokes/whisper-small-eg2",
    "MAdel121/whisper-medium-egy",
    "openai/whisper-large-v3-turbo",
]
TRAINED_ON_MGB3 = {"rahafvii/STT-EGY"}
# Share of clips reproduced exactly above which a score is treated as leaked test data.
LEAK_THRESHOLD = 0.3

# MARK: - Scoring (same rules as web/harness.js normalizeText)

FOLDS = {"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ة": "ه", "ى": "ي"}


def normalize(text):
    out = []
    for ch in text.lower():
        cp = ord(ch)
        if 0x064B <= cp <= 0x065F or cp in (0x0670, 0x0640):
            continue
        if ch in FOLDS:
            out.append(FOLDS[ch])
        elif 0x0660 <= cp <= 0x0669:
            out.append(str(cp - 0x0660))
        elif 0x06F0 <= cp <= 0x06F9:
            out.append(str(cp - 0x06F0))
        elif unicodedata.category(ch).startswith("P"):
            continue
        else:
            out.append(ch)
    return " ".join("".join(out).split())


def edit_distance(a, b):
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i] + [0] * len(b)
        for j in range(1, len(b) + 1):
            cur[j] = min(prev[j - 1] + (a[i - 1] != b[j - 1]), prev[j] + 1, cur[j - 1] + 1)
        prev = cur
    return prev[len(b)]


def word_errors(ref, hyp):
    r, h = normalize(ref).split(), normalize(hyp).split()
    return edit_distance(r, h), len(r)


def char_errors(ref, hyp):
    r, h = list(normalize(ref).replace(" ", "")), list(normalize(hyp).replace(" ", ""))
    return edit_distance(r, h), len(r)


def self_test():
    assert word_errors("أحمد في الجامعة", "احمد فِي الجامعـه")[0] == 0
    assert normalize("الساعة ٣ و٤٥") == normalize("الساعه 3 و45")
    assert char_errors("هنعمل الـ meeting بكرة", "هنعمل ال meting بكره")[0] == 1
    assert word_errors("Let's start the review.", "lets start review") == (1, 4)
    # The first real Egyptian test from the web prototype (Android, Whisper base).
    assert word_errors("حدوتة جديدة النهاردة مش بتاعتي", "ورده الحباتة جميلة النرضة مش بتعتي") == (5, 5)
    assert char_errors("حدوتة جديدة النهاردة مش بتاعتي", "ورده الحباتة جميلة النرضة مش بتعتي") == (14, 26)
    print("self-test ok: scoring matches web/harness.js")


# MARK: - Data


def load_test_split():
    """The MGB-3 test split. The dataset's current version only keeps `train`, so
    this searches its history for the newest version that still has test files."""
    from datasets import load_dataset
    from huggingface_hub import HfApi

    try:
        return load_dataset(DATASET, split="test"), "main", "test"
    except ValueError:
        pass
    api = HfApi()
    for commit in api.list_repo_commits(DATASET, repo_type="dataset"):
        files = api.list_repo_files(DATASET, repo_type="dataset", revision=commit.commit_id)
        test = [f for f in files if f.endswith(".parquet") and "test" in f.lower()]
        if test:
            urls = [f"hf://datasets/{DATASET}@{commit.commit_id}/{f}" for f in test]
            return load_dataset("parquet", data_files=urls, split="train"), commit.commit_id[:7], "test"
    print("WARNING: no test split anywhere in the dataset's history; scoring on train, which favours MGB-3 fine-tunes")
    return load_dataset(DATASET, split="train"), "main", "train"


def load_clips(limit, seed, max_seconds=30.0):
    """Clips as `{index, seconds, text}` plus either raw `audio` or Whisper
    `features`: the archived MGB-3 test split was saved pre-processed for Whisper
    training (80-bin log-mel features and token ids), not as audio and text."""
    from datasets import Audio

    ds, revision, split = load_test_split()
    print(f"dataset {DATASET} @ {revision}, split {split}: {len(ds)} rows, columns {ds.column_names}")
    order = list(range(len(ds)))
    random.Random(seed).shuffle(order)
    clips = []

    if "input_features" in ds.column_names:
        from transformers import WhisperTokenizer

        tokenizer = WhisperTokenizer.from_pretrained("openai/whisper-small")
        for i in order:
            row = ds[i]
            text = tokenizer.decode([t for t in row["labels"] if t >= 0], skip_special_tokens=True).strip()
            length = row.get("input_length")
            seconds = (length / 16000 if length and length > 1000 else length) or 30.0
            if not text or seconds > max_seconds or seconds < 0.5:
                continue
            clips.append({"index": i, "features": row["input_features"], "seconds": float(seconds), "text": text})
            if len(clips) >= limit:
                break
        return clips, f"{split} split @ {revision} (pre-computed Whisper features)"

    ds = ds.cast_column("audio", Audio(sampling_rate=16000))
    text_column = "sentence" if "sentence" in ds.column_names else [c for c in ds.column_names if c != "audio"][0]
    for i in order:
        row = ds[i]
        audio = row["audio"]["array"]
        seconds = len(audio) / 16000
        text = (row[text_column] or "").strip()
        if not text or seconds > max_seconds or seconds < 0.5:
            continue
        clips.append({"index": i, "audio": audio.astype("float32"), "seconds": seconds, "text": text})
        if len(clips) >= limit:
            break
    return clips, f"{split} split @ {revision}"


# MARK: - Models


def transcribe_all(model_id, clips, batch_size):
    import torch

    torch.set_num_threads(os.cpu_count() or 4)
    if "features" in clips[0]:
        return transcribe_features(model_id, clips, batch_size)

    from transformers import pipeline

    asr = pipeline("automatic-speech-recognition", model=model_id, device="cpu", torch_dtype=torch.float32)
    params = sum(p.numel() for p in asr.model.parameters())
    inputs = [{"raw": c["audio"], "sampling_rate": 16000} for c in clips]

    def run(generate_kwargs):
        return asr(inputs, batch_size=batch_size, generate_kwargs=generate_kwargs)

    start = time.time()
    try:
        outputs = run({"language": "arabic", "task": "transcribe"})
        forced = "language=arabic"
    except Exception as error:  # some fine-tunes ship without language tokens in their generation config
        print(f"  {model_id}: forcing Arabic failed ({error}); using the model's own defaults")
        start = time.time()
        outputs = run({})
        forced = "model default"
    elapsed = time.time() - start
    return [o["text"] for o in outputs], elapsed, params, forced


def transcribe_features(model_id, clips, batch_size):
    """Feeds pre-computed 80-bin log-mel features straight to a Whisper model."""
    import numpy as np
    import torch
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    processor = WhisperProcessor.from_pretrained(model_id)
    model = WhisperForConditionalGeneration.from_pretrained(model_id, torch_dtype=torch.float32).eval()
    if model.config.num_mel_bins != 80:
        raise ValueError(f"needs {model.config.num_mel_bins}-bin features; this test set has 80-bin features only")
    params = sum(p.numel() for p in model.parameters())

    def run(generate_kwargs):
        texts = []
        for b in range(0, len(clips), batch_size):
            feats = torch.tensor(np.stack([np.asarray(c["features"], dtype=np.float32) for c in clips[b:b + batch_size]]))
            with torch.no_grad():
                ids = model.generate(input_features=feats, max_new_tokens=225, **generate_kwargs)
            texts += processor.batch_decode(ids, skip_special_tokens=True)
        return texts

    start = time.time()
    try:
        texts = run({"language": "ar", "task": "transcribe"})
        forced = "language=arabic"
    except Exception as error:
        print(f"  {model_id}: forcing Arabic failed ({error}); using the model's own defaults")
        start = time.time()
        texts = run({})
        forced = "model default"
    return texts, time.time() - start, params, forced


# MARK: - Report


def score(clips, texts):
    w = [word_errors(c["text"], t) for c, t in zip(clips, texts)]
    c = [char_errors(c["text"], t) for c, t in zip(clips, texts)]
    per_clip_cer = [e / n for e, n in c if n]
    exact = sum(1 for clip, t in zip(clips, texts) if normalize(clip["text"]) == normalize(t))
    return {
        # No real model reproduces long human transcripts verbatim, annotator quirks
        # included, unless it was trained on them.
        "exact_share": exact / max(1, len(clips)),
        "wer": sum(e for e, _ in w) / max(1, sum(n for _, n in w)),
        "cer": sum(e for e, _ in c) / max(1, sum(n for _, n in c)),
        "median_clip_cer": statistics.median(per_clip_cer) if per_clip_cer else None,
    }


def report(results, clips, examples, args):
    audio_seconds = sum(c["seconds"] for c in clips)
    ok = sorted((r for r in results if "error" not in r), key=lambda r: r["cer"])
    lines = [
        "# Egyptian Arabic speech-to-text scores",
        "",
        f"{len(clips)} clips ({audio_seconds / 60:.1f} min) from the MGB-3 Egyptian Arabic {args.source} "
        f"([{DATASET}](https://huggingface.co/datasets/{DATASET})), seed {args.seed}. "
        "Lower is better. Scored with the app's Arabic-aware normalization.",
        "",
        "| Model | Size | CER | WER | Median clip CER | Exact clips | Speed (CPU) | Notes |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in ok:
        notes = []
        if r["exact_share"] > LEAK_THRESHOLD:
            notes.append("**likely trained on these clips: score not trustworthy**")
        elif r["model"] in TRAINED_ON_MGB3:
            notes.append("trained on MGB-3 (home advantage)")
        if r["forced"] != "language=arabic":
            notes.append(r["forced"])
        lines.append(
            f"| `{r['model']}` | {r['params'] / 1e6:.0f}M | **{r['cer'] * 100:.1f}%** | {r['wer'] * 100:.1f}% | "
            f"{r['median_clip_cer'] * 100:.1f}% | {r['exact_share'] * 100:.0f}% | {r['rtf']:.2f}× real time | {'; '.join(notes)} |"
        )
    for r in results:
        if "error" in r:
            lines.append(f"| `{r['model']}` | – | failed | – | – | – | – | {r['error'][:120]} |")
    lines += [
        "",
        "CER (character error rate) is the main measure for Arabic: word boundaries and spellings vary.",
        f"Exact clips is the share of clips transcribed exactly like the reference. Real models don't reproduce long human "
        f"transcripts verbatim (pause marks and slips included), so above {LEAK_THRESHOLD:.0%} the model has most likely seen these clips in training.",
        "Speed is processing time divided by audio length on the CI runner's CPU; it only compares models with each other.",
        "",
        "## Examples",
        "",
    ]
    for k, clip in enumerate(clips[: len(examples)]):
        lines.append(f"**Clip {k + 1}** ({clip['seconds']:.1f} s)")
        lines.append("")
        lines.append(f"- Reference: {clip['text']}")
        for model_id, texts in examples[k].items():
            lines.append(f"- `{model_id.split('/')[-1]}`: {texts}")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models", default=",".join(DEFAULT_MODELS))
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--examples", type=int, default=5)
    parser.add_argument("--out", default="eval/results")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    self_test()
    if args.self_test:
        return

    clips, args.source = load_clips(args.limit, args.seed)
    print(f"{len(clips)} clips, {sum(c['seconds'] for c in clips) / 60:.1f} min of audio")
    audio_seconds = sum(c["seconds"] for c in clips)
    examples = [{} for _ in range(min(args.examples, len(clips)))]
    results = []
    for model_id in [m.strip() for m in args.models.split(",") if m.strip()]:
        print(f"→ {model_id}", flush=True)
        try:
            texts, elapsed, params, forced = transcribe_all(model_id, clips, args.batch_size)
        except Exception as error:
            print(f"  failed: {error}")
            results.append({"model": model_id, "error": str(error)})
            continue
        r = {"model": model_id, "params": params, "rtf": elapsed / audio_seconds, "forced": forced, **score(clips, texts)}
        print(f"  CER {r['cer'] * 100:.1f}%  WER {r['wer'] * 100:.1f}%  {r['rtf']:.2f}× real time", flush=True)
        results.append(r)
        for k in range(len(examples)):
            examples[k][model_id] = texts[k]

    os.makedirs(args.out, exist_ok=True)
    markdown = report(results, clips, examples, args)
    with open(os.path.join(args.out, "egyptian-asr.md"), "w", encoding="utf-8") as f:
        f.write(markdown + "\n")
    with open(os.path.join(args.out, "egyptian-asr.json"), "w", encoding="utf-8") as f:
        json.dump({"dataset": DATASET, "clips": len(clips), "seed": args.seed, "results": results}, f, ensure_ascii=False, indent=2)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(markdown + "\n")
    print(markdown)
    if not any("error" not in r for r in results):
        sys.exit("every model failed")


if __name__ == "__main__":
    main()
