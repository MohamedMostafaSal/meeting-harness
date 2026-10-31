// Scores a transcript against caption cues: once over the whole span (so text that
// lands either side of a window boundary isn't counted as wrong), then per window
// to show where it goes wrong. Items are assigned to the window holding their midpoint.

export function scoreAgainstCaptions(cues, segments, seconds, { characterErrorRate, wordErrorRate }, windowSeconds = 60) {
  const join = (items) => items.map((x) => x.text).join(' ');
  const inSpan = (x) => x.start < seconds;
  const ref = join(cues.filter(inSpan));
  const hyp = join(segments.filter(inSpan));
  const cer = characterErrorRate(ref, hyp).rate;
  const wer = wordErrorRate(ref, hyp).rate;

  const windows = [];
  const side = [];
  const words = (text) => text.split(/\s+/).filter(Boolean).length;
  for (let start = 0; start < seconds; start += windowSeconds) {
    const end = Math.min(seconds, start + windowSeconds);
    const inside = (x) => (x.start + x.end) / 2 >= start && (x.start + x.end) / 2 < end;
    const r = join(cues.filter(inside));
    const h = join(segments.filter(inside));
    windows.push({ start, end, cer: r ? characterErrorRate(r, h).rate : null, refWords: words(r), hypWords: words(h) });
    side.push(`### ${clock(start)}–${clock(end)}`, '', `**Captions:** ${r || '–'}`, '', `**Harness:** ${h || '–'}`, '');
  }
  return { cer, wer, windows, sideBySide: side.join('\n') + '\n' };
}

function clock(s) {
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
}
