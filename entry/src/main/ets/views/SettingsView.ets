/** 设置页：外观主题、服务器与账号、dsh 令牌重贴、危险区数据清除与关于信息。 */
import web_webview from '@ohos.web.webview';
import promptAction from '@ohos.promptAction';
import mediaquery from '@ohos.mediaquery';
import { BusinessError } from '@ohos.base';
import { DshConfigStore } from '../service/DshConfigStore';
import { DshApiClient } from '../service/DshApiClient';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { KEY_CONFIG_READY, KEY_THEME_MODE, KEY_TOKEN_TICK, THEME_DARK, THEME_FOLLOW_SYSTEM, THEME_LIGHT } from '../model/DshTypes';

@Component
export struct SettingsView {
  @StorageProp('themeIsDark') dark: boolean = true;

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
      this.cardHeader('🗄', '隐藏的会话')
      Text('长按会话可仅在本机隐藏（例如 PC 端已归档的会话）。此处可全部恢复。')
        .fontSize(12)
        .fontColor(this.t().textTertiary)
        .lineHeight(18)
        .width('100%')
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

  private async restoreHidden(): Promise<void> {
    try {
      await DshConfigStore.clearHiddenSessions(getContext(this));
      this.hiddenCount = 0;
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
