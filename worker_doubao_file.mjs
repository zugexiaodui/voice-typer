// Persistent JSONL worker for 豆包录音文件识别（AUC bigmodel submit + query）。
// 与流式 worker 分开：这里把整段 WAV 以 base64 提交，等任务完成一次性返回文本。
// stdout 只走协议；密钥与服务端原文不会回显。
//
// 命令：{"cmd":"transcribe","id":N,"wav":"C:\\...\\rec.wav"} / {"cmd":"exit"}
// 应答：{"id":N,"ok":true,"text":"…"} 或 {"id":N,"ok":false,"error":"…"}
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { resolveCredential } from './worker_doubao.mjs';

export const SUBMIT_URL = 'https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit';
export const QUERY_URL = 'https://openspeech.bytedance.com/api/v3/auc/bigmodel/query';
export const DEFAULT_RESOURCE_ID = 'volc.seedasr.auc';
export const DEFAULT_TIMEOUT_MS = 120000;

// 文档上限 512 MB；base64 会把内存再放大一倍，这里按单次听写的实际需要收紧。
const MAX_WAV_BYTES = 120 * 1024 * 1024;
const MAX_LINE_BYTES = 1024 * 1024;
const STATUS_OK = '20000000';
const STATUS_SILENCE = '20000003';
const PROCESSING = new Set(['20000001', '20000002']);

const statusCode = res => String(res?.headers?.get?.('x-api-status-code') ?? '');
const statusMessage = res => String(res?.headers?.get?.('x-api-message') ?? '');

// 把服务端状态码翻成能直接给用户看的原因；未知码保留服务端原话。
function describeFailure(code, message, resource) {
  if (code === '45000030') return `豆包未开通该模型资源（${resource}），请在控制台开通后再试`;
  if (code === '45000010' || code === '45000001') return `豆包拒绝了请求（${code}）：${message || '参数或权限有误'}`;
  if (code === '403') return `豆包鉴权失败（HTTP 403）${message ? '：' + message : ''}`;
  return `豆包识别失败（${code || '无状态码'}）${message ? '：' + message : ''}`;
}

function extractText(payload) {
  const result = payload?.result || {};
  const direct = typeof result.text === 'string' ? result.text.trim() : '';
  if (direct) return direct;
  const utterances = Array.isArray(result.utterances) ? result.utterances : [];
  return utterances.map(u => String(u?.text ?? '')).join('').trim();
}

export class FileRecognitionWorker {
  constructor({
    emit = () => {},
    env = process.env,
    fetchImpl = globalThis.fetch,
    submitUrl = env.VT_DOUBAO_FILE_SUBMIT_URL || SUBMIT_URL,
    queryUrl = env.VT_DOUBAO_FILE_QUERY_URL || QUERY_URL,
    sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
    now = () => Date.now(),
  } = {}) {
    this.emit = emit;
    this.env = env;
    this.fetchImpl = fetchImpl;
    this.submitUrl = submitUrl;
    this.queryUrl = queryUrl;
    this.sleep = sleep;
    this.now = now;
  }

  timeoutMs() {
    const raw = Number(this.env.VT_DOUBAO_FILE_TIMEOUT_MS);
    if (!Number.isFinite(raw)) return DEFAULT_TIMEOUT_MS;
    return Math.min(30 * 60 * 1000, Math.max(10000, Math.round(raw)));
  }

  resourceId() {
    const raw = String(this.env.VT_DOUBAO_FILE_RESOURCE || '').trim();
    return raw || DEFAULT_RESOURCE_ID;
  }

  async transcribe({ id, wav } = {}) {
    const started = Date.now();
    const done = (extra) => ({ id, ms: Date.now() - started, ...extra });
    const fail = error => done({ ok: false, error });

    let stat;
    try { stat = fs.statSync(String(wav || '')); } catch { return fail('找不到录音文件'); }
    if (!stat.isFile() || stat.size <= 0) return fail('录音文件为空');
    if (stat.size > MAX_WAV_BYTES) return fail(`录音文件过大（${(stat.size / 1048576).toFixed(1)} MB，上限 120 MB）`);

    const keyName = this.env.VT_DOUBAO_KEY_NAME || 'DOUBAO_API_KEY';
    const key = resolveCredential(this.env, keyName);
    if (!key) return fail(`豆包密钥未配置（引用名 ${keyName}）`);

    const resource = this.resourceId();
    const timeoutMs = this.timeoutMs();
    const deadline = this.now() + timeoutMs;
    const requestId = randomUUID();
    const headers = {
      'Content-Type': 'application/json',
      'X-Api-Key': key,
      'X-Api-Resource-Id': resource,
      'X-Api-Request-Id': requestId,
      'X-Api-Sequence': '-1',
    };

    let audio;
    try { audio = fs.readFileSync(String(wav)).toString('base64'); }
    catch (e) { return fail('读取录音文件失败'); }

    const body = JSON.stringify({
      user: { uid: 'voice-typer' },
      audio: { format: 'wav', data: audio },
      request: { model_name: 'bigmodel', enable_itn: true, show_utterances: true, enable_punc: true },
    });

    let submitted;
    try {
      submitted = await this.fetchImpl(this.submitUrl, {
        method: 'POST', headers, body,
        signal: AbortSignal.timeout(Math.min(60000, timeoutMs)),
      });
    } catch {
      return fail('无法连接豆包服务，请检查网络');
    }
    if (submitted.status !== 200) {
      return fail(describeFailure(String(submitted.status), statusMessage(submitted), resource));
    }
    const submitCode = statusCode(submitted);
    if (submitCode !== STATUS_OK) {
      return fail(describeFailure(submitCode, statusMessage(submitted), resource));
    }

    // 提交后轮询。短音频通常 1~3 秒完成，间隔从 400ms 逐步放宽，减少空转。
    let delay = 400;
    while (this.now() < deadline) {
      await this.sleep(delay);
      delay = Math.min(1500, Math.round(delay * 1.35));
      if (this.now() >= deadline) break;

      let res;
      try {
        res = await this.fetchImpl(this.queryUrl, {
          method: 'POST', headers, body: '{}',
          signal: AbortSignal.timeout(Math.min(20000, Math.max(1000, deadline - this.now()))),
        });
      } catch {
        continue; // 单次查询抖动不上报，交给总超时兜底
      }
      if (res.status !== 200) {
        return fail(describeFailure(String(res.status), statusMessage(res), resource));
      }
      const code = statusCode(res);
      const message = statusMessage(res);
      if (PROCESSING.has(code)) continue;
      if (code === STATUS_SILENCE) return done({ ok: true, text: '' });
      if (code !== STATUS_OK) return fail(describeFailure(code, message, resource));

      let payload = {};
      try { payload = JSON.parse(await res.text()); } catch { return fail('豆包返回了无法解析的结果'); }
      const durationMs = Number(payload?.audio_info?.duration) || null;
      return done({ ok: true, text: extractText(payload), durationMs });
    }
    return fail(`等待豆包结果超时（${Math.round(timeoutMs / 1000)} 秒）`);
  }
}

export function runWorker(input = process.stdin, output = process.stdout, env = process.env) {
  const worker = new FileRecognitionWorker({ env, emit: msg => output.write(JSON.stringify(msg) + '\n') });
  let chain = Promise.resolve();
  let exited = false;

  const respond = msg => { try { output.write(JSON.stringify(msg) + '\n'); } catch { } };

  function stop() {
    if (exited) return;
    exited = true;
    try { input.removeAllListeners?.('data'); } catch { }
    process.exit(0);
  }

  const consume = line => {
    const text = line.trim();
    if (!text) return;
    if (Buffer.byteLength(text) > MAX_LINE_BYTES) return;
    let cmd;
    try { cmd = JSON.parse(text); } catch { return respond({ id: null, ok: false, error: '无法解析的命令' }); }
    if (cmd?.cmd === 'exit') return stop();
    // 两种写法都认：主程序通用链路发的是 {id,wav,lang}（没有 cmd 字段），
    // 带 cmd 的写法便于手工调试。别再让协议分叉出第三套。
    const isTranscribe = cmd?.cmd === 'transcribe' || (cmd?.cmd === undefined && typeof cmd?.wav === 'string');
    if (!isTranscribe) return respond({ id: cmd?.id ?? null, ok: false, error: '未知命令' });
    chain = chain.then(async () => {
      const result = await worker.transcribe({ id: cmd.id, wav: cmd.wav });
      respond(result);
    }).catch(() => respond({ id: cmd.id ?? null, ok: false, error: '识别进程内部错误' }));
  };

  let pending = '';
  input.on('data', chunk => {
    pending += chunk.toString('utf8');
    let newline;
    while ((newline = pending.indexOf('\n')) >= 0) {
      consume(pending.slice(0, newline));
      pending = pending.slice(newline + 1);
    }
    // 没有换行的超长行只可能是坏数据：丢弃，避免把内存拖爆。
    if (pending.length > MAX_LINE_BYTES) pending = '';
  });
  // stdin 关闭（应用退出/管道断开）时不要立刻杀掉进程：正在进行的识别可能已经提交给云端，
  // 让它把结果写完再退，否则结果丢失、日志里只剩一条 ready。
  input.on('end', () => {
    if (pending.trim()) consume(pending);
    Promise.resolve(chain).then(stop, stop);
  });
  output.write(JSON.stringify({ ready: true }) + '\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) runWorker();
