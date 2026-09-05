import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import preferences from '@ohos.data.preferences';
import { KEY_CONFIG_READY, KEY_THEME_IS_DARK, KEY_THEME_MODE } from '../model/DshTypes';
import { ThemeManager } from '../theme/Theme';

const DOMAIN = 0x0000;
const TAG = 'PocketDSH';

export default class EntryAbility extends UIAbility {
  private themeMode: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 同步读取配置，保证 Index 首帧渲染时 AppStorage 已就绪（避免引导页闪烁）。
    try {
      const store = preferences.getPreferencesSync(this.context, { name: 'dsh_config' });
      this.themeMode = store.getSync('themeMode', 0) as number;
      const onboarded = store.getSync('onboarded', false) as boolean;
      AppStorage.setOrCreate(KEY_THEME_MODE, this.themeMode);
      AppStorage.setOrCreate(KEY_THEME_IS_DARK, true);
      AppStorage.setOrCreate(KEY_CONFIG_READY, onboarded);
      AppStorage.setOrCreate('tokenRefreshTick', 0);
      ThemeManager.apply(this.themeMode, this.isSystemDark());
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load config failed: %{public}s', JSON.stringify(err));
      AppStorage.setOrCreate(KEY_THEME_MODE, 0);
      AppStorage.setOrCreate(KEY_THEME_IS_DARK, true);
      AppStorage.setOrCreate(KEY_CONFIG_READY, false);
      AppStorage.setOrCreate('tokenRefreshTick', 0);
    }
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  private isSystemDark(): boolean {
    const cfg = this.context.config;
    if (cfg === undefined || cfg === null) {
      return false;
    }
    return cfg.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 跟随系统模式下，系统深浅色切换时同步主题。
    if (this.themeMode === 0) {
      ThemeManager.apply(0, newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    // 读取底部系统导航条（手势条）避让高度，供底栏/输入区垫底，避免按钮点不到
    try {
      const mainWin: window.Window = windowStage.getMainWindowSync();
      const avoid: window.AvoidArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('bottomAvoidPx', avoid.bottomRect.height);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'read avoid area failed: %{public}s', JSON.stringify(err));
      AppStorage.setOrCreate('bottomAvoidPx', 0);
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
