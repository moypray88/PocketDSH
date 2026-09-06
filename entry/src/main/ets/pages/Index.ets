import { HomeView } from '../views/HomeView';
import { WorkspaceView } from '../views/WorkspaceView';
import { WorkspaceChatView } from '../views/WorkspaceChatView';
import { SettingsView } from '../views/SettingsView';
import { OnboardingView } from '../views/OnboardingView';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { KEY_CONFIG_READY, KEY_CUR_TAB } from '../model/DshTypes';

enum TabId {
  Sessions = 0,
  Home = 1,
  Console = 2,
  Settings = 3,
}

/** 应用外壳：阔折叠展开态走左侧导航栏，合盖外屏走底部 Tab，断点自动切换。 */
@Entry
@Component
struct Index {
  @StorageProp('themeIsDark') dark: boolean = true;
  @StorageProp(KEY_CONFIG_READY) configReady: boolean = false;
  /** 底部系统导航条避让高度（px），底栏据此垫底。 */
  @StorageProp('bottomAvoidPx') bottomAvoidPx: number = 0;
  @State cur: TabId = TabId.Home;
  @State expanded: boolean = true;

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
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

  /** 动作型底栏项（新建）。 */
  @Builder
  barAction(glyph: string, label: string) {
    Column() {
      Text(glyph)
        .fontSize(19)
        .fontColor(this.t().accent2)
      Text(label)
        .fontSize(9)
        .margin({ top: 1 })
        .fontColor(this.t().textSecondary)
    }
    .layoutWeight(1)
    .constraintSize({ minHeight: 30 })
    .justifyContent(FlexAlign.Center)
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
      this.barAction('✎', '新建')
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
