// CI only: runs the real models (downloaded from Hugging Face) through the same
// pipeline the browser uses. Two speeches by two different people are joined
// with a pause, so the run exercises speech detection, language ID, routing,
// speech-to-text and speaker clustering together.
import * as T from '@huggingface/transformers';
import wavefile from 'wavefile';
import { loadVoiceModels, loadWhisper, whisperModels } from '../models.js';
import { newContext, diarize, plan, transcribe, piecesFor, assemble } from '../pipeline.js';
import { DEFAULT_POLICY, SAMPLE_RATE, toMarkdown, normalizeText, normalizeLevel } from '../harness.js';

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
// Same ingest as the page: loudness normalization, at the quiet level of a phone recording.
const quietAudio = audio.map((x) => x * 0.03);
const { audio: normalized, gainDb } = normalizeLevel(quietAudio);
console.log(`normalized a quiet copy by +${gainDb.toFixed(1)} dB`);
audio.set(normalized);

// Same staging as the browser: one model family at a time.
const settings = { preset: 'light', device: 'cpu' };
const { multilingual, english } = whisperModels(settings.preset);
const options = { policy: DEFAULT_POLICY, allowedLanguages: ['en', 'ar'], meeting: 'smoke', debug: true };
const ctx = newContext();
const t1 = Date.now();

const voices = await loadVoiceModels(T, settings);
const utterances = await diarize(audio, voices, options, ctx);

const multi = await loadWhisper(T, settings, multilingual);
const lid = await multi.identify(jfk, ['en', 'ar']);
console.log('LID on JFK:', lid);
check(lid[0].language === 'en' && lid[0].confidence > 0.9, 'language ID picks English for JFK');

const pieces = await plan(audio, utterances, multi, options, ctx);
const texts = await transcribe(audio, pieces, piecesFor(pieces, multi.recognizers, multilingual), multi, {}, ctx);

const en = await loadWhisper(T, settings, english);
Object.assign(texts, await transcribe(audio, pieces, piecesFor(pieces, en.recognizers, english), en, {}, ctx));

const { transcript, log, timings } = assemble({ ...options, utterances, pieces, texts, duration: audio.length / SAMPLE_RATE }, ctx);
console.log(`pipeline ran in ${((Date.now() - t1) / 1000).toFixed(1)} s for ${(audio.length / SAMPLE_RATE).toFixed(1)} s of audio`);
console.log(log.join('\n'));
console.log(timings);
console.log(toMarkdown(transcript));

const text = normalizeText(transcript.segments.map((s) => s.text).join(' '));
const speakers = new Set(transcript.segments.map((s) => s.speaker).filter(Boolean));
const jfkSpeakers = new Set(transcript.segments.filter((s) => s.end <= jfk.length / SAMPLE_RATE + 0.5).map((s) => s.speaker));
const mlkSpeakers = new Set(transcript.segments.filter((s) => s.start >= jfk.length / SAMPLE_RATE + 1).map((s) => s.speaker));
check(text.includes('ask not what your country'), 'JFK words transcribed');
check(text.includes('dream'), 'MLK words transcribed');
check(transcript.segments.every((s) => s.lang === 'en'), 'every segment routed as English');
check(transcript.segments.every((s) => s.producer === 'en'), 'English specialist handled everything');
// The MLK recording has a crowd shouting back, which may rightly count as another voice.
const long = (s) => s.end - s.start >= 3;
const jfkMain = new Set(transcript.segments.filter((s) => long(s) && s.end <= jfk.length / SAMPLE_RATE + 0.5).map((s) => s.speaker));
const mlkMain = new Set(transcript.segments.filter((s) => long(s) && s.start >= jfk.length / SAMPLE_RATE + 1).map((s) => s.speaker));
check(speakers.size >= 2, `at least two speakers found (${speakers.size})`);
check(jfkMain.size === 1 && mlkMain.size === 1, 'each speech is one speaker throughout');
check([...jfkSpeakers].every((s) => !mlkSpeakers.has(s)), 'JFK and MLK never share a speaker label');
