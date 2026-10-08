// textrules.mjs — 纯文本后处理规则（无副作用，可独立测试）
//
// 为什么把填充词去除做成程序化规则而不是只写在提示词里：
//   实测提示词对"删除类"指令很不可靠 —— 第一版提示词几乎什么都不做。
//   而填充词去除是纯机械操作，用正则可控、可审计、零成本、零延迟。
//
// 为什么只删句首和标点之后：
//   「啊」「呀」「哦」在中文里也承担语气功能：
//     「这本书真好啊」—— 删掉「啊」句子就坏了
//     「是啊」        —— 这是应答，不是废话
//   无脑全删会破坏句意。只删句首/标点后的独立填充词，既覆盖绝大多数口语废话，
//   又不会碰到语气助词。

export const FILLER_DEFAULT = ['嗯', '呃', '额', '唉', '哎', '呐', '唔', 'emmm', 'emm'];

/**
 * 去掉句首 / 标点之后的填充词。
 * @param {string} text
 * @param {string} extraWords 额外汇总表，用 、 , ， 或空格分隔
 */
export function stripFillers(text, extraWords = '') {
  if (!text) return text;
  const extra = extraWords
    ? String(extraWords).split(/[、,，\s]+/).map((s) => s.trim()).filter(Boolean)
    : [];
  const all = [...FILLER_DEFAULT, ...extra];
  if (all.length === 0) return text;

  // 长词优先，避免短词先匹配掉长词的一部分
  all.sort((a, b) => b.length - a.length);
  const alt = all.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|');
  const punct = '。！？；：，、,.!?;:';
  const w = `(?:${alt})`;

  let prev;
  let out = text;
  let guard = 0;
  do {
    prev = out;
    // ① 句首的填充词：连同其后紧跟的标点一起去掉。
    //    若只删填充词会留下一个孤立句号（「嗯。稍等。」→「。稍等。」）。
    out = out.replace(new RegExp(`^\\s*${w}(?:[、,，\\s]*${w})*[、,，\\s]*[${punct}]?\\s*`), '');
    // ② 标点之后的填充词：保留那个标点本身
    out = out.replace(new RegExp(`([${punct}])(?:[、,，\\s]*${w})+[、,，\\s]*`, 'g'), '$1');
    // ③ 首尾可能剩下的多余空白与重复空格
    out = out.replace(/[ \t]{2,}/g, ' ').replace(/^\s+/, '');
  } while (out !== prev && ++guard < 20);

  return out.trim();
}
