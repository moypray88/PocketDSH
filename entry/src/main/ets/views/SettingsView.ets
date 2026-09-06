/** 设置页：外观主题、服务器与账号、dsh 令牌重贴、危险区数据清除与关于信息。 */
import web_webview from '@ohos.web.webview';
import promptAction from '@ohos.promptAction';
import mediaquery from '@ohos.mediaquery';
import { BusinessError } from '@ohos.base';
import { DshConfigStore } from '../service/DshConfigStore';
import { DshApiClient } from '../service/DshApiClient';
import { DshSessionsRepository } from '../service/DshSessionsRepository';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { KEY_CONFIG_READY, KEY_CUR_TAB, KEY_HIDDEN_TICK, KEY_THEME_MODE, KEY_TOKEN_TICK, THEME_DARK, THEME_FOLLOW_SYSTEM, THEME_LIGHT } from '../model/DshTypes';

/** 隐藏会话行（标题尽力从服务器解析，未知回退短 ID）。 */
interface HiddenRow {
  id: string;
  title: string;
}

@Component
export struct SettingsView {
  @StorageProp('themeIsDark') dark: boolean = true;
  /** 打开完整版控制台（WebView）。 */
  onOpenConsole: () => void = () => {};
  /** Index 当前 Tab：设置页组件常驻，切回时重读本机隐藏数。 */
  @StorageProp(KEY_CUR_TAB) @Watch('onTabChange') curTab: number = 1;

  /** 0 跟随系统 / 1 深色 / 2 浅色。 */
  @State themeMode: number = THEME_FOLLOW_SYSTEM;
  @State serverUrl: string = '';
  @State username: string = '';
  @State hasPassword: boolean = false;
  @State hasToken: boolean = false;
  @State tokenEditorOpen: boolean = false;
  @State tokenUrlInput: string = '';
  @State savingToken: boolean = false;
  /** 本机隐藏的会话数量。 */
  @State hiddenCount: number = 0;
  /** 展开的隐藏会话行（含标题）。 */
  @State hiddenRows: HiddenRow[] = [];
  @State hiddenExpanded: boolean = false;
  @State hiddenLoading: boolean = false;

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  aboutToAppear(): void {
    this.refresh();
  }

  private async refresh(): Promise<void> {
    try {
      const ctx = getContext(this);
      const data = await DshConfigStore.load(ctx);
      this.serverUrl = data.serverUrl;
      this.username = data.username;
      this.hasPassword = data.hasPassword;
      this.hasToken = data.hasToken;
      this.themeMode = data.themeMode;
      this.tokenUrlInput = await DshConfigStore.getTokenUrl();
      const hidden: string[] = await DshConfigStore.getHiddenSessions(ctx);
      this.hiddenCount = hidden.length;
    } catch (err) {
      const e = err as BusinessError;
      promptAction.showToast({ message: '配置读取失败：' + e.message });
    }
  }

  /** 切回设置 Tab：重读本机隐藏数（本地读，无网络）；展开态则顺带重载行。 */
  private onTabChange(): void {
    this.syncHiddenCount();
    if (this.hiddenExpanded) {
      this.loadHiddenRows();
    }
  }

  private async syncHiddenCount(): Promise<void> {
    try {
      const hidden: string[] = await DshConfigStore.getHiddenSessions(getContext(this));
      this.hiddenCount = hidden.length;
    } catch (err) {
    }
  }

  /** 展开/收起隐藏会话列表；首次展开拉取行（含标题解析）。 */
  private toggleHidden(): void {
    this.hiddenExpanded = !this.hiddenExpanded;
    if (this.hiddenExpanded && this.hiddenRows.length === 0 && this.hiddenCount > 0) {
      this.loadHiddenRows();
    }
  }

  /** 拉取隐藏会话行：ID 来自本机偏好，标题尽力从服务器会话列表解析。 */
  private async loadHiddenRows(): Promise<void> {
    this.hiddenLoading = true;
    try {
      const ctx = getContext(this);
      const ids: string[] = await DshConfigStore.getHiddenSessions(ctx);
      const titleById: Map<string, string> = new Map<string, string>();
      try {
        const sessions = await DshSessionsRepository.listSessions(ctx);
        for (let i: number = 0; i < sessions.length; i++) {
          titleById.set(sessions[i].sessionId, sessions[i].title);
        }
      } catch (err) {
        // 标题解析失败（离线/认证过期）：行回退短 ID，恢复功能不受影响
      }
      const rows: HiddenRow[] = [];
      for (let i = 0; i < ids.length; i++) {
        const t: string | undefined = titleById.get(ids[i]);
        const row: HiddenRow = {
          id: ids[i],
          title: t !== undefined ? t : ids[i].substring(0, 13) + '…',
        };
        rows.push(row);
      }
      this.hiddenRows = rows;
      this.hiddenCount = rows.length;
    } finally {
      this.hiddenLoading = false;
    }
  }

  /** 逐个恢复：移除一条隐藏记录并通知工作台。 */
  private async restoreOne(row: HiddenRow): Promise<void> {
    try {
      await DshConfigStore.unhideSession(getContext(this), row.id);
      const next: HiddenRow[] = [];
      for (let i = 0; i < this.hiddenRows.length; i++) {
        if (this.hiddenRows[i].id !== row.id) {
          next.push(this.hiddenRows[i]);
        }
      }
      this.hiddenRows = next;
      this.hiddenCount = next.length;
      this.notifyHiddenChanged();
      promptAction.showToast({ message: '已恢复「' + row.title + '」' });
    } catch (err) {
      const e = err as BusinessError;
      promptAction.showToast({ message: '恢复失败：' + e.message });
    }
  }

  /** 通知常驻的工作台重载 hiddenIds（组件不重建，仅靠信号同步）。 */
  private notifyHiddenChanged(): void {
    const t = AppStorage.get<number>(KEY_HIDDEN_TICK) ?? 0;
    AppStorage.setOrCreate(KEY_HIDDEN_TICK, t + 1);
  }

  private async applyThemeMode(mode: number): Promise<void> {
    this.themeMode = mode;
    // 以系统实时深浅色作为“跟随系统”模式的依据。
    const systemDark: boolean = mediaquery.matchMediaSync('(prefers-color-scheme: dark)').matches;
    AppStorage.setOrCreate(KEY_THEME_MODE, mode);
    ThemeManager.apply(mode, systemDark);
    try {
      await DshConfigStore.setThemeMode(getContext(this), mode);
    } catch (err) {
      const e = err as BusinessError;
      promptAction.showToast({ message: '主题保存失败：' + e.message });
    }
  }

  private async saveToken(): Promise<void> {
    const url = this.tokenUrlInput.trim();
    if (url === '' || url.indexOf('token=') < 0) {
      promptAction.showToast({ message: '请粘贴包含 token 参数的完整 URL' });
      return;
    }
    this.savingToken = true;
    try {
      await DshConfigStore.saveTokenUrl(url);
      // 清掉旧签名 Cookie（WebView 通道）与原生客户端内存 Cookie，工作台将用新令牌重新登录。
      web_webview.WebCookieManager.clearAllCookiesSync();
      DshApiClient.clearCookie();
      const n = AppStorage.get<number>(KEY_TOKEN_TICK) ?? 0;
      AppStorage.setOrCreate(KEY_TOKEN_TICK, n + 1);
      this.hasToken = true;
      this.tokenEditorOpen = false;
      promptAction.showToast({ message: '已保存，工作台将自动重新登录' });
    } catch (err) {
      const e = err as BusinessError;
      promptAction.showToast({ message: '保存失败：' + e.message });
    } finally {
      this.savingToken = false;
    }
  }

  private confirmWipe(): void {
    AlertDialog.show({
      title: '清除全部数据',
      message: '将删除本机保存的服务器配置、密码与 dsh 令牌，并回到首次引导。确定继续？',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '清除',
        fontColor: '#FFFFFF',
        backgroundColor: this.t().danger,
        action: () => {
          this.wipeAll();
        },
      },
    });
  }

  private async wipeAll(): Promise<void> {
    try {
      await DshConfigStore.wipe(getContext(this));
      web_webview.WebCookieManager.clearAllCookiesSync();
      DshApiClient.clearCookie();
      // Index 监听该键，置 false 后自动回到引导页。
      AppStorage.setOrCreate(KEY_CONFIG_READY, false);
      promptAction.showToast({ message: '已清除全部数据' });
    } catch (err) {
      const e = err as BusinessError;
      promptAction.showToast({ message: '清除失败：' + e.message });
    }
  }

  build() {
    Scroll() {
      Column() {
        Column({ space: 16 }) {
          this.appearanceCard()
          this.accountCard()
          this.hiddenCard()
          this.tokenCard()
          this.consoleCard()
          this.dangerCard()
          this.aboutCard()
        }
        .width('100%')
        .constraintSize({ maxWidth: 640 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 20, right: 20, top: 24, bottom: 40 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  cardHeader(icon: string, title: string) {
    Row({ space: 8 }) {
      Text(icon)
        .fontSize(14)
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().textPrimary)
    }
    .width('100%')
  }

  @Builder
  appearanceCard() {
    Column({ space: 14 }) {
      this.cardHeader('🎨', '外观')
      Row({ space: 10 }) {
        this.modeBlock(THEME_FOLLOW_SYSTEM, '跟随系统', '◐')
        this.modeBlock(THEME_DARK, '深色', '☾')
        this.modeBlock(THEME_LIGHT, '浅色', '☀')
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  @Builder
  modeBlock(mode: number, label: string, glyph: string) {
    Column({ space: 6 }) {
      Text(glyph)
        .fontSize(18)
        .fontColor(this.themeMode === mode ? this.t().accent : this.t().textSecondary)
      Text(label)
        .fontSize(12)
        .fontColor(this.themeMode === mode ? this.t().textPrimary : this.t().textSecondary)
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .borderRadius(12)
    .border({
      width: this.themeMode === mode ? 1.5 : 1,
      color: this.themeMode === mode ? this.t().accent : this.t().border,
    })
    .backgroundColor(this.themeMode === mode ? this.t().navActiveBg : Color.Transparent)
    .onClick(() => {
      this.applyThemeMode(mode);
    })
  }

  @Builder
  accountCard() {
    Column({ space: 12 }) {
      this.cardHeader('📡', '服务器与账号')

      Row() {
        Text('服务器')
          .fontSize(13)
          .fontColor(this.t().textSecondary)
        Text(this.serverUrl === '' ? '未配置' : this.serverUrl)
          .fontSize(13)
          .fontColor(this.serverUrl === '' ? this.t().textTertiary : this.t().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
          .margin({ left: 12 })
      }
      .width('100%')

      Row() {
        Text('用户名')
          .fontSize(13)
          .fontColor(this.t().textSecondary)
        Text(this.username === '' ? '未配置' : this.username)
          .fontSize(13)
          .fontColor(this.username === '' ? this.t().textTertiary : this.t().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
          .margin({ left: 12 })
      }
      .width('100%')

      Row() {
        Text('密码')
          .fontSize(13)
          .fontColor(this.t().textSecondary)
        Blank()
        Text(this.hasPassword ? '已保存' : '未保存')
          .fontSize(13)
          .fontColor(this.hasPassword ? this.t().success : this.t().textTertiary)
      }
      .width('100%')

      Row() {
        Text('dsh 令牌')
          .fontSize(13)
          .fontColor(this.t().textSecondary)
        Blank()
        Text(this.hasToken ? '已保存' : '未保存')
          .fontSize(13)
          .fontColor(this.hasToken ? this.t().success : this.t().textTertiary)
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  @Builder
  hiddenCard() {
    Column({ space: 12 }) {
      Row() {
        Row({ space: 8 }) {
          Text('🗄')
            .fontSize(14)
          Text('隐藏的会话')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.t().textPrimary)
        }
        .layoutWeight(1)
        .onClick(() => {
          if (this.hiddenCount > 0) {
            this.toggleHidden();
          }
        })

        if (this.hiddenCount > 0) {
          Text(this.hiddenExpanded ? '收起 ▴' : '展开 ▾')
            .fontSize(12)
            .fontColor(this.t().accent)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(10)
            .backgroundColor(this.t().navActiveBg)
            .onClick(() => {
              this.toggleHidden();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('长按会话可仅在本机隐藏（不影响服务器）。展开可逐个恢复。')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .lineHeight(18)
        .width('100%')

      if (this.hiddenExpanded && this.hiddenLoading) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(this.t().accent)
          Text('正在读取隐藏会话…')
            .fontSize(12)
            .fontColor(this.t().textTertiary)
        }
        .width('100%')
      }

      if (this.hiddenExpanded && this.hiddenCount === 0) {
        Text('当前没有隐藏的会话')
          .fontSize(12)
          .fontColor(this.t().textTertiary)
          .width('100%')
      }

      if (this.hiddenExpanded && this.hiddenRows.length > 0) {
        Column() {
          ForEach(this.hiddenRows, (r: HiddenRow) => {
            this.hiddenRow(r)
          }, (r: HiddenRow) => r.id)
        }
        .width('100%')
        .borderRadius(12)
        .backgroundColor(this.t().navActiveBg)
      }

      Row() {
        Text('已隐藏 ' + this.hiddenCount + ' 个会话')
          .fontSize(13)
          .fontColor(this.t().textSecondary)
          .layoutWeight(1)
        if (this.hiddenCount > 0) {
          Button('全部恢复')
            .height(36)
            .fontSize(13)
            .fontColor(this.t().accent)
            .backgroundColor(this.t().navActiveBg)
            .borderRadius(12)
            .onClick(() => {
              this.restoreHidden();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  /** 单条隐藏会话行：标题 + 逐个恢复。 */
  @Builder
  hiddenRow(r: HiddenRow) {
    Row() {
      Text(r.title)
        .fontSize(13)
        .fontColor(this.t().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('恢复')
        .fontSize(12)
        .fontColor(this.t().accent)
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .margin({ left: 8 })
        .borderRadius(9)
        .border({ width: 1, color: this.t().accent })
        .onClick(() => {
          this.restoreOne(r);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
  }

  private async restoreHidden(): Promise<void> {
    try {
      await DshConfigStore.clearHiddenSessions(getContext(this));
      this.hiddenCount = 0;
      this.hiddenRows = [];
      this.notifyHiddenChanged();
      promptAction.showToast({ message: '已恢复全部隐藏会话' });
    } catch (err) {
      const e = err as BusinessError;
      promptAction.showToast({ message: '恢复失败：' + e.message });
    }
  }

  @Builder
  tokenCard() {
    Column({ space: 12 }) {
      this.cardHeader('🔑', '重新粘贴 dsh 令牌')
      Text('dsh web 重启后旧令牌会失效。在云主机重新运行 dsh web，复制打印的完整 URL 粘贴到下面，保存后工作台将自动重新登录。')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .lineHeight(18)
        .width('100%')
      Button(this.tokenEditorOpen ? '收起' : '粘贴新令牌')
        .height(38)
        .fontSize(13)
        .fontColor(this.t().accent)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .onClick(() => {
          this.tokenEditorOpen = !this.tokenEditorOpen;
        })
      if (this.tokenEditorOpen) {
        TextArea({ text: this.tokenUrlInput, placeholder: 'http://…/?token=xxx' })
          .width('100%')
          .height(88)
          .fontSize(12)
          .fontColor(this.t().textPrimary)
          .placeholderColor(this.t().textTertiary)
          .backgroundColor(this.t().navActiveBg)
          .borderRadius(12)
          .onChange((value: string) => {
            this.tokenUrlInput = value;
          })
        Button() {
          Row({ space: 8 }) {
            if (this.savingToken) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(this.t().onAccent)
            }
            Text(this.savingToken ? '保存中…' : '保存并重新登录')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.t().onAccent)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height(42)
        .borderRadius(12)
        .backgroundColor(Color.Transparent)
        .linearGradient({
          angle: 135,
          colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
        })
        .enabled(!this.savingToken)
        .onClick(() => {
          this.saveToken();
        })
      }
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  /** 完整版控制台入口（WebView，加载较慢，作为备用全功能通道）。 */
  @Builder
  consoleCard() {
    Column({ space: 12 }) {
      this.cardHeader('🖥', '完整版控制台')
      Text('内嵌 dsh 官方网页控制台。功能最全，但需加载完整网页，打开较慢；日常任务建议用"会话"页。')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .lineHeight(18)
        .width('100%')
      Button('打开完整版控制台')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().accent)
        .backgroundColor(Color.Transparent)
        .borderRadius(12)
        .border({ width: 1, color: this.t().border })
        .onClick(() => {
          this.onOpenConsole();
        })
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  @Builder
  dangerCard() {
    Column({ space: 12 }) {
      this.cardHeader('⚠️', '危险区')
      Text('清除本机保存的全部配置、凭据与令牌，应用将回到首次引导。')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .lineHeight(18)
        .width('100%')
      Button('清除全部数据')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().danger)
        .backgroundColor(Color.Transparent)
        .borderRadius(12)
        .border({ width: 1, color: this.t().danger })
        .onClick(() => {
          this.confirmWipe();
        })
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  @Builder
  aboutCard() {
    Column({ space: 10 }) {
      this.cardHeader('ℹ️', '关于')
      Text('PocketDSH v1.0.0 · 内嵌 DeepSeek Harness 控制台 · 双主题 · 阔折叠适配')
        .fontSize(12)
        .fontColor(this.t().textSecondary)
        .lineHeight(18)
        .width('100%')
    }
    .width('100%')
    .padding(18)
    .borderRadius(18)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }
}
