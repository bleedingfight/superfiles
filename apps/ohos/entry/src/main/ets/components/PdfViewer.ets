import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { pdfService } from '@kit.PDFKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { ensureMountedForId } from '../common/MountOps';
import { errText } from '../common/Format';
import { t } from '../common/L10n';
import { theme, Palette, SPACE2, SPACE3, SPACE4, T_BODY, T_SECONDARY } from '../common/Tokens';

/**
 * PDF 应用内预览（@kit.PDFKit，纯离线）。
 *
 * 文件先经内核 readBytes 落地缓存（网络后端同样是这段逻辑），
 * PdfDocument 加载后按「可视窗口 ±2 页」渲染 PixelMap，窗口外的页
 * 及时 release —— 每页 1400px 宽 RGBA 约 10MB，不做窗口控制大文档
 * 直接 OOM。捏合缩放 + 双击复位。
 */

const BMP_WIDTH: number = 1400;
const WIN_RADIUS: number = 2;
const MAX_BYTES: number = 200 * 1024 * 1024;
const CHUNK: number = 2 * 1024 * 1024;

@Component
export struct PdfViewer {
  @Prop docId: string;
  @Prop docName: string;
  @Prop docSize: number;
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @State phase: number = 0; // 0 取文件中 1 解析中 2 就绪 3 失败
  @State progress: number = 0;
  @State error: string = '';
  @State pageCount: number = 0;
  @State dims: number[] = [];      // [wPt0, hPt0, wPt1, hPt1, ...]
  @State bitmaps: Array<image.PixelMap | undefined> = [];
  @State winFrom: number = 0;
  @State winTo: number = -1;
  @State zoom: number = 1;
  private core: SuperFiles | null = null;
  private filesDir: string = '';
  private doc: pdfService.PdfDocument | null = null;
  private rendering: Set<number> = new Set<number>();
  private widthVp: number = 400;
  private pinchBase: number = 1;
  private scrollTag: number = 0;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.filesDir = ctx.cacheDir;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.fail(errText(e));
      return;
    }
    try {
      const d = display.getDefaultDisplaySync();
      this.widthVp = d.width / d.densityPixels;
    } catch (e) {
      this.widthVp = 400;
    }
    this.load();
  }

  aboutToDisappear(): void {
    this.releaseAll();
  }

  private fail(msg: string): void {
    this.error = msg;
    this.phase = 3;
  }

  private tick(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 0);
    });
  }

  private cachePath(): string {
    let h: number = 5381;
    for (let i = 0; i < this.docId.length; i++) {
      h = (h * 33 + this.docId.charCodeAt(i)) | 0;
    }
    return `${this.filesDir}/pdf_${h}_${this.docSize}.pdf`;
  }

  /** 内核字节 → 缓存文件（已缓存且大小一致则复用）。 */
  private async materialize(): Promise<string> {
    const path: string = this.cachePath();
    if (this.filesDir.length === 0 || this.core === null) {
      throw new Error('no core');
    }
    try {
      if (fileIo.accessSync(path)) {
        const st = fileIo.statSync(path);
        if (Number(st.size) === this.docSize) {
          return path;
        }
      }
    } catch (e) {
      // re-download
    }
    const total: number = this.docSize;
    let off: number = 0;
    const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      while (off < total) {
        const want: number = Math.min(CHUNK, total - off);
        const chunk: Uint8Array = this.core.readBytes(this.docId, BigInt(off), want);
        if (chunk.length === 0) {
          break;
        }
        fileIo.writeSync(f.fd, chunk.buffer as ArrayBuffer);
        off += chunk.length;
        this.progress = Math.min(99, Math.round(off * 100 / total));
        await this.tick();
      }
    } finally {
      fileIo.closeSync(f);
    }
    if (off < total) {
      throw new Error('incomplete');
    }
    return path;
  }

  private async load(): Promise<void> {
    if (this.docSize <= 0 || this.docSize > MAX_BYTES) {
      this.fail(this.tt('pv.pdfTooLarge'));
      return;
    }
    this.phase = 0;
    try {
      const ctx0 = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!ensureMountedForId(ctx0, this.core as SuperFiles, this.docId)) {
        this.fail(this.tt('pv.backendOffline'));
        return;
      }
      const path: string = await this.materialize();
      this.phase = 1;
      await this.tick();
      const doc: pdfService.PdfDocument = new pdfService.PdfDocument();
      const r: pdfService.ParseResult = doc.loadDocument(path, '', (p: number): number => {
        this.progress = p;
        return 1;
      });
      if (r !== pdfService.ParseResult.PARSE_SUCCESS) {
        doc.releaseDocument();
        throw new Error('parse ' + r);
      }
      this.doc = doc;
      const n: number = doc.getPageCount();
      const dims: number[] = [];
      for (let i = 0; i < n; i++) {
        const page: pdfService.PdfPage = doc.getPage(i);
        dims.push(page.getWidth());
        dims.push(page.getHeight());
      }
      this.pageCount = n;
      this.dims = dims;
      const bitmaps: Array<image.PixelMap | undefined> = [];
      for (let i = 0; i < n; i++) {
        bitmaps.push(undefined);
      }
      this.bitmaps = bitmaps;
      this.phase = 2;
      hilog.info(0x0000, 'SuperFiles', 'PDF loaded pages=%{public}d firstW=%{public}d', n, dims.length > 0 ? dims[0] : 0);
      await this.ensureWindow(0);
    } catch (e) {
      this.fail(this.tt('pv.pdfError') + '：' + errText(e));
    }
  }

  private renderOne(i: number): void {
    if (this.doc === null) {
      return;
    }
    try {
      const page: pdfService.PdfPage = this.doc.getPage(i);
      const pm: image.PixelMap = page.getPagePixelMap();
      this.bitmaps[i] = pm;
      hilog.info(0x0000, 'SuperFiles', 'PDF page %{public}d rendered', i);
    } catch (e) {
      hilog.error(0x0000, 'SuperFiles', 'PDF page %{public}d render fail: %{public}s', i, errText(e));
    }
  }

  /** 渲染可视页 ±WIN_RADIUS，释放窗口外 ±2 页之外的 PixelMap。 */
  private async ensureWindow(center: number): Promise<void> {
    if (this.pageCount <= 0) {
      return;
    }
    const tag: number = ++this.scrollTag;
    const from: number = Math.max(0, center - WIN_RADIUS);
    const to: number = Math.min(this.pageCount - 1, center + WIN_RADIUS);
    if (from === this.winFrom && to === this.winTo) {
      return;
    }
    this.winFrom = from;
    this.winTo = to;
    // 释放远窗页
    for (let i = 0; i < this.pageCount; i++) {
      if (i < from - WIN_RADIUS - 2 || i > to + WIN_RADIUS + 2) {
        const old: image.PixelMap | undefined = this.bitmaps[i];
        if (old !== undefined) {
          try {
            old.release();
          } catch (e) {
            // ignore
          }
          this.bitmaps[i] = undefined;
        }
      }
    }
    this.bitmaps = this.bitmaps.slice();
    // 渲染窗口内缺失页（逐页让出主线程）
    for (let i = from; i <= to; i++) {
      if (this.bitmaps[i] !== undefined || this.rendering.has(i)) {
        continue;
      }
      this.rendering.add(i);
      await this.tick();
      if (tag !== this.scrollTag) {
        this.rendering.delete(i);
        return; // 滚动目标已变，交给新一轮
      }
      this.renderOne(i);
      this.rendering.delete(i);
      this.bitmaps = this.bitmaps.slice();
    }
  }

  private releaseAll(): void {
    for (let i = 0; i < this.bitmaps.length; i++) {
      const pm: image.PixelMap | undefined = this.bitmaps[i];
      if (pm !== undefined) {
        try {
          pm.release();
        } catch (e) {
          // ignore
        }
        this.bitmaps[i] = undefined;
      }
    }
    if (this.doc !== null) {
      try {
        this.doc.releaseDocument();
      } catch (e) {
        // ignore
      }
      this.doc = null;
    }
  }

  /** 每页显示高度 vp（按容器宽度等比）。 */
  private pageHeightVp(i: number): number {
    const wPt: number = this.dims[i * 2];
    const hPt: number = this.dims[i * 2 + 1];
    const contentW: number = this.widthVp - SPACE4 * 2;
    return contentW * hPt / wPt;
  }

  private onScrollY(offset: number): void {
    let acc: number = 0;
    let center: number = 0;
    for (let i = 0; i < this.pageCount; i++) {
      acc += this.pageHeightVp(i) + SPACE3;
      if (offset < acc) {
        center = i;
        break;
      }
      center = i;
    }
    this.ensureWindow(center);
  }

  @Builder
  pageBox(i: number) {
    Column({ space: SPACE2 }) {
      if (this.bitmaps[i] !== undefined) {
        Image(this.bitmaps[i])
          .width('100%')
          .draggable(false)
      } else {
        Column({ space: SPACE2 }) {
          LoadingProgress().width(28).height(28).color(this.th().primary)
          Text(this.tt('pv.pdfPage', `${i + 1}`))
            .fontSize(T_SECONDARY)
            .fontColor(this.th().onSurfaceVariant)
        }
        .width('100%')
        .height(this.pageHeightVp(i))
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .shadow({ radius: 3, color: '#14000000' })
  }

  build() {
    Stack() {
      if (this.phase === 3) {
        Column({ space: SPACE2 }) {
          Text(this.error).fontSize(T_BODY).fontColor(this.th().error)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.phase === 2) {
        Scroll() {
          Column({ space: SPACE3 }) {
            ForEach(this.rangeArr(), (i: number) => {
              this.pageBox(i)
            }, (i: number) => `p${i}`)
          }
          .width('100%')
          .padding(SPACE4)
          .scale({ x: this.zoom, y: this.zoom })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .onScroll((xOff: number, yOff: number) => {
          this.onScrollY(yOff / this.zoom);
        })
        .parallelGesture(
          PinchGesture()
            .onActionStart(() => {
              this.pinchBase = this.zoom;
            })
            .onActionUpdate((e: GestureEvent) => {
              const z: number = this.pinchBase * e.scale;
              this.zoom = Math.min(4, Math.max(1, z));
            })
        )
        .gesture(
          TapGesture({ count: 2 })
            .onAction(() => {
              animateTo({ duration: 160 }, () => {
                this.zoom = this.zoom > 1.2 ? 1 : 2;
              });
            })
        )
        Text(`${this.tt('pv.pdfPages', `${this.pageCount}`)}`)
          .fontSize(11)
          .fontColor(this.th().onSurfaceVariant)
          .backgroundColor(this.th().searchFieldBg)
          .borderRadius(10)
          .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          .margin({ bottom: 12 })
      } else {
        Column({ space: SPACE2 }) {
          LoadingProgress().width(36).height(36).color(this.th().primary)
          Text(this.phase === 0 ? this.tt('pv.pdfFetching') : this.tt('pv.pdfParsing'))
            .fontSize(T_BODY)
            .fontColor(this.th().onSurfaceVariant)
          if (this.progress > 0 && this.progress < 100) {
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
              .width(180)
              .height(4)
            Text(`${this.progress}%`)
              .fontSize(T_SECONDARY)
              .fontColor(this.th().outline)
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Bottom)
    .backgroundColor(this.dark ? '#000000' : '#f5f5f5')
  }

  /** ForEach 需要数组数据源：生成 [0, pageCount)。 */
  private rangeArr(): number[] {
    const arr: number[] = [];
    for (let i = 0; i < this.pageCount; i++) {
      arr.push(i);
    }
    return arr;
  }
}
