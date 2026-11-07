package com.superfiles.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.superfiles.core.Capabilities
import com.superfiles.core.Entry
import com.superfiles.core.EntryKind
import com.superfiles.core.SuperFiles
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class BrowserState(
    val rootId: String = "",
    val currentId: String = "",
    val title: String = "",
    val entries: List<Entry> = emptyList(),
    val capabilities: Capabilities? = null,
    val canGoUp: Boolean = false,
    val loading: Boolean = false,
    val error: String? = null,
    val indexedCount: Long = 0,
    val searchQuery: String = "",
)

/**
 * M0 view model: browse the app private storage through the Rust core.
 *
 * Every core call is blocking by design (see `crates/sfiles-ffi`), so it is
 * dispatched to `Dispatchers.IO`; the UI thread never touches the core.
 */
class VfsViewModel(application: Application) : AndroidViewModel(application) {

    private val core: SuperFiles = run {
        val root = File(application.filesDir, "storage").apply { mkdirs() }
        val index = File(application.filesDir, "index.sqlite")
        SuperFiles.open(root.absolutePath, index.absolutePath)
    }

    private val _state = MutableStateFlow(BrowserState(rootId = core.rootId()))
    val state = _state.asStateFlow()

    private val history = ArrayDeque<String>()

    init {
        load(core.rootId())
    }

    fun openEntry(entry: Entry) {
        if (entry.kind != EntryKind.DIRECTORY) return
        history.addLast(_state.value.currentId)
        load(entry.id)
    }

    fun goUp() {
        val previous = history.removeLastOrNull() ?: return
        load(previous)
    }

    fun refresh() = load(_state.value.currentId.ifEmpty { core.rootId() })

    fun search(rawQuery: String) {
        _state.update { it.copy(searchQuery = rawQuery) }
        if (rawQuery.isBlank()) {
            refresh()
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            val result = withContext(Dispatchers.IO) { runCatching { core.search(rawQuery, 200u) } }
            result
                .onSuccess { hits ->
                    _state.update {
                        it.copy(
                            loading = false,
                            entries = hits,
                            title = "搜索：$rawQuery",
                            error = null,
                        )
                    }
                }
                .onFailure(::report)
        }
    }

    fun createFolder(name: String) {
        val parent = _state.value.currentId
        if (name.isBlank()) return
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { core.createDir(parent, name) } }
            result.onSuccess { load(parent) }.onFailure(::report)
        }
    }

    fun delete(entry: Entry) {
        val parent = _state.value.currentId
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { core.remove(entry.id, entry.kind == EntryKind.DIRECTORY) }
            }
            result.onSuccess { load(parent) }.onFailure(::report)
        }
    }

    /** Walk the whole tree into SQLite so search works offline. */
    fun indexEverything() {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    core.indexDir(core.rootId())
                    core.indexCount().toLong()
                }
            }
            result
                .onSuccess { count -> _state.update { it.copy(indexedCount = count) } }
                .onFailure(::report)
        }
    }

    fun dismissError() {
        _state.update { it.copy(error = null) }
    }

    private fun load(id: String) {
        viewModelScope.launch {
            _state.update { it.copy(loading = true, error = null) }
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val entries = core.list(id)
                    val caps = core.capabilities(id)
                    val path = core.displayPath(id)
                    Triple(entries, caps, path)
                }
            }
            result
                .onSuccess { (entries, caps, path) ->
                    _state.update {
                        it.copy(
                            loading = false,
                            currentId = id,
                            entries = entries,
                            capabilities = caps,
                            canGoUp = history.isNotEmpty(),
                            title = path,
                            error = null,
                        )
                    }
                }
                .onFailure(::report)
        }
    }

    private fun report(error: Throwable) {
        _state.update {
            it.copy(loading = false, error = error.message ?: error::class.simpleName ?: "未知错误")
        }
    }
}
