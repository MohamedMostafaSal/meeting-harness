import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_POLICY, windows, evenSplit, buildTurns, route, agglomerate, assignSpeakers,
  hallucinationReason, mergeSegments, wordErrorRate, characterErrorRate, normalizeText,
  toEvents, toMarkdown, similarity, groupUtterances,
} from '../harness.js';

const policy = DEFAULT_POLICY.router;
const en = { id: 'en', label: 'EN', languages: ['en'] };
const msa = { id: 'ar-msa', languages: ['ar'], variant: 'msa' };
const egyptian = { id: 'ar-eg', languages: ['ar'], variant: 'egyptian' };
const multi = { id: 'multi', fallback: true };

test('confident language goes to its specialist', () => {
  assert.deepEqual(route([{ language: 'en', confidence: 0.95 }], 3, [en, egyptian, multi], policy),
    { kind: 'specialist', model: 'en', language: 'en' });
});

test('Arabic prefers the Egyptian variant regardless of order', () => {
  assert.equal(route([{ language: 'ar', confidence: 0.9 }], 3, [msa, egyptian], policy).model, 'ar-eg');
  assert.equal(route([{ language: 'ar', confidence: 0.9 }], 3, [msa], policy).model, 'ar-msa');
});

test('ambiguous long turn is split, short one falls back without a hint', () => {
  const guesses = [{ language: 'ar', confidence: 0.62 }, { language: 'en', confidence: 0.38 }];
  assert.deepEqual(route(guesses, 5, [en, egyptian, multi], policy), { kind: 'split', window: 2 });
  const d = route(guesses, 3, [en, egyptian, multi], policy);
  assert.equal(d.kind, 'fallback');
  assert.equal(d.language, null);
  assert.equal(route(guesses, 9, [en, multi], policy, false).kind, 'fallback');
});

test('language without specialist falls back with hint, or becomes unroutable', () => {
  assert.equal(route([{ language: 'de', confidence: 0.99 }], 3, [en, multi], policy).language, 'de');
  assert.equal(route([{ language: 'de', confidence: 0.99 }], 3, [en], policy).kind, 'unroutable');
});

test('windows fold a trailing sliver; evenSplit never exceeds the limit', () => {
  const w = windows({ start: 0, end: 2.3 }, 1);
  assert.equal(w.length, 2);
  assert.equal(w.at(-1).end, 2.3);
  const parts = evenSplit({ start: 0, end: 70 }, 28);
  assert.equal(parts.length, 3);
  assert.ok(parts.every((p) => p.end - p.start <= 28));
  assert.equal(evenSplit({ start: 1, end: 5 }, 28).length, 1);
});

test('buildTurns: silence dropped, flicker absorbed, overlap flagged, chunks respected', () => {
  const raw = [
    { start: 0, end: 1, cls: 0, chunk: 0 },
    { start: 1, end: 4, cls: 1, chunk: 0 },
    { start: 4, end: 4.1, cls: 2, chunk: 0 }, // flicker → absorbed into speaker 1
    { start: 4.1, end: 6, cls: 1, chunk: 0 },
    { start: 6, end: 7, cls: 4, chunk: 0 },   // overlap
    { start: 7, end: 10, cls: 2, chunk: 0 },
    { start: 10, end: 12, cls: 2, chunk: 1 }, // same class id, new chunk → new turn
  ];
  const turns = buildTurns(raw, DEFAULT_POLICY.turns);
  assert.deepEqual(turns.map(({ start, end, overlap }) => ({ start, end, overlap })), [
    { start: 1, end: 6, overlap: false },
    { start: 6, end: 7, overlap: true },
    { start: 7, end: 10, overlap: false },
    { start: 10, end: 12, overlap: false },
  ]);
});

test('buildTurns bridges short pauses within one speaker in one chunk', () => {
  const raw = [
    { start: 0, end: 2, cls: 1, chunk: 0 },
    { start: 2, end: 2.6, cls: 0, chunk: 0 },  // short pause → bridged
    { start: 2.6, end: 5, cls: 1, chunk: 0 },
    { start: 5, end: 7, cls: 0, chunk: 0 },    // long pause → new turn
    { start: 7, end: 9, cls: 1, chunk: 0 },
    { start: 9, end: 9.5, cls: 0, chunk: 0 },  // short pause, but another speaker follows
    { start: 9.5, end: 10, cls: 2, chunk: 0 },
  ];
  const turns = buildTurns(raw, DEFAULT_POLICY.turns);
  assert.deepEqual(turns.map((t) => [t.start, t.end, t.cls]), [[0, 5, 1], [7, 9, 1], [9.5, 10, 2]]);
});

test('groupUtterances joins the same speaker across small gaps only', () => {
  const t = (start, end, overlap = false) => ({ start, end, overlap });
  const A = { id: 'S1' }, B = { id: 'S2' };
  const out = groupUtterances(
    [t(0, 2), t(2.5, 4), t(4.2, 5), t(5.1, 6, true), t(9, 10), t(10.5, 11), t(11.2, 12)],
    [A, A, B, A, A, null, null],
    DEFAULT_POLICY.utterances);
  assert.deepEqual(out.map((u) => [u.start, u.end, u.label?.id ?? null]),
    [[0, 4, 'S1'], [4.2, 5, 'S2'], [5.1, 6, 'S1'], [9, 10, 'S1'], [10.5, 11, null], [11.2, 12, null]]);
});

test('clustering groups voices in order of first appearance', () => {
  const A = [1, 0, 0], An = [0.95, 0.1, 0.05], B = [0, 1, 0], Bn = [0.1, 0.95, 0];
  assert.deepEqual(agglomerate([B, A, Bn, An], 0.7), [0, 1, 0, 1]);
  assert.deepEqual(agglomerate([], 0.7), []);
  assert.equal(similarity([1, 0], [1, 0, 0]), 0);
});

test('speaker assignment: enrolled match is one-to-one, overlap never creates a speaker', () => {
  const sp = { clusterThreshold: 0.7, enrollmentThreshold: 0.75 };
  const closer = [0.819152, 0.573576, 0], further = [0.766044, 0, 0.642788];
  const registry = [{ id: 'sara', name: 'Sara', embedding: [1, 0, 0] }];
  assert.deepEqual(assignSpeakers([further, closer], [true, true], registry, sp),
    [{ id: 'S1', name: null }, { id: 'sara', name: 'Sara' }]);

  const A = [1, 0, 0], B = [0, 1, 0];
  assert.deepEqual(assignSpeakers([A, null, B], [true, true, false], [], sp).map((l) => l?.id ?? null), ['S1', null, null]);
  assert.deepEqual(assignSpeakers([A], [true], [{ id: 'S1', name: 'Owner', embedding: B }], sp)[0].id, 'S2');
});

test('hallucination guard', () => {
  assert.equal(hallucinationReason('  ', 2), 'empty');
  assert.equal(hallucinationReason('...', 2), 'empty');
  assert.match(hallucinationReason('Thank you for watching!', 2), /hallucination/);
  assert.match(hallucinationReason('اشتركوا في القناة', 2), /hallucination/);
  assert.equal(hallucinationReason('the the the the the the the the the', 5), 'repeats itself');
  assert.equal(hallucinationReason('a'.repeat(100), 1), 'too much text for the audio length');
  assert.equal(hallucinationReason('خلينا نبدأ بالـ quarterly review', 3), null);
});

test('merge joins same speaker and language across small gaps only', () => {
  const seg = (start, end, speaker, lang, text) => ({ start, end, speaker, lang, text, conf: 0.9, producer: 'en', overlap: false, uncertain: false });
  const merged = mergeSegments([
    seg(0, 2, 'S1', 'en', 'hello'),
    seg(2.3, 4, 'S1', 'en', 'there'),
    seg(4.1, 5, 'S1', 'ar', 'أهلا'),
    seg(8, 9, 'S1', 'ar', 'ازيك'),
  ], DEFAULT_POLICY.merge);
  assert.deepEqual(merged.map((s) => s.text), ['hello there', 'أهلا', 'ازيك']);
  assert.deepEqual(merged.map((s) => s.id), ['s_0001', 's_0002', 's_0003']);
});

test('Arabic-aware error rates match the Swift core', () => {
  assert.equal(wordErrorRate('أحمد في الجامعة', 'احمد فِي الجامعـه').errors, 0);
  assert.equal(normalizeText('الساعة ٣ و٤٥'), normalizeText('الساعه 3 و45'));
  assert.equal(characterErrorRate('هنعمل الـ meeting بكرة', 'هنعمل ال meting بكره').errors, 1);
  assert.deepEqual(wordErrorRate("Let's start the review.", 'lets start review'), { errors: 1, referenceLength: 4, rate: 0.25 });
});

test('exports use the connector wire format', () => {
  const transcript = {
    meeting: 'm1',
    segments: [{ id: 's_0001', start: 12.4, end: 13.9, speaker: 'sara', speaker_name: 'Sara', lang: 'ar', text: 'خلينا نبدأ', conf: 0.94, producer: 'ar', overlap: false, uncertain: false, why: 'internal' }],
    gaps: [{ start: 3700, end: 3702, reason: 'language uncertain' }],
  };
  const events = toEvents(transcript);
  assert.deepEqual(events.map((e) => e.type), ['meeting.started', 'segment.final', 'meeting.ended']);
  assert.equal(events[1].segment.why, undefined);
  assert.deepEqual(events[1].segment.words, []);
  const md = toMarkdown(transcript);
  assert.match(md, /\*\*Sara\*\* `00:12 · ar`/);
  assert.match(md, /`1:01:40–1:01:42`: language uncertain/);
});
