// Page logic: audio in, settings, running the pipeline phases, rendering the transcript.
import { DEFAULT_POLICY, SAMPLE_RATE, normalizeLevel, timestamp, toEvents, toJSONLines, toMarkdown, wordErrorRate, characterErrorRate } from './harness.js';
import { decodeToMono16k, Recorder } from './audio.js';
import { recognizersFor, whisperModels } from './models.js';
import { newContext, mergeContext, piecesFor, assemble } from './pipeline.js';
import { LiveCapture, LiveCaptioner, liveCaptionsSupported } from './live.js';
import { DEMO_RESULT, DEMO_CAPTIONS } from './demo.js';

const $ = (id) => document.getElementById(id);
const SAMPLE_URL = 'https://huggingface.co/datasets/Xenova/transformers.js-docs/resolve/main/jfk.wav';
const VOICES_KEY = 'meeting-harness.voices';

const state = { audio: null, audioName: '', result: null, names: {}, diag: {} };

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
      const where = e.filename ? ` (${e.filename.split('/').pop()}:${e.lineno})` : '';
      reject(new Error((e.message || 'The model worker stopped unexpectedly. Check the connection and reload.') + where));
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
let capture = null;
let captioner = null;
let meterFrame = 0;

$('record').addEventListener('click', async () => {
  hideError();
  try {
    await recorder.start();
  } catch (e) {
    return showError(e.name === 'NotAllowedError' ? 'Microphone access was refused. Allow it in your browser settings, then try again.' : e.message);
  }
  $('studio').dataset.state = 'recording';
  $('audio-ready').hidden = true;
  $('results').hidden = true;
  $('record-time').textContent = '00:00';
  renderCaptions([], null);
  ticker = setInterval(() => ($('record-time').textContent = timestamp(recorder.elapsed)), 250);
  try { wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* optional */ }

  capture = new LiveCapture(30);
  try { await capture.start(recorder.stream); } catch { capture = null; }
  drawMeter();
  if (!capture) {
    $('live-hint').textContent = 'Live captions are unavailable in this browser. The full transcript is made when you stop.';
  } else if (!liveCaptionsSupported()) {
    $('live-hint').textContent = 'Live captions need more memory than iPhone browsers give a page. The full transcript is made when you stop.';
  } else {
    $('live-hint').textContent = 'Live captions are drafts. The full transcript, with speakers, is made when you stop.';
    captioner = new LiveCaptioner(capture, {
      settings: { ...settings(), preset: 'light' },
      allowed: languages(),
      onUpdate: renderCaptions,
      onError: () => ($('live-hint').textContent = 'Live captions stopped. Recording continues; the full transcript is made when you stop.'),
    });
  }
});

$('stop').addEventListener('click', async () => {
  clearInterval(ticker);
  cancelAnimationFrame(meterFrame);
  captioner?.stop();
  captioner = null;
  capture?.stop();
  capture = null;
  wakeLock?.release?.().catch(() => {});
  const recordedSeconds = recorder.elapsed;
  const mimeType = recorder.mimeType;
  const blob = await recorder.stop();
  $('studio').dataset.state = 'idle';
  const ok = await useAudio(blob, `Recording ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`, { recordedSeconds, mimeType });
  if (ok) $('run').click();
});

/** Recent input levels as mirrored bars on the night background. */
function drawMeter() {
  const canvas = $('meter');
  const dpr = devicePixelRatio || 1;
  const width = canvas.clientWidth, height = canvas.clientHeight;
  if (canvas.width !== width * dpr) { canvas.width = width * dpr; canvas.height = height * dpr; }
  const g = canvas.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, width, height);
  const bars = 48, gap = 3, bar = Math.max(2, (width - gap * (bars - 1)) / bars);
  meterLevels.push(capture ? capture.level() : demoLevel());
  while (meterLevels.length > bars) meterLevels.shift();
  meterLevels.forEach((level, i) => {
    const h = Math.max(4, level * height);
    g.fillStyle = `rgba(63, 181, 158, ${0.35 + 0.65 * (i / bars)})`;
    g.beginPath();
    g.roundRect?.(i * (bar + gap), (height - h) / 2, bar, h, bar / 2) ?? g.rect(i * (bar + gap), (height - h) / 2, bar, h);
    g.fill();
  });
  if ($('studio').dataset.state === 'recording') meterFrame = requestAnimationFrame(drawMeter);
}
const meterLevels = [];
let demoTick = 0;
/** A plausible speech envelope, for demo mode. */
function demoLevel() {
  demoTick += 1;
  const x = demoTick / 6;
  return Math.max(0.05, 0.4 + 0.3 * Math.sin(x) * Math.cos(x * 0.37) + 0.15 * Math.sin(x * 2.3));
}

function renderCaptions(lines, draft) {
  const nodes = [...lines.map((l) => captionNode(l, false)), ...(draft ? [captionNode(draft, true)] : [])];
  $('captions').replaceChildren(...nodes);
  $('captions').scrollTop = $('captions').scrollHeight;
}

function captionNode(line, isDraft) {
  const p = el('p', `caption${isDraft ? ' draft' : ''}`, line.text);
  p.dir = line.language === 'ar' ? 'rtl' : 'ltr';
  if (line.language) p.lang = line.language;
  return p;
}

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

/** Decodes and normalizes audio for the pipeline. Returns false if it can't be used. */
async function useAudio(blob, name, { recordedSeconds = null, mimeType = '' } = {}) {
  hideError();
  state.diag = { input: name, type: blob.type || mimeType || 'unknown', bytes: blob.size, recordedSeconds };
  let decoded;
  try {
    decoded = await decodeToMono16k(blob);
  } catch (e) {
    state.diag.decodeError = String(e?.message ?? e);
    showError(`This audio could not be decoded (${state.diag.type}). Try an m4a, mp3 or wav file.`);
    return false;
  }
  // D1: quiet phone recordings otherwise read as silence to the speech detector.
  const { audio, gainDb, speechDb } = normalizeLevel(decoded);
  state.audio = audio;
  const seconds = audio.length / SAMPLE_RATE;
  Object.assign(state.diag, { decodedSeconds: +seconds.toFixed(2), speechDb: +speechDb.toFixed(1), gainDb: +gainDb.toFixed(1) });

  const notes = [];
  if (recordedSeconds && seconds < recordedSeconds * 0.7) {
    notes.push(`Only ${seconds.toFixed(1)} s of the ${recordedSeconds.toFixed(1)} s recording could be read.`);
  }
  if (!Number.isFinite(speechDb) || speechDb < -60) notes.push('This audio is almost silent. Check the microphone and record closer to the sound.');
  state.audioName = name;
  $('audio-name').textContent = name;
  $('audio-duration').textContent = `${timestamp(seconds)} · speech level ${Number.isFinite(speechDb) ? speechDb.toFixed(0) : '–∞'} dB` +
    (gainDb > 1 ? `, raised ${gainDb.toFixed(0)} dB` : '');
  $('audio-note').textContent = notes.join(' ');
  $('audio-note').hidden = !notes.length;
  $('player').src = URL.createObjectURL(blob);
  $('audio-ready').hidden = false;
  $('run').disabled = false;
  $('run-hint').textContent = 'The first run downloads the models, which can take a few minutes.';
  return true;
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
    state.diag.settings = { ...settings(), languages: languages() };
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

  // Errors name the step they happened in, and keep the log gathered so far.
  const step = async (label, message) => {
    phase = `${label} · `;
    state.diag.step = label;
    breadcrumb({ status: 'running', step: label, stage: 'starting' });
    showStage({ stage: 'Loading models' });
    try {
      const out = await runTask(message);
      if (out.ctx) mergeContext(ctx, out.ctx);
      return out;
    } catch (e) {
      state.diag.log = ctx.log;
      throw new Error(`${label} failed: ${e.message}`);
    }
  };

  const d = await step('Step 1 of 3', { task: 'diarize', audio, settings: config, options });
  if (!d.utterances.length) {
    ctx.log.push('No speech found: the speech detector heard only silence or noise.');
    return assemble({ ...options, utterances: [], pieces: [], texts: {}, duration: audio.length / SAMPLE_RATE }, ctx);
  }

  const p = await step('Step 2 of 3', { task: 'plan', audio, settings: config, options, utterances: d.utterances, modelId: multilingual });
  const texts = { ...p.texts };

  if (piecesFor(p.pieces, recognizersFor(config.preset), english).length) {
    const e = await step('Step 3 of 3', { task: 'transcribe', audio, settings: config, options, pieces: p.pieces, modelId: english });
    Object.assign(texts, e.texts);
  }
  state.diag.step = 'done';
  breadcrumb({ status: 'done' });
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
  if (!done) breadcrumb({ stage });
  const current = Number(/Step (\d)/.exec(phase)?.[1] ?? 0);
  document.querySelectorAll('#steps li').forEach((li) => {
    const n = Number(li.dataset.step);
    li.classList.toggle('done', n < current);
    li.classList.toggle('active', n === current);
  });
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
    const tag = avatar(t.segments.find((s) => s.speaker === id)?.speaker_name || id, id);
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
    const li = el('li', 'hint', 'No speech was found in this audio. The input level is shown with the recording; open Routing decisions for details.');
    li.style.padding = '12px 18px';
    $('transcript').replaceChildren(li);
  } else {
    const nodes = [];
    let previous = null;
    for (const s of t.segments) {
      const newTurn = !previous || previous.speaker !== s.speaker || s.start - previous.end > 30;
      const who = s.speaker_name || s.speaker || 'Speaker';
      if (newTurn) {
        const head = el('li', 'turn-head');
        head.style.setProperty('--sp', colorFor(s.speaker));
        head.append(avatar(who, s.speaker), el('span', 'who', who), el('span', 'when', timestamp(s.start)));
        nodes.push(head);
      }
      const li = el('li', `seg${s.uncertain ? ' uncertain' : ''}`);
      li.style.setProperty('--sp', colorFor(s.speaker));
      li.dataset.start = s.start;
      li.dataset.end = s.end;
      const text = el('p', 'text', s.text);
      text.dir = s.lang === 'ar' ? 'rtl' : 'ltr';
      if (s.lang) text.lang = s.lang;
      if (s.uncertain) text.append(el('span', 'flag', s.why ? `Unsure: ${s.why}` : 'Unsure'));
      if (s.overlap) text.append(el('span', 'flag', 'People talking at once'));
      li.append(text);
      if (newTurn || s.lang !== previous?.lang) li.append(el('span', 'tag', s.lang ?? '?'));
      li.title = `${s.producer} · language confidence ${s.conf.toFixed(2)}`;
      li.addEventListener('click', () => { $('player').currentTime = s.start; $('player').play().catch(() => {}); });
      nodes.push(li);
      previous = s;
    }
    $('transcript').replaceChildren(...nodes);
  }
  $('gaps').replaceChildren(...t.gaps.map((g) => el('p', 'gaps', `Not transcribed ${timestamp(g.start)}–${timestamp(g.end)} · ${g.reason}`)));
}

function avatar(name, id) {
  const a = el('span', 'avatar', /^S\d+$/.test(name) ? name : name.split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase());
  a.style.setProperty('--sp', colorFor(id));
  a.setAttribute('aria-hidden', 'true');
  return a;
}

// Highlight the line being played.
$('player').addEventListener('timeupdate', () => {
  const t = $('player').currentTime;
  document.querySelectorAll('#transcript .seg').forEach((li) => {
    li.classList.toggle('current', !$('player').paused && t >= +li.dataset.start && t < +li.dataset.end);
  });
});

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

// MARK: - Crash breadcrumb
//
// When a browser runs out of memory it kills the tab, and nothing on the page
// survives to report it. The page notes each step before starting it, so the
// next load can say where the last run stopped.

const LAST_RUN_KEY = 'meeting-harness.last-run';

function breadcrumb(update) {
  try {
    // A new run records its settings; later updates (stage, done, reported) only add to them.
    const base = update.status === 'running'
      ? { ...settings(), seconds: state.audio ? +(state.audio.length / SAMPLE_RATE).toFixed(1) : null }
      : JSON.parse(localStorage.getItem(LAST_RUN_KEY) ?? '{}');
    localStorage.setItem(LAST_RUN_KEY, JSON.stringify({ ...base, ...update, at: new Date().toISOString() }));
  } catch { /* storage unavailable: no breadcrumb */ }
}

(function reportLastRun() {
  let last;
  try { last = JSON.parse(localStorage.getItem(LAST_RUN_KEY) ?? 'null'); } catch { return; }
  if (last?.status !== 'running') return;
  state.diag.previousRun = last;
  $('last-run').textContent =
    `The last run stopped during ${last.step} (${last.stage}) with ${last.preset} models on ${last.seconds ?? '?'} s of audio. ` +
    'The browser most likely ran out of memory and closed the page. Use Light models or a shorter recording, ' +
    'and tap Copy diagnostics below to report it.';
  $('last-run').hidden = false;
  $('error-text').textContent = 'Previous run crashed.';
  $('error').hidden = false;
  breadcrumb({ status: 'reported' });
})();

// MARK: - Errors

function showError(message) {
  state.diag.error = message;
  $('error-text').textContent = message;
  $('error').hidden = false;
}

function diagnostics() {
  let lastRun = null;
  try { lastRun = JSON.parse(localStorage.getItem(LAST_RUN_KEY) ?? 'null'); } catch { /* unavailable */ }
  const { log, ...rest } = state.diag;
  return JSON.stringify({
    app: 'meeting-harness web',
    userAgent: navigator.userAgent,
    memoryGB: navigator.deviceMemory ?? null,
    webgpu: 'gpu' in navigator,
    lastRun,
    ...rest,
    log: log ?? state.result?.log ?? null,
  }, null, 2);
}

$('copy-diag').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(diagnostics());
    $('copy-diag').textContent = 'Copied. Paste it into your report.';
  } catch {
    $('diag-text').textContent = diagnostics();
    $('diag-text').hidden = false;
  }
});

// Anything that escapes a handler still reaches the page instead of failing silently.
addEventListener('error', (e) => showError(`Unexpected error: ${e.message}`));
addEventListener('unhandledrejection', (e) => showError(`Unexpected error: ${e.reason?.message ?? e.reason}`));
function hideError() { $('error').hidden = true; }

// MARK: - Settings summary

function updateSetupSummary() {
  const names = { en: 'English', ar: 'Arabic', de: 'German', fr: 'French' };
  $('setup-summary').textContent = `${languages().map((l) => names[l]).join(' + ')} · ${$('preset').value === 'light' ? 'Light' : 'Balanced'} models`;
}
document.querySelectorAll('#languages input, #preset').forEach((n) => n.addEventListener('change', updateSetupSummary));
updateSetupSummary();

// MARK: - Demo mode (?demo, ?demo=live) for screenshots and walkthroughs

const demo = new URLSearchParams(location.search).get('demo');
if (demo === 'live') {
  $('studio').dataset.state = 'recording';
  $('record-time').textContent = '12:34';
  renderCaptions(DEMO_CAPTIONS.lines, DEMO_CAPTIONS.draft);
  $('live-hint').textContent = 'Live captions are drafts. The full transcript, with speakers, is made when you stop.';
  for (let i = 0; i < 48; i++) meterLevels.push(demoLevel());
  drawMeter();
} else if (demo !== null) {
  state.result = structuredClone(DEMO_RESULT);
  state.names = {};
  $('audio-name').textContent = 'Product standup';
  $('audio-duration').textContent = '12:34 · speech level −31 dB, raised 11 dB';
  $('audio-ready').hidden = false;
  $('run').disabled = false;
  renderResult();
  window.scrollTo(0, 0);
}
