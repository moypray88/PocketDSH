/** 轻量 Markdown 解析器：代码围栏 + 标题/列表/引用/分隔线/表格 + 行内粗体/行内码/链接。 */

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
  Table = 9,
}

/** 行内样式片段。 */
export interface MdRun {
  text: string;
  bold: boolean;
  mono: boolean;
  /** 非空表示链接地址。 */
  link: string;
}

/** 表格数据（首行为表头）。 */
export interface MdTable {
  cols: number;
  header: MdRun[][];
  rows: MdRun[][][];
}

/** 块级元素。 */
export interface MdBlock {
  kind: MdKind;
  runs: MdRun[];
  /** 仅 Code 块使用。 */
  code: string;
  /** 仅 Ordered 块使用。 */
  order: number;
  /** 仅 Table 块使用。 */
  table: MdTable | null;
}

function mkBlock(kind: MdKind, runs: MdRun[], code: string, order: number, table: MdTable | null): MdBlock {
  const b: MdBlock = {
    kind: kind,
    runs: runs,
    code: code,
    order: order,
    table: table,
  };
  return b;
}

function mkRun(text: string, bold: boolean, mono: boolean, link: string): MdRun {
  const r: MdRun = {
    text: text,
    bold: bold,
    mono: mono,
    link: link,
  };
  return r;
}

/** 行内解析：`code`、**bold**、[text](url)，从左到右扫描，未配对符号按原文输出。 */
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
          runs.push(mkRun(plain, false, false, ''));
          plain = '';
        }
        runs.push(mkRun(s.substring(i + 1, close), false, true, ''));
        i = close + 1;
        continue;
      }
    }
    if (ch === '*' && s.charAt(i + 1) === '*') {
      const close: number = s.indexOf('**', i + 2);
      if (close > i + 1) {
        if (plain !== '') {
          runs.push(mkRun(plain, false, false, ''));
          plain = '';
        }
        runs.push(mkRun(s.substring(i + 2, close), true, false, ''));
        i = close + 2;
        continue;
      }
    }
    if (ch === '[') {
      const mid: number = s.indexOf('](', i + 1);
      if (mid > i) {
        const end: number = s.indexOf(')', mid + 2);
        if (end > mid) {
          if (plain !== '') {
            runs.push(mkRun(plain, false, false, ''));
            plain = '';
          }
          runs.push(mkRun(s.substring(i + 1, mid), false, false, s.substring(mid + 2, end)));
          i = end + 1;
          continue;
        }
      }
    }
    plain += ch;
    i++;
  }
  if (plain !== '') {
    runs.push(mkRun(plain, false, false, ''));
  }
  return runs;
}

/** 拆分表格行单元格：去首尾空管道，逐格 trim。 */
function splitCells(line: string): string[] {
  let parts: string[] = line.split('|');
  if (parts.length > 0 && parts[0].trim() === '') {
    parts = parts.slice(1);
  }
  if (parts.length > 0 && parts[parts.length - 1].trim() === '') {
    parts = parts.slice(0, parts.length - 1);
  }
  const cells: string[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    cells.push(parts[i].trim());
  }
  return cells;
}

function isSeparatorLine(cells: string[]): boolean {
  if (cells.length === 0) {
    return false;
  }
  for (let i: number = 0; i < cells.length; i++) {
    const t: string = cells[i].replace(/:/g, '').replace(/-/g, '').trim();
    if (t !== '') {
      return false;
    }
    if (cells[i].indexOf('-') < 0) {
      return false;
    }
  }
  return true;
}

/** 解析表格块。 */
function parseTable(lines: string[], out: MdBlock[]): void {
  const raw: string[][] = [];
  for (let i: number = 0; i < lines.length; i++) {
    raw.push(splitCells(lines[i]));
  }
  let headerCells: string[] = [];
  let bodyStart: number = 0;
  if (raw.length >= 2 && isSeparatorLine(raw[1])) {
    headerCells = raw[0];
    bodyStart = 2;
  }
  let cols: number = headerCells.length;
  const bodyRows: MdRun[][][] = [];
  for (let i: number = bodyStart; i < raw.length; i++) {
    const cells: string[] = raw[i];
    if (cells.length > cols) {
      cols = cells.length;
    }
    const row: MdRun[][] = [];
    for (let j: number = 0; j < cells.length; j++) {
      row.push(parseRuns(cells[j]));
    }
    bodyRows.push(row);
  }
  const header: MdRun[][] = [];
  for (let j: number = 0; j < headerCells.length; j++) {
    header.push(parseRuns(headerCells[j]));
  }
  const tbl: MdTable = {
    cols: cols,
    header: header,
    rows: bodyRows,
  };
  out.push(mkBlock(MdKind.Table, [], '', 0, tbl));
}

/** 解析非代码段：按行识别结构，连续普通行合并为段落。 */
function parseTextSegment(seg: string, out: MdBlock[]): void {
  const lines: string[] = seg.split('\n');
  let para: string[] = [];
  const flushPara = (): void => {
    if (para.length > 0) {
      out.push(mkBlock(MdKind.Para, parseRuns(para.join('\n')), '', 0, null));
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
      out.push(mkBlock(MdKind.Rule, [], '', 0, null));
      continue;
    }
    if (t.indexOf('### ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H3, parseRuns(t.substring(4)), '', 0, null));
      continue;
    }
    if (t.indexOf('## ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H2, parseRuns(t.substring(3)), '', 0, null));
      continue;
    }
    if (t.indexOf('# ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H1, parseRuns(t.substring(2)), '', 0, null));
      continue;
    }
    if (t.indexOf('|') === 0) {
      flushPara();
      const tbl: string[] = [];
      while (i < lines.length && lines[i].trim().indexOf('|') === 0) {
        tbl.push(lines[i].trim());
        i++;
      }
      i--;
      parseTable(tbl, out);
      continue;
    }
    if ((t.indexOf('- ') === 0 || t.indexOf('* ') === 0) && t.indexOf('**') !== 0) {
      flushPara();
      out.push(mkBlock(MdKind.Bullet, parseRuns(t.substring(2)), '', 0, null));
      continue;
    }
    if (t.indexOf('> ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.Quote, parseRuns(t.substring(2)), '', 0, null));
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
      out.push(mkBlock(MdKind.Ordered, parseRuns(t.substring(k + 2)), '', order, null));
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
      blocks.push(mkBlock(MdKind.Code, [], code, 0, null));
    } else {
      parseTextSegment(seg, blocks);
    }
  }
  return blocks;
}
