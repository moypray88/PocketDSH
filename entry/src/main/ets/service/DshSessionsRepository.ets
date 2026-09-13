/** 会话仓库：session/list 与 session/page 的 wire 解析，产出视图模型。 */
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { DshApiClient, DshApiClientError } from './DshApiClient';
import { DshStreamClient } from './DshStreamClient';
import { CatalogVm, ChatEntryKind, ChatEntryVm, HistoryPageVm, ModelGroupVm, ModelItemVm, PresetItemVm, SessionSummaryVm, ToolCallVm, WorkspaceBaselineVm, WorkspaceVm } from '../model/SessionVms';

/* ───────────── wire 形状（宽松解析；字段可缺省也可为显式 null） ───────────── */

/** session/list 的 value。 */
interface WireSessionListValue {
  items?: WireSessionItem[];
}

/* ───────────── workspace/follow 基线 wire 形状 ───────────── */

interface WireWorkspaceView {
  workspaceId?: string;
  path?: string;
  title?: string;
  sessionIds?: string[];
}

interface WireWorkspaceBaselineValue {
  items?: WireWorkspaceView[];
  archivedSessionIds?: string[];
}

/** session/list 单项。 */
interface WireSessionItem {
  sessionId?: string;
  updatedAt?: number;
  running?: boolean;
  /** 空会话（尚无任何轮次）：web 端列表不显示，仅保留当前选中的占位行。 */
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

/** 内容块（text / reasoning / image）。 */
interface WireContentBlock {
  type?: string;
  text?: string;
  /** image 块携带的附件引用（attachmentId 取图凭据）。 */
  attachment?: WireImageAttachment;
}

/** 图片附件引用（源码 ImageAttachmentRef，attachmentId 永远不是文件路径）。 */
interface WireImageAttachment {
  attachmentId?: string;
  mediaType?: string;
  bytes?: number;
  width?: number;
  height?: number;
  name?: string;
}

/** user/message 的来源标识。 */
interface WireUserSource {
  kind?: string;
}

/** user/message 的 data。 */
interface WireUserEventData {
  content?: WireContentBlock[];
  source?: WireUserSource;
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

/** turn/end 的 data（失败详情在 reason 里，失败轮次没有 assistant/message）。 */
interface WireTurnEndEventData {
  turn?: number;
  reason?: WireTurnEndReasonData;
}

/** turn/end 的 reason：completed/blocked/max-tokens/interrupted/aborted/error。 */
interface WireTurnEndReasonData {
  kind?: string;
  error?: WireLlmFailureData;
  reason?: WireAbortCauseData;
}

/** llm 失败详情（code+message 必有，源码 llmFailureValue）。 */
interface WireLlmFailureData {
  code?: string;
  message?: string;
  status?: number;
}

/** aborted 的中止原因。 */
interface WireAbortCauseData {
  kind?: string;
}

/** session/create 的请求（源码类型 SessionCreateRequest：workspaceId 与 cwd 互斥，前者才会归组到工作区）。 */
interface WireCreateRequest {
  workspaceId?: string;
  cwd?: string;
}

/** session/create 的返回。 */
interface WireCreateValue {
  sessionId?: string;
  agentPreset?: string;
}

/** session/prompt 的内容块（文本 + 图片内嵌）。 */
interface WirePromptPart {
  type: string;
  text?: string;
  mediaType?: string;
  data?: string;
  name?: string;
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

/** agentPresets/list 的返回行（源码类型 AgentPresetRow；broken 行不可选）。 */
interface WirePresetRow {
  id?: string;
  name?: string;
  description?: string;
  isDefault?: boolean;
  broken?: string;
}

/** agentPresets/list 的返回（源码类型 AgentPresetRoster）。 */
interface WirePresetRoster {
  presets?: WirePresetRow[];
}

/** agentPresets/select 的请求（named wire args 直传，参数名即键）。 */
interface WirePresetSelectRequest {
  agent: string;
  agentPreset: string;
}

/** session/readImage 的返回（按工作区白名单路径取图）。 */
interface WireReadImageValue {
  mediaType?: string;
  bytes?: number;
  data?: string;
}

/** session/attachment 的返回（按附件引用取图）。 */
interface WireAttachmentValue {
  attachment?: WireImageAttachment;
  data?: string;
}

/** 取图结果：mediaType + base64（不含 data: 前缀）。 */
export interface ImageDataVm {
  mediaType: string;
  base64: string;
}

/** session/readImage 的请求。 */
interface WireReadImageRequest {
  path: string;
}

/** session/attachment 的请求（源码类型 SessionAttachmentRequest）。 */
interface WireAttachmentRequest {
  sessionId: string;
  attachmentId: string;
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
        // blank 会话与 web 端一致：不出现在列表（web 仅保留当前选中的新会话占位行）
        if (it.blank === true) {
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
   * 拉取工作区基线（workspace/follow 首帧）：工作区列表 + 全局归档集。
   * WS 不可用时返回 null，调用方退化为平铺列表且不做归档过滤。
   * @param force true 跳过客户端缓存强制拉取（手动 ⟳）
   */
  static async workspaceBaseline(ctx: common.Context, force: boolean): Promise<WorkspaceBaselineVm | null> {
    const raw: object | null = await DshStreamClient.fetchWorkspaceFollowBaseline(ctx, force);
    if (raw === null) {
      return null;
    }
    const parsed: WireWorkspaceBaselineValue = raw as WireWorkspaceBaselineValue;
    const workspaces: WorkspaceVm[] = [];
    const items: WireWorkspaceView[] = parsed.items !== undefined && parsed.items !== null ? parsed.items : [];
    for (let i: number = 0; i < items.length; i++) {
      const it: WireWorkspaceView = items[i];
      const wid: string = DshSessionsRepository.cleanStr(it.workspaceId);
      if (wid === '') {
        continue;
      }
      const ids: string[] = [];
      const rawIds: string[] = it.sessionIds !== undefined && it.sessionIds !== null ? it.sessionIds : [];
      for (let j: number = 0; j < rawIds.length; j++) {
        const sid: string = DshSessionsRepository.cleanStr(rawIds[j]);
        if (sid !== '') {
          ids.push(sid);
        }
      }
      const w: WorkspaceVm = {
        workspaceId: wid,
        title: DshSessionsRepository.cleanStr(it.title, wid),
        path: DshSessionsRepository.cleanStr(it.path),
        sessionIds: ids,
      };
      workspaces.push(w);
    }
    const archived: string[] = [];
    const rawArchived: string[] = parsed.archivedSessionIds !== undefined && parsed.archivedSessionIds !== null
      ? parsed.archivedSessionIds : [];
    for (let i: number = 0; i < rawArchived.length; i++) {
      const sid: string = DshSessionsRepository.cleanStr(rawArchived[i]);
      if (sid !== '') {
        archived.push(sid);
      }
    }
    const base: WorkspaceBaselineVm = {
      workspaces: workspaces,
      archivedSessionIds: archived,
    };
    return base;
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
    // 生成中判定：存在晚于最后一条 user/assistant 消息的 chunk 流事件
    let maxContentSeq: number = -1;
    let maxChunkSeq: number = -1;
    // 最近一条 turn/end：失败轮次的 chunk 不会被压缩成 chunkrow，
    // 若只比 chunk 与 content 的先后会把已结束（尤其失败）的轮次误判为生成中
    let maxTurnEndSeq: number = -1;

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
        if (seq > maxContentSeq) {
          maxContentSeq = seq;
        }
        const d: WireUserEventData = data as WireUserEventData;
        // 只渲染真人消息：插件上下文（plugin）与技能目录（skill-catalog）等
        // 系统注入的伪用户消息不渲染，否则问题与回复之间会出现大段"空白墙"
        const src: WireUserSource | null = d.source !== undefined && d.source !== null ? d.source : null;
        const kind: string = src === null ? '' : DshSessionsRepository.cleanStr(src.kind);
        const joined: string = DshSessionsRepository.joinBlocks(d.content, 'text');
        const isHuman: boolean = kind === 'user'
          || (kind === '' && !joined.startsWith('<system-reminder>') && !joined.startsWith('Current runtime context.'));
        if (!isHuman) {
          continue;
        }
        entries.push(DshSessionsRepository.entry(ChatEntryKind.User, seq, time, 0,
          joined, '', 0, 0, '', null, DshSessionsRepository.collectImageIds(d.content)));
      } else if (type === 'assistant/message') {
        const d: WireAssistantEventData = data as WireAssistantEventData;
        const msg: WireAssistantMessage = d.message !== undefined && d.message !== null
          ? d.message : EMPTY_MSG;
        const usage: WireUsage = d.usage !== undefined && d.usage !== null
          ? d.usage : EMPTY_USAGE;
        const source: WireAssistantSource | null = msg.source !== undefined && msg.source !== null ? msg.source : null;
        const stepText: string = DshSessionsRepository.joinBlocks(msg.content, 'text');
        const stepReasoning: string = DshSessionsRepository.joinBlocks(msg.content, 'reasoning');
        // 工具步骤的空消息（无正文无思考）不渲染卡片，避免"你好"与回复之间出现成片空白
        if (stepText === '' && stepReasoning === '') {
          continue;
        }
        if (seq > maxContentSeq) {
          maxContentSeq = seq;
        }
        entries.push(DshSessionsRepository.entry(ChatEntryKind.Assistant, seq, time,
          DshSessionsRepository.cleanNum(d.turn),
          stepText,
          stepReasoning,
          DshSessionsRepository.cleanNum(usage.inputTokens),
          DshSessionsRepository.cleanNum(usage.outputTokens),
          source === null ? '' : DshSessionsRepository.cleanStr(source.model),
          null, DshSessionsRepository.collectImageIds(msg.content)));
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
        const entry: ChatEntryVm = DshSessionsRepository.entry(ChatEntryKind.Tool, seq, time, tool.turn, '', '', 0, 0, '', tool, []);
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
          '第 ' + turn + ' 轮', '', 0, 0, '', null, []));
      } else if (type === 'turn/end') {
        // 失败轮次没有 assistant/message，错误详情只在 turn/end 的 reason 里——
        // 不解析的话失败在手机端完全不可见（web 端有"本轮运行失败"红条）
        const d: WireTurnEndEventData = data as WireTurnEndEventData;
        const reasonObj: WireTurnEndReasonData | undefined | null = d.reason;
        let reasonKind: string = reasonObj !== undefined && reasonObj !== null
          && reasonObj.kind !== undefined && reasonObj.kind !== null ? reasonObj.kind : 'completed';
        let code: string = '';
        let message: string = '';
        if (reasonKind === 'error' && reasonObj !== undefined && reasonObj !== null) {
          const failure: WireLlmFailureData | undefined | null = reasonObj.error;
          if (failure !== undefined && failure !== null) {
            code = DshSessionsRepository.cleanStr(failure.code);
            message = DshSessionsRepository.cleanStr(failure.message);
          }
        } else if (reasonKind === 'aborted' && reasonObj !== undefined && reasonObj !== null
          && reasonObj.reason !== undefined && reasonObj.reason !== null) {
          reasonKind = 'aborted/' + DshSessionsRepository.cleanStr(reasonObj.reason.kind, '?');
        }
        if (reasonKind !== 'completed') {
          let text: string = '生成失败：' + message;
          if (text.length < 12) {
            text = '生成失败（' + reasonKind + '）';
          }
          if (code !== '') {
            text += ' [' + code + ']';
          }
          entries.push(DshSessionsRepository.entry(ChatEntryKind.Error, seq, time, 0,
            text, '', 0, 0, '', null, []));
        }
        if (seq > maxTurnEndSeq) {
          maxTurnEndSeq = seq;
        }
      } else if (type.indexOf('chunk') >= 0) {
        if (seq > maxChunkSeq) {
          maxChunkSeq = seq;
        }
      }
      // 其余事件类型（assistant/chunk、chunkrow/*、agent/inbox/*、step/*、
      // permission/*、sandbox/*、approval/*、request/*、web/*、session/* 杂项）
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
      generating: maxChunkSeq > maxContentSeq && maxChunkSeq > maxTurnEndSeq,
    };
    return page;
  }

  /**
   * 向指定会话发送一条消息（session/prompt，web 端同路径）。
   * @param imageBase64 图片的 base64（不含 data: 前缀）；空串表示纯文本
   * @param imageMediaType 如 'image/png' / 'image/jpeg'
   * @param imageName 原始文件名（可选）
   */
  static async sendText(ctx: common.Context, sessionId: string, text: string,
    imageBase64: string, imageMediaType: string, imageName: string): Promise<void> {
    const parts: WirePromptPart[] = [];
    const textPart: WirePromptPart = { type: 'text', text: text };
    parts.push(textPart);
    if (imageBase64 !== '') {
      const imgPart: WirePromptPart = {
        type: 'image',
        mediaType: imageMediaType,
        data: imageBase64,
        name: imageName,
      };
      parts.push(imgPart);
    }
    const req: WirePromptRequest = {
      requestId: 'app-' + Date.now().toString(16) + '-' + Math.floor(Math.random() * 100000000).toString(16),
      sessionId: sessionId,
      mode: 'queue',
      content: parts,
      clientTimeZone: 'Etc/GMT-8',
    };
    await DshApiClient.call(ctx, 'session/prompt', 'request', req);
  }

  /**
   * 创建新会话（延迟创建策略：仅在用户发出第一条消息时调用）。
   * workspaceId 非空时优先（服务器以工作区 path 为 cwd 并把会话归入该工作区）；
   * cwd 仅在无 workspaceId 时生效；两者都为空串表示服务器默认目录。
   * @param workspaceId 工作区 ID（归组凭据，服务端与 cwd 互斥）
   * @param cwd 工作目录（无工作区时的手动指定）
   * @param workspacePath 工作区路径（仅用于回显，可传空串）
   */
  static async createSession(ctx: common.Context, workspaceId: string, cwd: string,
    workspacePath: string): Promise<SessionSummaryVm> {
    let reqObj: object = EMPTY_DATA;
    if (workspaceId !== '') {
      const req: WireCreateRequest = { workspaceId: workspaceId };
      reqObj = req;
    } else if (cwd !== '') {
      const req: WireCreateRequest = { cwd: cwd };
      reqObj = req;
    }
    const value: object = await DshApiClient.call(ctx, 'session/create', 'request', reqObj);
    const parsed: WireCreateValue = value as WireCreateValue;
    const s: SessionSummaryVm = {
      sessionId: DshSessionsRepository.cleanStr(parsed.sessionId),
      title: '新会话',
      updatedAt: Date.now(),
      running: false,
      cwd: workspaceId !== '' ? workspacePath : cwd,
      turns: 0,
      lastPrompt: '',
      asOfSeq: -1,
      model: '',
    };
    return s;
  }

  /**
   * 按服务器本地路径读取图片文件（session/readImage；服务端限定已注册工作区目录内）。
   * @param path 服务器上的图片绝对路径
   */
  static async readImage(ctx: common.Context, path: string): Promise<ImageDataVm> {
    const req: WireReadImageRequest = { path: path };
    const value: object = await DshApiClient.call(ctx, 'session/readImage', 'request', req);
    const parsed: WireReadImageValue = value as WireReadImageValue;
    return {
      mediaType: DshSessionsRepository.cleanStr(parsed.mediaType, 'image/png'),
      base64: DshSessionsRepository.cleanStr(parsed.data),
    };
  }

  /**
   * 按附件引用读取消息内图片（session/attachment；服务端校验该会话日志引用过此附件）。
   * @param sessionId 图片所属会话（授权凭据）
   * @param attachmentId image 块里的附件 ID
   */
  static async readAttachment(ctx: common.Context, sessionId: string, attachmentId: string): Promise<ImageDataVm> {
    const req: WireAttachmentRequest = { sessionId: sessionId, attachmentId: attachmentId };
    const value: object = await DshApiClient.call(ctx, 'session/attachment', 'request', req);
    const parsed: WireAttachmentValue = value as WireAttachmentValue;
    const ref: WireImageAttachment = parsed.attachment !== undefined && parsed.attachment !== null
      ? parsed.attachment : {};
    return {
      mediaType: DshSessionsRepository.cleanStr(ref.mediaType, 'image/png'),
      base64: DshSessionsRepository.cleanStr(parsed.data),
    };
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

  /**
   * 拉取 Agent 预设名单（agentPresets/list，空 args；web 端「模式」选择同构）。
   * broken 行（组合不可用）不进入可选列表。
   */
  static async presetRoster(ctx: common.Context): Promise<PresetItemVm[]> {
    const value: object = await DshApiClient.call(ctx, 'agentPresets/list', '', null);
    const parsed: WirePresetRoster = value as WirePresetRoster;
    const rows: WirePresetRow[] = parsed.presets !== undefined && parsed.presets !== null ? parsed.presets : [];
    const items: PresetItemVm[] = [];
    for (let i: number = 0; i < rows.length; i++) {
      const r: WirePresetRow = rows[i];
      const id: string = DshSessionsRepository.cleanStr(r.id);
      if (id === '' || DshSessionsRepository.cleanStr(r.broken) !== '') {
        continue;
      }
      const item: PresetItemVm = {
        id: id,
        name: DshSessionsRepository.cleanStr(r.name, id),
        description: DshSessionsRepository.cleanStr(r.description),
        isDefault: r.isDefault === true,
      };
      items.push(item);
    }
    return items;
  }

  /** 为空白会话应用 Agent 预设（agentPresets/select；仅首条消息前可用，之后报 agent-preset/locked）。 */
  static async presetSelect(ctx: common.Context, sessionId: string, presetId: string): Promise<void> {
    const req: WirePresetSelectRequest = {
      agent: sessionId,
      agentPreset: presetId,
    };
    await DshApiClient.call(ctx, 'agentPresets/select', '', req);
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
    tool: ToolCallVm | null, images: string[]): ChatEntryVm {
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
      images: images,
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

  /** 收集 image 块的 attachmentId（保持出现顺序，跳过缺 id 的块）。 */
  private static collectImageIds(blocks: WireContentBlock[] | undefined | null): string[] {
    if (blocks === undefined || blocks === null) {
      return [];
    }
    const out: string[] = [];
    for (let i: number = 0; i < blocks.length; i++) {
      const block: WireContentBlock | null = blocks[i] !== null ? blocks[i] : null;
      if (block === null || block.type !== 'image' || block.attachment === undefined || block.attachment === null) {
        continue;
      }
      const id: string = DshSessionsRepository.cleanStr(block.attachment.attachmentId);
      if (id !== '') {
        out.push(id);
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
