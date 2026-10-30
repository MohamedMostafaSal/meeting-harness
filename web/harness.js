// The deterministic harness, ported from Sources/HarnessCore for the web
// prototype. Pure functions only: no models, no DOM, no network.

export const SAMPLE_RATE = 16000;

export const DEFAULT_POLICY = {
  router: {
    // Below this, a language guess is not trusted.
    languageConfidenceThreshold: 0.75,
    // Window used to re-identify an ambiguous turn. Whisper's language ID is
    // unreliable on very short audio, so this is longer than in the Swift core.
    splitWindow: 2.0,
    preferredVariants: { ar: 'egyptian' },
  },
  speakers: {
    // wavlm-base-plus-sv's model card suggests 0.86 for same-speaker verification.
    clusterThreshold: 0.86,
    enrollmentThreshold: 0.86,
    minEmbeddingDuration: 1.0,
  },
  turns: {
    // Segmentation flicker shorter than this is absorbed into its neighbour.
    minSegment: 0.3,
    // Pauses up to this long inside one speaker's speech don't end their turn.
    maxPause: 0.8,
    // Whisper reads at most 30 s at a time.
    maxTurn: 28,
  },
  utterances: {
    // Consecutive turns by the same speaker are transcribed together when this close.
    maxGap: 1.5,
    maxDuration: 28,
  },
  merge: {
    maxGap: 0.6,
    maxDuration: 30,
  },
};

// MARK: - Time ranges

export function evenSplit(range, maxLength) {
  const duration = range.end - range.start;
  const n = Math.max(1, Math.ceil(duration / maxLength - 1e-9));
  const step = duration / n;
  return Array.from({ length: n }, (_, i) => ({
    start: range.start + i * step,
    end: i === n - 1 ? range.end : range.start + (i + 1) * step,
  }));
}

/** Cuts `range` into windows of `size`, folding a trailing sliver into the last window. */
export function windows(range, size) {
  if (!(size > 0)) throw new Error('window size must be positive');
  const result = [];
  let t = range.start;
  while (t < range.end) {
    let end = Math.min(t + size, range.end);
    if (range.end - end < size / 2) end = range.end;
    result.push({ start: t, end });
    t = end;
  }
  return result;
}

export const roundMs = (seconds) => Math.round(seconds * 1000) / 1000;

// MARK: - Ingest (D1)

/** Speech loudness: the 90th-percentile 100 ms RMS, in dBFS (silence doesn't drag it down). */
export function measureLevel(audio, frame = SAMPLE_RATE / 10) {
  const levels = [];
  let peak = 0;
  for (let i = 0; i + frame <= audio.length; i += frame) {
    let energy = 0;
    for (let j = i; j < i + frame; j++) {
      energy += audio[j] * audio[j];
      peak = Math.max(peak, Math.abs(audio[j]));
    }
    levels.push(Math.sqrt(energy / frame));
  }
  if (!levels.length) return { speechDb: -Infinity, peak: 0 };
  levels.sort((a, b) => a - b);
  const p90 = levels[Math.min(levels.length - 1, Math.floor(levels.length * 0.9))];
  return { speechDb: p90 > 0 ? 20 * Math.log10(p90) : -Infinity, peak };
}

/**
 * Brings speech to about −20 dBFS, without clipping and without boosting by more
 * than 30 dB. Quiet phone recordings otherwise read as silence to the speech detector.
 */
export function normalizeLevel(audio, { targetDb = -20, maxGainDb = 30, ceiling = 0.98 } = {}) {
  const { speechDb, peak } = measureLevel(audio);
  if (!(peak > 0) || !Number.isFinite(speechDb)) return { audio, gainDb: 0, speechDb };
  const gainDb = Math.min(targetDb - speechDb, maxGainDb, 20 * Math.log10(ceiling / peak));
  const gain = 10 ** (gainDb / 20);
  const out = new Float32Array(audio.length);
  for (let i = 0; i < audio.length; i++) out[i] = audio[i] * gain;
  return { audio: out, gainDb, speechDb };
}

// MARK: - Chunking

/**
 * The sample index of the quietest 100 ms between `from` and `to` (sample indices),
 * so fixed-length model windows end in a pause instead of mid-word.
 */
export function quietestCut(audio, from, to, frame = SAMPLE_RATE / 10) {
  let best = to;
  let bestEnergy = Infinity;
  for (let start = Math.max(0, from); start + frame <= Math.min(to, audio.length); start += frame / 2) {
    let energy = 0;
    for (let i = start; i < start + frame; i++) energy += audio[i] * audio[i];
    if (energy < bestEnergy) {
      bestEnergy = energy;
      best = start + frame / 2;
    }
  }
  return best;
}

// MARK: - Turns (D4)

/**
 * Turns raw segmentation output into single-speaker turns.
 *
 * `raw` items are `{start, end, cls, chunk}` from pyannote segmentation-3.0,
 * whose classes are 0 = silence, 1–3 = one speaker, 4–6 = two speakers at once.
 * Speaker classes are local to each 10 s chunk, so they only join within a chunk.
 */
export function buildTurns(raw, { minSegment, maxPause = 0, maxTurn }) {
  const sorted = [...raw].sort((a, b) => a.start - b.start);

  // 1. Absorb flicker into the previous segment.
  const segments = [];
  for (const s of sorted) {
    if (segments.length && s.end - s.start < minSegment) {
      segments.at(-1).end = Math.max(segments.at(-1).end, s.end);
      continue;
    }
    segments.push({ ...s });
  }
  if (segments.length > 1 && segments[0].end - segments[0].start < minSegment) {
    segments[1].start = segments[0].start;
    segments.shift();
  }

  // 2. Join neighbours of the same class (silence joins across chunks).
  const joined = [];
  for (const s of segments) {
    const last = joined.at(-1);
    if (last && last.cls === s.cls && (s.cls === 0 || last.chunk === s.chunk)) {
      last.end = s.end;
    } else {
      joined.push({ ...s });
    }
  }

  // 3. Bridge short pauses inside one speaker's speech.
  const bridged = [];
  for (const s of joined) {
    const pause = bridged.at(-1);
    const before = bridged.at(-2);
    if (
      pause?.cls === 0 && pause.end - pause.start <= maxPause &&
      before && before.cls === s.cls && before.chunk === s.chunk
    ) {
      bridged.pop();
      before.end = s.end;
    } else {
      bridged.push(s);
    }
  }

  // 4. Keep speech, flag overlap, split what Whisper can't read in one go.
  const turns = [];
  for (const s of bridged) {
    if (s.cls === 0) continue;
    for (const piece of evenSplit(s, maxTurn)) {
      turns.push({ start: piece.start, end: piece.end, overlap: s.cls >= 4, chunk: s.chunk, cls: s.cls });
    }
  }
  return turns;
}

// MARK: - Router (D5)

export function top(guesses) {
  let best = null;
  for (const g of guesses ?? []) if (!best || g.confidence > best.confidence) best = g;
  return best;
}

/** The installed specialist for `language`, preferring the policy's variant. */
export function specialistFor(language, recognizers, policy) {
  const candidates = recognizers.filter((r) => !r.fallback && r.languages?.includes(language));
  const wanted = policy.preferredVariants?.[language];
  return candidates.find((r) => wanted && r.variant === wanted) ?? candidates[0] ?? null;
}

/**
 * Decides which speech-to-text model handles a stretch of speech. Returns one of
 * `{kind:'specialist', model, language}`, `{kind:'fallback', model, language}`
 * (language may be null), `{kind:'split', window}`, `{kind:'unroutable', reason}`.
 */
export function route(guesses, duration, recognizers, policy, allowSplit = true) {
  const fallback = (language, reason) => {
    const multi = recognizers.find((r) => r.fallback);
    return multi
      ? { kind: 'fallback', model: multi.id, language, reason }
      : { kind: 'unroutable', reason: `${reason}; no multilingual fallback installed` };
  };
  const best = top(guesses);
  if (best && best.confidence >= policy.languageConfidenceThreshold) {
    const specialist = specialistFor(best.language, recognizers, policy);
    if (specialist) return { kind: 'specialist', model: specialist.id, language: best.language };
    return fallback(best.language, `no specialist installed for ${best.language}`);
  }
  if (allowSplit && duration >= 2 * policy.splitWindow) return { kind: 'split', window: policy.splitWindow };
  return fallback(null, 'language uncertain');
}

// MARK: - Speakers (D3)

export function similarity(a, b) {
  if (!a || !b || a.length !== b.length) return 0;
  let dot = 0, na = 0, nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na > 0 && nb > 0 ? dot / Math.sqrt(na * nb) : 0;
}

/** Mean direction of several embeddings, each normalized first. */
export function centroid(embeddings) {
  const dim = embeddings[0].length;
  const sum = new Array(dim).fill(0);
  for (const e of embeddings) {
    const norm = Math.sqrt(e.reduce((s, x) => s + x * x, 0));
    if (!(norm > 0)) continue;
    for (let i = 0; i < dim; i++) sum[i] += e[i] / norm;
  }
  return sum.map((x) => x / embeddings.length);
}

/** Average-linkage agglomerative clustering; cluster numbers follow first appearance. */
export function agglomerate(embeddings, threshold) {
  const n = embeddings.length;
  if (n === 0) return [];
  const sim = embeddings.map((a) => embeddings.map((b) => similarity(a, b)));
  let clusters = embeddings.map((_, i) => [i]);
  while (clusters.length > 1) {
    let best = { a: 0, b: 0, score: -Infinity };
    for (let a = 0; a < clusters.length; a++) {
      for (let b = a + 1; b < clusters.length; b++) {
        let total = 0;
        for (const i of clusters[a]) for (const j of clusters[b]) total += sim[i][j];
        const score = total / (clusters[a].length * clusters[b].length);
        if (score > best.score) best = { a, b, score };
      }
    }
    if (best.score < threshold) break;
    clusters[best.a] = clusters[best.a].concat(clusters[best.b]);
    clusters.splice(best.b, 1);
  }
  const result = new Array(n).fill(0);
  clusters
    .sort((x, y) => Math.min(...x) - Math.min(...y))
    .forEach((members, number) => members.forEach((i) => (result[i] = number)));
  return result;
}

/**
 * Decides who spoke each turn. `embeddings[i]` null = too short to trust;
 * `reliable[i]` false = overlapped: never shapes clusters, joins one only if close.
 * `registry` is `[{id, name, embedding}]` of enrolled voices.
 */
export function assignSpeakers(embeddings, reliable, registry, policy) {
  const anchors = embeddings.map((e, i) => i).filter((i) => embeddings[i] && reliable[i]);
  const numbers = agglomerate(anchors.map((i) => embeddings[i]), policy.clusterThreshold);
  const clusterCount = numbers.length ? Math.max(...numbers) + 1 : 0;
  const centroids = Array.from({ length: clusterCount }, (_, c) =>
    centroid(anchors.filter((_, k) => numbers[k] === c).map((i) => embeddings[i])),
  );

  // One-to-one with enrolled voices, most similar pairs first.
  const pairs = [];
  centroids.forEach((c, ci) =>
    registry.forEach((e, ei) => {
      const score = similarity(c, e.embedding);
      if (score >= policy.enrollmentThreshold) pairs.push({ ci, ei, score });
    }),
  );
  const matched = new Map();
  const used = new Set();
  for (const p of pairs.sort((a, b) => b.score - a.score)) {
    if (matched.has(p.ci) || used.has(p.ei)) continue;
    matched.set(p.ci, p.ei);
    used.add(p.ei);
  }
  const taken = new Set(registry.map((e) => e.id));
  let next = 1;
  const labels = centroids.map((_, ci) => {
    if (matched.has(ci)) {
      const e = registry[matched.get(ci)];
      return { id: e.id, name: e.name };
    }
    while (taken.has(`S${next}`)) next++;
    return { id: `S${next++}`, name: null };
  });

  const result = new Array(embeddings.length).fill(null);
  anchors.forEach((i, k) => (result[i] = labels[numbers[k]]));
  embeddings.forEach((e, i) => {
    if (reliable[i] || !e || !centroids.length) return;
    let best = { c: -1, score: -Infinity };
    centroids.forEach((c, ci) => {
      const score = similarity(e, c);
      if (score > best.score) best = { c: ci, score };
    });
    if (best.score >= policy.clusterThreshold) result[i] = labels[best.c];
  });
  return result;
}

/**
 * Joins consecutive turns by the same (known) speaker into utterances, so speech
 * is transcribed in whole sentences rather than pause-to-pause scraps.
 * `labels[i]` is turn i's speaker label or null.
 */
export function groupUtterances(turns, labels, { maxGap, maxDuration }) {
  const out = [];
  turns.forEach((turn, i) => {
    const label = labels[i] ?? null;
    const last = out.at(-1);
    if (
      last && label && last.label?.id === label.id &&
      !last.overlap && !turn.overlap &&
      turn.start - last.end <= maxGap &&
      turn.end - last.start <= maxDuration
    ) {
      last.end = turn.end;
    } else {
      out.push({ start: turn.start, end: turn.end, overlap: turn.overlap, label });
    }
  });
  return out;
}

// MARK: - Confidence gating (D8)

// Phrases small Whisper models are known to invent over silence or music.
const KNOWN_HALLUCINATIONS = [
  /thank(s| you) (so much )?for watching/i,
  /please subscribe|like and subscribe/i,
  /اشتركوا في القناة/,
  /نانسي قنقر/,
  /شكرا (لكم )?على المشاهدة/,
  /ترجمة\s+(موقع|فريق)/,
  /\[(music|موسيقى|applause)\]/i,
  /♪/,
];

/** Why a transcription should be distrusted, or null. 'empty' means drop it. */
export function hallucinationReason(text, duration) {
  const clean = (text ?? '').trim();
  if (!clean || !/[\p{L}\p{N}]/u.test(clean)) return 'empty';
  if (KNOWN_HALLUCINATIONS.some((re) => re.test(clean))) return 'looks like a known Whisper hallucination';
  const words = clean.split(/\s+/);
  if (words.length >= 8 && new Set(words).size / words.length < 0.3) return 'repeats itself';
  const letters = clean.replace(/\s/g, '').length;
  if (duration > 0 && letters / duration > 30) return 'too much text for the audio length';
  return null;
}

// MARK: - Merge (D6)

/** Joins consecutive segments by the same speaker in the same language. */
export function mergeSegments(segments, { maxGap, maxDuration }) {
  const out = [];
  for (const s of segments) {
    const last = out.at(-1);
    if (
      last &&
      last.speaker === s.speaker &&
      last.lang === s.lang &&
      !last.overlap && !s.overlap &&
      s.start - last.end <= maxGap &&
      s.end - last.start <= maxDuration
    ) {
      last.end = s.end;
      last.text = `${last.text} ${s.text}`;
      last.conf = Math.min(last.conf, s.conf);
      last.uncertain = last.uncertain || s.uncertain;
      if (!last.producer.split('+').includes(s.producer)) last.producer += `+${s.producer}`;
      if (s.why) last.why = last.why ? `${last.why}; ${s.why}` : s.why;
    } else {
      out.push({ ...s });
    }
  }
  return out.map((s, i) => ({ ...s, id: `s_${String(i + 1).padStart(4, '0')}` }));
}

// MARK: - Evaluation (D11)

const ARABIC_FOLDS = new Map([
  ['أ', 'ا'], ['إ', 'ا'], ['آ', 'ا'], ['ٱ', 'ا'],
  ['ة', 'ه'],
  ['ى', 'ي'],
]);

/** Same rules as TextNormalizer in the Swift core. */
export function normalizeText(text) {
  let out = '';
  for (const ch of text.toLowerCase()) {
    const cp = ch.codePointAt(0);
    if ((cp >= 0x064b && cp <= 0x065f) || cp === 0x0670 || cp === 0x0640) continue;
    if (ARABIC_FOLDS.has(ch)) { out += ARABIC_FOLDS.get(ch); continue; }
    if (cp >= 0x0660 && cp <= 0x0669) { out += String(cp - 0x0660); continue; }
    if (cp >= 0x06f0 && cp <= 0x06f9) { out += String(cp - 0x06f0); continue; }
    if (/\p{P}/u.test(ch)) continue;
    out += ch;
  }
  return out.split(/\s+/).filter(Boolean).join(' ');
}

export function editDistance(a, b) {
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++) {
      cur[j] = Math.min(prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1), prev[j] + 1, cur[j - 1] + 1);
    }
    prev = cur;
  }
  return prev[b.length];
}

const rate = (errors, n) => ({ errors, referenceLength: n, rate: n ? errors / n : errors ? 1 : 0 });

export function wordErrorRate(reference, hypothesis) {
  const ref = normalizeText(reference).split(' ').filter(Boolean);
  const hyp = normalizeText(hypothesis).split(' ').filter(Boolean);
  return rate(editDistance(ref, hyp), ref.length);
}

export function characterErrorRate(reference, hypothesis) {
  const ref = [...normalizeText(reference).replace(/ /g, '')];
  const hyp = [...normalizeText(hypothesis).replace(/ /g, '')];
  return rate(editDistance(ref, hyp), ref.length);
}

// MARK: - Connector (D16) and exports

const SEGMENT_KEYS = ['id', 'start', 'end', 'speaker', 'speaker_name', 'lang', 'text', 'words', 'conf', 'producer', 'overlap', 'uncertain'];

/** A segment in the wire format of Sources/HarnessCore/Schema (internal fields dropped). */
export function wireSegment(s) {
  const out = {};
  for (const k of SEGMENT_KEYS) if (s[k] !== undefined && s[k] !== null) out[k] = s[k];
  out.words ??= [];
  return out;
}

export function toEvents(transcript) {
  const meeting = transcript.meeting;
  let seq = 0;
  return [
    { meeting, seq: seq++, type: 'meeting.started' },
    ...transcript.segments.map((s) => ({ meeting, seq: seq++, type: 'segment.final', segment: wireSegment(s) })),
    { meeting, seq: seq++, type: 'meeting.ended' },
  ];
}

export const toJSONLines = (events) => events.map((e) => JSON.stringify(e)).join('\n') + '\n';

export function timestamp(seconds) {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  const two = (n) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${two(m)}:${two(s)}`;
}

/** Same layout as MarkdownExporter in the Swift core. */
export function toMarkdown(transcript) {
  const lines = [`# Meeting ${transcript.meeting}`, ''];
  for (const s of transcript.segments) {
    const who = s.speaker_name || s.speaker || 'Speaker';
    const lang = s.lang ? ` · ${s.lang}` : '';
    lines.push(`**${who}** \`${timestamp(s.start)}${lang}\`  `);
    lines.push(s.text + (s.uncertain ? ' _(uncertain)_' : ''));
    lines.push('');
  }
  if (transcript.gaps.length) {
    lines.push('---', '');
    for (const g of transcript.gaps) lines.push(`- Not transcribed \`${timestamp(g.start)}–${timestamp(g.end)}\`: ${g.reason}`);
    lines.push('');
  }
  return lines.join('\n');
}

// MARK: - Live captions (the draft pass of "draft live, refine later")

export const LIVE_POLICY = {
  pauseSeconds: 0.6,        // this much quiet ends a sentence
  maxSentenceSeconds: 18,   // long monologues are cut anyway
  draftEverySeconds: 2,     // how often the sentence in progress is re-transcribed
  silenceRms: 0.008,
  minSeconds: 1,
};

export function rms(samples, from = 0, to = samples.length) {
  const n = Math.max(0, to - from);
  if (!n) return 0;
  let sum = 0;
  for (let i = from; i < to; i++) sum += samples[i] * samples[i];
  return Math.sqrt(sum / n);
}

/**
 * Decides what the live captioner does next. Same rules as the iPhone app's LiveCaptioner.
 * `state` is {sentenceStart, lastDraftAt} in absolute samples; `samples` start at `start`
 * and run to `total`. Returns {action: 'wait'|'skip'|'commit'|'draft', state}.
 */
export function liveStep(state, total, samples, start, policy = LIVE_POLICY, rate = SAMPLE_RATE) {
  const sentenceStart = Math.max(state.sentenceStart, start);
  const length = (total - sentenceStart) / rate;
  if (length < policy.minSeconds) return { action: 'wait', state };
  const offset = sentenceStart - start;
  const tail = Math.max(offset, samples.length - Math.round(policy.pauseSeconds * rate));
  const paused = rms(samples, tail) < policy.silenceRms;
  const hasSpeech = rms(samples, offset) >= policy.silenceRms;
  if (!hasSpeech) {
    return { action: 'skip', state: { ...state, sentenceStart: Math.max(sentenceStart, total - Math.round(policy.pauseSeconds * rate)) } };
  }
  if (paused || length >= policy.maxSentenceSeconds) {
    return { action: 'commit', from: sentenceStart, state: { sentenceStart: total, lastDraftAt: total } };
  }
  if ((total - state.lastDraftAt) / rate >= policy.draftEverySeconds) {
    return { action: 'draft', from: sentenceStart, state: { sentenceStart, lastDraftAt: total } };
  }
  return { action: 'wait', state: { ...state, sentenceStart } };
}
