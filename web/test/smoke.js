// CI only: runs the real models (downloaded from Hugging Face) through the same
// pipeline the browser uses. Two speeches by two different people are joined
// with a pause, so the run exercises speech detection, language ID, routing,
// speech-to-text and speaker clustering together.
import * as T from '@huggingface/transformers';
import wavefile from 'wavefile';
import { loadModels } from '../models.js';
import { runPipeline } from '../pipeline.js';
import { DEFAULT_POLICY, SAMPLE_RATE, toMarkdown } from '../harness.js';

const BASE = 'https://huggingface.co/datasets/Xenova/transformers.js-docs/resolve/main';

async function fetchWav(name) {
  const res = await fetch(`${BASE}/${name}`);
  if (!res.ok) throw new Error(`${name}: HTTP ${res.status}`);
  const wav = new wavefile.WaveFile(Buffer.from(await res.arrayBuffer()));
  wav.toBitDepth('32f');
  wav.toSampleRate(SAMPLE_RATE);
  let samples = wav.getSamples();
  if (Array.isArray(samples)) samples = samples[0];
  return Float32Array.from(samples);
}

function check(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    process.exitCode = 1;
  } else {
    console.log(`ok: ${message}`);
  }
}

const [jfk, mlk] = await Promise.all([fetchWav('jfk.wav'), fetchWav('mlk.wav')]);
const pause = new Float32Array(SAMPLE_RATE * 1.5);
const audio = new Float32Array(jfk.length + pause.length + mlk.length);
audio.set(jfk, 0);
audio.set(mlk, jfk.length + pause.length);

const t0 = Date.now();
const models = await loadModels(T, { preset: 'light', device: 'cpu' });
console.log(`models loaded in ${((Date.now() - t0) / 1000).toFixed(1)} s`);

const lid = await models.identify(jfk, ['en', 'ar']);
console.log('LID on JFK:', lid);
check(lid[0].language === 'en' && lid[0].confidence > 0.9, 'language ID picks English for JFK');

const t1 = Date.now();
const { transcript, log, timings } = await runPipeline(audio, models, {
  policy: DEFAULT_POLICY, allowedLanguages: ['en', 'ar'], meeting: 'smoke',
});
console.log(`pipeline ran in ${((Date.now() - t1) / 1000).toFixed(1)} s for ${(audio.length / SAMPLE_RATE).toFixed(1)} s of audio`);
console.log(log.join('\n'));
console.log(timings);
console.log(toMarkdown(transcript));

const text = transcript.segments.map((s) => s.text).join(' ').toLowerCase();
const speakers = new Set(transcript.segments.map((s) => s.speaker).filter(Boolean));
const jfkSpeakers = new Set(transcript.segments.filter((s) => s.end <= jfk.length / SAMPLE_RATE + 0.5).map((s) => s.speaker));
const mlkSpeakers = new Set(transcript.segments.filter((s) => s.start >= jfk.length / SAMPLE_RATE + 1).map((s) => s.speaker));
check(text.includes('ask not'), 'JFK words transcribed');
check(text.includes('dream'), 'MLK words transcribed');
check(transcript.segments.every((s) => s.lang === 'en'), 'every segment routed as English');
check(transcript.segments.every((s) => s.producer === 'en'), 'English specialist handled everything');
check(speakers.size >= 2, `at least two speakers found (${speakers.size})`);
check([...jfkSpeakers].every((s) => !mlkSpeakers.has(s)), 'JFK and MLK never share a speaker label');
