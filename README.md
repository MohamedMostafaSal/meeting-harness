# meeting-harness

**Meeting transcription built from small specialist models and deterministic code, with no single giant model.**

Most meeting transcription products send the whole recording through one large model and hope it handles everything: several speakers, several languages, cross-talk, jargon, silence. When it fails, you can't see where it failed and you can't fix that one part.

`meeting-harness` takes the opposite approach:

> **Break the problem into narrow questions. Send each one to the smallest model that answers it well. Let deterministic code handle routing, merging and decisions.**

The intelligence lives in the **structure**: the pipeline, the routing conditions and the confidence gates. The models are replaceable parts.

> Status: **proof of concept, design stage.** No code yet. This README is the working spec.

**Platform: an iPhone app, fully local.** The whole pipeline runs **on the device**. No audio or text leaves the phone unless the user exports it.

**Scope: the app is the ears, not the brain.** It produces the best possible transcript. Summaries, action items and any "assistant" work happen *outside* the app, in the user's own AI tools, which receive the meeting through a **connector** (see [Connector](#connector-meeting--your-ai)).

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
| **Expensive / cloud-only** | Small, quantized models run on the phone's Neural Engine. Everything is local; there is no server. |
| **Kills battery / phone gets hot** | Routing takes battery, heat and charging state into account. The heavy work waits until the phone is charging or idle. |
| **Huge app download** | Language packs: users only download the speech-to-text specialists for the languages they actually speak. |

---

## Decisions so far

| Topic | Decision | Why |
|---|---|---|
| Platform | **iOS first** (PoC) | One platform keeps the PoC small. Core ML and the Neural Engine are a mature target for small models. |
| Where it runs | **Fully local** | Privacy, no server costs, works offline. No cloud escalation at all. |
| v1 mode | **Record → accurate transcript** after the meeting | Accuracy first. Live captions are the target and the architecture is built for them from day one. |
| Why live matters | Feeds the **connector** | The user's external AI should be able to follow the meeting while it's happening. |
| Languages | **English + Arabic** first, then **German** (or French) as the third | Arabic and English are very different and often mixed in one sentence, which is the hardest routing case. A third language checks that the router really generalizes. |
| Understanding layer | **Out of the app** | Transcription has to be right first. Understanding happens in the user's AI tools via the connector. |
| Code | **Swift**, with the harness as a UI-free Swift package (`HarnessCore`) | See [Runtime stack](#runtime-stack). |

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
if segment conf < τ && larger local tier installed → re-run this segment on the larger tier
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

### Runtime stack

- **`HarnessCore`**: a pure Swift package with the deterministic harness (router, registry, merge, schema, policies). It has **no UI and no iOS-only imports**, so it builds and tests with `swift test` on macOS *and Linux*. Most of the logic can be tested without a phone.
- **`HarnessModels`**: adapters that wrap each AI pillar behind a Swift protocol (its contract). Core ML / Neural Engine implementations live here. The core only sees the protocols, so models are swappable and can be faked in tests.
- **App**: SwiftUI. Recording via `AVAudioEngine` with the background audio mode.
- **Candidate model runtimes to benchmark:** Core ML conversions of each pillar. Existing open Swift projects that already run Whisper, pyannote-style diarization and VAD on the Neural Engine (e.g. WhisperKit, FluidAudio) are worth evaluating before converting anything ourselves.
- **Why not a Rust/C++ core yet:** it only pays off once there's a second platform. For an iOS PoC it adds cross-language plumbing with no benefit. Because `HarnessCore` stays UI-free, porting it later is a contained job.

---

## Connector: meeting → your AI

The app doesn't try to be an assistant. It makes the meeting **readable by the assistant you already use**.

**The contract (fixed now):** an append-only stream of transcript events, in the same schema as the transcript store (D9).

```json
{ "meeting": "m_2026-10-30_1400", "seq": 42, "type": "segment.final",
  "segment": { "id": "s_0042", "start": 12.4, "end": 13.9, "speaker": "S2",
               "speaker_name": "Sara", "lang": "ar", "text": "خلينا نبدأ",
               "conf": 0.94, "producer": "asr-ar-small@1.2" } }
```

Event types: `meeting.started`, `segment.draft`, `segment.final`, `segment.revised` (when the refine pass improves a segment), `speaker.renamed`, `meeting.ended`.

Using one event stream for both modes means:
- **Recording mode (v1):** events are written once the transcript is final. The connector delivers a finished file.
- **Live mode (target):** the same events arrive as they happen. An AI following along sees drafts, then finals, then revisions. Nothing about the format changes.

**The transport (to decide; local-only rules out a cloud relay):**
1. **Files** (v1): JSON + Markdown written to a folder in the Files app / iCloud Drive that the user's AI tools can read. Simplest, works today.
2. **Local network:** the phone serves the event stream over the LAN (e.g. as an MCP server or a simple local API) to an AI tool on the user's Mac or PC. This is the path to live mode.
3. **Share sheet / Shortcuts:** send a finished transcript to any app manually or through automation.

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
          [D] Connector: event stream + transcript files ──► the user's AI tools
                                            ▼
                     [D] Exports: JSON · SRT · VTT · Markdown
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
| ~~M9~~ | ~~Understanding layer~~ | **Out of scope for the app.** Summaries and action items happen in the user's own AI tools, fed by the connector (D16). | | |

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
| D16 | **Connector** | Publishes the meeting to outside AI tools: a live, append-only event stream plus finished transcript files. See below. |

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

- **Which Arabic?** Modern Standard Arabic and the dialects (Egyptian, Gulf, Levantine, Maghrebi…) behave very differently for speech-to-text. Which ones matter most in your meetings? This decides which Arabic specialist we benchmark first.
- **Third language:** German or French?
- **Connector transport for live mode:** local network (MCP / local API) to a computer, or something else? Which AI tools should it plug into first?
- **Input sources:** in-person meetings via the iPhone mic first. Importing audio files too? Online calls (Zoom / Meet / Teams) are harder on iOS.
- **Speaker names:** voice enrollment for the owner, and manual renaming for everyone else after the meeting?

---

## Proposed roadmap

1. **Foundations (no phone needed):** `HarnessCore` Swift package with the transcript schema and event types (D9, D16), the router skeleton (D5) and the evaluation harness (D11). Fake models behind the protocols so the whole pipeline can be tested on Linux/macOS.
2. **Reference data:** a small set of English, Arabic and mixed meetings **recorded on an iPhone**, with hand-checked transcripts and speaker labels.
3. **English + Arabic baseline on device:** record → VAD → language ID → two speech-to-text specialists → punctuation, in a bare-bones SwiftUI app. Measure accuracy, speed, memory, battery and heat.
4. **Who spoke:** segmentation, embeddings, clustering, registry, owner voice enrollment (M2, M3, D3, D4, D6).
5. **Code-switching:** splitting segments at language boundaries, measured on the mixed Arabic/English recordings.
6. **Connector v1:** JSON + Markdown files exported to the Files app.
7. **Overlap handling:** detection, conditional separation, merge.
8. **Third language** (German or French) to prove the router generalizes.
9. **Live mode (target):** streaming live pass, device-aware scheduler (D13, D15), live connector over the local network.

---

## License

TBD.
