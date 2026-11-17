import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import {
  ConflictPolicy,
  Entry,
  EntryKind,
  FavoriteEntry,
  MountInfo,
  RecentOpen,
  ShareInfo,
  SuperFiles,
  TransferSnapshot,
  TransferState,
  ZipMethod
} from '@superfiles/core';
import { getCore } from '../common/Core';
import { openEntryExternal } from '../common/OpenExternal';
import { ensureMountedForId } from '../common/MountOps';
import { formatBytes, formatDate , errText} from '../common/Format';
import { FileIcon } from '../common/FileIcon';
import { SelDot } from '../common/SelDot';
import { saveShowHidden } from '../common/Settings';
import { PreviewView, isMediaName } from '../components/PreviewView';
import { mediaquery } from '@kit.ArkUI';
import { t } from '../common/L10n';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { theme, Palette, SCREEN_MARGIN, RADIUS_S, RADIUS_M, RADIUS_PILL, SPACE1, SPACE2, SPACE3, SPACE4, T_BODY, T_APPBAR, T_SECONDARY, T_FILENAME } from '../common/Tokens';

interface Crumb {
  id: string;
  name: string;
}

interface PreviewParams {
  ids: string[];
  names: string[];
  mimes: string[];
  sizes: number[];
  mods: number[];
  index: number;
}

const MODE_BROWSE: string = 'browse';
const MODE_FAVORITES: string = 'favorites';
const MODE_RECENT: string = 'recent';
const MODE_SEARCH: string = 'search';
const MODE_CATEGORY: string = 'category';

const SHEET_NONE: string = 'none';
const SHEET_ENTRY: string = 'entry';
const SHEET_NEW: string = 'new';
const SHEET_RENAME: string = 'rename';
const SHEET_DELETE: string = 'delete';
const SHEET_ZIP: string = 'zip';
const SHEET_DETAILS: string = 'details';
const SHEET_SHARE: string = 'share';
const SHEET_CONFLICT: string = 'conflict';
const SHEET_MORE: string = 'more';
const SHEET_SORT: string = 'sort';

const SORT_NAME: string = 'name';
const SORT_TIME: string = 'time';
const SORT_SIZE: string = 'size';

@Component
export struct FilesView {
  @State entries: Entry[] = [];
  @State crumbs: Crumb[] = [];
  @State mounts: MountInfo[] = [];
  @State mode: string = MODE_BROWSE;
  @State query: string = '';
  @State loading: boolean = false;
  @State error: string = '';
  @State notice: string = '';
  @State sheet: string = SHEET_NONE;
  @State input: string = '';
  @State title: string = '';
  @State titleKey: string = 'files.thisDevice';

  // selection
  @State selecting: boolean = false;
  @State selected: string[] = [];

  // list options
  @State sortKey: string = SORT_NAME;
  @State sortAsc: boolean = true;
  /** 跨源结果集默认按数据源聚组（本机最前），组内按 sortKey 排序。 */
  @State groupBySource: boolean = true;
  @StorageLink('sfShowHidden') showHidden: boolean = false;
  @State typeFilter: string = 'all';
  private searchTimer: number = -1;

  // action target
  @State selId: string = '';
  @State selName: string = '';
  @State selIsDir: boolean = false;
  @State selMeta: string = '';
  @State selPath: string = '';
  @State selMime: string = '';
  @State selSize: number = 0;
  @State selModified: number = 0;

  // destination picker
  @State picking: boolean = false;
  private transferTimer: number = -1;
  @State pickMode: string = 'copy';
  @State pickCrumbs: Crumb[] = [];
  @State pickEntries: Entry[] = [];

  @State shareUrl: string = '';
  @State shareQr: image.PixelMap | null = null;
  @State wide: boolean = false;
  @State showPane: boolean = false;
  @State paneId: string = '';
  @State paneName: string = '';
  @State paneMime: string = '';
  @State paneSize: number = 0;
  @State paneModified: number = 0;
  private wideListener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(min-width: 840vp)');
  @State conflictSources: string[] = [];
  @State conflictDest: string = '';
  @State conflictMove: boolean = false;
  @StorageLink('sfImportUri') @Watch('onImportRequest') importUri: string = '';
  @StorageLink('sfImportName') importName: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfOpenId') @Watch('onOpenRequest') openId: string = '';
  @StorageLink('sfBack') backState: string = 'none';
  @StorageLink('sfCategory') @Watch('onCategoryRequest') categoryReq: string = '';
  @State catKey: string = '';
  @StorageLink('sfBackRequest') @Watch('onBackRequest') backRequest: number = 0;
  @Prop startMode: string = '';
  @Prop embedded: boolean = false;
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  /** 发布「当前还能往哪退」：sheet > 多选 > 子目录。 */
  private syncBackState(): void {
    if (this.sheet !== SHEET_NONE) {
      this.backState = 'sheet';
    } else if (this.picking) {
      this.backState = 'picking';
    } else if (this.selecting) {
      this.backState = 'selection';
    } else if (this.mode === MODE_BROWSE && this.crumbs.length > 1) {
      this.backState = 'dir';
    } else if (this.mode === MODE_CATEGORY) {
      this.backState = 'mode';
    } else if (this.mode !== MODE_BROWSE) {
      this.backState = 'mode';
    } else {
      this.backState = 'none';
    }
    hilog.info(0x0000, 'SuperFiles', 'backState=%{public}s (sheet=%{public}s sel=%{public}s crumbs=%{public}d mode=%{public}s)',
      this.backState, this.sheet, `${this.selecting}`, this.crumbs.length, this.mode);
  }

  /** 系统返回：逐层回退，而不是直接退出应用。 */
  onBackRequest(): void {
    if (this.backRequest === 0) {
      return;
    }
    if (this.sheet !== SHEET_NONE) {
      this.closeSheet();
    } else if (this.picking) {
      this.picking = false;
    } else if (this.selecting) {
      this.selecting = false;
      this.selected = [];
    } else if (this.mode === MODE_BROWSE && this.crumbs.length > 1) {
      this.goTo(this.crumbs.length - 2);
    } else if (this.mode === MODE_CATEGORY) {
      if (this.embedded) {
        this.catKey = '';
        this.crumbs = [{ id: this.core === null ? '' : this.core.rootId(), name: this.tt('files.thisDevice') }];
        this.openLocation(MODE_BROWSE, 'files.thisDevice');
      } else {
        // 分类是从首页点进来的：返回到上级 = 回首页标签
        this.catKey = '';
        this.crumbs = [{ id: this.core === null ? '' : this.core.rootId(), name: this.tt('files.thisDevice') }];
        this.mode = MODE_BROWSE;
        this.refresh();
        AppStorage.setOrCreate('sfTab', 0);
      }
    } else if (this.mode !== MODE_BROWSE) {
      this.crumbs = [{ id: this.core === null ? '' : this.core.rootId(), name: this.tt('files.thisDevice') }];
      this.openLocation(MODE_BROWSE, 'files.thisDevice');
    }
    this.syncBackState();
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  private sortLabel(): string {
    if (this.sortKey === SORT_TIME) {
      return this.tt('files.sortTime');
    }
    if (this.sortKey === SORT_SIZE) {
      return this.tt('files.sortSize');
    }
    return this.tt('files.sortName');
  }

  private typeLabel(v: string): string {
    if (v === 'image') {
      return this.tt('files.filterImage');
    }
    if (v === 'video') {
      return this.tt('files.filterVideo');
    }
    if (v === 'doc') {
      return this.tt('files.filterDoc');
    }
    if (v === 'archive') {
      return this.tt('files.filterArchive');
    }
    return this.tt('files.filterAll');
  }

  /** 首页分类入口：图片/视频/文档/音频/压缩包。 */
  onCategoryRequest(): void {
    hilog.info(0x0000, 'SuperFiles', 'onCategoryRequest req=%{public}s', this.categoryReq);
    if (this.categoryReq.length === 0) {
      return;
    }
    this.catKey = this.categoryReq;
    this.categoryReq = '';
    this.mode = MODE_CATEGORY;
    this.selecting = false;
    this.selected = [];
    this.refresh();
    this.syncBackState();
  }

  private categoryExts(key: string): string[] {
    if (key === 'image') {
      return ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'];
    }
    if (key === 'video') {
      return ['mp4', 'mkv', 'mov', 'webm', 'm4v', 'avi'];
    }
    if (key === 'docs') {
      return ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv'];
    }
    if (key === 'audio') {
      return ['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'ape', 'wv', 'aiff', 'au'];
    }
    return ['zip', '7z', 'rar', 'tar', 'gz', 'bz2', 'xz'];
  }

  /**
   * 分类聚合：查本地 SQLite 索引（ext 列，修改时间倒序，LIMIT 截断）。
   * 网络挂载默认不进索引——在我的页/挂载菜单手动「创建索引」后才出现
   * （1 亿文件的网盘不可能也不应该全量进手机索引）。
   * 已授权本机目录不在索引内，保留小预算本地直扫作为补充。
   */
  private gatherCategory(key: string): Entry[] {
    if (this.core === null) {
      return [];
    }
    const exts: string[] = this.categoryExts(key);
    const out: Entry[] = [];
    try {
      const indexed: Entry[] = this.core.listByExts(exts, 800);
      for (const e of indexed) {
        out.push(e);
      }
    } catch (e) {
      // 索引不可用：分类页显示空，不回退网络遍历
    }
    // 已授权的本机目录（DocumentViewPicker 授权，重启后失效；本地 IO 无网络时延）
    const localUri: string = AppStorage.get<string>('sfLocalUri') ?? '';
    if (localUri.length > 0) {
      this.walkLocalForCategory(localUri, exts, out, [1200]);
    }
    return out;
  }

  /** 用 fs API 遍历授权目录，把命中扩展名的文件追加到结果（id 为真实路径）。 */
  private walkLocalForCategory(dir: string, exts: string[], out: Entry[], budget: number[]): void {
    if (budget[0] <= 0) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (const name of names) {
      if (budget[0] <= 0) {
        return;
      }
      const child: string = `${dir}/${name}`;
      let st: fileIo.Stat;
      try {
        st = fileIo.statSync(child);
      } catch (e) {
        continue;
      }
      if (st.isDirectory()) {
        budget[0]--;
        this.walkLocalForCategory(child, exts, out, budget);
        continue;
      }
      const dot: number = name.lastIndexOf('.');
      if (dot < 0) {
        continue;
      }
      const ext: string = name.substring(dot + 1).toLowerCase();
      if (exts.indexOf(ext) >= 0) {
        budget[0]--;
        out.push({
          id: child,
          name: name,
          kind: EntryKind.File,
          size: BigInt(Number(st.size)),
          modifiedMs: BigInt(Number(st.mtime) * 1000),
          hidden: name.startsWith('.'),
          readonly: false
        });
      }
    }
  }

  /** Home tab asks us to jump into a folder (or open a mount root). */
  onOpenRequest(): void {
    if (this.openId.length === 0 || this.core === null) {
      return;
    }
    let name: string = this.tt('files.location');
    try {
      name = this.core.stat(this.openId).name;
    } catch (e) {
      // fall back to a generic label
    }
    this.mode = MODE_BROWSE;
    this.crumbs = [{ id: this.openId, name: name }];
    this.refresh();
    this.openId = '';
  }

  aboutToAppear(): void {
    this.wideListener.on('change', (e) => this.wide = e.matches);
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
      this.crumbs = [{ id: this.core.rootId(), name: this.tt('files.thisDevice') }];
      this.refreshMounts();
      if (this.startMode === MODE_FAVORITES) {
        this.mode = MODE_FAVORITES;
        this.titleKey = 'files.favorites';
      } else if (this.startMode === MODE_RECENT) {
        this.mode = MODE_RECENT;
        this.titleKey = 'files.recents';
      }
      this.refresh();
      if (this.openId.length > 0) {
        this.onOpenRequest();
      }
      // Files 页是按需创建的：首页点分类时本组件还不存在，watch 收不到，
      // 所以创建时必须补处理一次挂起的分类请求。
      if (this.categoryReq.length > 0) {
        this.onCategoryRequest();
      }
    } catch (e) {
      this.error = `this.tt('files.openRootFailed')：${String(e)}`;
    }
  }

  private currentId(): string {
    return this.crumbs.length === 0 ? '' : this.crumbs[this.crumbs.length - 1].id;
  }

  /**
   * 来源标签：本地条目显示「本机」，远端条目显示挂载名（webdav://msi → msi）。
   * 分类列表里本机与各挂载的文件混排，标注来源便于决策——远端大文件适合先
   * 拷到本地再播放，而不是直接串流。挂载已断开时兜底显示 scheme 名。
   */
  private sourceTagOf(id: string): string {
    if (id.length === 0 || id.startsWith('/')) {
      return this.tt('files.thisDevice');
    }
    for (const m of this.mounts) {
      if (id === m.rootId || id.startsWith(`${m.rootId}/`)) {
        return m.label;
      }
    }
    const at: number = id.indexOf('://');
    if (at > 0) {
      return id.substring(0, at);
    }
    return '';
  }

  private refreshMounts(): void {
    if (this.core === null) {
      return;
    }
    try {
      this.mounts = this.core.mounts();
    } catch (e) {
      this.mounts = [];
    }
  }

  private matchesFilter(e: Entry): boolean {
    if (!this.showHidden && e.hidden) {
      return false;
    }
    if (this.typeFilter === 'all' || e.kind === EntryKind.Directory) {
      return true;
    }
    const n: string = e.name.toLowerCase();
    if (this.typeFilter === 'image') {
      return /\.(jpg|jpeg|png|gif|webp|bmp|heic|heif)$/.test(n);
    }
    if (this.typeFilter === 'video') {
      return /\.(mp4|mkv|mov|webm|m4v)$/.test(n);
    }
    if (this.typeFilter === 'doc') {
      return /\.(pdf|doc|docx|xls|xlsx|ppt|pptx|txt|md|csv)$/.test(n);
    }
    if (this.typeFilter === 'archive') {
      return /\.(zip|7z|rar|tar|gz)$/.test(n);
    }
    return true;
  }

  private sortEntries(items: Entry[]): Entry[] {
    // 跨源结果集（分类/搜索/收藏/最近）默认按数据源聚组：本机最前，
    // 其余按来源名聚在一起；组内沿用所选的排序方式与方向。浏览单个
    // 目录时没有跨源可言，聚组自动失效。
    const grouped: boolean = this.groupBySource && this.mode !== MODE_BROWSE;
    if (!grouped) {
      return this.compareSorted(items);
    }
    const groups: Map<string, Entry[]> = new Map();
    for (const e of items) {
      const key: string = this.sourceGroupKey(e.id);
      let bucket: Entry[] | undefined = groups.get(key);
      if (bucket === undefined) {
        bucket = [];
        groups.set(key, bucket);
      }
      bucket.push(e);
    }
    const sorted: Entry[] = [];
    // 本机恒为第一组，其后各挂载按来源名升序聚组
    const keys: string[] = [];
    const selfKey: string = this.tt('files.thisDevice');
    for (const k of groups.keys()) {
      if (k !== selfKey) {
        keys.push(k);
      }
    }
    keys.sort();
    if (groups.get(selfKey) !== undefined) {
      keys.unshift(selfKey);
    }
    for (const k of keys) {
      const bucket: Entry[] = groups.get(k) ?? [];
      for (const e of this.compareSorted(bucket)) {
        sorted.push(e);
      }
    }
    return sorted;
  }

  /** 现有比较器：目录优先 + sortKey + 方向。 */
  private compareSorted(items: Entry[]): Entry[] {
    const sorted: Entry[] = items.slice();
    sorted.sort((a: Entry, b: Entry) => {
      const ad: number = a.kind === EntryKind.Directory ? 0 : 1;
      const bd: number = b.kind === EntryKind.Directory ? 0 : 1;
      if (ad !== bd) {
        return ad - bd;
      }
      let cmp: number = 0;
      if (this.sortKey === SORT_SIZE) {
        cmp = Number(a.size) - Number(b.size);
      } else if (this.sortKey === SORT_TIME) {
        const am: number = a.modifiedMs === undefined ? 0 : Number(a.modifiedMs);
        const bm: number = b.modifiedMs === undefined ? 0 : Number(b.modifiedMs);
        cmp = am - bm;
      } else {
        const an: string = a.name.toLowerCase();
        const bn: string = b.name.toLowerCase();
        cmp = an === bn ? 0 : (an < bn ? -1 : 1);
      }
      return this.sortAsc ? cmp : -cmp;
    });
    return sorted;
  }

  /** 来源组键：与行尾来源徽章一致（本机 → 挂载名，断连时兜底 scheme 名）。 */
  private sourceGroupKey(id: string): string {
    return this.sourceTagOf(id);
  }

  private refresh(): void {
    if (this.core === null) {
      return;
    }
    this.loading = true;
    // 分类/搜索/最近里混有远端条目，行尾的来源标签需要最新的挂载列表
    // （重启后挂载丢失，但索引条目的 id 还在）。
    this.refreshMounts();
    try {
      let items: Entry[] = [];
      if (this.mode === MODE_FAVORITES) {
        const favs: FavoriteEntry[] = this.core.favorites(300);
        for (const f of favs) {
          items.push(f.entry);
        }
      } else if (this.mode === MODE_RECENT) {
        const recents: RecentOpen[] = this.core.recentFiles(300);
        for (const r of recents) {
          items.push(r.entry);
        }
      } else if (this.mode === MODE_SEARCH) {
        items = this.core.search(this.query, 300);
      } else if (this.mode === MODE_CATEGORY) {
        items = this.gatherCategory(this.catKey);
      } else {
        try {
          items = this.core.list(this.currentId());
        } catch (err) {
          // 进程重启后挂载失效：先补连再重试（搜索/最近打开进来的网络目录同样适用）
          if (errText(err).indexOf('no backend') >= 0) {
            const ctx0 = this.getUIContext().getHostContext() as common.UIAbilityContext;
            if (!ensureMountedForId(ctx0, this.core, this.currentId())) {
              throw new Error(errText(err));
            }
            items = this.core.list(this.currentId());
          } else {
            throw new Error(errText(err));
          }
        }
      }
      const kept: Entry[] = [];
      for (const e of items) {
        if (this.matchesFilter(e)) {
          kept.push(e);
        }
      }
      this.entries = this.sortEntries(kept);
      this.error = '';
    } catch (e) {
      this.entries = [];
      this.error = this.tt('files.readFailed') + '：' + errText(e);
      hilog.error(0x0000, 'SuperFiles', 'list failed id=%{public}s err=%{public}s',
        this.currentId(), errText(e));
    }
    this.loading = false;
    this.syncBackState();
  }

  private openLocation(kind: string, titleKey: string): void {
    this.mode = kind;
    this.titleKey = titleKey;
    this.query = '';
    this.selecting = false;
    this.selected = [];
    this.refresh();
  }

  private openMount(m: MountInfo): void {
    this.mode = MODE_BROWSE;
    this.title = m.label;
    this.crumbs = [{ id: m.rootId, name: m.label }];
    this.refresh();
  }

  private enter(e: Entry): void {
    if (this.mode !== MODE_BROWSE) {
      this.mode = MODE_BROWSE;
      this.crumbs = [{ id: e.id, name: e.name }];
      this.title = e.name;
    } else {
      const next: Crumb[] = this.crumbs.slice();
      next.push({ id: e.id, name: e.name });
      this.crumbs = next;
    }
    this.refresh();
  }

  private goTo(index: number): void {
    if (index >= this.crumbs.length - 1) {
      return;
    }
    this.crumbs = this.crumbs.slice(0, index + 1);
    this.refresh();
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  private toggleSelect(e: Entry): void {
    const next: string[] = this.selected.slice();
    const at: number = next.indexOf(e.id);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(e.id);
    }
    this.selected = next;
    if (next.length === 0) {
      this.selecting = false;
    }
    this.syncBackState();
  }

  private isMediaFile(name: string): boolean {
    return isMediaName(name);
  }

  private onTap(e: Entry): void {
    if (this.selecting) {
      this.toggleSelect(e);
      return;
    }
    if (e.kind === EntryKind.Directory) {
      this.enter(e);
      return;
    }
    if (this.core !== null) {
      try {
        this.core.recordOpen(e.id);
      } catch (err) {
        // best effort
      }
    }
    // 媒体/PDF 点击即预览（视频直接播）；其他类型弹操作菜单
    if (this.isMediaFile(e.name) || /\.pdf$/i.test(e.name)) {
      this.previewEntry(e);
    } else {
      this.openEntrySheet(e);
    }
  }

  private previewEntry(e: Entry): void {
    if (this.wide) {
      this.paneId = e.id;
      this.paneName = e.name;
      this.paneMime = e.mime === undefined ? '' : e.mime;
      this.paneSize = Number(e.size);
      this.paneModified = e.modifiedMs === undefined ? 0 : Number(e.modifiedMs);
      this.showPane = true;
      return;
    }
    // 画廊：把当前列表里的媒体文件串起来，左右滑切换。
    // PDF 等非媒体走单页画廊（不与媒体串台）。
    let media: Entry[] = [];
    if (this.isMediaFile(e.name)) {
      for (const x of this.entries) {
        if (x.kind !== EntryKind.Directory && this.isMediaFile(x.name)) {
          media.push(x);
        }
      }
      let found: number = -1;
      for (let i = 0; i < media.length; i++) {
        if (media[i].id === e.id) {
          found = i;
        }
      }
      if (found < 0) {
        media.push(e);
        found = media.length - 1;
      }
      const idxAll: number = found;
      // 画廊下标
      const ids: string[] = [];
      const names: string[] = [];
      const mimes: string[] = [];
      const sizes: number[] = [];
      const mods: number[] = [];
      for (const m of media) {
        ids.push(m.id);
        names.push(m.name);
        mimes.push(m.mime === undefined ? '' : m.mime);
        sizes.push(Number(m.size));
        mods.push(m.modifiedMs === undefined ? 0 : Number(m.modifiedMs));
      }
      const params: PreviewParams = {
        ids: ids, names: names, mimes: mimes, sizes: sizes, mods: mods, index: idxAll
      };
      router.pushUrl({ url: 'pages/Preview', params: params });
      return;
    }
    // PDF 等单页预览
    const params: PreviewParams = {
      ids: [e.id],
      names: [e.name],
      mimes: [e.mime === undefined ? '' : e.mime],
      sizes: [Number(e.size)],
      mods: [e.modifiedMs === undefined ? 0 : Number(e.modifiedMs)],
      index: 0
    };
    router.pushUrl({ url: 'pages/Preview', params: params });
  }

  /** 直接收藏/取消收藏某个条目（侧滑按钮用）。 */
  private favoriteDirect(e: Entry): void {
    if (this.core === null) {
      return;
    }
    try {
      const favs: FavoriteEntry[] = this.core.favorites(500);
      let exists: boolean = false;
      for (const f of favs) {
        if (f.entry.id === e.id) {
          exists = true;
        }
      }
      if (exists) {
        this.core.removeFavorite(e.id);
        this.notice = this.tt('files.favoriteRemoved');
      } else {
        this.core.addFavorite(e.id);
        this.notice = this.tt('files.favoriteAdded');
      }
      if (this.mode === MODE_FAVORITES) {
        this.refresh();
      }
    } catch (err) {
      this.error = this.tt('files.favoriteFailed') + '：' + errText(err);
    }
  }

  /** 侧滑删除：进确认页。 */
  private deleteDirect(e: Entry): void {
    this.selId = e.id;
    this.selName = e.name;
    this.selIsDir = e.kind === EntryKind.Directory;
    this.selSize = Number(e.size);
    this.selModified = e.modifiedMs === undefined ? 0 : Number(e.modifiedMs);
    this.selMime = e.mime === undefined ? '' : e.mime;
    this.sheet = SHEET_DELETE;
  }

  /** 侧滑详情：直接打开详情面板。 */
  private detailDirect(e: Entry): void {
    this.openEntrySheet(e);
    this.sheet = SHEET_DETAILS;
  }

  private onLongPress(e: Entry): void {
    if (!this.selecting) {
      this.selecting = true;
      this.selected = [e.id];
      this.syncBackState();
      return;
    }
    this.toggleSelect(e);
  }

  private openEntrySheet(e: Entry): void {
    if (this.core !== null && e.kind !== EntryKind.Directory) {
      try {
        this.core.recordOpen(e.id);
      } catch (err) {
        // best effort
      }
    }
    this.selId = e.id;
    this.selName = e.name;
    this.selIsDir = e.kind === EntryKind.Directory;
    this.selSize = Number(e.size);
    this.selModified = e.modifiedMs === undefined ? 0 : Number(e.modifiedMs);
    this.selMime = e.mime === undefined ? '' : e.mime;
    this.selMeta = this.selIsDir ? this.tt('common.folder') : formatBytes(this.selSize);
    if (this.selModified > 0) {
      this.selMeta = `${this.selMeta} · ${formatDate(this.selModified)}`;
    }
    try {
      this.selPath = this.core === null ? '' : this.core.displayPath(e.id);
    } catch (err) {
      this.selPath = '';
    }
    this.sheet = SHEET_ENTRY;
  }

  private closeSheet(): void {
    if (this.sheet === SHEET_SHARE) {
      this.stopShare();
    }
    this.sheet = SHEET_NONE;
    this.input = '';
    this.syncBackState();
  }

  private validName(name: string): boolean {
    const n: string = name.trim();
    return n.length > 0 && n.indexOf('/') < 0 && n !== '.' && n !== '..';
  }

  private doCreate(): void {
    const name: string = this.input.trim();
    if (this.core === null || !this.validName(name)) {
      this.error = this.tt('files.nameRequired');
      return;
    }
    try {
      this.core.createDir(this.currentId(), name);
      this.closeSheet();
      this.refresh();
    } catch (e) {
      this.error = this.tt('files.newFailed') + '：' + errText(e);
    }
  }

  private doRename(): void {
    const name: string = this.input.trim();
    if (this.core === null || !this.validName(name)) {
      this.error = this.tt('files.nameRequired');
      return;
    }
    try {
      this.core.rename(this.selId, name);
      this.closeSheet();
      this.refresh();
    } catch (e) {
      this.error = this.tt('files.renameFailed') + '：' + errText(e);
    }
  }

  private doDelete(): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.remove(this.selId, true);
      this.selected = [];
      this.selecting = false;
      this.closeSheet();
      this.refresh();
    } catch (e) {
      this.error = this.tt('files.deleteFailed') + '：' + errText(e);
    }
  }

  private deleteSelected(): void {
    if (this.core === null || this.selected.length === 0) {
      return;
    }
    try {
      let failed: number = 0;
      for (const id of this.selected) {
        try {
          this.core.remove(id, true);
        } catch (e) {
          failed++;
        }
      }
      this.notice = failed === 0 ? this.tt('files.deleted', `${this.selected.length}`) : this.tt('files.batchDeletePartial', `${failed}`);
      this.selected = [];
      this.selecting = false;
      this.refresh();
    } catch (e) {
      this.error = this.tt('files.batchDeleteFailed') + '：' + errText(e);
    }
  }

  private isArchiveName(name: string): boolean {
    return /\.(zip|7z|rar|tar|gz|bz2|xz)$/i.test(name);
  }

  private isTextName(name: string): boolean {
    return /\.(txt|md|json|log|xml|yaml|yml|csv|ini|conf|rs|kt|ets|ts|js|py|sh|toml)$/i.test(name);
  }

  private primaryActionLabel(): string {
    if (this.isMediaFile(this.selName) && /\.(mp4|mkv|mov|webm|m4v|avi|mp3|flac|wav|aac|m4a|ogg|ape|wv|aiff|au)$/i.test(this.selName)) {
      return this.tt('files.play');
    }
    if (this.isTextName(this.selName)) {
      return this.tt('files.openFile');
    }
    if (this.isArchiveName(this.selName)) {
      return this.tt('files.openFile');
    }
    return this.tt('common.openPreview');
  }

  private primaryAction(): void {
    this.openPreview();
  }

  /** 菜单「使用其他应用打开」：落地缓存后拉起系统 viewData。 */
  private openSelExternal(): void {
    if (this.core === null) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    openEntryExternal(ctx, this.core, this.selId, this.selName, this.selSize)
      .then(() => {
        this.notice = '';
      })
      .catch((e: Error) => {
        const msg: string = errText(e);
        if (msg.indexOf('size-unsupported') >= 0) {
          this.error = this.tt('pv.pdfTooLarge');
        } else if (msg.indexOf('incomplete') >= 0) {
          this.error = this.tt('pv.openFailed');
        } else {
          this.error = this.tt('pv.noApp');
        }
      });
  }

  private openPreview(): void {
    if (this.core === null || this.selIsDir) {
      return;
    }
    this.closeSheet();
    for (const e of this.entries) {
      if (e.id === this.selId) {
        this.previewEntry(e);
        return;
      }
    }
  }

  @Builder
  paneHeader() {
    Row({ space: 8 }) {
      Button('‹')
        .fontSize(20)
        .width(34)
        .height(34)
        .backgroundColor(this.th().searchFieldBg)
        .fontColor(this.th().onSurface)
        .onClick(() => this.showPane = false)
      Column({ space: 2 }) {
        Text(this.paneName)
          .fontSize(14)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .fontColor(this.th().onSurface)
        Text(`${formatBytes(this.paneSize)} · ${formatDate(this.paneModified)}`)
          .fontSize(10)
          .fontColor(this.th().onSurfaceVariant)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: SPACE3, right: SPACE3, top: SPACE2, bottom: SPACE2 })
  }

  private toggleFavorite(): void {
    if (this.core === null) {
      return;
    }
    try {
      const favs: FavoriteEntry[] = this.core.favorites(500);
      let exists: boolean = false;
      for (const f of favs) {
        if (f.entry.id === this.selId) {
          exists = true;
        }
      }
      if (exists) {
        this.core.removeFavorite(this.selId);
        this.notice = this.tt('files.favoriteRemoved');
      } else {
        this.core.addFavorite(this.selId);
        this.notice = this.tt('files.favoriteAdded');
      }
      this.closeSheet();
      if (this.mode === MODE_FAVORITES) {
        this.refresh();
      }
    } catch (e) {
      this.error = this.tt('files.favoriteFailed') + '：' + errText(e);
    }
  }

  private doZip(): void {
    const name: string = this.input.trim().length === 0 ? 'archive.zip' : this.input.trim();
    if (this.core === null) {
      return;
    }
    const sources: string[] = this.selecting ? this.selected : [this.selId];
    try {
      this.core.compressZip(sources, this.currentId(), name, ZipMethod.Deflate, {
        onProgress: (done: bigint, total: bigint) => {
          this.notice = this.tt('files.zipProgress', `${Number(done)}`, `${Number(total)}`);
        }
      });
      this.notice = this.tt('files.zipDone', name);
      this.selected = [];
      this.selecting = false;
      this.closeSheet();
      this.refresh();
    } catch (e) {
      this.error = this.tt('files.zipFailed') + '：' + errText(e);
    }
  }

  private doShare(): void {
    if (this.core === null) {
      return;
    }
    const ids: string[] = this.selecting ? this.selected : [this.selId];
    try {
      const info: ShareInfo = this.core.startShare(ids);
      this.shareUrl = info.url;
      this.sheet = SHEET_SHARE;
      this.makeQr(info.url);
    } catch (e) {
      this.error = this.tt('files.shareFailed') + '：' + errText(e);
    }
  }

  /** 用 ScanKit 生成二维码；失败则退化为纯链接展示。 */
  private makeQr(content: string): void {
    this.shareQr = null;
    generateBarcode.createBarcode(content, {
      scanType: scanCore.ScanType.QR_CODE,
      width: 600,
      height: 600,
      margin: 2,
      level: generateBarcode.ErrorCorrectionLevel.LEVEL_M
    }).then((pm: image.PixelMap) => {
      this.shareQr = pm;
    }).catch(() => {
      this.shareQr = null;
    });
  }

  private stopShare(): void {
    if (this.core !== null) {
      try {
        this.core.stopShare();
      } catch (e) {
        // best effort
      }
    }
    this.shareUrl = '';
    this.shareQr = null;
  }

  private startPicking(move: boolean): void {
    if (this.core === null) {
      return;
    }
    this.pickMode = move ? 'move' : 'copy';
    this.pickCrumbs = [{ id: this.core.rootId(), name: this.tt('files.thisDevice') }];
    this.picking = true;
    this.loadPick();
  }

  private loadPick(): void {
    if (this.core === null) {
      return;
    }
    try {
      const id: string = this.pickCrumbs[this.pickCrumbs.length - 1].id;
      const all: Entry[] = this.core.list(id);
      const dirs: Entry[] = [];
      for (const e of all) {
        if (e.kind === EntryKind.Directory && (this.showHidden || !e.hidden)) {
          dirs.push(e);
        }
      }
      this.pickEntries = this.sortEntries(dirs);
    } catch (e) {
      this.pickEntries = [];
    }
  }

  private confirmDestination(): void {
    if (this.core === null) {
      return;
    }
    this.conflictDest = this.pickCrumbs[this.pickCrumbs.length - 1].id;
    this.conflictSources = this.selecting ? this.selected.slice() : [this.selId];
    this.conflictMove = this.pickMode === 'move';
    this.picking = false;
    // 只有目标目录真的存在同名条目时才弹冲突选择，否则直接开始。
    if (this.hasConflict(this.conflictSources, this.conflictDest)) {
      this.sheet = SHEET_CONFLICT;
    } else {
      this.runTransfer(ConflictPolicy.Rename);
    }
  }

  /** 目标目录里是否已有与任一源同名的条目。 */
  private hasConflict(srcIds: string[], destId: string): boolean {
    if (this.core === null) {
      return false;
    }
    try {
      const names: Set<string> = new Set();
      const destEntries: Entry[] = this.core.list(destId);
      for (const e of destEntries) {
        names.add(e.name);
      }
      for (const id of srcIds) {
        const base: string = this.baseNameOf(id);
        if (base.length > 0 && names.has(base)) {
          return true;
        }
      }
      return false;
    } catch (e) {
      // 列目录失败时保守起见仍弹冲突框
      return true;
    }
  }

  private baseNameOf(id: string): string {
    if (this.core === null) {
      return '';
    }
    try {
      const p: string = this.core.displayPath(id);
      const t: string = p.replace(/\/+$/, '');
      const at: number = t.lastIndexOf('/');
      return at >= 0 ? t.substring(at + 1) : t;
    } catch (e) {
      return '';
    }
  }

  private runTransfer(policy: number): void {
    if (this.core === null || this.conflictSources.length === 0) {
      return;
    }
    try {
      if (this.conflictMove) {
        this.core.startMove(this.conflictSources, this.conflictDest, policy);
      } else {
        this.core.startCopy(this.conflictSources, this.conflictDest, policy);
      }
      this.notice = this.tt(this.conflictMove ? 'files.moveStarted' : 'files.copyStarted', `${this.conflictSources.length}`);
      this.selected = [];
      this.selecting = false;
      this.closeSheet();
      this.refresh();
      this.watchTransfersUntilDone();
    } catch (e) {
      this.error = this.tt('files.transferCreateFailed') + '：' + errText(e);
    }
  }

  /**
   * 移动/复制在后台执行，完成后自动刷新当前列表。
   * 轮询传输表：不再有运行中的任务时刷新一次并停止。
   */
  private watchTransfersUntilDone(): void {
    if (this.transferTimer >= 0) {
      return;
    }
    this.transferTimer = setInterval(() => {
      if (this.core === null) {
        this.stopTransferWatch();
        return;
      }
      try {
        const snaps: TransferSnapshot[] = this.core.transfers();
        let active: number = 0;
        for (const s of snaps) {
          if (s.state === TransferState.Running || s.state === TransferState.Queued ||
            s.state === TransferState.Paused) {
            active++;
          }
        }
        if (active === 0) {
          this.stopTransferWatch();
          this.refresh();
        }
      } catch (e) {
        this.stopTransferWatch();
      }
    }, 1500);
  }

  private stopTransferWatch(): void {
    if (this.transferTimer >= 0) {
      clearInterval(this.transferTimer);
      this.transferTimer = -1;
    }
  }

  /** Share sheets ("分享到本应用") land here as a file uri. */
  onImportRequest(): void {
    if (this.importUri.length === 0 || this.core === null) {
      return;
    }
    const name: string = this.importName.length === 0 ? `导入-${Date.now()}` : this.importName;
    try {
      const file = fileIo.openSync(this.importUri, fileIo.OpenMode.READ_ONLY);
      try {
        const entry: Entry = this.core.createFile(this.core.rootId(), name);
        this.core.importFromFd(entry.id, file.fd, BigInt(0));
        this.notice = this.tt('files.imported', name);
        this.refresh();
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      this.error = this.tt('files.importFailed') + '：' + errText(e);
    }
    this.importUri = '';
    this.importName = '';
  }

  aboutToDisappear(): void {
    this.stopTransferWatch();
    this.wideListener.off('change');
  }

  @Builder
  chip(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(active ? this.th().onPrimary : this.th().onSurface)
      .backgroundColor(active ? this.th().primary : this.th().searchFieldBg)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(16)
      .onClick(action)
  }

  /** TopAppBar per screens.md §1: back / path title / ⋯ overflow. */
  @Builder
  appBar() {
    Row({ space: SPACE2 }) {
      if (this.selecting) {
        Button('✕')
          .fontSize(16)
          .width(36)
          .height(36)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurface)
          .onClick(() => {
            this.selecting = false;
            this.selected = [];
          })
        Text(this.tt('files.selectedN', `${this.selected.length}`))
          .fontSize(T_APPBAR)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().onSurface)
          .layoutWeight(1)
        Button(this.tt('common.selectAll'))
          .fontSize(13)
          .height(36)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().primary)
          .onClick(() => {
            const all: string[] = [];
            for (const e of this.entries) {
              all.push(e.id);
            }
            this.selected = all;
          })
      } else {
        if (this.mode === MODE_BROWSE && this.crumbs.length > 1) {
          Button('‹')
            .fontSize(22)
            .width(36)
            .height(36)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurface)
            .onClick(() => this.goTo(this.crumbs.length - 2))
        } else if (this.mode !== MODE_BROWSE) {
          Button('‹')
            .fontSize(22)
            .width(36)
            .height(36)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurface)
            .onClick(() => {
              this.crumbs = [{ id: this.core === null ? '' : this.core.rootId(), name: this.tt('files.thisDevice') }];
              this.openLocation(MODE_BROWSE, 'files.thisDevice');
            })
        }
        Text(this.pathTitle())
          .fontSize(T_APPBAR)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Button(this.tt('files.more'))
          .fontSize(16)
          .width(36)
          .height(36)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurface)
          .onClick(() => {
            // 分类/搜索/收藏/最近同样提供更多菜单：排序、升降序、隐藏文件、
            // 多选（进而全选 → 复制/移动/删除）对结果集都有意义。
            this.sheet = SHEET_MORE;
          })
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: SCREEN_MARGIN - 8, right: SCREEN_MARGIN - 8 })
  }

  /** 输入即搜（250ms 防抖）；清空回到浏览模式。 */
  private onSearchInput(v: string): void {
    this.query = v;
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    if (v.trim().length === 0) {
      if (this.mode === MODE_SEARCH) {
        this.mode = MODE_BROWSE;
        this.titleKey = 'files.thisDevice';
        this.refresh();
      }
      return;
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.runSearch(this.query);
    }, 250);
  }

  private runSearch(q: string): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    if (q.trim().length === 0) {
      return;
    }
    this.mode = MODE_SEARCH;
    this.titleKey = 'files.searchTitle';
    this.title = q;
    this.refresh();
  }

  private pathTitle(): string {
    if (this.mode === MODE_CATEGORY) {
      return this.tt('home.cat.' + this.catKey);
    }
    if (this.mode !== MODE_BROWSE) {
      if (this.titleKey === 'files.searchTitle') {
        return this.tt('files.searchTitle', this.title);
      }
      return this.tt(this.titleKey);
    }
    if (this.crumbs.length === 1) {
      return this.tt('files.thisDevice');
    }
    const names: string[] = [];
    for (const c of this.crumbs) {
      names.push(c.name);
    }
    return names.join(' / ');
  }

  /** SearchFieldBar per screens.md §1. */
  @Builder
  searchBar() {
    Row({ space: SPACE2 }) {
      TextInput({ text: this.query, placeholder: this.tt('files.searchPlaceholder') })
        .height(44)
        .layoutWeight(1)
        .backgroundColor(this.th().searchFieldBg)
        .borderRadius(RADIUS_PILL)
        .padding({ left: SPACE4, right: SPACE4 })
        .onChange((v: string) => this.onSearchInput(v))
        .onSubmit(() => this.runSearch(this.query))
      if (this.query.length > 0) {
        Text('×')
          .fontSize(18)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => {
            this.query = '';
            this.mode = MODE_BROWSE;
            this.titleKey = 'files.thisDevice';
            this.refresh();
          })
      }
    }
    .width('100%')
    .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, bottom: SPACE2 })
  }

  /** Footer（计数）per screens.md §1. */
  @Builder
  footer() {
    Row() {
      Text(this.tt('files.countN', `${this.entries.length}`))
        .fontSize(T_SECONDARY)
        .fontColor(this.th().onSurfaceVariant)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: SPACE2, bottom: SPACE2 })
  }

  @Builder
  entryRow(e: Entry) {
    Row({ space: SPACE3 }) {
      if (this.selecting) {
        SelDot({ selected: this.isSelected(e.id), dark: this.dark })
      }
      FileIcon({ name: e.name, isDir: e.kind === EntryKind.Directory, dark: this.dark, box: 36 })
      Column({ space: 3 }) {
        Text(e.name)
          .fontSize(T_FILENAME)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: SPACE2 }) {
          Text(e.kind === EntryKind.Directory ? this.tt('common.folder') : formatBytes(Number(e.size)))
            .fontSize(11).fontColor(this.th().onSurfaceVariant)
          if (e.modifiedMs !== undefined) {
            Text(formatDate(Number(e.modifiedMs)))
              .fontSize(11).fontColor(this.th().onSurfaceVariant)
          }
          // 分类列表：本机/远端混排，行尾标注来源（挂载名/本机）
          if (this.mode === MODE_CATEGORY) {
            Blank()
            Text(this.sourceTagOf(e.id))
              .fontSize(10)
              .fontColor(this.th().primary)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .backgroundColor(this.th().divider)
              .borderRadius(RADIUS_PILL)
              .maxLines(1)
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('⋯').fontSize(16).fontColor(this.th().outline)
        .onClick(() => this.openEntrySheet(e))
    }
    .width('100%')
    .constraintSize({ minHeight: 74 })
    .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE2, bottom: SPACE2 })
    .backgroundColor(this.th().surfaceCard)
    .onClick(() => this.onTap(e))
    .gesture(LongPressGesture({ duration: 400 }).onAction(() => {
      if (!this.selecting) {
        this.selecting = true;
        this.selected = [e.id];
        this.syncBackState();
      }
    }))
  }

  /** 右滑（start）：左侧滑出 收藏 / 删除，全高。 */
  @Builder
  swipeEndBtns(e: Entry) {
    Row() {
      Column() {
        Text(this.isFav(e.id) ? this.tt('home.unfavorite') : this.tt('files.favorites'))
          .fontSize(12)
          .fontColor(this.th().onPrimary)
      }
      .width(72)
      .height('100%')
      .backgroundColor(this.th().primaryWarm)
      .justifyContent(FlexAlign.Center)
      .onClick(() => this.favoriteDirect(e))

      Column() {
        Text(this.tt('common.delete'))
          .fontSize(12)
          .fontColor(Color.White)
      }
      .width(72)
      .height('100%')
      .backgroundColor(this.th().error)
      .justifyContent(FlexAlign.Center)
      .borderRadius({ topLeft: 14, bottomLeft: 14 })
      .onClick(() => this.deleteDirect(e))
    }
    .height('100%')
  }

  /** 左滑（end）：右侧滑出 更多，点开菜单，全高。 */
  @Builder
  swipeStartBtn(e: Entry) {
    Row() {
      Column() {
        Text(this.tt('common.more'))
          .fontSize(12)
          .fontColor(this.th().onPrimary)
      }
      .width(72)
      .height('100%')
      .backgroundColor(this.th().primary)
      .justifyContent(FlexAlign.Center)
      .borderRadius({ topRight: 14, bottomRight: 14 })
      .onClick(() => this.openEntrySheet(e))
    }
    .height('100%')
    .justifyContent(FlexAlign.Start)
  }

  private isFav(id: string): boolean {
    if (this.core === null) {
      return false;
    }
    try {
      const favs: FavoriteEntry[] = this.core.favorites(500);
      for (const f of favs) {
        if (f.entry.id === id) {
          return true;
        }
      }
    } catch (err) {
      // ignore
    }
    return false;
  }

  @Builder
  batchBar() {
    Row({ space: 8 }) {
      this.chip(this.tt('common.selectAll'), false, () => {
        const all: string[] = [];
        for (const e of this.entries) {
          all.push(e.id);
        }
        this.selected = all;
      })
      this.chip(this.tt('common.copy'), false, () => this.startPicking(false))
      this.chip(this.tt('common.move'), false, () => this.startPicking(true))
      this.chip(this.tt('common.compress'), false, () => {
        this.input = 'archive.zip';
        this.sheet = SHEET_ZIP;
      })
      this.chip(this.tt('common.share'), false, () => this.doShare())
      this.chip(this.tt('common.delete'), false, () => this.deleteSelected())
    }
    .width('100%')
    .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })
    .backgroundColor(this.th().searchFieldBg)
  }

  /** 系统风格单列菜单行（图库同款）：整行可点，危险操作红色。 */
  @Builder
  sheetMenuRow(label: string, danger: boolean, primary: boolean, action: () => void) {
    Text(label)
      .fontSize(15)
      .fontColor(danger ? this.th().error : (primary ? this.th().primary : this.th().onSurface))
      .fontWeight(primary ? FontWeight.Medium : FontWeight.Regular)
      .width('100%')
      .height(46)
      .padding({ left: 4, right: 4 })
      .onClick(action)
  }

  @Builder
  entrySheetActions() {
    Column({ space: 0 }) {
      if (!this.selIsDir) {
        this.sheetMenuRow(this.primaryActionLabel(), false, true, () => this.primaryAction())
        Divider().color(this.th().divider)
      }
      if (!this.isMediaFile(this.selName) && !/\.pdf$/i.test(this.selName)) {
        this.sheetMenuRow(this.tt('pv.openExternal'), false, false, () => {
          this.closeSheet();
          this.openSelExternal();
        })
      }
      this.sheetMenuRow(this.tt('files.copyTo'), false, false, () => {
        this.selecting = false;
        this.startPicking(false);
      })
      Divider().color(this.th().divider)
      this.sheetMenuRow(this.tt('files.moveTo'), false, false, () => {
        this.selecting = false;
        this.startPicking(true);
      })
      Divider().color(this.th().divider)
      this.sheetMenuRow(this.tt('common.rename'), false, false, () => {
        this.input = this.selName;
        this.sheet = SHEET_RENAME;
      })
      Divider().color(this.th().divider)
      this.sheetMenuRow(this.isFav(this.selId) ? this.tt('home.unfavorite') : this.tt('files.favorites'), false, false, () => this.toggleFavorite())
      Divider().color(this.th().divider)
      this.sheetMenuRow(this.tt('common.compress'), false, false, () => {
        this.input = `${this.selName}.zip`;
        this.selecting = false;
        this.sheet = SHEET_ZIP;
      })
      if (this.isZipName(this.selName)) {
        Divider().color(this.th().divider)
        this.sheetMenuRow(this.tt('files.extract'), false, false, () => this.doExtract())
      }
      if (!this.selIsDir) {
        Divider().color(this.th().divider)
        this.sheetMenuRow(this.tt('common.share'), false, false, () => {
          this.selecting = false;
          this.doShare();
        })
      }
      Divider().color(this.th().divider)
      this.sheetMenuRow(this.tt('common.details'), false, false, () => this.sheet = SHEET_DETAILS)
      Divider().color(this.th().divider)
      this.sheetMenuRow(this.tt('common.delete'), true, false, () => this.sheet = SHEET_DELETE)
    }
    .width('100%')
  }

  private isZipName(name: string): boolean {
    return /\.zip$/i.test(name);
  }

  /** 解压到当前目录：同名自动重命名（引擎侧处理），完成后刷新。 */
  private doExtract(): void {
    if (this.core === null) {
      return;
    }
    try {
      const n: bigint = this.core.extractZip(this.selId, this.currentId(), {
        onProgress: (done: bigint, total: bigint) => {
          this.notice = this.tt('files.extractProgress', `${Number(done)}`, `${Number(total)}`);
        }
      });
      this.notice = this.tt('files.extractDone', `${Number(n)}`);
      this.closeSheet();
      this.refresh();
    } catch (e) {
      this.error = this.tt('files.extractFailed') + '：' + errText(e);
    }
  }

  @Builder
  menuRow(label: string, action: () => void) {
    Row() {
      Text(label).fontSize(14).fontColor(this.th().onSurface).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(action)
  }

  @Builder
  sheetOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.closeSheet())
      Column({ space: 14 }) {
        if (this.sheet === SHEET_MORE) {
          Text(this.tt('files.more')).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.th().onSurface)
          Divider().color(this.th().divider)
          this.menuRow(this.tt('files.menuSelect'), () => {
            this.selecting = true;
            this.syncBackState();
            this.closeSheet();
          })
          if (this.mode === MODE_BROWSE) {
            this.menuRow(this.tt('files.menuNewFolder'), () => {
              this.sheet = SHEET_NONE;
              this.input = '';
              this.sheet = SHEET_NEW;
            })
          }
          this.menuRow(this.tt('files.menuRefresh'), () => {
            this.refresh();
            this.closeSheet();
          })
          // 排序：点开独立面板选方式（名称/时间/大小）与升/降序，
          // 不再用「点击循环切换」的隐性交互。
          this.menuRow(this.tt('files.menuSort', this.sortLabel()), () => {
            this.sheet = SHEET_SORT;
          })
          this.menuRow(this.tt('files.menuHidden', this.showHidden ? this.tt('files.withHidden') : this.tt('files.withoutHidden')), () => {
            this.showHidden = !this.showHidden;
            saveShowHidden(this.getUIContext().getHostContext() as common.UIAbilityContext, this.showHidden);
            this.refresh();
          })
          // 类型过滤只对目录浏览和全局搜索有意义；分类页本身就是一个类型切片
          if (this.mode === MODE_BROWSE || this.mode === MODE_SEARCH) {
            this.menuRow(this.tt('files.menuFilter', this.typeLabel(this.typeFilter)), () => {
              const order: string[] = ['all', 'image', 'video', 'doc', 'archive'];
              const at: number = order.indexOf(this.typeFilter);
              this.typeFilter = order[(at + 1) % order.length];
              this.refresh();
            })
          }
          Button(this.tt('common.close'))
            .width('100%')
            .height(40)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurfaceVariant)
            .onClick(() => this.closeSheet())
        } else if (this.sheet === SHEET_SORT) {
          // 排序面板：显式选择排序方式与方向，当前项以主题色高亮。
          Text(this.tt('files.sortTitle')).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.th().onSurface)
          Divider().color(this.th().divider)
          this.sheetMenuRow(this.tt('files.sortName'), false, this.sortKey === SORT_NAME, () => {
            this.sortKey = SORT_NAME;
            this.refresh();
            this.closeSheet();
          })
          this.sheetMenuRow(this.tt('files.sortTime'), false, this.sortKey === SORT_TIME, () => {
            this.sortKey = SORT_TIME;
            this.refresh();
            this.closeSheet();
          })
          this.sheetMenuRow(this.tt('files.sortSize'), false, this.sortKey === SORT_SIZE, () => {
            this.sortKey = SORT_SIZE;
            this.refresh();
            this.closeSheet();
          })
          Divider().color(this.th().divider)
          // 数据源聚组仅对跨源结果集（分类/搜索/收藏/最近）有意义
          if (this.mode !== MODE_BROWSE) {
            this.sheetMenuRow(this.groupBySource ? this.tt('files.groupOn') : this.tt('files.groupOff'),
              false, this.groupBySource, () => {
              this.groupBySource = !this.groupBySource;
              this.refresh();
              this.closeSheet();
            })
            Divider().color(this.th().divider)
          }
          this.sheetMenuRow(this.tt('files.asc'), false, this.sortAsc, () => {
            this.sortAsc = true;
            this.refresh();
            this.closeSheet();
          })
          this.sheetMenuRow(this.tt('files.desc'), false, !this.sortAsc, () => {
            this.sortAsc = false;
            this.refresh();
            this.closeSheet();
          })
          Button(this.tt('common.close'))
            .width('100%')
            .height(40)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurfaceVariant)
            .onClick(() => this.closeSheet())
        } else if (this.sheet === SHEET_ENTRY) {
          Text(this.selName).fontSize(17).fontWeight(FontWeight.Medium).maxLines(2)
          Text(this.selMeta).fontSize(13).fontColor(this.th().onSurfaceVariant)
          Divider().color(this.th().divider)
          this.entrySheetActions()
          Button(this.tt('common.close'))
            .width('100%')
            .height(40)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurfaceVariant)
            .onClick(() => this.closeSheet())
        } else if (this.sheet === SHEET_NEW) {
          Text(this.tt('files.newFolder')).fontSize(17).fontWeight(FontWeight.Medium)
          TextInput({ text: this.input, placeholder: this.tt('files.folderName') })
            .height(44)
            .onChange((v: string) => this.input = v)
          Row({ space: 10 }) {
            Button(this.tt('common.cancel'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().searchFieldBg)
              .fontColor(this.th().onSurface)
              .onClick(() => this.closeSheet())
            Button(this.tt('files.create'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().primary)
              .fontColor(this.th().onPrimary)
              .onClick(() => this.doCreate())
          }
          .width('100%')
        } else if (this.sheet === SHEET_RENAME) {
          Text(this.tt('common.rename')).fontSize(17).fontWeight(FontWeight.Medium)
          TextInput({ text: this.input })
            .height(44)
            .onChange((v: string) => this.input = v)
          Row({ space: 10 }) {
            Button(this.tt('common.cancel'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().searchFieldBg)
              .fontColor(this.th().onSurface)
              .onClick(() => this.closeSheet())
            Button(this.tt('common.ok'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().primary)
              .fontColor(this.th().onPrimary)
              .onClick(() => this.doRename())
          }
          .width('100%')
        } else if (this.sheet === SHEET_DELETE) {
          Text(`删除「${this.selName}」？`).fontSize(17).fontWeight(FontWeight.Medium)
          Text(this.selIsDir ? this.tt('files.deleteDirWarn') : this.tt('files.deleteFileWarn'))
            .fontSize(13)
            .fontColor(this.th().onSurfaceVariant)
          Row({ space: 10 }) {
            Button(this.tt('common.cancel'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().searchFieldBg)
              .fontColor(this.th().onSurface)
              .onClick(() => this.closeSheet())
            Button(this.tt('common.delete'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().error)
              .fontColor(this.th().onPrimary)
              .onClick(() => this.doDelete())
          }
          .width('100%')
        } else if (this.sheet === SHEET_ZIP) {
          Text(this.tt('files.zipTitle')).fontSize(17).fontWeight(FontWeight.Medium)
          TextInput({ text: this.input, placeholder: 'archive.zip' })
            .height(44)
            .onChange((v: string) => this.input = v)
          Row({ space: 10 }) {
            Button(this.tt('common.cancel'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().searchFieldBg)
              .fontColor(this.th().onSurface)
              .onClick(() => this.closeSheet())
            Button(this.tt('common.compress'))
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.th().primary)
              .fontColor(this.th().onPrimary)
              .onClick(() => this.doZip())
          }
          .width('100%')
        } else if (this.sheet === SHEET_DETAILS) {
          Text(this.tt('common.details')).fontSize(17).fontWeight(FontWeight.Medium)
          Text(`${this.tt('common.name')}：${this.selName}`).fontSize(13).width('100%')
          Text(`${this.tt('common.type')}：${this.selIsDir ? this.tt('common.folder') : (this.selMime.length > 0 ? this.selMime : this.tt('common.unknown'))}`)
            .fontSize(13)
            .width('100%')
          Text(`${this.tt('common.size')}：${this.selIsDir ? '—' : formatBytes(this.selSize)}`).fontSize(13).width('100%')
          Text(`${this.tt('common.modified')}：${this.selModified > 0 ? formatDate(this.selModified) : '—'}`)
            .fontSize(13)
            .width('100%')
          Text(`${this.tt('common.path')}：${this.selPath}`).fontSize(13).width('100%').maxLines(3)
          Button(this.tt('common.close'))
            .width('100%')
            .height(40)
            .backgroundColor(this.th().searchFieldBg)
            .fontColor(this.th().onSurface)
            .onClick(() => this.closeSheet())
        } else if (this.sheet === SHEET_CONFLICT) {
          Text(this.tt('files.conflictTitle')).fontSize(17).fontWeight(FontWeight.Medium)
          Text(this.tt('files.conflictHint', this.conflictMove ? this.tt('common.move') : this.tt('common.copy'), `${this.conflictSources.length}`))
            .fontSize(T_BODY)
            .fontColor(this.th().onSurfaceVariant)
          Button(this.tt('files.overwrite'))
            .width('100%')
            .height(40)
            .backgroundColor(this.th().primary)
            .fontColor(this.th().onPrimary)
            .onClick(() => this.runTransfer(ConflictPolicy.Overwrite))
          Button(this.tt('files.skip'))
            .width('100%')
            .height(40)
            .backgroundColor(this.th().searchFieldBg)
            .fontColor(this.th().onSurface)
            .onClick(() => this.runTransfer(ConflictPolicy.Skip))
          Button(this.tt('files.autoRename'))
            .width('100%')
            .height(40)
            .backgroundColor(this.th().searchFieldBg)
            .fontColor(this.th().onSurface)
            .onClick(() => this.runTransfer(ConflictPolicy.Rename))
          Button(this.tt('common.cancel'))
            .width('100%')
            .height(40)
            .backgroundColor(Color.Transparent)
            .fontColor(this.th().onSurfaceVariant)
            .onClick(() => this.closeSheet())
        } else if (this.sheet === SHEET_SHARE) {
          Text(this.tt('files.shareLan')).fontSize(17).fontWeight(FontWeight.Medium)
          Text(this.tt('files.shareHint')).fontSize(13).fontColor(this.th().onSurfaceVariant)
          if (this.shareQr !== null) {
            Image(this.shareQr)
              .width(200)
              .height(200)
              .alignSelf(ItemAlign.Center)
              .margin({ top: 8, bottom: 8 })
          }
          Text(this.shareUrl)
            .fontSize(14)
            .fontColor(this.th().primary)
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
          Button(this.tt('files.stopShare'))
            .width('100%')
            .height(40)
            .backgroundColor(this.th().errorContainer)
            .fontColor(this.th().error)
            .onClick(() => this.closeSheet())
        }
      }
      .width('100%')
      .padding(20)
      .backgroundColor(this.th().surfaceCard)
      .borderRadius({ topLeft: 18, topRight: 18 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  @Builder
  pickerOverlay() {
    Column() {
      Row({ space: 8 }) {
        Button('‹')
          .fontSize(22)
          .width(38)
          .height(38)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => {
            if (this.pickCrumbs.length > 1) {
              this.pickCrumbs = this.pickCrumbs.slice(0, this.pickCrumbs.length - 1);
              this.loadPick();
            }
          })
        Text(this.pickMode === 'move' ? this.tt('files.pickerMove') : this.tt('files.pickerCopy'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .layoutWeight(1)
        Text(this.tt('common.cancel'))
          .fontSize(13)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => this.picking = false)
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 10, bottom: 10 })

      Scroll() {
        Row({ space: 2 }) {
          ForEach(this.pickCrumbs, (c: Crumb, index: number) => {
            if (index > 0) {
              Text('/').fontSize(12).fontColor(this.th().outline)
            }
            Text(c.name)
              .fontSize(12)
              .fontColor(index === this.pickCrumbs.length - 1 ? this.th().onSurface : this.th().primary)
              .onClick(() => {
                this.pickCrumbs = this.pickCrumbs.slice(0, index + 1);
                this.loadPick();
              })
          }, (c: Crumb, index: number) => `${c.id}-${index}`)
        }
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(28)

      List() {
        ForEach(this.pickEntries, (e: Entry) => {
          ListItem() {
            Row({ space: 10 }) {
              Text('📁').fontSize(17)
              Text(e.name).fontSize(15).fontColor(this.th().onSurface).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 12, bottom: 12 })
            .onClick(() => {
              const next: Crumb[] = this.pickCrumbs.slice();
              next.push({ id: e.id, name: e.name });
              this.pickCrumbs = next;
              this.loadPick();
            })
          }
        }, (e: Entry) => e.id)
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 46 })

      Button(this.pickMode === 'move' ? this.tt('files.moveHere') : this.tt('files.copyHere'))
        .width('90%')
        .height(44)
        .backgroundColor(this.th().primary)
        .fontColor(this.th().onPrimary)
        .onClick(() => this.confirmDestination())
        .margin({ bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surfaceCard)
  }

  @Builder
  listContent() {
    if (this.loading) {
      Column() {
        LoadingProgress().width(36).height(36)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    } else if (this.entries.length === 0) {
      Column({ space: 6 }) {
        Text(this.mode === MODE_SEARCH ? this.tt('files.noMatch') : this.tt('files.empty'))
          .fontSize(15)
          .fontColor(this.th().onSurfaceVariant)
        Text(this.mode === MODE_BROWSE ? this.tt('files.emptyHint') : ' ')
          .fontSize(13)
          .fontColor(this.th().outline)
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    } else {
      List() {
        ForEach(this.entries, (e: Entry) => {
          ListItem() {
        this.entryRow(e)
          }
          .swipeAction({
            start: {
              builder: () => {
                this.swipeEndBtns(e);
              },
              actionAreaDistance: 56
            },
            end: {
              builder: () => {
                this.swipeStartBtn(e);
              },
              actionAreaDistance: 56
            }
          })
        }, (e: Entry) => e.id)
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 52 })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (!this.embedded) {
          this.appBar()
        }
        this.searchBar()

        if (this.error.length > 0) {
          Row() {
            Text(this.error).fontSize(13).fontColor(this.th().error).layoutWeight(1)
            Text('×').fontSize(14).fontColor(this.th().error).onClick(() => this.error = '')
          }
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })
          .backgroundColor(this.th().errorContainer)
        }
        if (this.notice.length > 0) {
          Row() {
            Text(this.notice).fontSize(13).fontColor(this.th().success).layoutWeight(1)
            Text('×').fontSize(14).fontColor(this.th().success).onClick(() => this.notice = '')
          }
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })
          .backgroundColor(this.th().sheetBadgeBg)
        }

        if (this.selecting) {
          this.batchBar()
        }

        if (this.wide && this.showPane) {
          Row() {
            this.listContent()
            Divider().vertical(true).width(1).height('100%').color(this.th().divider)
            Column({ space: SPACE1 }) {
              this.paneHeader()
              PreviewView({
                previewId: this.paneId,
                previewName: this.paneName,
                previewMime: this.paneMime,
                previewSize: this.paneSize,
                previewModified: this.paneModified
              })
            }
            .layoutWeight(1)
            .height('100%')
          }
          .layoutWeight(1)
          .width('100%')
        } else {
          this.listContent()
        }

        this.footer()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surfaceCard)

      if (this.sheet !== SHEET_NONE) {
        this.sheetOverlay()
      }
      if (this.picking) {
        this.pickerOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
