// Why segments went to the English model, and how speaker labels are distributed.
// Reads yt/cues.json and yt/<preset>/harness.json. No model runs.
//
//   node eval/lab/routing_stats.mjs [presets=balanced,light]
import fs from 'node:fs';

const presets = (process.argv[2] ?? 'balanced,light').split(',');
const cues = JSON.parse(fs.readFileSync('yt/cues.json', 'utf8'));
const LID = /^(\s*)([\d.]+)–([\d.]+)s LID (\w+) ([\d.]+) \/ (\w+) ([\d.]+) → (.*)$/;
const quantile = (xs, q) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(q * xs.length))];
const overlapOf = (a, b) => Math.max(0, Math.min(a.end, b.end) - Math.max(a.start, b.start));

function isLoop(text) {
  const w = text.split(/\s+/).filter(Boolean);
  for (let i = 0; i < w.length; i++) for (let n = 1; n <= 4; n++) {
    const at = (r) => w.slice(i + n * r, i + n * (r + 1)).join(' ');
    let r = 1;
    while (i + n * (r + 1) <= w.length && at(r) === at(0)) r++;
    if (r >= 4) return true;
  }
  return false;
}

for (const preset of presets) {
  const { transcript, log } = JSON.parse(fs.readFileSync(`yt/${preset}/harness.json`, 'utf8'));
  const pieces = log.flatMap((line) => {
    const m = LID.exec(line);
    if (!m || m[8].startsWith('ambiguous')) return [];
    const p = { [m[4]]: +m[5], [m[6]]: +m[7] };
    return [{ start: +m[2], end: +m[3], en: p.en, ar: p.ar, window: m[1].length > 0,
      to: m[8].startsWith('English') ? 'en' : m[8].startsWith('Arabic') ? 'ar' : 'fallback' }];
  });
  const pieceFor = (s) => pieces.map((p) => [overlapOf(p, s), p]).sort((a, b) => b[0] - a[0])[0]?.[1];
  const segments = transcript.segments.map((s) => ({ ...s, piece: pieceFor(s), loop: isLoop(s.text) }));
  const en = segments.filter((s) => s.lang === 'en');

  console.log(`\n# ${preset}: ${segments.length} segments, ${en.length} labeled en`);
  console.log('## Every en segment: start, length, en confidence, route, window?, loop?, text || captions');
  for (const s of en) {
    const caps = cues.filter((c) => overlapOf(c, { start: s.start - 0.3, end: s.end + 0.3 }) > 0).map((c) => c.text).join(' ');
    console.log([s.start.toFixed(1), (s.end - s.start).toFixed(1), s.piece?.en, s.piece?.to, s.piece?.window ? 'win' : 'whole',
      s.loop ? 'LOOP' : '', s.text.slice(0, 70), '||', caps.slice(0, 80)].join(' | '));
  }

  const lengths = en.map((s) => s.end - s.start);
  const ar = segments.filter((s) => s.lang === 'ar');
  const seconds = (xs) => xs.reduce((sum, s) => sum + s.end - s.start, 0).toFixed(0);
  console.log('## Lengths', { enMedian: quantile(lengths, 0.5), enP90: quantile(lengths, 0.9), enSeconds: seconds(en),
    arMedian: quantile(ar.map((s) => s.end - s.start), 0.5), arSeconds: seconds(ar),
    enUnder1s: lengths.filter((l) => l < 1).length, enUnder2s: lengths.filter((l) => l < 2).length });

  const toEn = pieces.filter((p) => p.to === 'en');
  const confidences = toEn.map((p) => p.en);
  console.log('## Pieces routed to the English specialist', { pieces: toEn.length, windows: toEn.filter((p) => p.window).length,
    fallback: pieces.filter((p) => p.to === 'fallback').length,
    min: Math.min(...confidences), p10: quantile(confidences, 0.1), median: quantile(confidences, 0.5), max: Math.max(...confidences) });
  for (const t of [0.75, 0.8, 0.9, 0.95, 0.98, 0.99]) console.log(`  en confidence >= ${t}: ${confidences.filter((c) => c >= t).length}`);
  for (const prior of [0.5, 0.8, 0.9, 0.95, 0.99]) {
    const posterior = (p) => (p.en * (1 - prior)) / (p.en * (1 - prior) + p.ar * prior);
    console.log(`  Arabic prior ${prior}: ${toEn.filter((p) => posterior(p) >= 0.75).length} still en at the 0.75 threshold`);
  }

  // Real English is a judgment made by reading the captions ("كورس", "9 اور 10"), kept here so it can be checked.
  const REAL_ENGLISH = [479.8, 484.0, 484.5, 485.4];
  const kind = (s) => {
    if (REAL_ENGLISH.includes(+s.start.toFixed(1))) return 'real English';
    if (/^[\s>-]*([[(][^\])]*[\])][\s.]*)+$/.test(s.text)) return 'non-speech tag';
    return 'invented English';
  };
  const kinds = {};
  for (const s of en) { const k = kind(s); kinds[k] = kinds[k] ?? { segments: 0, seconds: 0 }; kinds[k].segments++; kinds[k].seconds += s.end - s.start; }
  console.log('## Kinds of en segment', kinds, 'fallback pieces ending en:', en.filter((s) => s.piece?.to === 'fallback').length, 'of', pieces.filter((p) => p.to === 'fallback').length);

  console.log('## Pieces by length: routed en / ar / fallback');
  for (const [lo, hi] of [[0, 1], [1, 2], [2, 4], [4, 8], [8, 99]]) {
    const xs = pieces.filter((p) => p.end - p.start >= lo && p.end - p.start < hi);
    const n = (to) => xs.filter((p) => p.to === to).length;
    console.log(`  ${lo}-${hi}s: ${n('en')} / ${n('ar')} / ${n('fallback')} (${Math.round((100 * n('en')) / (xs.length || 1))}% en)`);
  }

  // What each rule would still send to the English specialist, among pieces that went there.
  const specialist = en.filter((s) => s.piece?.to === 'en');
  const real = specialist.filter((s) => kind(s) === 'real English').length;
  const posterior = (p, prior) => (p.en * (1 - prior)) / (p.en * (1 - prior) + p.ar * prior);
  const rules = {
    'threshold 0.90': (s) => s.piece.en >= 0.9,
    'threshold 0.95': (s) => s.piece.en >= 0.95,
    'threshold 0.99': (s) => s.piece.en >= 0.99,
    'Arabic prior 0.90': (s) => posterior(s.piece, 0.9) >= 0.75,
    'Arabic prior 0.99': (s) => posterior(s.piece, 0.99) >= 0.75,
    'under 2 s never English': (s) => s.end - s.start >= 2,
    'under 2 s never English + prior 0.90': (s) => s.end - s.start >= 2 && posterior(s.piece, 0.9) >= 0.75,
  };
  console.log(`## Rules, of ${specialist.length} en-specialist segments (${real} real English): kept en, of which real`);
  for (const [name, keep] of Object.entries(rules)) {
    const kept = specialist.filter(keep);
    console.log(`  ${name}: ${kept.length}, ${kept.filter((s) => kind(s) === 'real English').length} real`);
  }

  fs.mkdirSync('eval/lab', { recursive: true });
  fs.writeFileSync(`eval/lab/routing-en-segments-${preset}-2026-10-31.md`, [
    `# Segments labeled \`en\`, ${preset} (generated by routing_stats.mjs; captions left out, see \`yt/cues.json\`)`, '',
    '| Start | Length | LID en / ar | Route | Call | Kind | Harness text |', '|---|---|---|---|---|---|---|',
    ...en.map((s) => `| ${s.start.toFixed(1)} | ${(s.end - s.start).toFixed(1)} | ${s.piece.en.toFixed(2)} / ${s.piece.ar.toFixed(2)} | ${s.piece.to} | ${s.piece.window ? 're-check window' : 'whole utterance'} | ${kind(s)}${s.loop ? ', loop' : ''} | ${s.text.slice(0, 70).replace(/\|/g, '/')} |`),
  ].join('\n') + '\n');

  const loops = segments.filter((s) => s.loop);
  console.log('## Loops by route', Object.fromEntries(['en', 'ar'].map((l) => {
    const xs = loops.filter((s) => s.lang === l);
    return [l, { segments: xs.length, seconds: seconds(xs), lengths: xs.map((s) => +(s.end - s.start).toFixed(1)) }];
  })), 'by piece route', loops.map((s) => s.piece?.to).join(','));

  const speakers = new Map();
  for (const s of segments) {
    const key = s.speaker ?? '(none)';
    const v = speakers.get(key) ?? { turns: 0, seconds: 0, first: s.start, last: s.end };
    v.turns++; v.seconds += s.end - s.start; v.last = s.end;
    speakers.set(key, v);
  }
  const rows = [...speakers].sort((a, b) => b[1].seconds - a[1].seconds);
  console.log('## Speakers: label, segments, seconds, first, last');
  for (const [k, v] of rows) console.log(`  ${k} ${v.turns} ${v.seconds.toFixed(1)} ${v.first.toFixed(0)} ${v.last.toFixed(0)}`);
  const labeled = rows.filter(([k]) => k !== '(none)');
  const total = labeled.reduce((sum, [, v]) => sum + v.seconds, 0);
  console.log({ labels: labeled.length, under10s: labeled.filter(([, v]) => v.seconds < 10).length, under5s: labeled.filter(([, v]) => v.seconds < 5).length,
    oneSegment: labeled.filter(([, v]) => v.turns === 1).length, top3Share: +(labeled.slice(0, 3).reduce((sum, [, v]) => sum + v.seconds, 0) / total).toFixed(3),
    top5Share: +(labeled.slice(0, 5).reduce((sum, [, v]) => sum + v.seconds, 0) / total).toFixed(3),
    unlabeledSegments: speakers.get('(none)')?.turns ?? 0, unlabeledSeconds: +(speakers.get('(none)')?.seconds ?? 0).toFixed(1) });
  const small = new Set(labeled.filter(([, v]) => v.seconds < 10).map(([k]) => k));
  const inSmall = segments.filter((s) => small.has(s.speaker));
  console.log({ secondsInSmallLabels: +labeled.filter(([k]) => small.has(k)).reduce((sum, [, v]) => sum + v.seconds, 0).toFixed(1), labeledSeconds: +total.toFixed(1),
    smallLabelsUnder2s: labeled.filter(([k, v]) => small.has(k) && v.seconds < 2).length,
    segmentsInSmall: inSmall.length, enOrTagInSmall: inSmall.filter((s) => s.lang === 'en').length, overlapInSmall: inSmall.filter((s) => s.overlap).length,
    labelsSpanningOver60s: labeled.filter(([, v]) => v.last - v.first > 60).map(([k]) => k).join(',') });
  console.log(log.filter((l) => /^(Segmentation|Speakers|Utterances)/.test(l)).join(' · '));
  console.log('ar-route LID on long loops:', log.filter((l) => /^(295\.|489\.|311\.)/.test(l)).join(' ; '));
}
