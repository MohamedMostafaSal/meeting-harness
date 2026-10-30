// Live captions while recording: a rolling 16 kHz buffer fed from the microphone,
// and a captioner that sends sentences to a long-lived Whisper worker.
// The full pipeline still runs after recording and replaces these drafts.
import { SAMPLE_RATE, LIVE_POLICY, liveStep, rms, hallucinationReason } from './harness.js';

/** The last `seconds` of microphone audio at 16 kHz, plus the total recorded. */
export class LiveCapture {
  constructor(seconds = 30) {
    this.capacity = seconds * SAMPLE_RATE;
    this.buffer = new Float32Array(this.capacity);
    this.length = 0;   // valid samples in buffer (≤ capacity), newest at the end
    this.total = 0;    // samples recorded since start
  }

  async start(stream) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    this.ctx = new Ctx();
    this.source = this.ctx.createMediaStreamSource(stream);
    // ScriptProcessor is deprecated but works in every browser, Safari included.
    this.node = this.ctx.createScriptProcessor(4096, 1, 1);
    const ratio = this.ctx.sampleRate / SAMPLE_RATE;
    this.node.onaudioprocess = (e) => {
      const input = e.inputBuffer.getChannelData(0);
      const out = new Float32Array(Math.floor(input.length / ratio));
      for (let i = 0; i < out.length; i++) {
        const x = i * ratio, j = Math.floor(x), t = x - j;
        out[i] = input[j] * (1 - t) + (input[j + 1] ?? input[j]) * t;
      }
      this.append(out);
    };
    this.source.connect(this.node);
    this.node.connect(this.ctx.destination);
  }

  append(samples) {
    const n = samples.length;
    if (n >= this.capacity) {
      this.buffer.set(samples.subarray(n - this.capacity));
      this.length = this.capacity;
    } else {
      const keep = Math.min(this.length, this.capacity - n);
      this.buffer.copyWithin(0, this.length - keep, this.length);
      this.buffer.set(samples, keep);
      this.length = keep + n;
    }
    this.total += n;
  }

  /** Samples from absolute index `from` to now (as many as are still buffered). */
  samplesFrom(from) {
    const bufferStart = this.total - this.length;
    const begin = Math.max(from, bufferStart);
    return { samples: this.buffer.slice(begin - bufferStart, this.length), start: begin };
  }

  /** 0…1 level of the last 50 ms, eased so speech fills a meter. */
  level() {
    const n = Math.min(this.length, SAMPLE_RATE / 20);
    const db = Math.max(-60, 20 * Math.log10(Math.max(rms(this.buffer, this.length - n, this.length), 1e-6)));
    return Math.min(1, 10 ** (db / 40) * 1.4);
  }

  get seconds() { return this.total / SAMPLE_RATE; }

  stop() {
    this.node?.disconnect();
    this.source?.disconnect();
    this.ctx?.close?.();
  }
}

/** Talks to one long-lived worker that keeps the multilingual Whisper loaded. */
class LiveWorker {
  constructor(settings, allowed) {
    this.worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
    this.pending = new Map();
    this.nextId = 1;
    this.worker.onmessage = ({ data }) => {
      const job = this.pending.get(data.id);
      if (!job || data.type === 'download' || data.type === 'stage') return;
      this.pending.delete(data.id);
      data.type === 'error' ? job.reject(new Error(data.message)) : job.resolve(data);
    };
    this.ready = this.call({ task: 'live-init', settings, allowed });
  }

  call(message, transfer = []) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ ...message, id }, transfer);
    });
  }

  terminate() { this.worker.terminate(); }
}

/**
 * Pauses cut the speech into sentences. While someone talks, the sentence is
 * re-transcribed every couple of seconds as a draft; at a pause it is committed in
 * the language detected for it among the meeting's languages.
 */
export class LiveCaptioner {
  constructor(capture, { settings, allowed, onUpdate, onError }) {
    this.capture = capture;
    this.onUpdate = onUpdate;
    this.onError = onError;
    this.lines = [];
    this.draft = null;
    this.state = { sentenceStart: 0, lastDraftAt: 0 };
    this.language = null;
    this.busy = false;
    this.worker = new LiveWorker(settings, allowed);
    this.worker.ready.catch((e) => this.onError?.(e));
    this.timer = setInterval(() => this.step(), 500);
  }

  async step() {
    if (this.busy) return;
    const { samples, start } = this.capture.samplesFrom(this.state.sentenceStart);
    const decision = liveStep(this.state, this.capture.total, samples, start, LIVE_POLICY);
    this.state = decision.state;
    if (decision.action !== 'commit' && decision.action !== 'draft') return;
    const clip = samples.slice(Math.max(0, decision.from - start));
    this.busy = true;
    try {
      await this.worker.ready;
      const commit = decision.action === 'commit';
      const out = await this.worker.call({ task: 'live-caption', audio: clip, commit, language: this.language }, [clip.buffer]);
      const text = (out.text ?? '').trim();
      if (hallucinationReason(text, clip.length / SAMPLE_RATE) !== null) {
        if (commit) this.draft = null;
      } else if (commit) {
        this.language = out.language ?? this.language;
        this.lines.push({ language: out.language, text });
        this.lines = this.lines.slice(-40);
        this.draft = null;
      } else {
        this.draft = { language: out.language ?? this.language, text };
      }
      this.onUpdate?.(this.lines, this.draft);
    } catch (e) {
      this.onError?.(e);
    } finally {
      this.busy = false;
    }
  }

  /** Stops captioning and frees the worker's memory before the full pipeline runs. */
  stop() {
    clearInterval(this.timer);
    this.worker.terminate();
  }
}

/** Phones whose browsers give a page too little memory for live captions. */
export function liveCaptionsSupported() {
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  return !ios;
}
