import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Entry, EntryKind, SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { formatBytes, formatDate , errText} from '../common/Format';
import { FileIcon } from '../common/FileIcon';
import { t } from '../common/L10n';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_M, RADIUS_PILL,
  SPACE1, SPACE2, SPACE3, SPACE4, T_APPBAR, T_BODY, T_CARD_TITLE, T_FILENAME, T_SECONDARY
} from '../common/Tokens';

interface CleanItem {
  id: string;
  name: string;
  size: number;
  isDir: boolean;
  modified: number;
}

@Entry
@Component
struct Cleanup {
  @State items: CleanItem[] = [];
  @State loaded: boolean = false;
  @State error: string = '';
  @State notice: string = '';
  @State confirming: boolean = false;
  @State targetId: string = '';
  @State targetName: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfLang') lang: string = 'auto';
  private core: SuperFiles | null = null;

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
      this.scan();
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
    }
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

  private scan(): void {
    if (this.core === null) {
      return;
    }
    try {
      const root: string = this.core.rootId();
      const all: Entry[] = this.core.list(root);
      const out: CleanItem[] = [];
      for (const e of all) {
        if (e.name.startsWith('.')) {
          continue; // 隐藏目录（内核 .tmp 兜底等）不进清理列表
        }
        const isDir: boolean = e.kind === EntryKind.Directory;
        const size: number = isDir ? this.dirSize(e.id, [500]) : Number(e.size);
        out.push({
          id: e.id,
          name: e.name,
          size: size,
          isDir: isDir,
          modified: e.modifiedMs === undefined ? 0 : Number(e.modifiedMs)
        });
      }
      out.sort((a: CleanItem, b: CleanItem) => b.size - a.size);
      this.items = out;
      this.loaded = true;
      this.error = '';
    } catch (e) {
      this.error = this.tt('cl.scanFailed') + '：' + errText(e);
    }
  }

  private doDelete(): void {
    if (this.core === null) {
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
        Text(this.tt('cl.hint'))
          .fontSize(T_SECONDARY)
          .fontColor(this.th().onSurfaceVariant)
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, bottom: SPACE2 })

        if (!this.loaded) {
          Column() {
            LoadingProgress().width(36).height(36)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else if (this.items.length === 0) {
          Column({ space: 6 }) {
            Text(this.tt('cl.empty')).fontSize(15).fontColor(this.th().onSurfaceVariant)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else {
          List() {
            ForEach(this.items, (it: CleanItem) => {
              ListItem() {
                Row({ space: SPACE3 }) {
                  FileIcon({ name: it.name, isDir: it.isDir, dark: this.dark, box: 32 })
                  Column({ space: 2 }) {
                    Text(it.name).fontSize(T_FILENAME).fontColor(this.th().onSurface)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Text(`${formatBytes(it.size)}${it.modified > 0 ? ' · ' + formatDate(it.modified) : ''}`)
                      .fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant).width('100%')
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  Text(this.tt('common.delete')).fontSize(T_BODY).fontColor(this.th().error)
                }
                .width('100%')
                .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE3, bottom: SPACE3 })
                .onClick(() => {
                  this.targetId = it.id;
                  this.targetName = it.name;
                  this.confirming = true;
                })
              }
            }, (it: CleanItem) => it.id)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 68 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)

      if (this.confirming) {
        Column() {
          Blank().layoutWeight(1).onClick(() => this.confirming = false)
          Column({ space: SPACE3 }) {
            Text(this.tt('cl.deleteTitle', this.targetName)).fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor(this.th().onSurface)
            Text(this.tt('cl.deleteWarn')).fontSize(T_BODY).fontColor(this.th().onSurfaceVariant)
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
