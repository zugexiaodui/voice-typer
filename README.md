# voice-typer

**Windows 全局语音输入** —— 在任意程序里按一下热键说话，本地识别成文字，自动粘贴到光标处。

音频**完全不出本机**（除非你主动开启可选的 AI 校验）。

```
按热键 → 说话 → 再按一下 → 文字出现在光标处
```

---

## 目录

- [功能](#功能)
- [环境要求](#环境要求)
- [安装](#安装)
- [使用](#使用)
- [设置说明](#设置说明)
- [命令行参数](#命令行参数)
- [目录结构](#目录结构)
- [工作原理](#工作原理)
- [常见问题](#常见问题)
- [第三方组件与许可](#第三方组件与许可)

---

## 功能

### 识别

两个**本地**引擎，设置里随时切换：

| 引擎 | 速度 | 语言 | 热词 | 适合 |
|---|---|---|---|---|
| `SenseVoiceSmall`（默认） | 快，RTF ≈ **0.034** | 中/英/日/韩/粤 | ✗ | 日常输入 |
| `Qwen3-ASR-0.6B` | 慢约 7 倍，RTF ≈ **0.25** | 52 种 + 22 种中文方言 | ✓ | 高精度 / 多语言 / 长文 |

- **Silero VAD** 自动断句；支持**流式上屏**，不等说完就先出字
- 16 kHz / 16-bit / 单声道采集（Windows MCI）
- 音频只在内存和临时文件里流转，不上传

### 交互

- **全局热键**：任意程序里都能用。默认 `Ctrl+Alt+Space`，可自定义；`Esc` 取消本次录音（只在录音期间占用）
- **悬浮按钮**：可拖动、可改大小、可换图标，按状态变色

| 状态 | 颜色 | 圆内标记 | 动效 |
|---|---|---|---|
| 待机 | 🔵 蓝 | 话筒 | — |
| 录音中 | 🔴 红 | 声波柱 | 外圈呼吸，2.2 秒一周期 |
| 识别中 | 🟠 橙 | 话筒 | — |
| **AI 校验中** | 🟣 **玫红** | **三个点** | **依次亮灭，1.4 秒一轮** |
| 上屏完成 | 🟢 绿 | 话筒 | 闪 420 ms |

- 逐像素透明（分层窗口 `UpdateLayeredWindow`），**无黑边、无锯齿**
- 托盘菜单：设置 / 显示隐藏悬浮按钮 / **后处理模型一键切换** / 退出

### 收尾 AI 校验（可选，默认关闭）

说完之后把识别结果送一次大模型做修正。**任何失败都原样返回 —— 绝不因为纠错失败而丢字。**

两套提示词模式：

| 模式 | 做什么 |
|---|---|
| **保守校对**（默认） | 只修同音字和口语填充词，几乎不动原文 |
| **AI 整理** | 通顺化、补标点、并句、整理语序；但保留原意、不许总结提炼 |

服务来源做成**预设**（见 [`correct-presets.json`](correct-presets.json)），在界面或托盘里选个名字就行：

- **DeepSeek 官方** —— 最快，实测约 1.1 秒
- **DeepSeek - ikuncode** —— 中转站，慢 4~5 倍
- **Aizex - GPT-4o / GPT-4o mini / GPT-4.1** —— 中转站，约 2~3 秒

也可以自己加：往 `correct-presets.json` 里复制一段改掉即可，不用改代码。

---

## 环境要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Windows | 10 / 11 | 依赖 Win32 API（`RegisterHotKey`、`UpdateLayeredWindow`、MCI） |
| PowerShell | **7.0+** | 需要 .NET Core 的 WinForms；Windows PowerShell 5.1 不支持 |
| Node.js | 18+ | 跑 SenseVoice 引擎和 AI 校验器 |
| Python | 3.10+ | **只有用 Qwen3 引擎才需要**，装在独立 venv 里 |

> 开发环境实测：Windows 11 26200 / PowerShell 7.6.6 / Node v24.13.0 / Python 3.12.14

---

## 安装

### 1. 获取代码

```powershell
git clone https://github.com/zugexiaodui/voice-typer.git
cd voice-typer
```

### 2. 安装 Node 依赖

```powershell
npm install
# 或 pnpm install
```

会装上 `sherpa-onnx-node`（含 Windows x64 的 `onnxruntime.dll`）。

### 3. 下载识别模型

#### SenseVoiceSmall（默认引擎，必装）

从 [sherpa-onnx 模型发布页](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)
下载 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2` 并解压。

程序按顺序在这些位置找 `model.int8.onnx`：

1. 环境变量 `VT_MODEL_DIR`
2. `%USERPROFILE%\.dsh\speech-to-text\sensevoice\models\sensevoice-onnx`
3. `%DSH_HOME%\speech-to-text\sensevoice\models\sensevoice-onnx`

目录里需要：

```
model.int8.onnx      ← 约 228 MB
tokens.txt
silero_vad.onnx      ← 放在同级或上级的 silero\ 目录里
```

#### Qwen3-ASR-0.6B（可选引擎）

从 [sherpa-onnx 模型发布页](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)
下载 `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2`，解压到工程的 `models\` 下：

```
models\sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25\
    encoder.int8.onnx
    decoder.int8.onnx
    conv_frontend.onnx
    tokenizer\
```

> 只能在 `models\` 下放一个 Qwen3 模型，程序会自动找 `encoder.int8.onnx`。
> 也可以把路径写进设置里的 `qwen3ModelDir`。

### 4. 建 Python 环境（仅 Qwen3 引擎需要）

```powershell
python -m venv .venv-qwen3
.\.venv-qwen3\Scripts\pip.exe install sherpa-onnx==1.13.8 numpy
```

不污染系统 Python，装在工程内的 `.venv-qwen3` 里。

### 5. 配置 API 密钥（仅 AI 校验需要）

校正器**不把密钥写进配置文件**，而是按名字去凭证文件里读。默认读：

```
%USERPROFILE%\.dsh\.credentials.yaml
```

格式（`refs:` 段下一行一个）：

```yaml
refs:
  DEEPSEEK_API_KEY: 你的密钥
  IKUNCODE_API_KEY: 你的密钥
  AIZEX_API_KEY:    你的密钥
```

密钥的查找顺序（`corrector.mjs`）：

1. 环境变量 `VT_CORRECT_API_KEY`（直接给值）
2. 环境变量 `<VT_CORRECT_KEY_NAME>`（默认 `DEEPSEEK_API_KEY`）
3. 凭证文件里名为 `<VT_CORRECT_KEY_NAME>` 的那一行

凭证文件路径可用 `VT_CORRECT_KEYFILE` 改。

### 6. 启动

```powershell
# 带控制台窗口（能看到日志，方便排查）
.\启动（带窗口）.bat

# 静默启动（无窗口，后台运行）
.\启动（静默）.vbs
```

启动后托盘会出现图标，悬浮按钮出现在桌面右下角。

> **建议**：给 `启动（带窗口）.bat` 建一个桌面快捷方式，以后双击即可。

---

## 使用

| 操作 | 怎么做 |
|---|---|
| 开始 / 结束录音 | 按热键（默认 `Ctrl+Alt+Space`），或点一下悬浮按钮 |
| 取消本次录音 | 录音期间按 `Esc` |
| **跳过 AI 校验** | AI 校验等待时按 `Esc` —— 不等了，直接用识别原文上屏 |
| 打开设置 | 左键点托盘图标，或右键 → 设置 |
| 快速切换后处理模型 | 右键托盘图标 → **后处理模型** |
| 拖动悬浮按钮 | 直接拖 |
| 退出 | 右键托盘图标 → 退出 |

说话时左下角会出现半透明悬浮提示，实时显示识别进度和结果。

---

## 设置说明

设置窗口改完点保存**立即生效，无需重启**。

| 分组 | 主要项 |
|---|---|
| 快捷键 | 录音快捷键、取消快捷键 |
| 识别 | 语言、CPU 线程数、空闲释放内存、**识别引擎**、Qwen3 热词 |
| 悬浮按钮 | 图标、大小、显示/隐藏 |
| **收尾 AI 校验** | 开关、**提示词模式**、**服务预设**、地址、接口格式、模型、密钥名、max tokens、超时、关思考参数、词表、填充词 |
| 其他 | 自动上屏、流式、悬浮提示、启动气泡 |

**「测试校验」按钮**会用当前界面上的参数真跑一次，直接告诉你耗时和结果 —— 不用真的说一段话。

### 环境变量速查

设置界面覆盖不到的进阶项：

| 变量 | 作用 |
|---|---|
| `VT_THREADS` | CPU 线程数 |
| `VT_IDLE_MS` | 空闲多久释放模型内存 |
| `VT_VAD_THRESHOLD` / `VT_VAD_MIN_SILENCE` / `VT_VAD_MAX_SPEECH` | VAD 参数 |
| `VT_WHOLE_MAX_SEC` | 整段识别的时长上限 |
| `VT_QWEN3_MODEL_DIR` / `VT_QWEN3_HOTWORDS` / `VT_QWEN3_MAX_TOTAL_LEN` | Qwen3 引擎 |
| `VT_CORRECT_MODEL` / `VT_CORRECT_TIMEOUT_MS` | 纠错模型与超时 |
| `VT_CORRECT_BASE_URL` / `VT_CORRECT_API_FORMAT` | 服务地址与接口格式 |
| `VT_CORRECT_KEY_NAME` / `VT_CORRECT_API_KEY` / `VT_CORRECT_KEYFILE` | 密钥来源 |
| `VT_CORRECT_MODE` | 提示词模式：`proofread` / `tidy` |
| `VT_CORRECT_THINK_PARAMS` | 关思考参数发不发：`deepseek` / `none` |
| `VT_CORRECT_MAX_TOKENS` / `VT_CORRECT_GLOSSARY` / `VT_CORRECT_FILLERS` | 输出上限、词表、填充词 |

---

## 命令行参数

```powershell
.\启动（带窗口）.bat [参数]
```

| 参数 | 作用 |
|---|---|
| `-ShowSettings` | 启动后直接打开设置窗口 |
| `-NoPaste` | 只显示识别结果，不自动粘贴 |
| `-Notify` | 强制弹一次启动气泡 |
| `-SettingsOnly` | 只开设置窗口，不注册热键 |
| `-Test` | 自检后退出 |
| `-HotkeyTest` | 只测热键，8 秒后退出 |
| `-StreamTest` | 用真实音频验证流式提交逻辑 |
| `-EngineTest` | 验证当前引擎（启动 + VAD + 识别） |
| `-CorrectTest` | 验证 AI 校验（**会真实调用 API**） |

---

## 目录结构

```
voice-typer/
├── 启动（带窗口）.bat        带控制台启动
├── 启动（静默）.vbs          后台启动
├── voice-typer.ps1          主程序：热键、录音、编排、上屏
├── config.ps1               配置读写 + 预设解析
├── gui.ps1                  设置窗口 + 托盘菜单
├── floating.ps1             悬浮按钮：分层窗口绘制 + 状态机
├── icons.ps1                SVG 图标路径 → 位图渲染
├── worker.mjs               SenseVoice 识别子进程（Node）
├── worker_qwen3.py          Qwen3-ASR 识别子进程（Python）
├── corrector.mjs            AI 校验子进程（Node）
├── textrules.mjs            纯文本规则：去填充词
├── correct-presets.json     AI 校验的服务预设
├── settings.json            用户设置
├── models/                  Qwen3 模型（自行下载，不入库）
├── .venv-qwen3/             Qwen3 的 Python 环境（自行创建，不入库）
├── node_modules/            Node 依赖
├── 识别调优说明.md           详细排查记录与踩坑笔记
└── 第三方资源说明.txt         第三方组件与许可
```

---

## 工作原理

```
                  ┌──────────────────────────────────────────┐
   热键/悬浮按钮 ─→│ voice-typer.ps1（主进程，Win32 消息循环） │
                  └────┬──────────────────────────────┬──────┘
                       │                              │
              ┌────────▼────────┐            ┌────────▼─────────┐
              │ 录音（winmm MCI）│            │ 悬浮按钮（分层窗口）│
              │ 16kHz/16bit/mono │            │ 5 种状态 + 动画    │
              └────────┬────────┘            └──────────────────┘
                       │ WAV
              ┌────────▼─────────────────┐
              │ 识别子进程（stdin/stdout  │
              │ JSON-lines 协议）         │
              │  • worker.mjs   SenseVoice│
              │  • worker_qwen3.py  Qwen3 │
              └────────┬─────────────────┘
                       │ 文字
              ┌────────▼─────────┐
              │ corrector.mjs    │ ← 可选，失败就原样返回
              │ 大模型纠错        │
              └────────┬─────────┘
                       │ 最终文字
              ┌────────▼─────────┐
              │ 剪贴板 + Ctrl+V   │
              │ 粘贴到原焦点窗口   │
              └──────────────────┘
```

几个设计选择：

- **子进程 + stdin/stdout 的 JSON-lines 协议** —— 模型崩了不会拖垮主进程；换引擎不用改主程序
- **密钥不经命令行传递** —— 由子进程自己去凭证文件读，避免出现在进程列表里
- **纠错永远不阻塞上屏** —— 超时/断网/无密钥/被护栏拦下，一律原样返回
- **配色集中在一张表**（`floating.ps1` 的 `$script:FloatPalette`）—— 换颜色、换标记只改数据

---

## 常见问题

<details>
<summary><b>说话没反应 / 热键没生效</b></summary>

热键可能被别的程序占了（`RegisterHotKey` 会返回「已被注册」）。启动时的气泡提示会告诉你。
打开设置换一个组合键即可。注意 `Esc` 只在录音期间才会被占用。
</details>

<details>
<summary><b>AI 校验"看起来没生效"</b></summary>

大概率是被护栏静默拦下了，或者超时了。用 `-CorrectTest` 看日志，或点设置里的「测试校验」。

最常见的两个原因：

1. **超时设太短** —— 中转站（ikuncode 之类）长句要 4~8 秒，沿用官方的 6000 ms 会导致**长句永远超时**，而短句正常，很难发现。建议 20000。
2. **max tokens 太小** —— 有些中转站的 DeepSeek 关不掉思考模式，会先烧几百个思维 token 才吐正文。`max_tokens` 小于 1024 时正文可能是空的。建议 2048。
</details>

<details>
<summary><b>换成 GPT 模型后一直卡住到超时</b></summary>

`reasoning_effort` 和 `thinking` 是 **DeepSeek 专用**参数。发给 GPT 系列，中转站不会报错，而是**挂住不回**。

设置里把「关思考参数」改成 **「不发送」** 即可。预设里已经配好了，漏填时程序会按模型名自动判断（`deepseek` 开头才发）。
</details>

<details>
<summary><b>悬浮按钮不见了</b></summary>

右键托盘图标 → 「显示/隐藏悬浮按钮」。位置存在 `%TEMP%\voice-typer-floatpos.txt`，删掉会回到默认位置。
</details>

<details>
<summary><b>Qwen3 引擎报「找不到模型」</b></summary>

`models\` 下需要有 `encoder.int8.onnx`。或者用设置里的 `qwen3ModelDir` 指定绝对路径。
</details>

<details>
<summary><b>想更深入了解调优细节</b></summary>

见 [`识别调优说明.md`](识别调优说明.md) —— 里面有完整的排查记录：参数实测数据、踩过的坑、每处改动的动机。写着"为什么是现在这样"。
</details>

---

## 第三方组件与许可

| 组件 | 用途 | 许可 |
|---|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 识别运行时（Node 版 + Python 版，均 1.13.8） | Apache-2.0 |
| [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | 语音识别模型 | 见模型仓库 |
| [Qwen3-ASR-0.6B](https://github.com/QwenLM/Qwen3-ASR) | 语音识别模型（可选） | Apache-2.0 |
| [Silero VAD](https://github.com/snakers4/silero-vad) | 语音活动检测 | MIT |
| [Google Material Symbols](https://github.com/google/material-design-icons) | 默认话筒图标 | Apache-2.0 |
| [Tabler Icons](https://github.com/tabler/tabler-icons) | 可选图标 | MIT |
| [Phosphor Icons](https://github.com/phosphor-icons/core) | 可选图标 | MIT |

图标以 SVG 路径数据形式内嵌在 [`icons.ps1`](icons.ps1)，由 WPF 的 `Geometry.Parse` 解析后光栅化。

AI 校验为**可选功能**，只在你开启时调用，且**只发送识别后的文字，不上传音频**。
第三方中转服务的数据处理方式由其自身决定，与本程序无关。

---

## 已知限制

- **仅 Windows** —— 深度依赖 Win32 API，没有跨平台计划
- 识别模型都在 CPU 上跑。4 线程下 SenseVoice 实时率约 0.034（1 秒音频约 34 ms），Qwen3 约 0.25
- Qwen3 引擎整段识别上限约 70 秒（受模型上下文限制）
- AI 校验模式下有一处固有取舍：护栏阈值放宽后，模型改错东西更不容易被发现
