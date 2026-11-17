import { router } from '@kit.ArkUI';
import { TransfersView } from '../views/TransfersView';
import { theme, Palette, SCREEN_MARGIN, T_APPBAR } from '../common/Tokens';
import { t } from '../common/L10n';

@Entry
@Component
struct TransfersPage {
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';

  /** 多选态下返回先退出多选；否则允许弹出本页（回上级）。 */
  onBackPress(): boolean {
    const sel: boolean = AppStorage.get<boolean>('sfTrSel') ?? false;
    if (sel) {
      const n: number = AppStorage.get<number>('sfTrSelExit') ?? 0;
      AppStorage.setOrCreate('sfTrSelExit', n + 1);
      return true;
    }
    return false;
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button('‹')
          .fontSize(22)
          .width(38)
          .height(38)
          .backgroundColor(theme(this.dark).searchFieldBg)
          .fontColor(theme(this.dark).onSurface)
          .onClick(() => router.back())
        Text(t(this.sysLang, 'pg.transfers')).fontSize(T_APPBAR).fontWeight(FontWeight.Bold)
          .fontColor(theme(this.dark).onSurface)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 4 })

      TransfersView({ embedded: true })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(theme(this.dark).surface)
  }
}
