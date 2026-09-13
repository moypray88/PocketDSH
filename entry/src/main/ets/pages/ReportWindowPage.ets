/** 独立报告窗口页：ReportViewerAbility 承载的浏览器（✕ 关闭、返回键逐层后退）。 */
import common from '@ohos.app.ability.common';
import { ReportBrowser } from '../views/ReportBrowser';
import { KEY_REPORT_WINDOW_BACK_TICK, KEY_REPORT_WINDOW_URL, KEY_REPORT_WINDOW_TICK } from '../model/DshTypes';

@Entry
@Component
struct ReportWindowPage {
  /** Ability onNewWant 下发的换页信号。 */
  @StorageLink(KEY_REPORT_WINDOW_TICK) @Watch('onWindowTick') winTick: number = 0;
  @State url: string = '';
  @State canBack: boolean = false;

  aboutToAppear(): void {
    const stored: string | undefined = AppStorage.get<string>(KEY_REPORT_WINDOW_URL);
    if (stored !== undefined && stored !== '') {
      this.url = stored;
    }
  }

  private onWindowTick(): void {
    const next: string | undefined = AppStorage.get<string>(KEY_REPORT_WINDOW_URL);
    if (next !== undefined && next !== '' && next !== this.url) {
      this.url = next;
    }
  }

  onBackPress(): boolean {
    if (this.canBack) {
      const t: number = AppStorage.get<number>(KEY_REPORT_WINDOW_BACK_TICK) ?? 0;
      AppStorage.setOrCreate(KEY_REPORT_WINDOW_BACK_TICK, t + 1);
      return true;
    }
    this.closeWindow();
    return true;
  }

  private closeWindow(): void {
    (getContext(this) as common.UIAbilityContext).terminateSelf();
  }

  build() {
    Column() {
      ReportBrowser({
        urlToLoad: this.url,
        showClose: true,
        onDepthChange: (canBack: boolean) => {
          this.canBack = canBack;
        },
        onExitRequest: () => {
          this.closeWindow();
        },
      })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
