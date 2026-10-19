// Persistent JSONL worker. stdout is protocol-only; errors never echo provider payloads or credentials.
// Commands: start/audio/finish/cancel/recognize/exit. PCM audio is mono16k signed16 LE.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import WebSocket from 'ws';
import { encodeInit, encodeAudio, parseResponse, normalizeResult, buildPayload, parsePcmWav } from './doubao-protocol.mjs';

export const ENDPOINTS = Object.freeze({
  sentence: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream',
  realtime: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async',
});
const MAX_AUDIO_BYTES = 64 * 1024;
const MAX_LINE_BYTES = 128 * 1024;
const MAX_WAV_BYTES = 64 * 1024 * 1024;
const SAFE_ERRORS = Object.freeze({
  INVALID_COMMAND: 'Invalid worker command', INVALID_SESSION: 'A nonempty session string is required',
  INVALID_OPTIONS: 'Invalid recognition options', MISSING_KEY: 'Doubao API credential is not configured',
  INVALID_AUDIO: 'Expected base64 PCM16 mono 16000 Hz audio', SESSION_NOT_ACTIVE: 'Session is not active',
  INPUT_CLOSED: 'Audio input has already finished', QUEUE_OVERFLOW: 'Audio sending queue exceeded its limit',
  CONNECT_TIMEOUT: 'Doubao connection timed out', CONNECT_FAILED: 'Doubao connection failed; check network and service permission',
  SEND_TIMEOUT: 'Audio sending timed out', SEND_FAILED: 'Audio sending failed',
  FINISH_TIMEOUT: 'Timed out waiting for the final recognition packet',
  PROTOCOL_ERROR: 'Invalid response from Doubao', SERVICE_ERROR: 'Doubao rejected the recognition request',
  DISCONNECTED: 'Doubao disconnected before the final recognition packet',
  INVALID_WAV: 'Expected a readable PCM16 mono 16000 Hz WAV within 64 MiB',
  LINE_TOO_LONG: 'Worker command exceeded its size limit',
});
const validSession = value => typeof value === 'string' && value.length > 0 && value.length <= 128;
const elapsed = start => Math.round(performance.now() - start);
function boundedTimeout(value, fallback) {
  return value === undefined ? fallback : Number.isInteger(value) && value >= 10 && value <= 120000 ? value : null;
}

export function resolveCredential(env = process.env, keyName = env.VT_DOUBAO_KEY_NAME || 'DOUBAO_API_KEY') {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(keyName)) return null;
  for (const name of ['VT_DOUBAO_API_KEY', 'DOUBAO_API_KEY', keyName]) {
    if (typeof env[name] === 'string' && env[name].trim()) return env[name].trim();
  }
  const file = env.VT_DOUBAO_KEYFILE || path.join(os.homedir(), '.dsh', '.credentials.yaml');
  try {
    if (fs.statSync(file).size > 1024 * 1024) return null;
    const raw = fs.readFileSync(file, 'utf8');
    // Match refs entries by name, as corrector.mjs does; accept common YAML scalar quoting.
    const escaped = keyName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const m = raw.match(new RegExp('^\\s*' + escaped + '\\s*:\\s*(?:"([^"\\r\\n]+)"|\x27([^\x27\\r\\n]+)\x27|([^\\s#]+))', 'm'));
    return m ? (m[1] || m[2] || m[3]).trim() : null;
  } catch { return null; }
}

export class DoubaoWorker {
  constructor({ emit, env = process.env, WebSocketImpl = WebSocket, endpointForMode = mode => ENDPOINTS[mode],
    maxQueueBytes = 1024 * 1024, highWaterBytes = 256 * 1024, sendTimeoutMs = 10000, onExit = () => {} } = {}) {
    this.emit = emit || (() => {}); this.env = env; this.WebSocketImpl = WebSocketImpl;
    this.endpointForMode = endpointForMode; this.maxQueueBytes = maxQueueBytes;
    this.highWaterBytes = highWaterBytes; this.sendTimeoutMs = sendTimeoutMs; this.onExit = onExit;
    this.active = null; this.exited = false;
  }
  error(session, code, extra = {}) {
    this.emit({ event: 'error', session: validSession(session) ? session : null, code, error: SAFE_ERRORS[code] || SAFE_ERRORS.INVALID_COMMAND, ...extra });
  }
  current(s) { return this.active === s && !s.done && !this.exited; }
  metrics(s) {
    return { connectedMs: s.connectedMs ?? null, firstResultMs: s.firstResultMs ?? null,
      finishMs: s.finishAt === null ? null : elapsed(s.finishAt), totalMs: elapsed(s.startedAt) };
  }
  dispose(s) {
    s.done = true;
    for (const timer of [s.connectTimer, s.finishTimer, s.sendTimer, s.drainTimer, s.fileTimer]) clearTimeout(timer);
    s.queue.length = 0; s.pendingResponses.length = 0; s.queuedBytes = 0;
    if (this.active === s) this.active = null;
    // Keep the error listener installed: terminate during handshake can emit an asynchronous error.
    try { if (s.ws?.readyState === 1) s.ws.close(); else s.ws?.terminate(); } catch { }
    if (s.ws?.readyState !== 3) {
      const socket = s.ws;
      const timer = setTimeout(() => { try { socket?.terminate(); } catch { } }, 250);
      timer.unref?.();
    }
  }
  fail(s, code, extra = {}) {
    if (!this.current(s)) return;
    const metrics = this.metrics(s); this.dispose(s);
    this.error(s.session, code, { ...extra, ...metrics });
  }
  handle(command) {
    if (this.exited) return;
    if (!command || typeof command !== 'object' || Array.isArray(command)) return this.error(null, 'INVALID_COMMAND');
    const { cmd, session } = command;
    if (cmd === 'exit') { this.exited = true; if (this.active) this.dispose(this.active); this.onExit(); return; }
    if (!validSession(session)) return this.error(null, 'INVALID_SESSION');
    if (cmd === 'start' || cmd === 'recognize') return this.begin(command);
    if (cmd === 'cancel') {
      if (this.active?.session === session) this.dispose(this.active);
      return; // Idempotent; finished is reserved for a server final packet.
    }
    if (!['audio', 'finish'].includes(cmd)) return this.error(session, 'INVALID_COMMAND');
    const s = this.active;
    if (!s || s.session !== session) return this.error(session, 'SESSION_NOT_ACTIVE');
    if (cmd === 'finish') { this.finish(s); return; }
    if (s.fileMode || s.finishRequested) return this.fail(s, 'INPUT_CLOSED');
    if (typeof command.data !== 'string' || command.data.length > Math.ceil(MAX_AUDIO_BYTES / 3) * 4 ||
        !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(command.data)) {
      return this.fail(s, 'INVALID_AUDIO');
    }
    const pcm = Buffer.from(command.data, 'base64');
    if (!pcm.length || pcm.length % 2 || pcm.length > MAX_AUDIO_BYTES || pcm.toString('base64') !== command.data) {
      return this.fail(s, 'INVALID_AUDIO');
    }
    this.enqueue(s, pcm);
  }
  begin(command) {
    const mode = command.mode || 'sentence', options = command.options ?? {};
    if (typeof options !== 'object' || Array.isArray(options)) return this.error(command.session, 'INVALID_OPTIONS');
    let payload, pcm = null;
    const connectTimeoutMs = boundedTimeout(command.connectTimeoutMs ?? options.connectTimeoutMs, 10000);
    const finishTimeoutMs = boundedTimeout(command.timeoutMs ?? options.timeoutMs, 15000);
    try {
      payload = buildPayload(mode, options);
      if (!connectTimeoutMs || !finishTimeoutMs || (command.resourceId !== undefined &&
          !['volc.seedasr.sauc.duration', 'volc.seedasr.sauc.concurrent', 'volc.bigasr.sauc.duration', 'volc.bigasr.sauc.concurrent'].includes(command.resourceId)) ||
          (command.keyName !== undefined && (typeof command.keyName !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(command.keyName)))) throw new Error();
    } catch { this.error(command.session, 'INVALID_OPTIONS'); return; }
    const key = resolveCredential(this.env, command.keyName);
    if (!key) return this.error(command.session, 'MISSING_KEY');
    if (command.cmd === 'recognize') {
      try {
        if (typeof command.wav !== 'string' || fs.statSync(command.wav).size > MAX_WAV_BYTES) throw new Error();
        pcm = parsePcmWav(fs.readFileSync(command.wav));
      } catch { this.error(command.session, 'INVALID_WAV'); return; }
    }
    if (this.active) this.dispose(this.active);
    const s = { session: command.session, mode, payload, queue: [], queuedBytes: 0, sequence: 1, pendingResponses: [],
      done: false, initialized: false, sending: false, finishRequested: false, lastSent: false,
      finishTimeoutMs, startedAt: performance.now(), finishAt: null, lastResult: { text: '', segments: [] },
      fileMode: Boolean(pcm), filePcm: pcm, fileOffset: 0 };
    this.active = s;
    s.connectTimer = setTimeout(() => this.fail(s, 'CONNECT_TIMEOUT'), connectTimeoutMs);
    try {
      s.ws = new this.WebSocketImpl(this.endpointForMode(mode), {
        headers: { 'X-Api-Key': key, 'X-Api-Resource-Id': command.resourceId || 'volc.seedasr.sauc.duration', 'X-Api-Request-Id': randomUUID() },
        handshakeTimeout: connectTimeoutMs, maxPayload: 4 * 1024 * 1024, perMessageDeflate: false,
      });
      s.ws.on('error', () => this.fail(s, s.initialized ? 'SEND_FAILED' : 'CONNECT_FAILED'));
      s.ws.on('unexpected-response', (_request, response) => {
        response.resume(); this.fail(s, 'CONNECT_FAILED', { httpStatus: response.statusCode });
      });
      s.ws.on('close', () => this.fail(s, 'DISCONNECTED'));
      s.ws.on('message', (data, isBinary) => {
        if (!this.current(s)) return;
        if (!isBinary) return this.fail(s, 'PROTOCOL_ERROR');
        if (!s.initialized) {
          if (s.pendingResponses.length >= 16) return this.fail(s, 'PROTOCOL_ERROR');
          s.pendingResponses.push(data); return;
        }
        this.receive(s, data);
      });
      s.ws.on('open', () => {
        if (!this.current(s)) return;
        this.send(s, encodeInit(s.sequence++, payload), () => {
          clearTimeout(s.connectTimer); s.initialized = true; s.connectedMs = elapsed(s.startedAt);
          this.emit({ event: 'connected', session: s.session, mode, ...this.metrics(s) });
          const pending = s.pendingResponses.splice(0);
          for (const data of pending) this.receive(s, data);
          if (!this.current(s)) return;
          if (s.fileMode) this.feedFile(s);
          this.drain(s);
        });
      });
    } catch { this.fail(s, 'CONNECT_FAILED'); }
  }
  send(s, packet, callback) {
    if (!this.current(s)) return;
    s.sending = true;
    s.sendTimer = setTimeout(() => this.fail(s, 'SEND_TIMEOUT'), this.sendTimeoutMs);
    try {
      s.ws.send(packet, { binary: true }, error => {
        if (!this.current(s)) return;
        clearTimeout(s.sendTimer); s.sending = false;
        if (error) return this.fail(s, 'SEND_FAILED');
        callback();
      });
    } catch { this.fail(s, 'SEND_FAILED'); }
  }
  enqueue(s, pcm) {
    if (!this.current(s)) return;
    if (s.queuedBytes + pcm.length + (s.ws?.bufferedAmount || 0) > this.maxQueueBytes) return this.fail(s, 'QUEUE_OVERFLOW');
    s.queue.push(pcm); s.queuedBytes += pcm.length; this.drain(s);
  }
  drain(s) {
    if (!this.current(s) || !s.initialized || s.sending || s.lastSent || s.drainTimer) return;
    if ((s.ws.bufferedAmount || 0) > this.highWaterBytes) {
      s.backpressureSince ??= performance.now();
      if (elapsed(s.backpressureSince) >= this.sendTimeoutMs) return this.fail(s, 'SEND_TIMEOUT');
      s.drainTimer = setTimeout(() => { s.drainTimer = null; this.drain(s); }, 10); return;
    }
    s.backpressureSince = null;
    try {
      if (s.queue.length) {
        const pcm = s.queue.shift();
        this.send(s, encodeAudio(s.sequence++, pcm), () => { s.queuedBytes -= pcm.length; this.drain(s); });
      } else if (s.finishRequested) {
        s.lastSent = true;
        this.send(s, encodeAudio(s.sequence++, Buffer.alloc(0), true), () => {});
      }
    } catch { this.fail(s, 'PROTOCOL_ERROR'); }
  }
  finish(s) {
    if (!this.current(s) || s.finishRequested) return;
    // recognize owns its input lifetime; a manual finish is allowed and stops file feeding.
    clearTimeout(s.fileTimer); s.filePcm = null;
    s.finishRequested = true; s.finishAt = performance.now();
    s.finishTimer = setTimeout(() => this.fail(s, 'FINISH_TIMEOUT'), s.finishTimeoutMs);
    this.drain(s);
  }
  feedFile(s) {
    if (!this.current(s) || s.finishRequested || !s.filePcm) return;
    const end = Math.min(s.fileOffset + 6400, s.filePcm.length);
    this.enqueue(s, s.filePcm.subarray(s.fileOffset, end)); s.fileOffset = end;
    if (!this.current(s)) return;
    if (end >= s.filePcm.length) { this.finish(s); return; }
    s.fileTimer = setTimeout(() => this.feedFile(s), 200);
  }
  receive(s, data) {
    if (!this.current(s)) return;
    let response;
    try { response = parseResponse(data); } catch { return this.fail(s, 'PROTOCOL_ERROR'); }
    const bodyCode = response.body?.code;
    if (response.type === 15 || response.code !== 0 || (bodyCode !== undefined && bodyCode !== 0 && bodyCode !== 20000000)) {
      const value = response.code || bodyCode;
      return this.fail(s, 'SERVICE_ERROR', Number.isInteger(value) ? { serviceCode: value } : {});
    }
    const normalized = normalizeResult(response.body, response.isLast);
    if (response.body && Object.hasOwn(response.body, 'result')) {
      s.lastResult = normalized;
      if (normalized.text && s.firstResultMs === undefined) s.firstResultMs = elapsed(s.startedAt);
      this.emit({ event: 'result', session: s.session, ...normalized, isFinal: response.isLast, ...this.metrics(s) });
    }
    if (response.isLast) {
      const result = { ...s.lastResult, segments: s.lastResult.segments.map(segment => ({ ...segment, definite: true })) };
      const event = { event: 'finished', session: s.session, ...result, ...this.metrics(s) };
      this.dispose(s); this.emit(event);
    }
  }
  shutdown() { this.exited = true; if (this.active) this.dispose(this.active); }
}

export function runWorker(input = process.stdin, output = process.stdout) {
  let pending = Buffer.alloc(0), discarding = false, stopped = false;
  const worker = new DoubaoWorker({ emit: event => { if (!stopped) output.write(JSON.stringify(event) + '\n'); }, onExit: stop });
  function stop() { stopped = true; worker.shutdown(); input.removeListener('data', consume); input.pause(); }
  function consume(chunk) {
    const bytes = Buffer.from(chunk);
    let start = 0;
    while (start <= bytes.length && !stopped) {
      const newline = bytes.indexOf(10, start);
      const piece = bytes.subarray(start, newline < 0 ? bytes.length : newline);
      if (!discarding) {
        if (pending.length + piece.length > MAX_LINE_BYTES) {
          pending = Buffer.alloc(0); discarding = true; worker.error(null, 'LINE_TOO_LONG');
        } else pending = Buffer.concat([pending, piece]);
      }
      if (newline >= 0) {
        if (!discarding && pending.toString('utf8').trim()) {
          try { worker.handle(JSON.parse(pending.toString('utf8'))); }
          catch { worker.error(null, 'INVALID_COMMAND'); }
        }
        pending = Buffer.alloc(0); discarding = false;
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
