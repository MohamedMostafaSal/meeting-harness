// Runs one pipeline phase off the main thread, then the page terminates this
// worker. A WebAssembly heap never shrinks, so a fresh worker per phase is what
// frees each model's memory before the next one loads (iPhone Safari crashes a
// tab that holds every model at once).
import * as T from 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/dist/transformers.min.js';
import { loadVoiceModels, loadWhisper, whisperModels } from './models.js';
import { newContext, diarize, plan, transcribe, piecesFor } from './pipeline.js';

T.env.allowLocalModels = false;

// Live captions keep one multilingual Whisper loaded for the whole recording.
let live = null;

async function handleLive(data, onDownload) {
  const { id, task } = data;
  if (task === 'live-init') {
    const { multilingual } = whisperModels(data.settings.preset);
    live = { whisper: await loadWhisper(T, data.settings, multilingual, onDownload), allowed: data.allowed };
    postMessage({ type: 'result', id });
    return;
  }
  // Committed sentences get their language detected; drafts reuse the last one.
  let language = data.language;
  if (data.commit || !language) {
    const guesses = await live.whisper.identify(data.audio, live.allowed);
    language = guesses[0]?.language ?? language ?? live.allowed[0];
  }
  const { text } = await live.whisper.transcribe(data.audio, { model: 'multi', language });
  postMessage({ type: 'result', id, text, language });
}

self.onmessage = async ({ data }) => {
  const { id, task, settings, options = {} } = data;
  const onDownload = (p) => {
    if (p.status === 'progress' || p.status === 'done' || p.status === 'initiate') {
      postMessage({ type: 'download', id, status: p.status, file: `${p.name}/${p.file}`, loaded: p.loaded ?? 0, total: p.total ?? 0 });
    }
  };
  const onProgress = (p) => postMessage({ type: 'stage', id, ...p });
  const short = (modelId) => modelId.split('/').pop();

  try {
    if (task?.startsWith('live-')) return await handleLive(data, onDownload);
    if (settings.device === 'webgpu' && !('gpu' in navigator)) {
      throw new Error('This browser has no WebGPU. Switch the engine to WASM in Setup.');
    }
    const ctx = newContext();

    if (task === 'embed' || task === 'diarize') {
      onProgress({ stage: 'Loading voice models' });
      const voices = await loadVoiceModels(T, settings, onDownload);
      if (task === 'embed') {
        postMessage({ type: 'result', id, embedding: await voices.embed(data.audio) });
      } else {
        const utterances = await diarize(data.audio, voices, { ...options, onProgress }, ctx);
        postMessage({ type: 'result', id, utterances, ctx });
      }
      return;
    }

    onProgress({ stage: `Loading ${short(data.modelId)}` });
    const whisper = await loadWhisper(T, settings, data.modelId, onDownload);

    if (task === 'plan') {
      // Language ID needs the multilingual model, which also transcribes what's routed to it.
      const pieces = await plan(data.audio, data.utterances, whisper, { ...options, onProgress }, ctx);
      const texts = await transcribe(data.audio, pieces, piecesFor(pieces, whisper.recognizers, data.modelId), whisper, { onProgress }, ctx);
      postMessage({ type: 'result', id, pieces, texts, ctx });
    } else if (task === 'transcribe') {
      const indexes = piecesFor(data.pieces, whisper.recognizers, data.modelId);
      const texts = await transcribe(data.audio, data.pieces, indexes, whisper, { onProgress }, ctx);
      postMessage({ type: 'result', id, texts, ctx });
    } else {
      throw new Error(`Unknown task ${task}`);
    }
  } catch (error) {
    postMessage({ type: 'error', id, message: String(error?.message ?? error) });
  }
};
