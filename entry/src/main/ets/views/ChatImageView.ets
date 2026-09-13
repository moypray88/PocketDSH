/** 聊天内图片组件：Markdown 图片块与消息附件图的异步加载渲染（占位/失败重试/点按全屏）。 */
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { DshImageCache, DshImageCacheError } from '../service/DshImageCache';
import { ThemeColors, ThemeManager } from '../theme/Theme';

/** 加载状态。 */
enum ImgState {
  Loading = 0,
  Ok = 1,
  Failed = 2,
}

/** 图片块共通渲染：状态机 + 失败重试 + 点按回调（全屏预览由宿主页实现）。 */
@Component
export struct MdImageView {
  @Prop @Watch('onSrcChanged') src: string = '';
  @Prop dark: boolean = true;
  @State state: number = ImgState.Loading;
  @State displaySrc: string = '';
  /** 点按已加载图片：参数为可渲染源（https URL 或 file:// URI）。 */
  onOpen: (displaySrc: string) => void = (_s: string) => {
  };
  private loadSeq: number = 0;

  private t(): ThemeColors {
    return this.dark ? ThemeManager.DARK : ThemeManager.LIGHT;
  }

  aboutToAppear(): void {
    this.load();
  }

  private onSrcChanged(): void {
    this.load();
  }

  private load(): void {
    this.loadSeq++;
    const seq: number = this.loadSeq;
    this.state = ImgState.Loading;
    this.displaySrc = '';
    const ctx: common.Context = getContext(this);
    DshImageCache.resolve(ctx, this.src).then((display: string) => {
      if (seq !== this.loadSeq) {
        return;
      }
      this.displaySrc = display;
      this.state = ImgState.Ok;
    }).catch((_e: BusinessError) => {
      if (seq !== this.loadSeq) {
        return;
      }
      this.state = ImgState.Failed;
    });
  }

  build() {
    Column() {
      if (this.state === ImgState.Ok) {
        Image(this.displaySrc)
          .objectFit(ImageFit.Contain)
          .constraintSize({ maxWidth: '100%', maxHeight: 340 })
          .borderRadius(10)
          .backgroundColor(this.t().navActiveBg)
          .onClick(() => {
            this.onOpen(this.displaySrc);
          })
      } else if (this.state === ImgState.Failed) {
        Row({ space: 6 }) {
          Text('🖼')
            .fontSize(14)
          Text(this.src)
            .fontSize(11)
            .fontColor(this.t().textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('重试')
            .fontSize(12)
            .fontColor(this.t().accent)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(10)
        .backgroundColor(this.t().navActiveBg)
        .border({ width: 1, color: this.t().border })
        .onClick(() => {
          this.load();
        })
      } else {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(this.t().accent)
          Text('加载图片…')
            .fontSize(11)
            .fontColor(this.t().textTertiary)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 14, bottom: 14 })
        .borderRadius(10)
        .backgroundColor(this.t().navActiveBg)
        .border({ width: 1, color: this.t().border })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
  }
}

/** 消息内附件图片（image 内容块）：按 sessionId+attachmentId 经 session/attachment 取图。 */
@Component
export struct AttachmentImageView {
  @Prop sessionId: string = '';
  @Prop @Watch('onKeyChanged') attachmentId: string = '';
  @Prop dark: boolean = true;
  @State state: number = ImgState.Loading;
  @State displaySrc: string = '';
  /** 点按已加载图片：参数为可渲染源（file:// URI）。 */
  onOpen: (displaySrc: string) => void = (_s: string) => {
  };
  private loadSeq: number = 0;

  private t(): ThemeColors {
    return this.dark ? ThemeManager.DARK : ThemeManager.LIGHT;
  }

  aboutToAppear(): void {
    this.load();
  }

  private onKeyChanged(): void {
    this.load();
  }

  private load(): void {
    this.loadSeq++;
    const seq: number = this.loadSeq;
    this.state = ImgState.Loading;
    this.displaySrc = '';
    const ctx: common.Context = getContext(this);
    DshImageCache.resolveAttachment(ctx, this.sessionId, this.attachmentId).then((display: string) => {
      if (seq !== this.loadSeq) {
        return;
      }
      this.displaySrc = display;
      this.state = ImgState.Ok;
    }).catch((_e: BusinessError) => {
      if (seq !== this.loadSeq) {
        return;
      }
      this.state = ImgState.Failed;
    });
  }

  build() {
    Column() {
      if (this.state === ImgState.Ok) {
        Image(this.displaySrc)
          .objectFit(ImageFit.Contain)
          .constraintSize({ maxWidth: '100%', maxHeight: 340 })
          .borderRadius(10)
          .backgroundColor(this.t().navActiveBg)
          .onClick(() => {
            this.onOpen(this.displaySrc);
          })
      } else if (this.state === ImgState.Failed) {
        Row({ space: 6 }) {
          Text('🖼')
            .fontSize(14)
          Text('图片加载失败')
            .fontSize(11)
            .fontColor(this.t().textTertiary)
            .layoutWeight(1)
          Text('重试')
            .fontSize(12)
            .fontColor(this.t().accent)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .borderRadius(10)
        .backgroundColor(this.t().navActiveBg)
        .border({ width: 1, color: this.t().border })
        .onClick(() => {
          this.load();
        })
      } else {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(this.t().accent)
          Text('加载图片…')
            .fontSize(11)
            .fontColor(this.t().textTertiary)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 14, bottom: 14 })
        .borderRadius(10)
        .backgroundColor(this.t().navActiveBg)
        .border({ width: 1, color: this.t().border })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
  }
}
