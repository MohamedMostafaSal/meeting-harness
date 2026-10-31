# Roadmap

Work agreed with the maintainer, in order. Items marked **waiting** start only after the lab results
they depend on are in (see [lab-tasks.md](lab-tasks.md)); nothing here is being built yet.

## Findings from lab task 3 ([results](../eval/results/faster-whisper-2026-10-31.md))

- Repetition limits during decoding (`no_repeat_ngram_size`, `repetition_penalty`) removed every loop and cut
  time 7×. transformers.js supports both; WhisperKit doesn't have them but takes custom logits filters
  (`WhisperKitConfig.logitsFilters`), so the app can add them in Swift.
- Recognize speech in VAD chunks of at most about 25 s, not one clip per speaker turn: per-turn clips cost
  4.7× (each pads to a 30 s window). Speaker turns are then laid over the text by time.
- Meetily's 25 s split is worth taking; its text cleanup is not (it halves loops at best and can delete real
  repeats like "آه آه").
- Whisper's no-speech probability can't gate non-speech with the Egyptian model (near 0 on everything real).

## Waiting on lab task 5 (tuning the limits, human transcripts)

1. **Decoding safeguards.** Repetition limits during decoding on every Whisper path (values from task 5),
   Meetily's 25 s split, blank and non-speech token suppression. Not Meetily's text cleanup.
2. **Recognizer and runtime.** Egyptian model vs stock `small` decided on human transcripts (task 5b);
   VAD-chunk recognition with speaker turns laid over by time.
3. **Routing fix.** Stop trusting language ID on clips under about 2 s (use neighbouring speech or the
   meeting's main language), with an optional Arabic prior; tested together with the safeguards,
   because short clips sent to Arabic can loop (lab task 2).
4. **Non-speech gate.** Drop laughter, music and silence before recognition. Whisper's no-speech
   probability doesn't work for the Egyptian model (task 3); needs another signal and a hand-labeled test.
5. **Speakers.** Require longer fingerprints before starting a new speaker; re-run with the debug
   similarity table to check the 33-speaker result (lab task 2).

## After that

6. **Hard memory budgets and processing gates** ([design.md](design.md#hard-budgets-and-gates-planned-after-the-lab-results)),
   sized from the lab's speed and memory numbers.
7. **The harness control loop:** check each result, retry or escalate within a budget, carry meeting
   context (speaker language priors, a word list), and agreement between models on uncertain parts.
8. **Live captions** rebuilt on whatever task 3 picks; then the deferred lab task 4 measures them.

## Open decisions

- Fully local, or opt-in cloud recognition for the final transcript or live captions.
