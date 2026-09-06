/** 原生工作台：会话列表 + 对话历史（只读）。展开态双栏，合盖态两级导航。 */
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@ohos.base';
import { DshSessionsRepository } from '../service/DshSessionsRepository';
import { DshStreamClient, DshStreamListener } from '../service/DshStreamClient';
import { DshConfigStore } from '../service/DshConfigStore';
import { CatalogVm, ChatEntryKind, ChatEntryVm, HistoryPageVm, ModelGroupVm, ModelItemVm, SessionSectionVm, SessionSummaryVm, ToolCallVm, WorkspaceBaselineVm, WorkspaceVm } from '../model/SessionVms';
import { MdBlock, MdKind, MdRun, parseMarkdown } from '../parse/MdParser';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { KEY_CUR_TAB, KEY_HIDDEN_TICK, TAB_SESSIONS } from '../model/DshTypes';

/** 会话列表加载状态。 */
enum ListState {
  Loading = 0,
  Ready = 1,
  Failed = 2,
}

/** 历史加载状态。 */
enum ChatState {
  Idle = 0,
  Loading = 1,
  Ready = 2,
  Failed = 3,
}

/** 列表展示模式：按时间分组（ZCode「分组」同款）。 */
const MODE_GROUPED: number = 0;
/** 列表展示模式：按项目分组（ZCode「项目」同款）。 */
const MODE_PROJECTS: number = 1;
/** 每个分区默认展示的会话条数，超出折叠进「显示更多」。 */
const SECTION_PREVIEW: number = 5;
/** 时间分组的桶标题（升序跨度）。 */
const TIME_BUCKET_TITLES: string[] = ['今天', '昨天', '7 天内', '30 天内', '更早'];

/**
 * DshStreamListener 的视图桥接：把流客户端回调转发到组件方法。
 * （ArkTS 对象字面量不能带方法，需独立类持有组件引用。）
 */
class ChatStreamListener implements DshStreamListener {
  private owner: WorkspaceChatView;

  constructor(owner: WorkspaceChatView) {
    this.owner = owner;
  }

  onSnapshot(cursor: number): void {
    this.owner.onStreamSnapshot(cursor);
  }

  onUserMessage(seq: number, time: number, text: string): void {
    this.owner.onStreamUserMessage(seq, time, text);
  }

  onLiveDelta(kind: string, text: string): void {
    this.owner.onStreamLiveDelta(kind, text);
  }

  onLiveBlock(kind: string, fullText: string): void {
    this.owner.onStreamLiveBlock(kind, fullText);
  }

  onLiveUsage(inputTokens: number, outputTokens: number): void {
    this.owner.onStreamLiveUsage(inputTokens, outputTokens);
  }

  onAssistantMessage(seq: number, time: number, turn: number, text: string,
    reasoning: string, usageIn: number, usageOut: number, model: string): void {
    this.owner.onStreamAssistantMessage(seq, time, turn, text, reasoning, usageIn, usageOut, model);
  }

  onToolCall(seq: number, time: number, turn: number, callId: string, name: string, args: string): void {
    this.owner.onStreamToolCall(seq, time, turn, callId, name, args);
  }

  onToolResult(callId: string, resultText: string): void {
    this.owner.onStreamToolResult(callId, resultText);
  }

  onTurnStart(seq: number, time: number, turn: number): void {
    this.owner.onStreamTurnStart(seq, time, turn);
  }

  onTurnEnd(seq: number, time: number, reasonKind: string, failureCode: string, failureMessage: string, live: boolean): void {
    this.owner.onStreamTurnEnd(seq, time, reasonKind, failureCode, failureMessage, live);
  }

  onTitleChanged(title: string): void {
    this.owner.onStreamTitleChanged(title);
  }

  onStreamDown(): void {
    this.owner.onStreamDown();
  }
}

@Component
export struct WorkspaceChatView {
  /** 合盖外屏紧凑模式：单栏两级导航。 */
  @Prop coverMode: boolean = false;

  @StorageProp('themeIsDark') dark: boolean = true;
  /** 底部系统导航条避让高度（px），输入区据此垫底。 */
  @StorageProp('bottomAvoidPx') bottomAvoidPx: number = 0;
  /** 系统侧滑/返回键弹出信号（Index.onBackPress 下发）。 */
  @StorageProp('backPopTick') @Watch('onBackPop') backPopTick: number = 0;
  /** 新建会话请求信号（首页"新建任务"/Tab"新建对话"下发）。 */
  @StorageProp('chatCreateTick') @Watch('onCreateTick') chatCreateTick: number = 0;
  /** 当前 Tab（Index 下发；0=本页）。组件常驻（Visibility 切换），据此感知重新可见并刷新列表。 */
  @StorageProp(KEY_CUR_TAB) @Watch('onCurTabChange') curTab: number = 1;
  /** 本机隐藏集被设置页改动：重载 hiddenIds 并刷新列表。 */
  @StorageProp(KEY_HIDDEN_TICK) @Watch('onHiddenTick') hiddenTick: number = 0;
  /** 工作区基线（web「工作区」同构分组）；空数组 = 基线不可用，退化为平铺列表。 */
  @State workspaces: WorkspaceVm[] = [];
  /** web 端已归档的会话 ID（各端隐藏）。 */
  @State archivedIds: string[] = [];
  /** 折叠的分区 key（默认全部展开；仅内存态）。 */
  @State foldedKeys: string[] = [];
  /** 列表展示模式：0 按时间分组 / 1 按项目分组（ZCode 同款切换，持久化）。 */
  @State groupMode: number = MODE_PROJECTS;
  /** 「显示更多」已展开的分区 key 集合（仅内存态）。 */
  @State moreKeys: string[] = [];

  @State listState: ListState = ListState.Loading;
  @State sessions: SessionSummaryVm[] = [];
  @State filter: string = '';
  @State selectedId: string = '';
  @State chatState: ChatState = ChatState.Idle;
  @State entries: ChatEntryVm[] = [];
  @State hasMore: boolean = false;
  @State oldestSeq: number = 0;
  @State throughSeq: number = -1;
  @State errorMsg: string = '';
  /** 已展开区域的键集合（r+seq 思考过程 / t+seq 正文 / seq 工具结果）。 */
  @State expandedSeqs: string[] = [];
  /** 合盖态当前层级：false 会话列表 / true 对话页。 */
  @State inChat: boolean = false;
  @State loadingOlder: boolean = false;
  /** 展开态左栏宽度：0 表示收起（对话区最大化）。 */
  @State listPaneWidth: number = 320;
  /** 输入框内容与发送中状态。 */
  @State inputText: string = '';
  @State sending: boolean = false;
  @State creating: boolean = false;
  /** 模型选择浮层与目录。 */
  @State modelPickerOpen: boolean = false;
  @State catalogLoading: boolean = false;
  @State catalogGroups: ModelGroupVm[] = [];
  @State catalogDefaultModel: string = '';
  /** 本地模型切换覆盖（优先于会话投影）。 */
  @State modelOverride: string = '';
  /** 本机隐藏的会话 ID。 */
  @State hiddenIds: string[] = [];
  /** 重命名浮层。 */
  @State renameOpen: boolean = false;
  @State renameText: string = '';
  @State renameTargetId: string = '';
  /** 乐观回显：发送瞬间本地先显示，服务器确认后移除。 */
  @State echoText: string = '';
  @State echoSending: boolean = false;
  /** 助手生成中（显示"正在输入"指示）。 */
  @State typing: boolean = false;
  /**
   * 流式打字机卡。注意：必须用 @State 字符串直接绑定渲染，不能走
   * "@Builder 按值传对象参数"——ArkUI 分支首次创建即捕获参数，
   * 之后整对象重赋值不会触发 @Builder 内刷新（卡片会冻结）。
   */
  @State liveActive: boolean = false;
  @State liveText: string = '';
  @State liveReasoning: string = '';
  @State liveThinkingOpen: boolean = false;
  /** 流式卡 live 用量（usage chunk 到达时更新）。 */
  @State liveUsageIn: number = 0;
  @State liveUsageOut: number = 0;
  /** 流式增量缓冲（80ms 节流 flush 到 liveEntry）。 */
  private streamBufText: string = '';
  private streamBufReasoning: string = '';
  private flushTimer: number = -1;
  /** 流客户端监听器（attachStream 惰性创建，避免字段初始化期引用 this）。 */
  private streamListener: ChatStreamListener | null = null;
  /** 自动贴底门控：用户上翻即暂停（否则流式期间被 80ms 一次的 scrollEdge 拽住），触底恢复。 */
  private followBottom: boolean = true;
  private lastScrollY: number = 0;
  /** 待发送图片附件（base64，不含 data: 前缀）。 */
  @State attachBase64: string = '';
  @State attachName: string = '';
  @State attachMediaType: string = '';
  /** 草稿模式：新任务页，首条消息发出时才真正创建会话。 */
  @State drafting: boolean = false;
  @State draftText: string = '';
  @State draftCwd: string = '';
  /** 工作目录选择浮层。 */
  @State wsPickerOpen: boolean = false;
  @State wsCustomOpen: boolean = false;
  @State wsCustomText: string = '';

  private scroller: Scroller = new Scroller();
  private inFlight: boolean = false;
  /** 已向下翻过更早历史：暂停自动刷新避免清掉已加载页。 */
  private loadedOlder: boolean = false;
  private autoTimer: number = -1;
  /** 发送后的短程追踪定时器。 */
  private pollTimer: number = -1;
  /** 静默同步连续失败计数。 */
  private chaseFailCount: number = 0;

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  /** 同步返回深度到 AppStorage（0 列表 / 1 对话 / 2 浮层），供 Index.onBackPress 判定。 */
  private setBackDepth(d: number): void {
    AppStorage.setOrCreate('chatBackDepth', d);
  }

  /** 系统返回：优先关浮层，再退草稿/会话列表。 */
  private onBackPop(): void {
    if (this.wsPickerOpen) {
      this.wsPickerOpen = false;
      this.wsCustomOpen = false;
      this.setBackDepth(this.drafting ? 1 : 0);
      return;
    }
    if (this.modelPickerOpen || this.renameOpen) {
      this.modelPickerOpen = false;
      this.renameOpen = false;
      this.setBackDepth(this.inChat ? 1 : 0);
      return;
    }
    if (this.drafting || this.inChat) {
    this.drafting = false;
    this.draftText = '';
    this.inChat = false;
    this.attachBase64 = '';
    this.attachName = '';
    this.attachMediaType = '';
    this.detachStream();
    this.setBackDepth(0);
  }
  }

  /** 响应跨页"新建会话"请求：进入草稿模式（不发请求，首条消息才建会话）。 */
  private onCreateTick(): void {
    this.enterDraft();
  }

  /** 重新切回会话 Tab：静默重拉列表（组件常驻不重建，web 端新增的会话靠此补齐）。 */
  private onCurTabChange(): void {
    if (this.curTab === TAB_SESSIONS) {
      this.refreshList(false);
    }
  }

  /** 本机隐藏集被设置页改动（逐个/全部恢复）：重载隐藏集，列表自动重渲染。 */
  private onHiddenTick(): void {
    this.loadHidden();
  }

  /** 进入新任务草稿页。 */
  private enterDraft(): void {
    this.selectedId = '';
    this.entries = [];
    this.chatState = ChatState.Idle;
    this.drafting = true;
    this.draftText = '';
    this.draftCwd = '';
    this.expandedSeqs = [];
    this.detachStream();
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    this.inChat = true;
    this.setBackDepth(1);
  }

  /** 草稿可发送条件。 */
  private canSendDraft(): boolean {
    return this.draftText.trim() !== '' && !this.creating;
  }

  /** 当前工作目录展示文案。 */
  private draftCwdLabel(): string {
    return this.draftCwd === '' ? '默认 · 服务器主目录' : this.draftCwd;
  }

  /** 最近使用过的工作目录（去重取 6 个）。 */
  private recentCwds(): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < this.sessions.length && out.length < 6; i++) {
      const cwd: string = this.sessions[i].cwd;
      if (cwd !== '' && out.indexOf(cwd) < 0) {
        out.push(cwd);
      }
    }
    return out;
  }

  /** 发送草稿：此刻才创建会话 → 打开 → 发送首条消息。 */
  private async sendDraft(): Promise<void> {
    const text: string = this.draftText.trim();
    if (text === '' || this.creating) {
      return;
    }
    this.creating = true;
    try {
      const ctx: common.Context = getContext(this);
      const s: SessionSummaryVm = await DshSessionsRepository.createSession(ctx, this.draftCwd);
      this.drafting = false;
      this.draftText = '';
      await this.openSession(s);
      this.echoText = text;
      this.echoSending = false;
      await DshSessionsRepository.sendText(ctx, s.sessionId, text, '', '', '');
      promptAction.showToast({ message: '已发送，正在等待 dsh 处理' });
      // 发送后首条消息已落库（非 blank），列表此刻才拉得到新会话
      this.refreshList(false);
      this.pollAfterSend();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      promptAction.showToast({ message: '创建失败：' + e.message });
    } finally {
      this.creating = false;
    }
  }

  aboutToAppear(): void {
    this.setBackDepth(0);
    this.refreshList(true);
    this.loadHidden();
    this.loadGroupMode();
    this.autoTimer = setInterval(() => {
      this.silentRefresh();
    }, 30000);
  }

  /** 恢复上次选择的列表展示模式（读取失败保持默认项目模式）。 */
  private loadGroupMode(): void {
    DshConfigStore.getListViewMode(getContext(this)).then((m: number) => {
      this.groupMode = m === MODE_GROUPED ? MODE_GROUPED : MODE_PROJECTS;
    }).catch((_e: BusinessError) => {
    });
  }

  /** 切换展示模式并持久化。 */
  private setGroupMode(mode: number): void {
    if (this.groupMode === mode) {
      return;
    }
    this.groupMode = mode;
    DshConfigStore.setListViewMode(getContext(this), mode).catch((_e: BusinessError) => {
    });
  }

  private async loadHidden(): Promise<void> {
    try {
      const ctx: common.Context = getContext(this);
      this.hiddenIds = await DshConfigStore.getHiddenSessions(ctx);
    } catch (err) {
      this.hiddenIds = [];
    }
  }

  aboutToDisappear(): void {
    if (this.autoTimer >= 0) {
      clearInterval(this.autoTimer);
      this.autoTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    this.detachStream();
  }

  /* ───────────── 数据加载 ───────────── */

  /** 拉取会话列表；manual=false 时静默（不闪 Loading），供自动刷新调用。 */
  private async refreshList(manual: boolean): Promise<void> {
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;
    if (manual) {
      this.listState = ListState.Loading;
    }
    try {
      const ctx: common.Context = getContext(this);
      // 工作区基线并行拉取（WS 临时连接，失败静默退化平铺；不阻塞会话列表先行渲染）
      DshSessionsRepository.workspaceBaseline(ctx, manual).then((b: WorkspaceBaselineVm | null) => {
        if (b !== null) {
          this.workspaces = b.workspaces;
          this.archivedIds = b.archivedSessionIds;
        }
      }).catch((err: BusinessError) => {
      });
      this.sessions = await DshSessionsRepository.listSessions(ctx);
      this.listState = ListState.Ready;
    } catch (err) {
      // 静默刷新失败且已有数据：保持现状不打扰（弱网下 30s 重试会自愈）
      if (manual || this.sessions.length === 0) {
        this.errorMsg = (err as BusinessError).message;
        this.listState = ListState.Failed;
      }
    } finally {
      this.inFlight = false;
    }
  }

  private async openSession(s: SessionSummaryVm): Promise<void> {
    this.selectedId = s.sessionId;
    this.throughSeq = s.asOfSeq;
    this.inChat = true;
    this.drafting = false;
    this.setBackDepth(1);
    this.setBackDepth(1);
    this.expandedSeqs = [];
    this.loadedOlder = false;
    this.modelOverride = '';
    this.echoText = '';
    this.clearLive();
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    await this.reloadHistory();
    this.attachStream();
    // 首页快捷任务复制后预填到输入框（只预填不发送）
    const prefill: string | undefined = AppStorage.get<string>('chatPrefill');
    if (prefill !== undefined && prefill !== '' && this.inputText === '') {
      this.inputText = prefill;
    }
    AppStorage.setOrCreate('chatPrefill', '');
  }

  private async reloadHistory(): Promise<void> {
    this.chatState = ChatState.Loading;
    this.loadedOlder = false;
    this.clearLive();
    this.followBottom = true;
    this.lastScrollY = 0;
    try {
      const ctx: common.Context = getContext(this);
      const page: HistoryPageVm = await DshSessionsRepository.loadHistory(ctx, this.selectedId, this.throughSeq, -1);
      this.entries = page.entries;
      this.hasMore = page.hasMore;
      this.oldestSeq = page.oldestSeq;
      this.typing = page.generating;
      this.chatState = ChatState.Ready;
      this.echoText = '';
      this.chaseFailCount = 0;
      this.scrollToBottom();
    } catch (err) {
      this.errorMsg = (err as BusinessError).message;
      this.chatState = ChatState.Failed;
    }
  }

  /** 30 秒静默刷新：列表页重拉会话列表；对话页仅追踪运行中会话的新消息。 */
  private async silentRefresh(): Promise<void> {
    if (this.curTab !== TAB_SESSIONS) {
      return;
    }
    if (this.inChat) {
      const sel: SessionSummaryVm | null = this.selectedSession();
      if (sel === null || !sel.running) {
        return;
      }
      await this.chaseNewMessages();
      return;
    }
    // 停留在列表页：web/PC 端新建或续聊的会话由此自动出现
    await this.refreshList(false);
  }

  /** 当前已显示的最大事件 seq（空列表为 -1）。 */
  private maxSeq(): number {
    if (this.entries.length === 0) {
      return -1;
    }
    return this.entries[this.entries.length - 1].seq;
  }

  /** 拉取最新一页：按最大 seq 判断更新，尾部增量合并且不清掉已翻的早期历史。 */
  private async chaseNewMessages(): Promise<void> {
    if (this.chatState !== ChatState.Ready || this.selectedId === '') {
      return;
    }
    try {
      const ctx: common.Context = getContext(this);
      // throughSeq 传 -1：由仓库层自动反查最新游标，确保能拿到新消息
      const page: HistoryPageVm = await DshSessionsRepository.loadHistory(ctx, this.selectedId, -1, -1);
      const pageMax: number = page.entries.length > 0 ? page.entries[page.entries.length - 1].seq : -1;
      const grew: boolean = pageMax > this.maxSeq();
      const genChanged: boolean = page.generating !== this.typing;
      if (grew) {
        if (!this.loadedOlder) {
          // 未翻过页：整页替换（含滚动贴底）
          this.entries = page.entries;
        } else {
          // 翻过页：只追加更新的尾部，保留已加载的早期历史
          const tail: ChatEntryVm[] = [];
          for (let i: number = 0; i < page.entries.length; i++) {
            if (page.entries[i].seq > this.maxSeq()) {
              tail.push(page.entries[i]);
            }
          }
          this.entries = this.entries.concat(tail);
        }
        this.hasMore = page.hasMore;
        if (!this.loadedOlder) {
          this.oldestSeq = page.oldestSeq;
        }
        this.echoText = '';
        this.scrollToBottom();
        this.refreshList(false);
      }
      if (genChanged && !DshStreamClient.isAlive()) {
        // 流式活跃时 typing 由 turn/end 驱动，轮询不得覆盖（避免竞态闪烁）
        this.typing = page.generating;
      }
      this.chaseFailCount = 0;
    } catch (err) {
      // 连续失败时提示一次，不再完全静默
      this.chaseFailCount++;
      if (this.chaseFailCount === 3) {
        promptAction.showToast({ message: '同步变慢了，请检查手机到服务器的网络' });
      }
    }
  }

  /** 发送后的短程高频追踪：每 2.5 秒一次、共 8 次（20 秒窗口）。 */
  private pollAfterSend(): void {
    // WS 流健康时事件实时到达，无需轮询兜底
    if (DshStreamClient.isAlive()) {
      return;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
    }
    let ticks: number = 0;
    this.pollTimer = setInterval(() => {
      ticks++;
      this.chaseNewMessages();
      if (ticks >= 8 && this.pollTimer >= 0) {
        clearInterval(this.pollTimer);
        this.pollTimer = -1;
      }
    }, 2500);
  }

  /* ───────────── WebSocket 流式（真打字机） ───────────── */

  /** 绑定流客户端到当前会话（openSession 后调用）。 */
  private attachStream(): void {
    const id: string = this.selectedId;
    if (id === '' || this.drafting) {
      return;
    }
    if (this.streamListener === null) {
      this.streamListener = new ChatStreamListener(this);
    }
    DshStreamClient.attach(getContext(this), id, this.streamListener);
  }

  /** 离开会话：断流 + 清理流式状态。 */
  private detachStream(): void {
    DshStreamClient.detach();
    this.clearLive();
  }

  /** 清空流式卡与缓冲（结算/轮次结束/离开会话时）。 */
  private clearLive(): void {
    this.streamBufText = '';
    this.streamBufReasoning = '';
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.liveActive = false;
    this.liveText = '';
    this.liveReasoning = '';
    this.liveThinkingOpen = false;
    this.liveUsageIn = 0;
    this.liveUsageOut = 0;
  }

  /** 流式增量 80ms 节流 flush：@State 字符串重赋值触发渲染，并贴底。 */
  private scheduleFlush(): void {
    if (this.flushTimer >= 0) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flushLive();
    }, 80);
  }

  private flushLive(): void {
    this.liveText = this.streamBufText;
    this.liveReasoning = this.streamBufReasoning;
    this.liveActive = this.streamBufText !== '' || this.streamBufReasoning !== '';
    if (this.followBottom) {
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  /** 追加一条条目（按 seq 去重，保持尾部追加语义）。 */
  private appendEntry(e: ChatEntryVm): void {
    if (e.seq >= 0 && e.seq <= this.maxSeq()) {
      return;
    }
    this.entries = this.entries.concat([e]);
    if (this.followBottom) {
      this.scrollToBottom();
    }
  }

  /* ── 流回调（由 ChatStreamListener 转发） ── */

  onStreamSnapshot(cursor: number): void {
    if (cursor > 0 && this.drafting === false) {
      this.throughSeq = cursor;
    }
  }

  onStreamUserMessage(seq: number, time: number, text: string): void {
    if (seq <= this.maxSeq()) {
      return;
    }
    const e: ChatEntryVm = {
      kind: ChatEntryKind.User, seq: seq, time: time, turn: 0,
      text: text, reasoning: '', usageIn: 0, usageOut: 0, model: '', tool: null,
    };
    this.echoText = '';
    this.appendEntry(e);
    this.refreshList(false);
  }

  onStreamLiveDelta(kind: string, text: string): void {
    if (kind === 'text') {
      this.streamBufText += text;
    } else {
      this.streamBufReasoning += text;
    }
    this.typing = true;
    this.scheduleFlush();
  }

  onStreamLiveBlock(kind: string, fullText: string): void {
    // 块结束 = 服务器权威整块内容，替换增量缓冲（纠正乱序/丢字）
    if (kind === 'text') {
      this.streamBufText = fullText;
    } else {
      this.streamBufReasoning = fullText;
    }
    this.scheduleFlush();
  }

  onStreamLiveUsage(inputTokens: number, outputTokens: number): void {
    this.liveUsageIn = inputTokens;
    this.liveUsageOut = outputTokens;
  }

  onStreamAssistantMessage(seq: number, time: number, turn: number, text: string,
    reasoning: string, usageIn: number, usageOut: number, model: string): void {
    // 结算：终结流式卡；正文为空且思考为空 = 工具步骤空壳帧，跳过
    this.clearLive();
    if (text === '' && reasoning === '') {
      return;
    }
    if (seq <= this.maxSeq()) {
      return;
    }
    const e: ChatEntryVm = {
      kind: ChatEntryKind.Assistant, seq: seq, time: time, turn: turn,
      text: text, reasoning: reasoning, usageIn: usageIn, usageOut: usageOut,
      model: model, tool: null,
    };
    this.echoText = '';
    this.appendEntry(e);
    this.refreshList(false);
  }

  onStreamToolCall(seq: number, time: number, turn: number, callId: string, name: string, args: string): void {
    if (seq <= this.maxSeq()) {
      return;
    }
    // 与仓库层同规格：入参截 2000 字（Write 类工具可能携带整文件内容）
    const trimmed: string = args.length > 2000 ? args.substring(0, 2000) + '…' : args;
    const tool: ToolCallVm = {
      callId: callId, name: name, arguments: trimmed, resultText: '', turn: turn,
    };
    const e: ChatEntryVm = {
      kind: ChatEntryKind.Tool, seq: seq, time: time, turn: turn,
      text: '', reasoning: '', usageIn: 0, usageOut: 0, model: '', tool: tool,
    };
    this.appendEntry(e);
  }

  onStreamToolResult(callId: string, resultText: string): void {
    // 按 callId 配对回填：重建对应条目对象并重赋数组，键含结果态触发 ForEach 重渲染
    const trimmed: string = resultText.length > 2000 ? resultText.substring(0, 2000) + '…' : resultText;
    const next: ChatEntryVm[] = [];
    let changed: boolean = false;
    for (let i: number = 0; i < this.entries.length; i++) {
      const e: ChatEntryVm = this.entries[i];
      if (!changed && e.tool !== null && e.tool.callId === callId) {
        const tool: ToolCallVm = {
          callId: e.tool.callId, name: e.tool.name, arguments: e.tool.arguments,
          resultText: trimmed, turn: e.tool.turn,
        };
        const updated: ChatEntryVm = {
          kind: e.kind, seq: e.seq, time: e.time, turn: e.turn,
          text: e.text, reasoning: e.reasoning, usageIn: e.usageIn, usageOut: e.usageOut,
          model: e.model, tool: tool,
        };
        next.push(updated);
        changed = true;
      } else {
        next.push(e);
      }
    }
    if (changed) {
      this.entries = next;
    }
  }

  onStreamTurnStart(seq: number, time: number, turn: number): void {
    // 只有"新轮次"（seq 越过已有条目）才置 typing；重放的旧轮次 start 不能打扰当前状态
    if (seq > this.maxSeq()) {
      const e: ChatEntryVm = {
        kind: ChatEntryKind.Turn, seq: seq, time: time, turn: turn,
        text: '第 ' + turn + ' 轮', reasoning: '', usageIn: 0, usageOut: 0, model: '', tool: null,
      };
      this.appendEntry(e);
      this.typing = true;
    }
  }

  onStreamTurnEnd(seq: number, time: number, reasonKind: string, failureCode: string,
    failureMessage: string, live: boolean): void {
    // 轮次结束 = 本轮生成彻底终止（幂等；snapshot 重放旧轮次时也安全）
    this.typing = false;
    this.clearLive();
    if (reasonKind === '' || reasonKind === 'completed') {
      return;
    }
    // 失败轮次没有 assistant/message，错误详情只在 turn/end 里——必须显式呈现
    let text: string = '生成失败：' + failureMessage;
    if (text.length < 12) {
      text = '生成失败（' + reasonKind + '）';
    }
    if (failureCode !== '') {
      text += ' [' + failureCode + ']';
    }
    if (seq > this.maxSeq()) {
      const e: ChatEntryVm = {
        kind: ChatEntryKind.Error, seq: seq, time: time, turn: 0,
        text: text, reasoning: '', usageIn: 0, usageOut: 0, model: '', tool: null,
      };
      this.appendEntry(e);
    }
    if (live) {
      promptAction.showToast({ message: text.length > 40 ? text.substring(0, 40) + '…' : text });
    }
  }

  onStreamTitleChanged(title: string): void {
    let changed: boolean = false;
    const next: SessionSummaryVm[] = [];
    for (let i: number = 0; i < this.sessions.length; i++) {
      const s: SessionSummaryVm = this.sessions[i];
      if (s.sessionId === this.selectedId && s.title !== title) {
        const updated: SessionSummaryVm = {
          sessionId: s.sessionId, title: title, updatedAt: s.updatedAt, running: s.running,
          cwd: s.cwd, turns: s.turns, lastPrompt: s.lastPrompt, asOfSeq: s.asOfSeq, model: s.model,
        };
        next.push(updated);
        changed = true;
      } else {
        next.push(s);
      }
    }
    if (changed) {
      this.sessions = next;
    }
  }

  onStreamDown(): void {
    // 流断开：转轮询兜底（chase 的 seq 去重保证与流式状态无缝衔接）
    if (this.echoText !== '' || this.selRunning()) {
      this.pollAfterSend();
    }
  }

  private async loadOlder(): Promise<void> {
    if (this.loadingOlder || !this.hasMore || this.oldestSeq <= 0) {
      return;
    }
    this.loadingOlder = true;
    try {
      const ctx: common.Context = getContext(this);
      const page: HistoryPageVm = await DshSessionsRepository.loadHistory(ctx, this.selectedId, this.throughSeq, this.oldestSeq);
      // 按 seq 去重合并（分页边界可能与已加载记录重叠）
      const merged: ChatEntryVm[] = page.entries.concat(this.entries);
      const seen: Set<number> = new Set<number>();
      const out: ChatEntryVm[] = [];
      for (let i: number = 0; i < merged.length; i++) {
        if (!seen.has(merged[i].seq)) {
          seen.add(merged[i].seq);
          out.push(merged[i]);
        }
      }
      this.entries = out;
      this.hasMore = page.hasMore;
      this.oldestSeq = page.oldestSeq > 0 ? page.oldestSeq : this.oldestSeq;
      this.loadedOlder = true;
    } catch (err) {
      promptAction.showToast({ message: '加载更早消息失败' });
    } finally {
      this.loadingOlder = false;
    }
  }

  private scrollToBottom(): void {
    // 分阶段滚动：重 Markdown 渲染需要多帧布局，单次定时会抢跑停在半空
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 120);
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 400);
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 900);
  }

  /** 展开态收起/展开左侧会话列表，对话区最大化。 */
  private toggleListPane(): void {
    animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.listPaneWidth = this.listPaneWidth === 0 ? 320 : 0;
    });
  }

  private canSend(): boolean {
    return (this.inputText.trim() !== '' || this.attachBase64 !== '') && !this.sending && this.selectedId !== '';
  }

  /** 从相册选择一张图片作为附件（base64 内嵌）。 */
  private async pickImage(): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1,
      });
      if (result.photoUris.length === 0) {
        return;
      }
      const uri: string = result.photoUris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      if (stat.size > 4 * 1024 * 1024) {
        fs.closeSync(file.fd);
        promptAction.showToast({ message: '图片请小于 4MB' });
        return;
      }
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file.fd);
      this.attachBase64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(buf));
      const lower: string = uri.toLowerCase();
      if (lower.endsWith('.png')) {
        this.attachMediaType = 'image/png';
        this.attachName = 'image.png';
      } else {
        this.attachMediaType = 'image/jpeg';
        this.attachName = 'image.jpg';
      }
    } catch (err) {
      promptAction.showToast({ message: '选择图片失败' });
    }
  }

  /** 长文折叠阈值（字符数）。 */
  private isLongText(text: string): boolean {
    return text.length > 300;
  }

  private isExpanded(key: string): boolean {
    return this.expandedSeqs.indexOf(key) >= 0;
  }

  /** 切换展开/折叠（支持多个区域同时展开）。 */
  private toggleExpand(key: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (let i: number = 0; i < this.expandedSeqs.length; i++) {
      if (this.expandedSeqs[i] === key) {
        found = true;
      } else {
        next.push(this.expandedSeqs[i]);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.expandedSeqs = next;
  }

  /** 发送当前输入：本地立即回显，服务器确认后由轮询替换为真实消息。 */
  private async sendCurrent(): Promise<void> {
    const text: string = this.inputText.trim();
    if (text === '' && this.attachBase64 === '') {
      return;
    }
    if (this.sending || this.selectedId === '') {
      return;
    }
    this.sending = true;
    this.echoText = (this.attachBase64 !== '' ? '🖼 ' : '') + text;
    this.echoSending = true;
    try {
      const ctx: common.Context = getContext(this);
      await DshSessionsRepository.sendText(ctx, this.selectedId, text,
        this.attachBase64, this.attachMediaType, this.attachName);
      this.inputText = '';
      this.attachBase64 = '';
      this.attachName = '';
      this.attachMediaType = '';
      this.echoSending = false;
      promptAction.showToast({ message: '已发送，正在等待 dsh 处理' });
      this.refreshList(false);
      // 静默增量追踪回复（不整页刷新、不闪屏）
      this.pollAfterSend();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.echoText = '';
      this.echoSending = false;
      const msg: string = e.message;
      if (msg.indexOf('not support') >= 0) {
        promptAction.showToast({ message: '当前模型不支持图片输入，请点右上角模型胶囊切换视觉模型' });
      } else {
        promptAction.showToast({ message: '发送失败：' + msg });
      }
    } finally {
      this.sending = false;
    }
  }

  /* ───────────── Markdown 渲染 ───────────── */

  /** 行内富文本：粗体加粗、行内码用等宽+强调色。 */
  @Builder
  runsText(runs: MdRun[], size: number, color: string) {
    Text() {
      ForEach(runs, (r: MdRun, i: number) => {
        if (r.mono) {
          Span(r.text)
            .fontSize(size - 2)
            .fontFamily('monospace')
            .fontColor(this.t().accent)
        } else if (r.link !== '') {
          Span(r.text)
            .fontColor(this.t().accent)
        } else if (r.bold) {
          Span(r.text)
            .fontWeight(FontWeight.Bold)
        } else {
          Span(r.text)
        }
      }, (r: MdRun, i: number) => i + '-' + r.text.length)
    }
    .fontSize(size)
    .fontColor(color)
    .lineHeight(size + 8)
  }

  /** 块级渲染：按 MdKind 分派样式。 */
  @Builder
  mdBlockView(b: MdBlock) {
    if (b.kind === MdKind.Code) {
      Text(b.code)
        .fontSize(12)
        .fontColor(this.t().termText)
        .fontFamily('monospace')
        .lineHeight(18)
        .padding(14)
        .borderRadius(10)
        .backgroundColor(this.t().termBg)
        .margin({ top: 8 })
        .width('100%')
    } else if (b.kind === MdKind.H1) {
      Column() {
        this.runsText(b.runs, 19, this.t().textPrimary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 12 })
    } else if (b.kind === MdKind.H2) {
      Column() {
        this.runsText(b.runs, 17, this.t().textPrimary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
    } else if (b.kind === MdKind.H3) {
      Column() {
        this.runsText(b.runs, 15.5, this.t().textPrimary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
    } else if (b.kind === MdKind.Bullet) {
      Row() {
        Text('•')
          .fontSize(15)
          .fontColor(this.t().accent)
          .width(16)
        Column() {
          this.runsText(b.runs, 15, this.t().textPrimary)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 5 })
    } else if (b.kind === MdKind.Ordered) {
      Row() {
        Text('' + b.order + '.')
          .fontSize(14)
          .fontColor(this.t().accent)
          .width(20)
        Column() {
          this.runsText(b.runs, 15, this.t().textPrimary)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 5 })
    } else if (b.kind === MdKind.Quote) {
      Row() {
        Text('▎')
          .fontSize(13)
          .fontColor(this.t().accent)
          .width(14)
        Column() {
          this.runsText(b.runs, 14, this.t().textSecondary)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 6 })
    } else if (b.kind === MdKind.Rule) {
      Column()
        .width('100%')
        .height(1)
        .backgroundColor(this.t().border)
        .margin({ top: 12, bottom: 4 })
    } else if (b.kind === MdKind.Table && b.table !== null) {
      Column() {
        if (b.table.header.length > 0) {
          Row() {
            ForEach(b.table.header, (cell: MdRun[], ci: number) => {
              Column() {
                this.runsText(cell, 13, this.t().textPrimary)
              }
              .layoutWeight(1)
              .padding(8)
              .border({ width: { bottom: 1 }, color: this.t().accent })
            }, (cell: MdRun[], ci: number) => 'h' + ci)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        ForEach(b.table.rows, (row: MdRun[], ri: number) => {
          Row() {
            ForEach(row, (cell: MdRun[], ci: number) => {
              Column() {
                this.runsText(cell, 13, this.t().textSecondary)
              }
              .layoutWeight(1)
              .padding(8)
              .border({ width: { bottom: 0.5 }, color: this.t().border })
            }, (cell: MdRun[], ci: number) => ri + '-' + ci)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (row: MdRun[], ri: number) => 'r' + ri)
      }
      .width('100%')
      .padding(6)
      .borderRadius(12)
      .backgroundColor(this.t().navActiveBg)
      .margin({ top: 8 })
    } else {
      Column() {
        this.runsText(b.runs, 15, this.t().textPrimary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 8 })
    }
  }

  /* ───────────── 模型选择 ───────────── */

  private currentModelLabel(): string {
    if (this.modelOverride !== '') {
      return this.modelOverride;
    }
    const sel: SessionSummaryVm | null = this.selectedSession();
    if (sel !== null && sel.model !== '') {
      return sel.model;
    }
    if (this.catalogDefaultModel !== '') {
      return this.catalogDefaultModel;
    }
    return '模型';
  }

  private async openModelPicker(): Promise<void> {
    this.modelPickerOpen = true;
    this.setBackDepth(2);
    if (this.catalogGroups.length > 0 || this.catalogLoading) {
      return;
    }
    this.catalogLoading = true;
    try {
      const ctx: common.Context = getContext(this);
      const catalog: CatalogVm = await DshSessionsRepository.modelCatalog(ctx);
      this.catalogGroups = catalog.groups;
      this.catalogDefaultModel = catalog.defaultModel;
    } catch (err) {
      promptAction.showToast({ message: '模型目录拉取失败' });
      this.modelPickerOpen = false;
      this.setBackDepth(1);
    } finally {
      this.catalogLoading = false;
    }
  }

  private async applyModel(g: ModelGroupVm, m: ModelItemVm): Promise<void> {
    if (this.selectedId === '') {
      return;
    }
    try {
      const ctx: common.Context = getContext(this);
      await DshSessionsRepository.selectModel(ctx, this.selectedId, g.id, m.id);
      this.modelOverride = m.id;
      this.modelPickerOpen = false;
      this.setBackDepth(1);
      promptAction.showToast({ message: '已切换到 ' + m.name });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      promptAction.showToast({ message: '切换失败：' + e.message });
    }
  }

  /* ───────────── 显示辅助 ───────────── */

  /** 可见会话：本机隐藏 + web 端已归档 过滤。 */
  private visibleSessions(): SessionSummaryVm[] {
    const out: SessionSummaryVm[] = [];
    for (let i: number = 0; i < this.sessions.length; i++) {
      const s: SessionSummaryVm = this.sessions[i];
      if (this.hiddenIds.indexOf(s.sessionId) >= 0) {
        continue;
      }
      if (this.archivedIds.indexOf(s.sessionId) >= 0) {
        continue;
      }
      out.push(s);
    }
    return out;
  }

  /** 列表分区：工作区按服务器展示序，成员按注册表手动排序；未分组（recency）殿后。 */
  private sections(): SessionSectionVm[] {
    const vis: SessionSummaryVm[] = this.visibleSessions();
    const secs: SessionSectionVm[] = [];
    if (this.workspaces.length === 0) {
      // 基线不可用：退化为单平铺（无分组头，走富信息行渲染）
      const flat: SessionSectionVm = { key: 'flat', title: '', path: '', sessions: vis, ungrouped: true, icon: '' };
      secs.push(flat);
      return secs;
    }
    const byId: Map<string, SessionSummaryVm> = new Map<string, SessionSummaryVm>();
    for (let i: number = 0; i < vis.length; i++) {
      byId.set(vis[i].sessionId, vis[i]);
    }
    const claimed: string[] = [];
    for (let w: number = 0; w < this.workspaces.length; w++) {
      const ws: WorkspaceVm = this.workspaces[w];
      const members: SessionSummaryVm[] = [];
      for (let j: number = 0; j < ws.sessionIds.length; j++) {
        const s: SessionSummaryVm | undefined = byId.get(ws.sessionIds[j]);
        if (s !== undefined) {
          members.push(s);
          claimed.push(s.sessionId);
        }
      }
      const sec: SessionSectionVm = {
        key: ws.workspaceId,
        title: ws.title,
        path: ws.path,
        sessions: members,
        ungrouped: false,
        icon: 'folder',
      };
      secs.push(sec);
    }
    const strays: SessionSummaryVm[] = [];
    for (let i: number = 0; i < vis.length; i++) {
      if (claimed.indexOf(vis[i].sessionId) < 0) {
        strays.push(vis[i]);
      }
    }
    strays.sort((a: SessionSummaryVm, b: SessionSummaryVm): number => b.updatedAt - a.updatedAt);
    if (strays.length > 0) {
      const sec: SessionSectionVm = {
        key: 'ungrouped',
        title: '未分组',
        path: '',
        sessions: strays,
        ungrouped: true,
        icon: 'hash',
      };
      secs.push(sec);
    }
    return secs;
  }

  /** 时间分组分区：今天 / 昨天 / 7 天内 / 30 天内 / 更早；仅含有会话的桶参与渲染。 */
  private timeSections(): SessionSectionVm[] {
    const vis: SessionSummaryVm[] = this.visibleSessions();
    const buckets: SessionSummaryVm[][] = [[], [], [], [], []];
    const now: Date = new Date();
    const startToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const dayMs: number = 24 * 60 * 60 * 1000;
    for (let i: number = 0; i < vis.length; i++) {
      const s: SessionSummaryVm = vis[i];
      let b: number = 4;
      if (s.updatedAt >= startToday) {
        b = 0;
      } else if (s.updatedAt >= startToday - dayMs) {
        b = 1;
      } else if (s.updatedAt >= startToday - 7 * dayMs) {
        b = 2;
      } else if (s.updatedAt >= startToday - 30 * dayMs) {
        b = 3;
      }
      buckets[b].push(s);
    }
    const secs: SessionSectionVm[] = [];
    for (let i: number = 0; i < buckets.length; i++) {
      if (buckets[i].length > 0) {
        const sec: SessionSectionVm = {
          key: 'tg:' + TIME_BUCKET_TITLES[i],
          title: TIME_BUCKET_TITLES[i],
          path: '',
          sessions: buckets[i],
          ungrouped: true,
          icon: 'clock',
        };
        secs.push(sec);
      }
    }
    return secs;
  }

  private isFolded(key: string): boolean {
    return this.foldedKeys.indexOf(key) >= 0;
  }

  /** 折叠/展开分区：替换数组触发 @State 重渲染。 */
  private toggleFold(key: string): void {
    const next: string[] = this.foldedKeys.slice();
    const idx: number = next.indexOf(key);
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(key);
    }
    this.foldedKeys = next;
  }

  private isMore(key: string): boolean {
    return this.moreKeys.indexOf(key) >= 0;
  }

  /** 展开/收起分区「显示更多」。 */
  private toggleMore(key: string): void {
    const next: string[] = this.moreKeys.slice();
    const idx: number = next.indexOf(key);
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(key);
    }
    this.moreKeys = next;
  }

  /** 分区当前展示的会话切片：未展开「显示更多」时截前 5 条。 */
  private previewSessions(sec: SessionSectionVm): SessionSummaryVm[] {
    if (this.isMore(sec.key) || sec.sessions.length <= SECTION_PREVIEW) {
      return sec.sessions;
    }
    return sec.sessions.slice(0, SECTION_PREVIEW);
  }

  /** 分区最新活动时间（ForEach 键成分：内容变化即重建行）。 */
  private newestOf(sec: SessionSectionVm): number {
    let newest: number = 0;
    for (let i: number = 0; i < sec.sessions.length; i++) {
      if (sec.sessions[i].updatedAt > newest) {
        newest = sec.sessions[i].updatedAt;
      }
    }
    return newest;
  }

  private filtered(): SessionSummaryVm[] {
    const kw: string = this.filter === '' ? '' : this.filter.toLowerCase();
    const vis: SessionSummaryVm[] = this.visibleSessions();
    const out: SessionSummaryVm[] = [];
    for (let i: number = 0; i < vis.length; i++) {
      const s: SessionSummaryVm = vis[i];
      if (kw !== '' && s.title.toLowerCase().indexOf(kw) < 0 && s.lastPrompt.toLowerCase().indexOf(kw) < 0) {
        continue;
      }
      out.push(s);
    }
    return out;
  }

  /** 长按会话：重命名（服务器级）/ 在本机隐藏。 */
  private confirmHideSession(s: SessionSummaryVm): void {
    AlertDialog.show({
      title: '会话操作',
      message: '「' + s.title + '」',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '重命名',
        fontColor: '#FFFFFF',
        backgroundColor: this.t().accent,
        action: () => {
          this.renameTargetId = s.sessionId;
          this.renameText = s.title === '(未命名会话)' ? '' : s.title;
          this.renameOpen = true;
          this.setBackDepth(2);
        },
      },
      secondaryButton: {
        value: '在本机隐藏',
        action: () => {
          this.hideSession(s);
        },
      },
    });
  }

  private async hideSession(s: SessionSummaryVm): Promise<void> {
    try {
      const ctx: common.Context = getContext(this);
      await DshConfigStore.hideSession(ctx, s.sessionId);
      await this.loadHidden();
      if (this.selectedId === s.sessionId) {
        this.selectedId = '';
        this.inChat = false;
        this.setBackDepth(0);
        this.chatState = ChatState.Idle;
        this.entries = [];
      }
      promptAction.showToast({ message: '已在本机隐藏' });
    } catch (err) {
      promptAction.showToast({ message: '隐藏失败' });
    }
  }

  /** 确认重命名：调用服务器 rename 并原位更新本地列表。 */
  private async confirmRename(): Promise<void> {
    const title: string = this.renameText.trim();
    if (title === '' || this.renameTargetId === '') {
      return;
    }
    try {
      const ctx: common.Context = getContext(this);
      await DshSessionsRepository.renameSession(ctx, this.renameTargetId, title);
      const next: SessionSummaryVm[] = [];
      for (let i: number = 0; i < this.sessions.length; i++) {
        if (this.sessions[i].sessionId === this.renameTargetId) {
          const updated: SessionSummaryVm = {
            sessionId: this.sessions[i].sessionId,
            title: title,
            updatedAt: this.sessions[i].updatedAt,
            running: this.sessions[i].running,
            cwd: this.sessions[i].cwd,
            turns: this.sessions[i].turns,
            lastPrompt: this.sessions[i].lastPrompt,
            asOfSeq: this.sessions[i].asOfSeq,
            model: this.sessions[i].model,
          };
          next.push(updated);
        } else {
          next.push(this.sessions[i]);
        }
      }
      this.sessions = next;
      this.renameOpen = false;
      this.setBackDepth(1);
      promptAction.showToast({ message: '已重命名' });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      promptAction.showToast({ message: '重命名失败：' + e.message });
    }
  }

  /** 当前选中会话是否在运行。 */
  private selRunning(): boolean {
    const sel: SessionSummaryVm | null = this.selectedSession();
    return sel !== null && sel.running;
  }

  /** 停止当前会话的生成。 */
  private async cancelRunning(): Promise<void> {
    if (this.selectedId === '') {
      return;
    }
    try {
      const ctx: common.Context = getContext(this);
      await DshSessionsRepository.cancelSession(ctx, this.selectedId);
      promptAction.showToast({ message: '已发送停止指令' });
      this.refreshList(false);
      setTimeout(() => {
        this.chaseNewMessages();
      }, 1500);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      promptAction.showToast({ message: '停止失败：' + e.message });
    }
  }

  /** 重命名浮层。 */
  @Builder
  renameOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.55)')
      .onClick(() => {
        this.renameOpen = false;
      this.setBackDepth(1);
      })

    Column({ space: 14 }) {
      Text('重命名会话')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.t().textPrimary)
        .width('100%')

      TextInput({ text: this.renameText, placeholder: '输入新名称…' })
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontColor(this.t().textPrimary)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.renameText = v;
        })
        .onSubmit(() => {
          this.confirmRename();
        })

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(this.t().textSecondary)
          .backgroundColor(this.t().navActiveBg)
          .borderRadius(12)
          .onClick(() => {
            this.renameOpen = false;
      this.setBackDepth(1);
          })
        Button('确认')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(this.t().onAccent)
          .backgroundColor(this.t().accent)
          .borderRadius(12)
          .onClick(() => {
            this.confirmRename();
          })
      }
      .width('100%')
    }
    .width('80%')
    .constraintSize({ maxWidth: 420 })
    .padding(20)
    .borderRadius(20)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  private selectedSession(): SessionSummaryVm | null {
    for (let i: number = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === this.selectedId) {
        return this.sessions[i];
      }
    }
    return null;
  }

  private relTime(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const diff: number = Date.now() - ts;
    const minute: number = 60 * 1000;
    if (diff < minute) {
      return '刚刚';
    }
    if (diff < 60 * minute) {
      return Math.floor(diff / minute) + ' 分钟前';
    }
    if (diff < 24 * 60 * minute) {
      return Math.floor(diff / (60 * minute)) + ' 小时前';
    }
    return Math.floor(diff / (24 * 60 * minute)) + ' 天前';
  }

  private fmtClock(ts: number): string {
    const d: Date = new Date(ts);
    const hh: string = d.getHours() < 10 ? '0' + d.getHours() : '' + d.getHours();
    const mm: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : '' + d.getMinutes();
    return hh + ':' + mm;
  }

  private selTitle(): string {
    const sel: SessionSummaryVm | null = this.selectedSession();
    return sel === null ? '会话' : sel.title;
  }

  private selCwd(): string {
    const sel: SessionSummaryVm | null = this.selectedSession();
    return sel === null ? '' : sel.cwd;
  }

  /* ───────────── 布局 ───────────── */

  build() {
    Stack() {
      this.mainLayout()
      if (this.wsPickerOpen) {
        this.wsPickerOverlay()
      }
      if (this.modelPickerOpen) {
        this.modelPickerOverlay()
      }
      if (this.renameOpen) {
        this.renameOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  mainLayout() {
    if (this.coverMode) {
      Stack() {
        Column() {
          if (this.inChat) {
            this.chatPane()
          } else {
            this.listPane()
          }
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    } else {
      Row() {
        this.listPane()
        Column() {
          this.chatPane()
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 新任务草稿页：美观居中构图，首条消息发出时才创建会话。 */
  @Builder
  draftComposer() {
    Column() {
      if (this.coverMode) {
        Row() {
          Column() {
            Text('‹')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.t().accent)
          }
          .width(48)
          .height(48)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.drafting = false;
            this.draftText = '';
            this.inChat = false;
            this.setBackDepth(0);
          })
        }
        .width('100%')
      }

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 4 }) {
            Text('✦')
              .fontSize(26)
              .fontColor(this.t().onAccent)
              .width(56)
              .height(56)
              .textAlign(TextAlign.Center)
              .borderRadius(18)
              .linearGradient({
                angle: 135,
                colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
              })
            Text('新任务')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.t().textPrimary)
              .margin({ top: 14 })
            Text('描述要做的事，发送时自动创建会话')
              .fontSize(13)
              .fontColor(this.t().textSecondary)
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 10 })

          Column() {
            TextArea({ text: this.draftText, placeholder: '例如：帮我抓取今天的 AI 领域舆情，整理成摘要…' })
              .width('100%')
              .height(156)
              .fontSize(15)
              .fontColor(this.t().textPrimary)
              .placeholderColor(this.t().textTertiary)
              .backgroundColor(Color.Transparent)
              // padding(0) 会让首行文字贴住组件上沿，CJK 字形左上角被裁掉半个角
              .padding({ left: 4, right: 4, top: 8, bottom: 8 })
              .onChange((v: string) => {
                this.draftText = v;
              })
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor(this.t().navActiveBg)
          .border({ width: 1, color: this.t().border })

          Row({ space: 10 }) {
            Text('📁')
              .fontSize(17)
            Column({ space: 2 }) {
              Text('工作目录')
                .fontSize(11)
                .fontColor(this.t().textTertiary)
              Text(this.draftCwdLabel())
                .fontSize(13)
                .fontColor(this.t().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('更换 ▾')
              .fontSize(12)
              .fontColor(this.t().accent)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(14)
          .backgroundColor(this.t().bgCard)
          .border({ width: 1, color: this.t().border })
          .onClick(() => {
            this.wsPickerOpen = true;
            this.setBackDepth(2);
          })

          Column() {
            Text(this.creating ? '创建中…' : '发送任务 ➤')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.canSendDraft() ? this.t().onAccent : this.t().textTertiary)
          }
          .width('100%')
          .height(52)
          .justifyContent(FlexAlign.Center)
          .borderRadius(16)
          .linearGradient({
            angle: 135,
            colors: this.canSendDraft()
              ? [[this.t().accent, 0.0], [this.t().accent2, 1.0]]
              : [[this.t().navActiveBg, 0.0], [this.t().navActiveBg, 1.0]],
          })
          .opacity(this.canSendDraft() ? 1.0 : 0.6)
          .onClick(() => {
            this.sendDraft();
          })

          Text('提示：不输入直接返回，不会创建任何会话')
            .fontSize(11)
            .fontColor(this.t().textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .constraintSize({ maxWidth: 640 })
        .padding({ left: 20, right: 20, top: 26, bottom: 30 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  /** 工作目录选择浮层：默认 / 最近使用 / 自定义路径。 */
  @Builder
  wsPickerOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.55)')
      .onClick(() => {
        this.wsPickerOpen = false;
        this.wsCustomOpen = false;
        this.setBackDepth(1);
      })

    Column({ space: 10 }) {
      Text('选择工作目录')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.t().textPrimary)
        .width('100%')
        .margin({ bottom: 4 })

      this.wsRow('默认 · 服务器主目录', this.draftCwd === '', () => {
        this.draftCwd = '';
        this.wsPickerOpen = false;
        this.setBackDepth(1);
      })
      ForEach(this.recentCwds(), (cwd: string) => {
        this.wsRow(cwd, this.draftCwd === cwd, () => {
          this.draftCwd = cwd;
          this.wsPickerOpen = false;
          this.setBackDepth(1);
        })
      }, (cwd: string) => cwd)

      if (!this.wsCustomOpen) {
        this.wsRow('输入其他路径…', false, () => {
          this.wsCustomOpen = true;
        })
      } else {
        Row({ space: 10 }) {
          TextInput({ text: this.wsCustomText, placeholder: '/absolute/path' })
            .layoutWeight(1)
            .height(42)
            .fontSize(13)
            .fontColor(this.t().textPrimary)
            .placeholderColor(this.t().textTertiary)
            .backgroundColor(this.t().navActiveBg)
            .borderRadius(10)
            .onChange((v: string) => {
              this.wsCustomText = v;
            })
          Button('确定')
            .height(42)
            .fontSize(13)
            .fontColor(this.t().onAccent)
            .backgroundColor(this.t().accent)
            .borderRadius(10)
            .onClick(() => {
              const p: string = this.wsCustomText.trim();
              if (p !== '') {
                this.draftCwd = p;
                this.wsPickerOpen = false;
                this.wsCustomOpen = false;
                this.setBackDepth(1);
              }
            })
        }
        .width('100%')
      }
    }
    .width('86%')
    .constraintSize({ maxWidth: 520 })
    .padding(18)
    .borderRadius(20)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  @Builder
  wsRow(label: string, selected: boolean, action: () => void) {
    Row({ space: 8 }) {
      Text(selected ? '● ' : '○ ')
        .fontSize(13)
        .fontColor(selected ? this.t().accent : this.t().textTertiary)
      Text(label)
        .fontSize(13.5)
        .fontColor(this.t().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(selected ? this.t().navActiveBg : Color.Transparent)
    .onClick(() => {
      action();
    })
  }

  /** 模型选择浮层：遮罩 + 目录卡片。 */
  @Builder
  modelPickerOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.55)')
      .onClick(() => {
        this.modelPickerOpen = false;
      this.setBackDepth(1);
      })

    Column() {
      Row() {
        Text('选择模型')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
          .layoutWeight(1)
        Column() {
          Text('✕')
            .fontSize(16)
            .fontColor(this.t().textSecondary)
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.modelPickerOpen = false;
      this.setBackDepth(1);
        })
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.catalogLoading) {
        Column() {
          LoadingProgress()
            .width(32)
            .height(32)
            .color(this.t().accent)
        }
        .width('100%')
        .padding({ top: 30, bottom: 30 })
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.catalogGroups, (g: ModelGroupVm) => {
              Column() {
                Text(g.name)
                  .fontSize(12)
                  .fontColor(this.t().textTertiary)
                  .margin({ top: 10, bottom: 6 })
                ForEach(g.models, (m: ModelItemVm) => {
                  Column() {
                    Row() {
                      Text(this.currentModelLabel() === m.id ? '● ' : '○ ')
                        .fontSize(13)
                        .fontColor(this.currentModelLabel() === m.id ? this.t().accent : this.t().textTertiary)
                      Text(m.name)
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.t().textPrimary)
                        .layoutWeight(1)
                    }
                    .width('100%')
                    if (m.description !== '') {
                      Text(m.description)
                        .fontSize(11.5)
                        .fontColor(this.t().textSecondary)
                        .lineHeight(16)
                        .margin({ top: 4 })
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding(14)
                  .borderRadius(12)
                  .backgroundColor(this.currentModelLabel() === m.id ? this.t().navActiveBg : Color.Transparent)
                  .margin({ bottom: 4 })
                  .onClick(() => {
                    this.applyModel(g, m);
                  })
                }, (m: ModelItemVm) => g.id + '/' + m.id)
              }
              .width('100%')
            }, (g: ModelGroupVm) => g.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('86%')
    .constraintSize({ maxWidth: 560, maxHeight: '72%' })
    .padding(18)
    .borderRadius(20)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  /** 左栏 / 合盖列表页：标题 + 模式切换 + 搜索 + 会话列表 + 新建。 */
  @Builder
  listPane() {
    Column() {
      Row() {
        Column() {
          Text('会话')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.t().textPrimary)
          Text(this.visibleSessions().length > 0 ? '' + this.visibleSessions().length + ' 个会话' : 'dsh 服务器')
            .fontSize(12)
            .fontColor(this.t().textTertiary)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(20)
            .fontColor([this.listState === ListState.Loading ? this.t().textTertiary : this.t().accent])
        }
        .width(48)
        .height(48)
        .borderRadius(14)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.t().navActiveBg)
        .onClick(() => {
          this.refreshList(true);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 12, top: 14, bottom: 10 })

      this.modeSwitcher()

      Row() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(15)
          .fontColor([this.t().textTertiary])
        TextInput({ placeholder: '搜索会话…' })
          .placeholderColor(this.t().textTertiary)
          .fontColor(this.t().textPrimary)
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .margin({ left: 8 })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.filter = v;
          })
      }
      .width('100%')
      .height(42)
      .borderRadius(13)
      .backgroundColor(this.t().navActiveBg)
      .border({ width: 1, color: this.t().border })
      .padding({ left: 14, right: 14 })
      .margin({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (this.listState === ListState.Loading) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(this.t().accent)
          Text('正在拉取会话…')
            .fontSize(13)
            .fontColor(this.t().textTertiary)
            .margin({ top: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.listState === ListState.Failed) {
        Column() {
          Text('⚠️')
            .fontSize(34)
          Text('会话拉取失败')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.t().textPrimary)
            .margin({ top: 10 })
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(this.t().textTertiary)
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
          Text('重试')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.t().accent)
            .padding({ top: 14, bottom: 14, left: 30, right: 30 })
            .borderRadius(14)
            .backgroundColor(this.t().navActiveBg)
            .margin({ top: 14 })
            .onClick(() => {
              this.refreshList(true);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 30, right: 30 })
      } else {
        Scroll() {
          Column() {
            if (this.filter === '') {
              if (this.groupMode === MODE_PROJECTS && this.workspaces.length > 0) {
                // 项目模式：工程目录分区（ZCode「项目」同构）
                ForEach(this.sections(), (sec: SessionSectionVm) => {
                  this.sectionBlock(sec)
                }, (sec: SessionSectionVm) => sec.key + ':' + (this.isFolded(sec.key) ? 'f' : 'e')
                  + ':' + (this.isMore(sec.key) ? 'm' : 'p')
                  + ':' + sec.sessions.length + ':' + this.newestOf(sec))
              } else {
                // 分组模式（或项目基线不可用）：按时间分段
                ForEach(this.timeSections(), (sec: SessionSectionVm) => {
                  this.sectionBlock(sec)
                }, (sec: SessionSectionVm) => sec.key + ':' + (this.isFolded(sec.key) ? 'f' : 'e')
                  + ':' + (this.isMore(sec.key) ? 'm' : 'p')
                  + ':' + sec.sessions.length + ':' + this.newestOf(sec))
              }
              if (this.visibleSessions().length === 0) {
                Text('没有会话')
                  .fontSize(13)
                  .fontColor(this.t().textTertiary)
                  .margin({ top: 30 })
              }
            } else {
              // 搜索中：平铺（富信息行）
              ForEach(this.filtered(), (s: SessionSummaryVm) => {
                this.sessionRow(s)
              }, (s: SessionSummaryVm) => s.sessionId)
              if (this.filtered().length === 0) {
                Text('没有匹配的会话')
                  .fontSize(13)
                  .fontColor(this.t().textTertiary)
                  .margin({ top: 30 })
              }
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .padding({ left: 10, right: 10, top: 8 })
      }

      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(16)
          .fontColor([this.t().onAccent])
        Text('新建会话')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.t().onAccent)
      }
      .width('100%')
      .height(46)
      .justifyContent(FlexAlign.Center)
      .borderRadius(14)
      .linearGradient({
        angle: 135,
        colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
      })
      .margin({ left: 16, right: 16, top: 10, bottom: 14 })
      .onClick(() => {
        this.enterDraft();
      })
    }
    .width(this.coverMode ? '100%' : this.listPaneWidth)
    .height('100%')
    .border(this.coverMode
      ? { width: { bottom: 0, right: 0, top: 0, left: 0 }, color: Color.Transparent }
      : {
        width: { right: this.listPaneWidth > 0 ? 0.5 : 0 },
        color: this.t().border,
      })
  }

  /** 展示模式切换（ZCode 同款）：⌗ 分组（按时间）/ 📁 项目（按工程目录）。 */
  @Builder
  modeSwitcher() {
    Row({ space: 8 }) {
      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.hash'))
          .fontSize(14)
          .fontColor([this.groupMode === MODE_GROUPED ? this.t().accent : this.t().textTertiary])
        Text('分组')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.groupMode === MODE_GROUPED ? this.t().accent : this.t().textSecondary)
      }
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(999)
      .backgroundColor(this.groupMode === MODE_GROUPED ? this.t().navActiveBg : Color.Transparent)
      .border({ width: 1, color: this.groupMode === MODE_GROUPED ? this.t().border : Color.Transparent })
      .onClick(() => {
        this.setGroupMode(MODE_GROUPED);
      })

      Row({ space: 5 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(14)
          .fontColor([this.groupMode === MODE_PROJECTS ? this.t().accent : this.t().textTertiary])
        Text('项目')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.groupMode === MODE_PROJECTS ? this.t().accent : this.t().textSecondary)
      }
      .height(30)
      .padding({ left: 12, right: 12 })
      .borderRadius(999)
      .backgroundColor(this.groupMode === MODE_PROJECTS ? this.t().navActiveBg : Color.Transparent)
      .border({ width: 1, color: this.groupMode === MODE_PROJECTS ? this.t().border : Color.Transparent })
      .onClick(() => {
        this.setGroupMode(MODE_PROJECTS);
      })

      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 2, bottom: 10 })
  }

  /** 分区：工作区/时间头 + 可折叠的成员会话（紧凑行），超出 5 条折叠进「显示更多」。 */
  @Builder
  sectionBlock(sec: SessionSectionVm) {
    Column() {
      this.sectionHeader(sec)
      if (!this.isFolded(sec.key)) {
        Column() {
          ForEach(this.previewSessions(sec), (s: SessionSummaryVm) => {
            this.groupedSessionRow(s)
          }, (s: SessionSummaryVm) => s.sessionId)
          if (sec.sessions.length > SECTION_PREVIEW) {
            this.moreRow(sec)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
  }

  /** 「显示更多 / 收起」行（ZCode 同款）：只展开本分区剩余会话。 */
  @Builder
  moreRow(sec: SessionSectionVm) {
    Row({ space: 4 }) {
      Text(this.isMore(sec.key) ? '收起' : '显示更多 ' + (sec.sessions.length - SECTION_PREVIEW) + ' 条')
        .fontSize(12)
        .fontColor(this.t().accent)
      if (this.isMore(sec.key)) {
        SymbolGlyph($r('sys.symbol.chevron_up'))
          .fontSize(11)
          .fontColor([this.t().accent])
      } else {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(11)
          .fontColor([this.t().accent])
      }
    }
    .width('100%')
    .height(32)
    .padding({ left: 30 })
    .borderRadius(10)
    .onClick(() => {
      this.toggleMore(sec.key);
    })
  }

  /** 工作区/未分组/时间段分区头：折叠箭头 + 图标 + 标题 + 成员数徽标。 */
  @Builder
  sectionHeader(sec: SessionSectionVm) {
    Row() {
      if (this.isFolded(sec.key)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([this.t().textTertiary])
          .width(16)
      } else {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([this.t().textTertiary])
          .width(16)
      }
      if (sec.icon === 'folder') {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(16)
          .fontColor([this.t().accent])
          .margin({ right: 6 })
      } else if (sec.icon === 'hash') {
        SymbolGlyph($r('sys.symbol.hash'))
          .fontSize(15)
          .fontColor([this.t().accent])
          .margin({ right: 6 })
      } else if (sec.icon === 'clock') {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(15)
          .fontColor([this.t().accent])
          .margin({ right: 6 })
      }
      Text(sec.title)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(sec.ungrouped ? this.t().textSecondary : this.t().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('' + sec.sessions.length)
        .fontSize(10)
        .fontColor(this.t().textTertiary)
        .padding({ left: 7, right: 7, top: 1, bottom: 1 })
        .borderRadius(999)
        .backgroundColor(this.t().navActiveBg)
    }
    .width('100%')
    .height(36)
    .padding({ left: 8, right: 8 })
    .borderRadius(10)
    .margin({ top: sec.ungrouped ? 12 : 6 })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        if (!sec.ungrouped && sec.path !== '') {
          promptAction.showToast({ message: sec.path });
        }
      }))
    .onClick(() => {
      this.toggleFold(sec.key);
    })
  }

  /** 分组内的紧凑会话行：状态点 + 标题 + 运行徽标 + 相对时间（web 侧边栏同构）。 */
  @Builder
  groupedSessionRow(s: SessionSummaryVm) {
    Row() {
      Column() {
        if (s.running) {
          Circle()
            .width(6)
            .height(6)
            .fill(this.t().success)
        } else {
          Circle()
            .width(5)
            .height(5)
            .fill(this.t().textTertiary)
            .opacity(0.35)
        }
      }
      .width(14)
      .alignItems(HorizontalAlign.Center)

      Text(s.title)
        .fontSize(14)
        .fontWeight(this.selectedId === s.sessionId ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.selectedId === s.sessionId ? this.t().accent : this.t().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 6 })

      if (s.running) {
        Text('运行中')
          .fontSize(9)
          .fontColor(this.t().success)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor(this.dark ? 'rgba(52,211,153,0.12)' : 'rgba(14,159,110,0.10)')
          .margin({ right: 6 })
      }
      Text(this.relTime(s.updatedAt))
        .fontSize(11)
        .fontColor(this.t().textTertiary)
    }
    .width('100%')
    .height(40)
    .padding({ left: 26, right: 12 })
    .borderRadius(12)
    .backgroundColor(this.selectedId === s.sessionId ? this.t().navActiveBg : Color.Transparent)
    .margin({ bottom: 2 })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        this.confirmHideSession(s);
      }))
    .onClick(() => {
      if (this.selectedId !== s.sessionId || !this.inChat) {
        this.openSession(s);
      } else if (this.coverMode) {
        this.inChat = true;
      }
    })
  }

  @Builder
  sessionRow(s: SessionSummaryVm) {
    Row() {
      Column() {
        Circle()
          .width(9)
          .height(9)
          .fill(s.running ? this.t().success : this.t().textTertiary)
          .opacity(s.running ? 1 : 0.4)
      }
      .width(16)
      .alignItems(HorizontalAlign.Center)
      .margin({ top: 5 })

      Column() {
        Text(s.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.t().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(s.lastPrompt === '' ? s.cwd : s.lastPrompt)
          .fontSize(12)
          .fontColor(this.t().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
        Row() {
          if (s.turns > 0) {
            Text('' + s.turns + ' 轮')
              .fontSize(11)
              .fontColor(this.t().accent)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor(this.t().navActiveBg)
          }
          Blank()
          Text(this.relTime(s.updatedAt))
            .fontSize(11)
            .fontColor(this.t().textTertiary)
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(12)
    .borderRadius(16)
    .backgroundColor(this.selectedId === s.sessionId ? this.t().navActiveBg : Color.Transparent)
    .border({
      width: this.selectedId === s.sessionId ? 1 : 0,
      color: this.selectedId === s.sessionId ? this.t().accent : this.t().border,
    })
    .margin({ bottom: 4 })
    .gesture(LongPressGesture({ repeat: false })
      .onAction(() => {
        this.confirmHideSession(s);
      }))
    .onClick(() => {
      if (this.selectedId !== s.sessionId || !this.inChat) {
        this.openSession(s);
      } else if (this.coverMode) {
        this.inChat = true;
      }
    })
  }

  /** 右栏 / 合盖对话页。 */
  @Builder
  chatPane() {
    Column() {
      Column() {
        if (this.drafting) {
          this.draftComposer()
        } else {
          this.chatHeader()
      if (this.chatState === ChatState.Loading) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(this.t().accent)
          Text('正在加载对话…')
            .fontSize(13)
            .fontColor(this.t().textTertiary)
            .margin({ top: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.chatState === ChatState.Failed) {
        Column() {
          Text('⚠️')
            .fontSize(34)
          Text('对话加载失败')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.t().textPrimary)
            .margin({ top: 10 })
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(this.t().textTertiary)
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
          Text('重试')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.t().accent)
            .padding({ top: 14, bottom: 14, left: 30, right: 30 })
            .borderRadius(14)
            .backgroundColor(this.t().navActiveBg)
            .margin({ top: 14 })
            .onClick(() => {
              this.refreshList(true);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 30, right: 30 })
      } else if (this.chatState === ChatState.Idle) {
        Column() {
          Text('◧')
            .fontSize(40)
            .fontColor(this.t().textTertiary)
          Text('从左侧选择一个会话')
            .fontSize(14)
            .fontColor(this.t().textTertiary)
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.scroller) {
          Column() {
            if (this.hasMore) {
                Text(this.loadingOlder ? '加载中…' : '加载更早的 50 条 ▴')
                  .fontSize(12)
                  .fontColor(this.t().accent)
                  .padding({ top: 10, bottom: 10, left: 24, right: 24 })
                  .borderRadius(14)
                  .backgroundColor(this.t().navActiveBg)
                  .margin({ top: 10 })
                  .alignSelf(ItemAlign.Center)
                  .onClick(() => {
                    this.loadOlder();
                  })
              }
              ForEach(this.entries, (e: ChatEntryVm, idx: number) => {
                Row() {
                  this.railNode(e, idx)
                  Column() {
                    if (e.kind === ChatEntryKind.Turn) {
                      this.turnSep(e)
                    } else if (e.kind === ChatEntryKind.User) {
                      this.userBubble(e)
                    } else if (e.kind === ChatEntryKind.Assistant) {
                      this.assistantCard(e, false)
                    } else if (e.kind === ChatEntryKind.Error) {
                      this.errorCard(e)
                    } else {
                      this.toolRow(e)
                    }
                  }
                  .layoutWeight(1)
                  .padding({ left: 12 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }, (e: ChatEntryVm) => (e.tool !== null && e.tool.resultText !== '' ? 'R' : '') + e.seq)
              if (this.liveActive) {
                // WebSocket 流式打字机卡：直接读 @State 字符串，每个 flush 都能刷新
                Row() {
                  Column() {
                    Circle()
                      .width(8)
                      .height(8)
                      .fill(this.t().accent2)
                      .margin({ top: 14 })
                  }
                  .width(18)
                  .alignItems(HorizontalAlign.Center)
                  Column() {
                    this.liveAssistantCard()
                  }
                  .layoutWeight(1)
                  .padding({ left: 12 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }
              if (this.typing && !this.liveActive) {
                Row({ space: 8 }) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color(this.t().accent)
                  Text('dsh 正在输入…')
                    .fontSize(12)
                    .fontColor(this.t().textSecondary)
                }
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .borderRadius(999)
                .backgroundColor(this.t().navActiveBg)
                .border({ width: 1, color: this.t().border })
                .margin({ top: 10 })
                .alignSelf(ItemAlign.Start)
              }
              if (this.echoText !== '') {
                Column() {
                  Text(this.echoText)
                    .fontSize(15)
                    .fontColor(this.t().textPrimary)
                    .lineHeight(22)
                  if (this.echoSending) {
                    Text('发送中…')
                      .fontSize(10)
                      .fontColor(this.t().textTertiary)
                      .margin({ top: 4 })
                  }
                }
                .constraintSize({ maxWidth: this.coverMode ? '86%' : '70%' })
                .padding({ left: 20, right: 20, top: 14, bottom: 14 })
                .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 5 })
                .backgroundColor(this.dark ? 'rgba(34,211,238,0.14)' : '#E8F0FE')
                .border({ width: 1, color: this.dark ? 'rgba(34,211,238,0.32)' : '#C9DDF9' })
                .margin({ top: 10 })
                .alignSelf(ItemAlign.End)
              }
            }
            .width('100%')
            // 短会话时内容锚定底部、紧贴输入框；长会话正常滚动
            .constraintSize({ minHeight: '100%' })
            .justifyContent(FlexAlign.End)
            .padding({ left: 14, right: 14, bottom: 12 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScroll((x: number, y: number) => {
          // offset 减小 = 用户在往上翻：暂停自动贴底（程序化贴底只增不减，不会误判）
          if (y < this.lastScrollY - 1) {
            this.followBottom = false;
          }
          this.lastScrollY = y;
        })
        .onScrollEdge((edge: Edge) => {
          if (edge === Edge.Bottom) {
            this.followBottom = true;
          }
        })
      }
        this.inputBar();
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 860 })
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  chatHeader() {
    Row() {
      if (this.coverMode) {
        Column() {
          Text('‹')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.t().accent)
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.inChat = false;
          this.setBackDepth(0);
        })
      }

      if (!this.coverMode) {
        // 展开态：收起/展开左侧会话列表，让对话区最大化
        Column() {
          Text(this.listPaneWidth === 0 ? '◫' : '◧')
            .fontSize(20)
            .fontColor(this.t().accent)
        }
        .width(44)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.toggleListPane();
        })
      }

      Column() {
        Text(this.selTitle())
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          if (this.selCwd() !== '') {
            Text(this.selCwd())
              .fontSize(11)
              .fontColor(this.t().textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 7, right: 7, top: 1, bottom: 1 })
              .borderRadius(6)
              .backgroundColor(this.t().navActiveBg)
          }
        }
        .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: this.coverMode ? 4 : 4 })

      if (this.selectedId !== '') {
        Column() {
          Text('◆ ' + this.currentModelLabel())
            .fontSize(11)
            .fontColor(this.t().accent)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .constraintSize({ maxWidth: 150 })
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .borderRadius(999)
        .backgroundColor(this.t().navActiveBg)
        .margin({ right: 4 })
        .onClick(() => {
          this.openModelPicker();
        })
      }

      if (this.selRunning()) {
        Column() {
          Text('■')
            .fontSize(14)
            .fontColor(this.t().danger)
        }
        .width(40)
        .height(40)
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.dark ? 'rgba(248,113,113,0.12)' : 'rgba(220,38,38,0.08)')
        .margin({ right: 4 })
        .onClick(() => {
          this.cancelRunning();
        })
      }

      if (this.chatState === ChatState.Ready || this.chatState === ChatState.Failed) {
        Column() {
          Text('⟳')
            .fontSize(20)
            .fontColor(this.t().accent)
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.reloadHistory();
        })
      }
    }
    .width('100%')
    .height(64)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 0, right: 0 })
    .border({ width: { bottom: 0.5 }, color: this.t().border })
  }

  /** 左侧时间线节点：仅圆点（连线在无界滚动容器里会把行高撑爆，弃用）。 */
  @Builder
  railNode(e: ChatEntryVm, idx: number) {
    Column() {
      if (e.kind === ChatEntryKind.Turn) {
        Circle()
          .width(11)
          .height(11)
          .fill(Color.Transparent)
          .stroke(this.t().border)
          .strokeWidth(1.5)
          .margin({ top: 13 })
      } else if (e.kind === ChatEntryKind.User) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.t().accent)
          .margin({ top: 14 })
      } else if (e.kind === ChatEntryKind.Tool) {
        Circle()
          .width(6)
          .height(6)
          .fill(this.t().textTertiary)
          .margin({ top: 15 })
      } else if (e.kind === ChatEntryKind.Error) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.t().danger)
          .margin({ top: 14 })
      } else {
        Circle()
          .width(8)
          .height(8)
          .fill(this.t().accent2)
          .margin({ top: 14 })
      }
    }
    .width(18)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  turnSep(e: ChatEntryVm) {
    Text(e.text)
      .fontSize(11)
      .fontColor(this.t().textTertiary)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.t().navActiveBg)
      .alignSelf(ItemAlign.Start)
      .margin({ top: 8, bottom: 2 })
  }

  @Builder
  userBubble(e: ChatEntryVm) {
    Column() {
      Text(e.text)
        .fontSize(15)
        .fontColor(this.t().textPrimary)
        .lineHeight(22)
    }
    .constraintSize({ maxWidth: this.coverMode ? '86%' : '70%' })
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 5 })
    .backgroundColor(this.dark ? 'rgba(34,211,238,0.14)' : '#E8F0FE')
    .border({ width: 1, color: this.dark ? 'rgba(34,211,238,0.32)' : '#C9DDF9' })
    .margin({ top: 10 })
    .alignSelf(ItemAlign.End)
  }

  /** 轮次失败卡（turn/end reason≠completed）：错误详情在此，否则失败轮次在手机端不可见。 */
  @Builder
  errorCard(e: ChatEntryVm) {
    Row({ space: 8 }) {
      Text('⛔')
        .fontSize(13)
      Column() {
        Text(e.text)
          .fontSize(12.5)
          .fontColor(this.t().textPrimary)
          .lineHeight(18)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.dark ? 'rgba(248,113,113,0.10)' : 'rgba(220,38,38,0.06)')
    .border({ width: 1, color: this.dark ? 'rgba(248,113,113,0.35)' : 'rgba(220,38,38,0.25)' })
    .margin({ top: 8 })
    .alignSelf(ItemAlign.Start)
  }

  /**
   * 流式 Markdown 的 ForEach 键：附加内容长度。正在生长的块换键重建、
   * 内容稳定的块照常复用——普通静态键会让生长中的段落冻结不刷新。
   */
  private mdKey(b: MdBlock, idx: number): string {
    let runsLen: number = 0;
    for (let i: number = 0; i < b.runs.length; i++) {
      runsLen += b.runs[i].text.length;
    }
    return '' + idx + '-' + b.kind + '-' + b.code.length + '-' + runsLen
      + '-' + (b.table !== null ? b.table.rows.length : 0);
  }

  /**
   * WebSocket 流式打字机卡：直接读 @State（liveText/liveReasoning），
   * 每次 flush 必然刷新；不做长文折叠（流式展开 + 光标）。
   */
  @Builder
  liveAssistantCard() {
    Column() {
      Row() {
        Text('◈ dsh · 正在输出')
          .fontSize(11)
          .fontColor(this.t().accent)
      }
      .width('100%')

      if (this.liveReasoning !== '') {
        if (this.liveThinkingOpen) {
          Column() {
            Row() {
              Text('💭 思考过程')
                .fontSize(12)
                .fontColor(this.t().textSecondary)
              Blank()
              Text('收起 ▴')
                .fontSize(11)
                .fontColor(this.t().accent)
            }
            .width('100%')
            Text(this.liveReasoning)
              .fontSize(12)
              .fontColor(this.t().textSecondary)
              .lineHeight(18)
              .margin({ top: 6 })
          }
          .width('100%')
          .padding(14)
          .borderRadius(10)
          .backgroundColor(this.t().navActiveBg)
          .margin({ top: 8 })
          .onClick(() => {
            this.liveThinkingOpen = false;
          })
        } else {
          Row() {
            Text('💭 思考中 · ' + this.liveReasoning.length + ' 字')
              .fontSize(12)
              .fontColor(this.t().textSecondary)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('展开 ▾')
              .fontSize(11)
              .fontColor(this.t().accent)
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 12, bottom: 12 })
          .borderRadius(10)
          .backgroundColor(this.t().navActiveBg)
          .margin({ top: 8 })
          .onClick(() => {
            this.liveThinkingOpen = true;
          })
        }
      }

      if (this.liveText !== '') {
        Column() {
          ForEach(parseMarkdown(this.liveText), (b: MdBlock, idx: number) => {
            this.mdBlockView(b)
          }, (b: MdBlock, idx: number) => this.mdKey(b, idx))
          Text('▌')
            .fontSize(15)
            .fontColor(this.t().accent)
            .margin({ top: 2 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 8 })
      }

      Row() {
        if (this.liveUsageOut > 0) {
          Text('输出 ' + this.liveUsageOut + ' tok')
            .fontSize(10)
            .fontColor(this.t().textTertiary)
            .margin({ right: 12 })
        }
        Text('流式生成中…')
          .fontSize(10)
          .fontColor(this.t().textTertiary)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 5, bottomRight: 18 })
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
    .margin({ top: 10 })
    .alignSelf(ItemAlign.Start)
  }

  /**
   * 助手卡片。live=true 时为 WebSocket 流式打字机：
   * 不做长文折叠（展开渲染 + 光标），不显示时间戳。
   */
  @Builder
  assistantCard(e: ChatEntryVm, live: boolean) {
    Column() {
      Row() {
        Text('◈ dsh' + (e.model === '' ? '' : ' · ' + e.model))
          .fontSize(11)
          .fontColor(this.t().accent)
      }
      .width('100%')

      if (e.reasoning !== '') {
        if (this.isExpanded('r' + e.seq)) {
          Column() {
            Row() {
              Text('💭 思考过程')
                .fontSize(12)
                .fontColor(this.t().textSecondary)
              Blank()
              Text('收起 ▴')
                .fontSize(11)
                .fontColor(this.t().accent)
            }
            .width('100%')
            Text(e.reasoning)
              .fontSize(12)
              .fontColor(this.t().textSecondary)
              .lineHeight(18)
              .margin({ top: 6 })
          }
          .padding(14)
          .borderRadius(10)
          .backgroundColor(this.t().navActiveBg)
          .margin({ top: 8 })
          .onClick(() => {
            this.toggleExpand('r' + e.seq);
          })
        } else {
          Row() {
            Text('💭 思考过程 · ' + e.reasoning.length + ' 字')
              .fontSize(12)
              .fontColor(this.t().textSecondary)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('展开 ▾')
              .fontSize(11)
              .fontColor(this.t().accent)
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 12, bottom: 12 })
          .borderRadius(10)
          .backgroundColor(this.t().navActiveBg)
          .margin({ top: 8 })
          .onClick(() => {
            this.toggleExpand('r' + e.seq);
          })
        }
      }

      if (e.text !== '') {
        if (!live && this.isLongText(e.text) && !this.isExpanded('t' + e.seq)) {
          Column() {
            Text(e.text.substring(0, 300) + '…')
              .fontSize(15)
              .fontColor(this.t().textPrimary)
              .lineHeight(23)
            Text('展开全部（共 ' + e.text.length + ' 字） ▾')
              .fontSize(12)
              .fontColor(this.t().accent)
              .margin({ top: 8 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 8 })
          .onClick(() => {
            this.toggleExpand('t' + e.seq);
          })
        } else {
          Column() {
            ForEach(parseMarkdown(e.text), (b: MdBlock, idx: number) => {
              this.mdBlockView(b)
            }, (b: MdBlock, idx: number) => idx + '-' + b.kind + '-' + b.code.length)
            if (live) {
              Text('▌')
                .fontSize(15)
                .fontColor(this.t().accent)
                .margin({ top: 2 })
            }
            if (!live && this.isLongText(e.text)) {
              Text('收起 ▴')
                .fontSize(12)
                .fontColor(this.t().accent)
                .margin({ top: 8 })
                .onClick(() => {
                  this.toggleExpand('t' + e.seq);
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 8 })
        }
      }

      if (!live) {
        Row() {
          if (e.usageIn > 0) {
            Text('输入 ' + e.usageIn + ' tok')
              .fontSize(10)
              .fontColor(this.t().textTertiary)
              .margin({ right: 12 })
          }
          if (e.usageOut > 0) {
            Text('输出 ' + e.usageOut + ' tok')
              .fontSize(10)
              .fontColor(this.t().textTertiary)
              .margin({ right: 12 })
          }
          Text(this.fmtClock(e.time))
            .fontSize(10)
            .fontColor(this.t().textTertiary)
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 5, bottomRight: 18 })
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
    .margin({ top: 10 })
    .alignSelf(ItemAlign.Start)
  }

  @Builder
  toolRow(e: ChatEntryVm) {
    Column() {
      Row() {
        Text('🔧')
          .fontSize(15)
        Text(e.tool === null ? '工具调用' : e.tool.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.t().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 10 })
        Text(e.tool !== null && e.tool.resultText !== '' ? '✓' : '…')
          .fontSize(13)
          .fontColor(this.t().success)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.isExpanded('' + e.seq) && e.tool !== null) {
        if (e.tool.arguments !== '') {
          Text(e.tool.arguments)
            .fontSize(11)
            .fontColor(this.t().termText)
            .fontFamily('monospace')
            .lineHeight(17)
            .padding(14)
            .borderRadius(10)
            .backgroundColor(this.t().termBg)
            .margin({ top: 8 })
        }
        if (e.tool.resultText !== '') {
          Text(e.tool.resultText)
            .fontSize(11)
            .fontColor(this.t().termText)
            .fontFamily('monospace')
            .lineHeight(17)
            .padding(14)
            .borderRadius(10)
            .backgroundColor(this.t().termBg)
            .margin({ top: 8 })
        }
      }
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 12, bottom: 12 })
    .borderRadius(14)
    .backgroundColor(this.t().navActiveBg)
    .border({ width: 1, color: this.t().border })
    .margin({ top: 8 })
    .alignSelf(ItemAlign.Start)
    .onClick(() => {
      this.toggleExpand('' + e.seq);
    })
  }

  @Builder
  inputBar() {
    Column() {
      if (this.attachBase64 !== '') {
        Row({ space: 8 }) {
          Text('🖼')
            .fontSize(15)
          Text(this.attachName)
            .fontSize(12)
            .fontColor(this.t().textSecondary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('✕')
            .fontSize(13)
            .fontColor(this.t().textSecondary)
            .onClick(() => {
              this.attachBase64 = '';
              this.attachName = '';
              this.attachMediaType = '';
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .borderRadius(12)
        .backgroundColor(this.t().navActiveBg)
        .margin({ bottom: 6 })
      }

      Row({ space: 10 }) {
        // 导轨等宽占位：输入框与消息内容严格左对齐
        Column()
          .width(30)

        Column() {
          Text('📎')
            .fontSize(17)
            .fontColor(this.attachBase64 !== '' ? this.t().accent : this.t().textSecondary)
        }
        .width(40)
        .height(46)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.pickImage();
        })

        TextInput({ text: this.inputText, placeholder: this.selectedId === '' ? '先选择一个会话…' : '输入新任务，发送给 dsh…' })
          .layoutWeight(1)
          .height(46)
          .fontSize(14)
          .fontColor(this.t().textPrimary)
          .placeholderColor(this.t().textTertiary)
          .backgroundColor(this.t().navActiveBg)
          .borderRadius(14)
          .padding({ left: 14, right: 14 })
          .enabled(this.selectedId !== '')
          .onChange((v: string) => {
            this.inputText = v;
          })
          .onSubmit(() => {
            this.sendCurrent();
          })

        Column() {
          Text(this.sending ? '…' : '➤')
            .fontSize(18)
            .fontColor(this.canSend() ? this.t().onAccent : this.t().textTertiary)
        }
        .width(46)
        .height(46)
        .borderRadius(14)
        .justifyContent(FlexAlign.Center)
        .linearGradient({
          angle: 135,
          colors: this.canSend()
            ? [[this.t().accent, 0.0], [this.t().accent2, 1.0]]
            : [[this.t().navActiveBg, 0.0], [this.t().navActiveBg, 1.0]],
        })
        .opacity(this.canSend() ? 1.0 : 0.7)
        .onClick(() => {
          this.sendCurrent();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ bottom: px2vp(this.bottomAvoidPx) + 4 })
    .border({ width: { top: 0.5 }, color: this.t().border })
  }
}
