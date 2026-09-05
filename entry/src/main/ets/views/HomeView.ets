/** 连接中心首页：服务器健康状态英雄卡、快捷任务指令复制与近期会话占位。 */

import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { DshConfigStore } from '../service/DshConfigStore';
import { HealthMonitor } from '../service/HealthMonitor';
import { DshSessionsRepository } from '../service/DshSessionsRepository';
import { DshConfigData, HealthSnapshot } from '../model/DshTypes';
import { SessionSummaryVm } from '../model/SessionVms';
import { ThemeColors, ThemeManager } from '../theme/Theme';

/** 快捷任务卡：点按复制 prompt 指令到剪贴板，再跳转工作台粘贴发送。 */
interface QuickTask {
  ic: string
  name: string
  desc: string
  prompt: string
}

const QUICK_TASKS: QuickTask[] = [
  {
    ic: '🚀',
    name: '部署博客更新',
    desc: '一键部署流水线',
    prompt: '请把博客最新代码部署到生产环境，完成后做一次健康检查并汇报结果。',
  },
  {
    ic: '🧹',
    name: '清理过期日志',
    desc: '释放磁盘空间',
    prompt: '清理服务器上超过30天的应用日志文件，先列出再删除，并汇报释放的空间。',
  },
  {
    ic: '🔄',
    name: '重启 dsh 服务',
    desc: '排障常用',
    prompt: '请重启服务器上的 dsh web 服务，并确认服务恢复在线。',
  },
  {
    ic: '📋',
    name: '日志巡检',
    desc: '每日体检',
    prompt: '查看最近的错误日志，总结需要关注的问题。',
  },
]

const REFRESH_INTERVAL_MS: number = 60000
const GRID_GUTTER: number = 12

@Component
export struct HomeView {
  /** 合盖外屏紧凑模式：快捷任务两列、指标行允许换行。 */
  @Prop coverMode: boolean = false;
  onEnterConsole: () => void = () => {};

  @StorageProp('themeIsDark') dark: boolean = true;

  @State health: HealthSnapshot = { online: false, latencyMs: -1, checkedAt: 0, detail: 'probing' };
  @State probing: boolean = true;
  @State serverUrl: string = '';
  /** 近期会话（真实数据，拉取失败为空走占位文案）。 */
  @State recentSessions: SessionSummaryVm[] = [];

  private timerId: number = -1;
  /** 防止探测重入（手动刷新撞上定时刷新）。 */
  private inFlight: boolean = false;
  private quickTasks: QuickTask[] = QUICK_TASKS;

  aboutToAppear(): void {
    // 先用上次缓存秒显，避免“空壳→数据”两段式重画
    const cachedHealth: HealthSnapshot | undefined = AppStorage.get<HealthSnapshot>('homeHealthCache');
    if (cachedHealth !== undefined && cachedHealth.checkedAt > 0) {
      this.health = cachedHealth;
      this.probing = false;
    }
    const cachedSessions: SessionSummaryVm[] | undefined = AppStorage.get<SessionSummaryVm[]>('homeSessionsCache');
    if (cachedSessions !== undefined) {
      this.recentSessions = cachedSessions;
    }
    const cachedServer: string | undefined = AppStorage.get<string>('homeServerCache');
    if (cachedServer !== undefined && cachedServer !== '') {
      this.serverUrl = cachedServer;
    }
    this.refresh(true);
    // 防御：组件重建时不堆叠新定时器
    if (this.timerId < 0) {
      this.timerId = setInterval(() => {
        this.refresh(false);
      }, REFRESH_INTERVAL_MS);
    }
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  /** 会话数据有实质变化才赋值，避免定时刷新引发整卡重绘闪动。 */
  private applySessions(top: SessionSummaryVm[]): void {
    let same: boolean = top.length === this.recentSessions.length;
    if (same) {
      for (let i: number = 0; i < top.length; i++) {
        if (top[i].sessionId !== this.recentSessions[i].sessionId
          || top[i].updatedAt !== this.recentSessions[i].updatedAt) {
          same = false;
          break;
        }
      }
    }
    if (!same) {
      this.recentSessions = top;
    }
  }

  /** 健康快照是否有实质变化（时间戳 5 秒内视为同一轮，不触发重绘）。 */
  private sameHealth(a: HealthSnapshot, b: HealthSnapshot): boolean {
    return a.online === b.online && a.latencyMs === b.latencyMs
      && a.detail === b.detail && Math.abs(a.checkedAt - b.checkedAt) < 5000;
  }

  /**
   * 探测入口：加载配置 → 取密码 → 探活；任一步失败落到离线快照。
   * 数据有实质变化才写入状态，杜绝周期性整页重绘。
   */
  private async refresh(manual: boolean): Promise<void> {
    if (this.inFlight) {
      return;
    }
    this.inFlight = true;
    // 仅在完全没有历史数据时才显示加载态；有缓存时静默刷新原位更新
    const showLoading: boolean = this.health.checkedAt === 0;
    if (showLoading) {
      this.probing = true;
    }
    try {
      const ctx: common.Context = getContext(this);
      const data: DshConfigData = await DshConfigStore.load(ctx);
      if (this.serverUrl !== data.serverUrl) {
        this.serverUrl = data.serverUrl;
      }
      AppStorage.setOrCreate('homeServerCache', data.serverUrl);
      const password: string = await DshConfigStore.getPassword();
      const snap: HealthSnapshot = await HealthMonitor.probe(data.serverUrl, data.username, password);
      if (!this.sameHealth(this.health, snap)) {
        this.health = snap;
      }
      AppStorage.setOrCreate('homeHealthCache', snap);
      // 近期会话独立拉取：失败时保留上一次数据（不清空、不闪动）
      try {
        const sessions: SessionSummaryVm[] = await DshSessionsRepository.listSessions(ctx);
        const top: SessionSummaryVm[] = [];
        const limit: number = sessions.length < 3 ? sessions.length : 3;
        for (let i: number = 0; i < limit; i++) {
          top.push(sessions[i]);
        }
        this.applySessions(top);
        AppStorage.setOrCreate('homeSessionsCache', top);
      } catch (err) {
        // 静默保留旧数据
      }
    } catch (err) {
      const offline: HealthSnapshot = { online: false, latencyMs: -1, checkedAt: Date.now(), detail: 'unreachable' };
      if (!this.sameHealth(this.health, offline)) {
        this.health = offline;
      }
    } finally {
      if (showLoading) {
        this.probing = false;
      }
      this.inFlight = false;
    }
  }

  private serverHost(): string {
    if (this.serverUrl === '') {
      return '未配置服务器';
    }
    return this.serverUrl.replace('https://', '').replace('http://', '');
  }

  private todayLabel(): string {
    const d: Date = new Date();
    const weeks: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    return `${d.getMonth() + 1}月${d.getDate()}日 · 星期${weeks[d.getDay()]}`;
  }

  private formatClock(ts: number): string {
    const d: Date = new Date(ts);
    const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    return `${hh}:${mm}`;
  }

  /** 复制快捷指令到剪贴板，并预填到工作台输入框。 */
  private async runQuickTask(task: QuickTask): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, task.prompt);
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await board.setData(data);
    } catch (err) {
      // 复制失败不阻断进入工作台。
    }
    AppStorage.setOrCreate('chatPrefill', task.prompt);
    promptAction.showToast({ message: '指令已填入工作台输入框，可直接发送' });
    this.onEnterConsole();
  }

  build() {
    Scroll() {
      Row() {
        Column() {
          this.header()
          this.heroCard()
          this.quickTaskSection()
          this.recentSessionsCard()
        }
        .width('100%')
        .constraintSize({ maxWidth: 900 })
        .padding(24)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  header() {
    Row() {
      Column() {
        Text('连接中心')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
        Text(this.todayLabel())
          .fontSize(13)
          .fontColor(this.t().textSecondary)
          .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        Text('⟳')
          .fontSize(22)
          .fontColor(this.probing ? this.t().textTertiary : this.t().accent)
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor(this.t().bgCard)
      .border({ width: 1, color: this.t().border })
      .justifyContent(FlexAlign.Center)
      .opacity(this.probing ? 0.7 : 1.0)
      .onClick(() => {
        this.refresh(true);
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  statusBadge() {
    if (this.probing) {
      Text('探测中…')
        .fontSize(12)
        .fontColor(this.t().textSecondary)
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
        .borderRadius(999)
        .backgroundColor(this.t().bgCard)
        .border({ width: 1, color: this.t().border })
    } else if (this.health.online && this.health.detail === 'auth-required') {
      Text('● 需重新登录')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().warn)
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
        .borderRadius(999)
        .backgroundColor(this.dark ? 'rgba(251,191,36,0.12)' : 'rgba(180,83,9,0.10)')
    } else if (this.health.online) {
      Text('● 在线')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().success)
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
        .borderRadius(999)
        .backgroundColor(this.dark ? 'rgba(52,211,153,0.12)' : 'rgba(14,159,110,0.12)')
    } else {
      Text('● 不可达')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().danger)
        .padding({ top: 6, bottom: 6, left: 12, right: 12 })
        .borderRadius(999)
        .backgroundColor(this.dark ? 'rgba(248,113,113,0.12)' : 'rgba(220,38,38,0.12)')
    }
  }

  @Builder
  metricLatency() {
    Column() {
      Text('延迟')
        .fontSize(11)
        .fontColor(this.t().textTertiary)
      Text(this.health.online ? `${this.health.latencyMs} ms` : '--')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.health.online ? this.t().accent : this.t().textPrimary)
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ right: this.coverMode ? 24 : 0, bottom: this.coverMode ? 12 : 0 })
  }

  @Builder
  metricLogin() {
    Column() {
      Text('登录态')
        .fontSize(11)
        .fontColor(this.t().textTertiary)
      Text('已自动登录')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().success)
        .margin({ top: 8 })
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ right: this.coverMode ? 24 : 0, bottom: this.coverMode ? 12 : 0 })
  }

  @Builder
  metricChecked() {
    Column() {
      Text('最近检测')
        .fontSize(11)
        .fontColor(this.t().textTertiary)
      Text(this.health.checkedAt > 0 ? this.formatClock(this.health.checkedAt) : '--')
        .fontSize(13)
        .fontColor(this.t().textTertiary)
        .margin({ top: 10 })
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.coverMode ? 12 : 0 })
  }

  /** 指标行：常规单行 Row，合盖紧凑模式用可换行 Flex。 */
  @Builder
  metricsBlock() {
    if (this.coverMode) {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start }) {
        this.metricLatency()
        this.metricLogin()
        this.metricChecked()
      }
      .width('100%')
      .margin({ top: 18 })
    } else {
      Row({ space: 28 }) {
        this.metricLatency()
        this.metricLogin()
        this.metricChecked()
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 18 })
    }
  }

  @Builder
  heroCard() {
    Column() {
      Row() {
        Text(this.serverHost())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        this.statusBadge()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.metricsBlock()

      Column() {
        Text('进入控制台 ▸')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().onAccent)
      }
      .width('100%')
      .height(48)
      .justifyContent(FlexAlign.Center)
      .borderRadius(16)
      .linearGradient({
        angle: 135,
        colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
      })
      .margin({ top: 20 })
      .onClick(() => {
        this.onEnterConsole();
      })

      Text('免登录 · 自动注入凭据 · 全功能 dsh 控制台')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 10 })
    }
    .width('100%')
    .padding(24)
    .borderRadius(24)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
    .margin({ top: 24 })
  }

  @Builder
  quickTaskSection() {
    Column() {
      Text('快捷任务')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.t().textPrimary)
      Text('点按复制指令，到工作台粘贴发送')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .margin({ top: 4 })

      GridRow({ columns: this.coverMode ? 2 : 4, gutter: GRID_GUTTER }) {
        ForEach(this.quickTasks, (task: QuickTask) => {
          GridCol() {
            Column() {
              Text(task.ic)
                .fontSize(22)
              Text(task.name)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.t().textPrimary)
                .margin({ top: 8 })
              Text(task.desc)
                .fontSize(11)
                .fontColor(this.t().textTertiary)
                .margin({ top: 4 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(14)
            .borderRadius(16)
            .backgroundColor(this.t().bgCard)
            .border({ width: 1, color: this.t().border })
            .onClick(() => {
              this.runQuickTask(task);
            })
          }
        }, (task: QuickTask) => task.name)
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .margin({ top: 28 })
  }

  @Builder
  recentSessionsCard() {
    Column() {
      Row() {
        Text('近期任务会话')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
          .layoutWeight(1)
        Column() {
          Text('全部 ›')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.t().accent)
        }
        .padding({ top: 8, bottom: 8, left: 12, right: 12 })
        .borderRadius(12)
        .backgroundColor(this.t().navActiveBg)
        .onClick(() => {
          this.onEnterConsole();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.recentSessions.length === 0) {
        Text('暂无会话数据——服务器暂无历史会话，或登录态失效。点击右上角刷新重试。')
          .fontSize(12)
          .fontColor(this.t().textSecondary)
          .lineHeight(18)
          .margin({ top: 8 })
      } else {
        ForEach(this.recentSessions, (s: SessionSummaryVm) => {
          Row() {
            Column() {
              Circle()
                .width(8)
                .height(8)
                .fill(s.running ? this.t().success : this.t().textTertiary)
                .opacity(s.running ? 1 : 0.4)
            }
            .width(14)
            .margin({ top: 5 })

            Column() {
              Text(s.title)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.t().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(s.lastPrompt === '' ? s.cwd : s.lastPrompt)
                .fontSize(11)
                .fontColor(this.t().textTertiary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 8 })

            Text(this.relTimeOf(s.updatedAt))
              .fontSize(11)
              .fontColor(this.t().textTertiary)
              .margin({ left: 10 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ top: 10, bottom: 10 })
          .borderRadius(12)
          .onClick(() => {
            this.onEnterConsole();
          })
        }, (s: SessionSummaryVm) => s.sessionId)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(20)
    .borderRadius(20)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
    .margin({ top: 24 })
  }

  private relTimeOf(ts: number): string {
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
}
