/** 独立报告浏览器窗口：会话内同源链接拉起；singleton 复用，onNewWant 换页。 */
import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { KEY_REPORT_WINDOW_URL, KEY_REPORT_WINDOW_TICK } from '../model/DshTypes';

const DOMAIN = 0x0000;
const TAG = 'PocketDSH';

export default class ReportViewerAbility extends UIAbility {
  onCreate(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.dispatchWant(want);
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.dispatchWant(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/ReportWindowPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'ReportViewer loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'ReportViewer window loaded');
    });
  }

  /** want.uri → AppStorage，页面监听 tick 换页（首建与复用统一入口）。 */
  private dispatchWant(want: Want): void {
    const uri: string = want.uri !== undefined ? want.uri : '';
    if (uri === '') {
      return;
    }
    AppStorage.setOrCreate(KEY_REPORT_WINDOW_URL, uri);
    const t: number = AppStorage.get<number>(KEY_REPORT_WINDOW_TICK) ?? 0;
    AppStorage.setOrCreate(KEY_REPORT_WINDOW_TICK, t + 1);
  }
}
