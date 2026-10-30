import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runPipeline } from '../pipeline.js';
import { DEFAULT_POLICY, SAMPLE_RATE } from '../harness.js';

// The README's demo meeting with scripted models: Sara (enrolled) opens in English,
// a guest answers, then Sara switches from Egyptian Arabic to English mid-sentence.
function demo() {
  const audio = new Float32Array(20 * SAMPLE_RATE);
  const timeOf = (clip) => {
    const start = (clip.byteOffset / 4) / SAMPLE_RATE;
    return { start, end: start + clip.length / SAMPLE_RATE };
  };
  const calls = [];
  const models = {
    recognizers: [
      { id: 'en', label: 'EN', languages: ['en'] },
      { id: 'ar', label: 'AR', languages: ['ar'], variant: 'general' },
      { id: 'multi', label: 'MULTI', fallback: true },
    ],
    async segment() {
      return [
        { start: 0, end: 2, cls: 0, chunk: 0 },
        { start: 2, end: 3.6, cls: 1, chunk: 0 },
        { start: 3.6, end: 5.5, cls: 2, chunk: 0 },
        { start: 5.5, end: 12.4, cls: 0, chunk: 0 },
        { start: 12.4, end: 18, cls: 1, chunk: 1 },
        { start: 18, end: 20, cls: 0, chunk: 1 },
      ];
    },
    async embed(clip) {
      const { start } = timeOf(clip);
      return start >= 3.6 && start < 5.5 ? [0.1, 0.95, 0.05] : [0.95, 0.1, 0.05];
    },
    async identify(clip) {
      const r = timeOf(clip);
      if (r.end <= 6) return [{ language: 'en', confidence: 0.98 }];
      if (r.end - r.start > 3) return [{ language: 'ar', confidence: 0.6 }, { language: 'en', confidence: 0.4 }];
      return r.start < 14 ? [{ language: 'ar', confidence: 0.93 }] : [{ language: 'en', confidence: 0.96 }];
    },
    async transcribe(clip, { model, language }) {
      const r = timeOf(clip);
      calls.push({ model, language, ...r });
      if (model === 'ar') return { text: 'خلينا نبدأ بالـ' };
      if (r.start < 3.6) return { text: "let's get started" };
      if (r.start < 6) return { text: 'sounds good' };
      return { text: 'quarterly review' };
    },
  };
  return { audio, models, calls };
}

const registry = [{ id: 'sara', name: 'Sara', embedding: [1, 0, 0] }];

test('code-switched turn is split and routed per language, speakers named', async () => {
  const { audio, models, calls } = demo();
  const { transcript, log } = await runPipeline(audio, models, { policy: DEFAULT_POLICY, registry, meeting: 'm1' });

  assert.deepEqual(transcript.segments.map((s) => s.text), ["let's get started", 'sounds good', 'خلينا نبدأ بالـ', 'quarterly review']);
  assert.deepEqual(transcript.segments.map((s) => s.lang), ['en', 'en', 'ar', 'en']);
  assert.deepEqual(transcript.segments.map((s) => s.speaker), ['sara', 'S1', 'sara', 'sara']);
  assert.deepEqual(transcript.segments.map((s) => s.speaker_name), ['Sara', null, 'Sara', 'Sara']);
  // 12.4–18 in 2 s windows: [12.4,14.4] [14.4,16.4] [16.4,18]; the first is Arabic.
  assert.equal(transcript.segments[2].end, 14.4);
  assert.ok(!calls.some((c) => c.model === 'multi'), 'every part had a confident specialist');
  assert.ok(log.some((l) => l.includes('ambiguous')));
});

test('silence never reaches speech-to-text', async () => {
  const { audio, models, calls } = demo();
  models.segment = async () => [{ start: 0, end: 20, cls: 0, chunk: 0 }];
  const { transcript } = await runPipeline(audio, models, { policy: DEFAULT_POLICY });
  assert.equal(transcript.segments.length, 0);
  assert.equal(calls.length, 0);
});

test('hallucinated text is kept but flagged; empty text is dropped', async () => {
  const { audio, models } = demo();
  models.transcribe = async (clip, { model }) => ({ text: model === 'ar' ? '' : 'Thank you for watching.' });
  const { transcript } = await runPipeline(audio, models, { policy: DEFAULT_POLICY, registry });
  assert.ok(transcript.segments.length > 0);
  assert.ok(transcript.segments.every((s) => s.uncertain && s.lang === 'en'));
});

test('unroutable speech becomes a gap', async () => {
  const { audio, models } = demo();
  models.recognizers = [{ id: 'en', label: 'EN', languages: ['en'] }];
  models.identify = async () => [{ language: 'de', confidence: 0.99 }];
  const { transcript } = await runPipeline(audio, models, { policy: DEFAULT_POLICY });
  assert.equal(transcript.segments.length, 0);
  assert.equal(transcript.gaps.length, 3);
});
