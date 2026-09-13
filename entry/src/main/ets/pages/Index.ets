import { HomeView } from '../views/HomeView';
import { WorkspaceView } from '../views/WorkspaceView';
import { WorkspaceChatView } from '../views/WorkspaceChatView';
import { ReportView } from '../views/ReportView';
import { SettingsView } from '../views/SettingsView';
import { OnboardingView } from '../views/OnboardingView';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { DshEventClient } from '../service/DshEventClient';
import { PendingAskVm } from '../model/SessionVms';
import { KEY_ASK_JUMP_ID, KEY_ASK_JUMP_TICK, KEY_ASK_TICK, KEY_CHAT_SELECTED_ID, KEY_CONFIG_READY, KEY_CUR_TAB, KEY_REPORT_BACK_DEPTH, KEY_REPORT_BACK_TICK } from '../model/DshTypes';

enum TabId {
  Sessions = 0,
  Home = 1,
  Console = 2,
  Settings = 3,
  Reports = 4,
}

/** 应用外壳：阔折叠展开态走左侧导航栏，合盖外屏走底部 Tab，断点自动切换。 */
@Entry
@Component
struct Index {
  @StorageProp('themeIsDark') dark: boolean = true;
  @StorageProp(KEY_CONFIG_READY) @Watch('onConfigReadyChanged') configReady: boolean = false;
  /** 底部系统导航条避让高度（px），底栏据此垫底。 */
  @StorageProp('bottomAvoidPx') bottomAvoidPx: number = 0;
  /** dsh 待回答交互：非当前会话的问题以横幅提示，点击跳转。 */
  @StorageProp(KEY_ASK_TICK) @Watch('onAskTick') askTick: number = 0;
  @StorageProp(KEY_CHAT_SELECTED_ID) @Watch('onAskTick') chatSelectedId: string = '';
  @State bannerAsk: PendingAskVm | null = null;
  /** 本机点了 ✕ 的横幅（内存态，仅隐藏提示不改服务器状态）。 */
  @State hiddenAskEventIds: string[] = [];
  @State cur: TabId = TabId.Home;
  @State expanded: boolean = true;

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  aboutToAppear(): void {
    if (this.configReady) {
      DshEventClient.start(getContext(this));
    }
  }

  /** 登录态建立 → 启动全局事件流；清除配置 → 停止。 */
  private onConfigReadyChanged(): void {
    if (this.configReady) {
      DshEventClient.start(getContext(this));
    } else {
      DshEventClient.stop();
      this.bannerAsk = null;
    }
  }

  /** 重算横幅：跳过已隐藏项与当前对话页正在展示的项。 */
  private onAskTick(): void {
    const all: PendingAskVm[] = DshEventClient.pendingAsks();
    let found: PendingAskVm | null = null;
    for (let i: number = 0; i < all.length; i++) {
      const a: PendingAskVm = all[i];
      if (this.hiddenAskEventIds.indexOf(a.eventId) >= 0) {
        continue;
      }
      if (this.cur === TabId.Sessions && a.sessionId === this.chatSelectedId) {
        continue;
      }
      found = a;
      break;
    }
    this.bannerAsk = found;
  }

  /** 横幅点击：切到会话 Tab 并打开目标会话。 */
  private jumpToAsk(): void {
    const ask: PendingAskVm | null = this.bannerAsk;
    if (ask === null) {
      return;
    }
    AppStorage.setOrCreate(KEY_ASK_JUMP_ID, ask.sessionId);
    const t: number = AppStorage.get<number>(KEY_ASK_JUMP_TICK) ?? 0;
    AppStorage.setOrCreate(KEY_ASK_JUMP_TICK, t + 1);
    this.switchTab(TabId.Sessions);
  }

  /** 横幅 ✕：仅本机隐藏该条提示。 */
  private hideBanner(): void {
    const ask: PendingAskVm | null = this.bannerAsk;
    if (ask === null) {
      return;
    }
    this.hiddenAskEventIds = this.hiddenAskEventIds.concat([ask.eventId]);
    this.onAskTick();
  }

  /** 横幅摘要文案。 */
  private bannerText(): string {
    const ask: PendingAskVm | null = this.bannerAsk;
    if (ask === null) {
      return '';
    }
    if (ask.kind === 'approval') {
      return ask.reason !== '' ? ask.reason : '工具 ' + ask.toolName + ' 请求越权执行';
    }
    if (ask.questions.length === 1 && ask.questions[0].planReview) {
      return '有一份计划待你审批';
    }
    const first: string = ask.questions.length > 0 ? ask.questions[0].question : '';
    const more: string = ask.questions.length > 1 ? '（共 ' + ask.questions.length + ' 题）' : '';
    const text: string = first.length > 42 ? first.substring(0, 42) + '…' : first;
    return text + more;
  }

  /** 系统侧滑/返回键：有二级层级时逐层回退，没有才允许退出应用。 */
  onBackPress(): boolean {
    if (!this.configReady) {
      const st = AppStorage.get<number>('onbStep') ?? 0;
      if (st > 0) {
        const t = AppStorage.get<number>('onbBackTick') ?? 0;
        AppStorage.setOrCreate('onbBackTick', t + 1);
        return true;
      }
      return false;
    }
    if (this.cur === TabId.Sessions) {
      const d = AppStorage.get<number>('chatBackDepth') ?? 0;
      if (d > 0) {
        const t = AppStorage.get<number>('backPopTick') ?? 0;
        AppStorage.setOrCreate('backPopTick', t + 1);
        return true;
      }
    }
    if (this.cur === TabId.Reports) {
      const rd = AppStorage.get<number>(KEY_REPORT_BACK_DEPTH) ?? 0;
      if (rd > 0) {
        const rt = AppStorage.get<number>(KEY_REPORT_BACK_TICK) ?? 0;
        AppStorage.setOrCreate(KEY_REPORT_BACK_TICK, rt + 1);
        return true;
      }
    }
    return false;
  }

  build() {
    Stack() {
      // 全局渐变背景
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [[this.t().bgGradStart, 0.0], [this.t().bgGradEnd, 1.0]],
        })

      if (!this.configReady) {
        OnboardingView({
          onCompleted: () => {
            AppStorage.setOrCreate(KEY_CONFIG_READY, true);
            this.cur = TabId.Home;
          },
        })
      } else if (this.expanded) {
        Row() {
          Column() {
            this.brandMark()
            this.railItem(TabId.Home, '◈', '首页')
            this.railItem(TabId.Sessions, '◧', '会话')
            this.railAction('✎', '新建对话')
            this.railItem(TabId.Reports, '▦', '策略报告')
            this.railItem(TabId.Settings, '⚙', '设置')
            Blank()
            Column() {
              Text('PocketDSH')
                .fontSize(12)
                .fontColor(this.t().textTertiary)
              Text('阔折叠适配 v1.0')
                .fontSize(10)
                .fontColor(this.t().textTertiary)
                .margin({ top: 2 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 4, bottom: 8 })
          }
          .width(96)
          .height('100%')
          .padding({ top: 24, bottom: 12 })
          .backgroundColor(this.t().bgRail)
          .border({ width: { right: 0.5 }, color: this.t().border })

          Column() {
            this.content()
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      } else {
        Column() {
          // 内容区只占剩余高度，确保底栏完整落在屏幕内
          Column() {
            this.content()
          }
          .layoutWeight(1)
          .width('100%')

          this.bottomBar()
        }
        .width('100%')
        .height('100%')
      }

      // dsh 待回答交互横幅：覆盖在内容层之上，容器透传触摸（只有横幅本体可点）
      if (this.configReady && this.bannerAsk !== null) {
        Column() {
          Row({ space: 10 }) {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.bannerAsk.kind === 'approval' ? this.t().warn : this.t().accent2)
            Column({ space: 2 }) {
              Text('dsh 等你回答')
                .fontSize(10)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.t().accent)
              Text(this.bannerText())
                .fontSize(13)
                .fontColor(this.t().textPrimary)
                .maxLines(2)
                .lineHeight(18)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text('›')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.t().textTertiary)
            Text('✕')
              .fontSize(13)
              .fontColor(this.t().textTertiary)
              .padding(6)
              .onClick(() => {
                this.hideBanner();
              })
          }
          .width('100%')
          .padding({ left: 14, right: 8, top: 10, bottom: 10 })
          .borderRadius(14)
          .backgroundColor(this.t().bgCard)
          .border({ width: 1, color: this.t().accent2 })
          .onClick(() => {
            this.jumpToAsk();
          })
        }
        .width('100%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, top: 10 })
        .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 阔折叠展开后窗口显著变宽，切到侧边导航；合盖回到紧凑布局。
      // 仅在结果真正变化时赋值，杜绝布局抖动引发的销毁-重建循环。
      const wide: boolean = Number(newValue.width) >= 640;
      if (wide !== this.expanded) {
        this.expanded = wide;
      }
    })
  }

  @Builder
  brandMark() {
    Column() {
      Column() {
        Text('◈')
          .fontSize(24)
          .fontColor(this.t().onAccent)
      }
      .width(44)
      .height(44)
      .borderRadius(14)
      .linearGradient({
        angle: 135,
        colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
      })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Text('PocketDSH')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.t().textPrimary)
        .margin({ top: 10 })
    }
    .width('100%')
    .margin({ bottom: 18 })
  }

  /** 切换 Tab：同步到 AppStorage，常驻的子视图（工作台等）据此感知页面显隐并刷新数据。 */
  private switchTab(id: TabId): void {
    this.cur = id;
    AppStorage.setOrCreate(KEY_CUR_TAB, Number(id));
    this.onAskTick();
  }

  /** 请求工作台新建会话（首页"新建任务"/侧栏"新建对话"共用入口）。 */
  private requestNewChat(): void {
    const t = AppStorage.get<number>('chatCreateTick') ?? 0;
    AppStorage.setOrCreate('chatCreateTick', t + 1);
    this.switchTab(TabId.Sessions);
  }

  @Builder
  railItem(id: TabId, glyph: string, label: string) {
    Column() {
      Text(glyph)
        .fontSize(22)
        .fontColor(this.cur === id ? this.t().accent : this.t().textSecondary)
      Text(label)
        .fontSize(11)
        .margin({ top: 4 })
        .fontColor(this.cur === id ? this.t().textPrimary : this.t().textSecondary)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor(this.cur === id ? this.t().navActiveBg : Color.Transparent)
    .onClick(() => {
      this.switchTab(id);
    })
  }

  /** 动作型侧栏项（新建对话）：点击执行动作，不保持选中态。 */
  @Builder
  railAction(glyph: string, label: string) {
    Column() {
      Text(glyph)
        .fontSize(22)
        .fontColor(this.t().accent2)
      Text(label)
        .fontSize(11)
        .margin({ top: 4 })
        .fontColor(this.t().textSecondary)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .borderRadius(12)
    .onClick(() => {
      this.requestNewChat();
    })
  }

  @Builder
  content() {
    Stack() {
      WorkspaceChatView({
        coverMode: !this.expanded,
      })
        .width('100%')
        .height('100%')
        .visibility(this.cur === TabId.Sessions ? Visibility.Visible : Visibility.None)

      HomeView({
        coverMode: !this.expanded,
        onEnterConsole: () => {
          this.switchTab(TabId.Sessions);
        },
        onGoSettings: () => {
          this.switchTab(TabId.Settings);
        },
      })
        .width('100%')
        .height('100%')
        .visibility(this.cur === TabId.Home ? Visibility.Visible : Visibility.None)

      WorkspaceView({
        coverMode: !this.expanded,
        onGoSettings: () => {
          this.switchTab(TabId.Settings);
        },
      })
        .width('100%')
        .height('100%')
        .visibility(this.cur === TabId.Console ? Visibility.Visible : Visibility.None)

      ReportView()
        .width('100%')
        .height('100%')
        .visibility(this.cur === TabId.Reports ? Visibility.Visible : Visibility.None)

      SettingsView({
        onOpenConsole: () => {
          this.cur = TabId.Console;
        },
      })
        .width('100%')
        .height('100%')
        .visibility(this.cur === TabId.Settings ? Visibility.Visible : Visibility.None)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  bottomBar() {
    Row() {
      this.barItem(TabId.Home, '◈', '首页')
      this.barItem(TabId.Sessions, '◧', '会话')
      this.barItem(TabId.Reports, '▦', '策略报告')
      this.barItem(TabId.Settings, '⚙', '设置')
    }
    .width('100%')
    .padding({ bottom: 4 })
    .backgroundColor(this.t().bgRail)
    .border({ width: { top: 0.5 }, color: this.t().border })
  }

  @Builder
  barItem(id: TabId, glyph: string, label: string) {
    Column() {
      Text(glyph)
        .fontSize(19)
        .fontColor(this.cur === id ? this.t().accent : this.t().textSecondary)
      Text(label)
        .fontSize(9)
        .margin({ top: 1 })
        .fontColor(this.cur === id ? this.t().textPrimary : this.t().textSecondary)
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 30 })
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(id);
    })
  }
}
