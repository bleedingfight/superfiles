import { closeCore } from '../common/Core';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { theme, Palette } from '../common/Tokens';
import { t } from '../common/L10n';
import { HomeView } from '../views/HomeView';
import { FilesView } from '../views/FilesView';
import { MineView } from '../views/MineView';
import { TransferOverlay } from '../views/TransferOverlay';

@Entry
@Component
struct Index {
  @StorageLink('sfTab') currentTab: number = 0;
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfOpenLocalSend') @Watch('openLocalSendPage') openLsReq: number = 0;

  /** 深链（组网码）到达时自动进入近邻传输页（页面已在栈顶则不重复压栈）。 */
  openLocalSendPage(): void {
    if (this.openLsReq !== 1) {
      return;
    }
    this.openLsReq = 0;
    const top: string = router.getState().path;
    if (top !== 'pages/LocalSendPage') {
      router.pushUrl({ url: 'pages/LocalSendPage' });
    }
  }

  aboutToAppear(): void {
    // 冷启动即带深链时 @Watch 不触发，补一次
    this.openLocalSendPage();
  }

  private th(): Palette {
    return theme(this.dark);
  }

  aboutToDisappear(): void {
    closeCore();
  }

  /**
   * 系统返回手势/返回键：优先让文件页逐层回退（弹窗 → 多选 → 上级目录），
   * 其次切回首页，最后才允许退出应用。
   */
  onBackPress(): boolean {
    // 传输浮层模态显示时，返回不打断传输
    const overlay: boolean = AppStorage.get<boolean>('sfTransferOverlay') ?? false;
    if (overlay) {
      return true;
    }
    const back: string = AppStorage.get<string>('sfBack') ?? 'none';
    hilog.info(0x0000, 'SuperFiles', 'onBackPress tab=%{public}d back=%{public}s', this.currentTab, back);
    if (this.currentTab === 1 && back !== 'none') {
      const n: number = AppStorage.get<number>('sfBackRequest') ?? 0;
      AppStorage.setOrCreate('sfBackRequest', n + 1);
      return true;
    }
    if (this.currentTab !== 0) {
      this.currentTab = 0;
      return true;
    }
    return false;
  }

  @Builder
  tabItem(label: string, glyph: string, index: number) {
    Column({ space: 2 }) {
      Text(glyph)
        .fontSize(18)
        .fontColor(this.currentTab === index ? this.th().primary : this.th().outline)
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? this.th().primary : this.th().outline)
    }
    .layoutWeight(1)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.currentTab = index)
  }

  build() {
    Stack() {
      Column() {
        // 内容区：条件渲染（不用 Tabs，避免它的整页横滑抢走列表行的 swipeAction 手势）
        Stack() {
          if (this.currentTab === 0) {
            HomeView()
          } else if (this.currentTab === 1) {
            FilesView()
          } else {
            MineView()
          }
        }
        .layoutWeight(1)
        .width('100%')

        // 底部导航
        Row() {
          this.tabItem(t(this.sysLang, 'tab.home'), '⌂', 0)
          this.tabItem(t(this.sysLang, 'tab.files'), '▤', 1)
          this.tabItem(t(this.sysLang, 'tab.mine'), '◍', 2)
        }
        .width('100%')
        .height(56)
        .backgroundColor(this.th().surfaceCard)
        .border({ width: { top: 0.5 }, color: this.th().divider })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)

      // 前台传输浮层（复制/移动进度，全 App 模态）
      TransferOverlay()
    }
    .width('100%')
    .height('100%')
  }
}
