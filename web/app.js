// Page logic: audio in, settings, running the pipeline phases, rendering the transcript.
import { DEFAULT_POLICY, SAMPLE_RATE, timestamp, toEvents, toJSONLines, toMarkdown, wordErrorRate, characterErrorRate } from './harness.js';
import { decodeToMono16k, Recorder } from './audio.js';
import { recognizersFor, whisperModels } from './models.js';
import { newContext, mergeContext, piecesFor, assemble } from './pipeline.js';

const $ = (id) => document.getElementById(id);
const SAMPLE_URL = 'https://huggingface.co/datasets/Xenova/transformers.js-docs/resolve/main/jfk.wav';
const VOICES_KEY = 'meeting-harness.voices';

const state = { audio: null, audioName: '', result: null, names: {} };

/**
 * Runs one task in a fresh worker and terminates it afterwards. A WebAssembly
 * heap never shrinks, so this is how each phase's models leave memory before
 * the next phase loads its own.
 */
function runTask(message) {
  const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
  return new Promise((resolve, reject) => {
    worker.onmessage = ({ data }) => {
      if (data.type === 'download') return showDownload(data);
      if (data.type === 'stage') return showStage(data);
      worker.terminate();
      if (data.type === 'error') reject(new Error(data.message));
      else resolve(data);
    };
    worker.onerror = (e) => {
      worker.terminate();
      reject(new Error(e.message || 'The model worker could not start. Check the connection and reload.'));
    };
    worker.postMessage({ ...message, id: 1 });
  });
}

// MARK: - Settings

const settings = () => ({ preset: $('preset').value, device: $('device').value });
const languages = () => [...document.querySelectorAll('#languages input:checked')].map((i) => i.value);

function policy() {
  return {
    ...DEFAULT_POLICY,
    router: { ...DEFAULT_POLICY.router, languageConfidenceThreshold: +$('t-lang').value, splitWindow: +$('t-split').value },
    speakers: { ...DEFAULT_POLICY.speakers, clusterThreshold: +$('t-cluster').value, enrollmentThreshold: +$('t-enroll').value },
  };
}

for (const [id, unit] of [['t-lang', ''], ['t-split', ' s'], ['t-cluster', ''], ['t-enroll', '']]) {
  const update = () => ($(`${id}-out`).textContent = `${$(id).value}${unit}`);
  $(id).addEventListener('input', update);
  update();
}

function loadVoices() {
  try { return JSON.parse(localStorage.getItem(VOICES_KEY) ?? '[]'); } catch { return []; }
}
function saveVoices(voices) {
  try { localStorage.setItem(VOICES_KEY, JSON.stringify(voices)); } catch { /* private mode: voices last for this visit */ }
  renderVoices(voices);
}
let voicesCache = loadVoices();
function renderVoices(voices = voicesCache) {
  voicesCache = voices;
  $('voice-count').textContent = voices.length ? `(${voices.length} saved)` : '';
  $('voices').replaceChildren(...voices.map((v) => {
    const li = document.createElement('li');
    const name = document.createElement('span');
    name.textContent = v.name;
    const remove = document.createElement('button');
    remove.className = 'button secondary';
    remove.type = 'button';
    remove.textContent = 'Remove';
    remove.onclick = () => saveVoices(voicesCache.filter((x) => x.id !== v.id));
    li.append(name, remove);
    return li;
  }));
}
renderVoices();

// MARK: - Audio in

const recorder = new Recorder();
let ticker = 0;

$('record').addEventListener('click', async () => {
  try {
    if (!recorder.recording) {
      await recorder.start();
      $('record').setAttribute('aria-pressed', 'true');
      $('record-label').textContent = 'Stop';
      ticker = setInterval(() => ($('record-time').textContent = timestamp(recorder.elapsed).replace(/^0/, '')), 250);
    } else {
      clearInterval(ticker);
      $('record').setAttribute('aria-pressed', 'false');
      $('record-label').textContent = 'Record';
      const blob = await recorder.stop();
      await useAudio(blob, `Recording ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`);
    }
  } catch (e) {
    showError(e.name === 'NotAllowedError' ? 'Microphone access was refused. Allow it in Settings › Safari › Microphone, then try again.' : e.message);
  }
});

$('file').addEventListener('change', async (e) => {
  const file = e.target.files?.[0];
  if (file) await useAudio(file, file.name);
});

$('sample').addEventListener('click', async () => {
  try {
    $('sample').disabled = true;
    const res = await fetch(SAMPLE_URL);
    if (!res.ok) throw new Error(`Could not download the sample (HTTP ${res.status}).`);
    await useAudio(await res.blob(), 'Sample: JFK inaugural address (English)');
  } catch (e) {
    showError(e.message);
  } finally {
    $('sample').disabled = false;
  }
});

async function useAudio(blob, name) {
  hideError();
  try {
    state.audio = await decodeToMono16k(blob);
  } catch {
    return showError('This audio could not be decoded. Try an m4a, mp3 or wav file.');
  }
  state.audioName = name;
  $('audio-name').textContent = name;
  $('audio-duration').textContent = timestamp(state.audio.length / 16000);
  $('player').src = URL.createObjectURL(blob);
  $('audio-ready').hidden = false;
  $('run').disabled = false;
  $('run-hint').textContent = 'The first run downloads the models, which can take a few minutes.';
}

// MARK: - Enrollment

$('voice-record').addEventListener('click', async () => {
  const name = $('voice-name').value.trim();
  if (!name) return showError('Type your name before recording your voice.');
  hideError();
  const button = $('voice-record');
  button.disabled = true;
  try {
    const voice = new Recorder();
    await voice.start();
    for (let s = 10; s > 0; s--) {
      button.textContent = `Keep talking… ${s}`;
      await new Promise((r) => setTimeout(r, 1000));
    }
    button.textContent = 'Saving your voice…';
    const audio = await decodeToMono16k(await voice.stop());
    showProgress(true);
    phase = '';
    const { embedding } = await runTask({ task: 'embed', audio, settings: settings() });
    const id = name.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-') || `voice-${Date.now()}`;
    saveVoices([...voicesCache.filter((v) => v.id !== id), { id, name, embedding }]);
    $('voice-name').value = '';
  } catch (e) {
    showError(e.message);
  } finally {
    showProgress(false);
    button.disabled = false;
    button.textContent = 'Record 10 seconds';
  }
});

// MARK: - Run

let wakeLock = null;

$('run').addEventListener('click', async () => {
  if (!state.audio) return;
  hideError();
  $('run').disabled = true;
  $('results').hidden = true;
  showProgress(true);
  try { wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* optional */ }
  const started = performance.now();
  try {
    const result = await runStaged();
    result.wall = (performance.now() - started) / 1000;
    state.result = result;
    state.names = {};
    renderResult();
  } catch (e) {
    showError(e.message);
  } finally {
    wakeLock?.release?.().catch(() => {});
    showProgress(false);
    $('run').disabled = false;
  }
});

// One worker per model family, so at most one family is in memory at a time:
// voices → multilingual Whisper (language ID + its own pieces) → English Whisper.
async function runStaged() {
  const audio = state.audio;
  const config = settings();
  const options = {
    policy: policy(),
    registry: voicesCache,
    allowedLanguages: languages(),
    meeting: `m_${new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '')}`,
  };
  const { multilingual, english } = whisperModels(config.preset);
  const ctx = newContext();

  phase = 'Step 1 of 3 · ';
  const d = await runTask({ task: 'diarize', audio, settings: config, options });
  mergeContext(ctx, d.ctx);

  phase = 'Step 2 of 3 · ';
  const p = await runTask({ task: 'plan', audio, settings: config, options, utterances: d.utterances, modelId: multilingual });
  mergeContext(ctx, p.ctx);
  const texts = { ...p.texts };

  phase = 'Step 3 of 3 · ';
  if (piecesFor(p.pieces, recognizersFor(config.preset), english).length) {
    const e = await runTask({ task: 'transcribe', audio, settings: config, options, pieces: p.pieces, modelId: english });
    mergeContext(ctx, e.ctx);
    Object.assign(texts, e.texts);
  }
  return assemble({ ...options, utterances: d.utterances, pieces: p.pieces, texts, duration: audio.length / SAMPLE_RATE }, ctx);
}

// MARK: - Progress

let phase = '';

const downloads = new Map();

function showProgress(on) {
  $('progress').hidden = !on;
  if (on) {
    downloads.clear();
    $('downloads').replaceChildren();
    $('stage').textContent = 'Starting…';
    $('stage-bar').removeAttribute('value');
  }
}

function showStage({ stage, done, total }) {
  $('stage').textContent = phase + (total ? `${stage}: ${done + 1} of ${total}` : stage);
  if (total) $('stage-bar').value = done / total;
  else $('stage-bar').removeAttribute('value');
}

function showDownload({ file, loaded, total, status }) {
  if (!downloads.has(file)) {
    const li = document.createElement('li');
    li.innerHTML = '<span></span><span></span>';
    li.firstChild.textContent = file;
    downloads.set(file, li);
    $('downloads').append(li);
  }
  const li = downloads.get(file);
  li.lastChild.textContent = status === 'done' ? 'ready' : total ? `${Math.round((loaded / total) * 100)}% of ${mb(total)}` : '…';
}

const mb = (bytes) => `${(bytes / 1e6).toFixed(bytes > 1e7 ? 0 : 1)} MB`;

// MARK: - Results

const speakerColor = new Map();
function colorFor(id) {
  if (!id) return 'var(--muted)';
  if (!speakerColor.has(id)) speakerColor.set(id, `var(--sp${(speakerColor.size % 6) + 1})`);
  return speakerColor.get(id);
}

function transcriptWithNames() {
  const t = structuredClone(state.result.transcript);
  for (const s of t.segments) if (s.speaker && state.names[s.speaker]) s.speaker_name = state.names[s.speaker];
  return t;
}

function renderResult() {
  const { duration, wall, timings, log } = state.result;
  const t = transcriptWithNames();
  speakerColor.clear();

  const speakerIds = [...new Set(t.segments.map((s) => s.speaker).filter(Boolean))];
  const langs = [...new Set(t.segments.map((s) => s.lang).filter(Boolean))];
  const stats = [
    ['Audio', timestamp(duration)],
    ['Processing', `${wall.toFixed(0)} s`],
    ['Speed', `${(duration / wall).toFixed(2)}× real time`],
    ['Speakers', String(speakerIds.length)],
    ['Languages', langs.join(' + ') || '–'],
  ];
  $('stats').replaceChildren(...stats.map(([k, v]) => {
    const div = document.createElement('div');
    div.innerHTML = '<dt></dt><dd></dd>';
    div.firstChild.textContent = k;
    div.lastChild.textContent = v;
    return div;
  }));

  $('speakers').replaceChildren(...speakerIds.map((id) => {
    const label = document.createElement('label');
    label.className = 'speaker-edit';
    label.style.setProperty('--sp', colorFor(id));
    const tag = document.createElement('span');
    tag.className = 'who';
    tag.style.color = colorFor(id);
    tag.textContent = id;
    const input = document.createElement('input');
    input.type = 'text';
    input.id = `name-${id}`;
    input.placeholder = 'Rename';
    input.value = state.names[id] ?? t.segments.find((s) => s.speaker === id)?.speaker_name ?? '';
    input.addEventListener('change', () => {
      state.names[id] = input.value.trim();
      renderTranscript(transcriptWithNames());
    });
    label.append(tag, input);
    return label;
  }));

  renderTranscript(t);

  const total = Object.values(timings).reduce((a, b) => a + b, 0) || 1;
  const names = { segmentation: 'Speech + turns', languageID: 'Language ID', transcription: 'Speech-to-text', embedding: 'Voices' };
  $('timings').replaceChildren(...Object.entries(timings).map(([k, ms]) => {
    const row = document.createElement('div');
    row.className = 'timing';
    row.innerHTML = '<span></span><span class="bar"></span><span class="mono"></span>';
    row.children[0].textContent = names[k] ?? k;
    row.children[1].style.width = `${(ms / total) * 100}%`;
    row.children[2].textContent = `${(ms / 1000).toFixed(1)} s`;
    return row;
  }));
  $('log').textContent = log.join('\n');
  $('results').hidden = false;
  $('results').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
}

function renderTranscript(t) {
  if (!t.segments.length) {
    const li = document.createElement('li');
    li.className = 'hint';
    li.textContent = 'No speech was found in this audio.';
    $('transcript').replaceChildren(li);
  } else {
    $('transcript').replaceChildren(...t.segments.map((s) => {
      const li = document.createElement('li');
      li.className = 'seg';
      li.style.setProperty('--sp', colorFor(s.speaker));
      const when = el('span', 'when', timestamp(s.start));
      const meta = el('div', 'meta');
      meta.append(el('span', 'who', s.speaker_name || s.speaker || 'Speaker'));
      if (s.lang) meta.append(el('span', 'tag', s.lang));
      if (s.overlap) meta.append(el('span', 'tag warn', 'overlap'));
      if (s.uncertain) meta.append(el('span', 'tag warn', 'uncertain'));
      const text = el('p', 'text', s.text);
      text.dir = 'auto';
      if (s.lang) text.lang = s.lang;
      li.append(when, meta, text);
      if (s.why) li.append(el('p', 'why', s.why));
      li.append(el('p', 'route', `${s.producer} · language confidence ${s.conf.toFixed(2)}`));
      return li;
    }));
  }
  $('gaps').replaceChildren(...t.gaps.map((g) => el('p', 'gaps', `Not transcribed ${timestamp(g.start)}–${timestamp(g.end)}: ${g.reason}`)));
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// MARK: - Export

async function copy(text, what) {
  try {
    await navigator.clipboard.writeText(text);
    $('export-status').textContent = `Copied ${what}.`;
  } catch {
    $('export-status').textContent = 'Copying was blocked by the browser. Use Save or share instead.';
  }
}

$('copy-md').addEventListener('click', () => copy(toMarkdown(transcriptWithNames()), 'Markdown'));
$('copy-jsonl').addEventListener('click', () => copy(toJSONLines(toEvents(transcriptWithNames())), 'events'));
$('share').addEventListener('click', async () => {
  const t = transcriptWithNames();
  const files = [
    new File([toMarkdown(t)], `${t.meeting}.md`, { type: 'text/markdown' }),
    new File([toJSONLines(toEvents(t))], `${t.meeting}.jsonl`, { type: 'application/json' }),
  ];
  try {
    if (navigator.canShare?.({ files })) {
      await navigator.share({ files, title: `Meeting ${t.meeting}` });
      $('export-status').textContent = 'Shared.';
      return;
    }
  } catch (e) {
    if (e.name === 'AbortError') return;
  }
  for (const f of files) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(f);
    a.download = f.name;
    a.click();
  }
  $('export-status').textContent = 'Downloaded the Markdown and JSON Lines files.';
});

$('score').addEventListener('click', () => {
  const reference = $('reference').value;
  if (!reference.trim() || !state.result) return;
  const hypothesis = state.result.transcript.segments.map((s) => s.text).join(' ');
  const w = wordErrorRate(reference, hypothesis);
  const c = characterErrorRate(reference, hypothesis);
  $('score-out').textContent = `Word error rate ${(w.rate * 100).toFixed(1)}% (${w.errors}/${w.referenceLength}) · Character error rate ${(c.rate * 100).toFixed(1)}%`;
});

// MARK: - Errors

function showError(message) {
  $('error').textContent = message;
  $('error').hidden = false;
}
function hideError() { $('error').hidden = true; }
