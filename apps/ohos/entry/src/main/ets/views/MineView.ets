import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import { SuperFiles } from '@superfiles/core';
import { deviceInfo } from '@kit.BasicServicesKit';
import { getCore } from '../common/Core';
import { enqueueScan } from '../common/ScanCenter';
import { errText, formatBytes } from '../common/Format';
import { t } from '../common/L10n';
import { avatarCharOf } from '../common/Avatar';
import { saveShowHidden, saveNick } from '../common/Settings';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_PILL,
  SPACE1, SPACE2, SPACE3, SPACE4, SPACE8, T_BODY, T_SECONDARY
} from '../common/Tokens';

/**
 * 「我的」— 结构对齐 Android MineScreen.kt：
 * 大标题 → 资料卡 → [存储] 存储清理/索引/重建/显示隐藏 → [传输] 传输记录/互传 → [关于] 版本/许可/诊断
 * 网络存储已独立到 NetworkStorage 页（首页「管理」进入）。
 */
@Component
export struct MineView {
  @State version: string = '';
  @State indexCount: number = 0;
  @State indexBytes: number = 0;
  @State msg: string = '';
  @State error: string = '';
  @State showLicenses: boolean = false;
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfNick') nick: string = '';
  @StorageLink('sfShowHidden') showHidden: boolean = false;
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
      this.version = this.core.version();
      this.reloadIndex();
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
    }
  }

  private reloadIndex(): void {
    if (this.core === null) {
      return;
    }
    try {
      this.indexCount = Number(this.core.indexCount());
      this.indexBytes = 0;
    } catch (e) {
      // ignore
    }
  }

  /**
   * 导出诊断（时间/版本/设备/索引统计/挂载与传输概况）。
   * 沙箱对用户不可见，因此走系统「另存为」（DocumentSavePicker）选目的地；
   * 选择器不可用时兜底落应用 files 目录。
   */
  private async exportDiagnostics(): Promise<void> {
    if (this.core === null) {
      this.error = this.tt('common.coreNotReady');
      return;
    }
    const core: SuperFiles = this.core;
    const content: string = this.buildDiagText(core);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: Array<string> = await savePicker.save({ newFileNames: ['superfiles_diagnostics.txt'] });
      if (uris.length === 0) {
        return; // 用户取消，不打扰
      }
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, content);
      fileIo.closeSync(f);
      this.msg = this.tt('mine.diagnosticsDone', uris[0]);
      this.error = '';
      return;
    } catch (e) {
      // 另存为不可用（无 Selected 框架/异常）：退回沙箱落盘，路径随提示给出
      try {
        const path: string = `${ctx.filesDir}/diagnostics.txt`;
        const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, content);
        fileIo.closeSync(f);
        this.msg = this.tt('mine.diagnosticsDone', path);
        this.error = '';
      } catch (e2) {
        this.error = errText(e);
      }
    }
  }

  /** 诊断正文：时间/版本/设备/索引/挂载/传输概况。 */
  private buildDiagText(core: SuperFiles): string {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const lines: string[] = [];
    lines.push(`Super Files 诊断 · ${new Date().toLocaleString()}`);
    lines.push(`App: v${this.version} (${ctx.applicationInfo.name})`);
    lines.push(`Device: ${deviceInfo.productModel} / ${deviceInfo.osFullName} / API ${deviceInfo.sdkApiVersion}`);
    lines.push(`Index: ${Number(core.indexCount())} entries`);
    let mountsText: string = '';
    try {
      for (const m of core.mounts()) {
        mountsText += `\n  - ${m.label} (${m.scheme}) ${m.rootId}`;
      }
    } catch (e) {
      mountsText = ' (unavailable)';
    }
    lines.push(`Mounts:${mountsText.length > 0 ? mountsText : ' none'}`);
    let transfersText: string = '';
    try {
      let n: number = 0;
      for (const trs of core.transfers()) {
        n++;
      }
      transfersText = ` ${n} in-memory`;
    } catch (e) {
      transfersText = ' unavailable';
    }
    lines.push(`Transfers:${transfersText}`);
    return lines.join('\n');
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(T_SECONDARY)
      .fontColor(this.th().onSurfaceVariant)
      .width('100%')
      .padding({ top: SPACE2, bottom: SPACE1 })
  }

  @Builder
  settingRow(glyph: string, title: string, subtitle: string, trailing: string,
    showSwitch: boolean, onClick: () => void) {
    Row({ space: SPACE3 }) {
      Text(glyph).fontSize(16).width(24).textAlign(TextAlign.Center)
      Column({ space: 1 }) {
        Text(title).fontSize(T_BODY).fontColor(this.th().onSurface).width('100%')
        if (subtitle.length > 0) {
          Text(subtitle).fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant).width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (showSwitch) {
        Toggle({ type: ToggleType.Switch, isOn: this.showHidden })
          .selectedColor(this.th().primary)
          .onChange((on: boolean) => {
            this.showHidden = on;
            saveShowHidden(this.getUIContext().getHostContext() as common.UIAbilityContext, on);
          })
      } else if (trailing.length > 0) {
        Text(trailing).fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant)
      }
      if (!showSwitch && trailing.length === 0) {
      }
    }
    .width('100%')
    .padding({ top: SPACE3, bottom: SPACE3 })
    .onClick(onClick)
  }

  @Builder
  licensesOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.showLicenses = false)
      Column({ space: SPACE2 }) {
        Text(this.tt('mine.licenses')).fontSize(17).fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface).width('100%')
        Scroll() {
          Text(this.tt('mine.licensesText'))
            .fontSize(12)
            .fontColor(this.th().onSurfaceVariant)
            .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        Button(this.tt('common.close'))
          .width('100%')
          .height(40)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => this.showLicenses = false)
      }
      .width('100%')
      .height('60%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll() {
        Column({ space: SPACE3 }) {
          Text(this.tt('tab.mine'))
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().onSurface)
            .width('100%')
            .padding({ top: SPACE2 })

          // 资料卡
          Row({ space: SPACE3 }) {
            Column() {
              Text(avatarCharOf(this.nick))
                .fontSize(20)
                .fontColor(this.th().primary)
            }
            .width(52)
            .height(52)
            .borderRadius(RADIUS_PILL)
            .backgroundColor(this.th().avatarBg)
            .justifyContent(FlexAlign.Center)

            Column({ space: 4 }) {
              TextInput({ text: this.nick, placeholder: this.tt('mine.nickPlaceholder') })
                .height(32)
                .fontSize(15)
                .backgroundColor(Color.Transparent)
                .padding(0)
                .onChange((v: string) => {
                  this.nick = v;
                  saveNick(this.getUIContext().getHostContext() as common.UIAbilityContext, v);
                })
              Text(this.tt('mine.versionIndex', this.version, `${this.indexCount}`))
                .fontSize(T_SECONDARY)
                .fontColor(this.th().onSurfaceVariant)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(SPACE4)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_L)

          if (this.error.length > 0) {
            Text(this.error).fontSize(T_BODY).fontColor(this.th().error).width('100%')
          }
          if (this.msg.length > 0) {
            Text(this.msg).fontSize(T_BODY).fontColor(this.th().success).width('100%')
          }

          // ---- 存储 ---------------------------------------------------------
          this.sectionTitle(this.tt('mine.storage'))
          Column({ space: SPACE1 }) {
            this.settingRow('🧹', this.tt('mine.cleanup'), '', '', false,
              () => router.pushUrl({ url: 'pages/Cleanup' }))
            Divider().color(this.th().divider).margin({ left: 40 })
            this.settingRow('📇', this.tt('mine.indexManage'), this.tt('mine.indexManageHint'), '', false,
              () => router.pushUrl({ url: 'pages/IndexManage' }))
            Divider().color(this.th().divider).margin({ left: 40 })
            this.settingRow('👁', this.tt('mine.showHidden'), '', '', true, () => {
            })
          }
          .width('100%')
          .padding({ left: SPACE4, right: SPACE4 })
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_L)

          // ---- 传输 ---------------------------------------------------------
          this.sectionTitle(this.tt('tr.title'))
          Column({ space: SPACE1 }) {
            this.settingRow('⇅', this.tt('mine.transfers'), '', '', false,
              () => router.pushUrl({ url: 'pages/TransfersPage' }))
            Divider().color(this.th().divider).margin({ left: 40 })
            this.settingRow('⇄', this.tt('mine.localsend'), this.tt('mine.localsendProto'), '', false,
              () => router.pushUrl({ url: 'pages/LocalSendPage' }))
          }
          .width('100%')
          .padding({ left: SPACE4, right: SPACE4 })
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_L)

          // ---- 关于 ---------------------------------------------------------
          this.sectionTitle(this.tt('mine.about'))
          Column({ space: SPACE1 }) {
            this.settingRow('ℹ', this.tt('mine.version'), '', `v${this.version}`, false, () => {
            })
            Divider().color(this.th().divider).margin({ left: 40 })
            this.settingRow('📜', this.tt('mine.licenses'), '', '', false,
              () => this.showLicenses = true)
            Divider().color(this.th().divider).margin({ left: 40 })
            this.settingRow('🩺', this.tt('mine.diagnostics'), '', '', false,
              () => this.exportDiagnostics())
          }
          .width('100%')
          .padding({ left: SPACE4, right: SPACE4 })
          .backgroundColor(this.th().surfaceCard)
          .borderRadius(RADIUS_L)

          Text('').height(SPACE8)
        }
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, bottom: 24 })
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)
      .scrollBar(BarState.Off)

      if (this.showLicenses) {
        this.licensesOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
