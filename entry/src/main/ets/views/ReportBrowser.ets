/** 报告浏览器：浏览器式工具条 + WebView。策略报告 Tab 与独立报告窗口共用。 */
import web_webview from '@ohos.web.webview';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { DshApiClient } from '../service/DshApiClient';
import { DshConfigStore } from '../service/DshConfigStore';
import { ReportFavorites, ReportFavItem } from '../service/ReportFavorites';
import { ThemeColors, ThemeManager } from '../theme/Theme';
import { KEY_CUR_TAB, KEY_REPORT_BACK_TICK, KEY_REPORT_WINDOW_BACK_TICK, TAB_REPORTS } from '../model/DshTypes';

@Component
export struct ReportBrowser {
  /** 目标地址：属性变更即导航（独立窗口 onNewWant 换页复用同一组件实例）。 */
  @Prop @Watch('onUrlToLoad') urlToLoad: string = '';
  /** 显示 ✕ 关闭钮（独立窗口形态）。 */
  @Prop showClose: boolean = false;
  /** 非空时「⋮」菜单提供「回到首页」（Tab 形态指向 /reports/）。 */
  @Prop homeUrl: string = '';
  /** webview 是否仍有历史可退（Tab 写 AppStorage 深度、窗口页本地记录）。 */
  onDepthChange: (canBack: boolean) => void = (_canBack: boolean) => {};
  /** 无历史可退时的退出请求（独立窗口返回键/✕ 关窗）。 */
  onExitRequest: () => void = () => {};

  @StorageProp('themeIsDark') dark: boolean = true;
  // Tab 与独立窗口并存时分键监听（showClose 区分形态），避免互相触发后退
  @StorageProp(KEY_REPORT_BACK_TICK) @Watch('onTabBackTick') tabBackTick: number = 0;
  @StorageProp(KEY_REPORT_WINDOW_BACK_TICK) @Watch('onWinBackTick') winBackTick: number = 0;
  /** 外壳当前 Tab：Tab 形态下每次点进「策略报告」都回到报告首页。 */
  @StorageProp(KEY_CUR_TAB) @Watch('onCurTab') curTab: number = -1;

  @State loading: boolean = false;
  @State progress: number = 0;
  @State canBack: boolean = false;
  @State canForward: boolean = false;
  @State rawUrl: string = '';
  @State loadError: string = '';
  @State basicUser: string = '';
  @State basicPass: string = '';
  /** 当前页标题（收藏标题优先用；onPageEnd 异步取 document.title）。 */
  @State pageTitle: string = '';
  /** 精品收藏：收藏面板开关与列表。 */
  @State favOpen: boolean = false;
  @State favItems: ReportFavItem[] = [];
  /** 收藏重命名对话框。 */
  @State favEditOpen: boolean = false;
  @State favEditUrl: string = '';
  @State favEditText: string = '';

  controller: web_webview.WebviewController = new web_webview.WebviewController();
  private attached: boolean = false;

  private t(): ThemeColors {
    return ThemeManager.palette(this.dark);
  }

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    DshConfigStore.load(ctx)
      .then((data) => {
        this.basicUser = data.username;
        return DshConfigStore.getPassword();
      })
      .then((pass: string) => {
        this.basicPass = pass;
      })
      .catch((_e: Object) => {});
    this.syncCookie(this.urlToLoad);
    ReportFavorites.list(ctx)
      .then((items: ReportFavItem[]) => {
        this.favItems = items;
      })
      .catch((_e: Object) => {});
  }

  /** 同步原生 dsh Cookie 到 WebView 罐：/reports/ 免认证可直开，dsh 同域页面兜底。 */
  private syncCookie(url: string): void {
    if (url.indexOf('http') !== 0) {
      return;
    }
    DshApiClient.ensureWebCookie(getContext(this))
      .then((cookie: string) => {
        if (cookie !== '') {
          web_webview.WebCookieManager.configCookieSync(url, cookie);
        }
      })
      .catch((_e: Object) => {});
  }

  private navigate(url: string): void {
    if (url === '') {
      return;
    }
    this.loading = true;
    this.loadError = '';
    if (this.attached) {
      this.controller.loadUrl(url);
    }
  }

  /** 属性换页（独立窗口 onNewWant）。 */
  private onUrlToLoad(): void {
    this.syncCookie(this.urlToLoad);
    this.navigate(this.urlToLoad);
  }

  /** 外壳切到「策略报告」Tab：回到报告首页（仅 Tab 形态；已在首页则不重载）。 */
  private onCurTab(): void {
    if (this.showClose || this.homeUrl === '') {
      return;
    }
    if (this.curTab !== TAB_REPORTS) {
      return;
    }
    if (this.rawUrl !== '' && this.rawUrl !== this.homeUrl) {
      this.navigate(this.homeUrl);
    }
  }

  /** 返回键信号（Tab 实例）：有历史则后退，无历史交还退出流程。 */
  private onTabBackTick(): void {
    if (!this.showClose) {
      this.handleBackPop();
    }
  }

  /** 返回键信号（独立窗口实例）。 */
  private onWinBackTick(): void {
    if (this.showClose) {
      this.handleBackPop();
    }
  }

  private handleBackPop(): void {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return;
      }
    } catch (err) {
      // controller 尚未附加时忽略
    }
    if (this.showClose) {
      this.onExitRequest();
    }
  }

  /** 刷新后退/前进可用态并上报深度。 */
  private refreshNavState(): void {
    let back: boolean = false;
    let forward: boolean = false;
    try {
      back = this.controller.accessBackward();
      forward = this.controller.accessForward();
    } catch (err) {
      // controller 未附加
    }
    this.canBack = back;
    this.canForward = forward;
    this.onDepthChange(back);
  }

  private displayUrl(): string {
    if (this.rawUrl === '') {
      return this.urlToLoad === '' ? 'about:blank' : this.urlToLoad;
    }
    let shown: string = this.rawUrl.replace(/^https?:\/\//, '');
    try {
      shown = decodeURI(shown);
    } catch (err) {
      // 含异常百分号编码时保持原样
    }
    return shown;
  }

  /** onPageEnd 后异步取页面标题，收藏标题优先使用。 */
  private fetchPageTitle(): void {
    try {
      this.controller.runJavaScript('document.title')
        .then((t: string) => {
          this.pageTitle = t !== undefined ? t : '';
        })
        .catch((_e: Object) => {
          this.pageTitle = '';
        });
    } catch (err) {
      this.pageTitle = '';
    }
  }

  /** 收藏标题：页面 title 优先（nginx autoindex 的 "Index of …" 转为路径名），退化用 URL 末段。 */
  private favTitleOf(url: string): string {
    if (this.pageTitle !== '') {
      if (this.pageTitle.indexOf('Index of ') === 0) {
        return this.autoindexTitle(url);
      }
      return this.pageTitle;
    }
    return this.deriveNameFromUrl(url);
  }

  /** 目录页标题：取 /reports/ 之后的路径段（如 industry-analysis），比 "Index of /…" 友好。 */
  private autoindexTitle(url: string): string {
    const schemeAt: number = url.indexOf('://');
    let path: string = schemeAt > 0 ? url.substring(schemeAt + 3) : url;
    const hashAt: number = path.indexOf('#');
    if (hashAt >= 0) {
      path = path.substring(0, hashAt);
    }
    const queryAt: number = path.indexOf('?');
    if (queryAt >= 0) {
      path = path.substring(0, queryAt);
    }
    const marker: string = '/reports/';
    const at: number = path.indexOf(marker);
    if (at >= 0) {
      let sub: string = path.substring(at + marker.length);
      while (sub.length > 0 && sub.charAt(sub.length - 1) === '/') {
        sub = sub.substring(0, sub.length - 1);
      }
      try {
        sub = decodeURI(sub);
      } catch (err) {
        // 含异常百分号编码时保持原样
      }
      if (sub !== '') {
        return sub;
      }
    }
    return this.deriveNameFromUrl(url);
  }

  /** URL 末段派生名：目录取上一段，文件去扩展名，均解码。 */
  private deriveNameFromUrl(url: string): string {
    let path: string = url;
    const schemeAt: number = url.indexOf('://');
    if (schemeAt > 0) {
      path = url.substring(schemeAt + 3);
    }
    const slash: number = path.lastIndexOf('/');
    let name: string = slash >= 0 ? path.substring(slash + 1) : path;
    if (name === '' && slash > 0) {
      name = path.substring(0, slash);
      const prev: number = name.lastIndexOf('/');
      name = prev >= 0 ? name.substring(prev + 1) : name;
    }
    const dot: number = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    try {
      name = decodeURI(name);
    } catch (err) {
      // 含异常百分号编码时保持原样
    }
    return name === '' ? url : name;
  }

  /** 收藏行副标题：去掉协议头的短地址。 */
  private shortUrl(url: string): string {
    const at: number = url.indexOf('://');
    return at > 0 ? url.substring(at + 3) : url;
  }

  /** 当前页是否已收藏。 */
  private isCurrentFav(): boolean {
    if (this.rawUrl === '') {
      return false;
    }
    for (let i: number = 0; i < this.favItems.length; i++) {
      if (this.favItems[i].url === this.rawUrl) {
        return true;
      }
    }
    return false;
  }

  /** 收藏/取消收藏当前页。 */
  private async toggleFav(): Promise<void> {
    const url: string = this.rawUrl;
    if (url === '') {
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      if (this.isCurrentFav()) {
        await ReportFavorites.remove(ctx, url);
        promptAction.showToast({ message: '已取消收藏' });
      } else {
        await ReportFavorites.add(ctx, url, this.favTitleOf(url));
        promptAction.showToast({ message: '已收藏' });
      }
      this.favItems = await ReportFavorites.list(ctx);
    } catch (err) {
      promptAction.showToast({ message: '收藏操作失败' });
    }
  }

  /** 打开收藏面板（先刷新列表）。 */
  private async openFavs(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      this.favItems = await ReportFavorites.list(ctx);
    } catch (err) {
      this.favItems = [];
    }
    this.favOpen = true;
  }

  /** 删除一条收藏。 */
  private async removeFav(item: ReportFavItem): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      await ReportFavorites.remove(ctx, item.url);
      this.favItems = await ReportFavorites.list(ctx);
      promptAction.showToast({ message: '已删除收藏' });
    } catch (err) {
      promptAction.showToast({ message: '删除失败' });
    }
  }

  /** 打开收藏重命名对话框（预填当前名称）。 */
  private openFavEdit(item: ReportFavItem): void {
    this.favEditUrl = item.url;
    this.favEditText = item.title;
    this.favEditOpen = true;
  }

  /** 保存收藏名称。 */
  private async saveFavEdit(): Promise<void> {
    const title: string = this.favEditText.trim();
    if (title === '') {
      promptAction.showToast({ message: '名称不能为空' });
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      await ReportFavorites.rename(ctx, this.favEditUrl, title);
      this.favItems = await ReportFavorites.list(ctx);
      this.favEditOpen = false;
      promptAction.showToast({ message: '已重命名' });
    } catch (err) {
      promptAction.showToast({ message: '重命名失败' });
    }
  }

  private copyLink(): void {
    const url: string = this.rawUrl !== '' ? this.rawUrl : this.urlToLoad;
    if (url === '') {
      return;
    }
    pasteboard.getSystemPasteboard()
      .setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url))
      .then(() => {
        promptAction.showToast({ message: '链接已复制' });
      })
      .catch((_e: Object) => {
        promptAction.showToast({ message: '复制失败' });
      });
  }

  private async openSystem(): Promise<void> {
    const url: string = this.rawUrl !== '' ? this.rawUrl : this.urlToLoad;
    if (url === '') {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await ctx.openLink(url);
    } catch (err) {
      promptAction.showToast({ message: '无法打开系统浏览器' });
    }
  }

  private async showMenu(): Promise<void> {
    const accent: string = this.t().textPrimary;
    // showActionMenu 的 buttons 是定长元组：三钮固定，第三钮按形态区分
    try {
      const resp: promptAction.ActionMenuSuccessResponse = await promptAction.showActionMenu({
        title: '页面操作',
        buttons: [
          { text: '在系统浏览器打开', color: accent },
          { text: '复制链接', color: accent },
          { text: this.homeUrl !== '' ? '回到报告首页' : '关闭窗口', color: accent },
          { text: '★ 我的收藏', color: accent },
        ],
      });
      if (resp.index === 0) {
        this.openSystem();
      } else if (resp.index === 1) {
        this.copyLink();
      } else if (resp.index === 2) {
        if (this.homeUrl !== '') {
          this.navigate(this.homeUrl);
        } else {
          this.onExitRequest();
        }
      } else if (resp.index === 3) {
        this.openFavs();
      }
    } catch (err) {
      // 用户点遮罩取消
    }
  }

  @Builder
  toolBtn(glyph: string, enabled: boolean, onTap: () => void) {
    Text(glyph)
      .fontSize(19)
      .fontColor(enabled ? this.t().textPrimary : this.t().textTertiary)
      .width(34)
      .height(34)
      .textAlign(TextAlign.Center)
      .borderRadius(10)
      .onClick(() => {
        if (enabled) {
          onTap();
        }
      })
  }

  build() {
    Stack() {
      Column() {
        // 浏览器工具条
      Row({ space: 4 }) {
        if (this.showClose) {
          this.toolBtn('✕', true, (): void => {
            this.onExitRequest();
          })
        }
        // 后退/前进/收藏：动态态直接内联读 @State（@Builder 值传参不响应更新的教训）
        Text('‹')
          .fontSize(22)
          .fontColor(this.canBack ? this.t().textPrimary : this.t().textTertiary)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .onClick(() => {
            if (this.canBack) {
              this.controller.backward();
            }
          })
        Text('›')
          .fontSize(22)
          .fontColor(this.canForward ? this.t().textPrimary : this.t().textTertiary)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .onClick(() => {
            if (this.canForward) {
              this.controller.forward();
            }
          })
        // 地址胶囊：点击复制（终端风深底配 termText 浅字，双主题可读）
        Text(this.displayUrl())
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(this.t().termText)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .padding({ left: 12, right: 12 })
          .height(32)
          .borderRadius(16)
          .backgroundColor(this.t().termBg)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.copyLink();
          })
        this.toolBtn('↻', true, (): void => {
          this.loading = true;
          try {
            this.controller.refresh();
          } catch (err) {
            // 未附加时忽略
          }
        })
        Text(this.isCurrentFav() ? '★' : '☆')
          .fontSize(19)
          .fontColor(this.rawUrl === ''
            ? this.t().textTertiary
            : (this.isCurrentFav() ? this.t().warn : this.t().textPrimary))
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(10)
          .onClick(() => {
            this.toggleFav();
          })
        this.toolBtn('⋮', true, (): void => {
          this.showMenu();
        })
      }
      .width('100%')
      .height(46)
      .padding({ left: 6, right: 6 })
      .backgroundColor(this.t().bgCard)
      .border({ width: { bottom: 0.5 }, color: this.t().border })

      // 顶部细进度线
      if (this.loading && !this.loadError) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(2)
          .color(this.t().accent)
          .backgroundColor(Color.Transparent)
      }

      Stack() {
        Web({ src: 'about:blank', controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .zoomAccess(true)
          .fileAccess(false)
          .darkMode(WebDarkMode.Off)
          // nginx autoindex 无 viewport meta：概览模式缩放至屏宽（报告页自带 viewport 不受影响）
          .overviewModeAccess(true)
          .onControllerAttached(() => {
            this.attached = true;
            this.navigate(this.urlToLoad);
          })
          .onPageBegin((_event) => {
            this.loading = true;
            this.loadError = '';
          })
          .onProgressChange((event) => {
            this.progress = event !== undefined ? event.newProgress : this.progress;
          })
          .onPageEnd((event) => {
            this.loading = false;
            this.rawUrl = event !== undefined ? event.url : this.rawUrl;
            this.refreshNavState();
            this.fetchPageTitle();
          })
          .onErrorReceive((event) => {
            // 仅主资源错误呈现为整页失败（子资源失败不打断阅读）
            if (event === undefined || !event.request.isMainFrame()) {
              return;
            }
            this.loading = false;
            this.loadError = event.error.getErrorInfo();
          })
          .onHttpAuthRequest((event) => {
            if (event !== undefined && this.basicUser !== '' && this.basicPass !== '') {
              return event.handler.confirm(this.basicUser, this.basicPass);
            }
            return false;
          })

        // 加载失败覆盖卡：Web 保持挂载以便重试
        if (this.loadError !== '') {
          Column() {
            Column({ space: 10 }) {
              Text('⚠️')
                .fontSize(38)
              Text('页面加载失败')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.t().textPrimary)
              Text(this.loadError)
                .fontSize(12)
                .fontColor(this.t().textSecondary)
                .textAlign(TextAlign.Center)
                .maxLines(3)
              Row({ space: 12 }) {
                Button('重试')
                  .backgroundColor(this.t().accent)
                  .fontColor(this.t().onAccent)
                  .onClick(() => {
                    this.loadError = '';
                    this.loading = true;
                    try {
                      this.controller.loadUrl(this.rawUrl !== '' ? this.rawUrl : this.urlToLoad);
                    } catch (err) {
                      this.loading = false;
                    }
                  })
                Button('复制链接')
                  .backgroundColor(this.t().navActiveBg)
                  .fontColor(this.t().accent)
                  .onClick(() => {
                    this.copyLink();
                  })
              }
              .margin({ top: 6 })
            }
            .width('82%')
            .padding(24)
            .borderRadius(20)
            .backgroundColor(this.t().bgCard)
            .border({ width: 1, color: this.t().border })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('rgba(0,0,0,0.45)')
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
      .width('100%')
      .height('100%')
      .backgroundColor(this.t().bgGradEnd)

    // 精品收藏面板（底部抽屉）
    if (this.favOpen) {
      this.favOverlay()
    }

    // 收藏重命名对话框（盖在收藏面板之上）
    if (this.favEditOpen) {
      this.favEditOverlay()
    }
  }
  .width('100%')
  .height('100%')
  }

  /** 收藏重命名对话框：遮罩 + 输入卡。 */
  @Builder
  favEditOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.55)')
      .onClick(() => {
        this.favEditOpen = false;
      })

    Column({ space: 12 }) {
      Text('重命名收藏')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.t().textPrimary)
        .width('100%')
      TextInput({ text: this.favEditText, placeholder: '收藏名称' })
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(this.t().termText)
        .placeholderColor(this.t().textTertiary)
        .backgroundColor(this.t().termBg)
        .borderRadius(10)
        .onChange((v: string) => {
          this.favEditText = v;
        })
      Text(this.favEditUrl)
        .fontSize(10)
        .fontFamily('monospace')
        .fontColor(this.t().textTertiary)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.t().navActiveBg)
          .fontColor(this.t().accent)
          .onClick(() => {
            this.favEditOpen = false;
          })
        Button('保存')
          .layoutWeight(1)
          .backgroundColor(this.t().accent)
          .fontColor(this.t().onAccent)
          .onClick(() => {
            this.saveFavEdit();
          })
      }
      .width('100%')
    }
    .width('82%')
    .constraintSize({ maxWidth: 420 })
    .padding(18)
    .borderRadius(20)
    .backgroundColor(this.t().bgCard)
    .border({ width: 1, color: this.t().border })
  }

  /** 收藏抽屉：上透明遮罩（点击关闭）+ 底部面板。 */
  @Builder
  favOverlay() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.favOpen = false;
        })
      this.favSheet()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.45)')
  }

  @Builder
  favSheet() {
    Column() {
      Row({ space: 8 }) {
        Text('★ 精品收藏')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.t().textPrimary)
          .layoutWeight(1)
        Text(this.favItems.length + ' 篇')
          .fontSize(11)
          .fontColor(this.t().textTertiary)
        Text('✕')
          .fontSize(14)
          .fontColor(this.t().textSecondary)
          .padding(6)
          .onClick(() => {
            this.favOpen = false;
          })
      }
      .width('100%')
      .padding({ bottom: 10 })

      if (this.favItems.length === 0) {
        Column({ space: 6 }) {
          Text('☆')
            .fontSize(30)
            .fontColor(this.t().textTertiary)
          Text('还没有收藏：打开报告后点 ☆ 保存，下次一键直达')
            .fontSize(12)
            .fontColor(this.t().textSecondary)
        }
        .width('100%')
        .margin({ top: 26, bottom: 26 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.favItems, (item: ReportFavItem) => {
              Row({ space: 10 }) {
                Text('📄')
                  .fontSize(15)
                Column({ space: 2 }) {
                  Text(item.title !== '' ? item.title : item.url)
                    .fontSize(13.5)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.t().textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.shortUrl(item.url))
                    .fontSize(10)
                    .fontFamily('monospace')
                    .fontColor(this.t().textTertiary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick(() => {
                  this.favOpen = false;
                  this.navigate(item.url);
                })
                Text('✏️')
                  .fontSize(12)
                  .fontColor(this.t().textSecondary)
                  .padding({ left: 6, right: 2, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.openFavEdit(item);
                  })
                Text('🗑')
                  .fontSize(13)
                  .fontColor(this.t().textSecondary)
                  .padding({ left: 4, right: 4, top: 8, bottom: 8 })
                  .onClick(() => {
                    this.removeFav(item);
                  })
              }
              .width('100%')
              .padding(10)
              .borderRadius(12)
              .backgroundColor(Color.Transparent)
              .border({ width: 1, color: this.t().border })
              .margin({ bottom: 8 })
            }, (item: ReportFavItem) => item.url)
          }
          .width('100%')
        }
        .width('100%')
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.t().bgCard)
    .borderRadius({ topLeft: 20, topRight: 20 })
    .border({ width: { top: 0.5 }, color: this.t().border })
    .constraintSize({ maxHeight: '62%' })
  }
}
