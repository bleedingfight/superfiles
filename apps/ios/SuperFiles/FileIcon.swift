import Foundation

/// Entry → SF Symbol 映射。规则见 docs/05-icons.md——两端必须同表，
/// 改这里时同步改 Android 的 FileIcon.kt。
enum FileIcon {
    static func symbolName(for entry: Entry) -> String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink: return "link"
        case .special: return "doc"
        case .file: break
        }

        if let special = specials[ext(of: entry.name)] {
            return special
        }
        if let mime = entry.mime {
            if mime.hasPrefix("image/") { return "photo" }
            if mime.hasPrefix("video/") { return "film" }
            if mime.hasPrefix("audio/") { return "music.note" }
            if mime.hasPrefix("text/") { return "doc.text" }
        }
        return "doc"
    }

    private static func ext(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    // docs/05-icons.md 特化表
    private static let specials: [String: String] = [
        "pdf": "doc.richtext",
        "doc": "doc.text.fill", "docx": "doc.text.fill",
        "xls": "tablecells", "xlsx": "tablecells", "csv": "tablecells",
        "ppt": "play.rectangle", "pptx": "play.rectangle",
        "zip": "doc.zipper", "rar": "doc.zipper", "7z": "doc.zipper",
        "tar": "doc.zipper", "gz": "doc.zipper", "xz": "doc.zipper", "bz2": "doc.zipper",
        "apk": "shippingbox",
        "exe": "terminal",
        "dmg": "opticaldisc", "iso": "opticaldisc",
        "epub": "book", "mobi": "book",
        "json": "curlybraces", "xml": "curlybraces", "html": "curlybraces",
        "srt": "captions.bubble", "ass": "captions.bubble", "vtt": "captions.bubble",
        "m3u": "play.rectangle.on.rectangle", "m3u8": "play.rectangle.on.rectangle",
        "ttf": "textformat", "otf": "textformat", "woff": "textformat", "woff2": "textformat",
        "torrent": "arrow.down.circle",
    ]
}
