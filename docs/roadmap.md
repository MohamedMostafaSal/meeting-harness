# Roadmap

Work agreed with the maintainer, in order. Items marked **waiting** start only after the lab results
they depend on are in (see [lab-tasks.md](lab-tasks.md)); nothing here is being built yet.

## Waiting on lab task 3 (faster-whisper and Meetily's settings)

1. **Decoding safeguards from Meetily.** Adopt whichever of Meetily's measures task 3 shows actually
   help (runs F and G): blocking blank and non-speech output, the no-speech threshold (0.55), the
   entropy and log-probability limits, and its post-decode cleanup (junk phrases, collapsing repeated
   words and phrases, dropping text that is mostly repeats). Cleanup deletes text, so adopt it only
   where the before/after scores show it removes loops rather than real speech; anything it removes
   is logged and marked, not silently dropped.
2. **Recognizer and runtime.** Pick the speech model and runtime per platform from task 3 (Egyptian
   model vs general, whisper.cpp vs faster-whisper vs the current ones).
3. **Routing fix.** Stop trusting language ID on clips under about 2 s (use neighbouring speech or the
   meeting's main language), with an optional Arabic prior; tested together with the safeguards,
   because short clips sent to Arabic can loop (lab task 2).
4. **Non-speech gate.** Drop laughter, music and silence before recognition, using Whisper's own
   no-speech probability if runs D and E show it separates them.
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
