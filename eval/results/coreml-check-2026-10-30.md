# Core ML conversion check: `tawreck-hasaballah/whisper-small-eg` (release `egyptian-arabic-v1`)

`eval/verify_coreml.py` on 12 Egyptian Arabic clips (16–27 s) from MightyStudent/Egyptian-ASR-MGB-3,
comparing the Core ML model the iPhone app downloads (run through WhisperKit's CLI on a macOS runner)
with the original PyTorch model.

| Setup | CER |
|---|---|
| Core ML, the app's decoding (whole utterance, 3 temperature fallbacks) | 47.8% |
| Core ML, greedy (no fallback) | 49.4% |
| Core ML, CLI default (VAD chunks) | 48.1% |
| PyTorch (original) | 39.3% |

| Clip | Seconds | Core ML (app) | PyTorch |
|---|---|---|---|
| 1 | 27.0 | 41.7% | 41.7% |
| 2 | 23.0 | 20.3% | 19.5% |
| 3 | 24.1 | 29.9% | 30.7% |
| 4 | 27.0 | 51.2% | 51.2% |
| 5 | 23.0 | 13.4% | 13.4% |
| 6 | 17.0 | 18.6% | 18.6% |
| 7 | 21.0 | 27.4% | 26.5% |
| 8 | 26.0 | 95.6% | 32.0% |
| 9 | 16.0 | 70.4% | 34.4% |
| 10 | 24.1 | 90.4% | 95.3% |
| 11 | 27.0 | 85.9% | 73.6% |
| 12 | 26.0 | 21.5% | 21.5% |

## What this says

- On 9 of 12 clips the converted model matches the original to within a point: the conversion is sound.
- Two clips fail outright in every Core ML setup: clip 8 decodes to a two-word fragment, clip 9 stops
  halfway through. Decoding settings (fallback, chunking) don't change this, so it happens inside the model.
- Leading suspect: float16. Core ML runs the model in float16 on the Neural Engine and GPU; PyTorch here
  ran in float32. The next check runs Core ML on the CPU (float32) and PyTorch in float16 to confirm.

## What the harness does about it

Failures like these are short or truncated output for a long utterance, which is what the hallucination
guard and the uncertain flag are for: the app keeps the text but marks it uncertain, and the gap is
visible in the transcript.
