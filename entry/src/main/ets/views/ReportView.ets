/** 策略报告 Tab：浏览器式打开服务器 /reports/（nginx 目录页），返回深度与外壳协调。 */
import common from '@ohos.app.ability.common';
import { DshConfigStore } from '../service/DshConfigStore';
import { ReportBrowser } from './ReportBrowser';
import { KEY_REPORT_BACK_DEPTH } from '../model/DshTypes';

@Component
export struct ReportView {
  @State homeUrl: string = '';
  @State targetUrl: string = '';

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    DshConfigStore.load(ctx)
      .then((data) => {
        this.homeUrl = data.serverUrl + '/reports/';
        this.targetUrl = this.homeUrl;
      })
      .catch((_e: Object) => {
        // 配置异常保持空 URL：组件呈现 about:blank，引导完成后重进 Tab 生效
      });
  }

  build() {
    Column() {
      if (this.targetUrl !== '') {
        ReportBrowser({
          urlToLoad: this.targetUrl,
          homeUrl: this.homeUrl,
          onDepthChange: (canBack: boolean) => {
            AppStorage.setOrCreate(KEY_REPORT_BACK_DEPTH, canBack ? 1 : 0);
          },
        })
          .width('100%')
          .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
