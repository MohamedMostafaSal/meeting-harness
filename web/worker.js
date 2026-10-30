// Runs the models off the main thread so the page stays responsive.
import * as T from 'https://cdn.jsdelivr.net/npm/@huggingface/transformers@3.8.1/dist/transformers.min.js';
import { loadModels } from './models.js';
import { runPipeline } from './pipeline.js';

T.env.allowLocalModels = false;

let loaded = null; // { key, models }

async function ensureModels(settings, id) {
  const key = `${settings.preset}|${settings.device}`;
  if (loaded?.key === key) return loaded.models;
  loaded = null;
  const models = await loadModels(T, settings, (p) => {
    if (p.status === 'progress' || p.status === 'done' || p.status === 'initiate') {
      postMessage({ type: 'download', id, status: p.status, file: `${p.name}/${p.file}`, loaded: p.loaded ?? 0, total: p.total ?? 0 });
    }
  });
  loaded = { key, models };
  return models;
}

self.onmessage = async ({ data }) => {
  const { type, id, settings } = data;
  try {
    if (settings.device === 'webgpu' && !('gpu' in navigator)) {
      throw new Error('This browser has no WebGPU. Switch the engine to WASM in Models.');
    }
    postMessage({ type: 'stage', id, stage: 'Loading models' });
    const models = await ensureModels(settings, id);

    if (type === 'load') {
      postMessage({ type: 'loaded', id });
    } else if (type === 'embed') {
      postMessage({ type: 'embedding', id, embedding: await models.embed(data.audio) });
    } else if (type === 'run') {
      const result = await runPipeline(data.audio, models, {
        ...data.options,
        onProgress: (p) => postMessage({ type: 'stage', id, ...p }),
      });
      postMessage({ type: 'result', id, result });
    }
  } catch (error) {
    postMessage({ type: 'error', id, message: String(error?.message ?? error) });
  }
};
