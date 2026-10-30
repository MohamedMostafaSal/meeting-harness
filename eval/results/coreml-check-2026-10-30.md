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
  halfway through. Decoding settings (fallback, chunking) don't change this.

## Follow-up: where each failure comes from

A second run added Core ML on the CPU and GPU, and the original model in float16:

| Clip | Core ML (Neural Engine) | Core ML (CPU) | Core ML (GPU) | PyTorch float16 | PyTorch float32 |
|---|---|---|---|---|---|
| 8 | 95.6% | 95.6% | 95.6% | 32.0% | 32.0% |
| 9 | 70.4% | 70.4% | 70.4% | 70.4% | 34.4% |
| 11 | 77.3% | 84.0% | 75.5% | 73.6% | 73.6% |

- **Clip 9 is float16.** PyTorch in float16 stops at the same word as Core ML. Every Core ML compute
  unit behaves the same, so moving the model off the Neural Engine doesn't help; a fix needs a float32
  conversion (larger and slower) or a model that is stable in float16.
- **Clip 8 is not precision.** PyTorch float16 transcribes it fine. Core ML's output starts with "[",
  the token Whisper uses for notes like "[music]". transformers suppresses those tokens (the model's
  `suppress_tokens`); WhisperKit suppresses none unless asked ("TODO: implement these as default" in
  its source). The app now passes the same non-speech list OpenAI's Whisper uses, built from the
  tokenizer, plus `suppressBlank`; the check now runs the CLI with the model's own list to confirm.

## What the harness does about it

The hallucination guard (a deterministic rule, in both the Swift core and the web app) now also flags
"too little text for the audio length": under 2 letters a second over 6 s or more. Clip 8's output is
caught that way and kept, marked uncertain. A cut-off ending like clip 9's is not caught yet; catching it
needs word timestamps (to see that the words stop well before the audio does).
