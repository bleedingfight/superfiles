package com.superfiles.app.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Android
import androidx.compose.material.icons.outlined.Article
import androidx.compose.material.icons.outlined.AudioFile
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.DiscFull
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.FontDownload
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.MenuBook
import androidx.compose.material.icons.outlined.Movie
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material.icons.outlined.PlaylistPlay
import androidx.compose.material.icons.outlined.Shortcut
import androidx.compose.material.icons.outlined.Slideshow
import androidx.compose.material.icons.outlined.Subtitles
import androidx.compose.material.icons.outlined.TableChart
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.TextSnippet
import androidx.compose.ui.graphics.vector.ImageVector
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind

/**
 * Entry → Material 图标映射。规则见 docs/05-icons.md——两端必须同表，
 * 改这里时同步改 iOS 的 FileIcon.swift。
 */
object FileIcon {
    fun of(entry: Entry): ImageVector =
        when (entry.kind) {
            EntryKind.DIRECTORY -> Icons.Outlined.Folder
            EntryKind.SYMLINK -> Icons.Outlined.Shortcut
            EntryKind.SPECIAL -> Icons.Outlined.InsertDriveFile
            EntryKind.FILE ->
                SPECIALS[extOf(entry.name)]
                    ?: categoryOf(entry.mime)
                    ?: Icons.Outlined.InsertDriveFile
        }

    private fun extOf(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) "" else name.substring(dot + 1).lowercase()
    }

    private fun categoryOf(mime: String?): ImageVector? =
        when {
            mime == null -> null
            mime.startsWith("image/") -> Icons.Outlined.Image
            mime.startsWith("video/") -> Icons.Outlined.Movie
            mime.startsWith("audio/") -> Icons.Outlined.AudioFile
            mime.startsWith("text/") -> Icons.Outlined.TextSnippet
            else -> null
        }

    // docs/05-icons.md 特化表
    private val SPECIALS: Map<String, ImageVector> =
        buildMap {
            put("pdf", Icons.Outlined.PictureAsPdf)
            put("doc", Icons.Outlined.Article); put("docx", Icons.Outlined.Article)
            put("xls", Icons.Outlined.TableChart); put("xlsx", Icons.Outlined.TableChart)
            put("csv", Icons.Outlined.TableChart)
            put("ppt", Icons.Outlined.Slideshow); put("pptx", Icons.Outlined.Slideshow)
            for (e in listOf("zip", "rar", "7z", "tar", "gz", "xz", "bz2")) {
                put(e, Icons.Outlined.FolderZip)
            }
            put("apk", Icons.Outlined.Android)
            put("exe", Icons.Outlined.Terminal)
            put("dmg", Icons.Outlined.DiscFull); put("iso", Icons.Outlined.DiscFull)
            put("epub", Icons.Outlined.MenuBook); put("mobi", Icons.Outlined.MenuBook)
            put("json", Icons.Outlined.Code); put("xml", Icons.Outlined.Code)
            put("html", Icons.Outlined.Code)
            put("srt", Icons.Outlined.Subtitles); put("ass", Icons.Outlined.Subtitles)
            put("vtt", Icons.Outlined.Subtitles)
            put("m3u", Icons.Outlined.PlaylistPlay); put("m3u8", Icons.Outlined.PlaylistPlay)
            put("ttf", Icons.Outlined.FontDownload); put("otf", Icons.Outlined.FontDownload)
            put("woff", Icons.Outlined.FontDownload); put("woff2", Icons.Outlined.FontDownload)
            put("torrent", Icons.Outlined.Download)
        }
}
