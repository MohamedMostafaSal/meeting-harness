// Audio in: microphone recording and file decoding, always ending as 16 kHz mono.
import { SAMPLE_RATE } from './harness.js';

/** Decodes any audio the browser understands (m4a from Voice Memos, mp3, wav…) to 16 kHz mono. */
export async function decodeToMono16k(blob) {
  const buffer = await blob.arrayBuffer();
  const Ctx = window.AudioContext || window.webkitAudioContext;
  const ctx = new Ctx();
  let decoded;
  try {
    decoded = await ctx.decodeAudioData(buffer);
  } finally {
    ctx.close?.();
  }
  try {
    const offline = new OfflineAudioContext(1, Math.ceil(decoded.duration * SAMPLE_RATE), SAMPLE_RATE);
    const source = offline.createBufferSource();
    source.buffer = decoded;
    source.connect(offline.destination);
    source.start();
    const rendered = await offline.startRendering();
    return rendered.getChannelData(0);
  } catch {
    return resampleLinear(mixdown(decoded), decoded.sampleRate, SAMPLE_RATE);
  }
}

function mixdown(audioBuffer) {
  const out = new Float32Array(audioBuffer.length);
  for (let c = 0; c < audioBuffer.numberOfChannels; c++) {
    const data = audioBuffer.getChannelData(c);
    for (let i = 0; i < out.length; i++) out[i] += data[i] / audioBuffer.numberOfChannels;
  }
  return out;
}

function resampleLinear(input, from, to) {
  const out = new Float32Array(Math.floor((input.length * to) / from));
  const ratio = from / to;
  for (let i = 0; i < out.length; i++) {
    const x = i * ratio;
    const j = Math.floor(x);
    const t = x - j;
    out[i] = (input[j] ?? 0) * (1 - t) + (input[j + 1] ?? input[j] ?? 0) * t;
  }
  return out;
}

/** Microphone recorder. iPhone Safari needs HTTPS and a tap to start. */
export class Recorder {
  #recorder = null;
  #chunks = [];
  #stream = null;
  startedAt = 0;

  get recording() { return this.#recorder?.state === 'recording'; }
  get mimeType() { return this.#recorder?.mimeType ?? ''; }
  get stream() { return this.#stream; }
  get elapsed() { return this.recording ? (Date.now() - this.startedAt) / 1000 : 0; }

  async start() {
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error('This browser cannot record here. Open the page over HTTPS in Safari or Chrome.');
    }
    this.#stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: true },
    });
    this.#chunks = [];
    this.#recorder = new MediaRecorder(this.#stream);
    this.#recorder.ondataavailable = (e) => e.data.size && this.#chunks.push(e.data);
    // No timeslice: iPhone Safari can write chunked recordings that decode only in part.
    this.#recorder.start();
    this.startedAt = Date.now();
  }

  /** Stops and resolves the recording as a Blob. */
  stop() {
    return new Promise((resolve) => {
      const recorder = this.#recorder;
      recorder.onstop = () => {
        this.#stream.getTracks().forEach((t) => t.stop());
        resolve(new Blob(this.#chunks, { type: recorder.mimeType || 'audio/mp4' }));
      };
      recorder.stop();
    });
  }
}
