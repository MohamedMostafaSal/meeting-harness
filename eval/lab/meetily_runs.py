"""Lab task 3, runs F and G: Meetily v0.4.1's import path, as the reference for loop handling.

    python eval/lab/meetily_runs.py F        (stock ggml-small)
    python eval/lab/meetily_runs.py G        (the Egyptian model converted to GGML)
    python eval/lab/meetily_runs.py test     (checks the cleanup port)

Run from the repo root. Writes yt/fw-<run>-raw/ and yt/fw-<run>-clean/harness.json for
eval/lab/loop_stats.mjs, and yt/fw-<run>-clean/run.json with timing, memory and each chunk's outcome.

Ported from frontend/src-tauri/src/whisper_engine/whisper_engine.rs (MIT): the decoding settings and
clean_repetitive_text. Silero VAD comes from faster-whisper's bundle with the settings of audio/vad.rs;
Meetily reaches it through silero_rs, so chunk edges may differ slightly.
"""

import json
import os
import sys
import time
import wave

MODELS = {"F": "yt/models/ggml-small.bin", "G": "yt/models/ggml-small-eg.bin"}
RATE = 16000
PRE_PAD, POST_PAD = 0.3, 0.4
MAX_SEGMENT = 25
SILENCE_RMS = 0.02
MIN_SAMPLES = 1600  # the import path skips anything shorter
JUNK = ["thank you for watching", "thanks for watching", "like and subscribe", "music playing", "applause",
        "laughter", "um um um", "uh uh uh", "ah ah ah"]


def is_meaningless(text):
    lower = text.lower()
    if any(p in lower for p in JUNK):
        return "junk phrase"
    # Rust's text.len() counts UTF-8 bytes, so an Arabic letter counts twice.
    if len(set(text)) <= 3 and len(text.encode("utf-8")) > 10:
        return "few distinct characters"
    return None


def remove_word_repetitions(words):
    out = []
    for word in words:
        if not out or out[-1] != word:
            out.append(word)
    return out


def remove_phrase_repetitions(words):
    if len(words) < 4:
        return words
    out = []
    i = 0
    while i < len(words):
        for n in range(2, min(5, (len(words) - i) // 2) + 1):
            if words[i:i + n] == words[i + n:i + n * 2]:
                out.extend(words[i:i + n])
                i += n * 2
                break
        else:
            out.append(words[i])
            i += 1
    return out


def repetition_ratio(text):
    words = text.split()
    if len(words) < 4:
        return 0.0
    counts = {}
    for word in words:
        counts[word.lower()] = counts.get(word.lower(), 0) + 1
    return sum(c - 1 for c in counts.values()) / len(words)


def clean(text):
    """Returns (cleaned text, why it was emptied or None)."""
    if not text:
        return "", None
    why = is_meaningless(text)
    if why:
        return "", why
    words = text.split()
    if len(words) < 3:
        return text, None
    final = " ".join(remove_phrase_repetitions(remove_word_repetitions(words)))
    if repetition_ratio(final) > 0.7:
        return "", "repetition ratio"
    return final, None


def test():
    assert clean("thanks for watching everyone") == ("", "junk phrase")
    assert clean("ههههههههه") == ("", "few distinct characters")
    assert clean("نعم نعم") == ("نعم نعم", None)  # under 3 words is left alone
    assert clean("لا لا لا تمام")[0] == "لا تمام"
    assert clean("أعرف أن أعرف أن تمام")[0] == "أعرف أن تمام"
    assert clean("أ ب أ ب أ ب أ ب أ ب ج")[0] == "أ ب أ ب أ ب ج"  # one pass only, as in Meetily
    assert clean("نعم ، نعم ، نعم ، نعم ، نعم ،") == ("نعم ، نعم ، نعم ،", None)  # 4 of 6 repeated: under 0.7
    assert clean("نعم تمام نعم لا نعم ماشي نعم نعم تمام تمام نعم")[1] is None
    assert repetition_ratio("نعم نعم نعم نعم نعم نعم لا") > 0.7
    print("cleanup port ok")
    import numpy

    # 70 s of loud signal with quiet gaps at 24 s and 48 s: cut in the gaps, nothing lost.
    audio = numpy.full(70 * RATE, 0.5, dtype=numpy.float32)
    audio[24 * RATE:24 * RATE + RATE // 2] = 0
    audio[48 * RATE:48 * RATE + RATE // 2] = 0
    parts = split_at_silence(audio, 0.0, 70.0)
    assert len(parts) == 3 and parts[0][0] == 0 and parts[-1][1] == 70, parts
    assert all(a[1] == b[0] for a, b in zip(parts, parts[1:])) and 24 <= parts[0][1] <= 24.5 and 48 <= parts[1][1] <= 48.5, parts
    # No silence: each cut runs 1 s past the target, still contiguous.
    parts = split_at_silence(numpy.full(60 * RATE, 0.5, dtype=numpy.float32), 0.0, 60.0)
    assert all(a[1] == b[0] for a, b in zip(parts, parts[1:])) and parts[-1][1] == 60, parts
    assert split_at_silence(audio, 1.0, 20.0) == [[1.0, 20.0]]
    print("split port ok")


def speech_chunks(audio):
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    # Padded here rather than by Silero because Meetily's pre and post pads differ.
    found = get_speech_timestamps(audio, VadOptions(threshold=0.50, neg_threshold=0.35, min_speech_duration_ms=250,
                                                    min_silence_duration_ms=2000, speech_pad_ms=0))
    chunks = []
    for s in found:
        start = max(0, s["start"] / RATE - PRE_PAD)
        end = min(len(audio) / RATE, s["end"] / RATE + POST_PAD)
        if chunks and start <= chunks[-1][1]:
            chunks[-1][1] = end
        else:
            chunks.append([start, end])
    return chunks


def split_at_silence(audio, start, end):
    """Port of split_segment_at_silence (audio/common.rs): chunks over 25 s are cut at the quietest 100 ms
    near each target, running 1 s past it if nothing is quiet enough. The import path does this before
    transcribing. Returns [start, end] pairs in seconds."""
    import numpy

    window, radius, overlap = RATE // 10, RATE * 3, RATE
    max_samples = MAX_SEGMENT * RATE
    samples = audio[int(start * RATE):int(end * RATE)]
    total = len(samples)
    if total <= max_samples:
        return [[start, end]]
    result = []
    pos = 0
    while pos < total:
        if total - pos <= max_samples:
            result.append([start + pos / RATE, end])
            break
        target = pos + max_samples
        search_start = max(target - radius, pos + RATE)
        search_end = min(target + radius, max(0, total - window))
        best_split, best_rms = min(target, total), float("inf")
        for i in range(search_start, search_end - window + 1, RATE // 100):
            rms = float(numpy.sqrt(numpy.mean(samples[i:i + window] ** 2)))
            if rms < best_rms:
                best_rms, best_split = rms, i + window // 2
        chunk_end = best_split if best_rms <= SILENCE_RMS else min(best_split + overlap, total)
        result.append([start + pos / RATE, start + chunk_end / RATE])
        pos = chunk_end
    return result


def save(folder, segments, info=None):
    os.makedirs(folder, exist_ok=True)
    json.dump({"transcript": {"segments": segments}}, open(f"{folder}/harness.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    if info:
        json.dump(info, open(f"{folder}/run.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)


def run(name):
    import numpy
    import psutil
    from pywhispercpp.model import Model

    with wave.open("yt/audio.wav") as f:
        audio = numpy.frombuffer(f.readframes(f.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768
    # Meetily's Windows settings. temperature_inc stays at whisper.cpp's default because Meetily doesn't set it.
    model = Model(MODELS[name], params_sampling_strategy=1, n_threads=4, redirect_whispercpp_logs_to=os.devnull,
                  language="ar", beam_search={"beam_size": 2, "patience": 1.0}, temperature=0.2, no_timestamps=True,
                  token_timestamps=True, suppress_blank=True, suppress_nst=True, max_initial_ts=1.0, entropy_thold=2.4,
                  logprob_thold=-1.0, no_speech_thold=0.55, max_len=200, single_segment=False, translate=False,
                  print_progress=False, print_realtime=False, print_timestamps=False, print_special=False)
    started = time.time()
    speech = speech_chunks(audio)
    chunks = [c for start, end in speech for c in split_at_silence(audio, start, end)]
    chunks = [c for c in chunks if (c[1] - c[0]) * RATE >= MIN_SAMPLES]
    vad_seconds = time.time() - started
    detail = []
    for start, end in chunks:
        found = model.transcribe(audio[int(start * RATE):int(end * RATE)])
        raw = " ".join(s.text.strip() for s in found).strip()
        cleaned, why = clean(raw)
        detail.append({"start": round(start, 3), "end": round(end, 3), "raw": raw, "clean": cleaned, "emptied": why})
    wall = time.time() - started
    segments = lambda key: [{"start": d["start"], "end": d["end"], "lang": "ar", "text": d[key]} for d in detail if d[key]]
    save(f"yt/fw-{name}-raw", segments("raw"))
    save(f"yt/fw-{name}-clean", segments("clean"), {
        "model": MODELS[name], "runtime": "whisper.cpp via pywhispercpp, CPU", "seconds": wall, "vad_seconds": vad_seconds,
        "audio_seconds": len(audio) / RATE, "realtime_factor": wall / (len(audio) / RATE), "vad_chunks": len(speech), "chunks": len(chunks),
        "speech_seconds": sum(e - s for s, e in chunks), "peak_memory_mb": round(psutil.Process().memory_info().peak_wset / 2**20),
        "detail": detail})
    print(f"{name}: {wall:.0f} s, {len(chunks)} chunks, {sum(1 for d in detail if d['emptied'])} emptied")


if __name__ == "__main__":
    test() if sys.argv[1] == "test" else run(sys.argv[1])
