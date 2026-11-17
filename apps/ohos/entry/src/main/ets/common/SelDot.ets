import { theme, Palette } from './Tokens';

/**
 * iOS 风格多选圆圈：未选中 = 灰色空心圆环；选中 = 主题色实心圆 + 白色对勾。
 * 用于长按/「选择」进入多选后，行左侧的选中指示。
 */
@Component
export struct SelDot {
  @Prop selected: boolean;
  @Prop dark: boolean = false;
  @Prop dot: number = 22;

  private th(): Palette {
    return theme(this.dark);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Circle()
        .width(this.dot)
        .height(this.dot)
        .fill(this.selected ? this.th().primary : Color.Transparent)
        .stroke(this.selected ? this.th().primary : this.th().outline)
        .strokeWidth(2)
      if (this.selected) {
        Text('✓')
          .fontSize(this.dot * 0.6)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
      }
    }
    .width(this.dot + 10)
    .height(this.dot + 10)
  }
}
