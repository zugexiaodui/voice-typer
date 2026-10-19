import test from 'node:test';
import assert from 'node:assert/strict';
import { once, EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { gzipSync, gunzipSync } from 'node:zlib';
import { WebSocketServer } from 'ws';
import { encodeInit, encodeAudio, parseResponse, normalizeResult, buildPayload, parsePcmWav } from './doubao-protocol.mjs';
import { DoubaoWorker, resolveCredential, runWorker, ENDPOINTS } from './worker_doubao.mjs';

function serverPacket(body, { final = false, type = 9, code = 0, compressed = true, sequence = 1, event } = {}) {
  const data = Buffer.from(JSON.stringify(body));
  const payload = compressed ? gzipSync(data) : data;
  const flags = 1 | (final ? 2 : 0) | (event === undefined ? 0 : 4);
  const b = Buffer.alloc(4 + 4 + (event === undefined ? 0 : 4) + (type === 15 ? 4 : 0) + 4 + payload.length);
  b.set([0x11, (type << 4) | flags, 0x10 | Number(compressed), 0]);
  let at = 4; b.writeInt32BE(final ? -sequence : sequence, at); at += 4;
  if (event !== undefined) { b.writeUInt32BE(event, at); at += 4; }
  if (type === 15) { b.writeInt32BE(code, at); at += 4; }
  b.writeUInt32BE(payload.length, at); payload.copy(b, at + 4); return b;
}
function clientPacket(b) {
  return { type: b[1] >> 4, flags: b[1] & 15, sequence: b.readInt32BE(4), payload: gunzipSync(b.subarray(12)) };
}
function wav(pcm = Buffer.alloc(12800), extra = false) {
  const b = Buffer.alloc(44 + pcm.length + (extra ? 10 : 0));
  b.write('RIFF'); b.writeUInt32LE(b.length - 8, 4); b.write('WAVE', 8); b.write('fmt ', 12); b.writeUInt32LE(16, 16);
  b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22); b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  let at = 36;
  if (extra) { b.write('JUNK', at); b.writeUInt32LE(1, at + 4); at += 10; }
  b.write('data', at); b.writeUInt32LE(pcm.length, at + 4); pcm.copy(b, at + 8); return b;
}
async function until(predicate, timeout = 2000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) { if (Date.now() > deadline) throw new Error('Test condition timed out'); await new Promise(r => setTimeout(r, 5)); }
}
async function fixture(t, onPacket, config = {}) {
  const server = new WebSocketServer({ port: 0, host: '127.0.0.1' }); await once(server, 'listening');
  const packets = [], connections = [], events = [];
  server.on('connection', (socket, req) => {
    connections.push({ socket, req });
    socket.on('message', data => { const p = clientPacket(data); packets.push(p); onPacket?.(socket, p); });
  });
  const worker = new DoubaoWorker({ emit: event => events.push(event), env: { DOUBAO_API_KEY: 'test-secret' },
    endpointForMode: () => `ws://127.0.0.1:${server.address().port}`, ...config });
  t.after(async () => { worker.shutdown(); for (const c of server.clients) c.terminate(); await new Promise(r => server.close(r)); });
  return { server, worker, packets, events, connections };
}

test('positive init/audio and negative final sequence match official layout', () => {
  const init = clientPacket(encodeInit(1, { hello: '你好' }));
  assert.equal(init.type, 1); assert.equal(init.sequence, 1); assert.deepEqual(JSON.parse(init.payload), { hello: '你好' });
  const audio = clientPacket(encodeAudio(2, Buffer.from([1, 2])));
  assert.equal(audio.type, 2); assert.equal(audio.flags, 1); assert.equal(audio.sequence, 2);
  assert.deepEqual(audio.payload, Buffer.from([1, 2]));
  const last = clientPacket(encodeAudio(3, Buffer.alloc(0), true)); assert.equal(last.flags, 3); assert.equal(last.sequence, -3);
  assert.throws(() => encodeAudio(0, Buffer.alloc(0))); assert.throws(() => encodeAudio(1, Buffer.alloc(1)));
});
test('parser validates lengths, encoding, compression and optional event', () => {
  const b = serverPacket({ result: { text: '文字' } }, { final: true, event: 12 });
  assert.deepEqual(parseResponse(b), { type: 9, sequence: -1, event: 12, code: 0, isLast: true, body: { result: { text: '文字' } } });
  for (let end = 0; end < b.length; end++) assert.throws(() => parseResponse(b.subarray(0, end)));
  assert.throws(() => parseResponse(Buffer.concat([b, Buffer.alloc(1)])));
  const bad = Buffer.from(b); bad[0] = 0x21; assert.throws(() => parseResponse(bad));
  const corrupt = Buffer.from(b); corrupt.fill(0, 16); assert.throws(() => parseResponse(corrupt));
  assert.equal(parseResponse(serverPacket({ error: 'private secret' }, { type: 15, code: 45000000 })).code, 45000000);
  assert.equal(parseResponse(serverPacket({}, { compressed: false })).isLast, false);
});
test('normalization preserves current snapshots and definitive utterances', () => {
  const result = normalizeResult({ result: [{ text: '你好', utterances: [{ text: '你好', start_time: 10, end_time: 200, definite: false }] }] });
  assert.deepEqual(result, { text: '你好', segments: [{ text: '你好', start: 10, end: 200, definite: false }] });
  assert.equal(normalizeResult({ result: { utterances: [{ text: '好', definite: false }] } }, true).segments[0].definite, true);
});
test('payload defaults and hotword JSON serialization', () => {
  const p = buildPayload('realtime', { hotwords: 'DeepSeek、豆包, Qwen3' });
  assert.equal(p.request.enable_nonstream, true); assert.equal(p.request.enable_ddc, false); assert.equal(p.request.result_type, 'full');
  assert.deepEqual(JSON.parse(p.request.corpus.context).hotwords, [{ word: 'DeepSeek' }, { word: '豆包' }, { word: 'Qwen3' }]);
  assert.equal(buildPayload('sentence', { language: 'zh-CN' }).audio.language, 'zh-CN');
  assert.throws(() => buildPayload('realtime', { language: 'zh-CN' }));
  assert.throws(() => buildPayload('realtime', { result_type: 'single' }));
  assert.throws(() => buildPayload('realtime', { end_window_size: 299 }));
});
test('native WAV parser handles nonstandard chunk offsets and rejects mismatched audio', () => {
  const pcm = Buffer.from([1, 2, 3, 4]); assert.deepEqual(parsePcmWav(wav(pcm, true)), pcm);
  const stereo = wav(pcm); stereo.writeUInt16LE(2, 22); assert.throws(() => parsePcmWav(stereo));
  const truncated = wav(pcm).subarray(0, 45); assert.throws(() => parsePcmWav(truncated));
});
test('credential lookup accepts refs, named environment and quoted scalars', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vt-key-test-')); t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const file = path.join(root, 'credentials.yaml'); fs.writeFileSync(file, 'refs:\n  MY_KEY: "test-key"\n');
  assert.equal(resolveCredential({ VT_DOUBAO_KEYFILE: file, VT_DOUBAO_KEY_NAME: 'MY_KEY' }), 'test-key');
  assert.equal(resolveCredential({ MY_KEY: ' env-key ' }, 'MY_KEY'), 'env-key');
  assert.equal(resolveCredential({ DOUBAO_API_KEY: 'raw', VT_DOUBAO_API_KEY: 'override' }), 'override');
  assert.equal(resolveCredential({}, 'bad[regex'), null);
});
test('concurrent receipt, queued audio, final packet and exactly-once finished', async t => {
  const f = await fixture(t, (ws, p) => {
    if (p.type === 1) ws.send(serverPacket({ result: { text: '你', utterances: [{ text: '你', definite: false }] } }));
    else if (p.flags === 3) ws.send(serverPacket({ result: { text: '你好。', utterances: [{ text: '你好。', start_time: 0, end_time: 200, definite: true }] } }, { final: true }));
  });
  f.worker.handle({ cmd: 'start', session: 'a', mode: 'realtime' });
  f.worker.handle({ cmd: 'audio', session: 'a', data: Buffer.alloc(6400).toString('base64') });
  await until(() => f.events.some(e => e.event === 'result'));
  assert.equal(f.events.some(e => e.event === 'finished'), false);
  f.worker.handle({ cmd: 'finish', session: 'a' }); f.worker.handle({ cmd: 'finish', session: 'a' });
  await until(() => f.events.some(e => e.event === 'finished'));
  assert.deepEqual(f.events.map(e => e.event), ['connected', 'result', 'result', 'finished']);
  assert.deepEqual(f.packets.map(p => p.sequence), [1, 2, -3]);
  assert.equal(f.events.at(-1).text, '你好。'); assert.equal(typeof f.events.at(-1).finishMs, 'number');
  assert.equal(f.connections[0].req.headers['x-api-key'], 'test-secret');
});
test('unexpected disconnect and server errors never report finished or echo provider secrets', async t => {
  const f = await fixture(t, (ws, p) => { if (p.type === 1) ws.close(); });
  f.worker.handle({ cmd: 'start', session: 'lost' }); await until(() => f.events.some(e => e.event === 'error'));
  assert.equal(f.events.at(-1).code, 'DISCONNECTED'); assert.equal(f.events.some(e => e.event === 'finished'), false);
  const g = await fixture(t, (ws, p) => { if (p.type === 1) ws.send(serverPacket({ message: 'test-secret' }, { type: 15, code: 45000000 })); });
  g.worker.handle({ cmd: 'start', session: 'rejected' }); await until(() => g.events.some(e => e.event === 'error'));
  assert.equal(g.events.at(-1).serviceCode, 45000000); assert.equal(JSON.stringify(g.events).includes('test-secret'), false);
});
test('cancel isolates old callbacks while next session can finish', async t => {
  const f = await fixture(t);
  f.worker.handle({ cmd: 'start', session: 'old' }); await until(() => f.events.some(e => e.event === 'connected'));
  const oldState = f.worker.active; f.worker.handle({ cmd: 'cancel', session: 'old' });
  f.worker.handle({ cmd: 'start', session: 'new' }); await until(() => f.events.filter(e => e.event === 'connected').length === 2);
  f.worker.receive(oldState, serverPacket({ result: { text: 'stale' } }, { final: true }));
  f.worker.handle({ cmd: 'cancel', session: 'old' });
  f.connections[1].socket.send(serverPacket({ result: { text: 'fresh' } }, { final: true }));
  await until(() => f.events.some(e => e.event === 'finished'));
  assert.equal(f.events.at(-1).session, 'new'); assert.equal(f.events.at(-1).text, 'fresh');
  assert.equal(f.events.some(e => e.text === 'stale'), false);
});
test('finish timeout, malformed packet and overflow are bounded errors', async t => {
  const f = await fixture(t); f.worker.handle({ cmd: 'start', session: 'timeout', options: { timeoutMs: 30 } });
  await until(() => f.events.length); f.worker.handle({ cmd: 'finish', session: 'timeout' });
  await until(() => f.events.some(e => e.code === 'FINISH_TIMEOUT'));
  const g = await fixture(t, (ws, p) => { if (p.type === 1) ws.send(Buffer.from([0])); });
  g.worker.handle({ cmd: 'start', session: 'bad' }); await until(() => g.events.some(e => e.code === 'PROTOCOL_ERROR'));
  const h = await fixture(t, null, { maxQueueBytes: 10 }); h.worker.handle({ cmd: 'start', session: 'big' });
  h.worker.handle({ cmd: 'audio', session: 'big', data: Buffer.alloc(12).toString('base64') });
  assert.equal(h.events.at(-1).code, 'QUEUE_OVERFLOW');
});
test('connection deadline and websocket backpressure cannot hang indefinitely', async () => {
  class NeverOpen extends EventEmitter { constructor() { super(); this.readyState = 0; } terminate() { this.readyState = 3; } }
  const events = [];
  const a = new DoubaoWorker({ emit: e => events.push(e), env: { DOUBAO_API_KEY: 'secret' }, WebSocketImpl: NeverOpen });
  a.handle({ cmd: 'start', session: 'opening', options: { connectTimeoutMs: 20 } });
  await until(() => events.length); assert.equal(events[0].code, 'CONNECT_TIMEOUT'); a.shutdown();
  class Stalled extends NeverOpen {
    constructor() { super(); this.readyState = 1; this.bufferedAmount = 100; queueMicrotask(() => this.emit('open')); }
    send(_data, _options, cb) { cb(); }
    close() { this.readyState = 3; }
  }
  const out = [], b = new DoubaoWorker({ emit: e => out.push(e), env: { DOUBAO_API_KEY: 'secret' }, WebSocketImpl: Stalled, highWaterBytes: 5, sendTimeoutMs: 20 });
  b.handle({ cmd: 'start', session: 'stalled' }); b.handle({ cmd: 'audio', session: 'stalled', data: 'AAA=' });
  await until(() => out.some(e => e.code === 'SEND_TIMEOUT')); b.shutdown();
});
test('recognize uses PCM-only chunks paced at 200ms and ends after final response', async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vt-wav-test-')); t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const file = path.join(root, 'sample.wav'); fs.writeFileSync(file, wav()); const times = [];
  const f = await fixture(t, (ws, p) => {
    if (p.type === 2 && p.flags !== 3) times.push(Date.now());
    if (p.flags === 3) ws.send(serverPacket({ result: { text: 'file result' } }, { final: true }));
  });
  f.worker.handle({ cmd: 'recognize', session: 'file', wav: file, mode: 'sentence' });
  await until(() => f.events.some(e => e.event === 'finished'));
  assert.equal(times.length, 2); assert.ok(times[1] - times[0] >= 170);
  assert.equal(JSON.parse(f.packets[0].payload).audio.format, 'pcm');
  assert.equal(f.packets.filter(p => p.type === 2).reduce((n, p) => n + p.payload.length, 0), 12800);
  assert.equal(f.events.at(-1).text, 'file result');
});
test('JSONL ready, split commands, oversized lines and exit keep stdout structured', async () => {
  const input = new PassThrough(), output = new PassThrough(), lines = [];
  output.on('data', b => lines.push(...b.toString().trim().split('\n').map(JSON.parse)));
  const worker = runWorker(input, output);
  input.write('{"cmd":"start","session":'); input.write('"x","mode":"unknown"}\n');
  input.write('x'.repeat(140000)); input.write('\n'); input.write('{"cmd":"exit"}\n');
  assert.deepEqual(lines.map(l => l.event), ['ready', 'error', 'error']);
  assert.equal(lines[1].code, 'INVALID_OPTIONS'); assert.equal(lines[2].code, 'LINE_TOO_LONG'); worker.shutdown();
  assert.equal(ENDPOINTS.realtime.endsWith('bigmodel_async'), true);
});
test('JSONL byte splits preserve multibyte session identifiers', () => {
  const input = new PassThrough(), output = new PassThrough(), events = [];
  output.on('data', b => events.push(JSON.parse(b.toString())));
  const worker = runWorker(input, output);
  const command = Buffer.from(JSON.stringify({ cmd: 'audio', session: '会话' }) + '\n');
  const split = command.indexOf(Buffer.from('会')) + 1;
  input.write(command.subarray(0, split)); input.write(command.subarray(split));
  assert.equal(events.at(-1).session, '会话'); worker.shutdown(); input.end();
});
test('empty authoritative full result clears earlier provisional text', async t => {
  const f = await fixture(t, (ws, p) => {
    if (p.type === 1) ws.send(serverPacket({ result: { text: 'provisional' } }));
    if (p.flags === 3) ws.send(serverPacket({ result: { text: '', utterances: [] } }, { final: true }));
  });
  f.worker.handle({ cmd: 'start', session: 'clear' });
  await until(() => f.events.some(e => e.event === 'result'));
  f.worker.handle({ cmd: 'finish', session: 'clear' });
  await until(() => f.events.some(e => e.event === 'finished'));
  assert.equal(f.events.at(-1).text, ''); assert.deepEqual(f.events.at(-1).segments, []);
});
