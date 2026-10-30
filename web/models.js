// Adapters from transformers.js models to the pipeline contract (see pipeline.js).
// Takes the transformers.js module as an argument so the same code runs in the
// browser (CDN build) and in Node (npm build, for the CI smoke test).

import { quietestCut } from './harness.js';

export const PRESETS = {
  light: {
    label: 'Light: fastest, weakest Arabic',
    english: 'Xenova/whisper-tiny.en',
    multilingual: 'Xenova/whisper-base',
  },
  balanced: {
    label: 'Balanced: better Arabic, slower',
    english: 'Xenova/whisper-base.en',
    multilingual: 'Xenova/whisper-small',
  },
};

export const SEGMENTATION_MODEL = 'onnx-community/pyannote-segmentation-3.0';
export const EMBEDDING_MODEL = 'Xenova/wavlm-base-plus-sv';

const SR = 16000;
const SEGMENT_CHUNK = 10 * SR; // pyannote segmentation is trained on 10 s chunks
const CUT_SEARCH = 3 * SR;     // each chunk ends at the quietest point of its last 3 s
const MAX_EMBED = 10 * SR;     // fingerprint at most the middle 10 s of a turn

export function recognizersFor(preset) {
  const p = PRESETS[preset];
  return [
    { id: 'en', label: `English specialist (${short(p.english)})`, model: p.english, languages: ['en'], forceLanguage: false },
    // No browser-ready Egyptian Arabic model yet: this slot is a general multilingual
    // Whisper forced to Arabic. The router still prefers an 'egyptian' variant when one is added.
    { id: 'ar', label: `Arabic specialist (${short(p.multilingual)})`, model: p.multilingual, languages: ['ar'], variant: 'general', forceLanguage: true },
    { id: 'multi', label: `Multilingual fallback (${short(p.multilingual)})`, model: p.multilingual, fallback: true, forceLanguage: true },
  ];
}

const short = (id) => id.split('/').pop();

/**
 * Loads every model for `preset`. `onProgress` receives transformers.js download
 * events ({status, file, progress, loaded, total, name}).
 */
export async function loadModels(T, { preset = 'light', device = 'wasm' } = {}, onProgress = () => {}) {
  const { pipeline, AutoProcessor, AutoModel, AutoModelForAudioFrameClassification, Tensor } = T;
  const progress_callback = (p) => onProgress(p);
  const recognizers = recognizersFor(preset);

  const segProcessor = await AutoProcessor.from_pretrained(SEGMENTATION_MODEL, { progress_callback });
  const segModel = await AutoModelForAudioFrameClassification.from_pretrained(SEGMENTATION_MODEL, {
    device, dtype: 'fp32', progress_callback,
  });
  const embProcessor = await AutoProcessor.from_pretrained(EMBEDDING_MODEL, { progress_callback });
  const embModel = await AutoModel.from_pretrained(EMBEDDING_MODEL, { device, dtype: 'q8', progress_callback });

  // Specialists that share a model share one loaded pipeline.
  const asr = new Map();
  for (const r of recognizers) {
    if (!asr.has(r.model)) {
      asr.set(r.model, await pipeline('automatic-speech-recognition', r.model, { device, dtype: 'q8', progress_callback }));
    }
  }
  const lidPipeline = asr.get(PRESETS[preset].multilingual);

  return {
    recognizers,

    // M1 + M2 + M4: pyannote's 7 classes give silence, single speakers and overlap at once.
    async segment(audio) {
      const out = [];
      for (let offset = 0, chunk = 0, end; offset < audio.length; offset = end, chunk++) {
        end = offset + SEGMENT_CHUNK >= audio.length
          ? audio.length
          : quietestCut(audio, offset + SEGMENT_CHUNK - CUT_SEARCH, offset + SEGMENT_CHUNK);
        const part = audio.subarray(offset, end);
        const padded = new Float32Array(Math.max(part.length, SR));
        padded.set(part);
        const inputs = await segProcessor(padded);
        const { logits } = await segModel(inputs);
        const [segments] = segProcessor.post_process_speaker_diarization(logits, padded.length);
        const limit = part.length / SR;
        for (const s of segments) {
          if (s.start >= limit) continue;
          out.push({ start: offset / SR + s.start, end: offset / SR + Math.min(s.end, limit), cls: s.id, chunk });
        }
      }
      return out;
    },

    // M3
    async embed(clip) {
      const from = Math.max(0, Math.floor((clip.length - MAX_EMBED) / 2));
      const inputs = await embProcessor(clip.subarray(from, from + MAX_EMBED));
      const { embeddings } = await embModel(inputs);
      return Array.from(embeddings.data);
    },

    // M6: Whisper's language token probabilities after <|startoftranscript|>,
    // renormalized over the meeting's languages. transformers.js doesn't expose
    // language detection yet, so this runs one decoder step directly.
    async identify(clip, allowed) {
      const { model, processor } = lidPipeline;
      const config = model.generation_config;
      const inputs = await processor(clip);
      const decoder_input_ids = new Tensor('int64', BigInt64Array.from([BigInt(config.decoder_start_token_id)]), [1, 1]);
      const { logits } = await model({ ...inputs, decoder_input_ids });
      const vocab = logits.dims.at(-1);
      const offset = (logits.dims.at(-2) - 1) * vocab;
      let candidates = Object.entries(config.lang_to_id).map(([token, id]) => ({
        language: token.slice(2, -2),
        logit: logits.data[offset + id],
      }));
      if (allowed?.length) candidates = candidates.filter((c) => allowed.includes(c.language));
      const max = Math.max(...candidates.map((c) => c.logit));
      const exp = candidates.map((c) => Math.exp(c.logit - max));
      const total = exp.reduce((a, b) => a + b, 0);
      return candidates
        .map((c, i) => ({ language: c.language, confidence: exp[i] / total }))
        .sort((a, b) => b.confidence - a.confidence)
        .slice(0, 5);
    },

    // M7
    async transcribe(clip, { model, language }) {
      const r = recognizers.find((x) => x.id === model);
      const options = r.forceLanguage ? { language: language ?? 'en', task: 'transcribe' } : {};
      const out = await asr.get(r.model)(clip, options);
      return { text: out.text ?? '' };
    },
  };
}
