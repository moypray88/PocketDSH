/** 原生工作台：会话列表 + 对话历史（只读）。展开态双栏，合盖态两级导航。 */
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { DshSessionsRepository } from '../service/DshSessionsRepository';
import { DshConfigStore } from '../service/DshConfigStore';
import { CatalogVm, ChatEntryKind, ChatEntryVm, HistoryPageVm, ModelGroupVm, ModelItemVm, SessionSummaryVm } from '../model/SessionVms';
import { MdBlock, MdKind, MdRun, parseMarkdown } from '../parse/MdParser';
import { ThemeColors, ThemeManager } from '../theme/Theme';

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

@Component
export struct WorkspaceChatView {
  /** 合盖外屏紧凑模式：单栏两级导航。 */
  @Prop coverMode: boolean = false;

  @StorageProp('themeIsDark') dark: boolean = true;
  /** 底部系统导航条避让高度（px），输入区据此垫底。 */
  @StorageProp('bottomAvoidPx') bottomAvoidPx: number = 0;

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

  aboutToAppear(): void {
    this.refreshList(true);
    this.loadHidden();
    this.autoTimer = setInterval(() => {
      this.silentRefresh();
    }, 30000);
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
      this.sessions = await DshSessionsRepository.listSessions(ctx);
      this.listState = ListState.Ready;
    } catch (err) {
      this.errorMsg = (err as BusinessError).message;
      this.listState = ListState.Failed;
    } finally {
      this.inFlight = false;
    }
  }

  private async openSession(s: SessionSummaryVm): Promise<void> {
    this.selectedId = s.sessionId;
    this.throughSeq = s.asOfSeq;
    this.inChat = true;
    this.expandedSeqs = [];
    this.loadedOlder = false;
    this.modelOverride = '';
    this.echoText = '';
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    await this.reloadHistory();
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
    try {
      const ctx: common.Context = getContext(this);
      const page: HistoryPageVm = await DshSessionsRepository.loadHistory(ctx, this.selectedId, this.throughSeq, -1);
      this.entries = page.entries;
      this.hasMore = page.hasMore;
      this.oldestSeq = page.oldestSeq;
      this.chatState = ChatState.Ready;
      this.echoText = '';
      this.chaseFailCount = 0;
      this.scrollToBottom();
    } catch (err) {
      this.errorMsg = (err as BusinessError).message;
      this.chatState = ChatState.Failed;
    }
  }

  /** 运行中会话的静默刷新：有新消息才替换列表并贴底，否则不动（不闪屏）。 */
  private async silentRefresh(): Promise<void> {
    const sel: SessionSummaryVm | null = this.selectedSession();
    if (sel === null || !sel.running) {
      return;
    }
    await this.chaseNewMessages();
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
      if (pageMax > this.maxSeq()) {
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
    return this.inputText.trim() !== '' && !this.sending && this.selectedId !== '';
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
    if (text === '' || this.sending || this.selectedId === '') {
      return;
    }
    this.sending = true;
    this.echoText = text;
    this.echoSending = true;
    try {
      const ctx: common.Context = getContext(this);
      await DshSessionsRepository.sendText(ctx, this.selectedId, text);
      this.inputText = '';
      this.echoSending = false;
      promptAction.showToast({ message: '已发送，正在等待 dsh 处理' });
      this.refreshList(false);
      // 静默增量追踪回复（不整页刷新、不闪屏）
      this.pollAfterSend();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.echoText = '';
      this.echoSending = false;
      promptAction.showToast({ message: '发送失败：' + e.message });
    } finally {
      this.sending = false;
    }
  }

  /** 新建会话：创建后刷新列表并直接进入。 */
  private async createNewSession(): Promise<void> {
    if (this.creating) {
      return;
    }
    this.creating = true;
    try {
      const ctx: common.Context = getContext(this);
      const s: SessionSummaryVm = await DshSessionsRepository.createSession(ctx);
      promptAction.showToast({ message: '新会话已创建' });
      await this.refreshList(true);
      await this.openSession(s);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      promptAction.showToast({ message: '创建失败：' + e.message });
    } finally {
      this.creating = false;
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
      promptAction.showToast({ message: '已切换到 ' + m.name });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      promptAction.showToast({ message: '切换失败：' + e.message });
    }
  }

  /* ───────────── 显示辅助 ───────────── */

  private filtered(): SessionSummaryVm[] {
    const kw: string = this.filter === '' ? '' : this.filter.toLowerCase();
    const out: SessionSummaryVm[] = [];
    for (let i: number = 0; i < this.sessions.length; i++) {
      const s: SessionSummaryVm = this.sessions[i];
      // 本机隐藏的会话不显示（如 PC 端已归档的）
      if (this.hiddenIds.indexOf(s.sessionId) >= 0) {
        continue;
      }
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

  /** 模型选择浮层：遮罩 + 目录卡片。 */
  @Builder
  modelPickerOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.55)')
      .onClick(() => {
        this.modelPickerOpen = false;
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

  /** 左栏 / 合盖列表页：搜索 + 会话列表 + 新建。 */
  @Builder
  listPane() {
    Column() {
      Row() {
        Column() {
          Text('会话')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.t().textPrimary)
          Text(this.sessions.length > 0 ? '' + this.sessions.length + ' 个会话' : 'dsh 服务器')
            .fontSize(12)
            .fontColor(this.t().textTertiary)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column() {
          Text('⟳')
            .fontSize(20)
            .fontColor(this.listState === ListState.Loading ? this.t().textTertiary : this.t().accent)
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

      Row() {
        Text('🔍')
          .fontSize(14)
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
      .height(44)
      .borderRadius(14)
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
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 10, right: 10, top: 8 })
      }

      Column() {
        Text('＋ 新建会话')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.t().accent)
      }
      .width('100%')
      .height(48)
      .justifyContent(FlexAlign.Center)
      .borderRadius(14)
      .backgroundColor(this.t().navActiveBg)
      .border({ width: 1, color: this.t().border })
      .margin({ left: 16, right: 16, top: 10, bottom: 14 })
      .onClick(() => {
        this.createNewSession();
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
                      this.assistantCard(e)
                    } else {
                      this.toolRow(e)
                    }
                  }
                  .layoutWeight(1)
                  .padding({ left: 12 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }, (e: ChatEntryVm) => '' + e.seq)
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
      }
        this.inputBar()
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

  @Builder
  assistantCard(e: ChatEntryVm) {
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
        if (this.isLongText(e.text) && !this.isExpanded('t' + e.seq)) {
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
            if (this.isLongText(e.text)) {
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
    Row({ space: 10 }) {
      // 导轨等宽占位：输入框与消息内容严格左对齐
      Column()
        .width(30)

      TextInput({ text: this.inputText, placeholder: this.selectedId === '' ? '先选择一个会话…' : '输入新任务，发送给 dsh…' })
        .layoutWeight(1)
        .height(46)
        .fontSize(14)
        .fontColor(this.t().textPrimary)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(14)
        .padding({ left: 16, right: 16 })
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
    .padding({ bottom: px2vp(this.bottomAvoidPx) + 4 })
    .border({ width: { top: 0.5 }, color: this.t().border })
  }
}
