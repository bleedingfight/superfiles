import Foundation

/// 间距刻度（4 基栅）与组件固定尺寸。规则见 docs/06-design-system.md §2——
/// 只允许取以下值，改这里时同步改 Android 的 Dimens.kt。
enum Spacing {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    /// FileRow 图标槽宽度
    static let rowIconSlot: CGFloat = 28

    /// EmptyState 弱化图标尺寸（docs/06-design-system.md §4）
    static let emptyIconSize: CGFloat = 40

    // 圆角刻度（tokens.json radius；docs/06 §2.5）
    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 14
    static let radiusL: CGFloat = 20
    static let radiusPill: CGFloat = 999
}
