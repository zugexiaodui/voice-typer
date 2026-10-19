import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { once } from 'node:events';
import { PassThrough } from 'node:stream';
import {
  ENDPOINT,
  DEFAULT_MODEL,
  MAX_AUDIO_BYTES,
  SAFE_ERRORS,
  HunyuanError,
  HunyuanWorker,
  buildRequest,
  parseAsrResponse,
  recognizeOnce,
  requestOnce,
  resolveCredential,
  runWorker,
} from './worker_hunyuan.mjs';

async function waitFor(predicate, timeout = 3000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('Test condition timed out');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

function tempDir(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vt-hunyuan-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function parseLines(raw) {
  return raw.toString('utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
}

const SUCCESS_PAYLOAD = {
  id: 'th_test',
  object: 'asr.task',
  status: 'completed',
  output: {
    duration_ms: 5592,
    text: '你好，世界。',
    sentences: [
      { begin_ms: 0, end_ms: 2500, text: '你好，' },
      { begin_ms: 2500, end_ms: 5592, text: '世界。' },
    ],
    subtitle_url: 'https://example.invalid/subtitle.json',
  },
  usage: { total_tokens: 123 },
  request_id: 'req_test',
};

test('buildRequest sends plain base64 data and the selected model', () => {
  const audio = Buffer.from([0, 1, 2, 3, 254, 255]);
  const request = buildRequest({ audio });
  assert.equal(request.endpoint, ENDPOINT);
  assert.equal(request.method, 'POST');
  assert.equal(request.headers['Content-Type'], 'application/json');
  assert.equal(request.headers.Authorization, undefined);
  const body = JSON.parse(request.body);
  assert.equal(body.model, DEFAULT_MODEL);
  assert.equal(body.data, audio.toString('base64'));
  // TokenHub corrupts audio when the base64 carries a data-URI prefix.
  assert.equal(request.body.includes('data:'), false);
  assert.equal(request.body.includes('data:audio'), false);
  assert.equal(request.body.includes(';base64'), false);
  const custom = buildRequest({ audio, model: 'hy-asr-custom', key: 'secret-key' });
  assert.equal(JSON.parse(custom.body).model, 'hy-asr-custom');
  assert.equal(custom.headers.Authorization, 'Bearer secret-key');
  assert.equal(custom.body.includes('secret-key'), false);
});

test('buildRequest rejects empty and oversized audio', () => {
  assert.throws(() => buildRequest({ audio: Buffer.alloc(0) }), error => error.code === 'INVALID_AUDIO');
  assert.throws(() => buildRequest({ audio: Buffer.alloc(MAX_AUDIO_BYTES + 1) }), error => error.code === 'AUDIO_TOO_LARGE');
  assert.throws(() => buildRequest({ audio: Buffer.from([1]), model: '   ' }), error => error.code === 'INVALID_OPTIONS');
});

test('parseAsrResponse maps success text, segments, duration and tokens', () => {
  const parsed = parseAsrResponse(JSON.stringify(SUCCESS_PAYLOAD), { httpStatus: 200 });
  assert.deepEqual(parsed, {
    ok: true,
    text: '你好，世界。',
    segments: [
      { text: '你好，', start: 0, end: 2500 },
      { text: '世界。', start: 2500, end: 5592 },
    ],
    durationMs: 5592,
    tokens: 123,
  });
  const fromBuffer = parseAsrResponse(Buffer.from(JSON.stringify(SUCCESS_PAYLOAD)), { httpStatus: 200 });
  assert.equal(fromBuffer.text, parsed.text);
  const noUsage = parseAsrResponse(JSON.stringify({ output: { text: 'ok' } }));
  assert.equal(noUsage.ok, true);
  assert.deepEqual(noUsage.segments, []);
  assert.equal(noUsage.durationMs, null);
  assert.equal(noUsage.tokens, null);
});

test('parseAsrResponse maps provider errors without leaking provider text', () => {
  const providerMessage = 'quota exhausted for internal project alpha-secret';
  const body = JSON.stringify({
    error: {
      code: '400001',
      message: providerMessage,
      message_zh: '额度不足',
      type: 'invalid_request_error',
      source: 'internal',
    },
  });
  const parsed = parseAsrResponse(body, { httpStatus: 402 });
  assert.equal(parsed.ok, false);
  assert.equal(parsed.code, 'HTTP_ERROR');
  assert.equal(parsed.error, SAFE_ERRORS.HTTP_ERROR);
  assert.equal(parsed.httpStatus, 402);
  assert.equal(parsed.providerCode, '400001');
  const serialized = JSON.stringify(parsed);
  assert.equal(serialized.includes(providerMessage), false);
  assert.equal(serialized.includes('额度不足'), false);
  assert.equal(serialized.includes('alpha-secret'), false);
});

test('recognizeOnce surfaces a safe HTTP_ERROR and never echoes the key', async () => {
  const key = 'super-secret-hunyuan-key';
  let seenRequest;
  const requestImpl = async request => {
    seenRequest = request;
    return {
      statusCode: 400,
      body: JSON.stringify({ error: { code: '400001', message: 'provider complained about ' + key } }),
    };
  };
  await assert.rejects(
    recognizeOnce({ audio: Buffer.from([1, 2, 3, 4]) }, { env: { HUNYUAN_API_KEY: key }, requestImpl }),
    error => {
      assert.ok(error instanceof HunyuanError);
      assert.equal(error.code, 'HTTP_ERROR');
      assert.equal(error.message, SAFE_ERRORS.HTTP_ERROR);
      assert.equal(error.httpStatus, 400);
      assert.equal(error.providerCode, '400001');
      assert.equal(String(error.message).includes(key), false);
      assert.equal(JSON.stringify(error).includes(key), false);
      assert.equal(JSON.stringify(error).includes('provider complained'), false);
      return true;
    },
  );
  assert.equal(seenRequest.headers.Authorization, 'Bearer ' + key);
  assert.equal(seenRequest.body.includes(key), false);
  assert.equal(JSON.parse(seenRequest.body).data, Buffer.from([1, 2, 3, 4]).toString('base64'));
});

test('recognizeOnce reports MISSING_KEY when no credential exists', async t => {
  const root = tempDir(t);
  let called = false;
  await assert.rejects(
    recognizeOnce({ audio: Buffer.from([1, 2]) }, {
      env: { VT_HUNYUAN_KEYFILE: path.join(root, 'missing-credentials.yaml') },
      requestImpl: async () => { called = true; throw new Error('network must not be reached'); },
    }),
    error => error.code === 'MISSING_KEY',
  );
  assert.equal(called, false);
});

test('resolveCredential reads override, base, named env and YAML forms', t => {
  const root = tempDir(t);
  const file = path.join(root, 'credentials.yaml');
  fs.writeFileSync(file, [
    'refs:',
    '  MY_HUNYUAN_KEY: "file-key"',
    "  SINGLE_KEY: 'single-key'",
    '  PLAIN_KEY: plain-key',
    '  COMMENTED_KEY: value # comment',
    '',
  ].join('\n'));
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, VT_HUNYUAN_KEY_NAME: 'MY_HUNYUAN_KEY' }), 'file-key');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, VT_HUNYUAN_KEY_NAME: 'SINGLE_KEY' }), 'single-key');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, VT_HUNYUAN_KEY_NAME: 'PLAIN_KEY' }), 'plain-key');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, VT_HUNYUAN_KEY_NAME: 'COMMENTED_KEY' }), 'value');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, MY_HUNYUAN_KEY: ' named-env ' }, 'MY_HUNYUAN_KEY'), 'named-env');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, HUNYUAN_API_KEY: 'base-key' }), 'base-key');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, HUNYUAN_API_KEY: 'base-key', VT_HUNYUAN_API_KEY: 'override-key' }), 'override-key');
  assert.equal(resolveCredential({ VT_HUNYUAN_KEYFILE: file, VT_HUNYUAN_KEY_NAME: 'ABSENT_KEY' }), null);
  assert.equal(resolveCredential({}, 'bad[name'), null);
});

test('requestOnce times out a stalled request and recognizeOnce maps timeouts', async t => {
  const server = http.createServer(request => { request.resume(); /* deliberately never respond */ });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => {
    server.closeAllConnections?.();
    server.close(() => resolve());
  }));
  const endpoint = 'http://127.0.0.1:' + server.address().port + '/asr';
  const started = Date.now();
  await assert.rejects(
    requestOnce({ endpoint, method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}', timeoutMs: 80 }),
    error => error instanceof HunyuanError && error.code === 'TIMEOUT',
  );
  assert.ok(Date.now() - started < 3000);
  await assert.rejects(
    recognizeOnce({ audio: Buffer.from([1, 2]), timeoutMs: 1000 }, {
      env: { HUNYUAN_API_KEY: 'test-secret' },
      requestImpl: async () => { const error = new Error('simulated timeout'); error.code = 'ETIMEDOUT'; throw error; },
    }),
    error => error.code === 'TIMEOUT',
  );
});

test('real http transport sends auth and accumulates the response body', async t => {
  const audio = Buffer.from([9, 8, 7, 6]);
  let seenRequest;
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      seenRequest = { headers: request.headers, body: Buffer.concat(chunks).toString('utf8') };
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(SUCCESS_PAYLOAD));
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => {
    server.closeAllConnections?.();
    server.close(() => resolve());
  }));
  const endpoint = 'http://127.0.0.1:' + server.address().port + '/v1/wand/asrproxy/sync_transcribe';
  const result = await recognizeOnce({ audio, endpoint, timeoutMs: 1000 }, {
    env: { HUNYUAN_API_KEY: 'transport-secret' },
    requestImpl: requestOnce,
  });
  assert.equal(result.text, SUCCESS_PAYLOAD.output.text);
  assert.equal(result.durationMs, 5592);
  assert.equal(seenRequest.headers.authorization, 'Bearer transport-secret');
  assert.equal(seenRequest.headers['content-type'], 'application/json');
  assert.deepEqual(JSON.parse(seenRequest.body), {
    model: DEFAULT_MODEL,
    data: audio.toString('base64'),
  });
});

test('parseAsrResponse maps non-JSON to PARSE_ERROR and missing output.text gracefully', () => {
  const nonJson = parseAsrResponse('<html>bad gateway</html>', { httpStatus: 200 });
  assert.equal(nonJson.ok, false);
  assert.equal(nonJson.code, 'PARSE_ERROR');
  assert.equal(nonJson.error, SAFE_ERRORS.PARSE_ERROR);
  assert.equal(nonJson.httpStatus, 200);
  const gateway = parseAsrResponse('bad gateway', { httpStatus: 502 });
  assert.equal(gateway.code, 'HTTP_ERROR');
  assert.equal(gateway.httpStatus, 502);
  const missingText = parseAsrResponse(JSON.stringify({ output: { sentences: [] } }), { httpStatus: 200 });
  assert.equal(missingText.code, 'PARSE_ERROR');
  const wrongShape = parseAsrResponse(JSON.stringify({ output: null }), { httpStatus: 200 });
  assert.equal(wrongShape.code, 'PARSE_ERROR');
});

test('oversized audio is rejected by recognizeOnce and the worker', async t => {
  let called = false;
  await assert.rejects(
    recognizeOnce({ audio: Buffer.alloc(MAX_AUDIO_BYTES + 1) }, {
      env: { HUNYUAN_API_KEY: 'test-secret' },
      requestImpl: async () => { called = true; throw new Error('network must not be reached'); },
    }),
    error => error.code === 'AUDIO_TOO_LARGE',
  );
  assert.equal(called, false);

  const events = [];
  const worker = new HunyuanWorker({
    emit: event => events.push(event),
    env: { HUNYUAN_API_KEY: 'test-secret' },
    maxAudioBytes: 8,
    requestImpl: async () => { called = true; return { statusCode: 200, body: JSON.stringify(SUCCESS_PAYLOAD) }; },
  });
  t.after(() => worker.shutdown());
  worker.handle({ cmd: 'recognize', session: 'large', pcm: Buffer.alloc(10).toString('base64') });
  assert.equal(events.length, 1);
  assert.equal(events[0].event, 'error');
  assert.equal(events[0].code, 'AUDIO_TOO_LARGE');
  assert.equal(events[0].httpStatus, null);
  assert.equal(called, false);
});

test('JSONL stream reassembles byte-split UTF-8 lines', async t => {
  const input = new PassThrough();
  const output = new PassThrough();
  let raw = Buffer.alloc(0);
  output.on('data', chunk => { raw = Buffer.concat([raw, chunk]); });
  const worker = runWorker(input, output, {
    env: { HUNYUAN_API_KEY: 'test-secret' },
    requestImpl: async () => ({ statusCode: 200, body: JSON.stringify(SUCCESS_PAYLOAD) }),
  });
  t.after(() => { worker.shutdown(); input.destroy(); });
  const session = '会话-🎤-abc';
  const lines = [
    JSON.stringify({ cmd: 'recognize', session, pcm: Buffer.from([0, 1, 2, 3]).toString('base64') }),
    JSON.stringify({ cmd: 'ping', session }),
  ].join('\n') + '\n';
  const bytes = Buffer.from(lines, 'utf8');
  for (let offset = 0; offset < bytes.length; offset += 1) input.write(bytes.subarray(offset, offset + 1));

  await waitFor(() => {
    const text = raw.toString('utf8');
    return text.includes('"event":"finished"') && text.includes('"event":"pong"');
  });
  const events = parseLines(raw);
  assert.deepEqual(events.map(event => event.event), ['ready', 'pong', 'finished']);
  const finished = events.find(event => event.event === 'finished');
  assert.equal(finished.session, session);
  assert.equal(finished.text, SUCCESS_PAYLOAD.output.text);
  assert.deepEqual(finished.segments, [
    { text: '你好，', start: 0, end: 2500 },
    { text: '世界。', start: 2500, end: 5592 },
  ]);
  assert.equal(finished.durationMs, 5592);
  assert.equal(finished.tokens, 123);
  assert.equal(typeof finished.elapsedMs, 'number');
  assert.equal(events.some(event => event.event === 'error'), false);
});

test('a second concurrent recognize is rejected with EVENT_NOT_IDLE', async t => {
  const events = [];
  let releaseFirst;
  const gate = new Promise(resolve => { releaseFirst = resolve; });
  let calls = 0;
  const worker = new HunyuanWorker({
    emit: event => events.push(event),
    env: { HUNYUAN_API_KEY: 'test-secret' },
    requestImpl: async () => {
      calls += 1;
      await gate;
      return { statusCode: 200, body: JSON.stringify(SUCCESS_PAYLOAD) };
    },
  });
  t.after(() => worker.shutdown());
  worker.handle({ cmd: 'recognize', session: 'first', pcm: Buffer.from([1, 2]).toString('base64') });
  worker.handle({ cmd: 'recognize', session: 'second', pcm: Buffer.from([3, 4]).toString('base64') });
  assert.equal(calls, 1);
  assert.equal(events.length, 1);
  assert.equal(events[0].event, 'error');
  assert.equal(events[0].code, 'EVENT_NOT_IDLE');
  assert.equal(events[0].session, 'second');
  assert.equal(events[0].error, SAFE_ERRORS.EVENT_NOT_IDLE);
  releaseFirst();
  await waitFor(() => events.some(event => event.event === 'finished'));
  const finished = events.find(event => event.event === 'finished');
  assert.equal(finished.session, 'first');
  assert.equal(finished.text, SUCCESS_PAYLOAD.output.text);
  assert.equal(events.some(event => event.event === 'error' && event.code !== 'EVENT_NOT_IDLE'), false);
});

test('exit aborts an in-flight request without emitting a late event', async t => {
  const events = [];
  let capturedSignal;
  const worker = new HunyuanWorker({
    emit: event => events.push(event),
    env: { HUNYUAN_API_KEY: 'test-secret' },
    requestImpl: request => new Promise((resolve, reject) => {
      capturedSignal = request.signal;
      request.signal.addEventListener('abort', () => reject(new HunyuanError('ABORTED')), { once: true });
    }),
  });
  t.after(() => worker.shutdown());
  worker.handle({ cmd: 'recognize', session: 'live', pcm: Buffer.from([1, 2]).toString('base64') });
  await waitFor(() => capturedSignal !== undefined);
  worker.handle({ cmd: 'exit' });
  assert.equal(capturedSignal.aborted, true);
  assert.equal(worker.active, null);
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(events.some(event => event.event === 'finished' || event.event === 'error'), false);
});

test('command validation and ping emit bounded safe errors', t => {
  const events = [];
  const worker = new HunyuanWorker({
    emit: event => events.push(event),
    env: { HUNYUAN_API_KEY: 'test-secret' },
    requestImpl: async () => ({ statusCode: 200, body: JSON.stringify(SUCCESS_PAYLOAD) }),
  });
  t.after(() => worker.shutdown());
  worker.handle(null);
  worker.handle({ cmd: 'ping', session: '' });
  worker.handle({ cmd: 'ping', session: 'ok' });
  worker.handle({ cmd: 'bogus', session: 'ok' });
  worker.handle({ cmd: 'recognize', session: 'ok', pcm: 'not base64!' });
  worker.handle({ cmd: 'recognize', session: 'ok', pcm: Buffer.from([1, 2]).toString('base64'), timeoutMs: 999 });
  worker.handle({ cmd: 'recognize', session: 'ok', pcm: Buffer.from([1, 2]).toString('base64'), timeoutMs: 600001 });
  assert.deepEqual(events.map(event => event.event), ['error', 'error', 'pong', 'error', 'error', 'error', 'error']);
  assert.deepEqual(events.filter(event => event.event === 'error').map(event => event.code), [
    'INVALID_COMMAND', 'INVALID_SESSION', 'INVALID_COMMAND', 'INVALID_AUDIO', 'INVALID_OPTIONS', 'INVALID_OPTIONS',
  ]);
  assert.equal(events[0].session, null);
  assert.equal(events[1].session, null);
  assert.equal(events[2].session, 'ok');
  for (const event of events.filter(item => item.event === 'error')) {
    assert.equal(event.httpStatus, null);
    assert.equal(typeof event.error, 'string');
    assert.equal(event.error.includes('test-secret'), false);
  }
});

test('recognize accepts a wav file path for connectivity tests', async t => {
  const root = tempDir(t);
  const file = path.join(root, 'sample.wav');
  const wavBytes = Buffer.from('RIFFxxxxWAVEfmt data-connectivity-only', 'utf8');
  fs.writeFileSync(file, wavBytes);
  let seenRequest;
  const events = [];
  const worker = new HunyuanWorker({
    emit: event => events.push(event),
    env: { HUNYUAN_API_KEY: 'test-secret' },
    requestImpl: async request => {
      seenRequest = request;
      return { statusCode: 200, body: JSON.stringify(SUCCESS_PAYLOAD) };
    },
  });
  t.after(() => worker.shutdown());
  worker.handle({ cmd: 'recognize', session: 'wav', wav: file });
  await waitFor(() => events.some(event => event.event === 'finished'));
  assert.equal(events.at(-1).session, 'wav');
  assert.equal(JSON.parse(seenRequest.body).data, wavBytes.toString('base64'));
  const missing = new HunyuanWorker({
    emit: event => events.push(event),
    env: { HUNYUAN_API_KEY: 'test-secret' },
    requestImpl: async () => ({ statusCode: 200, body: JSON.stringify(SUCCESS_PAYLOAD) }),
  });
  t.after(() => missing.shutdown());
  missing.handle({ cmd: 'recognize', session: 'missing', wav: path.join(root, 'absent.wav') });
  assert.equal(events.at(-1).event, 'error');
  assert.equal(events.at(-1).code, 'INVALID_AUDIO');
});
