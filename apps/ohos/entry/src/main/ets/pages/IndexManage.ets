import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { errText } from '../common/Format';
import { loadMounts, MountConfig } from '../common/MountStore';
import { ensureMounted } from '../common/MountOps';
import { enqueueScan } from '../common/ScanCenter';
import { t } from '../common/L10n';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_M, SPACE1, SPACE2, SPACE3, SPACE4,
  T_APPBAR, T_BODY, T_CARD_TITLE, T_FILENAME, T_SECONDARY
} from '../common/Tokens';

/**
 * 索引管理：本地默认建立索引；每个网络存储由用户决定是否建立、
 * 何时重建、何时只清该挂载的索引（不影响其它位置）。
 * 索引只服务分类/搜索，没建索引的挂载不会出现在结果里。
 */
interface IndexRow {
  id: string;
  label: string;
  count: number;
  isLocal: boolean;
  proto: string;
}

@Entry
@Component
struct IndexManage {
  @State rows: IndexRow[] = [];
  @State total: number = 0;
  @State error: string = '';
  @State notice: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfLang') lang: string = 'auto';
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfScanningId') @Watch('onScanState') scanId: string = '';
  @StorageLink('sfScanLabel') scanLabel: string = '';
  @StorageLink('sfScanFraction') scanFrac: number = -1;
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.error = errText(e);
      return;
    }
    this.load();
  }

  onScanState(): void {
    if (this.scanId.length === 0) {
      this.load();
    }
  }

  private load(): void {
    if (this.core === null) {
      return;
    }
    const out: IndexRow[] = [];
    try {
      const rootId: string = this.core.rootId();
      out.push({
        id: rootId,
        label: this.tt('index.localLabel'),
        count: Number(this.core.indexPrefixCount(rootId)),
        isLocal: true,
        proto: ''
      });
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      for (const c of loadMounts(ctx)) {
        out.push({
          id: c.rootId,
          label: c.label,
          count: c.rootId.length > 0 ? Number(this.core.indexPrefixCount(c.rootId)) : 0,
          isLocal: false,
          proto: c.proto
        });
      }
      this.total = Number(this.core.indexCount());
    } catch (e) {
      this.error = errText(e);
    }
    this.rows = out;
  }

  private rebuild(row: IndexRow): void {
    if (this.core === null) {
      return;
    }
    let id: string = row.id;
    if (!row.isLocal) {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const configs: MountConfig[] = loadMounts(ctx);
      let cfg: MountConfig | null = null;
      for (const c of configs) {
        if (c.label === row.label) {
          cfg = c;
        }
      }
      if (cfg === null) {
        return;
      }
      // 进程重启后挂载会失效：先建连再扫描，否则内核报 no backend mounted
      const rootId: string | null = ensureMounted(ctx, this.core, cfg, configs);
      if (rootId === null) {
        this.error = this.tt('mine.mountFailed');
        return;
      }
      id = rootId;
    }
    enqueueScan({ id: id, label: row.isLocal ? '' : row.label, full: true, force: true });
    this.notice = this.tt('mine.indexQueued', row.isLocal ? '' : row.label);
  }

  private clearAll(): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.clearIndex();
      this.notice = this.tt('index.clearAllDone');
      this.load();
    } catch (e) {
      this.error = this.tt('mine.clearFailed') + '：' + errText(e);
    }
  }

  private clearRow(row: IndexRow): void {
    if (this.core === null) {
      return;
    }
    try {
      const removed: bigint = this.core.clearIndexPrefix(row.id);
      this.notice = this.tt('index.clearDone', row.label, `${removed}`);
      this.load();
    } catch (e) {
      this.error = this.tt('mine.clearFailed') + '：' + errText(e);
    }
  }

  /** 与网络存储列表一致的品牌图标。 */
  @Builder
  dropboxIcon() {
    Column({ space: 0 }) {
      Row({ space: 0 }) {
        Polygon().points([[0, 5], [6.5, 0], [13, 5], [6.5, 10]]).fill('#0061FF').width(13).height(11)
        Polygon().points([[0, 5], [6.5, 0], [13, 5], [6.5, 10]]).fill('#0061FF').width(13).height(11)
      }
      .width(26)
      Row({ space: 0 }) {
        Polygon().points([[0, 0], [6.5, 5], [6.5, 11], [0, 6]]).fill('#0061FF').width(6.5).height(11)
        Blank().width(13)
        Polygon().points([[6.5, 0], [0, 5], [0, 11], [6.5, 6]]).fill('#0061FF').width(6.5).height(11)
      }
      .width(26)
      .justifyContent(FlexAlign.Center)
    }
    .width(28)
    .height(24)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  gdriveIcon() {
    Stack() {
      Polygon().points([[13, 0.92], [13, 8.25], [8.1, 15.58], [1.63, 19.25]]).fill('#34A853').width(26).height(20)
      Polygon().points([[13, 0.92], [24.38, 19.25], [17.9, 15.58], [13, 8.25]]).fill('#4285F4').width(26).height(20)
      Polygon().points([[1.63, 19.25], [24.38, 19.25], [17.9, 15.58], [8.1, 15.58]]).fill('#FBBC04').width(26).height(20)
    }
    .width(28)
    .height(22)
    .margin({ right: 2 })
  }

  @Builder
  onedriveIcon() {
    Text('☁')
      .fontSize(20)
      .fontColor('#0078D4')
      .width(28)
      .height(22)
      .textAlign(TextAlign.Center)
      .margin({ right: 2 })
  }

  @Builder
  pan115Icon() {
    Text('115')
      .fontSize(10)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor('#2E7CF6')
      .margin({ right: 2 })
  }

  private protoGlyph(scheme: string): string {
    const s: string = scheme.toLowerCase();
    if (s.indexOf('smb') >= 0) {
      return '⇄';
    }
    if (s.indexOf('sftp') >= 0) {
      return '⌘';
    }
    if (s.indexOf('webdav') >= 0) {
      return '☁';
    }
    return '☁';
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(T_SECONDARY)
      .fontColor(this.th().onSurfaceVariant)
      .width('100%')
      .padding({ top: SPACE3, bottom: SPACE1 })
  }

  @Builder
  rowView(row: IndexRow) {
    Row({ space: SPACE3 }) {
      if (row.isLocal) {
        Text('📱').fontSize(18).width(24).textAlign(TextAlign.Center)
      } else if (row.proto === 'Dropbox') {
        this.dropboxIcon()
      } else if (row.proto === 'GoogleDrive') {
        this.gdriveIcon()
      } else if (row.proto === 'OneDrive') {
        this.onedriveIcon()
      } else if (row.proto === '115') {
        this.pan115Icon()
      } else {
        Text(this.protoGlyph(row.proto)).fontSize(18).fontColor(this.th().primary).width(24).textAlign(TextAlign.Center)
      }
      Column({ space: 1 }) {
        Text(row.label)
          .fontSize(T_FILENAME)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.rowStatus(row))
          .fontSize(11)
          .fontColor(this.scanId === row.id ? this.th().primary : this.th().onSurfaceVariant)
          .maxLines(1)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.scanId !== row.id) {
        Text(row.count > 0 ? this.tt('index.rebuild') : this.tt('index.build'))
          .fontSize(12)
          .fontColor(this.th().primary)
          .padding({ left: SPACE2 })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: SPACE4, right: SPACE4 })
    .onClick(() => {
      if (this.scanId !== row.id) {
        this.rebuild(row);
      }
    })
  }

  private rowStatus(row: IndexRow): string {
    if (this.scanId === row.id) {
      const pct: string = `${Math.round(Math.max(0, this.scanFrac) * 100)}`;
      return this.tt('index.scanningPct', pct);
    }
    return row.count > 0 ? this.tt('index.entries', `${row.count}`) : this.tt('index.none');
  }

  @Builder
  deleteBtn(row: IndexRow) {
    Column() {
      Text(this.tt('index.clear'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.clearRow(row))
  }

  build() {
    Column() {
      Row({ space: SPACE3 }) {
        Button('‹')
          .fontSize(20)
          .width(34)
          .height(34)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => router.back())
        Column({ space: 1 }) {
          Text(this.tt('index.title'))
            .fontSize(T_APPBAR)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().onSurface)
          Text(this.tt('index.hint'))
            .fontSize(11)
            .fontColor(this.th().onSurfaceVariant)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })

      Scroll() {
        Column({ space: SPACE1 }) {
          // 汇总
          Column({ space: 2 }) {
            Text(this.tt('index.total'))
              .fontSize(12)
              .fontColor(this.th().onSurfaceVariant)
              .width('100%')
            Text(this.tt('index.totalLine', `${this.total}`))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().onSurface)
              .width('100%')
          }
          .width('100%')
          .padding(SPACE3)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_M)
          .alignItems(HorizontalAlign.Start)

          if (this.error.length > 0) {
            Text(this.error).fontSize(12).fontColor(this.th().error).width('100%')
          }
          if (this.notice.length > 0) {
            Text(this.notice).fontSize(12).fontColor(this.th().success).width('100%')
          }

          this.sectionTitle(this.tt('index.sectionLocal'))
          List() {
            ForEach(this.rows.filter((r: IndexRow) => r.isLocal), (r: IndexRow) => {
              ListItem() {
                this.rowView(r)
              }
              .swipeAction({
                end: {
                  builder: () => {
                    this.deleteBtn(r);
                  },
                  actionAreaDistance: 56
                }
              })
            }, (r: IndexRow) => `${r.id}|${r.count}`)
          }
          .width('100%')
          .height(66)
          .scrollBar(BarState.Off)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_L)

          this.sectionTitle(this.tt('index.sectionNetwork'))
          List() {
            ForEach(this.rows.filter((r: IndexRow) => !r.isLocal), (r: IndexRow) => {
              ListItem() {
                this.rowView(r)
              }
              .swipeAction({
                end: {
                  builder: () => {
                    this.deleteBtn(r);
                  },
                  actionAreaDistance: 56
                }
              })
            }, (r: IndexRow) => `${r.id}|${r.count}`)
          }
          .width('100%')
          .height(Math.max(1, this.rows.filter((r: IndexRow) => !r.isLocal).length) * 66)
          .scrollBar(BarState.Off)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_L)

          Text(this.tt('index.footnote'))
            .fontSize(11)
            .fontColor(this.th().outline)
            .width('100%')
            .padding({ top: SPACE2 })

          // 全局清空（原先在「我的」页，操作已并入本页）
          Text(this.tt('index.clearAll'))
            .fontSize(13)
            .fontColor(this.th().error)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: SPACE3, bottom: SPACE3 })
            .onClick(() => this.clearAll())
          Blank().height(24)
        }
        .width('100%')
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
  }
}
