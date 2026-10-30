# Contributing to meeting-harness

Thanks for helping. The project is a proof of concept, so the most valuable contributions right now are evidence about what works on real meetings.

## Most useful right now

1. **Transcription problems.** Run a meeting through the [web prototype](https://mohamedmostafasal.github.io/meeting-harness/) and open an issue with the *Routing decisions* log, the model preset, and what went wrong. The log shows which step made the mistake.
2. **Reference recordings.** Short Egyptian Arabic, English and mixed meetings with a hand-checked transcript and speaker labels. Only share recordings where **everyone recorded agreed**.
3. **Small on-device models** that are good at one job, especially Egyptian Arabic speech-to-text.

## Principles for changes

- **One model, one job.** A model sits behind a narrow contract (typed input, typed output, a confidence). See `Sources/HarnessCore/Pillars/`.
- **Models propose, code decides.** Routing, thresholds, merging and fallbacks are deterministic and unit-tested, with their numbers in a policy struct, not scattered through the code.
- **Measure every stage.** A change that claims better accuracy should come with numbers (WER/CER for words, speaker errors for who-spoke) on recordings anyone can check.
- **Nothing is dropped silently.** Speech the harness can't handle becomes a gap or an uncertain segment.

## Running the tests

```sh
swift test                      # Swift core (macOS or Linux, Swift 5.9+)
cd web && npm install && npm test   # web prototype logic
npm run smoke                   # web prototype with real models (needs internet, ~200 MB)
```

CI runs all three on every push.

## Adding a speech-to-text specialist (web prototype)

Add an entry to `recognizersFor` in `web/models.js` with its `languages` and, for dialects, a `variant`. The router's `preferredVariants` policy picks it; no routing code changes. In Swift, conform to `SpeechRecognizer` and describe it with a `RecognizerDescriptor`.

## Pull requests

Keep them focused, include tests for deterministic logic, and describe how you checked the result. By contributing you agree that your work is released under the [MIT license](LICENSE).
