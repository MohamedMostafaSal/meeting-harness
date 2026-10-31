# YouTube test set and the web harness on it (2026-10-31)

Lab task 1. The web harness (the batch pipeline, not live captions) on the first 10 minutes of
"السبت الممتاز | نجم الجيل | مع ويجز | THE GOATS" (https://youtu.be/dkeu6gi3mAc), on the maintainer's
laptop: Intel i7-6500U (2 cores, 4 threads), 16 GB RAM, CPU only, Node 24.

**Result: on this audio, repetition loops dominate the score.** Both presets go above 100% CER because
they write more text than was said: 61% of Balanced's words and 87% of Light's are loop repeats. With
the loops collapsed, CER is about 65–70%. The loops show up here in the batch pipeline, so they don't
come only from the live re-transcription in `web/live.js`.

## Test set (`yt/info.json`)

| | |
|---|---|
| Video length | 2702 s (first 600 s used) |
| Captions | **automatic** Arabic, 257 cues (the only uploaded track is English) |
| Audio | 16 kHz mono WAV |

The captions are YouTube's own speech recognition, so these scores measure **agreement with another
model, not accuracy**. They also contain `>>` and tags like `[ضحك]` (176 in all), and errors of their
own. The audio is a comedy talk show: fast Egyptian Arabic, overlapping voices, laughter, music and
some singing. That is harder than most meetings, so don't read these numbers as meeting accuracy.

## Scores (`yt/score.md`)

| | Balanced (whisper-small + whisper-base.en) | Light (whisper-base + whisper-tiny.en) |
|---|---|---|
| CER vs captions | **140.8%** | **275.8%** |
| WER vs captions | 175.6% | 354.3% |
| Speakers found | 33 | 33 |
| Speech by language | ar 06:08, en 01:30 | ar 06:13, en 01:25 |
| Segments marked uncertain | 20 of 142 | 33 of 138 |
| Gaps | 0 | 0 |
| Processing time | 1443 s (2.4× the audio) | 760 s (1.27× the audio) |
| of which language ID | 612 s | 193 s |
| of which transcription | 735 s | 469 s |

`score.md` labels the time "on a CI CPU"; these runs were on the laptop. The timings include a small
memory logger running alongside. Peak memory for the Node process across both runs was 4.7 GB, and
the lowest free system memory was 1.8 GB.

CER by minute:

| Minute | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| Balanced | 43% | 63% | 130% | 25% | 127% | 343% | 148% | 90% | 241% | 166% |
| Light | 54% | 238% | 215% | 30% | 131% | 634% | 443% | 155% | 309% | 479% |

Minute 3 is the best for both. It is mostly one person speaking at length, partly in formal Arabic.

## How much of it is loops

Added for this report, not in `score.md`: `eval/lab/loop_stats.mjs` collapses any phrase of 1–4 words
repeated 4+ times in a row inside a segment, then rescores. The last row also removes `>>`, bracketed
tags and `BLANK_AUDIO` from both sides.

| | Balanced | Light |
|---|---|---|
| Words written (captions: 1436 tokens) | 2826 | 5323 |
| Words that are loop repeats | 1715 (61%) | 4626 (87%) |
| Segments with a loop | 10 | 25 |
| Of those, marked uncertain | 9 | 24 |
| CER, loops collapsed | 65.5% | 70.2% |
| CER, loops collapsed and tags removed | 64.2% | 68.0% |
| WER, loops collapsed and tags removed | 85.9% | 90.9% |

- **Loops are not limited to short audio.** Some come from clips of about 2 s (a 1.9 s segment
  produced 221 repeated words), others from 15–18 s segments. Loop segments have a median length of
  7.1 s in Balanced and 3.5 s in Light.
- **The guard mostly notices them, but they stay in the output.** `hallucinationReason` flagged nearly
  all of them ("repeats itself"), yet flagged text stays in the transcript and in these scores. A
  transcript reader sees the loops marked uncertain, not removed.
- **Decoding isn't stopped early.** A short clip can run on for hundreds of words, which also costs
  processing time. Whether a repetition guard during decoding fixes this is untested here; it belongs
  to brief step 3.

## Typical errors (`yt/side-by-side.md`, Balanced)

**1. Plain transcription: close by ear, wrong in spelling and word boundaries (03:00, the best minute).**

> Captions: يا خفيف الروح ثقيل الاثر قليل القول كثير الخبر
>
> Harness: يا خفيف الروح طقيل الأثر قليل القول كثير الخبر

> Captions: واحب اسمعها لكم واسمعها ضيفي لاول مره
>
> Harness: وحب أسمعها لكم وسماها الضفة لأول مرة

**2. Loops (05:00, the worst minute).** A 15 s segment comes out as 178 words, nearly all one
repeated phrase; nothing like it is in the captions.

> Captions: طب يا اسطوره احنا النهارده عاملين حلقه
>
> Harness: لا أستطيع أن أستطيع أن أستطيع أن أستطيع أن أستطيع أن …

**3. Arabic speech apparently routed to the English model, which invents English (02:00; matched by
minute, not phrase by phrase).**

> Captions: ايه يا ريس؟ ايه الاخبار؟ … جاهز يلا بينا نصور
>
> Harness: Bad ice. Good night. … You're gonna let me done so? Yeah, you gotta go there.

## What this suggests

These are observations from one video, against automatic captions.

- **Language routing looks wrong.** About 1:30 of speech went to the English model, and 69 of
  Balanced's 142 segments are labeled `en`, while the captions read as almost entirely Arabic. The
  video's few English phrases can't account for that. No per-segment check was done.
- **33 speakers looks too high** for this show, in both presets, though there is no speaker ground
  truth to confirm it.
- **Language ID is expensive.** In Balanced it takes 612 s, nearly as long as transcription.

## Running this on Windows

`eval/youtube_test.sh` doesn't run as written on this laptop, so the steps were run by hand:

- `python3` is the Microsoft Store stub, and `ffmpeg` and `zip` were missing. `yt-dlp` and
  `imageio-ffmpeg` went into a temporary virtual environment.
- `youtube_fetch.py` crashes on the Arabic title and file writes without `PYTHONUTF8=1`.
- transformers.js cached a truncated `whisper-base.en` decoder (26.7 of 53.7 MB) without noticing. The
  run failed 27 minutes in, at the English model, with "system error 13" naming the encoder, which was
  fine. Replacing the file fixed it, and all four Whisper models then matched their published hashes.
- Claude Code's low-memory protection stopped two background runs, once only 2 minutes 15 seconds in
  with 4.4 GB free 10 seconds earlier. The third, identical run finished. These stops are not a
  measure of the harness's memory use.
- `yt-testset.zip` was not built, since `zip` was missing and this task doesn't use it. `yt/` stays
  on the laptop and out of git.
