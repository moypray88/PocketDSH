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
  Image = 10,
}

/** 行内样式片段。 */
export interface MdRun {
  text: string;
  bold: boolean;
  mono: boolean;
  /** 非空表示链接地址。 */
  link: string;
  /** 非空表示图片地址（行内图片退化为图标+说明文字渲染）。 */
  img: string;
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
  /** 仅 Image 块使用：图片地址（https URL 或服务器本地路径）。 */
  src: string;
}

function mkBlock(kind: MdKind, runs: MdRun[], code: string, order: number, table: MdTable | null, src: string): MdBlock {
  const b: MdBlock = {
    kind: kind,
    runs: runs,
    code: code,
    order: order,
    table: table,
    src: src,
  };
  return b;
}

function mkRun(text: string, bold: boolean, mono: boolean, link: string, img: string): MdRun {
  const r: MdRun = {
    text: text,
    bold: bold,
    mono: mono,
    link: link,
    img: img,
  };
  return r;
}

/** 图片扩展名 → 是否受支持（png/jpg/jpeg/webp/gif）。 */
export function imageExtOf(t: string): string {
  const dot: number = t.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  const ext: string = t.substring(dot).toLowerCase();
  if (ext === '.png' || ext === '.jpg' || ext === '.jpeg' || ext === '.webp' || ext === '.gif') {
    return ext;
  }
  return '';
}

/** 裸链接字符集：不含空白/引号/尖括号/反引号/圆括号/竖线，CJK 天然截断。 */
function isUrlChar(ch: string): boolean {
  const c: number = ch.charCodeAt(0);
  if (ch.length !== 1) {
    return false;
  }
  if (c >= 97 && c <= 122) {
    return true;
  }
  if (c >= 65 && c <= 90) {
    return true;
  }
  if (c >= 48 && c <= 57) {
    return true;
  }
  return '-._~:/?#[]@!$&*+,;=%'.indexOf(ch) >= 0;
}

/** 去掉尾部句读（如「详见 https://x/a.html。」）。 */
function trimUrlPunct(url: string): string {
  while (url.length > 0) {
    const last: string = url.charAt(url.length - 1);
    if ('.,;!?。，；！？、>'.indexOf(last) >= 0) {
      url = url.substring(0, url.length - 1);
      continue;
    }
    break;
  }
  return url;
}

/** URL 末尾是否带文件扩展名（最后一个 '/' 后为 '.' + 1~8 位字母数字）。 */
function hasFileExt(url: string): boolean {
  const slash: number = url.lastIndexOf('/');
  const dot: number = url.lastIndexOf('.');
  if (dot <= slash) {
    return false;
  }
  const ext: string = url.substring(dot + 1);
  if (ext.length < 1 || ext.length > 8) {
    return false;
  }
  for (let i: number = 0; i < ext.length; i++) {
    const c: number = ext.charCodeAt(i);
    const alnum: boolean = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
    if (!alnum) {
      return false;
    }
  }
  return true;
}

/** 裸链接合法性：http(s)://、/reports/、reports/ 相对路径或 /*.html 站内路径。 */
function validBareUrl(url: string): boolean {
  const isHttp: boolean = (url.indexOf('https://') === 0 && url.length > 8)
    || (url.indexOf('http://') === 0 && url.length > 7);
  const isReports: boolean = url.indexOf('/reports/') === 0 && url.length > '/reports/'.length;
  const isRelReports: boolean = url.indexOf('reports/') === 0 && url.length > 'reports/'.length;
  const isHtmlPath: boolean = url.charAt(0) === '/' && url.length > 5 && url.substring(url.length - 5) === '.html';
  return isHttp || isReports || isRelReports || isHtmlPath;
}

/**
 * 从 start 扫描裸链接，返回地址（不合法返回空串）。
 * 中文文件名（如 https://…/生猪周期监测.html）不在 ASCII 字符集内：
 * 仅当 ASCII 截断后紧跟中文、且整段以 http/reports 开头并能在右侧收敛出文件
 * 扩展名时并入，否则维持截断，避免把后续中文正文吞进链接。
 */
function scanBareUrl(s: string, start: number): string {
  let j: number = start;
  while (j < s.length && isUrlChar(s.charAt(j))) {
    j++;
  }
  const url: string = trimUrlPunct(s.substring(start, j));
  if (validBareUrl(url)) {
    return url;
  }
  if (j < s.length && s.charCodeAt(j) > 127) {
    let k: number = j;
    while (k < s.length && (isUrlChar(s.charAt(k)) || s.charCodeAt(k) > 127)) {
      k++;
    }
    let cand: string = trimUrlPunct(s.substring(start, k));
    const rooted: boolean = cand.indexOf('http') === 0
      || cand.indexOf('/reports/') === 0 || cand.indexOf('reports/') === 0;
    if (rooted) {
      while (cand.length > 0) {
        if (hasFileExt(cand)) {
          return cand;
        }
        cand = cand.substring(0, cand.length - 1);
      }
    }
  }
  return url;
}

/** 从整行 `![alt](src)` 提取图片地址；非图片行返回空串。 */
function mdImageSrc(t: string): string {
  if (t.indexOf('![') !== 0) {
    return '';
  }
  const mid: number = t.indexOf('](');
  if (mid < 2) {
    return '';
  }
  const end: number = t.lastIndexOf(')');
  if (end < mid + 2) {
    return '';
  }
  return t.substring(mid + 2, end).trim();
}

/** 行内解析：`code`、**bold**、[text](url)、![alt](src)，从左到右扫描，未配对符号按原文输出。 */
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
          runs.push(mkRun(plain, false, false, '', ''));
          plain = '';
        }
        runs.push(mkRun(s.substring(i + 1, close), false, true, '', ''));
        i = close + 1;
        continue;
      }
    }
    if (ch === '*' && s.charAt(i + 1) === '*') {
      const close: number = s.indexOf('**', i + 2);
      if (close > i + 1) {
        if (plain !== '') {
          runs.push(mkRun(plain, false, false, '', ''));
          plain = '';
        }
        runs.push(mkRun(s.substring(i + 2, close), true, false, '', ''));
        i = close + 2;
        continue;
      }
    }
    if (ch === '!' && s.charAt(i + 1) === '[') {
      // 行内图片：正文 Text 内无法嵌位图，退化为 🖼 + 说明文字（独立成行的图片走 Image 块）
      const mid: number = s.indexOf('](', i + 2);
      if (mid > i + 1) {
        const end: number = s.indexOf(')', mid + 2);
        if (end > mid) {
          if (plain !== '') {
            runs.push(mkRun(plain, false, false, '', ''));
            plain = '';
          }
          runs.push(mkRun(s.substring(i + 2, mid), false, false, '', s.substring(mid + 2, end)));
          i = end + 1;
          continue;
        }
      }
    }
    if (ch === '[') {
      const mid: number = s.indexOf('](', i + 1);
      if (mid > i) {
        const end: number = s.indexOf(')', mid + 2);
        if (end > mid) {
          if (plain !== '') {
            runs.push(mkRun(plain, false, false, '', ''));
            plain = '';
          }
          runs.push(mkRun(s.substring(i + 1, mid), false, false, s.substring(mid + 2, end), ''));
          i = end + 1;
          continue;
        }
      }
    }
    // 裸 URL / 站内绝对路径：无 markdown 包裹也成链接（dsh 常直接贴报告地址）
    if (ch === 'h' || ch === '/') {
      const bare: string = scanBareUrl(s, i);
      if (bare !== '') {
        if (plain !== '') {
          runs.push(mkRun(plain, false, false, '', ''));
          plain = '';
        }
        runs.push(mkRun(bare, false, false, bare, ''));
        i = i + bare.length;
        continue;
      }
    }
    plain += ch;
    i++;
  }
  if (plain !== '') {
    runs.push(mkRun(plain, false, false, '', ''));
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
  out.push(mkBlock(MdKind.Table, [], '', 0, tbl, ''));
}

/** 解析非代码段：按行识别结构，连续普通行合并为段落。 */
function parseTextSegment(seg: string, out: MdBlock[]): void {
  const lines: string[] = seg.split('\n');
  let para: string[] = [];
  const flushPara = (): void => {
    if (para.length > 0) {
      out.push(mkBlock(MdKind.Para, parseRuns(para.join('\n')), '', 0, null, ''));
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
      out.push(mkBlock(MdKind.Rule, [], '', 0, null, ''));
      continue;
    }
    // 独立成行的图片：![alt](src) 或裸本地路径（/、~ 开头 + 图片扩展名且不含空格）
    const standaloneSrc: string = mdImageSrc(t) !== '' ? mdImageSrc(t)
      : ((t.charAt(0) === '/' || t.charAt(0) === '~') && t.indexOf(' ') < 0 && imageExtOf(t) !== '' ? t : '');
    if (standaloneSrc !== '') {
      flushPara();
      out.push(mkBlock(MdKind.Image, [], '', 0, null, standaloneSrc));
      continue;
    }
    if (t.indexOf('### ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H3, parseRuns(t.substring(4)), '', 0, null, ''));
      continue;
    }
    if (t.indexOf('## ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H2, parseRuns(t.substring(3)), '', 0, null, ''));
      continue;
    }
    if (t.indexOf('# ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.H1, parseRuns(t.substring(2)), '', 0, null, ''));
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
      out.push(mkBlock(MdKind.Bullet, parseRuns(t.substring(2)), '', 0, null, ''));
      continue;
    }
    if (t.indexOf('> ') === 0) {
      flushPara();
      out.push(mkBlock(MdKind.Quote, parseRuns(t.substring(2)), '', 0, null, ''));
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
      out.push(mkBlock(MdKind.Ordered, parseRuns(t.substring(k + 2)), '', order, null, ''));
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
      blocks.push(mkBlock(MdKind.Code, [], code, 0, null, ''));
    } else {
      parseTextSegment(seg, blocks);
    }
  }
  return blocks;
}
