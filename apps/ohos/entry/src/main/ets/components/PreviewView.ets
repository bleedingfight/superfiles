import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { PdfViewer } from './PdfViewer';
import { openEntryExternal } from '../common/OpenExternal';
import { ensureMountedForId } from '../common/MountOps';
import { formatBytes, formatDate, errText } from '../common/Format';
import { t } from '../common/L10n';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import {
  theme, Palette, RADIUS_S, RADIUS_M, SPACE1, SPACE2, SPACE3, SPACE4, T_BODY, T_EMPTY_BODY, T_EMPTY_TITLE, T_SECONDARY
} from '../common/Tokens';

export const KIND_IMAGE: number = 0;
export const KIND_VIDEO: number = 1;
export const KIND_TEXT: number = 2;
export const KIND_OTHER: number = 3;
export const KIND_PDF: number = 4;
export const KIND_AUDIO: number = 5;

export function kindOf(name: string, mime: string): number {
  const lower: string = name.toLowerCase();
  const m: string = mime.toLowerCase();
  if (m.startsWith('image/') || /\.(jpg|jpeg|png|gif|webp|bmp|heic|heif)$/.test(lower)) {
    return KIND_IMAGE;
  }
  if (m.startsWith('video/') || /\.(mp4|mkv|mov|webm|m4v)$/.test(lower)) {
    return KIND_VIDEO;
  }
  if (m.startsWith('text/') || /\.(txt|md|json|log|xml|yaml|yml|csv|ini|conf|rs|kt|ets|ts|js|py|sh|toml)$/.test(lower)) {
    return KIND_TEXT;
  }
  if (m === 'application/pdf' || /\.pdf$/.test(lower)) {
    return KIND_PDF;
  }
  if (m.startsWith('audio/') || /\.(mp3|flac|wav|aac|m4a|ogg|opus|amr|ape|wv|aiff|aif|au|mid|midi)$/i.test(lower)) {
    return KIND_AUDIO;
  }
  return KIND_OTHER;
}

/** 画廊口径：「有内置预览渲染」的媒体（图片/视频/音频）。PDF 走单页画廊，不串台。 */
export function isMediaName(name: string, mime: string = ''): boolean {
  const k: number = kindOf(name, mime);
  return k === KIND_IMAGE || k === KIND_VIDEO || k === KIND_AUDIO;
}

/**
 * Inline preview of a file (image / video / text). Shared by the full-screen
 * Preview page and the tablet dual-pane layout.
 */
@Component
export struct PreviewView {
  @Prop previewId: string;
  @Prop previewName: string;
  @Prop previewMime: string;
  @Prop previewSize: number;
  @Prop previewModified: number;
  @Prop angle: number = 0;
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @State source: string = '';
  @State text: string = '';
  @State kind: number = KIND_OTHER;
  @State error: string = '';
  @State loading: boolean = true;
  @State pixmap: image.PixelMap | undefined = undefined;
  @State imgProgress: number = 0;
  @State imgStage: string = '';
  @State audioFallback: boolean = false;
  private triedBytes: boolean = false;
  private videoController: VideoController = new VideoController();
  private started: boolean = false;
  private isVisible: boolean = false;
  private preloadTimer: number = -1;
  private filesDirCache: string = '';
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string): string {
    return t(this.sysLang, key);
  }

  aboutToAppear(): void {
    this.kind = kindOf(this.previewName, this.previewMime);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.filesDirCache = ctx.cacheDir;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.error = errText(e);
      this.loading = false;
    }
    // 预取：不可见的相邻页延迟 500ms 再加载，既不和当前页抢资源，
    // 又能在用户滑动前准备好（命中时切换零等待）。
    this.preloadTimer = setTimeout(() => {
      this.startIfVisible();
    }, 500);
  }

  aboutToDisappear(): void {
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
  }

  /** 只在页面真正可见时才开始取流/解码，避免画廊里相邻页抢占 CPU 和内存。 */
  private startIfVisible(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
    this.load();
  }

  private cacheFile(suffix: string): string {
    let h: number = 5381;
    for (let i = 0; i < this.previewId.length; i++) {
      h = (h * 33 + this.previewId.charCodeAt(i)) | 0;
    }
    const name: string = `img_${h}_${this.previewSize}${suffix}`;
    return this.filesDirCache.length > 0 ? `${this.filesDirCache}/${name}` : '';
  }

  private tick(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 0);
    });
  }

  /**
   * 大图路径：先查磁盘缓存 → 命中直接解码；否则分块读取（带进度）
   * 并落盘，再按最长边 1600 降采样解码。
   */
  private async loadImageBytes(): Promise<void> {
    if (this.core === null || this.triedBytes) {
      this.error = this.tt('pv.imageError');
      return;
    }
    this.triedBytes = true;
    const total: number = this.previewSize;
    if (total <= 0 || total > 64 * 1024 * 1024) {
      this.error = this.tt('pv.imageError');
      return;
    }
    const cache: string = this.cacheFile('.bin');
    const thumb: string = this.cacheFile('.thumb');

    // 1) 先把缓存缩略图贴出来（秒开），同时继续走下面的完整流程
    this.showThumbIfAny(thumb);

    // 2) 原始字节已缓存：直接解高清，不再走网络
    if (cache.length > 0) {
      try {
        if (fileIo.accessSync(cache)) {
          const st = fileIo.statSync(cache);
          if (Number(st.size) === total) {
            this.imgStage = this.tt('pv.decoding');
            this.decodeFrom(cache);
            return;
          }
        }
      } catch (e) {
        // ignore and re-download
      }
    }
    // 2) 分块读取（先只入内存，最后一次性落盘，避免每块一次写放大）
    try {
      const t0: number = Date.now();
      const buf: Uint8Array = new Uint8Array(total);
      const chunkSize: number = 2 * 1024 * 1024;
      let off: number = 0;
      this.imgStage = '';
      while (off < total) {
        const want: number = Math.min(chunkSize, total - off);
        const chunk: Uint8Array = this.core.readBytes(this.previewId, BigInt(off), want);
        if (chunk.length === 0) {
          break;
        }
        buf.set(chunk, off);
        off += chunk.length;
        this.imgProgress = Math.min(99, Math.round(off * 100 / total));
        await this.tick();
      }
      const t1: number = Date.now();
      this.imgProgress = 100;

      // 落盘缓存（best effort），命中后二次打开不再走网络
      if (cache.length > 0) {
        try {
          const f = fileIo.openSync(cache, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(f.fd, buf.buffer as ArrayBuffer);
          fileIo.closeSync(f);
        } catch (e) {
          // cache best effort
        }
      }
      const t2: number = Date.now();
      hilog.info(0x0000, 'SuperFiles', 'img timing: read %{public}dms, cache %{public}dms, bytes %{public}d',
        t1 - t0, t2 - t1, off);

      // 有缓存文件时直接从文件解码，省掉一次 41MB 的内存拷贝
      if (cache.length > 0 && fileIo.accessSync(cache)) {
        await this.decodePathQuickThenFull(cache, thumb);
      } else {
        await this.showQuickThenFull(buf.buffer as ArrayBuffer, thumb);
      }
    } catch (e) {
      this.error = this.tt('pv.imageError') + '：' + errText(e);
      this.imgStage = '';
    }
  }

  /** 从缓存文件：480 快速预览 → 1600 高清（省内存拷贝）。 */
  private async decodePathQuickThenFull(path: string, thumbPath: string): Promise<void> {
    try {
      const t0: number = Date.now();
      const src: image.ImageSource = image.createImageSource(path);
      const info: image.ImageInfo = await src.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;

      this.imgStage = this.tt('pv.quickPreview');
      const small: image.Size = this.scaleTo(w, h, 480);
      const pmSmall: image.PixelMap = await src.createPixelMap({ desiredSize: small });
      this.pixmap = pmSmall;
      const t1: number = Date.now();
      this.packThumb(pmSmall, thumbPath);
      await this.tick();

      this.imgStage = this.tt('pv.decoding');
      const big: image.Size = this.scaleTo(w, h, 1600);
      const pmBig: image.PixelMap = await src.createPixelMap({ desiredSize: big });
      this.pixmap = pmBig;
      this.error = '';
      this.imgStage = '';
      hilog.info(0x0000, 'SuperFiles', 'img timing: quick480 %{public}dms, full1600 %{public}dms (%{public}dx%{public}d)',
        t1 - t0, Date.now() - t1, big.width, big.height);
    } catch (e) {
      this.error = this.tt('pv.imageError') + '：' + errText(e);
      this.imgStage = '';
    }
  }

  /** 缓存缩略图秒开。 */
  private showThumbIfAny(thumbPath: string): void {
    if (thumbPath.length === 0) {
      return;
    }
    try {
      if (!fileIo.accessSync(thumbPath)) {
        return;
      }
      const src: image.ImageSource = image.createImageSource(thumbPath);
      src.createPixelMap().then((pm: image.PixelMap) => {
        if (this.pixmap === undefined) {
          this.pixmap = pm;
        }
      }).catch(() => {
        // ignore thumb failure
      });
    } catch (e) {
      // ignore
    }
  }

  private scaleTo(w0: number, h0: number, maxSide: number): image.Size {
    const longSide: number = Math.max(w0, h0);
    if (longSide <= maxSide) {
      return { width: w0, height: h0 };
    }
    const k: number = longSide / maxSide;
    return {
      width: Math.max(1, Math.floor(w0 / k)),
      height: Math.max(1, Math.floor(h0 / k))
    };
  }

  /** 先解 480 预览秒出图 → 打包成缩略图缓存 → 再解 1600 高清替换。 */
  private async showQuickThenFull(buf: ArrayBuffer, thumbPath: string): Promise<void> {
    try {
      const src: image.ImageSource = image.createImageSource(buf);
      const info: image.ImageInfo = await src.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;

      this.imgStage = this.tt('pv.quickPreview');
      const small: image.Size = this.scaleTo(w, h, 480);
      const pmSmall: image.PixelMap = await src.createPixelMap({ desiredSize: small });
      this.pixmap = pmSmall;
      this.imgProgress = 100;
      this.packThumb(pmSmall, thumbPath);
      await this.tick();

      this.imgStage = this.tt('pv.decoding');
      const big: image.Size = this.scaleTo(w, h, 1600);
      hilog.info(0x0000, 'SuperFiles', 'image decode %{public}dx%{public}d -> %{public}dx%{public}d', w, h, big.width, big.height);
      const pmBig: image.PixelMap = await src.createPixelMap({ desiredSize: big });
      this.pixmap = pmBig;
      this.error = '';
      this.imgStage = '';
    } catch (e) {
      if (this.pixmap === undefined) {
        this.error = this.tt('pv.imageError') + '：' + errText(e);
      }
      this.imgStage = '';
    }
  }

  private packThumb(pm: image.PixelMap, path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      const packer: image.ImagePacker = image.createImagePacker();
      packer.packing(pm, { format: 'image/jpeg', quality: 70 }).then((data: ArrayBuffer) => {
        try {
          const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(f.fd, data);
          fileIo.closeSync(f);
        } catch (e) {
          // cache best effort
        }
      }).catch(() => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  private decodeFrom(path: string): void {
    try {
      const source: image.ImageSource = image.createImageSource(path);
      this.decodeSource(source);
    } catch (e) {
      this.error = this.tt('pv.imageError') + '：' + errText(e);
      this.imgStage = '';
    }
  }

  private decodeSource(source: image.ImageSource): void {
    source.getImageInfo().then((info: image.ImageInfo) => {
      const w: number = info.size.width;
      const h: number = info.size.height;
      let dw: number = w;
      let dh: number = h;
      const maxSide: number = 1600;
      const longSide: number = Math.max(w, h);
      if (longSide > maxSide) {
        const scale: number = longSide / maxSide;
        dw = Math.max(1, Math.floor(w / scale));
        dh = Math.max(1, Math.floor(h / scale));
      }
      hilog.info(0x0000, 'SuperFiles', 'image decode %{public}dx%{public}d -> %{public}dx%{public}d', w, h, dw, dh);
      return source.createPixelMap({ desiredSize: { width: dw, height: dh } });
    }).then((pm: image.PixelMap) => {
      this.pixmap = pm;
      this.error = '';
      this.imgStage = '';
      this.imgProgress = 0;
    }).catch(() => {
      this.error = this.tt('pv.imageError');
      this.imgStage = '';
    });
  }

  private load(): void {
    if (this.core === null) {
      this.loading = false;
      return;
    }
    // 索引/搜索来源的条目可能属于未连接的挂载：先补连，否则流式 404
    const ctx0 = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!ensureMountedForId(ctx0, this.core, this.previewId)) {
      this.error = this.tt('pv.backendOffline');
      this.loading = false;
      return;
    }
    try {
      // 沙箱内文件直接走 file://；远端后端由内核起回环 HTTP 流（支持 Range）
      let url: string = '';
      try {
        url = this.core.streamUrl(this.previewId);
      } catch (e) {
        url = '';
      }
      if (url.length === 0 || url.startsWith('/')) {
        const path: string = this.core.displayPath(this.previewId);
        url = path.startsWith('/') ? `file://${path}` : path;
      }
      this.source = url;
      hilog.info(0x0000, 'SuperFiles', 'preview source=%{public}s', url);

      if (this.kind === KIND_TEXT) {
        const bytes: Uint8Array = this.core.readBytes(this.previewId, BigInt(0), 256 * 1024);
        const decoder = util.TextDecoder.create('utf-8');
        this.text = decoder.decodeToString(bytes);
      }
    } catch (e) {
      this.error = this.tt('pv.openFailed') + '：' + errText(e);
    }
    this.loading = false;
    // 当前可见才自动播；预取的相邻页保持暂停（避免两个视频同时出声）
    if ((this.kind === KIND_VIDEO || this.kind === KIND_AUDIO) && this.isVisible) {
      this.videoController.start();
    }
  }

  @Builder
  pane() {
    if (this.loading) {
      Column() {
        LoadingProgress().width(36).height(36).color(this.th().primary)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    } else if (this.error.length > 0) {
      Column({ space: SPACE2 }) {
        Text(this.error).fontSize(T_BODY).fontColor(this.th().error)
        Text(this.tt('pv.noPreview')).fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    } else if (this.kind === KIND_IMAGE) {
      Stack() {
        Image(this.pixmap !== undefined ? this.pixmap : this.source)
          .objectFit(ImageFit.Contain)
          .sourceSize({ width: 1600, height: 1600 })
          .width('100%')
          .height('100%')
          .rotate({ x: 0, y: 0, z: 1, angle: this.angle })
          .onError(() => {
            hilog.error(0x0000, 'SuperFiles', 'image url failed, fallback to bytes, src=%{public}s', this.source);
            this.loadImageBytes();
          })
        if (this.imgStage.length > 0 || (this.imgProgress > 0 && this.imgProgress < 100)) {
          Column({ space: SPACE2 }) {
            LoadingProgress().width(32).height(32).color(this.th().primary)
            Text(this.imgStage.length > 0 ? this.imgStage : `${this.imgProgress}%`)
              .fontSize(T_SECONDARY)
              .fontColor(this.th().onSurfaceVariant)
            if (this.imgProgress > 0 && this.imgProgress < 100) {
              Progress({ value: this.imgProgress, total: 100, type: ProgressType.Linear })
                .width(160)
                .height(4)
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
      }
      .layoutWeight(1)
      .width('100%')
    } else if (this.kind === KIND_VIDEO) {
      Column({ space: SPACE1 }) {
        Video({ src: this.source, controller: this.videoController })
          .controls(true)
          .autoPlay(false)
          .width('100%')
          .layoutWeight(1)
          .onError(() => {
            hilog.error(0x0000, 'SuperFiles', 'video playback error, src=%{public}s', this.source);
            this.error = this.tt('pv.videoError');
          })
          .onPrepared(() => {
            this.error = '';
            hilog.info(0x0000, 'SuperFiles', 'video prepared, src=%{public}s', this.source);
            // 播放器就绪后按可见性自动开播（切换页时不抢前台声音）
            if (this.isVisible) {
              this.videoController.start();
            }
          })
        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(12)
            .fontColor(this.th().error)
            .width('100%')
            .padding({ left: SPACE4, right: SPACE4, bottom: SPACE3 })
        }
      }
      .layoutWeight(1)
      .width('100%')
    } else if (this.kind === KIND_TEXT) {
      Scroll() {
        Text(this.text)
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor(this.th().onSurface)
          .width('100%')
          .padding(SPACE3)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
    } else if (this.kind === KIND_PDF) {
      PdfViewer({
        docId: this.previewId,
        docName: this.previewName,
        docSize: this.previewSize
      })
        .layoutWeight(1)
        .width('100%')
    } else if (this.kind === KIND_AUDIO) {
      Column({ space: SPACE3 }) {
        Column({ space: SPACE2 }) {
          Text('🎵').fontSize(56)
          if (this.audioFallback) {
            Text(this.tt('pv.audioUnsupported'))
              .fontSize(T_BODY)
              .fontColor(this.th().onSurfaceVariant)
              .textAlign(TextAlign.Center)
          }
          Text(this.previewName)
            .fontSize(T_BODY)
            .fontColor(this.th().onSurface)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${formatBytes(this.previewSize)} · ${formatDate(this.previewModified)}`)
            .fontSize(T_SECONDARY)
            .fontColor(this.th().outline)
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: SPACE4, right: SPACE4 })

        if (this.audioFallback) {
          Button(this.tt('pv.openExternal'))
            .fontSize(13)
            .height(38)
            .margin({ bottom: SPACE3 })
            .backgroundColor(this.th().primary)
            .fontColor(this.th().onPrimary)
            .onClick(() => {
              this.openExternalElsewhere();
            })
        } else {
          // 系统解码管线播音频（与视频同链路：远端走回环流，本地 file://）
          Video({ src: this.source, controller: this.videoController })
            .controls(true)
            .autoPlay(false)
            .width('100%')
            .height(200)
            .onError(() => {
              hilog.error(0x0000, 'SuperFiles', 'audio playback error, src=%{public}s', this.source);
              this.audioJumpExternal();
            })
            .onPrepared(() => {
              this.error = '';
              hilog.info(0x0000, 'SuperFiles', 'audio prepared, src=%{public}s', this.source);
              if (this.isVisible) {
                this.videoController.start();
              }
            })
        }
      }
      .layoutWeight(1)
      .width('100%')
    } else {
      Column({ space: SPACE2 }) {
        Text('📄').fontSize(48)
        Text(this.tt('pv.noRenderer')).fontSize(T_BODY).fontColor(this.th().onSurfaceVariant)
        Text(`${formatBytes(this.previewSize)} · ${formatDate(this.previewModified)}`)
          .fontSize(T_SECONDARY)
          .fontColor(this.th().outline)
        Button(this.tt('pv.openExternal'))
          .fontSize(13)
          .height(38)
          .margin({ top: SPACE2 })
          .backgroundColor(this.th().primary)
          .fontColor(this.th().onPrimary)
          .onClick(() => {
            this.openExternalElsewhere();
          })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
  }

  /** 系统解码放不动的音频：自动用系统/第三方应用打开；没人承接再给手动按钮。 */
  private audioJumpExternal(): void {
    if (this.core === null) {
      this.audioFallback = true;
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    openEntryExternal(ctx, this.core, this.previewId, this.previewName, this.previewSize)
      .catch(() => {
        this.audioFallback = true;
      });
  }

  /** 无法预览的格式：落地到缓存后跳第三方应用打开。 */
  private openExternalElsewhere(): void {
    if (this.core === null) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    openEntryExternal(ctx, this.core, this.previewId, this.previewName, this.previewSize)
      .catch((e: Error) => {
        const msg: string = errText(e);
        if (msg.indexOf('size-unsupported') >= 0) {
          this.error = this.tt('pv.pdfTooLarge');
        } else if (msg.indexOf('incomplete') >= 0) {
          this.error = this.tt('pv.openFailed');
        } else {
          // 多半是系统里没有应用承接该类型
          this.error = this.tt('pv.noApp');
        }
      });
  }

  build() {
    Column() {
      this.pane()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
    .onVisibleAreaChange([0.0, 0.1], (isVisible: boolean, ratio: number) => {
      this.isVisible = isVisible;
      if (isVisible) {
        this.startIfVisible();
        // 画廊切到本页才允许出声/播放；不可见页立即静音暂停
        if ((this.kind === KIND_VIDEO || this.kind === KIND_AUDIO) && this.started) {
          this.videoController.start();
        }
      } else if (this.kind === KIND_VIDEO || this.kind === KIND_AUDIO) {
        this.videoController.pause();
      }
    })
  }
}
