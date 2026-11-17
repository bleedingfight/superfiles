import { common } from '@kit.AbilityKit';
import { SuperFiles, TransferSnapshot, TransferState } from '@superfiles/core';
import { getCore } from '../common/Core';
import { theme, Palette, RADIUS_M, RADIUS_S, SPACE2, SPACE3, SPACE4 } from '../common/Tokens';
import { t } from '../common/L10n';
import { formatBytes } from '../common/Format';

/**
 * 前台传输浮层（复制/移动，对齐 Android ForegroundTransferOverlay）：
 * 任务开始后全 App 模态显示实时进度；「终止」取消全部进行中任务，
 * 「后台传输」收起浮层任务继续跑；全部完成后浮层自动消失，下次任务
 * 重新弹出。浮层可见时返回键被 Index 消费，不打断传输。
 */
@Component
export struct TransferOverlay {
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @State visible: boolean = false;
  @State current: string = '';
  @State bytesDone: number = 0;
  @State bytesTotal: number = 0;
  @State filesDone: number = 0;
  @State filesTotal: number = 0;
  @State rate: number = 0;
  private core: SuperFiles | null = null;
  private timer: number = -1;
  private lastBytes: number = 0;
  private lastMs: number = 0;
  private backgrounded: boolean = false;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  aboutToAppear(): void {
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.core = getCore(ctx);
    } catch (e) {
      this.core = null;
    }
    this.timer = setInterval(() => {
      this.tick();
    }, 1000);
    this.tick();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private tick(): void {
    if (this.core === null) {
      return;
    }
    try {
      const snaps: TransferSnapshot[] = this.core.transfers();
      const active: TransferSnapshot[] = snaps.filter((s: TransferSnapshot) =>
        s.state === TransferState.Running || s.state === TransferState.Queued ||
        s.state === TransferState.Paused);
      if (active.length === 0) {
        // 全部结束：浮层消失，复位「后台传输」标记
        this.visible = false;
        this.backgrounded = false;
        this.lastBytes = 0;
        this.lastMs = 0;
        AppStorage.setOrCreate('sfTransferOverlay', false);
        return;
      }
      // 新一批任务开始：重新弹出
      if (!this.visible && this.backgrounded) {
        // 仍处于已收起的同一批任务，不打扰
      } else if (!this.visible) {
        this.backgrounded = false;
      }
      let done: number = 0;
      let total: number = 0;
      let fDone: number = 0;
      let fTotal: number = 0;
      let cur: string = '';
      for (const s of active) {
        done += Number(s.bytesDone);
        total += Number(s.bytesTotal);
        fDone += Number(s.filesDone);
        fTotal += Number(s.filesTotal);
        if (cur.length === 0 && s.current !== undefined && s.current.length > 0) {
          cur = s.current;
        }
      }
      const now: number = Date.now();
      if (this.lastMs > 0 && now > this.lastMs) {
        const r: number = (done - this.lastBytes) * 1000 / (now - this.lastMs);
        this.rate = r > 0 ? r : 0;
      }
      this.lastBytes = done;
      this.lastMs = now;
      this.bytesDone = done;
      this.bytesTotal = total;
      this.filesDone = fDone;
      this.filesTotal = fTotal;
      this.current = cur;
      if (!this.backgrounded) {
        this.visible = true;
        AppStorage.setOrCreate('sfTransferOverlay', true);
      }
    } catch (e) {
      // ignore
    }
  }

  private cancelAll(): void {
    if (this.core === null) {
      return;
    }
    try {
      const snaps: TransferSnapshot[] = this.core.transfers();
      for (const s of snaps) {
        if (s.state === TransferState.Running || s.state === TransferState.Queued) {
          try {
            this.core.cancelTransfer(s.id);
          } catch (e) {
            // continue
          }
        }
      }
    } catch (e) {
      // ignore
    }
  }

  private sendToBackground(): void {
    this.backgrounded = true;
    this.visible = false;
    AppStorage.setOrCreate('sfTransferOverlay', false);
  }

  build() {
    // 只在传输进行时渲染，避免空 Stack 拦截底部导航等点击
    if (this.visible) {
      Column() {
        Blank().layoutWeight(1).onClick(() => {
        })
        Column({ space: SPACE3 }) {
            Row({ space: SPACE3 }) {
              Column() {
                Text(this.tt('tr.fgTransferring'))
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.th().onSurface)
                  .width('100%')
                Text(this.filesTotal > 1 ? this.tt('tr.fgItems', `${this.filesTotal}`) : this.tt('tr.fgOneItem'))
                  .fontSize(12)
                  .fontColor(this.th().onSurfaceVariant)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')

            Text(this.current.length > 0 ? this.current : this.tt('tr.fgPreparing'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().onSurface)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            Progress({ value: this.bytesTotal > 0 ? this.bytesDone / this.bytesTotal * 100 : 0, total: 100,
              type: ProgressType.Linear })
              .width('100%')
              .height(6)

            Row() {
              Text((this.filesTotal > 1
                  ? this.tt('tr.fgItemProgress', `${Math.min(this.filesDone, this.filesTotal)}`, `${this.filesTotal}`)
                  : '') + `${formatBytes(this.bytesDone)} / ${formatBytes(this.bytesTotal)}`)
                .fontSize(11)
                .fontColor(this.th().onSurfaceVariant)
                .layoutWeight(1)
              Text(this.rate > 0 ? `${formatBytes(Math.round(this.rate))}/s` : '…')
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.th().primary)
            }
            .width('100%')

            Row({ space: SPACE2 }) {
              Text(this.tt('tr.fgStop'))
                .fontSize(13)
                .fontColor(this.th().error)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .onClick(() => this.cancelAll())
              Blank().layoutWeight(1)
              Button(this.tt('tr.fgBackground'))
                .fontSize(13)
                .height(34)
                .backgroundColor(this.th().primary)
                .fontColor(Color.White)
                .onClick(() => this.sendToBackground())
            }
            .width('100%')
          }
          .width('100%')
          .padding(SPACE4)
          .backgroundColor(this.th().surface)
          .borderRadius(RADIUS_M)
          .alignItems(HorizontalAlign.Start)

          Blank().layoutWeight(1).onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
    }
  }
}
