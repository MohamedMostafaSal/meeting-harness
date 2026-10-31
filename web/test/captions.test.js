import test from 'node:test';
import assert from 'node:assert/strict';
import { scoreAgainstCaptions } from './captions.js';
import { characterErrorRate, wordErrorRate } from '../harness.js';

const fns = { characterErrorRate, wordErrorRate };

test('captions score over the whole span, so a split across a minute boundary is not an error', () => {
  const cues = [{ start: 55, end: 62, text: 'خلينا نبدأ' }, { start: 62, end: 70, text: 'the quarterly review' }];
  const segments = [{ start: 40, end: 58, text: 'خلينا' }, { start: 58, end: 75, text: 'نبدأ the quarterly review' }];
  const score = scoreAgainstCaptions(cues, segments, 120, fns);
  assert.equal(score.cer, 0);
  assert.equal(score.windows.length, 2);
  assert.ok(score.windows[0].cer > 0, 'per-minute rows can disagree at the boundary');
});

test('Arabic spelling variants are not errors', () => {
  const score = scoreAgainstCaptions([{ start: 0, end: 5, text: 'أنا رايحة المدرسة' }], [{ start: 0, end: 5, text: 'انا رايحه المدرسه' }], 60, fns);
  assert.equal(score.cer, 0);
});
