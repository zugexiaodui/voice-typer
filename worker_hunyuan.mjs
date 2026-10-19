// Persistent JSONL worker for Tencent Hunyuan ASR via TokenHub.
// stdout is protocol-only. Audio is held in memory on the recognize/pcm path; no disk writes happen there.
// Errors never echo provider payloads, request bodies, or credentials.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import https from 'node:https';
import { pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';

export const ENDPOINT = 'https://tokenhub.tencentmaas.com/v1/wand/asrproxy/sync_transcribe';
export const DEFAULT_MODEL = 'hy-asr-3.0-preview';
export const DEFAULT_TIMEOUT_MS = 120000;
export const MIN_TIMEOUT_MS = 1000;
export const MAX_TIMEOUT_MS = 600000;
export const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
export const MAX_LINE_BYTES = 40 * 1024 * 1024;
export const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

export const SAFE_ERRORS = Object.freeze({
  INVALID_COMMAND: 'Invalid worker command',
  INVALID_SESSION: 'A nonempty session string is required',
  INVALID_OPTIONS: 'Invalid recognition options',
  MISSING_KEY: 'Hunyuan API credential is not configured',
  INVALID_AUDIO: 'Expected nonempty base64 audio or a readable audio file',
  AUDIO_TOO_LARGE: 'Audio exceeds the maximum size limit',
  EVENT_NOT_IDLE: 'A recognition is already in progress',
  HTTP_ERROR: 'Hunyuan rejected the recognition request',
  PARSE_ERROR: 'Invalid response from Hunyuan',
  TIMEOUT: 'Hunyuan request timed out',
  NETWORK_ERROR: 'Hunyuan request failed; check network and service permission',
  RESPONSE_TOO_LARGE: 'Hunyuan response exceeded its size limit',
  ABORTED: 'Recognition was aborted',
  LINE_TOO_LONG: 'Worker command exceeded its size limit',
  INTERNAL_ERROR: 'Internal worker error',
});

const BASE64_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const KEY_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const MAX_SESSION_LENGTH = 128;
const MAX_MODEL_LENGTH = 128;

const validSession = value => typeof value === 'string' && value.length > 0 && value.length <= MAX_SESSION_LENGTH;
const elapsed = start => Math.round(performance.now() - start);
const finiteNumber = value => (typeof value === 'number' && Number.isFinite(value) ? value : null);

export function boundedTimeout(value, fallback = DEFAULT_TIMEOUT_MS) {
  if (value === undefined || value === null) return fallback;
  return Number.isInteger(value) && value >= MIN_TIMEOUT_MS && value <= MAX_TIMEOUT_MS ? value : null;
}

export class HunyuanError extends Error {
  constructor(code, { httpStatus = null, providerCode = null } = {}) {
    const safeCode = SAFE_ERRORS[code] ? code : 'INTERNAL_ERROR';
    super(SAFE_ERRORS[safeCode]);
    this.name = 'HunyuanError';
    this.code = safeCode;
    this.httpStatus = Number.isInteger(httpStatus) ? httpStatus : null;
    this.providerCode = typeof providerCode === 'string' && providerCode ? providerCode : null;
  }
}

// Same lookup style as worker_doubao.mjs: override env, base env, named env, then YAML scalar.
export function resolveCredential(env = process.env, keyName = env.VT_HUNYUAN_KEY_NAME || 'HUNYUAN_API_KEY') {
  if (typeof keyName !== 'string' || !KEY_NAME_RE.test(keyName)) return null;
  for (const name of ['VT_HUNYUAN_API_KEY', 'HUNYUAN_API_KEY', keyName]) {
    if (typeof env[name] === 'string' && env[name].trim()) return env[name].trim();
  }
  const file = env.VT_HUNYUAN_KEYFILE || path.join(os.homedir(), '.dsh', '.credentials.yaml');
  try {
    if (fs.statSync(file).size > 1024 * 1024) return null;
    const raw = fs.readFileSync(file, 'utf8');
    const escaped = keyName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const pattern = '^\\s*' + escaped + '\\s*:\\s*(?:"([^"\\r\\n]+)"|\'([^\'\\r\\n]+)\'|([^\\s#]+))';
    const match = raw.match(new RegExp(pattern, 'm'));
    return match ? (match[1] || match[2] || match[3]).trim() : null;
  } catch {
    return null;
  }
}

export function buildRequest({ audio, model = DEFAULT_MODEL, key, endpoint = ENDPOINT } = {}) {
  if (!Buffer.isBuffer(audio) || audio.length === 0) throw new HunyuanError('INVALID_AUDIO');
  if (audio.length > MAX_AUDIO_BYTES) throw new HunyuanError('AUDIO_TOO_LARGE');
  if (typeof model !== 'string' || !model.trim() || model.length > MAX_MODEL_LENGTH) throw new HunyuanError('INVALID_OPTIONS');
  if (typeof endpoint !== 'string' || !endpoint) throw new HunyuanError('INVALID_OPTIONS');
  // TokenHub requires standard base64 with no data-URI prefix. Raw PCM16 or WAV/MP3 bytes are both accepted.
  const body = JSON.stringify({ model: model.trim(), data: audio.toString('base64') });
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'Content-Length': String(Buffer.byteLength(body)),
  };
  if (typeof key === 'string' && key.length) headers.Authorization = 'Bearer ' + key;
  return { endpoint, method: 'POST', headers, body };
}

function safeProviderCode(value) {
  const text = typeof value === 'number' && Number.isFinite(value) ? String(value) : value;
  return typeof text === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(text.trim()) ? text.trim() : null;
}

function parseFailure(code, httpStatus, providerCode = null) {
  return {
    ok: false,
    code,
    error: SAFE_ERRORS[code] || SAFE_ERRORS.PARSE_ERROR,
    httpStatus: Number.isInteger(httpStatus) ? httpStatus : null,
    providerCode: providerCode || null,
  };
}

const successStatus = status => status === null || status === undefined || (Number.isInteger(status) && status >= 200 && status < 300);

// Parses a TokenHub ASR response. Provider message text is deliberately discarded.
export function parseAsrResponse(body, { httpStatus = 200 } = {}) {
  let text;
  if (Buffer.isBuffer(body)) text = body.toString('utf8');
  else if (typeof body === 'string') text = body;
  else return parseFailure(successStatus(httpStatus) ? 'PARSE_ERROR' : 'HTTP_ERROR', httpStatus);

  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    return parseFailure(successStatus(httpStatus) ? 'PARSE_ERROR' : 'HTTP_ERROR', httpStatus);
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return parseFailure(successStatus(httpStatus) ? 'PARSE_ERROR' : 'HTTP_ERROR', httpStatus);
  }

  const providerError = payload.error;
  if ((providerError !== undefined && providerError !== null) || !successStatus(httpStatus)) {
    return parseFailure('HTTP_ERROR', httpStatus, safeProviderCode(providerError?.code));
  }

  const output = payload.output;
  if (!output || typeof output !== 'object' || Array.isArray(output) || typeof output.text !== 'string') {
    return parseFailure('PARSE_ERROR', httpStatus);
  }
  const segments = Array.isArray(output.sentences)
    ? output.sentences
      .filter(sentence => sentence && typeof sentence === 'object' && typeof sentence.text === 'string')
      .map(sentence => ({ text: sentence.text, start: finiteNumber(sentence.begin_ms), end: finiteNumber(sentence.end_ms) }))
    : [];
  return {
    ok: true,
    text: output.text,
    segments,
    durationMs: finiteNumber(output.duration_ms),
    tokens: finiteNumber(payload.usage?.total_tokens),
  };
}

// Default transport. Uses an absolute wall-clock timer plus a socket timeout and destroys the request.
export function requestOnce({ endpoint, method = 'POST', headers = {}, body = '', timeoutMs = DEFAULT_TIMEOUT_MS, signal } = {}) {
  return new Promise((resolve, reject) => {
    let url;
    try { url = new URL(endpoint); } catch { reject(new HunyuanError('INVALID_OPTIONS')); return; }
    const transport = url.protocol === 'http:' ? http : url.protocol === 'https:' ? https : null;
    if (!transport) { reject(new HunyuanError('INVALID_OPTIONS')); return; }
    const ms = Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS;
    let settled = false;
    let req = null;
    let timer = null;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (signal) signal.removeEventListener?.('abort', onAbort);
      fn(value);
    };
    const onAbort = () => {
      finish(reject, new HunyuanError('ABORTED'));
      try { req?.destroy(); } catch { }
    };
    const onTimeout = () => {
      finish(reject, new HunyuanError('TIMEOUT'));
      try { req?.destroy(); } catch { }
    };
    if (signal?.aborted) { finish(reject, new HunyuanError('ABORTED')); return; }
    try {
      req = transport.request(url, { method, headers, timeout: ms }, response => {
        const chunks = [];
        let total = 0;
        response.on('data', chunk => {
          if (settled) return;
          const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
          total += bytes.length;
          if (total > MAX_RESPONSE_BYTES) {
            finish(reject, new HunyuanError('RESPONSE_TOO_LARGE', { httpStatus: response.statusCode }));
            try { response.destroy(); } catch { }
            return;
          }
          chunks.push(bytes);
        });
        response.on('end', () => finish(resolve, { statusCode: response.statusCode ?? null, headers: response.headers, body: Buffer.concat(chunks) }));
        response.on('aborted', () => finish(reject, new HunyuanError('NETWORK_ERROR')));
        response.on('error', () => finish(reject, new HunyuanError('NETWORK_ERROR')));
      });
      req.on('timeout', onTimeout);
      req.on('error', () => finish(reject, new HunyuanError(signal?.aborted ? 'ABORTED' : 'NETWORK_ERROR')));
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      timer = setTimeout(onTimeout, ms);
      req.end(body);
    } catch {
      finish(reject, new HunyuanError('NETWORK_ERROR'));
    }
  });
}

export async function recognizeOnce({
  audio, model = DEFAULT_MODEL, keyName, timeoutMs, signal, endpoint = ENDPOINT,
} = {}, { env = process.env, requestImpl = requestOnce } = {}) {
  const ms = boundedTimeout(timeoutMs, DEFAULT_TIMEOUT_MS);
  if (ms === null) throw new HunyuanError('INVALID_OPTIONS');
  if (keyName !== undefined && (typeof keyName !== 'string' || !KEY_NAME_RE.test(keyName))) throw new HunyuanError('INVALID_OPTIONS');
  if (!Buffer.isBuffer(audio) || audio.length === 0) throw new HunyuanError('INVALID_AUDIO');
  if (audio.length > MAX_AUDIO_BYTES) throw new HunyuanError('AUDIO_TOO_LARGE');
  const key = resolveCredential(env, keyName);
  if (!key) throw new HunyuanError('MISSING_KEY');
  const request = buildRequest({ audio, model, key, endpoint });
  let response;
  try {
    response = await requestImpl({ ...request, timeoutMs: ms, signal });
  } catch (error) {
    if (error instanceof HunyuanError) throw error;
    if (signal?.aborted) throw new HunyuanError('ABORTED');
    const code = error?.code === 'ETIMEDOUT' || error?.code === 'TIMEOUT' ? 'TIMEOUT' : 'NETWORK_ERROR';
    throw new HunyuanError(code);
  }
  const httpStatus = Number.isInteger(response?.statusCode) ? response.statusCode : 200;
  const parsed = parseAsrResponse(response?.body, { httpStatus });
  if (!parsed.ok) throw new HunyuanError(parsed.code, { httpStatus: parsed.httpStatus, providerCode: parsed.providerCode });
  return parsed;
}

export class HunyuanWorker {
  constructor({
    emit, env = process.env, requestImpl = requestOnce, onExit = () => { },
    recognizeImpl = recognizeOnce, maxAudioBytes = MAX_AUDIO_BYTES,
  } = {}) {
    this.emit = emit || (() => { });
    this.env = env;
    this.requestImpl = requestImpl;
    this.onExit = onExit;
    this.recognizeImpl = recognizeImpl;
    this.maxAudioBytes = maxAudioBytes;
    this.active = null;
    this.exited = false;
  }

  error(session, code, extra = {}) {
    const event = {
      event: 'error',
      session: validSession(session) ? session : null,
      code,
      error: SAFE_ERRORS[code] || SAFE_ERRORS.INVALID_COMMAND,
      httpStatus: Number.isInteger(extra.httpStatus) ? extra.httpStatus : null,
    };
    if (extra.providerCode) event.providerCode = extra.providerCode;
    this.emit(event);
  }

  decodeAudio(command) {
    if (typeof command.pcm === 'string') {
      const pcm = command.pcm;
      if (pcm.length === 0) return { error: 'INVALID_AUDIO' };
      if (pcm.length > Math.ceil(this.maxAudioBytes / 3) * 4) return { error: 'AUDIO_TOO_LARGE' };
      if (!BASE64_RE.test(pcm)) return { error: 'INVALID_AUDIO' };
      let audio;
      try { audio = Buffer.from(pcm, 'base64'); } catch { return { error: 'INVALID_AUDIO' }; }
      if (audio.length === 0) return { error: 'INVALID_AUDIO' };
      if (audio.length > this.maxAudioBytes) return { error: 'AUDIO_TOO_LARGE' };
      if (audio.toString('base64') !== pcm) return { error: 'INVALID_AUDIO' };
      return { audio };
    }
    if (typeof command.wav === 'string') {
      if (!command.wav) return { error: 'INVALID_AUDIO' };
      try {
        const stat = fs.statSync(command.wav);
        if (!stat.isFile() || stat.size <= 0) return { error: 'INVALID_AUDIO' };
        if (stat.size > this.maxAudioBytes) return { error: 'AUDIO_TOO_LARGE' };
        const audio = fs.readFileSync(command.wav);
        if (audio.length === 0) return { error: 'INVALID_AUDIO' };
        if (audio.length > this.maxAudioBytes) return { error: 'AUDIO_TOO_LARGE' };
        return { audio };
      } catch {
        return { error: 'INVALID_AUDIO' };
      }
    }
    return { error: 'INVALID_AUDIO' };
  }

  handle(command) {
    if (this.exited) return;
    if (!command || typeof command !== 'object' || Array.isArray(command)) return this.error(null, 'INVALID_COMMAND');
    const cmd = command.cmd;
    if (cmd === 'exit') {
      this.shutdown();
      this.onExit();
      return;
    }
    if (!validSession(command.session)) return this.error(null, 'INVALID_SESSION');
    const session = command.session;
    if (cmd === 'ping') {
      this.emit({ event: 'pong', session });
      return;
    }
    if (cmd !== 'recognize') return this.error(session, 'INVALID_COMMAND');
    if (this.active) return this.error(session, 'EVENT_NOT_IDLE');

    const model = command.model === undefined ? DEFAULT_MODEL : command.model;
    if (typeof model !== 'string' || !model.trim() || model.length > MAX_MODEL_LENGTH) return this.error(session, 'INVALID_OPTIONS');
    const keyName = command.keyName;
    if (keyName !== undefined && (typeof keyName !== 'string' || !KEY_NAME_RE.test(keyName))) return this.error(session, 'INVALID_OPTIONS');
    const timeoutMs = boundedTimeout(command.timeoutMs, DEFAULT_TIMEOUT_MS);
    if (timeoutMs === null) return this.error(session, 'INVALID_OPTIONS');

    const decoded = this.decodeAudio(command);
    if (decoded.error) return this.error(session, decoded.error);

    const job = { session, controller: new AbortController(), startedAt: performance.now() };
    this.active = job;
    void this.run(job, { audio: decoded.audio, model: model.trim(), keyName, timeoutMs, signal: job.controller.signal });
  }

  async run(job, options) {
    try {
      const result = await this.recognizeImpl(options, { env: this.env, requestImpl: this.requestImpl });
      if (this.active !== job || this.exited) return;
      this.active = null;
      this.emit({
        event: 'finished',
        session: job.session,
        text: result.text,
        segments: result.segments,
        durationMs: result.durationMs,
        tokens: result.tokens,
        elapsedMs: elapsed(job.startedAt),
      });
    } catch (error) {
      if (this.active !== job || this.exited) return;
      this.active = null;
      const known = error instanceof HunyuanError;
      this.error(job.session, known ? error.code : 'INTERNAL_ERROR', {
        httpStatus: known ? error.httpStatus : null,
        providerCode: known ? error.providerCode : null,
      });
    }
  }

  shutdown() {
    this.exited = true;
    const job = this.active;
    this.active = null;
    try { job?.controller.abort(); } catch { }
  }
}

export function runWorker(input = process.stdin, output = process.stdout, options = {}) {
  let pending = Buffer.alloc(0);
  let discarding = false;
  let stopped = false;
  const worker = new HunyuanWorker({
    ...options,
    emit: event => { if (!stopped) output.write(JSON.stringify(event) + '\n'); },
    onExit: stop,
  });
  function stop() {
    stopped = true;
    worker.shutdown();
    input.removeListener('data', consume);
    input.pause();
  }
  function consume(chunk) {
    const bytes = Buffer.from(chunk);
    let start = 0;
    while (start <= bytes.length && !stopped) {
      const newline = bytes.indexOf(10, start);
      const piece = bytes.subarray(start, newline < 0 ? bytes.length : newline);
      if (!discarding) {
        if (pending.length + piece.length > MAX_LINE_BYTES) {
          pending = Buffer.alloc(0);
          discarding = true;
          worker.error(null, 'LINE_TOO_LONG');
        } else {
          pending = Buffer.concat([pending, piece]);
        }
      }
      if (newline >= 0) {
        if (!discarding && pending.length) {
          try { worker.handle(JSON.parse(pending.toString('utf8'))); }
          catch { worker.error(null, 'INVALID_COMMAND'); }
        }
        pending = Buffer.alloc(0);
        discarding = false;
      }
      if (newline < 0) break;
      start = newline + 1;
    }
  }
  output.on('error', stop);
  input.on('data', consume);
  input.on('end', stop);
  input.on('error', stop);
  output.write(JSON.stringify({ event: 'ready' }) + '\n');
  return worker;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) runWorker();
