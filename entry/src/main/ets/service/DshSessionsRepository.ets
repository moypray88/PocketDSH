/** 会话仓库：session/list 与 session/page 的 wire 解析，产出视图模型。 */
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { DshApiClient, DshApiClientError } from './DshApiClient';
import { CatalogVm, ChatEntryKind, ChatEntryVm, HistoryPageVm, ModelGroupVm, ModelItemVm, SessionSummaryVm, ToolCallVm } from '../model/SessionVms';

/* ───────────── wire 形状（宽松解析；字段可缺省也可为显式 null） ───────────── */

/** session/list 的 value。 */
interface WireSessionListValue {
  items?: WireSessionItem[];
}

/** session/list 单项。 */
interface WireSessionItem {
  sessionId?: string;
  updatedAt?: number;
  running?: boolean;
  blank?: boolean;
  cwd?: string;
  /** 非空表示是 subagent 子会话：必须经父地址访问，列表中过滤掉。 */
  parentSessionId?: string;
  /** 防御性归档标记（服务器字段形态待确认，兼容常见形态）。 */
  archived?: boolean;
  projections?: WireProjections;
}

/** 会话列表元数据（防御性解析归档标记）。 */
interface WireSessionListMeta {
  archived?: boolean;
  hidden?: boolean;
}

/** 会话投影。 */
interface WireProjections {
  asOfSeq?: number;
  values?: WireProjectionValues;
}

/** 投影值。 */
interface WireProjectionValues {
  title?: string;
  sessionStats?: WireSessionStats;
  turnOutline?: WireTurnOutlineItem[];
  modelSelection?: WireModelSelection;
  sessionListMetadata?: WireSessionListMeta;
}

/** 会话统计。 */
interface WireSessionStats {
  turns?: number;
}

/** 轮次大纲项。 */
interface WireTurnOutlineItem {
  prompt?: string;
}

/** 模型选择投影。 */
interface WireModelSelection {
  lastUsed?: WireModelId;
  next?: WireModelId;
}

/** 模型标识。 */
interface WireModelId {
  provider?: string;
  model?: string;
  reasoningEffort?: string;
}

/** session/page 的 request。 */
interface WirePageRequest {
  address: WireAddress;
  throughSeq: number;
  maxMessages: number;
  beforeSeq?: number;
}

/** 会话地址。 */
interface WireAddress {
  kind: string;
  sessionId: string;
}

/** session/page 的 value。 */
interface WireHistoryValue {
  records?: WireRecord[];
  hasMore?: boolean;
}

/** 历史记录。 */
interface WireRecord {
  event?: WireEvent;
}

/** 事件信封。 */
interface WireEvent {
  type?: string;
  seq?: number;
  time?: number;
  data?: object;
}

/** 内容块（text / reasoning）。 */
interface WireContentBlock {
  type?: string;
  text?: string;
}

/** user/message 的 data。 */
interface WireUserEventData {
  content?: WireContentBlock[];
}

/** assistant/message 的 data。 */
interface WireAssistantEventData {
  turn?: number;
  message?: WireAssistantMessage;
  usage?: WireUsage;
}

/** 助手消息体。 */
interface WireAssistantMessage {
  content?: WireContentBlock[];
  source?: WireAssistantSource;
}

/** 助手来源。 */
interface WireAssistantSource {
  model?: string;
}

/** 用量。 */
interface WireUsage {
  inputTokens?: number;
  outputTokens?: number;
}

/** tool/call 的 data。 */
interface WireToolCallData {
  turn?: number;
  callId?: string;
  name?: string;
  arguments?: string;
}

/** tool/result 的 data。 */
interface WireToolResultData {
  message?: WireToolResultMessage;
}

/** 工具结果消息体。 */
interface WireToolResultMessage {
  source?: WireToolResultSource;
  content?: WireToolResultBlock[];
}

/** 工具结果来源（callId 配对键）。 */
interface WireToolResultSource {
  callId?: string;
}

/** 工具结果块。 */
interface WireToolResultBlock {
  content?: WireContentBlock[];
}

/** turn/start 的 data。 */
interface WireTurnStartData {
  turn?: number;
}

/** session/create 的返回。 */
interface WireCreateValue {
  sessionId?: string;
  agentPreset?: string;
}

/** session/prompt 的内容块。 */
interface WirePromptPart {
  type: string;
  text: string;
}

/** session/prompt 的请求（web 端真实发送路径，实测通过）。 */
interface WirePromptRequest {
  requestId: string;
  sessionId: string;
  mode: string;
  content: WirePromptPart[];
  clientTimeZone: string;
}

/** session/selectModel 的请求。 */
interface WireSelectModel {
  sessionId: string;
  provider: string;
  model: string;
}

/** session/cancel 的请求（源码类型 SessionCancelRequest）。 */
interface WireCancelRequest {
  sessionId: string;
}

/** session/rename 的请求（源码类型 SessionRenameRequest）。 */
interface WireRenameRequest {
  sessionId: string;
  title: string;
}

/** session/modelCatalog 的返回。 */
interface WireCatalogValue {
  default?: WireModelId;
  groups?: WireCatalogGroup[];
}

/** 目录分组。 */
interface WireCatalogGroup {
  id?: string;
  name?: string;
  models?: WireCatalogModel[];
}

/** 目录模型项。 */
interface WireCatalogModel {
  id?: string;
  name?: string;
  description?: string;
}

/** 工具结果文本截断上限。 */
const RESULT_TEXT_MAX: number = 2000;
/** 列表摘要截断上限。 */
const LAST_PROMPT_MAX: number = 60;

/** 空对象兜底（避免每次字面量）。 */
const EMPTY_PROJ: WireProjections = { asOfSeq: -1 };
const EMPTY_VALUES: WireProjectionValues = {};
const EMPTY_STATS: WireSessionStats = { turns: 0 };
const EMPTY_DATA: Record<string, Object> = {};
const EMPTY_MSG: WireAssistantMessage = {};
const EMPTY_USAGE: WireUsage = {};

/**
 * DshSessionsRepository：会话列表与历史分页。
 * 服务器 JSON 常发显式 null，所有取值同时防 undefined 与 null。
 */
export class DshSessionsRepository {
  /** 拉取会话列表（按 updatedAt 降序，过滤 subagent 子会话）。 */
  static async listSessions(ctx: common.Context): Promise<SessionSummaryVm[]> {
    const value: object = await DshApiClient.call(ctx, 'session/list', '_request', null);
    const parsed: WireSessionListValue = value as WireSessionListValue;
    const items: WireSessionItem[] = parsed.items !== undefined && parsed.items !== null ? parsed.items : [];
    const out: SessionSummaryVm[] = [];
    for (let i: number = 0; i < items.length; i++) {
      const it: WireSessionItem = items[i];
      // 单条解析失败只跳过该条，绝不让整个列表失败
      try {
        // subagent 子会话无法独立访问（需父地址），其内容以工具调用形式出现在父会话中
        if (it.parentSessionId !== undefined && it.parentSessionId !== null && it.parentSessionId !== '') {
          continue;
        }
        // 归档会话过滤：兼容顶层 archived 与 sessionListMetadata 内的常见标记形态
        if (it.archived === true) {
          continue;
        }
        const proj: WireProjections = it.projections !== undefined && it.projections !== null
          ? it.projections : EMPTY_PROJ;
        const values: WireProjectionValues = proj.values !== undefined && proj.values !== null
          ? proj.values : EMPTY_VALUES;
        const meta: WireSessionListMeta | null = values.sessionListMetadata !== undefined && values.sessionListMetadata !== null
          ? values.sessionListMetadata : null;
        if ((meta !== null && (meta.archived === true || meta.hidden === true))) {
          continue;
        }
        const stats: WireSessionStats = values.sessionStats !== undefined && values.sessionStats !== null
          ? values.sessionStats : EMPTY_STATS;
        const outline: WireTurnOutlineItem[] = values.turnOutline !== undefined && values.turnOutline !== null
          ? values.turnOutline : [];
        let lastPrompt: string = '';
        if (outline.length > 0) {
          const p: string | undefined | null = outline[outline.length - 1].prompt;
          lastPrompt = DshSessionsRepository.truncate(DshSessionsRepository.cleanStr(p), LAST_PROMPT_MAX);
        }
        const summary: SessionSummaryVm = {
          sessionId: DshSessionsRepository.cleanStr(it.sessionId),
          title: DshSessionsRepository.titleOf(values),
          updatedAt: DshSessionsRepository.cleanNum(it.updatedAt),
          running: it.running === true,
          cwd: DshSessionsRepository.cleanStr(it.cwd),
          turns: DshSessionsRepository.cleanNum(stats.turns),
          lastPrompt: lastPrompt,
          asOfSeq: proj.asOfSeq !== undefined && proj.asOfSeq !== null ? proj.asOfSeq : -1,
          model: DshSessionsRepository.lastUsedModel(values),
        };
        out.push(summary);
      } catch (err) {
        continue;
      }
    }
    out.sort((a: SessionSummaryVm, b: SessionSummaryVm): number => b.updatedAt - a.updatedAt);
    return out;
  }

  /**
   * 拉取一页历史（seq 升序）。
   * @param throughSeq 游标上限；<0 时自动反查（先发超大值，从错误信息提取真实游标）
   * @param beforeSeq 只取此 seq 之前的一页；<0 表示从最新开始
   */
  static async loadHistory(ctx: common.Context, sessionId: string, throughSeq: number, beforeSeq: number): Promise<HistoryPageVm> {
    const address: WireAddress = { kind: 'session', sessionId: sessionId };
    const reqObj: WirePageRequest = {
      address: address,
      throughSeq: throughSeq > 0 ? throughSeq : 999999999,
      maxMessages: 50,
    };
    if (beforeSeq >= 0) {
      reqObj.beforeSeq = beforeSeq;
    }

    let value: object;
    try {
      value = await DshApiClient.call(ctx, 'session/page', 'request', reqObj);
    } catch (err) {
      // throughSeq 超限时网关报 "through seq X is past cursor N"：提取 N 重试一次
      const message: string = (err as BusinessError).message;
      const match: RegExpMatchArray | null = message.match(/past cursor (\d+)/);
      if (match !== null && match.length >= 2 && throughSeq <= 0) {
        reqObj.throughSeq = Number(match[1]);
        value = await DshApiClient.call(ctx, 'session/page', 'request', reqObj);
      } else if (err instanceof DshApiClientError) {
        throw err;
      } else {
        throw new DshApiClientError('network/error', message);
      }
    }

    const parsed: WireHistoryValue = value as WireHistoryValue;
    const records: WireRecord[] = parsed.records !== undefined && parsed.records !== null ? parsed.records : [];
    const entries: ChatEntryVm[] = [];
    const toolByCallId: Map<string, ChatEntryVm> = new Map<string, ChatEntryVm>();

    for (let i: number = 0; i < records.length; i++) {
      const rec: WireRecord = records[i];
      // 单条事件解析失败只跳过该条，不影响整页历史
      try {
        const ev: WireEvent | undefined | null = rec.event;
        if (ev === undefined || ev === null) {
          continue;
        }
        const type: string = DshSessionsRepository.cleanStr(ev.type);
        const seq: number = DshSessionsRepository.cleanNum(ev.seq, -1);
        const time: number = DshSessionsRepository.cleanNum(ev.time);
        const data: object = ev.data !== undefined && ev.data !== null ? ev.data : EMPTY_DATA;

      if (type === 'user/message') {
        const d: WireUserEventData = data as WireUserEventData;
        entries.push(DshSessionsRepository.entry(ChatEntryKind.User, seq, time, 0,
          DshSessionsRepository.joinBlocks(d.content, 'text'), '', 0, 0, '', null));
      } else if (type === 'assistant/message') {
        const d: WireAssistantEventData = data as WireAssistantEventData;
        const msg: WireAssistantMessage = d.message !== undefined && d.message !== null
          ? d.message : EMPTY_MSG;
        const usage: WireUsage = d.usage !== undefined && d.usage !== null
          ? d.usage : EMPTY_USAGE;
        const source: WireAssistantSource | null = msg.source !== undefined && msg.source !== null ? msg.source : null;
        entries.push(DshSessionsRepository.entry(ChatEntryKind.Assistant, seq, time,
          DshSessionsRepository.cleanNum(d.turn),
          DshSessionsRepository.joinBlocks(msg.content, 'text'),
          DshSessionsRepository.joinBlocks(msg.content, 'reasoning'),
          DshSessionsRepository.cleanNum(usage.inputTokens),
          DshSessionsRepository.cleanNum(usage.outputTokens),
          source === null ? '' : DshSessionsRepository.cleanStr(source.model),
          null));
      } else if (type === 'tool/call') {
        const d: WireToolCallData = data as WireToolCallData;
        const callId: string = DshSessionsRepository.cleanStr(d.callId);
        const tool: ToolCallVm = {
          callId: callId,
          name: DshSessionsRepository.cleanStr(d.name),
          arguments: DshSessionsRepository.truncate(DshSessionsRepository.cleanStr(d.arguments), RESULT_TEXT_MAX),
          resultText: '',
          turn: DshSessionsRepository.cleanNum(d.turn),
        };
        const entry: ChatEntryVm = DshSessionsRepository.entry(ChatEntryKind.Tool, seq, time, tool.turn, '', '', 0, 0, '', tool);
        entries.push(entry);
        if (callId !== '') {
          toolByCallId.set(callId, entry);
        }
      } else if (type === 'tool/result') {
        const d: WireToolResultData = data as WireToolResultData;
        const msg: WireToolResultMessage | null = d.message !== undefined && d.message !== null ? d.message : null;
        if (msg !== null) {
          const source: WireToolResultSource | null = msg.source !== undefined && msg.source !== null ? msg.source : null;
          const callId: string = source === null ? '' : DshSessionsRepository.cleanStr(source.callId);
          if (callId !== '' && toolByCallId.has(callId)) {
            const target: ChatEntryVm | undefined = toolByCallId.get(callId);
            if (target !== undefined && target.tool !== null) {
              const blocks: WireToolResultBlock[] = msg.content !== undefined && msg.content !== null ? msg.content : [];
              let result: string = '';
              for (let b: number = 0; b < blocks.length; b++) {
                const block: WireToolResultBlock | null = blocks[b] !== null ? blocks[b] : null;
                if (block === null) {
                  continue;
                }
                result += DshSessionsRepository.joinBlocks(block.content, 'text');
              }
              target.tool.resultText = DshSessionsRepository.truncate(result, RESULT_TEXT_MAX);
            }
          }
        }
      } else if (type === 'turn/start') {
        const d: WireTurnStartData = data as WireTurnStartData;
        const turn: number = DshSessionsRepository.cleanNum(d.turn);
        entries.push(DshSessionsRepository.entry(ChatEntryKind.Turn, seq, time, turn,
          '第 ' + turn + ' 轮', '', 0, 0, '', null));
      }
      // 其余事件类型（assistant/chunk、chunkrow/*、agent/inbox/*、step/*、
      // permission/*、sandbox/*、approval/*、request/*、web/*、session/* 杂项、turn/end）
      // 只读模式不需要，直接忽略。
      } catch (err) {
        continue;
      }
    }

    entries.sort((a: ChatEntryVm, b: ChatEntryVm): number => a.seq - b.seq);
    const page: HistoryPageVm = {
      entries: entries,
      hasMore: parsed.hasMore === true,
      oldestSeq: entries.length > 0 ? entries[0].seq : 0,
    };
    return page;
  }

  /**
   * 向指定会话发送一条消息（session/prompt，web 端同路径）。
   * 成功后消息进入 agent inbox，会话事件开始增长，调用方轮询历史即可看到回复。
   */
  static async sendText(ctx: common.Context, sessionId: string, text: string): Promise<void> {
    const part: WirePromptPart = { type: 'text', text: text };
    const req: WirePromptRequest = {
      requestId: 'app-' + Date.now().toString(16) + '-' + Math.floor(Math.random() * 100000000).toString(16),
      sessionId: sessionId,
      mode: 'queue',
      content: [part],
      clientTimeZone: 'Etc/GMT-8',
    };
    await DshApiClient.call(ctx, 'session/prompt', 'request', req);
  }

  /** 创建新会话，返回可立即用于 openSession 的摘要。 */
  static async createSession(ctx: common.Context): Promise<SessionSummaryVm> {
    const value: object = await DshApiClient.call(ctx, 'session/create', 'request', EMPTY_DATA);
    const parsed: WireCreateValue = value as WireCreateValue;
    const s: SessionSummaryVm = {
      sessionId: DshSessionsRepository.cleanStr(parsed.sessionId),
      title: '新会话',
      updatedAt: Date.now(),
      running: false,
      cwd: '',
      turns: 0,
      lastPrompt: '',
      asOfSeq: -1,
      model: '',
    };
    return s;
  }

  /** 拉取模型目录（session/modelCatalog，空 args）。 */
  static async modelCatalog(ctx: common.Context): Promise<CatalogVm> {
    const value: object = await DshApiClient.call(ctx, 'session/modelCatalog', '', null);
    const parsed: WireCatalogValue = value as WireCatalogValue;
    const groups: ModelGroupVm[] = [];
    const wireGroups: WireCatalogGroup[] = parsed.groups !== undefined && parsed.groups !== null ? parsed.groups : [];
    for (let i: number = 0; i < wireGroups.length; i++) {
      const g: WireCatalogGroup = wireGroups[i];
      const models: ModelItemVm[] = [];
      const wireModels: WireCatalogModel[] = g.models !== undefined && g.models !== null ? g.models : [];
      for (let j: number = 0; j < wireModels.length; j++) {
        const m: WireCatalogModel = wireModels[j];
        const id: string = DshSessionsRepository.cleanStr(m.id);
        const item: ModelItemVm = {
          id: id,
          name: DshSessionsRepository.cleanStr(m.name, id),
          description: DshSessionsRepository.cleanStr(m.description),
        };
        models.push(item);
      }
      const gid: string = DshSessionsRepository.cleanStr(g.id);
      const group: ModelGroupVm = {
        id: gid,
        name: DshSessionsRepository.cleanStr(g.name, gid),
        models: models,
      };
      groups.push(group);
    }
    const def: WireModelId | null = parsed.default !== undefined && parsed.default !== null ? parsed.default : null;
    const catalog: CatalogVm = {
      defaultModel: def === null ? '' : DshSessionsRepository.cleanStr(def.model),
      groups: groups,
    };
    return catalog;
  }

  /** 为会话切换模型（session/selectModel，实测通过）。 */
  static async selectModel(ctx: common.Context, sessionId: string, provider: string, model: string): Promise<void> {
    const req: WireSelectModel = {
      sessionId: sessionId,
      provider: provider,
      model: model,
    };
    await DshApiClient.call(ctx, 'session/selectModel', 'request', req);
  }

  /** 停止会话当前生成（session/cancel）。 */
  static async cancelSession(ctx: common.Context, sessionId: string): Promise<void> {
    const req: WireCancelRequest = {
      sessionId: sessionId,
    };
    await DshApiClient.call(ctx, 'session/cancel', 'request', req);
  }

  /** 会话重命名（session/rename）。 */
  static async renameSession(ctx: common.Context, sessionId: string, title: string): Promise<void> {
    const req: WireRenameRequest = {
      sessionId: sessionId,
      title: title,
    };
    await DshApiClient.call(ctx, 'session/rename', 'request', req);
  }

  /* ───────────── null/undefined 双防工具 ───────────── */

  /** 字符串取值：null/undefined 回退默认（默认空串）。 */
  private static cleanStr(v: string | undefined | null, fallback: string = ''): string {
    return v === undefined || v === null ? fallback : v;
  }

  /** 数值取值：null/undefined 回退默认（默认 0）。 */
  private static cleanNum(v: number | undefined | null, fallback: number = 0): number {
    return v === undefined || v === null ? fallback : v;
  }

  /** 会话最近使用的模型 ID（逐层防 null）。 */
  private static lastUsedModel(values: WireProjectionValues): string {
    const ms: WireModelSelection | null = values.modelSelection !== undefined && values.modelSelection !== null
      ? values.modelSelection : null;
    if (ms === null) {
      return '';
    }
    const lu: WireModelId | null = ms.lastUsed !== undefined && ms.lastUsed !== null ? ms.lastUsed : null;
    if (lu === null) {
      return '';
    }
    return DshSessionsRepository.cleanStr(lu.model);
  }

  /* ───────────── 其他私有工具 ───────────── */

  private static entry(kind: ChatEntryKind, seq: number, time: number, turn: number,
    text: string, reasoning: string, usageIn: number, usageOut: number, model: string,
    tool: ToolCallVm | null): ChatEntryVm {
    const e: ChatEntryVm = {
      kind: kind,
      seq: seq,
      time: time,
      turn: turn,
      text: text,
      reasoning: reasoning,
      usageIn: usageIn,
      usageOut: usageOut,
      model: model,
      tool: tool,
    };
    return e;
  }

  private static titleOf(values: WireProjectionValues): string {
    if (values.title !== undefined && values.title !== null && values.title !== '') {
      return values.title;
    }
    return '(未命名会话)';
  }

  private static joinBlocks(blocks: WireContentBlock[] | undefined | null, wantType: string): string {
    if (blocks === undefined || blocks === null) {
      return '';
    }
    let out: string = '';
    for (let i: number = 0; i < blocks.length; i++) {
      const block: WireContentBlock | null = blocks[i] !== null ? blocks[i] : null;
      if (block === null) {
        continue;
      }
      if (block.type === wantType && block.text !== undefined && block.text !== null) {
        out += block.text;
      }
    }
    return out;
  }

  private static truncate(text: string, max: number): string {
    if (text.length <= max) {
      return text;
    }
    return text.substring(0, max) + '…';
  }
}
