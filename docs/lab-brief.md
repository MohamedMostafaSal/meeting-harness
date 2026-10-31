# Lab brief: measure before rebuilding live captions

For a Claude Code session on the maintainer's Windows laptop (`meeting-harness-lab`). Read
[design.md](design.md) and the README first. Goal: replace guesses with numbers, then pick the
live-captioning approach. Don't change the app yet.

## Why

On the laptop, the web app's live captions were slow, power hungry, and looped on Egyptian Arabic
("نحن نحن نحن"). Known causes, to confirm with measurements:

- Whisper isn't a streaming model. `web/live.js` re-transcribes the sentence in progress every 2 s,
  and every call encodes a full 30 s window (mostly padding).
- transformers.js runs on the CPU through WebAssembly (WebGPU is optional and experimental).
- The browser's Arabic model is general Whisper (whisper-base in Light: about 53% CER on Egyptian
  Arabic in `eval/results/egyptian-asr-2026-10-30.md`). Small models loop on short, unclear audio, and
  `hallucinationReason` in `web/harness.js` only catches loops of 8+ words.

## 1. Test set from the YouTube video

YouTube blocks GitHub's runners, so this runs on the laptop. Needs Python 3, Node 18+, ffmpeg and
`zip` (on Windows run the script in Git Bash, or run the three commands inside it by hand).

```
eval/youtube_test.sh "https://youtu.be/dkeu6gi3mAc" 10 ar balanced
```

Report: `yt/info.json` (uploaded or automatic captions?), `yt/score.md`, and a few telling excerpts
from `yt/side-by-side.md`. Keep `yt/` and `yt-testset.zip` out of git (already ignored).

## 2. Measure the current live captions

Serve `web/` (`npx serve web` or `python -m http.server -d web`), open it in Chrome, record while
the video plays through the speakers (or route the audio in). For Light and Balanced, note:

- delay from a sentence ending to its committed caption (by eye or with timestamps in `live.js`)
- CPU use (Task Manager) and whether the fans spin up
- whether the loops happen, and on what kind of audio (short phrases, pauses, music)

## 3. Try streaming recognizers on the same audio (Windows)

On the first 10 minutes of `yt/audio.wav`, for each candidate measure: real-time factor, CPU/GPU use,
CER against `yt/cues.json` (use `web/test/captions.js` or `eval/score_models.py`'s `char_errors`),
and whether it handles Egyptian Arabic and English mixed in one sentence.

1. **faster-whisper** (CTranslate2, int8 on CPU, or CUDA if there's an NVIDIA GPU) with
   `tawreck-hasaballah/whisper-small-eg` converted by `ct2-transformers-converter`, plus
   `vad_filter=True`, `condition_on_previous_text=False` and a repetition guard. This is "Whisper,
   but on efficient runtime and only at pauses", the cheapest change to the current design.
2. **whisper.cpp** with the same model (GGML conversion), streaming example, to compare.
3. **sherpa-onnx streaming models** (real streaming, very cheap): check what Arabic streaming
   models exist today; record if there are none worth testing.
4. If the maintainer allows cloud (opt-in only, not decided yet): one streaming cloud recognizer with
   Egyptian Arabic, for a quality ceiling. Ask before sending any audio anywhere.

## 4. Write it up

Put the results in `eval/results/live-asr-<date>.md`: a table of candidate × (CER, real-time factor,
CPU, loops, code-switching), and a recommendation for (a) the browser and (b) the iPhone app. Note
what can't be tested on Windows (Apple's on-device recognizer, WhisperKit on the Neural Engine) so
it can be done on a Mac or in CI.
