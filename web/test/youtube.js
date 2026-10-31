// CI only: runs the browser's pipeline (real models, same staging) on a YouTube test set
// made by eval/youtube_fetch.py, and scores it against the video's captions.
//
//   node test/youtube.js <dir> [preset]
//
// Writes <dir>/harness.md (transcript), <dir>/harness.json and <dir>/score.md.
import fs from 'node:fs';
import path from 'node:path';
import * as T from '@huggingface/transformers';
import wavefile from 'wavefile';
import { loadVoiceModels, loadWhisper, whisperModels } from '../models.js';
import { newContext, diarize, plan, transcribe, piecesFor, assemble } from '../pipeline.js';
import { DEFAULT_POLICY, SAMPLE_RATE, toMarkdown, normalizeLevel, characterErrorRate, wordErrorRate, timestamp } from '../harness.js';
import { scoreAgainstCaptions } from './captions.js';

const [dir = 'yt', preset = 'balanced'] = process.argv.slice(2);
const info = JSON.parse(fs.readFileSync(path.join(dir, 'info.json'), 'utf8'));
const cues = JSON.parse(fs.readFileSync(path.join(dir, 'cues.json'), 'utf8'));

const wav = new wavefile.WaveFile(fs.readFileSync(path.join(dir, 'audio.wav')));
wav.toBitDepth('32f');
let samples = wav.getSamples();
if (Array.isArray(samples)) samples = samples[0];
const { audio, gainDb } = normalizeLevel(Float32Array.from(samples));
const seconds = audio.length / SAMPLE_RATE;
console.log(`${info.title}: ${seconds.toFixed(0)} s, normalized by ${gainDb.toFixed(1)} dB, ${preset} models`);

// Same staging as the browser: one model family at a time.
const settings = { preset, device: 'cpu' };
const { multilingual, english } = whisperModels(preset);
const options = { policy: DEFAULT_POLICY, allowedLanguages: ['en', 'ar'], meeting: 'youtube' };
const ctx = newContext();
const started = Date.now();

const voices = await loadVoiceModels(T, settings);
const utterances = await diarize(audio, voices, options, ctx);
console.log(`${utterances.length} utterances`);
const multi = await loadWhisper(T, settings, multilingual);
const pieces = await plan(audio, utterances, multi, options, ctx);
const texts = await transcribe(audio, pieces, piecesFor(pieces, multi.recognizers, multilingual), multi, {}, ctx);
const en = await loadWhisper(T, settings, english);
Object.assign(texts, await transcribe(audio, pieces, piecesFor(pieces, en.recognizers, english), en, {}, ctx));
const { transcript, log, timings } = assemble({ ...options, utterances, pieces, texts, duration: seconds }, ctx);
const wall = (Date.now() - started) / 1000;

fs.writeFileSync(path.join(dir, 'harness.md'), toMarkdown(transcript));
fs.writeFileSync(path.join(dir, 'harness.json'), JSON.stringify({ transcript, log, timings }, null, 1));

const segments = transcript.segments.map((s) => ({ start: s.start, end: s.end, text: s.text }));
const score = scoreAgainstCaptions(cues, segments, seconds, { characterErrorRate, wordErrorRate });
const speakers = new Set(transcript.segments.map((s) => s.speaker).filter(Boolean));
const languages = {};
for (const s of transcript.segments) languages[s.lang] = (languages[s.lang] ?? 0) + (s.end - s.start);
const uncertain = transcript.segments.filter((s) => s.uncertain).length;

const lines = [
  `## Web harness (${preset} models: ${multilingual.split('/').pop()} + ${english.split('/').pop()})`, '',
  `| | |`, `|---|---|`,
  `| Character error rate vs captions | **${(score.cer * 100).toFixed(1)}%** |`,
  `| Word error rate vs captions | ${(score.wer * 100).toFixed(1)}% |`,
  `| Speakers found | ${speakers.size} |`,
  `| Speech by language | ${Object.entries(languages).map(([l, s]) => `${l} ${timestamp(s)}`).join(', ')} |`,
  `| Segments marked uncertain | ${uncertain} of ${transcript.segments.length} |`,
  `| Gaps (not transcribed) | ${transcript.gaps.length} |`,
  `| Processing time | ${wall.toFixed(0)} s for ${seconds.toFixed(0)} s of audio on this machine |`, '',
  '| Minute | CER | Caption words | Harness words |', '|---|---|---|---|',
  ...score.windows.map((w) => `| ${timestamp(w.start)} | ${w.cer === null ? '–' : `${(w.cer * 100).toFixed(0)}%`} | ${w.refWords} | ${w.hypWords} |`),
];
fs.writeFileSync(path.join(dir, 'score.md'), lines.join('\n') + '\n');
fs.writeFileSync(path.join(dir, 'side-by-side.md'), score.sideBySide);
console.log(lines.join('\n'));
console.log(log.join('\n'));
console.log(timings);
