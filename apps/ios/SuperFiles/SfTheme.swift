import SwiftUI
import UIKit

/// iOS 侧设计系统实现。唯一真相源是 `design/tokens.json`（docs/06），
/// 本文件与 Android 的 `Colors.kt` / `Dimens.kt` 一一对应——改这里必须先改 tokens。
///
/// 颜色用 `UIColor(dynamicProvider:)` 做浅/深色切换，避免每个视图都传 colorScheme。
enum Sf {
    // MARK: 色彩（浅色 = Figma 实测基线；深色 = tokens.json dark 段）

    static let surface = dynamic(0xF8F7F4, 0x1A1916)
    static let surfaceCard = dynamic(0xFFFFFF, 0x26231F)
    static let surfaceTint = dynamic(0xEAF0F8, 0x22324A)
    static let primary = dynamic(0x466DA6, 0xA9C3E6)
    static let primaryWarm = dynamic(0xA18460, 0xC7A87F)
    static let success = dynamic(0x6F8D7D, 0x9CB8A9)
    static let onSurface = dynamic(0x292E35, 0xE7E5E1)
    static let onSurfaceVariant = dynamic(0x777D86, 0xA0A5AD)
    static let outline = dynamic(0xA4A8AE, 0x6A7078)
    static let error = dynamic(0xB3261E, 0xF2B8B5)

    static let searchFieldBg = dynamic(0xF0EFEB, 0x26231F)
    static let avatarBg = dynamic(0xF0EBE3, 0x33291F)
    static let usageDeep = dynamic(0x304D76, 0xD3E2F4)
    static let usageTrack = dynamic(0xD8E1ED, 0x3B4148)
    static let usageSegDocs = dynamic(0x8CA6C8, 0x7E98B9)
    static let usageSegOther = dynamic(0xB4C0CF, 0x8E939A)

    static let pdfBadgeBg = dynamic(0xF6ECE8, 0x3B2925)
    static let pdfBadgeFg = dynamic(0xB7796E, 0xD9A198)
    static let sheetBadgeBg = dynamic(0xEDF2ED, 0x26332A)
    static let docBadgeBg = dynamic(0xEAF0F8, 0x22324A)

    // MARK: 字体（docs/06 §3）

    static let appBarFont = Font.system(size: 17, weight: .bold)
    static let fileNameFont = Font.system(size: 14, weight: .medium)
    static let metaFont = Font.system(size: 11, weight: .regular)
    static let cardTitleFont = Font.system(size: 12, weight: .medium)
    static let emptyTitleFont = Font.system(size: 15, weight: .medium)
    static let emptyBodyFont = Font.system(size: 13, weight: .regular)
    static let footerFont = Font.system(size: 10, weight: .regular)

    // MARK: 尺寸

    static let safeMargin: CGFloat = 24
    static let rowHeight: CGFloat = 74
    static let badgeWidth: CGFloat = 46
    static let badgeHeight: CGFloat = 50
    static let badgeCorner: CGFloat = 10
}

/// 16 进制 → 随系统外观切换的动态色。
private func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(uiColor: UIColor { trait in
        UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
    })
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
