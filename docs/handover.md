# Handover: where meeting-harness stands

From the cloud session that built it (2026-10-31), to the session on the maintainer's laptop. Read
this, then [lab-brief.md](lab-brief.md), then [design.md](design.md).

## The project

A meeting transcriber that routes work through small specialist models and deterministic rules
instead of one big model: who spoke (diarization), which language (language ID restricted to the
meeting's languages, re-checked in short windows for code-switching), which model hears it (router),
then hallucination checks, merging, and an append-only event log (JSON Lines) that AI tools read
through a connector. English + Egyptian Arabic first; German/French later.

Decisions made with the maintainer: iPhone first and fully local (so far); record first, live captions
are the target; the understanding layer lives outside the app (Claude via a connector); MIT license;
public repo with the web app on GitHub Pages.

## What exists

- `Sources/HarnessCore`: Swift core (schema, events, router, speakers, utterances, loudness,
  hallucination guard, merge, live sentence rules). Tests run on Linux in CI (`swift.yml`).
- `App/`: iPhone app (SwiftUI, WhisperKit + SpeakerKit from argmax-oss-swift 1.1.1). Builds and passes
  unit tests on a simulator in CI (`ios.yml`), which also commits screenshots. **Never run on a
  device**; the maintainer plans to use xtool.
- `web/`: the same pipeline in the browser (transformers.js 3.8.1), one worker per model family so
  phones don't run out of memory. Live on GitHub Pages. 24 unit tests plus a real-model smoke test
  (`web.yml`). Laptop layout, Space to record, demo modes `?demo` and `?demo=live`.
- `eval/`: model scoring on MGB-3 (`score_models.py`, results in `eval/results/`), Core ML vs PyTorch
  check (`verify_coreml.py`, `verify-model.yml`), YouTube test sets (`youtube_fetch.py`,
  `youtube_test.sh`, `youtube_coreml.py`, `youtube.yml`).
- Egyptian Arabic model: `tawreck-hasaballah/whisper-small-eg` (30.9% CER on MGB-3, best that wasn't
  trained on the test set), converted to Core ML and published as release `egyptian-arabic-v1`.

## What we learned

- Core ML Egyptian model: 41.6% vs 39.3% CER for the original (12 clips). WhisperKit suppresses no
  tokens by default; the app now suppresses Whisper's non-speech tokens like transformers does
  (fixed a clip that came out as "[مايام الوليد]"). The rest of the gap is float16: one clip stops
  halfway in PyTorch float16 too. See `eval/results/coreml-check-2026-10-30.md`.
- **Live captions in the browser don't work well**: on the laptop they were slow, power hungry and
  looped ("نحن نحن نحن"). Whisper isn't a streaming model; we re-transcribe every 2 s and each call
  encodes a padded 30 s window, on CPU via WebAssembly, with a weak general Arabic model. The
  maintainer asked whether the approach holds; the answer given: the harness (routing, speakers,
  events, evaluation) holds and is model-agnostic; Whisper-in-the-browser for live captions doesn't.
- YouTube blocks GitHub's runners ("confirm you're not a bot"). Download test sets on the laptop. Do
  not work around YouTube's bot checks (alternate clients, cookies): that was ruled out.

## Open questions for the maintainer

1. Is fully local a must, or is opt-in cloud recognition acceptable (for the final transcript or for
   live captions)? This decides whether cloud recognizers are compared.
2. Which live-captioning approach, once `lab-brief.md` produces numbers.

## Next

Follow `lab-brief.md`: build the YouTube test set (Arabic captions), measure the current live
captions, compare faster/streaming recognizers on the same audio, write up a recommendation in
`eval/results/`. Don't change the app until the maintainer picks an approach. Ask before sending any
audio to a cloud service.

## Working notes

- The laptop is Windows (`D:\meeting-harness`). `eval/youtube_test.sh` is bash: use Git Bash or run
  its steps by hand. Keep `yt/` and `yt-testset.zip` out of git (ignored).
- CI: `ios.yml` runs on macOS for anything under `App/` or `Sources/HarnessCore/`; `web.yml` deploys
  Pages; `verify-model.yml` and `youtube.yml` are manual. `youtube.yml` takes a direct link to
  `yt-testset.zip` and also scores the iPhone Core ML model on a Mac runner.
- Commit messages in this repo describe what changed and why, in plain sentences.
