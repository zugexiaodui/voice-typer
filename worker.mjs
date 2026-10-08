// worker.mjs — 常驻识别进程。模型只加载一次，之后按行接收请求。
// 协议（stdin/stdout 各一行一条 JSON，UTF-8）：
//   请求  {"id":1,"wav":"C:\\...\\rec.wav","lang":"auto"}
//   应答  {"id":1,"ok":true,"text":"识别结果"}
//         {"id":1,"ok":false,"error":"原因"}
// 空闲超过 VT_IDLE_MS（默认 90000）毫秒自动退出，把内存还给系统。
import sherpa from 'sherpa-onnx-node';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';

// 日志写到文件（若 VT_LOG 指定）或 stderr。写文件可避免 stderr 管道无人读取时被写满而卡死。
const logPath = process.env.VT_LOG;
let logStream = null;
if (logPath) { try { logStream = fs.createWriteStream(logPath, { flags: 'a' }); } catch { } }
const log = (m) => {
  const line = `[worker ${new Date().toISOString().slice(11, 23)}] ${m}\n`;
  if (logStream) { try { logStream.write(line); } catch { } }
  else { try { process.stderr.write(line); } catch { } }
};
process.stdout.on('error', () => { });
process.on('uncaughtException', (e) => { log(`异常: ${e.stack || e.message}`); });

// ---------- 定位模型 ----------
const cands = [
  process.env.VT_MODEL_DIR,
  path.join(os.homedir(), '.dsh', 'speech-to-text', 'sensevoice', 'models', 'sensevoice-onnx'),
  process.env.DSH_HOME ? path.join(process.env.DSH_HOME, 'speech-to-text', 'sensevoice', 'models', 'sensevoice-onnx') : null,
].filter(Boolean);
const modelDir = cands.find((d) => fs.existsSync(path.join(d, 'model.int8.onnx')));
if (!modelDir) { log(`找不到模型，已尝试: ${cands.join(' | ')}`); process.exit(2); }
const MODEL = path.join(modelDir, 'model.int8.onnx');
const TOKENS = path.join(modelDir, 'tokens.txt');
const THREADS = Number(process.env.VT_THREADS || 4);

// ---------- Silero VAD（用于按真实语音活动切分，比能量阈值可靠得多）----------
const VAD_CANDS = [
  process.env.VT_VAD_MODEL,
  path.join(os.homedir(), '.dsh', 'speech-to-text', 'sensevoice', 'models', 'silero', 'silero_vad.onnx'),
  path.join(modelDir, '..', 'silero', 'silero_vad.onnx'),
  path.join(modelDir, 'silero_vad.onnx'),
].filter(Boolean);
const VAD_MODEL = VAD_CANDS.find((p) => fs.existsSync(p));
if (VAD_MODEL) log(`VAD 模型: ${VAD_MODEL}`); else log('未找到 VAD 模型，段落切分将不可用');

// ---------- 读 WAV → Float32 16k 单声道 ----------
function readWav(p) {
  const b = fs.readFileSync(p);
  if (b.toString('ascii', 0, 4) !== 'RIFF' || b.toString('ascii', 8, 12) !== 'WAVE') throw new Error('不是合法 WAV');
  const ch = b.readUInt16LE(22), sr = b.readUInt32LE(24), bits = b.readUInt16LE(34);
  if (bits !== 16) throw new Error(`仅支持 16bit PCM，实际 ${bits}bit`);
  const off = b.indexOf(Buffer.from('data'), 12) + 8;
  const frames = Math.floor((b.length - off) / (2 * ch));
  const s = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    let acc = 0;
    for (let c = 0; c < ch; c++) acc += b.readInt16LE(off + i * 2 * ch + c * 2);
    s[i] = acc / ch / 32768;
  }
  let samples = s;
  if (sr !== 16000) {                       // 线性重采样兜底
    const r = sr / 16000, n = Math.floor(s.length / r), o = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const x = i * r, i0 = Math.floor(x), i1 = Math.min(i0 + 1, s.length - 1);
      o[i] = s[i0] + (s[i1] - s[i0]) * (x - i0);
    }
    samples = o;
  }
  return { samples, duration: frames / sr };
}

// ---------- VAD：把音频切成语音段，逐段识别，返回 {text, segments} ----------
// 用真正的语音活动检测（Silero）而不是能量阈值 —— 能量法区分不了"停顿"和"轻音节的语音"，
// 实测会把句子内部的轻声段误判成停顿，导致切段错位、内容错乱。
function transcribeWithVad(samples, lang) {
  if (!VAD_MODEL) throw new Error('缺少 Silero VAD 模型');
  const vad = new sherpa.Vad({
    sileroVad: {
      model: VAD_MODEL,
      threshold: Number(process.env.VT_VAD_THRESHOLD || 0.5),
      minSilenceDuration: Number(process.env.VT_VAD_MIN_SILENCE || 0.45),
      minSpeechDuration: Number(process.env.VT_VAD_MIN_SPEECH || 0.25),
      maxSpeechDuration: Number(process.env.VT_VAD_MAX_SPEECH || 15),
      windowSize: 512,
    },
    sampleRate: 16000,
  }, 60);                                  // 60 秒环形缓冲

  const r = recognizer(lang || 'auto');
  const parts = [];
  const segInfo = [];
  const WIN = 512;                         // VAD 要求的窗口大小
  for (let i = 0; i + WIN <= samples.length; i += WIN) {
    vad.acceptWaveform(samples.subarray(i, i + WIN));
    while (!vad.isEmpty()) {
      const seg = vad.front();
      const st = r.createStream();
      st.acceptWaveform({ sampleRate: 16000, samples: seg.samples });
      r.decode(st);
      const t = (r.getResult(st).text || '').trim();
      if (t) { parts.push(t); segInfo.push({ t, dur: seg.samples.length / 16000 }); }
      vad.pop();
    }
  }
  vad.flush();
  while (!vad.isEmpty()) {
    const seg = vad.front();
    const st = r.createStream();
    st.acceptWaveform({ sampleRate: 16000, samples: seg.samples });
    r.decode(st);
    const t = (r.getResult(st).text || '').trim();
    if (t) { parts.push(t); segInfo.push({ t, dur: seg.samples.length / 16000 }); }
    vad.pop();
  }
  return { text: parts.join(''), segments: segInfo };
}

// ---------- 按语言缓存识别器 ----------
const recs = new Map();
function recognizer(lang) {
  if (recs.has(lang)) return recs.get(lang);
  const mc = {
    senseVoice: { model: MODEL, tokens: TOKENS, useInverseTextNormalization: 1 },
    tokens: TOKENS, numThreads: THREADS, provider: 'cpu', debug: 0,
  };
  if (lang && lang !== 'auto') mc.senseVoice.language = lang;
  const t0 = Date.now();
  const r = new sherpa.OfflineRecognizer({ featConfig: { sampleRate: 16000, featureDim: 80 }, modelConfig: mc });
  log(`识别器(${lang}) 就绪，加载 ${Date.now() - t0} ms`);
  recs.set(lang, r);
  return r;
}

// ---------- 空闲看门狗 ----------
let last = Date.now();
const idleMs = Number(process.env.VT_IDLE_MS || 90000);
setInterval(() => {
  if (Date.now() - last > idleMs) { log('空闲超时，退出'); process.exit(0); }
}, 5000).unref();

// ---------- 预热：先加载默认语言，节省第一次转写的等待 ----------
try { recognizer(process.env.VT_PRELOAD_LANG || 'auto'); } catch (e) { log(`预热失败: ${e.message}`); }
process.stdout.write(JSON.stringify({ ready: true, modelDir }) + '\n');
log(`已就绪，模型: ${MODEL}`);

// ---------- 主循环 ----------
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  last = Date.now();
  let req;
  try { req = JSON.parse(s); } catch { return; }
  try {
    if (req.cmd === 'ping') { process.stdout.write(JSON.stringify({ id: req.id, ok: true, pong: true }) + '\n'); return; }
    if (req.cmd === 'exit') { process.exit(0); }
    const a = readWav(req.wav);
    if (a.duration < 0.15) throw new Error('录音太短');
    const t0 = Date.now();
    let text, segInfo = null;
    if (req.vad) {
      const out = transcribeWithVad(a.samples, req.lang || 'auto');
      text = out.text;
      segInfo = out.segments;
    } else {
      const r = recognizer(req.lang || 'auto');
      const st = r.createStream();
      st.acceptWaveform({ sampleRate: 16000, samples: a.samples });
      r.decode(st);
      text = (r.getResult(st).text || '').trim();
    }
    const ms = Date.now() - t0;
    log(`转写 ${a.duration.toFixed(2)}s${req.vad ? ` (VAD ${segInfo.length}段)` : ''} → ${ms} ms`);
    process.stdout.write(JSON.stringify({
      id: req.id, ok: true, text, ms, dur: a.duration, segments: segInfo,
    }) + '\n');
  } catch (e) {
    process.stdout.write(JSON.stringify({ id: req.id, ok: false, error: e.message }) + '\n');
  }
});
rl.on('close', () => process.exit(0));
