/** 轻量 Markdown 解析器：代码围栏 + 标题/列表/引用/分隔线 + 行内粗体/行内码。 */

/** 块级类型。 */
export enum MdKind {
  Para = 0,
  H1 = 1,
  H2 = 2,
  H3 = 3,
  Bullet = 4,
  Ordered = 5,
  Quote = 6,
  Code = 7,
  Rule = 8,
}

/** 行内样式片段。 */
export interface MdRun {
  text: string;
  bold: boolean;
  mono: boolean;
}

/** 块级元素。 */
export interface MdBlock {
  kind: MdKind;
  runs: MdRun[];
  /** 仅 Code 块使用。 */
  code: string;
  /** 仅 Ordered 块使用。 */
  order: number;
}

function mkBlock(kind: MdKind, runs: MdRun[], code: string, order: number): MdBlock {
  const b: MdBlock = {
    kind: kind,
    runs: runs,
    code: code,
    order: order,
  };
  return b;
}

function mkRun(text: string, bold: boolean, mono: boolean): MdRun {
  const r: MdRun = {
    text: text,
    bold: bold,
    mono: mono,
  };
  return r;
}

/** 行内解析：`code` 与 **bold**，从左到右扫描，未配对符号按原文输出。 */
export function parseRuns(s: string): MdRun[] {
  const runs: MdRun[] = [];
  let plain: string = '';
  let i: number = 0;
  while (i < s.length) {
    const ch: string = s.charAt(i);
    if (ch === '`') {
      const close: number = s.indexOf('`', i + 1);
      if (close > i) {
        if (plain !== '') {
          runs.push(mkRun(plain, false, false));
          plain = '';
        }
        runs.push(mkRun(s.substring(i + 1, close), false, true));
        i = close + 1;
        continue;
      }
    }
    if (ch === '*' && s.charAt(i + 1) === '*') {
      const close: number = s.indexOf('**', i + 2);
      if (close > i + 1) {
        if (plain !== '') {
          runs.push(mkRun(plain, false, false));
          plain = '';
        }
        runs.push(mkRun(s.substring(i + 2, close), true, false));
        i = close + 2;
        continue;
      }
    }
    plain += ch;
    i++;
  }
  if (plain !== '') {
    runs.push(mkRun(plain, false, false));
  }
  return runs;
}

/** 解析非代码段：按行识别结构，连续普通行合并为段落。 */
function parseTextSegment(seg: string, out: MdBlock[]): void {
  const lines: string[] = seg.split('\n');
  let para: string[] = [];
  const flushPara = (): void => {
    if (para.length > 0) {
      out.push(mkBlock(MdKind.Para, parseRuns(para.join('\n')), '', 0));
      para = [];
    }
  };

  for (let i: number = 0; i < lines.length; i++) {
    const t: string = lines[i].trim();
    if (t === '') {
      flushPara();
      continue;
    }
    if (t === '---' || t === '***' || t === '___') {
      flushPara();
      out.push(mkBlock(MdKind.Rule, [], '', 0));
      continue;
    }
    if (t.indexOf('### ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H3, parseRuns(t.substring(4)), '', 0));
      continue;
    }
    if (t.indexOf('## ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H2, parseRuns(t.substring(3)), '', 0));
      continue;
    }
    if (t.indexOf('# ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H1, parseRuns(t.substring(2)), '', 0));
      continue;
    }
    if ((t.indexOf('- ') === 0 || t.indexOf('* ') === 0) && t.indexOf('**') !== 0) {
      flushPara();
      out.push(mkBlock(MdKind.Bullet, parseRuns(t.substring(2)), '', 0));
      continue;
    }
    if (t.indexOf('> ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.Quote, parseRuns(t.substring(2)), '', 0));
      continue;
    }
    // 有序列表：数字 + 点 + 空格
    let k: number = 0;
    while (k < t.length && t.charAt(k) >= '0' && t.charAt(k) <= '9') {
      k++;
    }
    if (k > 0 && k + 1 < t.length && t.charAt(k) === '.' && t.charAt(k + 1) === ' ') {
      flushPara();
      const order: number = Number(t.substring(0, k));
      out.push(mkBlock(MdKind.Ordered, parseRuns(t.substring(k + 2)), '', order));
      continue;
    }
    para.push(t);
  }
  flushPara();
}

/** 解析全文：``` 围栏为代码块，其余按行解析结构。 */
export function parseMarkdown(src: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const parts: string[] = src.split('```');
  for (let i: number = 0; i < parts.length; i++) {
    const seg: string = parts[i];
    if (seg === '') {
      continue;
    }
    if (i % 2 === 1) {
      // 代码块：去掉首行语言标注（如 bash / json）
      let code: string = seg;
      const nl: number = code.indexOf('\n');
      const firstLine: string = nl < 0 ? code : code.substring(0, nl);
      if (firstLine.trim().length > 0 && firstLine.trim().length < 16 && firstLine.indexOf(' ') < 0) {
        code = nl < 0 ? '' : code.substring(nl + 1);
      }
      blocks.push(mkBlock(MdKind.Code, [], code, 0));
    } else {
      parseTextSegment(seg, blocks);
    }
  }
  return blocks;
}
