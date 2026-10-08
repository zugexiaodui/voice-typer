#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
worker_qwen3.py — Qwen3-ASR 常驻识别进程

与 worker.mjs 使用完全相同的 JSON 行协议，主控 PowerShell 无需区分引擎：
  请求  {"id":1,"wav":"C:\\...\\rec.wav","lang":"auto","vad":true}
  应答  {"id":1,"ok":true,"text":"...","ms":123,"dur":4.5,
         "segments":[{"t":"...","dur":4.4}]}
        {"id":1,"ok":false,"error":"原因"}
  控制  {"cmd":"ping","id":2} / {"cmd":"exit"}

设计要点：
  * 模型只加载一次（加载约 3.8 秒），之后每句转写约 1.7 秒（4 线程实测）
  * VAD 用 Silero，与 SenseVoice 路径同一套模型，保证切句行为一致
  * 热词（hotwords）是本引擎独有能力，可直接提升专有名词准确率
  * 空闲超过 VT_IDLE_MS 自动退出，把约 1.5 GB 内存还给系统
"""
import sys
import os
import io
import json
import time
import wave
import threading

import numpy as np
import sherpa_onnx

sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
sys.stderr.reconfigure(encoding='utf-8', line_buffering=True)


def log(msg):
    sys.stderr.write(f'[qwen3 {time.strftime("%H:%M:%S")}] {msg}\n')


# ─────────── 路径解析 ───────────
def first_existing(paths):
    for p in paths:
        if p and os.path.exists(p):
            return p
    return None


def find_model_under_models():
    """兜底：在脚本同级的 models/ 下找一个含 encoder.int8.onnx 的目录。

    和 config.ps1 里 Get-Qwen3ModelDir 的逻辑一致 —— 不写死版本号，
    这样模型换版本、目录改名都不用改代码，别人 clone 下来也能直接用。
    """
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'models')
    if not os.path.isdir(base):
        return None
    for name in sorted(os.listdir(base)):
        d = os.path.join(base, name)
        if os.path.isfile(os.path.join(d, 'encoder.int8.onnx')):
            return d
    return None


MODEL_DIR = first_existing([
    os.environ.get('VT_QWEN3_MODEL_DIR'),   # 主控一定会传，正常路径
    find_model_under_models(),              # 单独跑这个脚本时的兜底
])

if not MODEL_DIR:
    log('找不到 Qwen3-ASR 模型目录（可用 VT_QWEN3_MODEL_DIR 指定）')
    sys.exit(2)

CONV_FRONTEND = os.path.join(MODEL_DIR, 'conv_frontend.onnx')
ENCODER = os.path.join(MODEL_DIR, 'encoder.int8.onnx')
DECODER = os.path.join(MODEL_DIR, 'decoder.int8.onnx')
TOKENIZER = os.path.join(MODEL_DIR, 'tokenizer')

for f in (CONV_FRONTEND, ENCODER, DECODER, TOKENIZER):
    if not os.path.exists(f):
        log(f'缺少模型文件: {f}')
        sys.exit(2)

VAD_MODEL = first_existing([
    os.environ.get('VT_VAD_MODEL'),
    os.path.join(os.path.expanduser('~'), '.dsh', 'speech-to-text', 'sensevoice',
                 'models', 'silero', 'silero_vad.onnx'),
    os.path.join(MODEL_DIR, '..', 'silero', 'silero_vad.onnx'),
])

THREADS = int(os.environ.get('VT_THREADS', '4'))
IDLE_MS = int(os.environ.get('VT_IDLE_MS', '120000'))
HOTWORDS = (os.environ.get('VT_QWEN3_HOTWORDS', '') or '').strip()
# 热词用逗号分隔（sherpa-onnx 要求 ASCII 逗号）
HOTWORDS = ','.join(w.strip() for w in HOTWORDS.replace('、', ',').replace('，', ',').split(',') if w.strip())


# ─────────── 音频读取 ───────────
def read_wav(path):
    """读 WAV → float32 单声道 16kHz"""
    with wave.open(path, 'rb') as w:
        sr, ch, sw, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f'只支持 16bit PCM，实际 {sw * 8}bit')
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    dur = len(a) / sr
    if sr != 16000:
        tgt = int(len(a) * 16000 / sr)
        a = np.interp(np.linspace(0, len(a) - 1, tgt), np.arange(len(a)), a).astype(np.float32)
    return a, dur


# ─────────── 模型（懒加载 + 缓存） ───────────
_rec = None

# 【关键】max_total_len 是解码器的 KV 缓存长度，直接决定"一次能识别多长的音频"。
# 不显式指定时 sherpa-onnx 用默认值 512，这个值太小，长音频会被静默截断。
# 实测（qiqiu1.wav 51 秒，有标准答案）：
#     max_total_len=512  → 只输出 8 个字「language」（完全崩掉）
#     max_total_len=1024 → 231 字，正确
#     max_total_len=2048 → 231 字，正确，且能稳定处理约 70 秒
# 用用户真实录音逐步加长也能复现：512 在 46 秒处崩掉，2048 到 69 秒仍完整。
MAX_TOTAL_LEN = int(os.environ.get('VT_QWEN3_MAX_TOTAL_LEN', '2048'))
# 单次生成的最大 token 数。128 对短句够用，但长段会不够，给足余量。
MAX_NEW_TOKENS = int(os.environ.get('VT_QWEN3_MAX_NEW_TOKENS', '512'))


def recognizer():
    global _rec
    if _rec is not None:
        return _rec
    t0 = time.time()
    _rec = sherpa_onnx.OfflineRecognizer.from_qwen3_asr(
        conv_frontend=CONV_FRONTEND,
        encoder=ENCODER,
        decoder=DECODER,
        tokenizer=TOKENIZER,
        num_threads=THREADS,
        sample_rate=16000,
        feature_dim=128,
        decoding_method='greedy_search',
        provider='cpu',
        debug=False,
        hotwords=HOTWORDS,
        max_total_len=MAX_TOTAL_LEN,
        max_new_tokens=MAX_NEW_TOKENS,
        temperature=1e-6,
        top_p=0.8,
        seed=42,
    )
    log(f'模型加载完成 {time.time() - t0:.2f}s  线程={THREADS}  '
        f'上下文={MAX_TOTAL_LEN}  热词={len(HOTWORDS.split(",")) if HOTWORDS else 0} 个')
    return _rec


def decode(samples):
    rec = recognizer()
    st = rec.create_stream()
    st.accept_waveform(16000, samples)
    rec.decode_stream(st)
    return (st.result.text or '').strip()


# ─────────── 整段识别（默认路径，最准） ───────────
# Qwen3 是离线 LLM-ASR，上下文给得越完整越准。实测同一段 23 秒录音：
#     整段识别 → 87 字全对
#     VAD 切句 → 丢句首「我虽然」，只剩 84 字
# 所以默认走整段识别，不用 VAD；只有音频长到超出上下文时才切块。
WHOLE_MAX_SEC = float(os.environ.get('VT_WHOLE_MAX_SEC', '45'))


def trim_silence(samples):
    """剪掉首尾静音。只减少无用的上下文占用，不改变识别内容。"""
    win = 512
    frames = len(samples) // win
    if frames < 4:
        return samples
    e = np.array([np.abs(samples[i * win:(i + 1) * win]).mean() for i in range(frames)])
    thr = max(0.004, float(e.max()) * 0.08)
    voiced = np.where(e > thr)[0]
    if not len(voiced):
        return samples
    s0 = max(0, int(voiced[0]) * win - int(16000 * 0.2))
    s1 = min(len(samples), (int(voiced[-1]) + 1) * win + int(16000 * 0.2))
    return samples[s0:s1]


def whole_segments(samples):
    """整段识别。音频过长时按 VAD 切成大块再拼，避免超出上下文被截断。"""
    a = trim_silence(samples)
    dur = len(a) / 16000.0
    if dur <= WHOLE_MAX_SEC:
        t = decode(a)
        return [{'t': t, 'dur': dur, 'closed': True}] if t else []
    # 超长：切成不超过 WHOLE_MAX_SEC 的大块（块越大越准，所以不是切成小句）
    raw = vad_segments(a, min_sil=0.7, max_speech=WHOLE_MAX_SEC,
                       pre_roll=0.2, drop_short=False)
    if not raw:
        t = decode(a)
        return [{'t': t, 'dur': dur, 'closed': True}] if t else []
    return [{'t': t, 'dur': d, 'closed': True} for (t, d, _c) in raw]


# ─────────── VAD 切句 ───────────
# 注意：Python 版 sherpa_onnx 只提供底层 VadModel（逐窗口判断"是否有语音"），
# 没有 Node 版那样的自动切段封装。所以这里自己实现切段状态机。
# 切段规则与 Node 路径保持一致：静音超过 min_silence 就收一段，
# 单段超过 max_speech 强制收段，结尾未闭合的段也收（标记为未闭合）。
def vad_segments(samples, min_sil=None, max_speech=None, pre_roll=0.35, drop_short=True):
    """返回 [(text, 时长秒, 是否已闭合), ...]；无 VAD 模型时返回 None

    pre_roll  —— 语音起点之前保留的秒数。Silero 对"软起音"不敏感：句首轻声的
                  「我」往往检测不到，不补这一段就会把第一个字吞掉。实测
                  「我虽然觉得可以了」会变成「觉得可以了」——这就是用户说的"断字"。
    drop_short —— 丢掉极短的幻觉碎片（<0.8 秒且只有 1~2 个字）。这类碎片在
                  录音尾部很常见，会凭空多出一个「啊」之类的字。
    """
    if not VAD_MODEL:
        return None
    try:
        cfg = sherpa_onnx.VadModelConfig()
        cfg.silero_vad.model = VAD_MODEL
        cfg.silero_vad.threshold = float(os.environ.get('VT_VAD_THRESHOLD', '0.5'))
        cfg.silero_vad.min_silence_duration = float(
            min_sil if min_sil is not None else os.environ.get('VT_VAD_MIN_SILENCE', '0.45'))
        cfg.silero_vad.min_speech_duration = float(os.environ.get('VT_VAD_MIN_SPEECH', '0.25'))
        cfg.silero_vad.window_size = 512
        cfg.sample_rate = 16000

        vad = sherpa_onnx.VadModel.create(cfg)
        win = 512
        min_sil = cfg.silero_vad.min_silence_duration
        max_speech = float(max_speech if max_speech is not None
                           else os.environ.get('VT_VAD_MAX_SPEECH', '12'))

        # 关键：在音频尾部补一段静音，强制让最后一段闭合。
        # 否则若原始音频结尾没有足够静音（很常见，比如正好说完就停），
        # 最后一段永远是"未闭合"状态，主控会把它当作"还在说"而不提交，导致丢字。
        pad = np.zeros(int(16000 * (min_sil + 0.35)), dtype=np.float32)
        samples = np.concatenate([samples, pad])

        out = []
        cur = []            # 当前段的采样点列表
        sil_run = 0.0
        started = False
        preroll = []        # 语音开始前暂存的窗口，用于补回软起音
        preroll_need = max(1, int(pre_roll * 16000 / win))

        def close(segment, closed):
            if not segment:
                return
            arr = np.concatenate(segment)
            dur = len(arr) / 16000.0
            if dur < 0.15:
                return
            txt = decode(arr)
            if not txt:
                return
            # 极短且只有一两个字的碎片多半是幻觉，丢掉
            if drop_short and dur < 0.8 and len(txt) <= 2:
                return
            out.append((txt, dur, closed))

        for i in range(0, len(samples) - win + 1, win):
            chunk = samples[i:i + win]
            speech = bool(vad.is_speech(chunk))

            if speech:
                if not started and preroll:
                    cur.extend(preroll)    # 补回语音起点，防止吞掉句首
                preroll = []
                cur.append(chunk)
                sil_run = 0.0
                started = True
                # 单段过长 → 强制收段，避免无限累积
                if sum(len(c) for c in cur) / 16000.0 >= max_speech:
                    close(cur, True)
                    cur = []
                    started = False
            elif started:
                cur.append(chunk)          # 静音也留在段里，保住尾音
                sil_run += win / 16000.0
                if sil_run >= min_sil:
                    close(cur, True)
                    cur = []
                    started = False
                    sil_run = 0.0
            else:
                preroll.append(chunk)      # 还没开始说话，先存着
                if len(preroll) > preroll_need:
                    preroll.pop(0)

        if cur:
            close(cur, False)              # 尾部未闭合段
        return out
    except Exception as e:
        log(f'VAD 失败，回退整段识别: {e}')
        return None


# ─────────── 主循环 ───────────
_last_activity = time.time()


def idle_watchdog():
    while True:
        time.sleep(5)
        if (time.time() - _last_activity) * 1000 > IDLE_MS:
            log('空闲超时，退出')
            os._exit(0)


def main():
    global _last_activity
    log(f'模型目录 {MODEL_DIR}')
    log(f'VAD 模型 {VAD_MODEL or "(未找到，将整段识别)"}')

    # 预热：先加载模型，省掉第一次转写的等待
    try:
        recognizer()
    except Exception as e:
        log(f'预热失败: {e}')

    print(json.dumps({'ready': True, 'modelDir': MODEL_DIR, 'hotwords': len(HOTWORDS.split(",")) if HOTWORDS else 0},
                     ensure_ascii=False), flush=True)

    threading.Thread(target=idle_watchdog, daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        _last_activity = time.time()
        try:
            req = json.loads(line)
        except Exception:
            continue

        if req.get('cmd') == 'exit':
            log('收到退出指令')
            os._exit(0)
        if req.get('cmd') == 'ping':
            print(json.dumps({'id': req.get('id'), 'ok': True, 'pong': True}), flush=True)
            continue

        rid = req.get('id')
        try:
            wav = req.get('wav')
            if not wav or not os.path.exists(wav):
                raise ValueError(f'找不到音频文件: {wav}')
            samples, _ = read_wav(wav)
            dur = len(samples) / 16000.0
            if dur < 0.15:
                raise ValueError('录音太短')

            t0 = time.time()
            raw = None
            if req.get('vad'):
                # 流式专用：切成小段并带 closed 标记，供主控决定何时提交
                raw = vad_segments(samples)
            if raw is None:
                # 默认路径：整段识别。不用 VAD —— 切句会在句子中间断开并吞掉句首，
                # 整段识别上下文最完整，实测准确率明显更好。
                segs = whole_segments(samples)
            else:
                # text 返回**全部**段落（含末尾未闭合段），供收尾时做完整兜底；
                # closed 标记由主控用来决定"流式过程中是否可提交这一段"。
                # 不要把未闭合段从 text 里剔除 —— 那会让收尾结果丢失最后一句话。
                segs = [{'t': t, 'dur': d, 'closed': bool(c)} for (t, d, c) in raw]
            text = ''.join(s['t'] for s in segs)
            ms = int((time.time() - t0) * 1000)

            log(f'转写 {dur:.2f}s'
                f'{"(VAD %d段/%d闭合)" % (len(segs), sum(1 for s in segs if s["closed"])) if req.get("vad") else ""}'
                f' → {ms} ms')
            print(json.dumps({'id': rid, 'ok': True, 'text': text, 'ms': ms,
                              'dur': dur, 'segments': segs}, ensure_ascii=False), flush=True)
        except Exception as e:
            print(json.dumps({'id': rid, 'ok': False, 'error': str(e)}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
