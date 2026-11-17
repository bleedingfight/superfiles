import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { FileIcon } from '../common/FileIcon';
import { formatBytes, formatDate , errText} from '../common/Format';
import { t } from '../common/L10n';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_M, RADIUS_PILL,
  SPACE1, SPACE2, SPACE3, SPACE4, T_APPBAR, T_BODY, T_FILENAME, T_SECONDARY
} from '../common/Tokens';

interface BrowseParams {
  uri: string;
  title: string;
}

interface Item {
  uri: string;
  name: string;
  isDir: boolean;
  size: number;
  modified: number;
}

const PV_NONE: number = 0;
const PV_IMAGE: number = 1;
const PV_TEXT: number = 2;
const PV_OTHER: number = 3;

/**
 * 本机存储浏览器：用户通过 DocumentViewPicker 授权目录后进入。
 * 只读；授权有效期到设备重启。文件可单条导入沙箱（走内核 VFS）。
 */
@Entry
@Component
struct LocalBrowse {
  @State dirUri: string = '';
  @State title: string = '';
  @State items: Item[] = [];
  @State loading: boolean = true;
  @State error: string = '';
  @State notice: string = '';
  @State pvMode: number = PV_NONE;
  @State pvName: string = '';
  @State pvUri: string = '';
  @State pvText: string = '';
  @State menuUri: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfShowHidden') showHidden: boolean = false;
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  aboutToAppear(): void {
    const params = router.getParams() as BrowseParams;
    let u: string = params.uri;
    if (u.startsWith('file://')) {
      try {
        u = new fileUri.FileUri(u).path;
      } catch (e) {
        u = u.replace(/^file:\/\//, '');
      }
    }
    this.dirUri = u;
    this.title = params.title;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
    }
    this.load(this.dirUri);
  }

  private load(dirUri: string): void {
    this.loading = true;
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dirUri);
    } catch (e) {
      this.items = [];
      this.loading = false;
      this.error = this.tt('home.expired');
      return;
    }
    const out: Item[] = [];
    for (const name of names) {
      if (!this.showHidden && name.startsWith('.')) {
        continue;
      }
      let childUri: string = `${dirUri}/${name}`;
      let st: fileIo.Stat;
      try {
        st = fileIo.statSync(childUri);
      } catch (e) {
        try {
          childUri = `${dirUri}/${encodeURIComponent(name)}`;
          st = fileIo.statSync(childUri);
        } catch (e2) {
          continue;
        }
      }
      out.push({
        uri: childUri,
        name: name,
        isDir: st.isDirectory(),
        size: Number(st.size),
        modified: Number(st.mtime) * 1000
      });
    }
    out.sort((a: Item, b: Item) => {
      const ad: number = a.isDir ? 0 : 1;
      const bd: number = b.isDir ? 0 : 1;
      if (ad !== bd) {
        return ad - bd;
      }
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
    });
    this.items = out;
    this.loading = false;
  }

  private menuItem(): Item | null {
    for (const it of this.items) {
      if (it.uri === this.menuUri) {
        return it;
      }
    }
    return null;
  }

  private deleteDirRecursively(dir: string): void {
    const names: string[] = fileIo.listFileSync(dir);
    for (const name of names) {
      const child: string = `${dir}/${name}`;
      const st: fileIo.Stat = fileIo.statSync(child);
      if (st.isDirectory()) {
        this.deleteDirRecursively(child);
      } else {
        fileIo.unlinkSync(child);
      }
    }
    fileIo.rmdirSync(dir);
  }

  private deleteItem(it: Item): void {
    try {
      if (it.isDir) {
        this.deleteDirRecursively(it.uri);
      } else {
        fileIo.unlinkSync(it.uri);
      }
      this.notice = this.tt('files.deleted', '1');
      this.load(this.dirUri);
    } catch (e) {
      this.error = this.tt('files.deleteFailed') + '：' + errText(e);
    }
  }

  @Builder
  swipeMoreItemBtn(it: Item) {
    Column() {
      Text(this.tt('common.more'))
        .fontSize(13)
        .fontColor(this.th().onPrimary)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().primary)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topRight: 14, bottomRight: 14 })
    .onClick(() => {
      this.menuUri = it.uri;
    })
  }

  @Builder
  swipeDeleteItemBtn(it: Item) {
    Column() {
      Text(this.tt('common.delete'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topLeft: 14, bottomLeft: 14 })
    .onClick(() => {
      this.deleteItem(it);
    })
  }

  @Builder
  itemMenuRow(label: string, color: string | number, action: () => void) {
    Text(label)
      .fontSize(15)
      .fontColor(color)
      .width('100%')
      .height(44)
      .onClick(action)
  }

  @Builder
  itemMenuOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.menuUri = '')
      Column({ space: SPACE2 }) {
        Text(this.menuItem() === null ? '' : (this.menuItem() as Item).name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Divider().color(this.th().divider)
        this.itemMenuRow(this.tt('common.open'), this.th().onSurface, () => {
          const it: Item | null = this.menuItem();
          this.menuUri = '';
          if (it !== null) {
            this.openItem(it);
          }
        })
        this.itemMenuRow(this.tt('home.importThis'), this.th().onSurface, () => {
          const it: Item | null = this.menuItem();
          this.menuUri = '';
          if (it !== null) {
            this.importItem(it);
          }
        })
        this.itemMenuRow(this.tt('common.delete'), this.th().error, () => {
          const it: Item | null = this.menuItem();
          this.menuUri = '';
          if (it !== null) {
            this.deleteItem(it);
          }
        })
        Button(this.tt('common.cancel'))
          .width('100%')
          .height(40)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => this.menuUri = '')
      }
      .width('100%')
      .padding({ left: SPACE4, right: SPACE4, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  private isText(name: string): boolean {
    return /\.(txt|md|json|log|xml|yaml|yml|csv|ini|conf|rs|kt|ets|ts|js|py|sh|toml)$/i.test(name);
  }

  private isImage(name: string): boolean {
    return /\.(jpg|jpeg|png|gif|webp|bmp|heic|heif)$/i.test(name);
  }

  private openItem(it: Item): void {
    if (it.isDir) {
      router.pushUrl({ url: 'pages/LocalBrowse', params: { uri: it.uri, title: `${this.title}/${it.name}` } });
      return;
    }
    this.pvName = it.name;
    this.pvUri = it.uri;
    if (this.isImage(it.name)) {
      this.pvMode = PV_IMAGE;
      return;
    }
    if (this.isText(it.name) && it.size < 512 * 1024) {
      try {
        const f = fileIo.openSync(it.uri, fileIo.OpenMode.READ_ONLY);
        try {
          const buf: ArrayBuffer = new ArrayBuffer(Math.min(it.size, 256 * 1024));
          fileIo.readSync(f.fd, buf);
          const decoder = util.TextDecoder.create('utf-8');
          this.pvText = decoder.decodeToString(new Uint8Array(buf));
        } finally {
          fileIo.closeSync(f);
        }
        this.pvMode = PV_TEXT;
        return;
      } catch (e) {
        this.pvMode = PV_OTHER;
        return;
      }
    }
    this.pvMode = PV_OTHER;
  }

  private importItem(it: Item): void {
    if (this.core === null) {
      return;
    }
    try {
      const f = this.core.createFile(this.core.rootId(), it.name);
      const src = fileIo.openSync(it.uri, fileIo.OpenMode.READ_ONLY);
      try {
        this.core.importFromFd(f.id, src.fd, BigInt(0));
      } finally {
        fileIo.closeSync(src);
      }
      this.notice = this.tt('home.importedOk', it.name);
      this.pvMode = PV_NONE;
    } catch (e) {
      this.error = this.tt('home.importFail') + '：' + errText(e);
    }
  }

  @Builder
  previewOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.pvMode = PV_NONE)
      Column({ space: SPACE3 }) {
        Row({ space: SPACE2 }) {
          Text(this.pvName)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.th().onSurface)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('✕').fontSize(16).fontColor(this.th().onSurfaceVariant)
            .onClick(() => this.pvMode = PV_NONE)
        }
        .width('100%')

        if (this.pvMode === PV_IMAGE) {
          Image(this.pvUri)
            .objectFit(ImageFit.Contain)
            .width('100%')
            .constraintSize({ maxHeight: 420 })
        } else if (this.pvMode === PV_TEXT) {
          Scroll() {
            Text(this.pvText)
              .fontSize(13)
              .fontFamily('monospace')
              .fontColor(this.th().onSurface)
              .width('100%')
          }
          .constraintSize({ maxHeight: 420 })
          .width('100%')
          .align(Alignment.TopStart)
        } else {
          Text(this.tt('pv.noRenderer'))
            .fontSize(13)
            .fontColor(this.th().onSurfaceVariant)
            .width('100%')
            .padding(SPACE3)
        }

        if (this.pvMode === PV_OTHER) {
          Button(this.tt('home.importThis'))
            .width('100%')
            .height(42)
            .backgroundColor(this.th().primary)
            .fontColor(this.th().onPrimary)
            .onClick(() => {
              const it: Item = { uri: this.pvUri, name: this.pvName, isDir: false, size: 0, modified: 0 };
              this.importItem(it);
            })
        }
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Row({ space: SPACE2 }) {
          Button('‹')
            .fontSize(22)
            .width(36)
            .height(36)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurface)
            .onClick(() => router.back())
          Column({ space: 2 }) {
            Text(this.title)
              .fontSize(T_APPBAR)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().onSurface)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.tt('home.readOnlyTag'))
              .fontSize(T_SECONDARY)
              .fontColor(this.th().onSurfaceVariant)
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height(52)
        .padding({ left: SCREEN_MARGIN - 8, right: SCREEN_MARGIN - 8 })

        if (this.error.length > 0) {
          Text(this.error).fontSize(12).fontColor(this.th().error).width('100%')
            .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }
        if (this.notice.length > 0) {
          Text(this.notice).fontSize(12).fontColor(this.th().success).width('100%')
            .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }

        if (this.loading) {
          Column() {
            LoadingProgress().width(36).height(36).color(this.th().primary)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else if (this.items.length === 0) {
          Column({ space: 6 }) {
            Text(this.tt('home.emptyDir')).fontSize(15).fontColor(this.th().onSurfaceVariant)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else {
          List() {
            ForEach(this.items, (it: Item) => {
              ListItem() {
                Row({ space: SPACE3 }) {
                  FileIcon({ name: it.name, isDir: it.isDir, dark: this.dark, box: 32 })
                  Column({ space: 1 }) {
                    Text(it.name)
                      .fontSize(T_FILENAME)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.th().onSurface)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(it.isDir ? this.tt('common.folder')
                        : `${formatBytes(it.size)}${it.modified > 0 ? ' · ' + formatDate(it.modified) : ''}`)
                      .fontSize(11)
                      .fontColor(this.th().onSurfaceVariant)
                      .maxLines(1)
                      .width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .constraintSize({ minHeight: 72 })
                .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
              }
              .swipeAction({
                start: {
                  builder: () => {
                    this.swipeDeleteItemBtn(it);
                  },
                  actionAreaDistance: 56
                },
                end: {
                  builder: () => {
                    this.swipeMoreItemBtn(it);
                  },
                  actionAreaDistance: 56
                }
              })
              .onClick(() => this.openItem(it))
            }, (it: Item) => it.uri)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 88 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)

      if (this.pvMode !== PV_NONE) {
        this.previewOverlay()
      }
      if (this.menuUri.length > 0) {
        this.itemMenuOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
