import { theme, RADIUS_S } from './Tokens';

/**
 * 品牌按钮体系（对齐 docs/06-design-system.md §对话框（品牌风），与 Android 侧
 * PrimaryConfirmButton / SafeCancelButton 一一对应）：
 *
 * - SfPrimaryButton   主操作：实心 primary + onPrimary
 * - SfSecondaryButton 次操作：浅底 searchFieldBg + onSurface
 *
 * 页面新代码不手写 Button 的 backgroundColor/fontColor 组合，一律用这两个组件，
 * 避免样式漂移（danger 态仍走页面既有红底惯例，待设计定稿后补 SfDangerButton）。
 */

@Component
export struct SfPrimaryButton {
  @Prop label: string = '';
  @Prop full: boolean = true;
  @Prop btnHeight: number = 40;
  @StorageLink('sfDark') dark: boolean = false;
  private onAction: () => void = (): void => {};

  build() {
    Button(this.label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .height(this.btnHeight)
      .width(this.full ? '100%' : 'auto')
      .backgroundColor(theme(this.dark).primary)
      .fontColor(theme(this.dark).onPrimary)
      .borderRadius(RADIUS_S)
      .onClick(() => this.onAction())
  }
}

@Component
export struct SfSecondaryButton {
  @Prop label: string = '';
  @Prop full: boolean = true;
  @Prop btnHeight: number = 36;
  @StorageLink('sfDark') dark: boolean = false;
  private onAction: () => void = (): void => {};

  build() {
    Button(this.label)
      .fontSize(13)
      .height(this.btnHeight)
      .width(this.full ? '100%' : 'auto')
      .backgroundColor(theme(this.dark).searchFieldBg)
      .fontColor(theme(this.dark).onSurface)
      .borderRadius(RADIUS_S)
      .onClick(() => this.onAction())
  }
}
