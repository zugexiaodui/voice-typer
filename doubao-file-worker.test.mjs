// worker_doubao_file.mjs 的本地测试：不开真实网络，用 mock fetch / 本地 HTTP 服务。
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { FileRecognitionWorker } from './worker_doubao_file.mjs';

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'vt-doubao-file-'));
test.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));
const wavPath = path.join(tmpDir, 'sample.wav');
const wavBytes = Buffer.alloc(4800, 7);
fs.writeFileSync(wavPath, wavBytes);

const reply = (code, message = 'OK', body = '{}', status = 200) => ({
  status,
  headers: new Headers({ 'x-api-status-code': code, 'x-api-message': message }),
  text: async () => body,
});

function makeWorker({ submit, queries, env = {}, timeoutMs = 120000 } = {}) {
  let clock = 0;
  const calls = [];
  const queue = [...(queries || [])];
  const fetchImpl = async (url, opts) => {
    calls.push({ url, headers: opts.headers, body: opts.body });
    if (String(url).endsWith('/submit')) return submit;
    const next = queue.length > 1 ? queue.shift() : queue[0];
    return next;
  };
  const worker = new FileRecognitionWorker({
    env: { VT_DOUBAO_API_KEY: 'test-key', VT_DOUBAO_FILE_TIMEOUT_MS: String(timeoutMs), ...env },
    fetchImpl,
    sleep: async ms => { clock += ms; },
    now: () => clock,
  });
  return { worker, calls };
}

test('整段识别成功，返回带标点文本', async () => {
  const payload = JSON.stringify({ audio_info: { duration: 5592 }, result: { text: '开放时间早上9点至下午5点。' } });
  const { worker } = makeWorker({ submit: reply('20000000'), queries: [reply('20000000', 'OK', payload)] });
  const res = await worker.transcribe({ id: 7, wav: wavPath });
  assert.equal(res.ok, true);
  assert.equal(res.text, '开放时间早上9点至下午5点。');
  assert.equal(res.id, 7);
  assert.equal(res.durationMs, 5592);
});

test('result.text 缺失时回退到 utterances 拼接', async () => {
  const payload = JSON.stringify({ result: { utterances: [{ text: '第一句。' }, { text: '第二句。' }] } });
  const { worker } = makeWorker({ submit: reply('20000000'), queries: [reply('20000000', 'OK', payload)] });
  const res = await worker.transcribe({ id: 1, wav: wavPath });
  assert.equal(res.ok, true);
  assert.equal(res.text, '第一句。第二句。');
});

test('处理中状态会继续轮询', async () => {
  const payload = JSON.stringify({ result: { text: '好了。' } });
  const { worker, calls } = makeWorker({
    submit: reply('20000000'),
    queries: [reply('20000001', 'processing'), reply('20000002', 'processing'), reply('20000000', 'OK', payload)],
  });
  const res = await worker.transcribe({ id: 2, wav: wavPath });
  assert.equal(res.ok, true);
  assert.equal(res.text, '好了。');
  assert.equal(calls.filter(c => String(c.url).endsWith('/query')).length, 3);
});

test('静音返回空文本而不是报错', async () => {
  const { worker } = makeWorker({ submit: reply('20000000'), queries: [reply('20000003', 'silence')] });
  const res = await worker.transcribe({ id: 3, wav: wavPath });
  assert.equal(res.ok, true);
  assert.equal(res.text, '');
});

test('资源未开通时给出可读错误，并带上资源名', async () => {
  const { worker } = makeWorker({
    submit: reply('45000030', '[resource_id=volc.seedasr.auc] requested resource not granted', '{}', 403),
  });
  const res = await worker.transcribe({ id: 4, wav: wavPath });
  assert.equal(res.ok, false);
  assert.match(res.error, /403/);
});

test('服务端业务错误码会原样报告', async () => {
  const { worker } = makeWorker({ submit: reply('45000002', 'invalid audio') });
  const res = await worker.transcribe({ id: 5, wav: wavPath });
  assert.equal(res.ok, false);
  assert.match(res.error, /45000002/);
  assert.match(res.error, /invalid audio/);
});

test('一直处理中就按超时失败，不会无限等', async () => {
  const { worker } = makeWorker({
    submit: reply('20000000'),
    queries: [reply('20000001', 'processing')],
    timeoutMs: 10000,
  });
  const res = await worker.transcribe({ id: 6, wav: wavPath });
  assert.equal(res.ok, false);
  assert.match(res.error, /超时/);
});

test('提交与查询共用同一个请求号，且音频按 base64 发送', async () => {
  const payload = JSON.stringify({ result: { text: 'x' } });
  const { worker, calls } = makeWorker({ submit: reply('20000000'), queries: [reply('20000000', 'OK', payload)] });
  await worker.transcribe({ id: 8, wav: wavPath });
  const [submit, query] = calls;
  assert.equal(submit.headers['X-Api-Request-Id'], query.headers['X-Api-Request-Id']);
  assert.equal(submit.headers['X-Api-Resource-Id'], 'volc.seedasr.auc');
  assert.equal(submit.headers['X-Api-Sequence'], '-1');
  const body = JSON.parse(submit.body);
  assert.equal(body.audio.format, 'wav');
  assert.deepEqual(Buffer.from(body.audio.data, 'base64'), wavBytes);
  assert.equal(query.body, '{}');
});

test('缺少密钥/文件时提前失败', async () => {
  const workerNoKey = new FileRecognitionWorker({
    env: { VT_DOUBAO_KEYFILE: path.join(tmpDir, 'no-credentials.yaml') },
    fetchImpl: async () => reply('20000000'),
  });
  const res1 = await workerNoKey.transcribe({ id: 9, wav: wavPath });
  assert.equal(res1.ok, false);
  assert.match(res1.error, /密钥/);

  const worker = new FileRecognitionWorker({ env: { VT_DOUBAO_API_KEY: 'k' }, fetchImpl: async () => reply('20000000') });
  const res2 = await worker.transcribe({ id: 10, wav: path.join(tmpDir, 'missing.wav') });
  assert.equal(res2.ok, false);
  assert.match(res2.error, /找不到录音文件/);
});

test('进程协议：ready → transcribe → 结果，本地 HTTP 服务真实往返', async () => {
  const seen = [];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      seen.push({ url: req.url, headers: req.headers, body: raw });
      const isQuery = req.url.includes('/query');
      const payload = isQuery ? JSON.stringify({ result: { text: '协议测试通过。' } }) : '{}';
      res.writeHead(200, { 'content-type': 'application/json', 'x-api-status-code': '20000000', 'x-api-message': 'OK' });
      res.end(payload);
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  const child = spawn(process.execPath, [path.join(import.meta.dirname, 'worker_doubao_file.mjs')], {
    env: {
      ...process.env,
      VT_DOUBAO_API_KEY: 'local-key',
      VT_DOUBAO_FILE_SUBMIT_URL: `http://127.0.0.1:${port}/submit`,
      VT_DOUBAO_FILE_QUERY_URL: `http://127.0.0.1:${port}/query`,
    },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const lines = [];
  const rl = readline.createInterface({ input: child.stdout });
  const waitFor = predicate => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('等待 worker 输出超时')), 5000);
    const onLine = line => {
      lines.push(line);
      const parsed = JSON.parse(line);
      if (predicate(parsed)) { clearTimeout(timer); rl.off('line', onLine); resolve(parsed); }
    };
    rl.on('line', onLine);
  });

  try {
    await waitFor(msg => msg.ready === true);
    child.stdin.write(JSON.stringify({ cmd: 'transcribe', id: 42, wav: wavPath }) + '\n');
    const result = await waitFor(msg => msg.id === 42);
    assert.equal(result.ok, true);
    assert.equal(result.text, '协议测试通过。');
    assert.equal(seen.length, 2);
    assert.equal(seen[0].headers['x-api-request-id'], seen[1].headers['x-api-request-id']);
  } finally {
    rl.close();
    child.kill();
    server.close();
  }
});
