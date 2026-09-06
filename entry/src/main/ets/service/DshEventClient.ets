/** dsh 全局事件流客户端：/api/remote.mux 复用通道上的 $events 流。
 *
 * 协议（源码级逆向 + wire 契约，见 ARCHITECTURE.md §3.6）：
 *  - open 帧 endpoint='$events'，payload={args:{}}；
 *  - 首个 item 为 ready 帧 {type:'ready', clientId, host:{home}}，clientId 是回答回执的身份；
 *  - 随后 item 为 waterfall 帧 {type:'waterfall', event, eventId, agentId, request}
 *    （event='user-questions/request' 提问组 | 'approval/request' 工具审批；agentId === sessionId）、
 *    cancel 帧 {type:'cancel', eventId}（服务端撤销，如已在别端作答）、
 *    emit 帧（状态广播，忽略）；
 *  - 回答走 unary RPC POST /api/$events/result，
 *    args={clientId, eventId, outcome:{kind:'result',value}|{kind:'next'}|{kind:'rejected',error}}。
 */
import webSocket from '@ohos.net.webSocket';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { DshApiClient, DshApiClientError, DshWsConnectInfo } from './DshApiClient';
import { PendingAskVm, QuestionOptionVm, QuestionVm } from '../model/SessionVms';
import { KEY_ASK_TICK } from '../model/DshTypes';

const EV_TAG: string = 'PocketDSH_EV';
const RECONNECT_BASE_MS: number = 1500;
const RECONNECT_MAX_MS: number = 15000;
/** 重连后旧一代遗留 waterfall 的宽限期：ready 起 5s 内未被重投递的条目按陈旧丢弃。 */
const STALE_GRACE_MS: number = 5000;

/* ───────────── 出站帧形状 ───────────── */

interface WireOpenFrame {
  type: string;
  streamId: string;
  endpoint: string;
  payload: Record<string, Object>;
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

/** ready 帧。 */
interface WireReadyValue {
  type?: string;
  clientId?: string;
}

/** waterfall 帧。 */
interface WireWaterfallValue {
  type?: string;
  event?: string;
  eventId?: string;
  agentId?: string;
  request?: object;
}

/** cancel 帧。 */
interface WireCancelValue {
  type?: string;
  eventId?: string;
}

/** 提问选项 wire。 */
interface WireQuestionOption {
  label?: string;
  description?: string;
}

/** 提问 intent（计划审批特例）。 */
interface WireQuestionIntent {
  kind?: string;
  approve?: string;
}

/** 单题 wire。 */
interface WireQuestion {
  id?: string;
  header?: string;
  question?: string;
  detail?: string;
  multiSelect?: boolean;
  options?: WireQuestionOption[];
  intent?: WireQuestionIntent;
}

/** user-questions/request 的 request。 */
interface WireQuestionsRequest {
  questions?: object[];
}

/** approval/request 的 request。 */
interface WireApprovalRequest {
  toolName?: string;
  callId?: string;
  reason?: string;
}

/* ───────────── 回答回执（$events/result args） ───────────── */

/** 单题回答：skipped = selected 空；自定义答案走 custom（单选时 custom 覆盖 selected）。 */
interface WireAnswerEntry {
  id: string;
  selected: string[];
  custom?: string;
}

/** 提问回答批次。 */
interface WireAnswersValue {
  answers: WireAnswerEntry[];
}

/** waterfall 处理结果。 */
interface WireEventOutcome {
  kind: string;
  value?: Object;
  error?: WireOutcomeError;
}

interface WireOutcomeError {
  name: string;
  message: string;
  code?: string;
}

interface WireEventResultArgs {
  clientId: string;
  eventId: string;
  outcome: WireEventOutcome;
}

/**
 * DshEventClient：应用级常驻事件流（与会话 follow 互不影响）。start() 后自动重连；
 * pending 提问/审批列表由本类持有，视图经 AppStorage KEY_ASK_TICK 感知变更后重读。
 */
export class DshEventClient {
  private static socket: webSocket.WebSocket | null = null;
  private static connecting: boolean = false;
  private static wantConnected: boolean = false;
  private static appCtx: common.Context | null = null;
  private static streamId: string = '';
  /** ready 帧下发的客户端身份（回答回执必带）。 */
  private static clientId: string = '';
  private static retryAttempt: number = 0;
  private static retryTimer: number = -1;
  /** 陈旧清理定时器（ready 后丢弃未被重投递的旧代遗留）。 */
  private static staleTimer: number = -1;
  /** 当前待处理列表（提问组 + 工具审批）。 */
  private static asks: PendingAskVm[] = [];

  /** 启动（幂等）；configReady 后由外壳调用。 */
  static start(ctx: common.Context): void {
    DshEventClient.appCtx = ctx;
    if (DshEventClient.wantConnected) {
      return;
    }
    DshEventClient.wantConnected = true;
    hilog.info(0x0000, EV_TAG, 'start');
    DshEventClient.connect();
  }

  /** 停止（清除配置/退出登录时调用）。 */
  static stop(): void {
    DshEventClient.wantConnected = false;
    if (DshEventClient.retryTimer >= 0) {
      clearTimeout(DshEventClient.retryTimer);
      DshEventClient.retryTimer = -1;
    }
    DshEventClient.clearStaleTimer();
    const s: webSocket.WebSocket | null = DshEventClient.socket;
    DshEventClient.socket = null;
    DshEventClient.connecting = false;
    DshEventClient.clientId = '';
    DshEventClient.setAsks([]);
    if (s !== null) {
      try {
        s.close().catch((err: BusinessError) => {
        });
      } catch (err) {
      }
    }
  }

  /** 当前待处理列表（调用方只读，不持有引用修改）。 */
  static pendingAsks(): PendingAskVm[] {
    return DshEventClient.asks;
  }

  /* ───────────── 回答（视图层动作） ───────────── */

  /**
   * 提交提问回答批次（与 web QuestionComposer 完全同构）：
   * 跳过题 selected=[]；单选题自定义文本覆盖选项；多选题选项与自定义可共存。
   */
  static async answerQuestions(ctx: common.Context, eventId: string, questions: QuestionVm[],
    selected: string[][], customs: string[], skipped: boolean[]): Promise<void> {
    const answers: WireAnswerEntry[] = [];
    for (let i: number = 0; i < questions.length; i++) {
      const q: QuestionVm = questions[i];
      const sel: string[] = i < selected.length ? selected[i] : [];
      const custom: string = i < customs.length ? customs[i].trim() : '';
      if (i < skipped.length && skipped[i]) {
        const e0: WireAnswerEntry = { id: q.id, selected: [] };
        answers.push(e0);
        continue;
      }
      if (custom !== '' && q.multiSelect !== true) {
        const e1: WireAnswerEntry = { id: q.id, selected: [], custom: custom };
        answers.push(e1);
      } else if (custom !== '') {
        const e2: WireAnswerEntry = { id: q.id, selected: sel, custom: custom };
        answers.push(e2);
      } else {
        const e3: WireAnswerEntry = { id: q.id, selected: sel };
        answers.push(e3);
      }
    }
    const value: WireAnswersValue = { answers: answers };
    await DshEventClient.sendOutcome(ctx, eventId, 'result', value);
    DshEventClient.removeByEvent(eventId);
  }

  /** 工具审批决定：'allowed-once' | 'rejected'（web ApprovalPanel 同构）。 */
  static async answerApproval(ctx: common.Context, eventId: string, decision: string): Promise<void> {
    await DshEventClient.sendOutcome(ctx, eventId, 'result', decision);
    DshEventClient.removeByEvent(eventId);
  }

  /** 放弃整组问题（web「放弃整组问题」同构：reject 语义 ASK_CANCELLED）。 */
  static async cancelQuestions(ctx: common.Context, eventId: string): Promise<void> {
    await DshEventClient.sendRejected(ctx, eventId, 'UserQuestionError',
      'the user cancelled ask_user_question', 'ASK_CANCELLED');
    DshEventClient.removeByEvent(eventId);
  }

  /** 让位：不处理，交给下一个监听端（如 web 控制台）。 */
  static async delegateEvent(ctx: common.Context, eventId: string): Promise<void> {
    await DshEventClient.sendOutcome(ctx, eventId, 'next', null);
    DshEventClient.removeByEvent(eventId);
  }

  /** 统一上报 outcome 并移除本地条目。value 为 null 表示无载荷（next）。 */
  private static async sendOutcome(ctx: common.Context, eventId: string, kind: string, value: Object | null): Promise<void> {
    let outcome: WireEventOutcome;
    if (value === null) {
      outcome = { kind: kind };
    } else {
      outcome = { kind: kind, value: value };
    }
    await DshEventClient.postResult(ctx, eventId, outcome);
  }

  private static async sendRejected(ctx: common.Context, eventId: string, name: string,
    message: string, code: string): Promise<void> {
    const error: WireOutcomeError = code === '' ? { name: name, message: message }
      : { name: name, message: message, code: code };
    const outcome: WireEventOutcome = { kind: 'rejected', error: error };
    await DshEventClient.postResult(ctx, eventId, outcome);
  }

  private static async postResult(ctx: common.Context, eventId: string, outcome: WireEventOutcome): Promise<void> {
    if (DshEventClient.clientId === '') {
      // 事件流未就绪：踢一次重连并短暂等待 ready（连接建立中就点提交的窗口）
      if (DshEventClient.socket === null && !DshEventClient.connecting && DshEventClient.wantConnected) {
        DshEventClient.connect();
      }
      for (let i: number = 0; i < 10 && DshEventClient.clientId === ''; i++) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(() => resolve(), 250);
        });
      }
      if (DshEventClient.clientId === '') {
        throw new DshApiClientError('ev/no-client', '事件流未就绪，请稍后重试');
      }
    }
    const args: WireEventResultArgs = {
      clientId: DshEventClient.clientId,
      eventId: eventId,
      outcome: outcome,
    };
    await DshApiClient.call(ctx, '$events/result', '', args);
  }

  /* ───────────── pending 列表维护 ───────────── */

  private static setAsks(next: PendingAskVm[]): void {
    DshEventClient.asks = next;
    DshEventClient.bump();
  }

  private static upsert(ask: PendingAskVm): void {
    const next: PendingAskVm[] = [];
    for (let i: number = 0; i < DshEventClient.asks.length; i++) {
      if (DshEventClient.asks[i].eventId !== ask.eventId) {
        next.push(DshEventClient.asks[i]);
      }
    }
    next.push(ask);
    DshEventClient.asks = next;
    DshEventClient.bump();
  }

  private static removeByEvent(eventId: string): void {
    let removed: boolean = false;
    const next: PendingAskVm[] = [];
    for (let i: number = 0; i < DshEventClient.asks.length; i++) {
      if (DshEventClient.asks[i].eventId === eventId) {
        removed = true;
      } else {
        next.push(DshEventClient.asks[i]);
      }
    }
    if (removed) {
      DshEventClient.asks = next;
      DshEventClient.bump();
    }
  }

  private static bump(): void {
    const t: number = AppStorage.get<number>(KEY_ASK_TICK) ?? 0;
    AppStorage.setOrCreate(KEY_ASK_TICK, t + 1);
  }

  private static clearStaleTimer(): void {
    if (DshEventClient.staleTimer >= 0) {
      clearTimeout(DshEventClient.staleTimer);
      DshEventClient.staleTimer = -1;
    }
  }

  /* ───────────── 连接管理 ───────────── */

  private static connect(): void {
    if (DshEventClient.connecting || DshEventClient.appCtx === null) {
      return;
    }
    if (DshEventClient.socket !== null) {
      return;
    }
    DshEventClient.connecting = true;
    hilog.info(0x0000, EV_TAG, 'connect begin');
    DshApiClient.wsConnectInfo(DshEventClient.appCtx).then((info: DshWsConnectInfo) => {
      if (!DshEventClient.wantConnected) {
        DshEventClient.connecting = false;
        return;
      }
      const url: string = DshEventClient.wsUrlOf(info.serverUrl);
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      DshEventClient.socket = ws;
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err || DshEventClient.socket !== ws || typeof value !== 'string') {
          return;
        }
        DshEventClient.onText(value);
      });
      let lostSeen: boolean = false;
      const onLostOnce = (why: string): void => {
        if (lostSeen) {
          return;
        }
        lostSeen = true;
        DshEventClient.socket = null;
        DshEventClient.connecting = false;
        hilog.error(0x0000, EV_TAG, why);
        DshEventClient.onLost();
      };
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        if (DshEventClient.socket !== ws) {
          return;
        }
        onLostOnce('ws close code=' + value.code + ' reason=' + value.reason);
      });
      ws.on('error', (err: BusinessError) => {
        if (DshEventClient.socket !== ws) {
          return;
        }
        onLostOnce('ws error ' + err.code + ' ' + err.message);
      });
      const options: webSocket.WebSocketRequestOptions = {
        header: info.headers,
      };
      ws.connect(url, options, (err: BusinessError, ok: boolean) => {
        if (DshEventClient.socket !== ws) {
          return;
        }
        if (err || ok !== true) {
          DshEventClient.socket = null;
          DshEventClient.connecting = false;
          if (err) {
            hilog.error(0x0000, EV_TAG, 'connect failed: ' + err.code + ' ' + err.message);
          } else {
            hilog.error(0x0000, EV_TAG, 'connect refused (ok=false)');
          }
          DshEventClient.onLost();
          return;
        }
        DshEventClient.connecting = false;
        DshEventClient.retryAttempt = 0;
        hilog.info(0x0000, EV_TAG, 'socket connected');
        if (DshEventClient.retryTimer >= 0) {
          clearTimeout(DshEventClient.retryTimer);
          DshEventClient.retryTimer = -1;
        }
        DshEventClient.sendOpen();
      });
    }).catch((err: BusinessError) => {
      DshEventClient.connecting = false;
      hilog.error(0x0000, EV_TAG, 'wsConnectInfo failed: ' + err.code + ' ' + err.message);
      DshEventClient.onLost();
    });
  }

  private static onLost(): void {
    hilog.error(0x0000, EV_TAG, 'event stream lost, retry=' + DshEventClient.retryAttempt);
    if (!DshEventClient.wantConnected) {
      return;
    }
    if (DshEventClient.retryTimer >= 0) {
      return;
    }
    DshEventClient.retryAttempt++;
    const delay: number = Math.min(RECONNECT_BASE_MS * DshEventClient.retryAttempt, RECONNECT_MAX_MS);
    DshEventClient.retryTimer = setTimeout(() => {
      DshEventClient.retryTimer = -1;
      if (DshEventClient.wantConnected && DshEventClient.socket === null) {
        DshEventClient.connect();
      }
    }, delay);
  }

  private static wsUrlOf(serverUrl: string): string {
    let url: string = serverUrl;
    if (url.indexOf('https://') === 0) {
      url = 'wss://' + url.substring(8);
    } else if (url.indexOf('http://') === 0) {
      url = 'ws://' + url.substring(7);
    }
    return url + '/api/remote.mux';
  }

  private static sendOpen(): void {
    const s: webSocket.WebSocket | null = DshEventClient.socket;
    if (s === null) {
      return;
    }
    DshEventClient.streamId = 'pdsh-ev-' + Date.now().toString(16) + '-' + Math.floor(Math.random() * 100000000).toString(16);
    hilog.info(0x0000, EV_TAG, 'open $events streamId=' + DshEventClient.streamId);
    const args: Record<string, Object> = {};
    const payload: Record<string, Object> = { 'args': args };
    const frame: WireOpenFrame = {
      type: 'open',
      streamId: DshEventClient.streamId,
      endpoint: '$events',
      payload: payload,
    };
    try {
      s.send(JSON.stringify(frame)).catch((err: BusinessError) => {
        hilog.error(0x0000, EV_TAG, 'open send failed: ' + err.code);
      });
    } catch (err) {
      hilog.error(0x0000, EV_TAG, 'open send threw');
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
    if (sid === undefined || sid === null || sid !== DshEventClient.streamId) {
      return;
    }
    const ftype: string = frame.type !== undefined && frame.type !== null ? frame.type : '';
    if (ftype === 'item') {
      const v: object | null = frame.value !== undefined && frame.value !== null ? frame.value : null;
      if (v !== null) {
        DshEventClient.onItem(v);
      }
    } else if (ftype === 'error' || ftype === 'end') {
      const code: string = frame.error !== undefined && frame.error !== null
        && frame.error.code !== undefined && frame.error.code !== null ? frame.error.code : '';
      hilog.error(0x0000, EV_TAG, 'stream frame ' + ftype + ' ' + code);
      const s: webSocket.WebSocket | null = DshEventClient.socket;
      DshEventClient.socket = null;
      if (s !== null) {
        try {
          s.close().catch((err: BusinessError) => {
          });
        } catch (err) {
        }
      }
      DshEventClient.onLost();
    }
  }

  private static onItem(value: object): void {
    const v: WireReadyValue = value as WireReadyValue;
    const t: string = v.type !== undefined && v.type !== null ? v.type : '';
    if (t === 'ready') {
      const cid: string = v.clientId !== undefined && v.clientId !== null ? v.clientId : '';
      DshEventClient.clientId = cid;
      hilog.info(0x0000, EV_TAG, 'ready clientId=' + cid);
      // 新一代开始：旧代遗留条目给 5s 宽限等待服务端重投递，未被重投的按陈旧丢弃
      const readyAt: number = Date.now();
      if (DshEventClient.asks.length > 0) {
        DshEventClient.clearStaleTimer();
        DshEventClient.staleTimer = setTimeout(() => {
          DshEventClient.staleTimer = -1;
          DshEventClient.dropOlderThan(readyAt);
        }, STALE_GRACE_MS);
      }
      return;
    }
    if (t === 'waterfall') {
      DshEventClient.onWaterfall(value as WireWaterfallValue);
      return;
    }
    if (t === 'cancel') {
      const c: WireCancelValue = value as WireCancelValue;
      const eventId: string = c.eventId !== undefined && c.eventId !== null ? c.eventId : '';
      if (eventId !== '') {
        hilog.info(0x0000, EV_TAG, 'cancel ' + eventId);
        DshEventClient.removeByEvent(eventId);
      }
      return;
    }
    // emit（api-session/status 等广播）：忽略
  }

  private static dropOlderThan(readyAt: number): void {
    const keep: PendingAskVm[] = [];
    for (let i: number = 0; i < DshEventClient.asks.length; i++) {
      if (DshEventClient.asks[i].receivedAt >= readyAt) {
        keep.push(DshEventClient.asks[i]);
      }
    }
    if (keep.length !== DshEventClient.asks.length) {
      hilog.info(0x0000, EV_TAG, 'stale drop ' + (DshEventClient.asks.length - keep.length));
      DshEventClient.setAsks(keep);
    }
  }

  private static onWaterfall(f: WireWaterfallValue): void {
    const event: string = f.event !== undefined && f.event !== null ? f.event : '';
    const eventId: string = f.eventId !== undefined && f.eventId !== null ? f.eventId : '';
    const agentId: string = f.agentId !== undefined && f.agentId !== null ? f.agentId : '';
    const req: object | null = f.request !== undefined && f.request !== null ? f.request : null;
    if (eventId === '' || agentId === '' || req === null) {
      hilog.error(0x0000, EV_TAG, 'waterfall missing fields event=' + event);
      return;
    }
    if (event === 'user-questions/request') {
      const qs: QuestionVm[] = DshEventClient.parseQuestions(req as WireQuestionsRequest);
      if (qs.length === 0) {
        hilog.error(0x0000, EV_TAG, 'user-questions with no parsable question, delegate');
        DshEventClient.delegateUnhandled(agentId, eventId);
        return;
      }
      const ask: PendingAskVm = {
        kind: 'questions',
        eventId: eventId,
        sessionId: agentId,
        questions: qs,
        toolName: '',
        callId: '',
        reason: '',
        receivedAt: Date.now(),
      };
      hilog.info(0x0000, EV_TAG, 'questions eventId=' + eventId + ' session=' + agentId + ' n=' + qs.length);
      DshEventClient.upsert(ask);
      return;
    }
    if (event === 'approval/request') {
      const r: WireApprovalRequest = req as WireApprovalRequest;
      const toolName: string = r.toolName !== undefined && r.toolName !== null ? r.toolName : '';
      const callId: string = r.callId !== undefined && r.callId !== null ? r.callId : '';
      const reason: string = r.reason !== undefined && r.reason !== null ? r.reason : '';
      const ask: PendingAskVm = {
        kind: 'approval',
        eventId: eventId,
        sessionId: agentId,
        questions: [],
        toolName: toolName,
        callId: callId,
        reason: reason,
        receivedAt: Date.now(),
      };
      hilog.info(0x0000, EV_TAG, 'approval eventId=' + eventId + ' session=' + agentId + ' tool=' + toolName);
      DshEventClient.upsert(ask);
      return;
    }
    // 未支持的事件：让位给下一个监听端（web 控制台）
    hilog.info(0x0000, EV_TAG, 'unsupported waterfall ' + event + ', delegate');
    DshEventClient.delegateUnhandled(agentId, eventId);
  }

  /** 未支持 waterfall 的静默让位（失败仅留日志，不影响流）。 */
  private static delegateUnhandled(agentId: string, eventId: string): void {
    const ctx: common.Context | null = DshEventClient.appCtx;
    if (ctx === null) {
      return;
    }
    DshEventClient.delegateEvent(ctx, eventId).catch((err: BusinessError) => {
      hilog.error(0x0000, EV_TAG, 'delegate failed session=' + agentId + ' ' + err.message);
    });
  }

  /** 解析提问列表（三层 null 防御：坏题跳过，绝不让单题坏数据放大为整组失败）。 */
  private static parseQuestions(req: WireQuestionsRequest): QuestionVm[] {
    const out: QuestionVm[] = [];
    const raw: object[] = req.questions !== undefined && req.questions !== null ? req.questions : [];
    for (let i: number = 0; i < raw.length; i++) {
      const item: object | null = raw[i] !== undefined && raw[i] !== null ? raw[i] : null;
      if (item === null) {
        continue;
      }
      const q: WireQuestion = item as WireQuestion;
      const id: string = q.id !== undefined && q.id !== null ? q.id : '';
      const question: string = q.question !== undefined && q.question !== null ? q.question : '';
      if (id === '' || question === '') {
        continue;
      }
      const header: string = q.header !== undefined && q.header !== null ? q.header : '';
      const detail: string = q.detail !== undefined && q.detail !== null ? q.detail : '';
      const multi: boolean = q.multiSelect === true;
      const opts: QuestionOptionVm[] = [];
      const rawOpts: WireQuestionOption[] | undefined | null = q.options;
      if (rawOpts !== undefined && rawOpts !== null) {
        for (let k: number = 0; k < rawOpts.length; k++) {
          const o: WireQuestionOption | null = rawOpts[k] !== undefined && rawOpts[k] !== null ? rawOpts[k] : null;
          if (o === null) {
            continue;
          }
          const label: string = o.label !== undefined && o.label !== null ? o.label : '';
          if (label === '') {
            continue;
          }
          const desc: string = o.description !== undefined && o.description !== null ? o.description : '';
          const opt: QuestionOptionVm = { label: label, description: desc };
          opts.push(opt);
        }
      }
      // 计划审批特例（web planReviewOf 同构）：单题 + intent.kind='plan-review' + detail 非空
      // + 非多选 + ≤2 选项 + intent.approve 命中某选项
      let planReview: boolean = false;
      let approveLabel: string = '';
      const intent: WireQuestionIntent | undefined | null = q.intent;
      if (intent !== undefined && intent !== null && intent.kind === 'plan-review' && detail !== '' && !multi
        && opts.length > 0 && opts.length <= 2) {
        const ap: string = intent.approve !== undefined && intent.approve !== null ? intent.approve : '';
        for (let k: number = 0; k < opts.length; k++) {
          if (opts[k].label === ap) {
            planReview = true;
            approveLabel = ap;
            break;
          }
        }
      }
      const vm: QuestionVm = {
        id: id,
        header: header,
        question: question,
        detail: detail,
        multiSelect: multi,
        planReview: planReview,
        approveLabel: approveLabel,
        options: opts,
      };
      out.push(vm);
    }
    return out;
  }
}
