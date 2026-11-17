import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CompletedTransfer, Entry, EntryKind, SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { formatBytes, formatDate, formatClock, errText } from '../common/Format';
import { FileIcon } from '../common/FileIcon';
import { t } from '../common/L10n';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_M,
  SPACE1, SPACE2, SPACE3, SPACE4, T_APPBAR, T_BODY, T_CARD_TITLE, T_FILENAME, T_SECONDARY
} from '../common/Tokens';

interface CleanItem {
  id: string;
  name: string;
  size: number;
  /** 目录大小还在后台渐进估算时为 false，行内数字显示出扫描标记。 */
  measured: boolean;
  isDir: boolean;
  modified: number;
}

@Entry
@Component
struct Cleanup {
  @State items: CleanItem[] = [];
  @State arrivals: CompletedTransfer[] = [];
  @State loaded: boolean = false;
  @State sweeping: boolean = false;
  @State error: string = '';
  @State notice: string = '';
  @State confirming: boolean = false;
  /** 'dir' = 删本机文件/目录；'arrival' = 删一次传输拷入的全部目标文件。 */
  @State confirmKind: string = 'dir';
  @State targetId: string = '';
  @State targetName: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfLang') lang: string = 'auto';
  private core: SuperFiles | null = null;
  /** 扫描队列：顶层目录逐个在后台补齐体积（约每 80ms 一个）。 */
  private sweepQueue: string[] = [];
  private sweepTimer: number = -1;
  private pollTimer: number = -1;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.lang, key, ...args);
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
      return;
    }
    this.scan();
  }

  aboutToDisappear(): void {
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private basename(path: string): string {
    const trimmed: string = path.replace(/\/+$/, '');
    const at: number = trimmed.lastIndexOf('/');
    return at >= 0 ? trimmed.substring(at + 1) : trimmed;
  }

  private dirSize(id: string, budget: number[]): number {
    if (this.core === null) {
      return 0;
    }
    let total: number = 0;
    let items: Entry[] = [];
    try {
      items = this.core.list(id);
    } catch (e) {
      return 0;
    }
    for (const e of items) {
      if (budget[0] <= 0) {
        return total;
      }
      budget[0] = budget[0] - 1;
      if (e.kind === EntryKind.Directory) {
        total += this.dirSize(e.id, budget);
      } else {
        total += Number(e.size);
      }
    }
    return total;
  }

  /**
   * 顶层条目秒出（文件 size 直接来自 stat，目录先占位），
   * 目录体积由后台 sweep 逐个补齐 —— 「后台静默扫描」：页面立即可用，
   * 数字渐进浮现，UI 不因深目录递归而卡住。
   */
  private scan(): void {
    if (this.core === null) {
      return;
    }
    try {
      const root: string = this.core.rootId();
      const all: Entry[] = this.core.list(root);
      const out: CleanItem[] = [];
      const queue: string[] = [];
      for (const e of all) {
        if (e.name.startsWith('.')) {
          continue; // 隐藏目录（内核 .tmp 兜底等）不进清理列表
        }
        const isDir: boolean = e.kind === EntryKind.Directory;
        const size: number = isDir ? 0 : Number(e.size);
        if (isDir) {
          queue.push(e.id);
        }
        out.push({
          id: e.id,
          name: e.name,
          size: size,
          measured: !isDir,
          isDir: isDir,
          modified: e.modifiedMs === undefined ? 0 : Number(e.modifiedMs)
        });
      }
      out.sort((a: CleanItem, b: CleanItem) => Number(b.isDir) - Number(a.isDir) || b.size - a.size);
      this.items = out;
      this.startSweep(queue);
      this.refreshArrivals();
      this.loaded = true;
      this.error = '';
    } catch (e) {
      this.error = this.tt('cl.scanFailed') + '：' + errText(e);
    }
  }

  private startSweep(queue: string[]): void {
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    this.sweepQueue = queue;
    this.sweeping = queue.length > 0;
    if (queue.length === 0) {
      return;
    }
    this.sweepTimer = setInterval(() => this.sweepStep(), 80);
  }

  private sweepStep(): void {
    const next: string | undefined = this.sweepQueue.shift();
    if (next === undefined) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
      this.sweeping = false;
      return;
    }
    const size: number = this.dirSize(next, [500]);
    const items: CleanItem[] = this.items.slice();
    for (let i = 0; i < items.length; i++) {
      if (items[i].id === next && items[i].isDir) {
        items[i].size = size;
        items[i].measured = true;
      }
    }
    this.items = items;
    if (this.sweeping && this.sweepQueue.length === 0) {
      this.sweeping = false;
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
  }

  /** 传输到本机的完成记录：2s 轮询保持同步（拷完这项很快出现在这里）。 */
  private refreshArrivals(): void {
    if (this.core === null) {
      return;
    }
    try {
      let rows: CompletedTransfer[] = this.core.completedTransfers(50);
      const local: CompletedTransfer[] = [];
      for (const r of rows) {
        if (r.destDir.startsWith('/')) {
          local.push(r); // 只关心落到本机的
        }
      }
      rows = local;
      if (this.pollTimer < 0) {
        this.pollTimer = setInterval(() => this.refreshArrivals(), 2000);
      }
      // 内容变了才落 @State（列表刷新会收回展开的左滑菜单）
      if (this.arrivalSig(rows) !== this.arrivalSig(this.arrivals)) {
        this.arrivals = rows;
      }
    } catch (e) {
      // 最近传输读不到不阻塞页面
    }
  }

  private arrivalSig(rows: CompletedTransfer[]): string {
    let sig: string = '';
    for (const r of rows) {
      sig += `${r.id}:${Number(r.bytesTotal)}:${Number(r.finishedAtMs)}|`;
    }
    return sig;
  }

  /** 一次传输的目标文件集合：join(destDir, basename(source))。 */
  private arrivalTargets(r: CompletedTransfer): string[] {
    const dir: string = r.destDir.replace(/\/+$/, '');
    const out: string[] = [];
    for (const src of r.sources) {
      const name: string = this.basename(src);
      if (name.length > 0) {
        out.push(`${dir}/${name}`);
      }
    }
    return out;
  }

  private doDelete(): void {
    if (this.core === null) {
      return;
    }
    if (this.confirmKind === 'arrival') {
      // 删除这次传输拷到本机的全部目标文件（忽略已不存在的），然后清记录行
      let removed: number = 0;
      for (const target of this.arrivalTargets(this.arrivalById(this.targetId))) {
        try {
          this.core.stat(target);
          this.core.remove(target, false);
          removed++;
        } catch (e) {
          // 目标文件已不存在（改名/移动过）——跳过
        }
      }
      try {
        this.core.forgetTransfer(this.targetId);
      } catch (e) {
        // 行已不在也不阻塞
      }
      this.notice = this.tt('cl.deleted', `${removed} ${this.targetName}`);
      this.confirming = false;
      this.refreshArrivals();
      this.scan();
      return;
    }
    try {
      this.core.remove(this.targetId, true);
      this.notice = this.tt('cl.deleted', this.targetName);
      this.confirming = false;
      this.scan();
    } catch (e) {
      this.error = this.tt('files.deleteFailed') + '：' + errText(e);
      this.confirming = false;
    }
  }

  private arrivalById(id: string): CompletedTransfer {
    let found: CompletedTransfer = this.arrivals[0];
    for (const r of this.arrivals) {
      if (r.id === id) {
        found = r;
      }
    }
    return found;
  }

  @Builder
  swipeDeleteBtn(label: string, onAction: () => void) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topRight: 14, bottomRight: 14 })
    .onClick(onAction)
  }

  @Builder
  arrivalRow(r: CompletedTransfer) {
    Row({ space: SPACE3 }) {
      Text('⇣')
        .fontSize(16)
        .fontColor(this.th().primary)
      Column({ space: 2 }) {
        Text(this.destLabel(r))
          .fontSize(T_FILENAME)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${formatBytes(Number(r.bytesTotal))} · ${this.tt('cl.arrivedAt')} ${formatClock(Number(r.finishedAtMs))}` +
          ` · ${Number(r.filesTotal)} ${this.tt('cl.files')}`)
          .fontSize(T_SECONDARY)
          .fontColor(this.th().onSurfaceVariant)
          .maxLines(1)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
  }

  private destLabel(r: CompletedTransfer): string {
    const dir: string = this.basename(r.destDir);
    if (dir.length > 0 && dir !== '/') {
      return dir;
    }
    if (r.sources.length === 1) {
      return this.basename(r.sources[0]);
    }
    return this.tt('cl.arrivals');
  }

  @Builder
  storageRow(it: CleanItem) {
    Row({ space: SPACE3 }) {
      FileIcon({ name: it.name, isDir: it.isDir, dark: this.dark, box: 32 })
      Column({ space: 2 }) {
        Text(it.name).fontSize(T_FILENAME).fontColor(this.th().onSurface)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(it.isDir && !it.measured
          ? this.tt('cl.sweeping')
          : `${formatBytes(it.size)}${it.modified > 0 ? ' · ' + formatDate(it.modified) : ''}`)
          .fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant).width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row({ space: 8 }) {
          Button('‹')
            .fontSize(22)
            .width(38)
            .height(38)
            .backgroundColor(this.th().searchFieldBg)
            .fontColor(this.th().onSurface)
            .onClick(() => router.back())
          Text(this.tt('cl.title')).fontSize(T_APPBAR).fontWeight(FontWeight.Bold)
            .fontColor(this.th().onSurface)
            .layoutWeight(1)
          if (this.sweeping) {
            LoadingProgress().width(18).height(18)
          }
          Text(this.tt('common.rescan')).fontSize(T_BODY).fontColor(this.th().primary).onClick(() => this.scan())
        }
        .width('100%')
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })

        if (this.error.length > 0) {
          Text(this.error).fontSize(T_BODY).fontColor(this.th().error)
            .width('100%').padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }
        if (this.notice.length > 0) {
          Text(this.notice).fontSize(T_BODY).fontColor(this.th().success)
            .width('100%').padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }

        if (!this.loaded) {
          Column() {
            LoadingProgress().width(36).height(36)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else {
          Scroll() {
            Column() {
              // ---- 传输到本机 ------------------------------------------------
              if (this.arrivals.length > 0) {
                Text(this.tt('cl.arrivals'))
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.th().onSurface)
                  .width('100%')
                  .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 4 })
                Text(this.tt('cl.arrivalsHint'))
                  .fontSize(T_SECONDARY)
                  .fontColor(this.th().onSurfaceVariant)
                  .width('100%')
                  .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, bottom: SPACE2 })
                List({ space: 0 }) {
                  ForEach(this.arrivals, (r: CompletedTransfer, index: number) => {
                    ListItem() {
                      Column() {
                        this.arrivalRow(r)
                        if (index !== this.arrivals.length - 1) {
                          Divider().color(this.th().divider)
                        }
                      }
                      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
                    }
                    .swipeAction({
                      end: {
                        builder: () => {
                          this.swipeDeleteBtn(this.tt('common.delete'), () => {
                            this.confirmKind = 'arrival';
                            this.targetId = r.id;
                            this.targetName = this.destLabel(r);
                            this.confirming = true;
                          })
                        },
                        actionAreaDistance: 56
                      }
                    })
                  }, (r: CompletedTransfer) => r.id)
                }
                .width('100%')
                .padding({ bottom: SPACE3 })
              }

              // ---- 本机存储 --------------------------------------------------
              Text(this.tt('cl.storage'))
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.th().onSurface)
                .width('100%')
                .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 4, bottom: SPACE2 })
              if (this.items.length === 0) {
                Text(this.tt('cl.empty')).fontSize(15)
                  .fontColor(this.th().onSurfaceVariant)
                  .width('100%')
                  .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
              } else {
                List({ space: 0 }) {
                  ForEach(this.items, (it: CleanItem, index: number) => {
                    ListItem() {
                      Column() {
                        this.storageRow(it)
                        if (index !== this.items.length - 1) {
                          Divider().color(this.th().divider)
                        }
                      }
                      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
                    }
                    .swipeAction({
                      end: {
                        builder: () => {
                          this.swipeDeleteBtn(this.tt('common.delete'), () => {
                            this.confirmKind = 'dir';
                            this.targetId = it.id;
                            this.targetName = it.name;
                            this.confirming = true;
                          })
                        },
                        actionAreaDistance: 56
                      }
                    })
                  }, (it: CleanItem) => it.id)
                }
                .width('100%')
              }
              Row().height(24)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)

      if (this.confirming) {
        Column() {
          Blank().layoutWeight(1).onClick(() => this.confirming = false)
          Column({ space: SPACE3 }) {
            Text(this.confirmKind === 'arrival'
              ? this.tt('cl.deleteArrivalTitle', this.targetName)
              : this.tt('cl.deleteTitle', this.targetName))
              .fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor(this.th().onSurface)
            Text(this.confirmKind === 'arrival'
              ? this.tt('cl.deleteArrivalWarn')
              : this.tt('cl.deleteWarn')).fontSize(T_BODY).fontColor(this.th().onSurfaceVariant)
            Row({ space: SPACE2 }) {
              Button(this.tt('common.cancel'))
                .layoutWeight(1)
                .height(40)
                .backgroundColor(this.th().searchFieldBg)
                .fontColor(this.th().onSurface)
                .onClick(() => this.confirming = false)
              Button(this.tt('common.delete'))
                .layoutWeight(1)
                .height(40)
                .backgroundColor(this.th().error)
                .fontColor(this.th().onPrimary)
                .onClick(() => this.doDelete())
            }
            .width('100%')
          }
          .width('100%')
          .padding(SPACE4)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
