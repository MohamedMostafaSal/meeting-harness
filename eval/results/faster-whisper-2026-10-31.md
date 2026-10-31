# faster-whisper and Meetily's settings on the same 10 minutes (2026-10-31)

Lab task 3, on the test set from task 1: the first 10 minutes of a fast Egyptian Arabic talk show. Laptop
CPU only (i7-6500U, 2 cores, 4 threads). Captions are YouTube's automatic ones, so CER means agreement with
another recognizer, and small differences between runs shouldn't be over-read.

**Result.**

- **Run C is the best setup measured:** the Egyptian model on faster-whisper with repetition limits, at 42.6%
  CER (Balanced: 140.8%), no loops, and 0.29× the audio length (Balanced: 2.4×).
- **Repetition limits during decoding are the key.** On the same model they removed the loops and cut the
  time from 1311 s to 177 s. They may also drop some real text in repetitive speech: minute 3 got worse.
- **The Egyptian model only helps with those limits on.** Without them it is worse than stock `small`; with
  them it is 2 points better on CER and about level on WER.
- **Forcing all pieces to Arabic added no loops when limits were on** (run D), but it costs 4.7× C's time
  and loses real English.
- **`no_speech_prob` can't be the non-speech gate for the Egyptian model.** A gate at 0.6 skipped nothing.
- **Meetily's setup doesn't beat C.** It is slower, its cleanup empties almost nothing, and loops remain.

## Scores

"Clean" means loops collapsed and tags removed, as in task 1. Loop words count phrases of 1–4 words repeated
4+ times in a row. The captions have about 1260 words plus 176 tags. Memory is the process's peak.

| Run | Setup | CER | WER | CER clean | WER clean | Loop words / words | Time | × audio | Memory |
|---|---|---|---|---|---|---|---|---|---|
| Balanced (task 1) | web harness, whisper-small + base.en | 140.8% | 175.6% | 64.2% | 85.9% | 1715 / 2826 | 1443 s | 2.4 | 4.7 GB* |
| A | stock small, faster-whisper | 44.8% | 74.5% | 40.7% | 72.2% | 0 / 1071 | 406 s | 0.68 | 1086 MB |
| B | Egyptian | 51.1% | 79.1% | 49.1% | 78.2% | 67 / 1044 | 1311 s | 2.18 | 1068 MB |
| **C** | **Egyptian + limits** | **42.6%** | 75.6% | **39.7%** | 75.9% | **0 / 1208** | **177 s** | **0.29** | 1048 MB |
| D | as C, harness pieces forced to Arabic | 44.9% | 76.3% | 42.7% | 77.3% | 0 / 1305 | 825 s | 1.38 | 1006 MB |
| E | as D, gate at `no_speech_prob` 0.6 | same as D (gate skipped nothing) | | | | | | | |
| F, before cleanup | Meetily, stock small | 52.4% | 78.3% | 49.9% | 76.8% | 47 / 1046 | 589 s | 0.98 | 864 MB |
| F, after cleanup | | 52.4% | 78.8% | 49.7% | 76.9% | 10 / 981 | | | |
| G, before cleanup | Meetily, Egyptian | 50.6% | 81.5% | 43.4% | 73.2% | 327 / 1321 | 540 s | 0.90 | 863 MB |
| G, after cleanup | | 46.6% | 74.9% | 43.7% | 72.9% | 71 / 1037 | | | |

\* Peak across both of task 1's presets, measured differently.

CER per minute:

| Minute | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| A | 42 | 46 | 53 | 26 | 48 | 59 | 50 | 47 | 52 | 52 |
| B | 46 | 80 | 68 | 28 | 39 | 60 | 74 | 63 | 79 | 58 |
| C | 43 | 51 | 73 | **42** | 52 | 46 | 45 | 49 | 51 | 47 |
| D | 36 | 46 | 51 | 29 | 43 | 62 | 57 | 48 | 52 | 61 |
| G, after cleanup | 53 | 63 | 61 | 23 | 45 | 74 | 52 | 63 | 70 | 64 |

These are rough, because a segment counts toward the minute holding its midpoint and segments differ in length.

## What each comparison shows

- **A vs Balanced: the same general model drops from 140.8% to 44.8%, and takes 3.6× less time.** This doesn't
  isolate the runtime, as the task hoped: A also forces Arabic, uses VAD instead of diarized pieces, and has no
  English route, plus faster-whisper's default guards.
- **B vs A: the Egyptian model alone is worse here,** with 6 looping segments and 3× the time.
- **C vs B: the limits are what work.** Loops go from 67 words to 0 and time from 1311 s to 177 s. The speedup is
  probably fewer retries at higher temperatures, but retries weren't counted. `compression_ratio_threshold=2.4`
  is already the default, so B also had it; only `no_repeat_ngram_size` and `repetition_penalty` differ.
- **C vs A is close.** C is 2 points better on CER, A 1 point better on WER, and C has 2.3× the speed. That's a thin
  case for the Egyptian model on quality alone against automatic captions; `whisper-small-eg` had a clearer lead on
  MGB-3 (30.9% vs 39.6% CER, `eval/results/egyptian-asr-2026-10-30.md`).
- **Warning on C:** minute 3, the cleanest speech, goes from 28% (B) to 42%, with 112 words against the captions'
  137 and B's 146. That minute has rhymed, repetitive speech, so the limits may be cutting real text. This is
  one minute and wasn't investigated.

## The harness's own pieces (D, E)

All 142 Balanced pieces were recovered from the routing log, padded 0.2 s on both sides.

- **Loop risk from task 2:** no loops with the limits on, across all 142 pieces including the short ones. Forcing
  short clips to Arabic **without** the limits wasn't run, so limits should ship with any such change.
- **Cost:** 5.8 s per piece, 825 s in all, against C's 177 s, because every piece encodes a padded 30 s window.
  Clip-by-clip recognition is the expensive part.
- **Accuracy:** 44.9% CER, close to C's 42.6%, so cutting by the harness's pieces doesn't by itself hurt.

### `no_speech_prob`

`Dn` is an added diagnostic, D without the voice filter, because the filter removes a clip before it gets a
score. faster-whisper's own no-speech check was off for both. Figures are from `Dn`.

| Pieces | n | Median | Max | Above 0.6 |
|---|---|---|---|---|
| "Non-speech tag" (task 2) | 18 | 0.000 | 0.473 | 0 |
| Real English | 4 | 0.000 | <0.001 | 0 |
| Invented English | 47 | 0.000 | 0.005 | 0 |
| Labeled `ar` | 73 | 0.000 | <0.001 | 0 |

`eval/lab/no_speech_probe.py` checks that this is a real result and not a bug:

| | Egyptian model | Stock small |
|---|---|---|
| 3 s digital silence | 0.78 | 0.82 |
| 3 s white noise | 0.72 | 0.88 |
| 18 "non-speech" pieces: median, above 0.6 | 0.000, 0 | 0.444, 5 |
| 4 real English pieces: median, above 0.6 | 0.000, 0 | 0.464, 1 |

So the score works on pure silence and noise, but on real clips the Egyptian model is near 0 throughout, perhaps
because of its fine-tuning. **It can't be the gate for this model.** Stock small spreads more, but it also marked a
real English piece, and the rest of its pieces weren't scored. The voice filter isn't enough either: it removed 1 of 18.

### What D wrote

**Correction to task 2:** "non-speech tag" described what the English model wrote, not what's in the audio, so it
**overstated** non-speech. At least 7 of the 18 look like real Arabic speech that the English model turned into a tag,
because D's text matches the captions (marked below). For those a near-zero score is correct, so the table above
isn't a clean test on them. There's still no labeled set of real laughter and music, which a gate test needs.

| Start | Balanced wrote | D wrote | Matches captions? |
|---|---|---|---|
| 7.5 | (upbeat music) | nothing (voice filter); `Dn`: برافو | |
| 117.2 | [BLANK_AUDIO] | زي يعني | |
| 329.7 | (laughing) | آه حضرنا | |
| 342.9 | (upbeat music) | أيه يا أيه، آه آهآه آاه آه | |
| 361.5 | (laughing) | بابي | |
| 365.6 | [Music] | جي أزرف آه تتأيب أردني إيه أعرف عايزي | partly |
| 396.1 | (grunting) | أه أه أها أه آه أح | yes |
| 413.8 | (groaning) | أقول أه أه آه آها آه | yes |
| 417.3 | (man speaking in foreign language) | أه أه أها أه لا جراول إي إي و و إي تغنى | yes |
| 430.0 | >> [LAUGH] | أأأ أحسي دي | |
| 508.5 | (laughing) | آه التكسان | |
| 565.6 | [LAUGH] | آه ههه | |
| 588.6 | (speaking in foreign language) | لأ لا تخفف فتّ | yes |
| 590.2 | [inaudible] | الصياء | |
| 591.7 | [BLANK_AUDIO] | بس قال لنا لابس و | yes |
| 592.2 | (speaking in foreign language) | أنا لبس وبعا مش حاجزيًا | yes |
| 595.2 | (speaking in foreign language) | أنا ما ديش في أن الرئما بحاجة | yes |
| 596.2 | (speaking in foreign language) | بحضرة كولة | |

"Matches" is my reading of nearby captions. E wrote the same, since it skipped nothing.

Real English pieces under forced Arabic:

| Start | Balanced wrote | D wrote |
|---|---|---|
| 479.8 | Oh, and yes courses. Oh that course course… | آه ايوه انتي اس كورسة، هو ده كور س كور كور |
| 484.0 | night out. | نعم عارك |
| 484.5 | a 10. | أه أه للتاني نعم |
| 485.4 | Not out of 10. Not out of 10. | نعم نعم نام وردتان |

The first comes through as English written in Arabic letters, which does match the captions' style. The "9 out of
10" exchange is lost. Forcing Arabic does damage English, though on this video only for these few seconds.

## Meetily's setup (F, G)

### The 25-second split matters

The task's description didn't mention it, but Meetily's import path (`import.rs`, `common.rs`) cuts speech chunks over
25 s at the quietest point nearby. My first F and G runs lacked it, so I ported it and re-ran both.

| | Chunks, longest | F: CER, words | G: CER, words (before cleanup) |
|---|---|---|---|
| Without split | 20, 125 s | 70.7%, 545 | 61.5%, 745 |
| With split, as Meetily does | 33, 28 s | 52.4%, 1046 | 50.6%, 1321 |

Without it, whisper.cpp lost much of the long chunks: a 74 s chunk produced 22 words. Why wasn't investigated.
**Any design that hands long VAD chunks to whisper.cpp needs this split.**

### What the cleanup does

| | F | G |
|---|---|---|
| Chunks emptied, of 33 | 0 | 1 |
| Chunks changed | 10 | 13 |
| Words removed from kept chunks | 65 | 174 |
| Loop words before → after | 47 → 10 | 327 → 71 |
| CER before → after | 52.4% → 52.4% | 50.6% → 46.6% |

- **Emptied:** only one kind occurred, "few distinct characters": 469.7 s, 2.6 s long, in G, "آه آه آه آه…". The junk
  phrases are English and never matched here, and the repetition-ratio rule never fired.
- **Word repeats collapsed:** at 308.8 s in G, a chunk goes from 99 words to 34.
- **Loops survive:** it makes one pass, removing one copy of each immediately repeated phrase, so a long loop only halves.
  After cleanup G still has runs like "قولت آه قولت آه قولت آه" (419.7 s).

So decoding settings alone leave loops in G, with no equivalent of C's limits, and the cleanup only reduces them. It
can also remove real repeats, since "آه آه" in Egyptian speech may be what was said.

### How faithful these runs are

- **Runtime: whisper.cpp through `pywhispercpp` 1.5.1, CPU. Vulkan was not tested.** I chose this because `whisper-cli`
  doesn't expose patience or max initial timestamp, which Meetily sets. The GPUs (Intel HD 520, GeForce 940MX) weren't
  tried, so these times are CPU only.
- **VAD:** Silero as bundled with faster-whisper, with Meetily's settings. Meetily uses `silero_rs`, so chunk edges may differ.
- **Ported from source beyond the task's list:** the 25 s split, skipping chunks under 0.1 s, `max_len=200`, token
  timestamps, and counting bytes in the "few characters" rule. `temperature_inc` stays at the default because Meetily
  doesn't set it. `eval/lab/meetily_runs.py test` checks the cleanup and split ports.

## What to try next

Proposals for the cloud session; nothing here has been built into the app.

1. Use C's limits as the baseline for any Whisper path. Check whether transformers.js and WhisperKit expose the same
   options, which wasn't checked here.
2. Find out what the limits cost on repetitive speech (minute 3), for example with `no_repeat_ngram_size` alone or at 4–5.
3. Transcribe VAD chunks rather than one clip per utterance where possible, given the 4.7× cost, and keep chunks under 25–30 s.
4. Don't use `no_speech_prob` as the gate on the Egyptian model. A real test needs hand-labeled laughter and music.
5. Take from Meetily the 25 s split, not the cleanup, at least without further testing.

## Limits

- One video against automatic captions, in fast, noisy, comedic speech. The ranking of A and C could change on real meetings
  or with hand-made captions.
- One run of each, on a laptop that may have been in use for other things, with small downloads during B, so treat times as rough.
  Times exclude model loading except where noted; F's and G's include VAD (2 s).
- `tokenizer.json` for the Egyptian CTranslate2 model was generated from its own tokenizer files, because the repo has none.
- CTranslate2 and GGML versions of the Egyptian model weren't checked against each other, and F and G differ from C in
  several ways at once, so they don't isolate the runtime.
