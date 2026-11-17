import { router, window } from '@kit.ArkUI';
import { PreviewView } from '../components/PreviewView';
import { theme, Palette, SCREEN_MARGIN, T_SECONDARY } from '../common/Tokens';
import { formatBytes, formatDate } from '../common/Format';

const SPACE_GAP: number = 8;

export interface PreviewParams {
  ids: string[];
  names: string[];
  mimes: string[];
  sizes: number[];
  mods: number[];
  index: number;
}

interface PreviewItem {
  id: string;
  name: string;
  mime: string;
  size: number;
  modified: number;
}

/** Lazy data source: only the visible page (±1) is instantiated. */
class MediaSource implements IDataSource {
  private items: PreviewItem[] = [];
  private listeners: DataChangeListener[] = [];

  reset(items: PreviewItem[]): void {
    this.items = items;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PreviewItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}

@Entry
@Component
struct Preview {
  @State names: string[] = [];
  @State mimes: string[] = [];
  @State rotateAngle: number = 0;
  @State sizes: number[] = [];
  @State mods: number[] = [];
  @State index: number = 0;
  @State total: number = 0;
  @State immersive: boolean = false;
  @StorageLink('sfDark') dark: boolean = false;
  private source: MediaSource = new MediaSource();
  private controller: SwiperController = new SwiperController();
  private win: window.Window | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  aboutToAppear(): void {
    const params = router.getParams() as PreviewParams;
    if (params === undefined || params.ids === undefined) {
      return;
    }
    const items: PreviewItem[] = [];
    for (let i = 0; i < params.ids.length; i++) {
      items.push({
        id: params.ids[i],
        name: params.names[i],
        mime: params.mimes[i],
        size: params.sizes[i],
        modified: params.mods[i]
      });
    }
    this.source.reset(items);
    this.names = params.names;
    this.mimes = params.mimes;
    this.sizes = params.sizes;
    this.mods = params.mods;
    this.total = items.length;
    this.index = Math.max(0, Math.min(params.index, items.length - 1));
    // 预览期间保持常亮（视频播放不再中途熄屏）
    window.getLastWindow(this.getUIContext().getHostContext()).then((w: window.Window) => {
      this.win = w;
      w.setWindowKeepScreenOn(true).catch(() => {
        // best effort
      });
    }).catch(() => {
      // ignore
    });
  }

  aboutToDisappear(): void {
    if (this.win !== null) {
      this.win.setWindowKeepScreenOn(false).catch(() => {
        // ignore
      });
      if (this.immersive) {
        this.setImmersive(false);
      }
    }
  }

  /** 全屏：隐藏系统状态栏/导航栏并锁定横屏；退出恢复。 */
  private setImmersive(on: boolean): void {
    this.immersive = on;
    if (this.win === null) {
      return;
    }
    if (on) {
      this.win.setPreferredOrientation(window.Orientation.LANDSCAPE).catch(() => {
        // ignore
      });
      this.win.setWindowSystemBarEnable([]).catch(() => {
        // ignore
      });
    } else {
      this.win.setPreferredOrientation(window.Orientation.AUTO_ROTATION).catch(() => {
        // ignore
      });
      this.win.setWindowSystemBarEnable(['status', 'navigation']).catch(() => {
        // ignore
      });
    }
  }

  private isImageNow(): boolean {
    const m: string = this.index < this.mimes.length ? this.mimes[this.index] : '';
    return m.startsWith('image/');
  }

  private rotateImage(): void {
    this.rotateAngle = (this.rotateAngle + 90) % 360;
  }

  private title(): string {
    return this.index < this.names.length ? this.names[this.index] : '';
  }

  private meta(): string {
    if (this.index >= this.sizes.length) {
      return '';
    }
    const size: string = formatBytes(this.sizes[this.index]);
    const mod: number = this.index < this.mods.length ? this.mods[this.index] : 0;
    return mod > 0 ? `${size} · ${formatDate(mod)}` : size;
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
    Column() {
      if (!this.immersive) {
      Row({ space: 8 }) {
        Button('‹')
          .fontSize(22)
          .width(38)
          .height(38)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => router.back())
        Column({ space: 2 }) {
          Text(this.title())
            .fontSize(15)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .fontColor(this.th().onSurface)
          Row({ space: SPACE_GAP }) {
            Text(this.meta())
              .fontSize(T_SECONDARY)
              .fontColor(this.th().onSurfaceVariant)
            if (this.total > 1) {
              Text(`${this.index + 1}/${this.total}`)
                .fontSize(T_SECONDARY)
                .fontColor(this.th().onSurfaceVariant)
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.isImageNow()) {
          Button('⟳')
            .fontSize(18)
            .width(38)
            .height(38)
            .backgroundColor(this.th().searchFieldBg)
            .fontColor(this.th().onSurface)
            .onClick(() => this.rotateImage())
        }
        Button('⛶')
          .fontSize(16)
          .width(38)
          .height(38)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => this.setImmersive(true))
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })
      }

      Swiper(this.controller) {
        LazyForEach(this.source, (it: PreviewItem) => {
          PreviewView({
            previewId: it.id,
            previewName: it.name,
            previewMime: it.mime,
            previewSize: it.size,
            previewModified: it.modified,
            angle: this.rotateAngle
          })
        }, (it: PreviewItem) => it.id)
      }
      .index(this.index)
      .loop(false)
      .cachedCount(1)
      .indicator(this.total > 1)
      .onChange((i: number) => {
        this.index = i;
        this.rotateAngle = 0;
      })
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)

    if (this.immersive) {
      Column({ space: 8 }) {
        if (this.isImageNow()) {
          Button('⟳')
            .fontSize(18)
            .width(40)
            .height(40)
            .backgroundColor('#66000000')
            .fontColor(Color.White)
            .onClick(() => this.rotateImage())
        }
        Button('⛶')
          .fontSize(16)
          .width(40)
          .height(40)
          .backgroundColor('#66000000')
          .fontColor(Color.White)
          .onClick(() => this.setImmersive(false))
      }
      .margin({ top: 8, right: 8 })
    }
    }
    .width('100%')
    .height('100%')
  }
}
