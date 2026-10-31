// How much of a harness transcript is repetition loops, and the score without them.
// Reads yt/cues.json and yt/<preset>/harness.json (copied there after each web/test/youtube.js run).
//
//   cd web && node ../eval/lab/loop_stats.mjs [presets=balanced,light]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const { characterErrorRate, wordErrorRate } = await import(pathToFileURL(path.resolve('harness.js')).href);
const presets = (process.argv[2] ?? 'balanced,light').split(',');
const ref = JSON.parse(fs.readFileSync('../yt/cues.json', 'utf8')).map((c) => c.text).join(' ');

// Keeps one copy of any phrase of 1–4 words repeated 4+ times in a row.
function collapse(text) {
  const words = text.split(/\s+/).filter(Boolean);
  const out = [];
  let removed = 0;
  for (let i = 0; i < words.length;) {
    let span = 0, phrase = 0;
    for (let n = 1; n <= 4; n++) {
      const at = (r) => words.slice(i + n * r, i + n * (r + 1)).join(' ');
      let r = 1;
      while (i + n * (r + 1) <= words.length && at(r) === at(0)) r++;
      if (r >= 4 && r * n > span) { span = r * n; phrase = n; }
    }
    if (span) { out.push(...words.slice(i, i + phrase)); removed += span - phrase; i += span; }
    else out.push(words[i++]);
  }
  return { text: out.join(' '), removed, total: words.length };
}

const clean = (s) => s.replace(/>>/g, ' ').replace(/\[[^\]]*\]/g, ' ');
for (const preset of presets) {
  const { transcript } = JSON.parse(fs.readFileSync(`../yt/${preset}/harness.json`, 'utf8'));
  const segments = transcript.segments.map((s) => ({ s, c: collapse(s.text) }));
  const looped = segments.filter((x) => x.c.removed > 0);
  const lengths = looped.map((x) => x.s.end - x.s.start).sort((a, b) => a - b);
  const raw = transcript.segments.map((s) => s.text).join(' ');
  const collapsed = segments.map((x) => x.c.text).join(' ');
  const words = segments.reduce((sum, x) => sum + x.c.total, 0);
  const removed = segments.reduce((sum, x) => sum + x.c.removed, 0);
  console.log(preset, {
    words, removed, loopShare: +(removed / words).toFixed(3),
    loopSegments: looped.length, loopSegmentsUncertain: looped.filter((x) => x.s.uncertain).length,
    medianLoopSeconds: +lengths[lengths.length >> 1].toFixed(1),
    labeledEnglish: transcript.segments.filter((s) => s.lang === 'en').length, segments: segments.length,
    cer: +characterErrorRate(ref, raw).rate.toFixed(3),
    cerCollapsed: +characterErrorRate(ref, collapsed).rate.toFixed(3),
    cerCollapsedClean: +characterErrorRate(clean(ref), clean(collapsed)).rate.toFixed(3),
    werCollapsedClean: +wordErrorRate(clean(ref), clean(collapsed)).rate.toFixed(3),
  });
}
