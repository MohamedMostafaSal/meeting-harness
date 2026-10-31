"""Lab task 3: faster-whisper on the YouTube test set, on the whole audio and on the harness's pieces.

    python eval/lab/faster_whisper_runs.py run A        (A, B, C on the audio; D, Dn on the pieces)
    python eval/lab/faster_whisper_runs.py report       (per-piece tables for D and Dn, derives E and En)

Run from the repo root. Writes yt/fw-<run>/harness.json in the shape eval/lab/loop_stats.mjs reads, plus
yt/fw-<run>/run.json with timing, peak memory and per-piece detail.

D and E follow the task; `Dn` is added as a diagnostic: the same, without the voice filter, because the
filter can remove a clip before Whisper gives it a no_speech_prob. faster-whisper's own no-speech check
is off on the pieces (no_speech_threshold=None), otherwise it hides the scores being measured. E and En
skip pieces after the fact: the text of the pieces they keep is the same as in D and Dn.
"""

import json
import os
import re
import statistics
import sys
import time
import wave

import numpy

BASE = dict(language="ar", vad_filter=True, condition_on_previous_text=False, beam_size=1)
# compression_ratio_threshold=2.4 is already faster-whisper's default, so A and B have it too.
LIMITS = dict(no_repeat_ngram_size=3, repetition_penalty=1.1, compression_ratio_threshold=2.4)
EGYPTIAN = "yt/models/whisper-small-eg-ct2"
RUNS = {
    "A": ("small", BASE),
    "B": (EGYPTIAN, BASE),
    "C": (EGYPTIAN, {**BASE, **LIMITS}),
    "D": (EGYPTIAN, {**BASE, **LIMITS, "no_speech_threshold": None}),
    "Dn": (EGYPTIAN, {**BASE, **LIMITS, "no_speech_threshold": None, "vad_filter": False}),
}
PAD = 0.2
RATE = 16000
GATE = 0.6
LID = re.compile(r"^\s*([\d.]+)–([\d.]+)s LID \w+ [\d.]+ / \w+ [\d.]+ → (.*)$")
TAG_ONLY = re.compile(r"^[\s>-]*([\[(][^\])]*[\])][\s.]*)+$")
REAL_ENGLISH = {479.8, 484.0, 484.5, 485.4}  # from task 2, by reading the captions


def balanced():
    return json.load(open("yt/balanced/harness.json", encoding="utf-8"))


def pieces():
    """The Balanced pieces from the routing log, each with its task 2 kind."""
    data = balanced()
    out = []
    for line in data["log"]:
        m = LID.match(line)
        if m and not m[3].startswith("ambiguous"):
            out.append({"start": float(m[1]), "end": float(m[2])})
    segments = data["transcript"]["segments"]
    for p in out:
        overlap = lambda s: min(p["end"], s["end"]) - max(p["start"], s["start"])
        s = max(segments, key=overlap)
        p["kind"] = kind(s)
        p["balanced_text"] = s["text"]
    return out


def kind(s):
    if s["lang"] != "en":
        return "labeled ar"
    if round(s["start"], 1) in REAL_ENGLISH:
        return "real English"
    return "non-speech tag" if TAG_ONLY.match(s["text"]) else "invented English"


def save(name, segments, info):
    folder = f"yt/fw-{name}"
    os.makedirs(folder, exist_ok=True)
    transcript = {"segments": segments}
    json.dump({"transcript": transcript}, open(f"{folder}/harness.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump(info, open(f"{folder}/run.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def run(name):
    import psutil
    from faster_whisper import WhisperModel

    model_id, options = RUNS[name]
    # yt/audio.wav is already 16 kHz mono PCM; faster-whisper's decode_audio breaks with current PyAV.
    with wave.open("yt/audio.wav") as f:
        audio = numpy.frombuffer(f.readframes(f.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768
    model = WhisperModel(model_id, device="cpu", compute_type="int8")
    started = time.time()
    if name in ("D", "Dn"):
        detail = []
        for p in pieces():
            clip = audio[max(0, int((p["start"] - PAD) * RATE)):int((p["end"] + PAD) * RATE)]
            found = list(model.transcribe(clip, **options)[0])
            detail.append({**p, "text": " ".join(s.text.strip() for s in found),
                           "no_speech_prob": found[0].no_speech_prob if found else None})
        segments = [{"start": d["start"], "end": d["end"], "lang": "ar", "text": d["text"]} for d in detail if d["text"]]
    else:
        detail = None
        segments = [{"start": s.start, "end": s.end, "lang": "ar", "text": s.text.strip()}
                    for s in model.transcribe(audio, **options)[0]]
    wall = time.time() - started
    process = psutil.Process()
    save(name, segments, {"model": model_id, "options": {k: v for k, v in options.items()}, "seconds": wall,
                          "audio_seconds": len(audio) / RATE, "realtime_factor": wall / (len(audio) / RATE),
                          "peak_memory_mb": round(process.memory_info().peak_wset / 2**20), "detail": detail})
    print(f"{name}: {wall:.0f} s, {len(segments)} segments")


def report():
    for base, gated in (("D", "E"), ("Dn", "En")):
        info = json.load(open(f"yt/fw-{base}/run.json", encoding="utf-8"))
        detail = info["detail"]
        keep = [d for d in detail if d["text"] and (d["no_speech_prob"] or 0) <= GATE]
        save(gated, [{"start": d["start"], "end": d["end"], "lang": "ar", "text": d["text"]} for d in keep],
             {"derived_from": base, "gate": GATE})
        print(f"\n# {base} and {gated}: {len(detail)} pieces, processing {info['seconds']:.0f} s, peak {info['peak_memory_mb']} MB")
        print(f"pieces with no output: {sum(not d['text'] for d in detail)}; skipped by the gate: {sum(1 for d in detail if d['text'] and d['no_speech_prob'] > GATE)}")
        for group in ("non-speech tag", "real English", "invented English", "labeled ar"):
            items = [d for d in detail if d["kind"] == group]
            scores = sorted(d["no_speech_prob"] for d in items if d["no_speech_prob"] is not None)
            quart = statistics.quantiles(scores, n=4) if len(scores) >= 2 else [None] * 3
            print(f"{group}: {len(items)} pieces, empty {sum(not d['text'] for d in items)}, scored {len(scores)}, above {GATE}: "
                  f"{sum(s > GATE for s in scores)}, quartiles {[round(q, 3) if q is not None else None for q in quart]}, "
                  f"min {scores[0] if scores else None}, max {scores[-1] if scores else None}")
        for group in ("non-speech tag", "real English"):
            print(f"## {group}: start, length, no_speech_prob, gated?, text")
            for d in detail:
                if d["kind"] == group:
                    gated_out = d["no_speech_prob"] is not None and d["no_speech_prob"] > GATE
                    print(f"{d['start']} | {d['end'] - d['start']:.1f} | {d['no_speech_prob'] if d['no_speech_prob'] is None else round(d['no_speech_prob'], 3)} | {'skip' if gated_out else ''} | {d['balanced_text'][:30]} => {d['text'][:90]}")
        for gate in (0.3, 0.5, 0.6, 0.7, 0.8, 0.9):
            nonspeech = [d for d in detail if d["kind"] == "non-speech tag" and d["no_speech_prob"] is not None]
            rest = [d for d in detail if d["kind"] != "non-speech tag" and d["no_speech_prob"] is not None]
            print(f"gate {gate}: skips {sum(d['no_speech_prob'] > gate for d in nonspeech)}/{len(nonspeech)} non-speech, {sum(d['no_speech_prob'] > gate for d in rest)}/{len(rest)} others")


if __name__ == "__main__":
    if sys.argv[1] == "run":
        run(sys.argv[2])
    else:
        report()
