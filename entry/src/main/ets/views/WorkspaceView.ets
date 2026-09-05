import web_webview from '@ohos.web.webview';
import { DshConfigStore } from '../service/DshConfigStore';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { KEY_TOKEN_TICK } from '../model/DshTypes';

/**
 * 工作台：内嵌 dsh 官方 Web 控制台。
 * 认证链路：
 *  1. nginx Basic Auth 层 —— onHttpAuthRequest 自动应答，全程无感；
 *  2. dsh 令牌层 —— 首次/失效时以保存的令牌 URL 访问一次，dsh 302 换取签名 Cookie 后免登录；
 *  3. Cookie 失效（dsh web 重启）时自动用令牌重试一次，仍失败则提示去设置重贴令牌。
 */
@Component
export struct WorkspaceView {
  /** 合盖外屏紧凑模式下缩小页面初始缩放，保证控制台可用。 */
  @Prop coverMode: boolean = false;
  onGoSettings: () => void = () => {};

  controller: web_webview.WebviewController = new web_webview.WebviewController();

  @StorageProp('themeIsDark') dark: boolean = true;
  @StorageProp(KEY_TOKEN_TICK) @Watch('onTokenTick') tokenTick: number = 0;

  @State serverUrl: string = '';
  @State basicUser: string = '';
  @State basicPass: string = '';
  @State tokenUrl: string = '';
  @State ready: boolean = false;
  @State attached: boolean = false;
  @State loading: boolean = true;
  @State progress: number = 0;
  @State authFail: boolean = false;
  private tokenTried: boolean = false;

  aboutToAppear(): void {
    this.loadConfig();
  }

  private async loadConfig(): Promise<void> {
    const ctx = getContext(this);
    const data = await DshConfigStore.load(ctx);
    this.serverUrl = data.serverUrl;
    this.basicUser = data.username;
    this.basicPass = await DshConfigStore.getPassword();
    this.tokenUrl = await DshConfigStore.getTokenUrl();
    this.ready = true;
    if (this.attached) {
      this.navigate(false);
    }
  }

  private navigate(withToken: boolean): void {
    if (this.serverUrl === '') {
      return;
    }
    this.loading = true;
    this.authFail = false;
    if (withToken && this.tokenUrl !== '') {
      this.controller.loadUrl(this.tokenUrl);
    } else {
      this.controller.loadUrl(this.serverUrl);
    }
  }

  private onTokenTick(): void {
    if (this.attached && this.ready) {
      this.tokenTried = false;
      this.navigate(true);
    }
  }

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  /** 页面加载结束后检测 dsh 401 文本页，判断登录态是否失效。 */
  private checkAuthState(url: string): void {
    if (this.serverUrl === '' || !url.startsWith(this.serverUrl)) {
      return;
    }
    this.controller.runJavaScript("document.body?document.body.innerText.slice(0,400):''")
      .then((txt: string) => {
        if (txt.indexOf('authentication required') >= 0) {
          if (!this.tokenTried && this.tokenUrl !== '') {
            this.tokenTried = true;
            this.navigate(true);
          } else {
            this.authFail = true;
          }
        } else {
          this.authFail = false;
        }
      })
      .catch(() => {});
  }

  build() {
    Stack() {
      Column() {
        if (this.loading && !this.authFail) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(2)
            .color(this.t().accent)
            .backgroundColor(Color.Transparent)
        }

        Web({ src: 'about:blank', controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .zoomAccess(true)
          .fileAccess(false)
          .darkMode(this.dark ? WebDarkMode.On : WebDarkMode.Off)
          .initialScale(this.coverMode ? 60 : 100)
          .onControllerAttached(() => {
            this.attached = true;
            if (this.ready) {
              this.navigate(false);
            }
          })
          .onPageBegin(() => {
            this.loading = true;
          })
          .onProgressChange((event) => {
            this.progress = event !== undefined ? event.newProgress : this.progress;
          })
          .onPageEnd((event) => {
            this.loading = false;
            this.checkAuthState(event !== undefined ? event.url : '');
          })
          .onHttpAuthRequest((event) => {
            if (event !== undefined && this.basicUser !== '' && this.basicPass !== '') {
              return event.handler.confirm(this.basicUser, this.basicPass);
            }
            return false;
          })
      }
      .width('100%')
      .height('100%')

      if (this.authFail) {
        Column() {
          Column() {
            Text('⚠️')
              .fontSize(40)
            Text('dsh 登录态已失效')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.t().textPrimary)
              .margin({ top: 12 })
            Text('服务器上的 dsh web 可能已重启，旧令牌失效。请从云主机控制台重新复制 dsh web 打印的完整 URL（含 token 参数），粘贴到设置页即可恢复免登录。')
              .fontSize(13)
              .fontColor(this.t().textSecondary)
              .lineHeight(20)
              .margin({ top: 10, bottom: 20 })
            Row({ space: 12 }) {
              Button('用令牌重试')
                .backgroundColor(this.t().navActiveBg)
                .fontColor(this.t().accent)
                .onClick(() => {
                  this.tokenTried = false;
                  this.navigate(true);
                })
              Button('去设置重新粘贴')
                .backgroundColor(this.t().accent)
                .fontColor(this.t().onAccent)
                .onClick(() => {
                  this.onGoSettings();
                })
            }
          }
          .padding(24)
          .borderRadius(20)
          .backgroundColor(this.t().bgCard)
          .border({ width: 1, color: this.t().border })
          .width('82%')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(0,0,0,0.45)')
      }
    }
    .width('100%')
    .height('100%')
  }
}
