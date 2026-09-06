/** dsh WebSocket 流客户端：/api/remote.mux 复用通道上的 session/follow 实时事件。 */
import webSocket from '@ohos.net.webSocket';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { DshApiClient, DshWsConnectInfo } from './DshApiClient';

/** 流式诊断日志标签（hilog 过滤：hilog | grep PocketDSH_WS）。 */
const WS_TAG: string = 'PocketDSH_WS';

/**
 * 流事件监听器：DshStreamClient 把 wire 帧归一化后的高层回调（主线程调用）。
 * 事件序号语义与会话历史一致：view 按 seq 去重，chunk 增量无序号语义。
 */
export interface DshStreamListener {
  /** follow 开仓快照：cursor 为当前游标（= session/page 的 throughSeq 上限）。 */
  onSnapshot(cursor: number): void;
  /** 真人用户消息（source.kind==='user'）。 */
  onUserMessage(seq: number, time: number, text: string): void;
  /** 助手流式增量：kind 'text' | 'reasoning'，text 为追加内容。 */
  onLiveDelta(kind: string, text: string): void;
  /** 块结束（block-end）：权威整块内容，view 用它替换增量缓冲。 */
  onLiveBlock(kind: string, fullText: string): void;
  /** 生成用量（usage chunk）。 */
  onLiveUsage(inputTokens: number, outputTokens: number): void;
  /** 助手消息结算（assistant/message）：终结流式卡，view 按 seq 去重后转正条目。 */
  onAssistantMessage(seq: number, time: number, turn: number, text: string,
    reasoning: string, usageIn: number, usageOut: number, model: string): void;
  /** 工具调用。 */
  onToolCall(seq: number, time: number, turn: number, callId: string, name: string, args: string): void;
  /** 工具结果（按 callId 配对回填）。 */
  onToolResult(callId: string, resultText: string): void;
  /** 轮次开始（turn/start）。 */
  onTurnStart(seq: number, time: number, turn: number): void;
  /**
   * 轮次结束（turn/end）。reasonKind: completed/blocked/max-tokens/interrupted/
   * aborted/error；非 completed 时 failureCode/failureMessage 携带失败详情
   * （llmFailure：code+message）。live=false 表示来自 snapshot 重放。
   */
  onTurnEnd(seq: number, time: number, reasonKind: string, failureCode: string, failureMessage: string, live: boolean): void;
  /** 会话标题变化（session/title）。 */
  onTitleChanged(title: string): void;
  /** 传输层断开（含流级错误）；view 可降级为轮询。 */
  onStreamDown(): void;
}

/* ───────────── 出站帧形状 ───────────── */

interface WireAddress {
  kind: string;
  sessionId: string;
}

interface WireFollowRequest {
  address: WireAddress;
  maxMessages: number;
  assistantStream: boolean;
}

interface WireOpenArgs {
  request: WireFollowRequest;
}

interface WireOpenPayload {
  args: WireOpenArgs;
}

interface WireOpenFrame {
  type: string;
  streamId: string;
  endpoint: string;
  payload: WireOpenPayload;
}

interface WireCancelFrame {
  type: string;
  streamId: string;
}

/* ───────────── 入站帧形状（宽松解析：字段可缺省可显式 null） ───────────── */

interface WireMuxError {
  code?: string;
  message?: string;
}

interface WireMuxFrame {
  type?: string;
  streamId?: string;
  value?: object;
  error?: WireMuxError;
}

interface WireBlock {
  type?: string;
  text?: string;
}

interface WireUsage {
  inputTokens?: number;
  outputTokens?: number;
}

/** item.value 通用形状。 */
interface WireItemValue {
  type?: string;
}

/** snapshot 帧。 */
interface WireSnapshotValue {
  type?: string;
  cursor?: number;
  records?: object[];
}

/** event 帧。 */
interface WireEventValue {
  type?: string;
  event?: WireEvent;
}

/** 持久事件。 */
interface WireEvent {
  type?: string;
  seq?: number;
  time?: number;
  data?: object;
}

/** 历史记录包裹。 */
interface WireRecordWrap {
  event?: WireEvent;
}

/** user/message data。 */
interface WireUserEventData {
  content?: WireBlock[];
  source?: WireUserSource;
}

interface WireUserSource {
  kind?: string;
}

/** assistant/message data。 */
interface WireAssistantEventData {
  turn?: number;
  message?: WireAssistantMessage;
  usage?: WireUsage;
}

interface WireAssistantMessage {
  content?: WireBlock[];
  source?: WireAssistantSource;
}

interface WireAssistantSource {
  model?: string;
}

/** assistant/chunk data。 */
interface WireChunkEventData {
  turn?: number;
  step?: number;
  chunk?: WireChunkBody;
}

/** chunk 原始体（v1 wire：block-start / delta / block-end / usage / finish）。 */
interface WireChunkBody {
  type?: string;
  index?: number;
  blockType?: string;
  text?: string;
  block?: WireBlock;
  usage?: WireUsage;
}

/** chunkrow/text-chunks、chunkrow/reasoning-chunks data（压缩历史行）。 */
interface WireChunkRowData {
  turn?: number;
  step?: number;
  index?: number;
  texts?: string[];
}

/** tool/call data。 */
interface WireToolCallData {
  turn?: number;
  callId?: string;
  name?: string;
  arguments?: string;
}

/** tool/result data。 */
interface WireToolResultData {
  message?: WireToolResultMessage;
}

interface WireToolResultMessage {
  source?: WireToolResultSource;
  content?: WireToolResultBlock[];
}

interface WireToolResultSource {
  callId?: string;
}

interface WireToolResultBlock {
  content?: WireBlock[];
}

/** turn/start、turn/end data。 */
interface WireTurnData {
  turn?: number;
  /** 仅 turn/end 携带。 */
  reason?: WireTurnEndReason;
}

/** turn/end 的 reason。 */
interface WireTurnEndReason {
  kind?: string;
  error?: WireLlmFailure;
  reason?: WireAbortCause;
}

/** llm 失败详情（code+message 必有）。 */
interface WireLlmFailure {
  code?: string;
  message?: string;
  status?: number;
}

/** aborted 的中止原因。 */
interface WireAbortCause {
  kind?: string;
  reason?: string;
}

/** session/title data。 */
interface WireTitleData {
  title?: string;
}

/** assistant-stream 帧（v2 服务器，向前兼容）。 */
interface WireStreamValue {
  type?: string;
  frame?: WireV2Frame;
}

interface WireV2Frame {
  type?: string;
  chunk?: WireChunkBody;
  outcome?: WireV2Outcome;
}

interface WireV2Outcome {
  kind?: string;
}

/* ───────────── workspace/follow 基线（一次性拉取，临时连接） ───────────── */

interface WireWorkspaceOpenFrame {
  type: string;
  streamId: string;
  endpoint: string;
  payload: Record<string, Object>;
}

interface WireWorkspaceView {
  workspaceId?: string;
  path?: string;
  title?: string;
  sessionIds?: string[];
}

/** item.value = {type:'baseline', value:{items, archivedSessionIds}}。 */
interface WireWorkspaceItemValue {
  type?: string;
  value?: object;
}

interface WireWorkspaceBaseline {
  items?: WireWorkspaceView[];
  archivedSessionIds?: string[];
}

const LIVE_RECONNECT_BASE_MS: number = 1500;
const LIVE_RECONNECT_MAX_MS: number = 15000;
/** workspace 基线缓存有效期：列表页 30s 轮询复用结果，不重复开临时连接。 */
const WORKSPACE_BASELINE_TTL_MS: number = 60000;
/** workspace 基线单次连接超时。 */
const WORKSPACE_BASELINE_TIMEOUT_MS: number = 8000;

/** 空对象兜底（arkts-no-untyped-obj-literals 要求字面量有类型锚点）。 */
const EMPTY_DATA: Record<string, Object> = {};

/**
 * DshStreamClient：单连接复用通道。attach() 绑定当前会话并打开 session/follow；
 * 断线自动重连（指数退避，重连后由 snapshot 重放补齐缺口）。detach() 关闭连接。
 * 服务器版本兼容：v1（实时 chunk 为持久 assistant/chunk 事件）与 v2（assistant-stream
 * 活帧）两种形态都归一化到同一组回调。
 */
export class DshStreamClient {
  /**
   * 诊断开关：诊断已完成，根因是显式 Origin 与 netstack 自动 Origin 合并导致
   * dsh Origin 校验拒绝（非 101），修复 = 不传显式 Origin。保留开关备用。
   */
  private static readonly DEBUG_LOCAL_WS: boolean = false;
  private static socket: webSocket.WebSocket | null = null;
  private static connecting: boolean = false;
  private static wantConnected: boolean = false;
  /** snapshot 已到达：follow 流真正建立。 */
  private static snapshotSeen: boolean = false;
  private static appCtx: common.Context | null = null;
  private static sessionId: string = '';
  private static streamId: string = '';
  private static listener: DshStreamListener | null = null;
  private static retryAttempt: number = 0;
  private static retryTimer: number = -1;
  /** 块序号 → 块类型（'text' | 'reasoning'），delta 按块归类。 */
  private static blockKinds: Map<number, string> = new Map<number, string>();
  /** snapshot 重放中：增量暂存客户端缓冲，重放结束按"是否仍在生成"决定交付或丢弃。 */
  private static replaying: boolean = false;
  private static replayText: string = '';
  private static replayReasoning: string = '';
  private static replayMaxChunkSeq: number = -1;
  private static replayMaxContentSeq: number = -1;
  private static replayMaxTurnEndSeq: number = -1;
  /** 流式增量诊断计数（自 follow 起）。 */
  private static deltaCount: number = 0;
  private static deltaChars: number = 0;

  /** 绑定会话并建立 follow 流（幂等；同一会话重复 attach 只更新监听器）。 */
  static attach(ctx: common.Context, sessionId: string, listener: DshStreamListener): void {
    DshStreamClient.listener = listener;
    DshStreamClient.appCtx = ctx;
    if (DshStreamClient.sessionId !== sessionId) {
      DshStreamClient.sessionId = sessionId;
      DshStreamClient.blockKinds.clear();
      DshStreamClient.snapshotSeen = false;
      // 换会话：旧流在服务端仍在推，先取消
      DshStreamClient.cancelStream();
    }
    DshStreamClient.wantConnected = true;
    if (DshStreamClient.socket === null && !DshStreamClient.connecting) {
      DshStreamClient.connect();
    } else if (DshStreamClient.socket !== null && DshStreamClient.snapshotSeen === false
      && DshStreamClient.streamId !== '') {
      // 连接在但流未建立（attach 竞态）：补发 open
      DshStreamClient.sendFollow();
    }
  }

  /** 解绑并关闭连接（离开会话页调用）。 */
  static detach(): void {
    DshStreamClient.wantConnected = false;
    DshStreamClient.listener = null;
    DshStreamClient.sessionId = '';
    DshStreamClient.snapshotSeen = false;
    if (DshStreamClient.retryTimer >= 0) {
      clearTimeout(DshStreamClient.retryTimer);
      DshStreamClient.retryTimer = -1;
    }
    DshStreamClient.cancelStream();
    const s: webSocket.WebSocket | null = DshStreamClient.socket;
    DshStreamClient.socket = null;
    DshStreamClient.connecting = false;
    if (s !== null) {
      try {
        s.close().catch((err: BusinessError) => {
        });
      } catch (err) {
      }
    }
  }

  /** follow 流是否健康（连接建立且 snapshot 已到达）。 */
  static isAlive(): boolean {
    return DshStreamClient.wantConnected && DshStreamClient.socket !== null && DshStreamClient.snapshotSeen;
  }

  /* ───────────── workspace/follow 基线（独立临时连接，与会话 follow 互不影响） ───────────── */

  private static baselineCache: object | null = null;
  private static baselineAt: number = 0;
  private static baselineInFlight: Promise<object | null> | null = null;

  /**
   * 拉取 workspace/follow 首帧 baseline（原始 wire，由仓库层解析）。
   * 独立开一条临时 WS 连接，拿到基线即关闭；TTL 内复用缓存（force 旁路）。
   * 任何失败返回 null（调用方退化为平铺列表），绝不抛出。
   */
  static async fetchWorkspaceFollowBaseline(ctx: common.Context, force: boolean): Promise<object | null> {
    const now: number = Date.now();
    if (!force && DshStreamClient.baselineCache !== null
      && now - DshStreamClient.baselineAt < WORKSPACE_BASELINE_TTL_MS) {
      hilog.info(0x0000, WS_TAG, 'wsb cache hit age=' + (now - DshStreamClient.baselineAt));
      return DshStreamClient.baselineCache;
    }
    if (DshStreamClient.baselineInFlight !== null) {
      return DshStreamClient.baselineInFlight;
    }
    DshStreamClient.baselineInFlight = DshStreamClient.doFetchBaseline(ctx);
    const result: object | null = await DshStreamClient.baselineInFlight;
    DshStreamClient.baselineInFlight = null;
    DshStreamClient.baselineAt = Date.now();
    if (result !== null) {
      DshStreamClient.baselineCache = result;
    }
    return result;
  }

  private static async doFetchBaseline(ctx: common.Context): Promise<object | null> {
    hilog.info(0x0000, WS_TAG, 'wsb fetch begin');
    let info: DshWsConnectInfo;
    try {
      info = await DshApiClient.wsConnectInfo(ctx);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(0x0000, WS_TAG, 'wsb wsConnectInfo failed: ' + e.code + ' ' + e.message);
      return null;
    }
    return new Promise<object | null>((resolve: (v: object | null) => void) => {
      let done: boolean = false;
      let ws: webSocket.WebSocket | null = null;
      const streamId: string = 'pdsh-wsb-' + Date.now().toString(16);
      const finish = (value: object | null, why: string): void => {
        if (done) {
          return;
        }
        done = true;
        hilog.info(0x0000, WS_TAG, 'wsb finish ' + why);
        if (ws !== null) {
          try {
            ws.close().catch((closeErr: BusinessError) => {
            });
          } catch (err) {
          }
        }
        resolve(value);
      };
      const timer: number = setTimeout(() => {
        finish(null, 'timeout');
      }, WORKSPACE_BASELINE_TIMEOUT_MS);
      ws = webSocket.createWebSocket();
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err || typeof value !== 'string') {
          return;
        }
        let frame: WireMuxFrame;
        try {
          frame = JSON.parse(value) as WireMuxFrame;
        } catch (e) {
          return;
        }
        if (frame === undefined || frame === null || frame.streamId !== streamId) {
          return;
        }
        if (frame.type === 'item' && frame.value !== undefined && frame.value !== null) {
          const v: WireWorkspaceItemValue = frame.value as WireWorkspaceItemValue;
          if (v.type === 'baseline' && v.value !== undefined && v.value !== null) {
            clearTimeout(timer);
            finish(v.value, 'baseline');
          }
        } else if (frame.type === 'error' || frame.type === 'end') {
          const code: string = frame.error !== undefined && frame.error !== null
            && frame.error.code !== undefined && frame.error.code !== null ? frame.error.code : '';
          clearTimeout(timer);
          finish(null, 'stream ' + frame.type + ' ' + code);
        }
      });
      ws.on('error', (err: BusinessError) => {
        hilog.error(0x0000, WS_TAG, 'wsb ws error ' + err.code + ' ' + err.message);
        clearTimeout(timer);
        finish(null, 'ws error');
      });
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        if (!done) {
          clearTimeout(timer);
          finish(null, 'ws close ' + value.code);
        }
      });
      const options: webSocket.WebSocketRequestOptions = {
        header: info.headers,
      };
      ws.connect(DshStreamClient.wsUrlOf(info.serverUrl), options, (err: BusinessError, ok: boolean) => {
        if (done) {
          return;
        }
        if (err || ok !== true || ws === null) {
          const code: number = err !== undefined && err !== null ? err.code : -1;
          const msg: string = err !== undefined && err !== null ? err.message : 'ok=false';
          hilog.error(0x0000, WS_TAG, 'wsb connect failed: ' + code + ' ' + msg);
          clearTimeout(timer);
          finish(null, 'connect failed');
          return;
        }
        hilog.info(0x0000, WS_TAG, 'wsb connected, opening workspace/follow');
        const args: Record<string, Object> = {};
        const payload: Record<string, Object> = { 'args': args };
        const frame: WireWorkspaceOpenFrame = {
          type: 'open',
          streamId: streamId,
          endpoint: 'workspace/follow',
          payload: payload,
        };
        try {
          ws.send(JSON.stringify(frame)).catch((sendErr: BusinessError) => {
            hilog.error(0x0000, WS_TAG, 'wsb open send failed: ' + sendErr.code);
          });
        } catch (err2) {
          clearTimeout(timer);
          finish(null, 'open send threw');
        }
      });
    });
  }

  /* ───────────── 连接管理 ───────────── */

  private static wsUrlOf(serverUrl: string): string {
    // 诊断模式：握手打到本机（经 hdc rport 转发到 PC），PC 侧记录原始请求头
    if (DshStreamClient.DEBUG_LOCAL_WS) {
      return 'ws://127.0.0.1:3092/api/remote.mux';
    }
    let url: string = serverUrl;
    if (url.indexOf('https://') === 0) {
      url = 'wss://' + url.substring(8);
    } else if (url.indexOf('http://') === 0) {
      url = 'ws://' + url.substring(7);
    }
    return url + '/api/remote.mux';
  }

  private static connect(): void {
    if (DshStreamClient.connecting || DshStreamClient.appCtx === null) {
      return;
    }
    // 已有连接（重试定时器与手动重连竞态）：不得再开第二条，否则旧 socket 泄漏
    if (DshStreamClient.socket !== null) {
      return;
    }
    DshStreamClient.connecting = true;
    hilog.info(0x0000, WS_TAG, 'connect begin');    DshApiClient.wsConnectInfo(DshStreamClient.appCtx).then((info: DshWsConnectInfo) => {
      if (!DshStreamClient.wantConnected) {
        DshStreamClient.connecting = false;
        return;
      }
      const url: string = DshStreamClient.wsUrlOf(info.serverUrl);
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      DshStreamClient.socket = ws;
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err || DshStreamClient.socket !== ws || typeof value !== 'string') {
          return;
        }
        DshStreamClient.onText(value);
      });
      // close/error 可能连发：用局部标记保证 onLost 只走一次，且 close code 一定能打出来
      let lostSeen: boolean = false;
      const onLostOnce = (why: string): void => {
        if (lostSeen) {
          return;
        }
        lostSeen = true;
        DshStreamClient.socket = null;
        DshStreamClient.connecting = false;
        hilog.error(0x0000, WS_TAG, why);
        DshStreamClient.onLost();
      };
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        if (DshStreamClient.socket !== ws) {
          return;
        }
        onLostOnce('ws close code=' + value.code + ' reason=' + value.reason);
      });
      ws.on('error', (err: BusinessError) => {
        if (DshStreamClient.socket !== ws) {
          return;
        }
        onLostOnce('ws error ' + err.code + ' ' + err.message);
      });
      const options: webSocket.WebSocketRequestOptions = {
        header: info.headers,
      };
      ws.connect(url, options, (err: BusinessError, value: boolean) => {
        if (DshStreamClient.socket !== ws) {
          return;
        }
        if (err || value !== true) {
          // 注意：netstack 握手失败可能以"无 err + value=false"回调，必须两个都判
          DshStreamClient.socket = null;
          DshStreamClient.connecting = false;
          if (err) {
            hilog.error(0x0000, WS_TAG, 'connect failed: ' + err.code + ' ' + err.message);
          } else {
            hilog.error(0x0000, WS_TAG, 'connect refused (value=false)');
          }
          DshStreamClient.onLost();
          return;
        }
        DshStreamClient.connecting = false;
        DshStreamClient.retryAttempt = 0;
        hilog.info(0x0000, WS_TAG, 'socket connected');
        // 连接成功：撤销挂起的重试定时器，避免稍后再开第二条连接
        if (DshStreamClient.retryTimer >= 0) {
          clearTimeout(DshStreamClient.retryTimer);
          DshStreamClient.retryTimer = -1;
        }
        DshStreamClient.sendFollow();
      });
    }).catch((err: BusinessError) => {
      // 认证链失败（Cookie 换取不通过）：按断线退避重试，下一轮重新走自愈
      DshStreamClient.connecting = false;
      hilog.error(0x0000, WS_TAG, 'wsConnectInfo failed: ' + err.code + ' ' + err.message);
      DshStreamClient.onLost();
    });
  }

  /** 断线处理：通知监听器并按指数退避重连。 */
  private static onLost(): void {
    DshStreamClient.snapshotSeen = false;
    hilog.error(0x0000, WS_TAG, 'stream lost, retry=' + DshStreamClient.retryAttempt);
    if (!DshStreamClient.wantConnected) {
      return;
    }
    const l: DshStreamListener | null = DshStreamClient.listener;
    if (l !== null) {
      l.onStreamDown();
    }
    if (DshStreamClient.retryTimer >= 0) {
      return;
    }
    DshStreamClient.retryAttempt++;
    const delay: number = Math.min(LIVE_RECONNECT_BASE_MS * DshStreamClient.retryAttempt, LIVE_RECONNECT_MAX_MS);
    DshStreamClient.retryTimer = setTimeout(() => {
      DshStreamClient.retryTimer = -1;
      if (DshStreamClient.wantConnected && DshStreamClient.socket === null) {
        DshStreamClient.connect();
      }
    }, delay);
  }

  private static cancelStream(): void {
    const s: webSocket.WebSocket | null = DshStreamClient.socket;
    const sid: string = DshStreamClient.streamId;
    if (s === null || sid === '') {
      return;
    }
    const frame: WireCancelFrame = { type: 'cancel', streamId: sid };
    try {
      s.send(JSON.stringify(frame)).catch((err: BusinessError) => {
      });
    } catch (err) {
    }
  }

  private static sendFollow(): void {
    const s: webSocket.WebSocket | null = DshStreamClient.socket;
    if (s === null || DshStreamClient.sessionId === '') {
      return;
    }
    DshStreamClient.snapshotSeen = false;
    DshStreamClient.streamId = 'pdsh-' + Date.now().toString(16) + '-' + Math.floor(Math.random() * 100000000).toString(16);
    DshStreamClient.deltaCount = 0;
    DshStreamClient.deltaChars = 0;
    hilog.info(0x0000, WS_TAG, 'follow open ' + DshStreamClient.sessionId);
    const addr: WireAddress = { kind: 'session', sessionId: DshStreamClient.sessionId };
    const req: WireFollowRequest = { address: addr, maxMessages: 50, assistantStream: true };
    const args: WireOpenArgs = { request: req };
    const payload: WireOpenPayload = { args: args };
    const frame: WireOpenFrame = {
      type: 'open',
      streamId: DshStreamClient.streamId,
      endpoint: 'session/follow',
      payload: payload,
    };
    try {
      s.send(JSON.stringify(frame)).then((ok: boolean) => {
        hilog.info(0x0000, WS_TAG, 'follow frame sent ok=' + ok);
      }).catch((err: BusinessError) => {
        hilog.error(0x0000, WS_TAG, 'follow frame send FAILED: ' + err.code + ' ' + err.message);
      });
    } catch (err) {
      hilog.error(0x0000, WS_TAG, 'follow frame send threw');
    }
  }

  /* ───────────── 帧处理 ───────────── */

  private static onText(text: string): void {
    let frame: WireMuxFrame;
    try {
      frame = JSON.parse(text) as WireMuxFrame;
    } catch (err) {
      return;
    }
    if (frame === undefined || frame === null) {
      return;
    }
    const sid: string | undefined = frame.streamId;
    if (sid === undefined || sid === null || sid !== DshStreamClient.streamId) {
      return;
    }
    const ftype: string = frame.type !== undefined && frame.type !== null ? frame.type : '';
    if (ftype === 'item') {
      const v: object | null = frame.value !== undefined && frame.value !== null ? frame.value : null;
      if (v !== null) {
        DshStreamClient.onItem(v);
      }
    } else if (ftype === 'error' || ftype === 'end') {
      // 流级终止：断开重连，重连后 snapshot 会补齐缺口
      hilog.error(0x0000, WS_TAG, 'stream frame ' + ftype + (frame.error !== undefined && frame.error !== null
        ? ' ' + (frame.error.code !== undefined && frame.error.code !== null ? frame.error.code : '') : ''));
      const s: webSocket.WebSocket | null = DshStreamClient.socket;
      DshStreamClient.socket = null;
      DshStreamClient.snapshotSeen = false;
      if (s !== null) {
        try {
          s.close().catch((err: BusinessError) => {
          });
        } catch (err) {
        }
      }
      DshStreamClient.onLost();
    }
  }

  private static onItem(value: object): void {
    const v: WireItemValue = value as WireItemValue;
    const t: string = v.type !== undefined && v.type !== null ? v.type : '';
    if (t === 'snapshot') {
      DshStreamClient.handleSnapshot(value as WireSnapshotValue);
    } else if (t === 'event') {
      const ev: WireEvent | undefined | null = (value as WireEventValue).event;
      if (ev !== undefined && ev !== null) {
        DshStreamClient.handleEvent(ev);
      }
    } else if (t === 'assistant-stream') {
      const f: WireV2Frame | undefined | null = (value as WireStreamValue).frame;
      if (f !== undefined && f !== null) {
        DshStreamClient.handleV2Frame(f);
      }
    }
  }

  /** follow 开仓快照：记录游标，重放窗口内事件（view 按 seq 去重）。 */
  private static handleSnapshot(value: WireSnapshotValue): void {
    DshStreamClient.blockKinds.clear();
    DshStreamClient.snapshotSeen = true;
    DshStreamClient.retryAttempt = 0;
    const l: DshStreamListener | null = DshStreamClient.listener;
    const cursor: number = value.cursor !== undefined && value.cursor !== null ? value.cursor : -1;
    const recCount: number = value.records !== undefined && value.records !== null ? value.records.length : -1;
    hilog.info(0x0000, WS_TAG, 'snapshot cursor=' + cursor + ' records=' + recCount);
    if (l !== null && cursor >= 0) {
      l.onSnapshot(cursor);
    }
    const records: object[] = value.records !== undefined && value.records !== null ? value.records : [];
    DshStreamClient.replaying = true;
    DshStreamClient.replayText = '';
    DshStreamClient.replayReasoning = '';
    DshStreamClient.replayMaxChunkSeq = -1;
    DshStreamClient.replayMaxContentSeq = -1;
    DshStreamClient.replayMaxTurnEndSeq = -1;
    for (let i: number = 0; i < records.length; i++) {
      const wrap: WireRecordWrap = records[i] as WireRecordWrap;
      const ev: WireEvent | undefined | null = wrap.event;
      if (ev === undefined || ev === null) {
        continue;
      }
      DshStreamClient.handleEvent(ev);
    }
    DshStreamClient.replaying = false;
    // 生成仍在进行（chunk 序号越过最后内容序号，且晚于最近 turn/end——
    // 失败轮次的 chunk 不压缩，缺 turn/end 条件会把已结束轮次误判为生成中）：
    // 把重放累积的半截内容一次性交付
    if (l !== null && DshStreamClient.replayMaxChunkSeq > DshStreamClient.replayMaxContentSeq
      && DshStreamClient.replayMaxChunkSeq > DshStreamClient.replayMaxTurnEndSeq) {
      if (DshStreamClient.replayText !== '') {
        l.onLiveDelta('text', DshStreamClient.replayText);
      }
      if (DshStreamClient.replayReasoning !== '') {
        l.onLiveDelta('reasoning', DshStreamClient.replayReasoning);
      }
    }
    DshStreamClient.replayText = '';
    DshStreamClient.replayReasoning = '';
  }

  private static handleEvent(ev: WireEvent): void {
    const type: string = ev.type !== undefined && ev.type !== null ? ev.type : '';
    const seq: number = ev.seq !== undefined && ev.seq !== null ? ev.seq : -1;
    const time: number = ev.time !== undefined && ev.time !== null ? ev.time : 0;
    const data: object = ev.data !== undefined && ev.data !== null ? ev.data : EMPTY_DATA;
    const l: DshStreamListener | null = DshStreamClient.listener;
    hilog.info(0x0000, WS_TAG, 'ev ' + type + '#' + seq);

    // snapshot 重放期间的生成中判定（与会话仓库 generating 逻辑同构）
    if (DshStreamClient.replaying) {
      if (type === 'user/message' || type === 'assistant/message') {
        if (seq > DshStreamClient.replayMaxContentSeq) {
          DshStreamClient.replayMaxContentSeq = seq;
        }
      } else if (type.indexOf('chunk') >= 0) {
        if (seq > DshStreamClient.replayMaxChunkSeq) {
          DshStreamClient.replayMaxChunkSeq = seq;
        }
      } else if (type === 'turn/end') {
        if (seq > DshStreamClient.replayMaxTurnEndSeq) {
          DshStreamClient.replayMaxTurnEndSeq = seq;
        }
      }
    }

    if (type === 'user/message') {
      const d: WireUserEventData = data as WireUserEventData;
      const src: WireUserSource | undefined | null = d.source;
      const kind: string = src !== undefined && src !== null && src.kind !== undefined && src.kind !== null
        ? src.kind : '';
      // 只交付真人消息；plugin / skill-catalog 是系统注入的伪用户消息
      if (kind !== 'user') {
        return;
      }
      const text: string = DshStreamClient.joinBlocks(d.content);
      if (l !== null && text !== '') {
        l.onUserMessage(seq, time, text);
      }
    } else if (type === 'assistant/message') {
      const d: WireAssistantEventData = data as WireAssistantEventData;
      const msg: WireAssistantMessage | null = d.message !== undefined && d.message !== null ? d.message : null;
      if (msg === null) {
        return;
      }
      const text: string = DshStreamClient.joinBlocks(msg.content);
      const reasoning: string = DshStreamClient.joinReasoning(msg.content);
      const usage: WireUsage | null = d.usage !== undefined && d.usage !== null ? d.usage : null;
      const usageIn: number = usage !== null && usage.inputTokens !== undefined && usage.inputTokens !== null
        ? usage.inputTokens : 0;
      const usageOut: number = usage !== null && usage.outputTokens !== undefined && usage.outputTokens !== null
        ? usage.outputTokens : 0;
      const src: WireAssistantSource | undefined | null = msg.source;
      const model: string = src !== undefined && src !== null && src.model !== undefined && src.model !== null
        ? src.model : '';
      const turn: number = d.turn !== undefined && d.turn !== null ? d.turn : 0;
      if (l !== null) {
        l.onAssistantMessage(seq, time, turn, text, reasoning, usageIn, usageOut, model);
      }
    } else if (type === 'assistant/chunk') {
      const d: WireChunkEventData = data as WireChunkEventData;
      if (d.chunk !== undefined && d.chunk !== null) {
        DshStreamClient.handleChunk(d.chunk);
      }
    } else if (type === 'chunkrow/text-chunks' || type === 'chunkrow/reasoning-chunks') {
      const d: WireChunkRowData = data as WireChunkRowData;
      const kind: string = type === 'chunkrow/text-chunks' ? 'text' : 'reasoning';
      let joined: string = '';
      const texts: string[] | undefined | null = d.texts;
      if (texts !== undefined && texts !== null) {
        for (let i: number = 0; i < texts.length; i++) {
          if (texts[i] !== undefined && texts[i] !== null) {
            joined += texts[i];
          }
        }
      }
      if (joined !== '') {
        DshStreamClient.emitDelta(kind, joined);
      }
    } else if (type === 'tool/call') {
      const d: WireToolCallData = data as WireToolCallData;
      if (l !== null) {
        const callId: string = d.callId !== undefined && d.callId !== null ? d.callId : '';
        const name: string = d.name !== undefined && d.name !== null ? d.name : '';
        const args: string = d.arguments !== undefined && d.arguments !== null ? d.arguments : '';
        const turn: number = d.turn !== undefined && d.turn !== null ? d.turn : 0;
        l.onToolCall(seq, time, turn, callId, name, args);
      }
    } else if (type === 'tool/result') {
      const d: WireToolResultData = data as WireToolResultData;
      const msg: WireToolResultMessage | undefined | null = d.message;
      if (msg === undefined || msg === null || l === null) {
        return;
      }
      const src: WireToolResultSource | undefined | null = msg.source;
      const callId: string = src !== undefined && src !== null && src.callId !== undefined && src.callId !== null
        ? src.callId : '';
      if (callId === '') {
        return;
      }
      let result: string = '';
      const blocks: WireToolResultBlock[] | undefined | null = msg.content;
      if (blocks !== undefined && blocks !== null) {
        for (let b: number = 0; b < blocks.length; b++) {
          const block: WireToolResultBlock | undefined | null = blocks[b];
          if (block === undefined || block === null) {
            continue;
          }
          result += DshStreamClient.joinBlocks(block.content);
        }
      }
      l.onToolResult(callId, result);
    } else if (type === 'turn/start') {
      const d: WireTurnData = data as WireTurnData;
      const turn: number = d.turn !== undefined && d.turn !== null ? d.turn : 0;
      if (l !== null) {
        l.onTurnStart(seq, time, turn);
      }
    } else if (type === 'turn/end') {
      if (l !== null) {
        const d: WireTurnData = data as WireTurnData;
        const reasonObj: WireTurnEndReason | undefined | null = d.reason;
        let reasonKind: string = reasonObj !== undefined && reasonObj !== null
          && reasonObj.kind !== undefined && reasonObj.kind !== null ? reasonObj.kind : 'completed';
        let failureCode: string = '';
        let failureMessage: string = '';
        if (reasonKind === 'error' && reasonObj !== undefined && reasonObj !== null) {
          const failure: WireLlmFailure | undefined | null = reasonObj.error;
          if (failure !== undefined && failure !== null) {
            failureCode = failure.code !== undefined && failure.code !== null ? failure.code : '';
            failureMessage = failure.message !== undefined && failure.message !== null ? failure.message : '';
          }
        } else if (reasonKind === 'aborted' && reasonObj !== undefined && reasonObj !== null) {
          const cause: WireAbortCause | undefined | null = reasonObj.reason;
          if (cause !== undefined && cause !== null) {
            reasonKind = 'aborted/' + (cause.kind !== undefined && cause.kind !== null ? cause.kind : '?');
          }
        }
        l.onTurnEnd(seq, time, reasonKind, failureCode, failureMessage, !DshStreamClient.replaying);
      }
    } else if (type === 'session/title') {
      const d: WireTitleData = data as WireTitleData;
      const title: string = d.title !== undefined && d.title !== null ? d.title : '';
      if (l !== null && title !== '') {
        l.onTitleChanged(title);
      }
    }
    // 其余事件（step/*、agent/inbox/*、request/*、assistant/attempt 等）流式路径不需要
  }

  /** 单个 chunk 体路由（v1 assistant/chunk 与 v2 assistant-stream 共用）。 */
  private static handleChunk(c: WireChunkBody): void {
    const ctype: string = c.type !== undefined && c.type !== null ? c.type : '';
    if (ctype === 'block-start') {
      const idx: number = c.index !== undefined && c.index !== null ? c.index : -1;
      const bt: string = c.blockType !== undefined && c.blockType !== null ? c.blockType : '';
      if (idx >= 0 && bt !== '') {
        DshStreamClient.blockKinds.set(idx, bt);
      }
    } else if (ctype === 'text-delta' || ctype === 'reasoning-delta') {
      const idx: number = c.index !== undefined && c.index !== null ? c.index : -1;
      let kind: string = ctype === 'text-delta' ? 'text' : 'reasoning';
      const mapped: string | undefined = idx >= 0 ? DshStreamClient.blockKinds.get(idx) : undefined;
      if (mapped !== undefined) {
        kind = mapped === 'text' ? 'text' : 'reasoning';
      }
      const text: string = c.text !== undefined && c.text !== null ? c.text : '';
      if (text !== '') {
        DshStreamClient.emitDelta(kind, text);
      }
    } else if (ctype === 'block-end') {
      const block: WireBlock | undefined | null = c.block;
      if (block === undefined || block === null) {
        return;
      }
      const bkind: string = block.type !== undefined && block.type !== null ? block.type : 'text';
      const btext: string = block.text !== undefined && block.text !== null ? block.text : '';
      if (DshStreamClient.replaying) {
        // 重放中：整块权威内容直接替换累积缓冲
        if (bkind === 'text') {
          DshStreamClient.replayText = btext;
        } else {
          DshStreamClient.replayReasoning = btext;
        }
        return;
      }
      const l: DshStreamListener | null = DshStreamClient.listener;
      if (l !== null) {
        l.onLiveBlock(bkind, btext);
      }
    } else if (ctype === 'usage') {
      const u: WireUsage | undefined | null = c.usage;
      if (u === undefined || u === null) {
        return;
      }
      const l: DshStreamListener | null = DshStreamClient.listener;
      if (l !== null && !DshStreamClient.replaying) {
        const inputTokens: number = u.inputTokens !== undefined && u.inputTokens !== null ? u.inputTokens : 0;
        const outputTokens: number = u.outputTokens !== undefined && u.outputTokens !== null ? u.outputTokens : 0;
        l.onLiveUsage(inputTokens, outputTokens);
      }
    }
    // finish 等控制块：结算由 assistant/message 事件负责，这里不需要处理
  }

  /** v2 服务器 assistant-stream 活帧（向前兼容；v1 服务器不会出现）。 */
  private static handleV2Frame(f: WireV2Frame): void {
    const t: string = f.type !== undefined && f.type !== null ? f.type : '';
    if (t === 'start') {
      DshStreamClient.blockKinds.clear();
    } else if (t === 'chunk') {
      const c: WireChunkBody | undefined | null = f.chunk;
      if (c !== undefined && c !== null) {
        DshStreamClient.handleChunk(c);
      }
    } else if (t === 'end') {
      const outcome: WireV2Outcome | undefined | null = f.outcome;
      if (outcome !== undefined && outcome !== null && outcome.kind === 'abandoned') {
        const l: DshStreamListener | null = DshStreamClient.listener;
        if (l !== null && !DshStreamClient.replaying) {
          l.onTurnEnd(-1, 0, 'abandoned', '', '', true);
        }
      }
    }
  }

  /** 交付一条增量；重放期间暂存缓冲。 */
  private static emitDelta(kind: string, text: string): void {
    if (DshStreamClient.replaying) {
      if (kind === 'text') {
        DshStreamClient.replayText += text;
      } else {
        DshStreamClient.replayReasoning += text;
      }
      return;
    }
    DshStreamClient.deltaCount++;
    DshStreamClient.deltaChars += text.length;
    if (DshStreamClient.deltaCount % 20 === 1) {
      hilog.info(0x0000, WS_TAG, 'delta#' + DshStreamClient.deltaCount + ' chars=' + DshStreamClient.deltaChars + ' kind=' + kind);
    }
    const l: DshStreamListener | null = DshStreamClient.listener;
    if (l !== null) {
      l.onLiveDelta(kind, text);
    }
  }

  /* ───────────── 工具 ───────────── */

  private static joinBlocks(blocks: WireBlock[] | undefined | null): string {
    if (blocks === undefined || blocks === null) {
      return '';
    }
    let out: string = '';
    for (let i: number = 0; i < blocks.length; i++) {
      const block: WireBlock | undefined | null = blocks[i];
      if (block === undefined || block === null) {
        continue;
      }
      if (block.type === 'text' && block.text !== undefined && block.text !== null) {
        out += block.text;
      }
    }
    return out;
  }

  private static joinReasoning(blocks: WireBlock[] | undefined | null): string {
    if (blocks === undefined || blocks === null) {
      return '';
    }
    let out: string = '';
    for (let i: number = 0; i < blocks.length; i++) {
      const block: WireBlock | undefined | null = blocks[i];
      if (block === undefined || block === null) {
        continue;
      }
      if (block.type === 'reasoning' && block.text !== undefined && block.text !== null) {
        out += block.text;
      }
    }
    return out;
  }
}
