// Recording-mode pipeline for the web prototype. Mirrors Sources/HarnessCore/Pipeline:
// segmentation → turns → language ID → router → speech-to-text → gating → who spoke → merge.
//
// `models` is any object with this contract (real ones live in models.js, fakes in tests):
//   recognizers: [{id, label, languages?, variant?, fallback?}]
//   segment(audio)                         → [{start, end, cls, chunk}]   (M1 + M2 + M4)
//   embed(clip)                            → number[]                     (M3)
//   identify(clip, allowedLanguages)       → [{language, confidence}]     (M6)
//   transcribe(clip, {model, language})    → {text}                       (M7)

import {
  SAMPLE_RATE, buildTurns, route, top, windows, assignSpeakers,
  hallucinationReason, mergeSegments, roundMs,
} from './harness.js';

const now = () => (globalThis.performance ?? Date).now();

export async function runPipeline(audio, models, options) {
  const {
    policy,
    registry = [],
    allowedLanguages = ['en', 'ar'],
    meeting = 'meeting',
    onProgress = () => {},
  } = options;

  const slice = (r) => audio.subarray(Math.round(r.start * SAMPLE_RATE), Math.round(r.end * SAMPLE_RATE));
  const log = [];
  const timings = { segmentation: 0, languageID: 0, transcription: 0, embedding: 0 };
  const timed = async (key, fn) => {
    const t0 = now();
    try { return await fn(); } finally { timings[key] += now() - t0; }
  };
  const fmt = (guesses) => guesses.slice(0, 2).map((g) => `${g.language} ${g.confidence.toFixed(2)}`).join(' / ');
  const span = (r) => `${r.start.toFixed(1)}–${r.end.toFixed(1)}s`;

  onProgress({ stage: 'Finding speech and speaker turns' });
  const raw = await timed('segmentation', () => models.segment(audio));
  const turns = buildTurns(raw, policy.turns);
  log.push(`Segmentation: ${turns.length} turns, ${turns.filter((t) => t.overlap).length} overlapped`);

  const identify = (r) => timed('languageID', () => models.identify(slice(r), allowedLanguages));

  // Plans one turn: route it, or split it into windows and route each part.
  async function plan(turn) {
    const guesses = await identify(turn);
    const decision = route(guesses, turn.end - turn.start, models.recognizers, policy.router);
    if (decision.kind !== 'split') {
      log.push(`${span(turn)} LID ${fmt(guesses)} → ${describe(decision)}`);
      return [{ range: turn, decision, guesses }];
    }
    log.push(`${span(turn)} LID ${fmt(guesses)} → ambiguous, re-checking in ${decision.window}s windows`);
    const groups = [];
    for (const w of windows(turn, decision.window)) {
      const g = await identify(w);
      const last = groups.at(-1);
      if (last && top(last.guesses)?.language === top(g)?.language) {
        last.range = { start: last.range.start, end: w.end };
        if ((top(g)?.confidence ?? 0) < (top(last.guesses)?.confidence ?? 0)) last.guesses = g;
      } else {
        groups.push({ range: w, guesses: g });
      }
    }
    return groups.map((group) => {
      const d = route(group.guesses, group.range.end - group.range.start, models.recognizers, policy.router, false);
      log.push(`  ${span(group.range)} LID ${fmt(group.guesses)} → ${describe(d)}`);
      return { range: group.range, decision: d, guesses: group.guesses };
    });
  }

  function describe(d) {
    const label = (id) => models.recognizers.find((r) => r.id === id)?.label ?? id;
    switch (d.kind) {
      case 'specialist': return `${label(d.model)} [${d.language}]`;
      case 'fallback': return `${label(d.model)} [${d.language ?? 'auto'}] (${d.reason})`;
      default: return `not transcribed (${d.reason})`;
    }
  }

  const segments = [];
  const turnOfSegment = [];
  const gaps = [];
  for (const [i, turn] of turns.entries()) {
    onProgress({ stage: 'Transcribing', done: i, total: turns.length });
    for (const piece of await plan(turn)) {
      const { range, decision, guesses } = piece;
      if (decision.kind === 'unroutable') {
        gaps.push({ start: roundMs(range.start), end: roundMs(range.end), reason: decision.reason });
        continue;
      }
      const language = decision.language ?? top(guesses)?.language ?? null;
      const { text } = await timed('transcription', () =>
        models.transcribe(slice(range), { model: decision.model, language }));
      const why = hallucinationReason(text, range.end - range.start);
      if (why === 'empty') continue;
      if (why) log.push(`  ${span(range)} flagged: ${why}`);
      segments.push({
        start: roundMs(range.start),
        end: roundMs(range.end),
        speaker: null,
        speaker_name: null,
        lang: language,
        text: text.trim(),
        // Prototype: language-ID confidence of the chosen language. There is no ASR confidence yet.
        conf: roundMs(guesses.find((g) => g.language === language)?.confidence ?? 0),
        producer: decision.model,
        overlap: turn.overlap,
        uncertain: why !== null,
        why: why ?? undefined,
      });
      turnOfSegment.push(i);
    }
  }

  onProgress({ stage: 'Working out who spoke' });
  const embeddings = [];
  for (const turn of turns) {
    embeddings.push(turn.end - turn.start >= policy.speakers.minEmbeddingDuration
      ? await timed('embedding', () => models.embed(slice(turn)))
      : null);
  }
  const labels = assignSpeakers(embeddings, turns.map((t) => !t.overlap), registry, policy.speakers);
  segments.forEach((s, k) => {
    const label = labels[turnOfSegment[k]];
    s.speaker = label?.id ?? null;
    s.speaker_name = label?.name ?? null;
  });
  const speakerCount = new Set(labels.filter(Boolean).map((l) => l.id)).size;
  log.push(`Speakers: ${speakerCount} found, ${labels.filter((l) => l === null).length} turns unlabeled`);

  const merged = mergeSegments(segments, policy.merge);
  return {
    transcript: { schema_version: 1, meeting, segments: merged, gaps },
    log,
    timings,
    duration: audio.length / SAMPLE_RATE,
  };
}
