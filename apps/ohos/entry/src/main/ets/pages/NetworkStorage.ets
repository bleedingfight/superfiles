import { router } from '@kit.ArkUI';
import { NetworkView } from '../views/NetworkView';
import { theme, Palette, SCREEN_MARGIN, T_APPBAR } from '../common/Tokens';
import { t } from '../common/L10n';

@Entry
@Component
struct NetworkStorage {
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';

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
        Text(t(this.sysLang, 'home.networkStorage'))
          .fontSize(T_APPBAR)
          .fontWeight(FontWeight.Bold)
          .fontColor(theme(this.dark).onSurface)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 4 })

      NetworkView()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(theme(this.dark).surface)
  }
}
