package com.superfiles.app.core

import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 解码内核的紧凑 Entry 字节流（[com.superfiles.core.SuperFiles.listByExtsPacked]）。
 *
 * 为什么不直接返回 `List<Entry>`：uniffi 的 `Vec<Entry>` 会对每个字符串各做
 * 一次 JNA 调用。实测 9000 条图片结果 360ms，而索引 SQL 本身只有 11ms。
 * 紧凑字节流只跨一次边界，解析在本进程内完成。
 *
 * 格式（小端）：u32 count，然后每条：
 * u8 kind / u8 flags / i64 size / i64 modified_ms（Long.MIN_VALUE = null）/
 * id / parent / name / mime（各为 u32 长度 + UTF-8；长度 -1 表示 null）。
 */
object PackedEntries {
    fun decode(bytes: ByteArray): List<Entry> {
        if (bytes.isEmpty()) return emptyList()
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val count = buf.int
        val out = ArrayList<Entry>(count)
        repeat(count) {
            val kind = when (buf.get().toInt()) {
                1 -> EntryKind.DIRECTORY
                2 -> EntryKind.SYMLINK
                3 -> EntryKind.SPECIAL
                else -> EntryKind.FILE
            }
            val flags = buf.get().toInt()
            val size = buf.long
            val modified = buf.long
            val id = readString(buf) ?: ""
            val parent = readString(buf)
            val name = readString(buf) ?: ""
            val mime = readString(buf)
            out += Entry(
                id = id,
                parent = parent,
                name = name,
                kind = kind,
                size = size.toULong(),
                modifiedMs = if (modified == Long.MIN_VALUE) null else modified,
                mime = mime,
                hidden = flags and 1 != 0,
                readonly = flags and 2 != 0,
            )
        }
        return out
    }

    private fun readString(buf: ByteBuffer): String? {
        val len = buf.int
        if (len < 0) return null
        val bytes = ByteArray(len)
        buf.get(bytes)
        return String(bytes, Charsets.UTF_8)
    }
}
