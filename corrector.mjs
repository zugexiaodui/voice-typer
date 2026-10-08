// corrector.mjs — 用 deepseek-flash（非推理模式）对语音识别结果做保守纠错
//
// 调用方式（由 voice-typer.ps1 通过临时文件传入，避免密钥/文本进日志）：
//   node corrector.mjs <输入文件> <输出文件>
//   环境变量：VT_CORRECT_MODEL / VT_CORRECT_TIMEOUT_MS / VT_CORRECT_GLOSSARY /
//             VT_CORRECT_KEYFILE / DEEPSEEK_API_KEY
//
// 设计原则：
//   * 只在"这次语音结束之后"跑一次，不参与流式过程
//   * 任何失败都原样返回输入（绝不因为纠错失败而丢字）
//   * 保守优先：宁可漏改，不可改错。实测模型会把正确的「开饭时间」改成「开放时间」，
//     所以提示词必须反复强调"不确定就保持原样"。

import fs from 'node:fs';
import { stripFillers } from './textrules.mjs';

const inFile = process.argv[2];
const outFile = process.argv[3];
if (!inFile || !outFile) { process.stderr.write('用法: corrector.mjs <输入文件> <输出文件>\n'); process.exit(2); }

// 用"抛哨兵"代替 process.exit(0)：请求失败时 undici 的常驻连接还活着，
// 此刻直接 process.exit() 会在 Windows 上触发 libuv 断言
//    Assertion failed: !(handle->flags & UV_HANDLE_CLOSING), file src\win\async.c, line 76
// 日志里看着像崩溃。抛到文件末尾统一接住，让进程自然退出即可。
const VT_DONE = Symbol('vt-done');

function passthrough(reason) {
  try {
    const t = fs.readFileSync(inFile, 'utf8');
    fs.writeFileSync(outFile, t, 'utf8');
    process.stderr.write(`[corrector] 原样返回（${reason}）\n`);
  } catch (e) {
    process.stderr.write(`[corrector] 回退失败: ${e.message}\n`);
  }
  throw VT_DONE;
}

try {

// ── 接口配置：默认官方 DeepSeek，可用环境变量切到其他兼容来源 ──
//   VT_CORRECT_BASE_URL   例如 https://api.ikuncode.ai，或直接给完整端点 URL
//   VT_CORRECT_API_FORMAT openai（默认）| anthropic
//   VT_CORRECT_KEY_NAME   从凭证文件里读哪个密钥，默认 DEEPSEEK_API_KEY
//   VT_CORRECT_API_KEY    直接给密钥（优先级最高）
const API_FORMAT = (process.env.VT_CORRECT_API_FORMAT || 'openai').trim().toLowerCase();
const KEY_NAME   = (process.env.VT_CORRECT_KEY_NAME   || 'DEEPSEEK_API_KEY').trim();

// 允许只给到域名，由这里补路径
function endpointUrl() {
  const raw = (process.env.VT_CORRECT_BASE_URL || '').trim();
  if (!raw) return 'https://api.deepseek.com/chat/completions';
  const u = raw.replace(/\/+$/, '');
  const anthropic = API_FORMAT === 'anthropic';
  if (/\/(chat\/completions|messages)$/.test(u)) return u;        // 已经是完整端点
  if (/\/v1$/.test(u)) return u + (anthropic ? '/messages' : '/chat/completions');
  return u + (anthropic ? '/v1/messages' : '/v1/chat/completions');
}
const ENDPOINT = endpointUrl();

// ── 取 API Key：直接给 > 同名环境变量 > DSH 凭证文件 ──
function resolveKey() {
  if (process.env.VT_CORRECT_API_KEY) return process.env.VT_CORRECT_API_KEY.trim();
  if (process.env[KEY_NAME]) return process.env[KEY_NAME].trim();
  const f = process.env.VT_CORRECT_KEYFILE || 'C:\\Users\\luyue\\.dsh\\.credentials.yaml';
  try {
    const raw = fs.readFileSync(f, 'utf8');
    const m = raw.match(new RegExp('^\\s*' + KEY_NAME + '\\s*:\\s*(\\S+)', 'm'));
    if (m) return m[1].trim();
  } catch { }
  return null;
}

const KEY = resolveKey();
if (!KEY) passthrough(`未找到密钥（${KEY_NAME}）`);

const MODEL = process.env.VT_CORRECT_MODEL || 'deepseek-flash';
const TIMEOUT = Number(process.env.VT_CORRECT_TIMEOUT_MS || 6000);

// ── 关思考的参数要不要发 ──
//   deepseek（默认）：发 reasoning_effort:"none" + thinking:{type:"disabled"}
//   none            ：一个都不发
// reasoning_effort / thinking 是 DeepSeek 系专用的，发给 GPT 这类模型会出事：
// 实测 aizex 上带这两个参数打 gpt-4o / gpt-4o-mini 是**直接挂住到超时**
// （日志里什么都没有，最难查），打 gpt-4.1 返回 403。去掉就一切正常。
// 所以做成可配置，默认保持 deepseek 行为不变。
const THINK_PARAMS = (process.env.VT_CORRECT_THINK_PARAMS || 'deepseek').trim().toLowerCase();
const USE_DS_THINK = THINK_PARAMS !== 'none';

let input = '';
try { input = fs.readFileSync(inFile, 'utf8').trim(); } catch (e) { passthrough(`读不到输入: ${e.message}`); }
if (!input) passthrough('输入为空');
// 太短的片段不值得纠错，还可能被模型"发挥"
if (input.length < 4) passthrough('文本太短');

// ── 提示词模式 ──
//   proofread（默认）：保守校对。只修同音字和填充词，护栏严格限制改动率。
//   tidy             ：AI 整理。允许通顺化/补标点/并句/整理语序，但不许改变原意，
//                      护栏介于两者之间（见下面 LIMITS）。
// instruct 是第一版激进模式的取值，现在统一走 tidy —— 留作兼容，老配置不会报错。
const PROMPT_MODE = (process.env.VT_CORRECT_MODE || 'proofread').trim().toLowerCase();
const TIDY = PROMPT_MODE === 'tidy' || PROMPT_MODE === 'instruct';
const MODE_LABEL = TIDY ? 'tidy' : 'proofread';

// ── 提示词（保守校对版）──
// 固定前缀（含规则和词表）能命中 DeepSeek 的上下文缓存，把输入成本降到 1/50
//
// 设计要点（踩过坑，改之前先读）：
//   * 第一版把重点全放在"宁可漏改不可改错"上，结果模型几乎什么都不改。
//     原因是 ASR 同音字错误产生的往往也是正常词（「派饭」「炫富」都是真词），
//     而"原文通顺就一字不动"这条规则恰好把这类错误全部放行了。
//   * 所以必须把"词表近音替换"单独提为【任务一】，并明确它优先于"保持原样"。
//   * "拿不准就保持原样"只用于【任务二】，否则会压制【任务一】。
const GLOSSARY = (process.env.VT_CORRECT_GLOSSARY || '').trim();
const PROOFREAD_SYSTEM = [
  '你是中文语音识别（ASR）结果的校对器。你的输入是一段语音识别文字，其中可能夹带同音字错误。',
  '',
  '你必须按顺序完成两个任务。',
  '',
  '═══ 任务一：词表近音替换（最高优先级，必须认真做）═══',
  GLOSSARY
    ? [
        '用户常用词表：',
        GLOSSARY,
        '',
        '请逐个检查词表中的每个词，在原文中寻找它的**同音或近音的误写**（声母/韵母相近、声调不同的都算）。',
        '只要发现，就必须替换成词表里的正确写法 —— **即使误写的那个词本身也是个正常的中文词，也必须替换**，',
        '因为语音识别错误产生的结果经常恰好是另一个真词。',
        '',
        '这类情况**不受"保持原样"规则保护**，是最需要修正的目标。',
        '判断标准是"读音像不像"，不是"原文读起来通不通顺"。',
        '',
        '示例：',
        '  「派饭时间」→「开饭时间」：pài fàn ≈ kāi fàn，「派饭」虽是正常词，仍须替换',
        '  「炫富按钮」→「悬浮按钮」：xuàn fù ≈ xuán fú，须替换',
        '  「烫烫」→「Tab」：近音，须替换',
      ].join('\n')
    : '（本次未提供词表，跳过任务一。）',
  '',
  '═══ 任务二：其他明显识别错误（保守处理）═══',
  '只修正这两类：',
  '  a) 明显的同音字错误（如「deep sick」→「DeepSeek」）',
  '  b) 明显的标点缺失或多出一个明显的乱字',
  '',
  '═══ 任务三：删掉口语填充词 ═══',
  '删掉独立出现的「嗯」「呃」「额」「唉」「哎」这类无意义的语气词和口头禅，',
  '包括重复的（如「嗯嗯嗯」「呃…呃」）。',
  '',
  '但**只删这些**：',
  '  ✓「嗯，我今天想去公园」→「我今天想去公园」',
  '  ✓「那个呃…帮我看一下」→「那个帮我看一下」（只删「呃」，不动「那个」）',
  '  ✗ 不能删「这本书真好啊」里的「啊」—— 这是语气助词，删了句子就坏了',
  '  ✗ 不能删「是啊」里的「啊」—— 这是应答',
  '  ✗ 不能删「那个」「就是」「然后」—— 它们在中文里是正常词，除非用户词表指定',
  '',
  '═══ 任务四：其他（禁止）═══',
  '除此之外一律保持原样。禁止：改写、润色、调整语序、增删实词、把口语改成书面语、同义词替换。',
  '  ✗「帮我看看」→「请帮我查看」（润色，禁止）',
  '  ✗「至下午5点」→「到下午5点」（同义替换，禁止）',
  '  ✗「开饭时间」→「开放时间」（无故改动，禁止）',
  '在任务二/三里拿不准就保持原样。但这条**不适用于任务一**（词表近音替换必须做）。',
  '',
  '═══ 输出要求 ═══',
  '只输出校对后的完整文本本身。不要解释、不要引号、不要前缀、不要 markdown、不要分行。',
  '如果什么都没改，就把原文原样输出。',
].filter((s) => s !== '').join('\n');

// ── 提示词（AI 整理版）──
// 定位：介于"保守校对"和"改写"之间 —— 允许通顺化、补标点、合并断句、整理明显混乱的语序，
// 但**不许改变用户原意**，也不许总结提炼。
// 上一版（允许提炼成任务）用户反馈"太激进"，这版是回退后的版本，护栏阈值也相应收紧。
const TIDY_SYSTEM = `你是一个专业的语音转文字后处理助手。

你的任务是将自动语音识别（ASR）的结果整理成准确、自然、易读的文本，并让它适合作为 AI 对话输入。

注意：
你不是内容改写助手，也不是需求分析助手。
你的首要目标是保留用户原本表达的意思。

请遵守以下规则：

---

## 1. 保留原始意图

必须保留：

- 用户提出的问题
- 用户的需求
- 用户的限制条件
- 用户的语气和表达重点
- 用户提到的对象、数字、名称

不要把用户的话转换成另一种需求。

例如：

原文：
"我想了解一下怎么优化我的网站速度"

可以修改为：
"我想了解一下如何优化我的网站速度。"

不要修改为：
"请帮我制定网站性能优化方案。"

后者增加了用户没有明确提出的任务。

---

## 2. 修正语音识别错误

检查并修复：

### 同音错误

根据上下文修正明显错误：

例如：

"派森代码"
→
"Python 代码"

"查 GPT"
→
"ChatGPT"

但如果无法确定，不要强行修改。

---

### 专业名词

优先保证：

- AI 模型名称
- 软件名称
- 编程语言
- 技术术语
- 产品名称

的正确性。

---

## 3. 删除语音中的噪音

删除：

- 嗯
- 啊
- 那个
- 就是
- 然后（没有连接作用时）
- 我想一下
- 怎么说呢

删除：

重复：

"帮我写一个一个程序"

修改：

"帮我写一个程序"

---

## 4. 保留口语中的有效信息

不要过度压缩。

例如：

原文：
"我现在有一个程序，然后它的问题就是运行速度比较慢，我想看看有没有什么优化的方法"

保留为：
"我现在有一个程序，它的问题是运行速度比较慢，我想看看有没有什么优化的方法。"

不要改成：
"帮我优化程序性能。"

---

## 5. 允许轻微整理

可以：

- 调整明显混乱的语序
- 补充标点
- 合并明显断裂的句子
- 修正语法错误

但不要：

- 总结
- 提炼
- 改写成新的任务
- 添加用户没有说的信息

---

## 6. AI 使用场景优化

因为文本通常会发送给 AI：

可以让表达更加清晰。

例如：

原文：

"这个代码为什么它这里不行"

可以改：

"为什么这段代码这里不能运行？"

但是：

不要扩展成：

"请分析这段代码无法运行的原因，并提供解决方案。"

---

## 7. 输出要求

只输出整理后的文本。

不要输出：

- 修改说明
- 分析过程
- 原文对比
- 任何额外解释

---

输入会作为下一条用户消息给你。

输出：

整理后的文本。`;

// 词表也拼进去（用户可能希望专有名词被纠正）
const TIDY_SYSTEM_FINAL = GLOSSARY
  ? TIDY_SYSTEM.replace(
      '输入会作为下一条用户消息给你。',
      `用户常用词表（原文出现它们的同音/近音误写时，一律替换成词表里的写法）：\n${GLOSSARY}\n\n输入会作为下一条用户消息给你。`)
  : TIDY_SYSTEM;

const SYSTEM = TIDY ? TIDY_SYSTEM_FINAL : PROOFREAD_SYSTEM;

// max_tokens：按输入长度估算，配置值作为"下限"而不是"覆盖"。
// 原因：思考模式关不掉的来源（如某些中转站）会先烧几百个思维 token 才吐正文，
// 256 根本不够；而官方 API 给大 max_tokens 既不涨价也不变慢（模型自己会停），
// 所以抬高下限没有副作用。
const AUTO_TOK = Math.max(256, Math.min(4096, input.length * 3));
const CFG_TOK  = Number(process.env.VT_CORRECT_MAX_TOKENS || 0);
const MAXTOK   = CFG_TOK > 0 ? Math.max(AUTO_TOK, Math.min(8192, CFG_TOK)) : AUTO_TOK;
// Anthropic 格式里 system 是顶层字段，不是 messages 中的一条
const body = API_FORMAT === 'anthropic'
  ? {
      model: MODEL,
      system: SYSTEM,
      messages: [{ role: 'user', content: input }],
      max_tokens: MAXTOK,
      stream: false,
    }
  : {
      model: MODEL,
      messages: [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: input },
      ],
      // 只有 DeepSeek 系认这两个参数，其他模型发了会被卡住（见上面 USE_DS_THINK 的说明）
      ...(USE_DS_THINK ? {
        reasoning_effort: 'none',            // 非推理模式
        thinking: { type: 'disabled' },      // 文档说明思考模式默认开启，必须显式关闭
      } : {}),
      max_tokens: MAXTOK,
      stream: false,
    };

const HEADERS = API_FORMAT === 'anthropic'
  ? { 'Content-Type': 'application/json', 'x-api-key': KEY, 'anthropic-version': '2023-06-01' }
  : { 'Content-Type': 'application/json', 'Authorization': `Bearer ${KEY}` };

const ctl = new AbortController();
const timer = setTimeout(() => ctl.abort(), TIMEOUT);
let result = null, err = null;
const t0 = Date.now();
try {
  const r = await fetch(ENDPOINT, {
    method: 'POST',
    headers: HEADERS,
    body: JSON.stringify(body),
    signal: ctl.signal,
  });
  if (!r.ok) err = `HTTP ${r.status} ${(await r.text()).slice(0, 150)}`;
  else result = await r.json();
} catch (e) {
  err = e.name === 'AbortError' ? `超时(${TIMEOUT}ms)` : e.message;
} finally { clearTimeout(timer); }
const elapsed = Date.now() - t0;

if (err) passthrough(err);

let out = (API_FORMAT === 'anthropic'
  ? (result?.content || []).filter((b) => b.type === 'text').map((b) => b.text).join('')
  : (result?.choices?.[0]?.message?.content || '')).trim();
if (!out) passthrough('模型返回空');

// ── 防"改错"护栏 ──
// 阈值按模式区分，这是两种模式最本质的差别：
//   proofread 严格 —— 只该改几个字，改动大了一定是模型在乱写
//   tidy      中等 —— 允许通顺化和整理语序，但不该把一段话压成一句结论；
//                     MIN_RATIO 专门防"过度压缩"（用户这版提示词里明确禁止的行为）
// 参考实测：同一段 65 字口水话，proofread 改动 7.7%，tidy 大约 35~55%。
const LIMITS = {
  proofread: { diff: 0.35, minRatio: 0.60, maxRatio: 1.60 },
  tidy:      { diff: 0.55, minRatio: 0.35, maxRatio: 1.60 },
};
const LIM = TIDY ? LIMITS.tidy : LIMITS.proofread;
const MAX_DIFF  = LIM.diff;      // 允许的 LCS 差异率上限
const MIN_RATIO = LIM.minRatio;  // 最短能压到原文的几成
const MAX_RATIO = LIM.maxRatio;  // 最长能扩到原文的几倍

const FILLER_EXTRA = (process.env.VT_CORRECT_FILLERS || '').trim();
const cmpIn = stripFillers(input, FILLER_EXTRA);
const cmpOut = stripFillers(out, FILLER_EXTRA);
const origLen = cmpIn.length, newLen = cmpOut.length;
const lenRatio = newLen / Math.max(1, origLen);

// ① 长度差异过大 → 模型在改写而不是纠错 → 丢弃
if (lenRatio < MIN_RATIO || lenRatio > MAX_RATIO) {
  passthrough(`长度变化过大 ${origLen}→${newLen}（疑似改写）`);
}
// ② 改动字符占比过高 → 丢弃
// 注意：必须用最长公共子序列(LCS)而不是逐位比对 —— 同音字修正常常改变长度
// （「deep sick」9字 →「DeepSeek」8字），逐位比分会因错位算出虚高的差异率而误拦。
function lcsLength(a, b) {
  const n = a.length, m = b.length;
  if (n === 0 || m === 0) return 0;
  let prev = new Uint16Array(m + 1);
  let cur = new Uint16Array(m + 1);
  for (let i = 1; i <= n; i++) {
    for (let j = 1; j <= m; j++) {
      cur[j] = (a[i - 1] === b[j - 1]) ? prev[j - 1] + 1 : Math.max(prev[j], cur[j - 1]);
    }
    const t = prev; prev = cur; cur = t;
    cur.fill(0);
  }
  return prev[m];
}
const dr = (origLen + newLen) === 0
  ? 0
  : 1 - (2 * lcsLength(cmpIn, cmpOut)) / (origLen + newLen);
if (dr > MAX_DIFF) {
  passthrough(`改动比例过高 ${(dr * 100).toFixed(0)}%（疑似改写）`);
}
// ③ 输出里混进解释性文字 → 丢弃
//   ⚠️ 不能简单地拦掉所有 \n\n。实测 gpt-4o 会把「第一个…第二个…第三个…」
//   整理成**带空行的编号列表**，这是很自然的整理结果，拦掉等于整条输出作废 ——
//   表现是"开了跟没开一样"，日志里只写"疑似包含解释性内容"，极难排查
//   （tidy 模式下这个 input 曾经 3/3 全被拦）。
//   所以只拦真正是"开场白"的形式：解释性开头，或把结果包进 markdown 代码块。
const looksExplanatory =
  /^(好的|以下是|下面是|这是|修正后|修改后|整理后|整理结果|校对后|输出[:：]|结果[:：]|文本[:：]|内容[:：])/.test(out) ||
  /```/.test(out);
if (looksExplanatory) {
  passthrough('输出疑似包含解释性内容');
}
// 换行统一：模型可能给 \r\n，也可能连续空好几行。保留段落，但不让空白失控。
out = out.replace(/\r\n?/g, '\n').replace(/\n{3,}/g, '\n\n').trim();

// ④ 程序化清一道填充词：提示词里已经要求删，但实测提示词对"删除类"指令不可靠
//    （第一版提示词就几乎什么都不做），所以这里再用规则兜一次底。
const cleaned = stripFillers(out, FILLER_EXTRA);
const removedFillers = out.length - cleaned.length;

const u = result?.usage || {};
const inTok  = u.prompt_tokens     ?? u.input_tokens     ?? '?';
const outTok = u.completion_tokens ?? u.output_tokens    ?? '?';
process.stderr.write(
  `[corrector] ${MODEL}(${API_FORMAT}/${MODE_LABEL}) ${inTok}→${outTok} tok  ${elapsed}ms  ` +
  `改动 ${(dr * 100).toFixed(1)}%` +
  (removedFillers > 0 ? `  去填充词 ${removedFillers} 字` : '') + '\n');
fs.writeFileSync(outFile, cleaned, 'utf8');
process.stdout.write(cleaned);

} catch (e) {
  // passthrough 的哨兵：正常早退，不算错误
  if (e !== VT_DONE) {
    process.stderr.write(`[corrector] 未预期错误: ${e && e.stack ? e.stack : e}\n`);
    process.exitCode = 1;
  }
  // 兜底：域名解析不了这类情况会留下卡住的句柄，进程不肯自然退出
  // （实测能多赖 5 秒），父进程就得多等。用 unref 定时器强制收尾：
  // 没有挂起句柄时进程立刻自然退出，根本不会走到这里，所以不会多等。
  setTimeout(() => process.exit(process.exitCode || 0), 2000).unref();
}
