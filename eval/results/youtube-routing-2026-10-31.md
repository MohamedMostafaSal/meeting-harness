# Why Arabic went to the English model, and why 33 speakers (2026-10-31)

Lab task 2, from the Balanced and Light `harness.json` of task 1 and `yt/cues.json`. No new model runs,
so the effect of any fix on CER is **not measured** here.

**Result.**

- **Routing:** the English route is mostly very short clips, including laughter and music, not English.
  Only 4 `en` segments in either preset are real English. Language ID is confident and wrong on these
  clips, so a stricter threshold doesn't fix it; ignoring language ID under 2 s does most of the work.
- **Loops:** routing doesn't cause them. Nearly all are on the Arabic path, so sending short clips to
  Arabic could add loops. Test that together with any routing fix.
- **Speakers:** the 33 is mostly many tiny clusters: 25 labels have under 10 s of speech and hold 19% of
  labeled speech. Whether the bigger labels are also split voices can't be told from these files.

## Routing

The full lists are in `eval/lab/routing-en-segments-balanced-2026-10-31.md` and
`-light-2026-10-31.md`: start, length, language-ID guesses, route, whole utterance or re-check window,
kind, harness text. Captions are left out of them to keep them off the public repo;
`eval/lab/routing_stats.mjs` prints them side by side on a machine that has `yt/`.

| Segments labeled `en` | Balanced | Light |
|---|---|---|
| Total (of all segments) | 69 of 142 | 62 of 138 |
| Real English | 4 (7.7 s) | 4 (7.7 s) |
| Only a non-speech tag, e.g. `(laughing)`, `[BLANK_AUDIO]` | 18 (21 s) | 19 (30 s) |
| Invented English on Arabic speech or noise | 47 (62 s) | 39 (48 s) |
| Median length (`ar` segments: about 2.8 s) | 0.9 s | 0.9 s |
| Under 1 s / under 2 s | 38 / 56 | 34 / 49 |

How these were counted:

- **Real English is a judgment made by reading the captions.** The four are one exchange at 479.8–487.5 s
  (caption "كورس", "9 اور 10": "course", "9 out of 10"). The start times are listed in the script.
- **The other two kinds are a rule:** text that is only tags is "non-speech", and everything else is
  "invented". "Invented" therefore includes names heard as English ("Wigs!" for Wegz) and short sounds
  like "Yeah" or "Hi", some of which may really have been said. The captions can't settle this because
  they write everything in Arabic script.
- **Real English also stays on the Arabic path.** Captions in minute 5 have "اي كولد ذا موست ايبيك" ("I
  call the most epic"). Language ID runs on whole utterances, so English inside mostly Arabic speech
  isn't separated unless the utterance is first marked ambiguous.

### Short clips are the problem

| Piece length | Balanced: en / ar / fallback | % en | Light: en / ar / fallback | % en |
|---|---|---|---|---|
| Under 1 s | 31 / 5 / 4 | 78% | 28 / 3 / 9 | 70% |
| 1–2 s | 19 / 9 / 5 | 58% | 12 / 12 / 8 | 38% |
| 2–4 s | 9 / 20 / 6 | 26% | 8 / 16 / 7 | 26% |
| 4–8 s | 2 / 20 / 0 | 9% | 1 / 22 / 0 | 4% |
| Over 8 s | 1 / 11 / 0 | 8% | 1 / 11 / 0 | 8% |

Most of these were whole-utterance calls: only 4 of Balanced's 62 pieces sent to the English specialist,
and 1 of Light's 50, came from a re-check window. Language ID isn't hesitating on these clips:

| LID confidence, pieces sent to the English specialist | Balanced (62) | Light (50) |
|---|---|---|
| Median | 0.97 | 0.97 |
| At least 0.90 | 48 | 36 |
| At least 0.95 | 41 | 29 |
| At least 0.99 | 20 | 14 |

A likely reason, from the code but not tested: `identify` in `web/models.js` keeps only the allowed
languages and rescales them, so the confidence only compares `en` with `ar`. A burst of laughter has no
"neither" option and can still score 0.99.

### Would a stricter threshold or an Arabic prior fix it?

Replayed from the logged confidences (2 decimals). The table counts the segments that would still go to
the English specialist, out of 58 wrong and 4 real in Balanced, and 47 wrong and 3 real in Light (Light's
fourth real segment went through the fallback). The prior reweights the two guesses, and a segment stays
English if it still reaches the current 0.75 threshold.

| Rule | Balanced: wrong left | real kept | Light: wrong left | real kept |
|---|---|---|---|---|
| Threshold 0.90 | 44 | 4 | 34 | 2 |
| Threshold 0.95 | 37 | 4 | 27 | 2 |
| Threshold 0.99 | 17 | 3 | 12 | 2 |
| Arabic prior 0.90 | 28 | 4 | 23 | 2 |
| Arabic prior 0.99 | 7 | 3 | 3 | 1 |
| Under 2 s never English | 10 | 2 | 7 | 2 |
| Under 2 s never English + prior 0.90 | 4 | 2 | 2 | 1 |

- **A stricter threshold: no.** It leaves many wrong segments even at 0.99. Those it removes mostly go to
  the multilingual fallback, which has no fixed language and ended in `en` 7 of 15 times in Balanced and
  12 of 24 in Light. Utterances of 4 s or more are re-checked in 2 s windows first, which are short too.
- **An Arabic prior: partly.** 0.99 removes most of the wrong segments but costs real English, and it
  suits only a meeting known to be mostly Arabic.
- **A length rule does the most, at a known cost.** Combined with a prior of 0.90 it removes 54 of 58 in
  Balanced and 45 of 47 in Light. It loses 2 of the real segments in each, and would lose real short
  English replies in a truly mixed meeting.
- **Non-speech is a separate problem.** Laughter and music should ideally produce no text at all, not an
  Arabic transcription instead of an English one.

## Loops vs routing

| Loop segments | Balanced | Light |
|---|---|---|
| Total | 10 | 25 |
| Labeled `ar` | 9 (80 s) | 24 (134 s) |
| Labeled `en` | 1 (4.2 s) | 1 (4.2 s) |
| Route: Arabic specialist / fallback / English specialist | 7 / 2 / 1 | 20 / 4 / 1 |
| Lengths of the `ar` ones | 1.9–18.3 s | 0.5–18.4 s |

The one `en` loop is the real English "course course course". The long Arabic loops had confident language
ID: 295.4–310.3 s scored `ar` 0.97 in Balanced and 1.00 in Light, and 489.3–507.5 s scored 0.98 and 1.00.
So **the Arabic model is looping on correctly routed audio**, and routing fixes won't remove these.

**Risk for any routing fix:** clips of about 2 s or less already loop on the Arabic path (for example 1.9 s
in Balanced, and 0.5–1.1 s in Light). Sending many more short clips there could add loops while removing
invented English. A non-speech check and decoding limits (task 4) should be tested alongside it.

## Speakers

The voice models are the same in both presets, so the speaker results match apart from how segments were
merged. Figures below are Balanced. The JSON holds merged segments, not the 169 raw turns, so counts are
segments.

| Label | Segments | Speech | First–last seen |
|---|---|---|---|
| S2 | 24 | 185.7 s | 10–539 s |
| S5 | 17 | 48.8 s | 108–598 s |
| S11 | 3 | 33.1 s | 162–209 s |
| S1 | 7 | 26.3 s | 0–589 s |
| S14 | 5 | 15.8 s | 258–522 s |
| S18 | 5 | 14.2 s | 333–573 s |
| S26 | 2 | 13.5 s | 431–565 s |
| S16 | 5 | 12.9 s | 327–578 s |
| 25 others, each under 10 s (S17 highest, at 8.8 s) | 32 | 80.3 s | |
| No label (42 turns) | 42 | 29.0 s | |

| | |
|---|---|
| Labels | 33 |
| Under 10 s / under 5 s / under 2 s | 25 / 19 / 11 |
| Labels with one segment | 20 (21 in Light) |
| Share of labeled speech: top 3 / top 5 / the 25 small ones | 62% / 72% / 19% |
| Small labels' segments that are `en` (mostly short clips, per above) | 11 of 32 |
| Small labels' segments marked overlapping | 1 of 32 |

- **Mostly tiny clusters.** Most labels are one short segment. Fingerprints are allowed from 1.0 s
  (`minEmbeddingDuration`), and 11 labels have under 2 s of speech in total. Fingerprints that short are
  likely noisy against a strict 0.86 clustering threshold, though that isn't tested here.
- **Overlap isn't the cause.** The code doesn't let overlapped turns start clusters, and only 1 of 32
  small-label segments is marked overlapping.
- **Laughter and noise may contribute.** A third of small-label segments are in the `en` group above,
  but there is no direct non-speech measure for all segments.
- **Few voices split in many: not answered.** Nine labels recur across more than a minute, which fits one
  person getting several labels, but the show does have several real speakers, and sketches. Fingerprints
  aren't saved in `harness.json`, and there is no speaker ground truth. Answering it needs a re-run with
  the pipeline's `debug` voice-similarity table.

## What to try next

Nothing here has been run; these are proposals for the cloud session to decide on.

1. Stop trusting language ID below about 2 s: use the neighboring speech or the meeting's main language.
2. Add a non-speech check before recognition, so laughter and music produce nothing.
3. Test 1 and 2 together with task 4's decoding limits, because of the loop risk above.
4. Leave out a stricter threshold. Keep an Arabic prior optional, for meetings known to be mostly Arabic.
5. Require longer fingerprints before starting a new speaker, then re-run with `debug` to see what merges.
