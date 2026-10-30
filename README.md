# meeting-harness

**Meeting transcription built from small specialist models and deterministic code, with no single giant model.**

Most meeting transcription products send the whole recording through one large model and hope it handles everything: several speakers, several languages, cross-talk, jargon, silence. When it fails, you can't see where it failed and you can't fix that one part.

`meeting-harness` takes the opposite approach:

> **Break the problem into narrow questions. Send each one to the smallest model that answers it well. Let deterministic code handle routing, merging and decisions.**

The intelligence lives in the **structure**: the pipeline, the routing conditions and the confidence gates. The models are replaceable parts.

> Status: **vision / design stage.** No code yet. This README is the working spec.

**Platform: a phone app first.** The whole pipeline is designed to run **on the device**. Using the cloud is optional and only happens when the user agrees.

---

## The pain points we're solving

| Pain point in existing tools | How the harness addresses it |
|---|---|
| Assumes **one language per meeting** | Language is identified **per segment**, and each segment is routed to an ASR model suited to that language. |
| **Code-switching** (e.g. Arabic ↔ English mid-conversation) breaks transcription | Short-window language ID plus re-segmentation at language boundaries. |
| **Overlapping speech** is dropped or merged into one speaker | A dedicated overlap detector. Overlapped regions are separated or flagged, never silently merged. |
| Speaker labels **drift** ("Speaker 2" becomes "Speaker 3" halfway through) | Speaker identity is a deterministic registry of voice embeddings, with optional enrollment of known voices. |
| **Hallucinated text** during silence or noise | No audio reaches ASR without passing voice activity detection (VAD). Low-confidence output is gated, not printed. |
| Bad with **names, acronyms, domain jargon** | A per-meeting glossary applied as ASR biasing and deterministic post-correction. |
| **Black box**: no idea how reliable a line is | Every word or segment carries its confidence and the name of the model that produced it. |
| **Expensive / cloud-only** | Small, quantized models run on the phone's neural engine. Audio never has to leave the device. |
| **Kills battery / phone gets hot** | Routing takes battery, heat and charging state into account. The heavy work waits until the phone is charging or idle. |
| **Huge app download** | Language packs: users only download the speech-to-text specialists for the languages they actually speak. |

---

## Mobile-first design

Running on a phone is the strongest argument for the small-specialist approach. A single giant model doesn't fit in a phone's memory, battery or heat limits. A set of 20–200 MB specialists does.

### Draft live, refine later

| | **Live pass** (during the meeting) | **Refine pass** (after the meeting) |
|---|---|---|
| Goal | Live captions with low delay | Most accurate final transcript |
| Runs | VAD → language ID → small streaming speech-to-text | Full diarization, overlap handling, language ID re-run, larger speech-to-text, punctuation |
| When | Always, within a strict compute budget | When the policy allows: charging, phone cool, app idle, or the user taps "Refine now" |
| Output | Draft transcript, marked as draft | Replaces the draft segment by segment, with a version history |

The same router drives both passes. Only the rules and budgets differ.

### Device-aware routing

The router (D5) uses **device state** as conditions, alongside model confidence:

```
if thermal >= serious        → live pass only, pause refinement
if battery < 20% && !charging → smallest ASR tier, defer diarization
if charging && idle           → run the refine pass on the queued meetings
if segment conf < τ && user allowed cloud && on Wi-Fi → escalate this segment only
```

### Model tiers and language packs

- Each AI pillar comes in tiers (**tiny / small / base**), quantized (int8 / int4) for the phone's neural hardware.
- The **core pack** ships with the app: VAD, language ID, speaker embeddings, punctuation.
- **Language packs** are downloaded on demand. Each is one speech-to-text specialist (plus an optional larger refine tier) for one language.
- The router can only route to packs that are installed. If a language is detected and its pack is missing, the segment goes to the multilingual fallback and the user is offered the download.

### Phone-specific realities

- **One mic in the middle of the table.** No mic per person, so diarization depends on the models. The phone owner's voice can be **enrolled once** during onboarding, which anchors the speaker registry.
- **Background recording.** On iOS this uses the background audio mode. On Android it needs a foreground service. Recording must survive the screen locking and recover from interruptions such as incoming calls.
- **Storage.** Audio is compressed (Opus) and encrypted at rest. The user decides how long raw audio is kept after the transcript is final.
- **Consent.** Recording laws differ by country. The app makes it easy to tell people they're being recorded. Phone calls are out of scope: iOS doesn't allow recording calls, and many places have stricter laws for them.

### Runtime stack (to validate)

- **Shared core** (the deterministic harness: router, registry, merge, schema) written once in a portable language such as **Rust or C++** and used by both platforms.
- **Model runtimes:** Core ML / Apple Neural Engine on iOS. LiteRT (TFLite), NNAPI or Qualcomm QNN on Android. ONNX Runtime Mobile, ExecuTorch or whisper.cpp as cross-platform options.
- **Native UI shells** (Swift / Kotlin) or one cross-platform UI layer. See open questions.

---

## Core principles

1. **One model, one job.** Every model has a narrow contract: typed input, typed output, a confidence score. If it can't fill the contract, it's the wrong model.
2. **Models propose, code decides.** Routing, thresholds, merging, retries and fallbacks are deterministic, testable and explainable.
3. **Everything is swappable.** Each AI pillar is an interface. A better Arabic ASR model, or a faster diarizer, can be dropped in without touching the rest.
4. **Escalate, don't default to big.** Start with the smallest capable model. Only send a segment to a heavier model when a deterministic condition says so (low confidence, unknown language, heavy overlap).
5. **Measure every stage.** Each pillar has its own metric, so we always know *which* stage is losing accuracy.

---

## Architecture at a glance

```
            ┌──────────────────────────────────────────────────────────┐
 audio ───► │ [D] Ingest & normalize (resample, mono/multichannel, gain) │
            └──────────────────────────────┬───────────────────────────┘
                                           ▼
                               [M] Voice Activity Detection
                                           │  speech regions only
                                           ▼
                 ┌─────────────────────────┴─────────────────────────┐
                 ▼                                                   ▼
     [M] Speaker segmentation                           [M] Overlap detection
     + [M] speaker embeddings                                        │
                 │                                                   ▼
                 ▼                                     [M] Source separation
     [D] Clustering + speaker registry                     (only if overlap)
                 └─────────────────────────┬─────────────────────────┘
                                           ▼
                        [D] Segment builder (who, when, overlap flag)
                                           ▼
                            [M] Spoken Language ID (per segment)
                                           ▼
            ┌──────────────── [D] ROUTER (conditions & policies) ───────────────┐
            │  lang=ar → ASR-ar   lang=en → ASR-en   unknown/low-conf → ASR-multi │
            │  confidence < τ → escalate to heavier model / mark as uncertain    │
            └───────────────────────────────┬───────────────────────────────────┘
                                            ▼
                         [M] ASR specialists (per language / domain)
                                            ▼
             [D] Alignment & merge (words ↔ speakers ↔ timeline)
                                            ▼
     [M] Punctuation & casing  →  [D] Inverse text normalization + glossary fixes
                                            ▼
                     [D] Transcript store (canonical JSON schema)
                                            ▼
          [M] Optional understanding layer: summary, action items, decisions
                                            ▼
                     [D] Exports: JSON · SRT · VTT · Markdown · DOCX
```

`[M]` = needs an AI model · `[D]` = deterministic, no model

---

## Pillars that need AI models

Every pillar has one narrow job. The candidate models listed are *starting points to benchmark*, not commitments.

| # | Pillar | Job (the contract) | Why it needs a model | Candidates to evaluate |
|---|---|---|---|---|
| M1 | **Voice Activity Detection** | audio → speech / non-speech regions | Telling speech from noise, music and breathing is perceptual. | Silero VAD, pyannote VAD |
| M2 | **Speaker segmentation** | audio → speaker-change points | Detecting a voice change is perceptual. | pyannote segmentation |
| M3 | **Speaker embeddings** | speech segment → voice vector | Turns "what a voice sounds like" into numbers. | ECAPA-TDNN, WeSpeaker, TitaNet |
| M4 | **Overlap detection** | audio → regions where 2+ people speak | Perceptual; the main cause of lost words. | pyannote OSD |
| M5 | **Source separation** *(conditional)* | overlapped audio → one stream per speaker | Only runs on flagged overlap regions. | SepFormer, MossFormer |
| M6 | **Spoken Language ID** | segment → language + confidence | Needed for routing and for code-switching. | VoxLingua107 ECAPA, Whisper LID head, MMS-LID |
| M7 | **ASR specialists** | segment + language → words + timestamps + confidence | The core speech-to-text step, one model per language or family. | language-specific Whisper fine-tunes, Parakeet / Canary, MMS, Moonshine |
| M8 | **Punctuation & casing** | raw word stream → punctuated sentences | Sentence boundaries depend on meaning. | small punctuation-restoration models |
| M9 | **Understanding layer** *(optional, last)* | final transcript → summary, action items, decisions | Requires language understanding. Runs on clean text, never raw audio. | small instruction-tuned LLMs with structured (JSON) output |

**Rule:** no AI pillar talks to another AI pillar directly. Everything passes through deterministic code in between.

---

## Pillars that are deterministic (no models)

This is the "harness" itself, and it's where most of the product value is.

| # | Pillar | Responsibility |
|---|---|---|
| D1 | **Ingest & normalization** | Decode any format (ffmpeg), resample, handle mono and multichannel (one mic per person makes diarization trivial), normalize loudness. |
| D2 | **Chunking & streaming buffer** | Fixed and overlapping windows for batch and live modes; handles back-pressure and latency budgets. |
| D3 | **Clustering & speaker registry** | Clusters embeddings into speakers (agglomerative / spectral). Keeps speaker IDs stable over time; matches enrolled voices by cosine similarity. |
| D4 | **Segment builder** | Combines VAD, segmentation and overlap output into clean segments: `{start, end, speaker, overlap}`. |
| D5 | **Router / policy engine** | The brain. Rules like *"lang = X with conf ≥ τ → ASR-X; else → multilingual ASR"*, *"overlap → separation first"*, *"ASR conf < τ → escalate or flag"*. Configurable, logged, unit-testable. |
| D6 | **Alignment & merge** | Matches ASR word timestamps to speaker turns, resolves boundary conflicts, re-joins split segments, orders everything on one timeline. |
| D7 | **Text normalization & glossary** | Inverse text normalization ("twenty five percent" → "25%") using grammar rules; per-meeting glossary and name correction. |
| D8 | **Confidence gating & fallbacks** | Applies thresholds, retry/escalation budgets and "uncertain" markers. Stops hallucinated text from reaching the transcript. |
| D9 | **Transcript schema & store** | One canonical, versioned JSON format: words, speakers, languages, confidences, provenance (which model produced what). |
| D10 | **Exporters** | JSON, SRT, VTT, Markdown, DOCX, all rendered from the canonical schema. |
| D11 | **Evaluation harness** | Per-pillar metrics: WER/CER (ASR), DER (diarization), LID accuracy, overlap recall, latency, cost. Regression tests on reference meetings. |
| D12 | **Model registry & runtime** | Declares the available models, their contracts, tiers, memory/hardware needs and versions; loads and unloads them lazily so they fit in phone memory. |
| D13 | **Device state monitor** | Exposes battery, charging, temperature, memory pressure and network to the router as plain conditions. |
| D14 | **Pack manager** | Downloads, verifies, updates and removes language/model packs; tells the router what is installed. |
| D15 | **Job scheduler** | Queues refine-pass work and runs it when device policy allows (charging, idle, cool). Resumable if interrupted. |

---

## How a segment flows (example)

```
00:12.4–00:15.1 | VAD: speech | speaker: S2 (registry match: "Sara", 0.91)
                | overlap: no
                | LID: ar 0.62, en 0.35        ← ambiguous → likely code-switch
ROUTER          | rule: LID conf < 0.75 → split into ~1s windows, re-run LID
                | → [12.4–13.9] ar 0.94 → ASR-ar
                | → [13.9–15.1] en 0.97 → ASR-en
MERGE           | words joined on one timeline, speaker S2 kept
OUTPUT          | Sara: "خلينا نبدأ بالـ quarterly review"
```

---

## Open questions (to settle together)

- **iOS, Android, or both at launch?** This affects which runtimes we benchmark first.
- **UI layer:** native (Swift + Kotlin) or cross-platform (Flutter / React Native / Kotlin Multiplatform) on top of the shared core?
- **Cloud escalation:** never, opt-in per meeting, or opt-in in settings?
- **Is live captioning a v1 feature,** or is v1 "record now, accurate transcript a few minutes later"?
- **Launch languages?** Pick 2–3 to start (e.g. English + Arabic) and design the router so more can be added.
- **Input sources?** Uploaded files, a live mic, or bots joining Zoom / Meet / Teams.
- **Speaker names:** voice enrollment, calendar invites, or manual labeling after the meeting?
- **Understanding layer:** in scope for v1, or transcription-only first?

---

## Proposed roadmap

1. **Foundations:** transcript schema (D9), ingest (D1), evaluation harness (D11) with reference meetings **recorded on phones**. Benchmark candidate models on real devices: speed, memory, battery, heat.
2. **Single-language baseline on device:** VAD → ASR → punctuation in a bare-bones app, measured end to end.
3. **Who spoke:** segmentation, embeddings, clustering and registry (M2, M3, D3, D4, D6).
4. **Multilingual routing:** LID plus the router, two ASR specialists, code-switch splitting.
5. **Overlap handling:** detection, conditional separation, merge.
6. **Live + refine:** streaming live pass, device-aware scheduler (D13, D15), language packs (D14).
7. **Understanding layer:** summaries and action items from the clean transcript.

---

## License

TBD.
