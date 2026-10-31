"""Is no_speech_prob a real signal? Checks the token it reads, then scores known silence and noise and the
task 2 non-speech pieces on both the Egyptian and the stock model.

    python eval/lab/no_speech_probe.py      (from the repo root)
"""

import statistics
import sys
import wave

import numpy

sys.path.insert(0, "eval/lab")
from faster_whisper import WhisperModel
from faster_whisper_runs import EGYPTIAN, PAD, RATE, pieces

with wave.open("yt/audio.wav") as f:
    audio = numpy.frombuffer(f.readframes(f.getnframes()), dtype=numpy.int16).astype(numpy.float32) / 32768
noise = numpy.random.default_rng(0).normal(0, 0.05, 3 * RATE).astype(numpy.float32)
items = [p for p in pieces() if p["kind"] in ("non-speech tag", "real English")]

for name in (EGYPTIAN, "small"):
    model = WhisperModel(name, device="cpu", compute_type="int8")
    t = model.hf_tokenizer
    print(f"\n# {name}: <|nospeech|> id {t.token_to_id('<|nospeech|>')}, <|nocaptions|> id {t.token_to_id('<|nocaptions|>')}")
    score = lambda clip: next(iter(model.transcribe(clip, language="ar", vad_filter=False, condition_on_previous_text=False,
                                                    beam_size=1, no_speech_threshold=None, temperature=0)[0]), None)
    for label, clip in (("3 s digital silence", numpy.zeros(3 * RATE, dtype=numpy.float32)), ("3 s white noise", noise)):
        s = score(clip)
        print(f"{label}: {s.no_speech_prob if s else None}, text {s.text[:40] if s else None!r}")
    groups = {}
    for p in items:
        s = score(audio[max(0, int((p["start"] - PAD) * RATE)):int((p["end"] + PAD) * RATE)])
        groups.setdefault(p["kind"], []).append(s.no_speech_prob if s else None)
    for kind, values in groups.items():
        scored = sorted(v for v in values if v is not None)
        print(f"{kind}: n {len(values)}, median {statistics.median(scored):.4f}, max {scored[-1]:.4f}, above 0.6: {sum(v > 0.6 for v in scored)}, above 0.1: {sum(v > 0.1 for v in scored)}")
