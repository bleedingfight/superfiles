package com.superfiles.app.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Android
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DiscFull
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FontDownload
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderZip
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.InsertDriveFile
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.PlaylistPlay
import androidx.compose.material.icons.filled.Shortcut
import androidx.compose.material.icons.filled.Slideshow
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.TextSnippet
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
            EntryKind.DIRECTORY -> Icons.Default.Folder
            EntryKind.SYMLINK -> Icons.Default.Shortcut
            EntryKind.SPECIAL -> Icons.Default.InsertDriveFile
            EntryKind.FILE ->
                SPECIALS[extOf(entry.name)]
                    ?: categoryOf(entry.mime)
                    ?: Icons.Default.InsertDriveFile
        }

    private fun extOf(name: String): String {
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) "" else name.substring(dot + 1).lowercase()
    }

    private fun categoryOf(mime: String?): ImageVector? =
        when {
            mime == null -> null
            mime.startsWith("image/") -> Icons.Default.Image
            mime.startsWith("video/") -> Icons.Default.Movie
            mime.startsWith("audio/") -> Icons.Default.AudioFile
            mime.startsWith("text/") -> Icons.Default.TextSnippet
            else -> null
        }

    // docs/05-icons.md 特化表
    private val SPECIALS: Map<String, ImageVector> =
        buildMap {
            put("pdf", Icons.Default.PictureAsPdf)
            put("doc", Icons.Default.Article); put("docx", Icons.Default.Article)
            put("xls", Icons.Default.TableChart); put("xlsx", Icons.Default.TableChart)
            put("csv", Icons.Default.TableChart)
            put("ppt", Icons.Default.Slideshow); put("pptx", Icons.Default.Slideshow)
            for (e in listOf("zip", "rar", "7z", "tar", "gz", "xz", "bz2")) {
                put(e, Icons.Default.FolderZip)
            }
            put("apk", Icons.Default.Android)
            put("exe", Icons.Default.Terminal)
            put("dmg", Icons.Default.DiscFull); put("iso", Icons.Default.DiscFull)
            put("epub", Icons.Default.MenuBook); put("mobi", Icons.Default.MenuBook)
            put("json", Icons.Default.Code); put("xml", Icons.Default.Code)
            put("html", Icons.Default.Code)
            put("srt", Icons.Default.Subtitles); put("ass", Icons.Default.Subtitles)
            put("vtt", Icons.Default.Subtitles)
            put("m3u", Icons.Default.PlaylistPlay); put("m3u8", Icons.Default.PlaylistPlay)
            put("ttf", Icons.Default.FontDownload); put("otf", Icons.Default.FontDownload)
            put("woff", Icons.Default.FontDownload); put("woff2", Icons.Default.FontDownload)
            put("torrent", Icons.Default.Download)
        }
}
