// Recording-mode pipeline for the web prototype, in three phases:
//
//   1. diarize     segmentation → turns → who spoke → utterances        (voice models)
//   2. plan        language ID → router, per utterance                   (multilingual Whisper)
//   3. transcribe  speech-to-text for the pieces routed to one model     (one Whisper at a time)
//   then assemble  gating → merge → transcript                           (no models)
//
// Phases only exchange plain data, so the page can run each one in its own
// short-lived worker. A WebAssembly heap never shrinks, so throwing the worker
// away is the only way to free a model's memory before loading the next one;
// that keeps iPhone Safari under its per-tab memory limit.
//
// Who spoke is decided *before* transcription: fingerprints are taken per
// speaker stretch (more audio, steadier voices), and each speaker's consecutive
// turns are transcribed as one utterance.
//
// `models` is any object with the parts of this contract a phase needs
// (real ones in models.js, fakes in tests):
//   recognizers: [{id, label, model, languages?, variant?, fallback?}]
//   segment(audio)                         → [{start, end, cls, chunk}]   (M1 + M2 + M4)
//   embed(clip)                            → number[]                     (M3)
//   identify(clip, allowedLanguages)       → [{language, confidence}]     (M6)
//   transcribe(clip, {model, language})    → {text}                       (M7)

import {
  SAMPLE_RATE, buildTurns, route, top, windows, assignSpeakers, groupUtterances, similarity,
  hallucinationReason, mergeSegments, roundMs,
} from './harness.js';

const now = () => (globalThis.performance ?? Date).now();
const fmt = (guesses) => guesses.slice(0, 2).map((g) => `${g.language} ${g.confidence.toFixed(2)}`).join(' / ');
const span = (r) => `${r.start.toFixed(1)}–${r.end.toFixed(1)}s`;

/** Log lines and per-pillar timings, collected across phases (and workers). */
export function newContext() {
  return { log: [], timings: { segmentation: 0, languageID: 0, transcription: 0, embedding: 0 } };
}

export function mergeContext(into, from) {
  into.log.push(...from.log);
  for (const [k, ms] of Object.entries(from.timings)) into.timings[k] = (into.timings[k] ?? 0) + ms;
  return into;
}

function tools(audio, ctx) {
  return {
    slice: (r) => audio.subarray(Math.round(r.start * SAMPLE_RATE), Math.round(r.end * SAMPLE_RATE)),
    timed: async (key, fn) => {
      const t0 = now();
      try { return await fn(); } finally { ctx.timings[key] += now() - t0; }
    },
  };
}

// MARK: - Phase 1: who spoke

/** Returns utterances: `[{start, end, overlap, label: {id, name} | null}]`. */
export async function diarize(audio, models, { policy, registry = [], debug = false, onProgress = () => {} }, ctx) {
  const { slice, timed } = tools(audio, ctx);

  onProgress({ stage: 'Finding speech and speaker turns' });
  const raw = await timed('segmentation', () => models.segment(audio));
  const turns = buildTurns(raw, policy.turns);
  ctx.log.push(`Segmentation: ${turns.length} turns, ${turns.filter((t) => t.overlap).length} overlapped`);

  // One fingerprint per stretch of one local speaker in one chunk. The
  // segmentation model can reuse a local label for a different voice after a
  // long silence, so a stretch ends at any gap longer than an utterance gap.
  onProgress({ stage: 'Working out who spoke' });
  const MAX_FINGERPRINT = 10 * SAMPLE_RATE;
  const units = []; // {turns: [index], reliable}
  const open = new Map(); // `${chunk}:${cls}` → unit index
  turns.forEach((turn, i) => {
    if (turn.overlap) return units.push({ turns: [i], reliable: false });
    const key = `${turn.chunk}:${turn.cls}`;
    const k = open.get(key);
    if (k !== undefined && turn.start - turns[units[k].turns.at(-1)].end <= policy.utterances.maxGap) {
      units[k].turns.push(i);
    } else {
      open.set(key, units.push({ turns: [i], reliable: true }) - 1);
    }
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
  if (debug) {
    const rows = embeddings.map((a, i) => {
      const t = turns[units[i].turns[0]];
      const sims = embeddings.map((b) => (a && b ? similarity(a, b).toFixed(2) : ' -  ')).join(' ');
      return `  ${t.start.toFixed(1).padStart(5)}s ${units[i].reliable ? ' ' : '*'} ${sims}`;
    });
    ctx.log.push('Voice similarity (rows/cols = voice samples, * = overlapped):', ...rows);
  }
  const unitLabels = assignSpeakers(embeddings, units.map((u) => u.reliable), registry, policy.speakers);
  const labels = new Array(turns.length).fill(null);
  units.forEach((u, k) => u.turns.forEach((i) => (labels[i] = unitLabels[k])));
  const speakerCount = new Set(unitLabels.filter(Boolean).map((l) => l.id)).size;
  ctx.log.push(`Speakers: ${speakerCount} found from ${units.length} voice samples, ${labels.filter((l) => l === null).length} turns unlabeled`);

  const utterances = groupUtterances(turns, labels, policy.utterances);
  ctx.log.push(`Utterances: ${utterances.length}`);
  return utterances;
}

// MARK: - Phase 2: which language, which model

function describe(d, recognizers) {
  const label = (id) => recognizers.find((r) => r.id === id)?.label ?? id;
  switch (d.kind) {
    case 'specialist': return `${label(d.model)} [${d.language}]`;
    case 'fallback': return `${label(d.model)} [${d.language ?? 'auto'}] (${d.reason})`;
    default: return `not transcribed (${d.reason})`;
  }
}

/**
 * Routes every utterance, splitting ambiguous ones into windows. Returns pieces:
 * `[{utterance, range, decision, language, conf}]`, in time order.
 */
export async function plan(audio, utterances, models, { policy, allowedLanguages = ['en', 'ar'], onProgress = () => {} }, ctx) {
  const { slice, timed } = tools(audio, ctx);
  const identify = (r) => timed('languageID', () => models.identify(slice(r), allowedLanguages));
  const recognizers = models.recognizers;
  const pieces = [];
  const add = (utterance, range, decision, guesses) => {
    const language = decision.language ?? top(guesses)?.language ?? null;
    pieces.push({
      utterance, range, decision, language,
      // Prototype: language-ID confidence of the chosen language. There is no ASR confidence yet.
      conf: roundMs(guesses.find((g) => g.language === language)?.confidence ?? 0),
    });
  };

  for (const [u, utterance] of utterances.entries()) {
    onProgress({ stage: 'Detecting languages', done: u, total: utterances.length });
    const guesses = await identify(utterance);
    const decision = route(guesses, utterance.end - utterance.start, recognizers, policy.router);
    if (decision.kind !== 'split') {
      ctx.log.push(`${span(utterance)} LID ${fmt(guesses)} → ${describe(decision, recognizers)}`);
      add(u, utterance, decision, guesses);
      continue;
    }
    ctx.log.push(`${span(utterance)} LID ${fmt(guesses)} → ambiguous, re-checking in ${decision.window}s windows`);
    const groups = [];
    for (const w of windows(utterance, decision.window)) {
      const g = await identify(w);
      const last = groups.at(-1);
      if (last && top(last.guesses)?.language === top(g)?.language) {
        last.range = { start: last.range.start, end: w.end };
        if ((top(g)?.confidence ?? 0) < (top(last.guesses)?.confidence ?? 0)) last.guesses = g;
      } else {
        groups.push({ range: w, guesses: g });
      }
    }
    for (const group of groups) {
      const d = route(group.guesses, group.range.end - group.range.start, recognizers, policy.router, false);
      ctx.log.push(`  ${span(group.range)} LID ${fmt(group.guesses)} → ${describe(d, recognizers)}`);
      add(u, group.range, d, group.guesses);
    }
  }
  return pieces;
}

/** Indexes of the pieces a given loaded model (by its model id) should transcribe. */
export function piecesFor(pieces, recognizers, modelId) {
  const ids = new Set(recognizers.filter((r) => r.model === modelId).map((r) => r.id));
  return pieces.flatMap((p, i) => (p.decision.kind !== 'unroutable' && ids.has(p.decision.model) ? [i] : []));
}

// MARK: - Phase 3: what was said

/** Transcribes `indexes` of `pieces`. Returns `{index: text}`. */
export async function transcribe(audio, pieces, indexes, models, { onProgress = () => {} } = {}, ctx) {
  const { slice, timed } = tools(audio, ctx);
  const texts = {};
  for (const [n, i] of indexes.entries()) {
    onProgress({ stage: 'Transcribing', done: n, total: indexes.length });
    const p = pieces[i];
    const { text } = await timed('transcription', () =>
      models.transcribe(slice(p.range), { model: p.decision.model, language: p.language }));
    texts[i] = text;
  }
  return texts;
}

// MARK: - Assemble

export function assemble({ utterances, pieces, texts, policy, meeting = 'meeting', duration }, ctx) {
  const segments = [];
  const gaps = [];
  pieces.forEach((p, i) => {
    const { range, decision } = p;
    if (decision.kind === 'unroutable') {
      gaps.push({ start: roundMs(range.start), end: roundMs(range.end), reason: decision.reason });
      return;
    }
    const text = texts[i] ?? '';
    const why = hallucinationReason(text, range.end - range.start);
    if (why === 'empty') return;
    if (why) ctx.log.push(`${span(range)} flagged: ${why}`);
    const utterance = utterances[p.utterance];
    segments.push({
      start: roundMs(range.start),
      end: roundMs(range.end),
      speaker: utterance.label?.id ?? null,
      speaker_name: utterance.label?.name ?? null,
      lang: p.language,
      text: text.trim(),
      conf: p.conf,
      producer: decision.model,
      overlap: utterance.overlap,
      uncertain: why !== null,
      why: why ?? undefined,
    });
  });
  return {
    transcript: { schema_version: 1, meeting, segments: mergeSegments(segments, policy.merge), gaps },
    log: ctx.log,
    timings: ctx.timings,
    duration,
  };
}

// MARK: - All phases with one model set (tests, CI smoke test)

export async function runPipeline(audio, models, options) {
  const ctx = newContext();
  const utterances = await diarize(audio, models, options, ctx);
  const pieces = await plan(audio, utterances, models, options, ctx);
  const indexes = pieces.flatMap((p, i) => (p.decision.kind === 'unroutable' ? [] : [i]));
  const texts = await transcribe(audio, pieces, indexes, models, options, ctx);
  return assemble({ ...options, utterances, pieces, texts, duration: audio.length / SAMPLE_RATE }, ctx);
}
