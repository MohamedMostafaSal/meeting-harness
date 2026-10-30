// Recording-mode pipeline for the web prototype:
// segmentation → turns → who spoke → utterances → language ID → router → speech-to-text → gating → merge.
//
// Unlike the Swift core so far, who spoke is decided *before* transcription:
// fingerprints are taken per speaker per segmentation chunk (more audio, steadier
// voices), and each speaker's consecutive turns are transcribed as one utterance.
//
// `models` is any object with this contract (real ones live in models.js, fakes in tests):
//   recognizers: [{id, label, languages?, variant?, fallback?}]
//   segment(audio)                         → [{start, end, cls, chunk}]   (M1 + M2 + M4)
//   embed(clip)                            → number[]                     (M3)
//   identify(clip, allowedLanguages)       → [{language, confidence}]     (M6)
//   transcribe(clip, {model, language})    → {text}                       (M7)

import {
  SAMPLE_RATE, buildTurns, route, top, windows, assignSpeakers, groupUtterances, similarity,
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

  // Who spoke: one fingerprint per (chunk, local speaker) from all their audio in that chunk.
  onProgress({ stage: 'Working out who spoke' });
  const MAX_FINGERPRINT = 10 * SAMPLE_RATE;
  const units = []; // {turns: [index], reliable}
  const byKey = new Map();
  turns.forEach((turn, i) => {
    if (turn.overlap) return units.push({ turns: [i], reliable: false });
    const key = `${turn.chunk}:${turn.cls}`;
    if (!byKey.has(key)) byKey.set(key, units.push({ turns: [], reliable: true }) - 1);
    units[byKey.get(key)].turns.push(i);
  });
  const embeddings = [];
  for (const unit of units) {
    const seconds = unit.turns.reduce((sum, i) => sum + turns[i].end - turns[i].start, 0);
    if (seconds < policy.speakers.minEmbeddingDuration) { embeddings.push(null); continue; }
    let clip;
    if (unit.turns.length === 1) {
      clip = slice(turns[unit.turns[0]]);
    } else {
      const parts = unit.turns.map((i) => slice(turns[i]));
      clip = new Float32Array(Math.min(MAX_FINGERPRINT, parts.reduce((n, p) => n + p.length, 0)));
      let at = 0;
      for (const p of parts) {
        if (at >= clip.length) break;
        clip.set(p.subarray(0, clip.length - at), at);
        at += p.length;
      }
    }
    embeddings.push(await timed('embedding', () => models.embed(clip)));
  }
  if (options.debug) {
    const rows = embeddings.map((a, i) => {
      const t = turns[units[i].turns[0]];
      const sims = embeddings.map((b) => (a && b ? similarity(a, b).toFixed(2) : ' -  ')).join(' ');
      return `  ${t.start.toFixed(1).padStart(5)}s ${units[i].reliable ? ' ' : '*'} ${sims}`;
    });
    log.push('Voice similarity (rows/cols = voice samples, * = overlapped):', ...rows);
  }
  const unitLabels = assignSpeakers(embeddings, units.map((u) => u.reliable), registry, policy.speakers);
  const labels = new Array(turns.length).fill(null);
  units.forEach((u, k) => u.turns.forEach((i) => (labels[i] = unitLabels[k])));
  const speakerCount = new Set(unitLabels.filter(Boolean).map((l) => l.id)).size;
  log.push(`Speakers: ${speakerCount} found from ${units.length} voice samples, ${labels.filter((l) => l === null).length} turns unlabeled`);

  const utterances = groupUtterances(turns, labels, policy.utterances);
  log.push(`Utterances: ${utterances.length}`);

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
  const gaps = [];
  for (const [i, turn] of utterances.entries()) {
    onProgress({ stage: 'Transcribing', done: i, total: utterances.length });
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
        speaker: turn.label?.id ?? null,
        speaker_name: turn.label?.name ?? null,
        lang: language,
        text: text.trim(),
        // Prototype: language-ID confidence of the chosen language. There is no ASR confidence yet.
        conf: roundMs(guesses.find((g) => g.language === language)?.confidence ?? 0),
        producer: decision.model,
        overlap: turn.overlap,
        uncertain: why !== null,
        why: why ?? undefined,
      });
    }
  }

  const merged = mergeSegments(segments, policy.merge);
  return {
    transcript: { schema_version: 1, meeting, segments: merged, gaps },
    log,
    timings,
    duration: audio.length / SAMPLE_RATE,
  };
}
