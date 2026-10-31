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

## 3. faster-whisper on the same 10 minutes (open, do this next)

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

Write it as `eval/results/faster-whisper-2026-10-31.md`.

## 4. Current live captions, measured briefly (deferred)

Lab brief step 2, shortened: the batch numbers already show the cost. Serve `web/`, record in Chrome
while **3 minutes** of the video play (from 03:00, the cleanest minute, then 05:00, the worst),
**Light** only. Report: delay from a sentence ending to its committed caption (a few examples),
CPU in Task Manager, whether captions loop, and whether the page stays responsive.

Deferred: task 1 and 2 show the problems are in the pipeline itself, not only in live captions.
Will come back once the recognizer and the gates are chosen.

