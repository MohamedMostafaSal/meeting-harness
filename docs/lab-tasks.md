# Lab tasks

The queue for the lab session on the maintainer's laptop (see [handover.md](handover.md)). The cloud
session adds tasks here on `master`; the lab does the first one still marked **open**, then:

1. writes results to `eval/results/` (or `eval/lab/` for raw notes) on branch `lab/live-asr`,
2. marks the task **done** in this file on that branch, with a one-line summary and the results file,
3. pushes `lab/live-asr` and stops.

Measure and report only: no changes to `App/`, `Sources/`, `web/` (local instrumentation is fine,
don't commit it), the workflows, or `master`. Ask the maintainer before sending audio to any cloud
service. Keep test audio and captions (`yt/`, `yt-testset.zip`) out of git.

---

## 1. YouTube test set and the current harness on it (done)

Done 2026-10-31: CER 140.8% (Balanced) and 275.8% (Light) against automatic captions, mostly repetition loops; about 65–70% with loops collapsed. Results: [eval/results/youtube-testset-2026-10-31.md](../eval/results/youtube-testset-2026-10-31.md).

Lab brief step 1. Run `eval/youtube_test.sh "https://youtu.be/dkeu6gi3mAc" 10 ar balanced` (Git Bash,
or its steps by hand). Report `yt/info.json`, `yt/score.md`, and 3 short excerpts from
`yt/side-by-side.md` that show the typical errors. Then run it again with `light` and report that
score too.

## 2. Why Arabic went to the English model, and why 33 speakers (done)

Done 2026-10-31: the English route is mostly clips under 2 s (only 4 real English segments), a stricter threshold doesn't fix it, loops are on the Arabic path, and the 33 is mostly tiny clusters. Results: [eval/results/youtube-routing-2026-10-31.md](../eval/results/youtube-routing-2026-10-31.md).

No new model runs: use the Balanced and Light `harness.json` from task 1 (routing log and segments)
and `yt/cues.json`.

- **Routing.** For every segment labelled `en`: start, length, the language-ID guesses and the
  routing decision from the log (was it a whole-utterance call or a re-check window?), the harness
  text, and the captions at the same time. Count how many look like real English vs Arabic. Then
  give the distribution of the language-ID confidence on those segments, and say whether a stricter
  threshold or an Arabic prior (most of the meeting is Arabic) would have fixed them.
- **Loops vs routing.** Of the loop segments, how many were routed `en` vs `ar`, and how long were they?
- **Speakers.** Turns and total speech per speaker label, sorted. How many labels have under 10 s of
  speech? Is the 33 driven by many tiny clusters (short turns, overlap, laughter) or by a few voices
  split in many?

Write it as `eval/results/youtube-routing-2026-10-31.md`.

## 3. faster-whisper and Meetily's settings on the same 10 minutes (done)

Done 2026-10-31: repetition limits on the Egyptian model (run C) gave 42.6% CER, no loops and 0.29x the audio length; `no_speech_prob` can't be its non-speech gate, and Meetily's setup doesn't beat C. Results: [eval/results/faster-whisper-2026-10-31.md](../eval/results/faster-whisper-2026-10-31.md).

Lab brief step 3, first candidate. Same audio, same scoring (`web/test/captions.js` or
`eval/score_models.py`), plus `eval/lab/loop_stats.mjs` for loops. Runs:

| Run | Model | Settings |
|---|---|---|
| A | `openai/whisper-small` (CTranslate2 int8) | `language="ar"`, `vad_filter=True`, `condition_on_previous_text=False`, `beam_size=1` |
| B | `tawreck-hasaballah/whisper-small-eg` converted with `ct2-transformers-converter --quantization int8` | as A |
| C | as B | plus `no_repeat_ngram_size=3`, `repetition_penalty=1.1`, `compression_ratio_threshold=2.4` |

For each: CER and WER (raw, and with loops collapsed and tags removed, as in task 1), loop words,
processing time and real-time factor, peak memory. A vs task 1's Balanced separates runtime and
decoding from the model; B vs A shows the Egyptian model; C shows whether stopping loops during
decoding works.

Then, because task 2 showed routing and loops interact, two runs on **the harness's own pieces** (cut
`yt/audio.wav` by the Balanced pieces from the routing log, or by the 142 segments if the pieces
can't be recovered; pad each 0.2 s on both sides):

| Run | Model | Settings |
|---|---|---|
| D | as C | every piece forced to Arabic (what "never English under 2 s" would do, taken to the limit) |
| E | as C | as D, but skip pieces whose `no_speech_prob` (first segment) is above 0.6 |

For D and E: loop words, CER against the captions (pieces joined in time order), and for the 18
non-speech-tag pieces and the 4 real-English ones from task 2, what each run wrote. Also give the
`no_speech_prob` distribution for the non-speech pieces vs the rest: that tells us whether Whisper's
own no-speech score can be the non-speech gate.

Then **Meetily's setup**, copied from Meetily v0.4.1 (MIT, github.com/Zackriya-Solutions/meeting-minutes,
`frontend/src-tauri/src/whisper_engine/whisper_engine.rs`, `audio/vad.rs`, `audio/hardware_detector.rs`),
as the reference for what a mature local app does about loops:

| Run | Model | Setup |
|---|---|---|
| F | `ggml-small.bin` (whisper.cpp's multilingual small) | Meetily's import path, below |
| G | `tawreck-hasaballah/whisper-small-eg` converted to GGML (whisper.cpp `models/convert-h5-to-ggml.py`) | as F |

- **Runtime:** whisper.cpp (Meetily uses it through `whisper-rs`). The Windows release with Vulkan if it
  runs on this laptop's GPU, otherwise the CPU build. Say which.
- **Segmentation:** Silero VAD on the 10 minutes with positive threshold 0.50, negative threshold 0.35,
  redemption 2000 ms (Meetily's import and re-transcribe paths), pre-speech pad 300 ms, post-speech pad
  400 ms, minimum speech 250 ms. Transcribe each speech segment on its own.
- **Decoding (Meetily's Windows settings):** language `ar`, beam search size 2 with patience 1.0,
  temperature 0.2, no timestamps, suppress blank, suppress non-speech tokens, max initial timestamp 1.0,
  entropy threshold 2.4, log-probability threshold −1.0, no-speech threshold 0.55.
- **Cleanup after decoding** (`clean_repetitive_text`, port it): empty the text if it contains one of
  Meetily's junk phrases (thank you for watching, thanks for watching, like and subscribe, music
  playing, applause, laughter, um um um, uh uh uh, ah ah ah) or has 3 or fewer distinct characters and
  more than 10 characters; if 3+ words, collapse consecutive repeats of a word to one, then collapse a
  2–5-word phrase immediately repeated once; then empty the text if (repeated words ÷ words) > 0.7.

For F and G: the same scores as A–C, **before and after the cleanup** (so we see what decoding settings do
vs what the cleanup removes), plus how many segments the cleanup emptied and a few examples of each kind.

Write it as `eval/results/faster-whisper-2026-10-31.md`.

## 4. Current live captions, measured briefly (deferred)

Lab brief step 2, shortened: the batch numbers already show the cost. Serve `web/`, record in Chrome
while **3 minutes** of the video play (from 03:00, the cleanest minute, then 05:00, the worst),
**Light** only. Report: delay from a sentence ending to its committed caption (a few examples),
CPU in Task Manager, whether captions loop, and whether the page stays responsive.

Deferred: task 1 and 2 show the problems are in the pipeline itself, not only in live captions.
Will come back once the recognizer and the gates are chosen.


## 5. Tune the repetition limits, and check against human transcripts (open)

Task 3's run C (Egyptian model, faster-whisper, `no_repeat_ngram_size=3`, `repetition_penalty=1.1`) is the
baseline. Two open questions: what the limits cost on real repeated speech (minute 3 got worse), and whether
C beats stock `small` (run A) against **human** transcripts rather than YouTube's automatic captions.

**a. Limit sweep on the same 10 minutes**, run C's setup otherwise unchanged:

| `no_repeat_ngram_size` | 0 | 3 | 4 | 5 | 0 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|---|---|
| `repetition_penalty` | 1.0 | 1.0 | 1.0 | 1.0 | 1.1 | 1.1 | 1.1 | 1.1 |

(`3 / 1.1` is C; `0 / 1.0` is B.) For each: CER, loop words / words, time, and minute 3's CER and word count
against the captions' 137. Then read minute 3 for the best two settings and say what was cut: real repeated
words, or noise.

**b. Human transcripts: MGB-3.** Run A, C, and the best setting from (a) on the 100 MGB-3 test clips that
`eval/score_models.py` uses (`--clips 100`, its default seed; the dataset is downloadable on the laptop).
MGB-3's transcripts are human-made, so this settles the Egyptian model vs stock `small` question. Report
CER and WER with `score_models.py`'s Arabic normalization, loops, and time.

**c. Optional, only if quick:** time the best setting on the laptop's NVIDIA GPU (GeForce 940MX) with
faster-whisper (`device="cuda"`, `compute_type="int8"` or `int8_float32`). Skip it if CUDA doesn't work
within a few minutes; report why.

Write it as `eval/results/repetition-limits-2026-10-31.md`.
