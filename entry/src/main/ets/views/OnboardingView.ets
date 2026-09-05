/** 首次引导（三步）：服务器地址 → Basic Auth 账号 → 粘贴并校验 dsh 令牌。凭据仅保存在本机。 */
import http from '@ohos.net.http';
import util from '@ohos.util';
import promptAction from '@ohos.promptAction';
import { BusinessError } from '@ohos.base';
import { DshConfigStore } from '../service/DshConfigStore';
import { DshApiClient } from '../service/DshApiClient';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { DEFAULT_SERVER, DEFAULT_USERNAME } from '../model/DshTypes';

@Component
export struct OnboardingView {
  /** 引导完成回调（Index 据此切换到主界面）。 */
  onCompleted: () => void = () => {};

  @StorageProp('themeIsDark') dark: boolean = true;

  /** 当前步骤：0 服务器地址 / 1 账号 / 2 令牌。 */
  @State step: number = 0;
  @State serverUrl: string = DEFAULT_SERVER;
  @State username: string = DEFAULT_USERNAME;
  @State password: string = '';
  @State tokenUrl: string = '';
  @State errorMsg: string = '';
  @State validating: boolean = false;

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  private prev(): void {
    this.errorMsg = '';
    if (this.step > 0) {
      this.step = this.step - 1;
    }
  }

  private next(): void {
    this.errorMsg = '';
    if (this.step === 0) {
      if (this.serverUrl.trim() === '') {
        this.errorMsg = '请填写服务器地址';
        return;
      }
      this.step = 1;
      return;
    }
    if (this.step === 1) {
      if (this.username.trim() === '' || this.password === '') {
        this.errorMsg = '请填写用户名与密码';
        return;
      }
      this.step = 2;
      return;
    }
    this.verifyToken();
  }

  /** Basic Auth 头：user:pass 经 UTF-8 编码后 Base64。 */
  private buildBasicAuth(): string {
    const raw = this.username.trim() + ':' + this.password;
    const encoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encode(raw);
    const helper = new util.Base64Helper();
    return 'Basic ' + helper.encodeToStringSync(bytes);
  }

  /** 从服务器自动令牌端点拉取令牌（需服务器端配置 /.pocketdsh/token）。 */
  private async autoFetchToken(): Promise<void> {
    this.errorMsg = '';
    this.validating = true;
    try {
      const serverUrl: string = DshConfigStore.normalizeServerUrl(this.serverUrl.trim());
      const url: string = await DshApiClient.fetchAutoTokenUrl(serverUrl, this.username.trim(), this.password);
      if (url !== '') {
        this.tokenUrl = url;
        promptAction.showToast({ message: '已自动获取令牌，请点击“验证并完成”' });
      } else {
        this.errorMsg = '服务器未配置自动令牌端点（/.pocketdsh/token），请手动粘贴令牌 URL';
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.errorMsg = '自动获取失败：' + e.message;
    } finally {
      this.validating = false;
    }
  }

  /** 本地预检后带 Basic Auth 真实 GET 令牌 URL，跟随重定向后以 200 为成功。 */
  private async verifyToken(): Promise<void> {
    const url = this.tokenUrl.trim();
    if (!url.startsWith('http') || url.indexOf('token=') < 0) {
      this.errorMsg = 'URL 需以 http 开头且包含 token= 参数，请完整复制 dsh web 打印的地址';
      return;
    }
    this.errorMsg = '';
    this.validating = true;
    const client = http.createHttp();
    try {
      const header: Record<string, string> = { 'Authorization': this.buildBasicAuth() };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        connectTimeout: 10000,
        readTimeout: 10000,
      };
      // 系统网络库默认跟随重定向（最多 5 次），resp 为最终响应。
      const resp: http.HttpResponse = await client.request(url, options);
      const body: string = resp.result as string;
      if (resp.responseCode === 200) {
        const ctx = getContext(this);
        const serverUrl = DshConfigStore.normalizeServerUrl(this.serverUrl.trim());
        await DshConfigStore.saveAccount(ctx, serverUrl, this.username.trim());
        await DshConfigStore.savePassword(this.password);
        await DshConfigStore.saveTokenUrl(url);
        await DshConfigStore.setOnboarded(ctx, true);
        this.onCompleted();
        return;
      }
      if (resp.responseCode === 401) {
        if (body.indexOf('authentication required') >= 0) {
          this.errorMsg = 'dsh 令牌无效或已过期，请重新复制';
        } else {
          this.errorMsg = '服务器用户名或密码错误';
        }
      } else {
        this.errorMsg = '服务器返回异常状态码：HTTP ' + resp.responseCode;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.errorMsg = '网络异常：' + e.message;
    } finally {
      client.destroy();
      this.validating = false;
    }
  }

  build() {
    Column() {
      Column() {
        Text('◈')
          .fontSize(24)
          .fontColor(this.t().onAccent)
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .borderRadius(15)
          .linearGradient({
            angle: 135,
            colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
          })

        Text('PocketDSH')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
          .margin({ top: 12 })

        Text('首次引导 · 连接你的 DeepSeek Harness')
          .fontSize(12)
          .fontColor(this.t().textSecondary)
          .margin({ top: 4 })

        Row({ space: 8 }) {
          this.dot(0)
          this.dot(1)
          this.dot(2)
        }
        .margin({ top: 18 })

        if (this.step === 0) {
          this.stepServer()
        } else if (this.step === 1) {
          this.stepAccount()
        } else {
          this.stepToken()
        }

        if (this.errorMsg !== '') {
          Text(this.errorMsg)
            .fontSize(13)
            .fontColor(this.t().danger)
            .width('100%')
            .margin({ top: 12 })
        }

        Row({ space: 12 }) {
          if (this.step > 0) {
            Button('上一步')
              .layoutWeight(1)
              .height(46)
              .fontSize(15)
              .fontColor(this.t().textSecondary)
              .backgroundColor(this.t().navActiveBg)
              .borderRadius(14)
              .enabled(!this.validating)
              .onClick(() => {
                this.prev();
              })
          }
          Button() {
            Row({ space: 8 }) {
              if (this.validating) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color(this.t().onAccent)
              }
              Text(this.validating ? '正在验证…' : (this.step < 2 ? '下一步' : '验证并完成'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.t().onAccent)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }
          .layoutWeight(1)
          .height(46)
          .borderRadius(14)
          .backgroundColor(Color.Transparent)
          .linearGradient({
            angle: 135,
            colors: [[this.t().accent, 0.0], [this.t().accent2, 1.0]],
          })
          .enabled(!this.validating)
          .onClick(() => {
            this.next();
          })
        }
        .width('100%')
        .margin({ top: 22 })
      }
      .width('86%')
      .constraintSize({ maxWidth: 480 })
      .padding({ left: 24, right: 24, top: 30, bottom: 26 })
      .borderRadius(24)
      .backgroundColor(this.t().bgCard)
      .border({ width: 1, color: this.t().border })

      Text('PocketDSH 仅在本机加密保存凭据')
        .fontSize(11)
        .fontColor(this.t().textTertiary)
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  dot(index: number) {
    Column()
      .width(this.step === index ? 20 : 8)
      .height(8)
      .borderRadius(4)
      .backgroundColor(this.step === index ? this.t().accent : this.t().border)
      .animation({ duration: 200, curve: Curve.EaseOut })
  }

  @Builder
  stepServer() {
    Column({ space: 10 }) {
      Text('1 · 服务器地址')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().textPrimary)
        .width('100%')
        .margin({ top: 20 })
      Text('填写 PocketDSH 服务器的根地址，通常为 https:// 开头、结尾不带斜杠。')
        .fontSize(12)
        .fontColor(this.t().textSecondary)
        .lineHeight(18)
        .width('100%')
      TextInput({ text: this.serverUrl, placeholder: 'https://dsh.example.com' })
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(this.t().textPrimary)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .onChange((value: string) => {
          this.serverUrl = value;
        })
    }
    .width('100%')
  }

  @Builder
  stepAccount() {
    Column({ space: 10 }) {
      Text('2 · 服务器账号')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().textPrimary)
        .width('100%')
        .margin({ top: 20 })
      Text('nginx Basic Auth 用户名与密码，用于通过网关认证。')
        .fontSize(12)
        .fontColor(this.t().textSecondary)
        .lineHeight(18)
        .width('100%')
      TextInput({ text: this.username, placeholder: '用户名' })
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(this.t().textPrimary)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .onChange((value: string) => {
          this.username = value;
        })
      TextInput({ text: this.password, placeholder: '密码' })
        .type(InputType.Password)
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(this.t().textPrimary)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .onChange((value: string) => {
          this.password = value;
        })
    }
    .width('100%')
  }

  @Builder
  stepToken() {
    Column({ space: 10 }) {
      Text('3 · 粘贴 dsh 令牌')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.t().textPrimary)
        .width('100%')
        .margin({ top: 20 })
      Text('在云主机上运行 dsh web 会打印形如 http://…/?token=xxx 的 URL，完整复制粘贴到这里。')
        .fontSize(12)
        .fontColor(this.t().textSecondary)
        .lineHeight(18)
        .width('100%')
      Button('✨ 自动获取令牌（需服务器端配置）')
        .width('100%')
        .height(40)
        .fontSize(13)
        .fontColor(this.t().accent)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .enabled(!this.validating)
        .onClick(() => {
          this.autoFetchToken();
        })
      TextArea({ text: this.tokenUrl, placeholder: 'http://…/?token=xxx' })
        .width('100%')
        .height(92)
        .fontSize(13)
        .fontColor(this.t().textPrimary)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().navActiveBg)
        .borderRadius(12)
        .onChange((value: string) => {
          this.tokenUrl = value;
        })
    }
    .width('100%')
  }
}
