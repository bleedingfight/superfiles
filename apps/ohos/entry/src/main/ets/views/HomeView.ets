import { common } from '@kit.AbilityKit';
import { fileUri, picker, statfs } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { socket } from '@kit.NetworkKit';
import { router } from '@kit.ArkUI';
import { Entry, EntryKind, FavoriteEntry, IndexProgressListener, MountInfo, RecentOpen, SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { isMediaName } from '../components/PreviewView';
import { avatarCharOf } from '../common/Avatar';
import { formatBytes, formatDate, formatRelTimeParts , errText} from '../common/Format';
import { FileIcon } from '../common/FileIcon';
import { SelDot } from '../common/SelDot';
import { t } from '../common/L10n';
import { loadMounts, saveMounts, MountConfig } from '../common/MountStore';
import { enqueueScan } from '../common/ScanCenter';
import { ensureMounted } from '../common/MountOps';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_M, RADIUS_PILL,
  SPACE1, SPACE2, SPACE3, SPACE4, SPACE6, T_APPBAR, T_CARD_TITLE, T_FILENAME, T_SECONDARY
} from '../common/Tokens';

interface PreviewParams {
  ids: string[];
  names: string[];
  mimes: string[];
  sizes: number[];
  mods: number[];
  index: number;
}

interface Usage {
  usedGb: string;
  restGb: string;
  fraction: number;
  percent: string;
}

/** Home tab — ported section by section from Android HomeScreen.kt. */
@Component
export struct HomeView {
  @State usage: Usage = { usedGb: '--', restGb: 'GB / -- GB', fraction: 0, percent: '' };
  @State recents: Entry[] = [];
  @State recentsOpened: number[] = [];
  @State favorites: FavoriteEntry[] = [];
  @State mounts: MountInfo[] = [];
  @State configs: MountConfig[] = [];
  @State probeStates: number[] = [];
  @State error: string = '';
  @State notice: string = '';
  @State showStorage: boolean = false;
  @State localUri: string = '';
  @State localName: string = '';
  @State mountMenuRoot: string = '';
  @State mountMenuLabel: string = '';
  @State entryMenuId: string = '';
  @State entryMenuName: string = '';
  @State entryMenuIsRecent: boolean = false;
  @State recentSelMode: boolean = false;
  @State recentSel: string[] = [];
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfNick') nick: string = '';
  @StorageLink('sfTab') @Watch('onTabChange') currentTab: number = 0;
  private core: SuperFiles | null = null;
  private filesDir: string = '';
  @StorageLink('sfScanningId') scanId: string = '';
  @StorageLink('sfScanLabel') scanLabel: string = '';
  @StorageLink('sfScanFraction') scanFrac: number = -1;
  /** 拖动排序：dragSrc=被拖行原始下标，hoverPos=当前悬停行；快照保证重复/过期事件幂等。 */
  private dragSrc: number = -1;
  private hoverPos: number = -1;
  private dragSnapConfigs: MountConfig[] = [];
  private dragSnapProbe: number[] = [];
  private dragLabel: string = '';

  private th(): Palette {
    return theme(this.dark);
  }

  /** 每次切回首页都重新探测一遍网络存储。 */
  onTabChange(): void {
    if (this.currentTab === 0) {
      this.reload();
    }
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.filesDir = ctx.filesDir;
    try {
      this.core = getCore(ctx);
      this.loadUsage();
      this.loadLocalGrant();
      this.reload();
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
    }
  }

  private loadUsage(): void {
    // 用应用自身目录做 statfs 路径：与 /data 同一 userdata 分区，但 /data 本身
    // 对应用进程不可搜索（EACCES），filesDir 一定可访问。
    let path: string = this.filesDir.length > 0 ? this.filesDir : '/data';
    try {
      const total: number = statfs.getTotalSizeSync(path);
      const avail: number = statfs.getFreeSizeSync(path);
      const used: number = total - avail;
      const fraction: number = total > 0 ? Math.max(0, Math.min(1, used / total)) : 0;
      const pct: string = (fraction * 100).toFixed(1);
      this.usage = {
        usedGb: (used / (1 << 30)).toFixed(1),
        restGb: `GB / ${Math.round(total / (1 << 30))} GB`,
        fraction: fraction,
        percent: this.tt('home.percentUsed', pct)
      };
    } catch (e) {
      this.usage = { usedGb: '--', restGb: 'GB / -- GB', fraction: 0, percent: '' };
    }
  }

  private reload(): void {
    if (this.core === null) {
      return;
    }
    try {
      const rec: RecentOpen[] = this.core.recentFiles(8);
      const items: Entry[] = [];
      const opened: number[] = [];
      for (const r of rec) {
        items.push(r.entry);
        opened.push(Number(r.openedMs));
      }
      this.recents = items;
      this.recentsOpened = opened;
      this.favorites = this.core.favorites(5);
      this.mounts = this.core.mounts();
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.configs = loadMounts(ctx);
      this.probeAll();
      this.error = '';
    } catch (e) {
      this.error = this.tt('files.readFailed') + '：' + errText(e);
    }
  }

  // ---- greeting --------------------------------------------------------------
  private greeting(): string {
    const h: number = new Date().getHours();
    if (h >= 5 && h < 11) {
      return this.tt('home.greeting.morning');
    }
    if (h >= 11 && h < 14) {
      return this.tt('home.greeting.noon');
    }
    if (h >= 14 && h < 18) {
      return this.tt('home.greeting.afternoon');
    }
    if (h >= 18 && h < 23) {
      return this.tt('home.greeting.evening');
    }
    return this.tt('home.greeting.night');
  }

  private tail(): string {
    const h: number = new Date().getHours();
    const day: number = Math.floor(Date.now() / 86400000);
    let a: string;
    let b: string;
    if (h >= 5 && h < 11) {
      a = this.tt('home.tail.m1');
      b = this.tt('home.tail.m2');
    } else if (h >= 11 && h < 14) {
      a = this.tt('home.tail.n1');
      b = this.tt('home.tail.n2');
    } else if (h >= 14 && h < 18) {
      a = this.tt('home.tail.a1');
      b = this.tt('home.tail.a2');
    } else if (h >= 18 && h < 23) {
      a = this.tt('home.tail.e1');
      b = this.tt('home.tail.e2');
    } else {
      a = this.tt('home.tail.g1');
      b = this.tt('home.tail.g2');
    }
    return day % 2 === 0 ? a : b;
  }

  private greetingLine(): string {
    const g: string = this.greeting();
    const n: string = this.nick.trim();
    return n.length === 0 ? `${g}。${this.tail()}` : `${g}，${n}。${this.tail()}`;
  }

  // ---- helpers ----------------------------------------------------------------
  private openFolder(id: string): void {
    AppStorage.setOrCreate('sfOpenId', id);
    AppStorage.setOrCreate('sfTab', 1);
  }

  private openEntry(e: Entry): void {
    if (e.kind === EntryKind.Directory) {
      this.openFolder(e.id);
      return;
    }
    // 最近打开里的媒体串成画廊，左右滑切换
    const media: Entry[] = [];
    for (const x of this.recents) {
      if (x.kind !== EntryKind.Directory && this.isMediaFile(x.name)) {
        media.push(x);
      }
    }
    let idx: number = -1;
    for (let i = 0; i < media.length; i++) {
      if (media[i].id === e.id) {
        idx = i;
      }
    }
    if (idx < 0) {
      media.push(e);
      idx = media.length - 1;
    }
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
      ids: ids, names: names, mimes: mimes, sizes: sizes, mods: mods, index: idx
    };
    router.pushUrl({ url: 'pages/Preview', params: params });
  }

  private isMediaFile(name: string): boolean {
    return isMediaName(name);
  }

  /** Relative path of the entry's parent inside the sandbox root (Android FavoriteItem.location). */
  private locationOf(e: Entry): string {
    if (this.core === null) {
      return '/';
    }
    try {
      const parent: string = e.parent === undefined ? this.core.rootId() : e.parent;
      const path: string = this.core.displayPath(parent);
      const rootPath: string = this.core.displayPath(this.core.rootId());
      if (path === rootPath) {
        return '/';
      }
      if (path.indexOf(`${rootPath}/`) === 0) {
        return path.substring(rootPath.length + 1);
      }
      return path;
    } catch (e) {
      return '/';
    }
  }

  private relTime(ms: number): string {
    const p = formatRelTimeParts(ms);
    if (p.kind === 0) {
      return this.tt('home.today', p.arg);
    }
    if (p.kind === 1) {
      return this.tt('home.yesterday', p.arg);
    }
    if (p.kind === 2) {
      return this.tt('home.daysAgo', p.arg);
    }
    return p.arg;
  }

  private protoGlyph(scheme: string): string {
    const s: string = scheme.toLowerCase();
    if (s.indexOf('smb') >= 0) {
      return '⇄';
    }
    if (s.indexOf('sftp') >= 0) {
      return '⌘';
    }
    if (s.indexOf('webdav') >= 0) {
      return '☁';
    }
    return '☁';
  }

  // ---- 本机存储授权（DocumentViewPicker，授权有效期到重启） ----------------------
  private grantPath(): string {
    return `${this.filesDir}/localdir.conf`;
  }

  private loadLocalGrant(): void {
    try {
      if (!fileIo.accessSync(this.grantPath())) {
        return;
      }
      const text: string = fileIo.readTextSync(this.grantPath());
      const sep: number = text.indexOf('\n');
      if (sep <= 0) {
        return;
      }
      const uri: string = text.substring(0, sep);
      const name: string = text.substring(sep + 1).trim();
      // 验证授权仍有效（重启后失效）
      try {
        fileIo.listFileSync(uri);
      } catch (e) {
        return;
      }
      this.localUri = uri;
      this.localName = name;
      AppStorage.setOrCreate('sfLocalUri', uri);
      AppStorage.setOrCreate('sfLocalName', name);
    } catch (e) {
      // ignore
    }
  }

  private saveLocalGrant(uri: string, name: string): void {
    try {
      const f = fileIo.openSync(this.grantPath(),
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, `${uri}\n${name}`);
      fileIo.closeSync(f);
    } catch (e) {
      // ignore
    }
  }

  private clearLocalGrant(): void {
    this.localUri = '';
    this.localName = '';
    AppStorage.setOrCreate('sfLocalUri', '');
    AppStorage.setOrCreate('sfLocalName', '');
    try {
      if (fileIo.accessSync(this.grantPath())) {
        fileIo.unlinkSync(this.grantPath());
      }
    } catch (e) {
      // ignore
    }
  }

  private openLocalBrowse(): void {
    if (this.localUri.length > 0) {
      try {
        fileIo.listFileSync(this.localUri);
      } catch (e) {
        this.clearLocalGrant();
        this.error = this.tt('home.expired');
        return;
      }
      router.pushUrl({ url: 'pages/LocalBrowse', params: { uri: this.localUri, title: this.localName } });
      return;
    }
    this.pickLocalFolder();
  }

  /** 拉起系统目录选择器授权；授权成功后保存并直接进入浏览。 */
  private pickLocalFolder(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let docPicker: picker.DocumentViewPicker;
    try {
      docPicker = new picker.DocumentViewPicker(ctx);
    } catch (e) {
      this.error = this.tt('home.grantFailed') + '：' + errText(e);
      return;
    }
    docPicker.select({ selectMode: picker.DocumentSelectMode.FOLDER }).then((uris: string[]) => {
      if (uris.length === 0) {
        return;
      }
      const raw: string = uris[0];
      // picker 返回的是 file://docs/... URI；fs API 需要真实路径
      let realPath: string = raw;
      try {
        realPath = new fileUri.FileUri(raw).path;
      } catch (e) {
        realPath = raw.replace(/^file:\/\//, '');
      }
      const slash: number = realPath.lastIndexOf('/');
      let name: string = slash >= 0 ? realPath.substring(slash + 1) : '本机存储';
      try {
        name = decodeURIComponent(name);
      } catch (e) {
        // keep raw
      }
      // 验证一次：路径不可用就直接提示，不进浏览页
      try {
        fileIo.listFileSync(realPath);
      } catch (e) {
        this.error = this.tt('home.grantFailed') + '：' + errText(e);
        return;
      }
      this.saveLocalGrant(realPath, name);
      this.localUri = realPath;
      this.localName = name;
      AppStorage.setOrCreate('sfLocalUri', realPath);
      AppStorage.setOrCreate('sfLocalName', name);
      router.pushUrl({ url: 'pages/LocalBrowse', params: { uri: realPath, title: name } });
    }).catch(() => {
      this.error = this.tt('home.grantFailed', '');
    });
  }

  /**
   * 打开首页时快速探测每个已保存连接（TCP 2s 超时）。
   * 已连接的直接算在线；探测失败才在行下显示「离线」。
   */
  private probeAll(): void {
    const states: number[] = [];
    for (const c of this.configs) {
      states.push(this.isOnline(c.rootId) ? 1 : 0);
    }
    this.probeStates = states;
    for (let i = 0; i < this.configs.length; i++) {
      if (states[i] === 1) {
        continue;
      }
      this.probeOne(this.configs[i], i);
    }
  }

  private probeTarget(c: MountConfig): string {
    let host: string = c.host.trim();
    let scheme: string = '';
    const schemeAt: number = host.indexOf('://');
    if (schemeAt > 0) {
      scheme = host.substring(0, schemeAt).toLowerCase();
      host = host.substring(schemeAt + 3);
    }
    const slash: number = host.indexOf('/');
    if (slash >= 0) {
      host = host.substring(0, slash);
    }
    const colon: number = host.indexOf(':');
    if (colon >= 0) {
      host = host.substring(0, colon);
    }
    if (scheme.length > 0 || c.proto === 'WebDAV') {
      return `${host}|${scheme === 'http' ? 80 : 443}`;
    }
    if (c.proto === 'SMB') {
      return `${host}|${c.port.trim().length === 0 ? 445 : Number(c.port)}`;
    }
    if (c.proto === 'SFTP') {
      return `${host}|${c.port.trim().length === 0 ? 22 : Number(c.port)}`;
    }
    return '';
  }

  private probeOne(c: MountConfig, index: number): void {
    // 云盘没有固定可探测端口，不做离线判定
    if (c.proto === 'Dropbox' || c.proto === 'GoogleDrive') {
      return;
    }
    const target: string = this.probeTarget(c);
    if (target.length === 0) {
      return;
    }
    const bar: number = target.lastIndexOf('|');
    const host: string = target.substring(0, bar);
    const port: number = Number(target.substring(bar + 1));
    if (host.length === 0 || port <= 0) {
      return;
    }
    try {
      const tcp = socket.constructTCPSocketInstance();
      tcp.connect({
        address: { address: host, port: port, family: 1 },
        timeout: 2000
      }).then(() => {
        this.setProbeState(index, 1);
        try {
          tcp.close();
        } catch (e) {
          // ignore
        }
      }).catch(() => {
        this.setProbeState(index, 2);
        try {
          tcp.close();
        } catch (e) {
          // ignore
        }
      });
    } catch (e) {
      this.setProbeState(index, 2);
    }
  }

  private setProbeState(index: number, state: number): void {
    if (index < 0 || index >= this.probeStates.length) {
      return;
    }
    const next: number[] = this.probeStates.slice();
    next[index] = state;
    this.probeStates = next;
  }

  private isOnline(rootId: string): boolean {
    if (rootId.length === 0) {
      return false;
    }
    for (const m of this.mounts) {
      if (m.rootId === rootId) {
        return true;
      }
    }
    return false;
  }

  /** 离线配置点击：用保存的凭据重连，成功后直接打开。 */
  private reconnectAndOpen(c: MountConfig): void {
    if (this.core === null) {
      return;
    }
    if (this.isOnline(c.rootId)) {
      this.openFolder(c.rootId);
      return;
    }
    try {
      let rootId: string = '';
      if (c.proto === 'SMB') {
        rootId = this.core.mountSmb(c.label, c.host, c.share, c.user, c.pass,
          c.port.trim().length === 0 ? 445 : Number(c.port));
      } else if (c.proto === 'WebDAV') {
        rootId = this.core.mountWebdav(c.label, c.host, c.user, c.pass);
      } else if (c.proto === 'SFTP') {
        rootId = this.core.mountSftp(c.label, c.host,
          c.port.trim().length === 0 ? 22 : Number(c.port), c.user, c.pass);
      } else if (c.proto === 'Dropbox') {
        rootId = this.core.mountDropbox(c.label, c.host, c.share, c.user, c.pass);
      } else {
        rootId = this.core.mountGoogleDrive(c.label, c.host, c.share, c.user, c.pass);
      }
      c.rootId = rootId;
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      saveMounts(ctx, this.configs);
      this.mounts = this.core.mounts();
      this.openFolder(rootId);
    } catch (e) {
      this.error = this.tt('mine.mountFailed') + '：' + errText(e);
    }
  }

  private removeConfig(c: MountConfig): void {
    if (this.core !== null && this.isOnline(c.rootId)) {
      try {
        this.core.unmount(c.rootId);
      } catch (e) {
        // best effort
      }
    }
    const next: MountConfig[] = [];
    for (const x of this.configs) {
      if (x.label !== c.label) {
        next.push(x);
      }
    }
    this.configs = next;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    saveMounts(ctx, next);
    this.reload();
  }

  /** 拖动悬停到某行：只记录悬停位（拖动中不改数据，避免事件风暴打乱顺序）。 */
  private dragHover(pos: number): void {
    if (this.dragSrc < 0) {
      return;
    }
    this.hoverPos = pos;
  }

  /** 松手落在目标行：基于拖动开始时的快照做一次换位并落盘（幂等，重复调用安全）。 */
  private dragDrop(target: number): void {
    const src: number = this.dragSrc;
    const snap: MountConfig[] = this.dragSnapConfigs;
    if (src < 0 || target < 0 || target >= snap.length || src >= snap.length) {
      return;
    }
    const item: MountConfig = snap[src];
    const rest: MountConfig[] = [];
    for (let i = 0; i < snap.length; i++) {
      if (i !== src) {
        rest.push(snap[i]);
      }
    }
    rest.splice(target, 0, item);
    this.configs = rest;
    if (this.dragSnapProbe.length === snap.length) {
      const pst: number = this.dragSnapProbe[src];
      const prest: number[] = [];
      for (let i = 0; i < this.dragSnapProbe.length; i++) {
        if (i !== src) {
          prest.push(this.dragSnapProbe[i]);
        }
      }
      prest.splice(target, 0, pst);
      this.probeStates = prest;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    saveMounts(ctx, this.configs);
    this.dragSrc = -1;
    this.hoverPos = -1;
    this.dragSnapConfigs = [];
    this.dragSnapProbe = [];
  }

  /** 拖动结束：若未触发 drop（取消/拖出列表），仅复位状态。 */
  private dragFinish(): void {
    this.dragSrc = -1;
    this.hoverPos = -1;
    this.dragSnapConfigs = [];
    this.dragSnapProbe = [];
  }

  /** 拖动过程中跟随手指的浮动预览（卡片样式，与列表行一致）。 */
  @Builder
  dragRowPreview() {
    Row() {
      Text(this.dragLabel)
        .fontSize(T_FILENAME)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.th().onSurface)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('88%')
    .height(64)
    .padding({ left: SPACE4 })
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .shadow({ radius: 10, color: '#40000000' })
  }

  private unmount(rootId: string, label: string): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.unmount(rootId);
      this.notice = this.tt('mine.unmounted', label);
      this.reload();
    } catch (e) {
      this.error = this.tt('mine.unmountFailed') + '：' + errText(e);
    }
  }

  private isFavorite(id: string): boolean {
    for (const f of this.favorites) {
      if (f.entry.id === id) {
        return true;
      }
    }
    return false;
  }

  private favoriteEntry(e: Entry): void {
    if (this.core === null) {
      return;
    }
    try {
      if (this.isFavorite(e.id)) {
        this.core.removeFavorite(e.id);
        this.notice = this.tt('files.favoriteRemoved');
      } else {
        this.core.addFavorite(e.id);
        this.notice = this.tt('files.favoriteAdded');
      }
      this.reload();
    } catch (err) {
      this.error = this.tt('files.favoriteFailed') + '：' + errText(err);
    }
  }

  private removeRecentEntry(id: string): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.removeRecent(id);
      this.reload();
    } catch (err) {
      this.error = errText(err);
    }
  }

  private openEntryMenu(e: Entry, isRecent: boolean): void {
    this.entryMenuId = e.id;
    this.entryMenuName = e.name;
    this.entryMenuIsRecent = isRecent;
  }

  private deleteEntry(id: string): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.remove(id, true);
      this.reload();
    } catch (e) {
      this.error = this.tt('files.deleteFailed') + '：' + errText(e);
    }
  }

  // ---- recents selection state -------------------------------------------------
  private toggleRecentSel(id: string): void {
    const next: string[] = this.recentSel.slice();
    const at: number = next.indexOf(id);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(id);
    }
    this.recentSel = next;
    if (next.length === 0) {
      this.recentSelMode = false;
    }
  }

  private deleteRecentSelection(): void {
    if (this.core === null) {
      return;
    }
    try {
      for (const id of this.recentSel) {
        try {
          this.core.removeRecent(id);
        } catch (e) {
          // continue with the rest
        }
      }
      this.recentSelMode = false;
      this.recentSel = [];
      this.reload();
    } catch (e) {
      this.error = this.tt('files.batchDeleteFailed') + '：' + errText(e);
    }
  }

  @Builder
  categoryCard(glyph: string, key: string) {
    Column({ space: 6 }) {
      Text(glyph).fontSize(22)
      Text(this.tt('home.cat.' + key))
        .fontSize(12)
        .fontColor(this.th().onSurface)
    }
    .layoutWeight(1)
    .height(76)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      AppStorage.setOrCreate('sfCategory', key);
      AppStorage.setOrCreate('sfTab', 1);
    })
  }

  @Builder
  categoriesRow() {
    Row({ space: SPACE2 }) {
      this.categoryCard('🖼', 'image')
      this.categoryCard('🎬', 'video')
      this.categoryCard('📄', 'docs')
      this.categoryCard('🎵', 'audio')
      this.categoryCard('🗜', 'archives')
    }
    .width('100%')
  }

  // ---- building blocks ----------------------------------------------------------
  @Builder
  greetingHeader() {
    Row({ space: SPACE3 }) {
      Column({ space: SPACE1 }) {
        Text(this.tt('home.brand'))
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.greetingLine())
          .fontSize(11)
          .fontColor(this.th().onSurfaceVariant)
          .maxLines(2)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column() {
        Text(avatarCharOf(this.nick))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().primaryWarm)
      }
      .width(40)
      .height(40)
      .borderRadius(RADIUS_PILL)
      .backgroundColor(this.th().avatarBg)
      .justifyContent(FlexAlign.Center)
      .onClick(() => AppStorage.setOrCreate('sfTab', 2))
    }
    .width('100%')
  }

  @Builder
  searchEntryBar() {
    Row({ space: SPACE2 }) {
      Text('🔍').fontSize(14)
      Text(this.tt('home.searchPh'))
        .fontSize(13)
        .fontColor(this.th().onSurfaceVariant)
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: SPACE4, right: SPACE4 })
    .backgroundColor(this.th().searchFieldBg)
    .borderRadius(RADIUS_PILL)
    .onClick(() => {
      AppStorage.setOrCreate('sfTab', 1);
    })
  }

  @Builder
  usageBar() {
    Row() {
      Row().width(`${this.usage.fraction * 100}%`).height(8).backgroundColor(this.th().primary)
      Row().layoutWeight(1).height(8).backgroundColor(this.th().usageTrack)
    }
    .width('100%')
    .height(8)
    .borderRadius(RADIUS_PILL)
    .clip(true)
  }

  @Builder
  usageCard() {
    Column({ space: SPACE3 }) {
      Row() {
        Column({ space: SPACE1 }) {
          Text(this.tt('home.storage')).fontSize(11).fontColor(this.th().usageDeep).width('100%')
          Row({ space: SPACE1 }) {
            Text(this.usage.usedGb).fontSize(24).fontWeight(FontWeight.Medium)
              .fontColor(this.th().usageDeep)
            Text(this.usage.restGb).fontSize(11).fontColor(this.th().primary).margin({ bottom: 4 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: SPACE1 }) {
          Text(this.tt('home.manage')).fontSize(11).fontColor(this.th().primary)
          Text('↗').fontSize(12).fontColor(this.th().primary)
        }
        .padding(SPACE1)
        .onClick(() => {
          this.showStorage = true;
        })
      }
      .width('100%')

      this.usageBar()

      Row() {
        Text(this.usage.percent).fontSize(10).fontColor(this.th().primary)
        Blank().layoutWeight(1)
        if (this.scanId.length > 0) {
          Row({ space: 4 }) {
            Progress({ value: this.scanFrac * 100, total: 100, type: ProgressType.Ring })
              .width(12)
              .height(12)
              .color(this.th().primary)
            Text(this.scanPercentText())
              .fontSize(10)
              .fontColor(this.th().primary)
          }
        } else if (this.indexDone()) {
          Row({ space: 3 }) {
            Text('✓')
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().success)
            Text(this.tt('home.indexUpdated'))
              .fontSize(10)
              .fontColor(this.th().success)
          }
        } else {
          Text(this.tt('home.indexIdle'))
            .fontSize(10)
            .fontColor(this.th().onSurfaceVariant)
        }
      }
      .width('100%')
      .onClick(() => {
        router.pushUrl({ url: 'pages/IndexManage' });
      })
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceTint)
    .borderRadius(RADIUS_L)
    .alignItems(HorizontalAlign.Start)
  }

  private indexDone(): boolean {
    if (this.core === null) {
      return false;
    }
    try {
      return Number(this.core.indexCount()) > 0;
    } catch (e) {
      return false;
    }
  }

  @Builder
  rootCard(glyph: string, name: string, sub: string, tint: string, action: () => void) {
    Column({ space: SPACE1 }) {
      Text(glyph).fontSize(20).fontColor(tint)
      Text(name).fontSize(T_FILENAME).fontColor(this.th().onSurface).width('100%')
      Text(sub).fontSize(10).fontColor(this.th().onSurfaceVariant).width('100%')
    }
    .layoutWeight(1)
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .alignItems(HorizontalAlign.Start)
    .onClick(action)
  }

  @Builder
  sectionHeader(title: string, action: string, onAction: () => void) {
    Row() {
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.th().onSurface)
        .layoutWeight(1)
      if (action.length > 0) {
        Text(action).fontSize(T_SECONDARY).fontColor(this.th().primary).onClick(onAction)
      }
    }
    .width('100%')
    .padding({ top: SPACE1 })
  }

  /** FileListRow contract (docs/06 §2): badge + name/meta + trailing slot. */
  @Builder
  fileRow(e: Entry, meta: string, trailing: boolean) {
    Row({ space: SPACE3 }) {
      FileIcon({ name: e.name, isDir: e.kind === EntryKind.Directory, dark: this.dark, box: 32 })
      Column({ space: 1 }) {
        Text(e.name)
          .fontSize(T_FILENAME)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(meta).fontSize(11).fontColor(this.th().onSurfaceVariant).maxLines(1).width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (trailing) {
        Text('⋯').fontSize(16).fontColor(this.th().outline)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding({ left: SPACE4, right: SPACE4 })
  }

  @Builder
  swipeDeleteBtn(rootId: string, label: string) {
    Column() {
      Text(this.tt('common.delete'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.unmount(rootId, label);
    })
  }

  @Builder
  swipeMoreBtn(e: Entry, isRecent: boolean) {
    Column() {
      Text(this.tt('common.more'))
        .fontSize(13)
        .fontColor(this.th().onPrimary)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().primary)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.openEntryMenu(e, isRecent))
  }

  @Builder
  swipeFavBtn(e: Entry) {
    Column() {
      Text(this.isFavorite(e.id) ? this.tt('home.unfavorite') : this.tt('files.favorites'))
        .fontSize(13)
        .fontColor(this.th().onPrimary)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().primaryWarm)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.favoriteEntry(e))
  }

  @Builder
  swipeRecentRemoveBtn(id: string) {
    Column() {
      Text(this.tt('home.removeRecent'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.removeRecentEntry(id))
  }

  @Builder
  swipeFavDeleteBtns(e: Entry) {
    Row() {
      this.swipeFavBtn(e);
      this.swipeDeleteEntryBtn(e.id);
    }
    .height('100%')
  }

  @Builder
  swipeFavRemoveRecentBtns(e: Entry) {
    Row() {
      this.swipeFavBtn(e);
      this.swipeRecentRemoveBtn(e.id);
    }
    .height('100%')
  }

  @Builder
  swipeDeleteEntryBtn(id: string) {
    Column() {
      Text(this.tt('common.delete'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.deleteEntry(id);
    })
  }

  // ---- sections -------------------------------------------------------------------
  @Builder
  localStorageSection() {
    this.sectionHeader(this.tt('home.localStorage'), '', () => {
    })
    Row({ space: SPACE2 }) {
      this.rootCard('💾', this.tt('home.localDevice'),
        this.localUri.length > 0 ? this.tt('home.localGrantedSub', this.localName) : this.tt('home.localGrantSub'),
        this.th().primary, () => {
          this.openLocalBrowse();
        })
    }
    .width('100%')
  }

  @Builder
  networkMountsSection() {
    if (this.configs.length > 0) {
      this.sectionHeader(this.tt('home.networkStorage'), this.tt('home.manage'),
        () => router.pushUrl({ url: 'pages/NetworkStorage' }))
      List() {
        ForEach(this.configs, (c: MountConfig, index: number) => {
          ListItem() {
            Row({ space: SPACE3 }) {
              if (c.proto === 'Dropbox') {
                this.mountDropboxIcon()
              } else if (c.proto === 'GoogleDrive') {
                this.mountGdriveIcon()
              } else {
                Text(this.protoGlyph(c.proto)).fontSize(18).fontColor(this.th().primary).width(24)
              }
              Column({ space: 1 }) {
                Text(c.label)
                  .fontSize(T_FILENAME)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.th().onSurface)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                if (index < this.probeStates.length && this.probeStates[index] === 2) {
                  Text(this.tt('home.statusOffline', c.proto.toUpperCase()))
                    .fontSize(11)
                    .fontColor(this.th().error)
                    .maxLines(1)
                    .width('100%')
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .constraintSize({ minHeight: 72 })
            .padding({ left: SPACE4, right: SPACE4 })
          }
          .swipeAction({
            start: {
              builder: () => {
                this.swipeRemoveConfigBtn(c);
              },
              actionAreaDistance: 56
            },
            end: {
              builder: () => {
                this.swipeMountMoreBtn(c);
              },
              actionAreaDistance: 56
            }
          })
          .onClick(() => this.reconnectAndOpen(c))
          // 长按拖动排序（拖到目标行即换位，松手落盘）
          .draggable(true)
          .onDragStart(() => {
            this.dragSrc = index;
            this.hoverPos = index;
            this.dragSnapConfigs = this.configs.slice();
            this.dragSnapProbe = this.probeStates.slice();
            this.dragLabel = c.label;
            return { builder: () => {
              this.dragRowPreview();
            } };
          })
          .onDragEnter(() => {
            this.dragHover(index);
          })
          .onDrop(() => {
            this.dragDrop(index);
          })
          .onDragEnd(() => {
            this.dragFinish();
          })
        }, (c: MountConfig) => c.label)
      }
      .width('100%')
      .height(this.configs.length * 72 + 2)
      .enableScrollInteraction(false)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 56 })
      .backgroundColor(this.th().surfaceCard)
      .borderRadius(RADIUS_M)
    }
  }

  /** 已配置云盘行的品牌图标：Dropbox 蓝盒（上排两菱形相接，下排两片斜板垂在外沿）。 */
  @Builder
  mountDropboxIcon() {
    Column({ space: 0 }) {
      Row({ space: 0 }) {
        Polygon().points([[0, 5], [6.5, 0], [13, 5], [6.5, 10]]).fill('#0061FF').width(13).height(11)
        Polygon().points([[0, 5], [6.5, 0], [13, 5], [6.5, 10]]).fill('#0061FF').width(13).height(11)
      }
      .width(26)
      Row({ space: 0 }) {
        Polygon().points([[0, 0], [6.5, 5], [6.5, 11], [0, 6]]).fill('#0061FF').width(6.5).height(11)
        Blank().width(13)
        Polygon().points([[6.5, 0], [0, 5], [0, 11], [6.5, 6]]).fill('#0061FF').width(6.5).height(11)
      }
      .width(26)
      .justifyContent(FlexAlign.Center)
    }
    .width(28)
    .height(24)
    .justifyContent(FlexAlign.Center)
  }

  /** 已配置云盘行的品牌图标：Google Drive 三角框标（绿/蓝/黄色带，中间镂空）。 */
  @Builder
  mountGdriveIcon() {
    Stack() {
      Polygon().points([[13, 0.92], [13, 8.25], [8.1, 15.58], [1.63, 19.25]]).fill('#34A853').width(26).height(20)
      Polygon().points([[13, 0.92], [24.38, 19.25], [17.9, 15.58], [13, 8.25]]).fill('#4285F4').width(26).height(20)
      Polygon().points([[1.63, 19.25], [24.38, 19.25], [17.9, 15.58], [8.1, 15.58]]).fill('#FBBC04').width(26).height(20)
    }
    .width(28)
    .height(22)
  }

  @Builder
  swipeMountMoreBtn(c: MountConfig) {
    Column() {
      Text(this.tt('common.more'))
        .fontSize(13)
        .fontColor(this.th().onPrimary)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().primary)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.mountMenuRoot = c.label;
      this.mountMenuLabel = c.label;
    })
  }

  @Builder
  swipeRemoveConfigBtn(c: MountConfig) {
    Column() {
      Text(this.tt('home.removeMount'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.removeConfig(c);
    })
  }

  @Builder
  favoritesSection() {
    if (this.favorites.length > 0) {
    this.sectionHeader(this.tt('files.favorites'), this.tt('home.manage'),
      () => router.pushUrl({ url: 'pages/Favorites' }))
    List() {
      ForEach(this.favorites, (f: FavoriteEntry, index: number) => {
        ListItem() {
          this.fileRow(f.entry, this.locationOf(f.entry), false)
        }
        .swipeAction({
          start: {
            builder: () => {
              this.swipeFavDeleteBtns(f.entry);
            },
            actionAreaDistance: 56
          },
          end: {
            builder: () => {
              this.swipeMoreBtn(f.entry, false);
            },
            actionAreaDistance: 56
          }
        })
        .onClick(() => this.openEntry(f.entry))
      }, (f: FavoriteEntry) => f.entry.id)
    }
    .width('100%')
    .height(this.favorites.length * 72 + 2)
    .enableScrollInteraction(false)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 56 })
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    }
  }

  @Builder
  recentSection() {
    this.sectionHeader(this.tt('home.recent'), this.tt('home.seeAll'),
      () => router.pushUrl({ url: 'pages/RecentsPage' }))
    if (this.recentSelMode) {
      Row({ space: SPACE2 }) {
        Text(this.tt('files.selectedN', `${this.recentSel.length}`))
          .fontSize(T_SECONDARY)
          .fontColor(this.th().onSurface)
          .layoutWeight(1)
        Text(this.tt('common.delete'))
          .fontSize(T_SECONDARY)
          .fontColor(this.th().error)
          .onClick(() => this.deleteRecentSelection())
        Text('✕')
          .fontSize(14)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => {
            this.recentSelMode = false;
            this.recentSel = [];
          })
      }
      .width('100%')
      .padding({ top: SPACE1, bottom: SPACE1 })
    }
    if (this.recents.length === 0) {
      Text(this.tt('home.noRecentFiles'))
        .fontSize(12)
        .fontColor(this.th().onSurfaceVariant)
        .width('100%')
        .padding({ top: SPACE2, bottom: SPACE2 })
    } else {
    List() {
      ForEach(this.recents, (e: Entry, index: number) => {
        ListItem() {
          Row({ space: SPACE3 }) {
            if (this.recentSelMode) {
              SelDot({ selected: this.recentSel.indexOf(e.id) >= 0, dark: this.dark })
            }
            FileIcon({ name: e.name, isDir: e.kind === EntryKind.Directory, dark: this.dark, box: 32 })
            Column({ space: 1 }) {
              Text(e.name)
                .fontSize(T_FILENAME)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.th().onSurface)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(`${formatBytes(Number(e.size))} · ${this.relTime(this.recentsOpened[index])}`)
                .fontSize(11)
                .fontColor(this.th().onSurfaceVariant)
                .maxLines(1)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            if (!this.recentSelMode) {
              Text('⋯').fontSize(16).fontColor(this.th().outline)
                .onClick(() => this.openEntry(e))
            }
          }
          .width('100%')
          .constraintSize({ minHeight: 72 })
          .padding({ left: SPACE4, right: SPACE4 })
        }
        .swipeAction({
          start: {
            builder: () => {
              this.swipeFavRemoveRecentBtns(e);
            },
            actionAreaDistance: 56
          },
          end: {
            builder: () => {
              this.swipeMoreBtn(e, true);
            },
            actionAreaDistance: 56
          }
        })
        .onClick(() => {
          if (this.recentSelMode) {
            this.toggleRecentSel(e.id);
          } else if (e.kind === EntryKind.Directory) {
            this.openFolder(e.id);
          } else {
            this.openEntry(e);
          }
        })
        .gesture(LongPressGesture({ duration: 400 }).onAction(() => {
          if (!this.recentSelMode) {
            this.recentSelMode = true;
            this.recentSel = [e.id];
          }
        }))
      }, (e: Entry) => e.id)
    }
    .width('100%')
    .height(this.recents.length * 72 + 2)
    .enableScrollInteraction(false)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 56 })
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    }
  }

  // ---- storage sheet（StorageSheet.kt 对齐） -------------------------------------
  @Builder
  storageRow(glyph: string, title: string, subtitle: string, meta: string, action: string, onClick: () => void) {
    Row({ space: SPACE3 }) {
      Text(glyph).fontSize(20).fontColor(this.th().primary).width(28)
      Column({ space: 1 }) {
        Text(title).fontSize(T_FILENAME).fontColor(this.th().onSurface).width('100%')
        if (subtitle.length > 0) {
          Text(subtitle).fontSize(10).fontColor(this.th().onSurfaceVariant).maxLines(1).width('100%')
        }
        if (meta.length > 0) {
          Text(meta).fontSize(10).fontColor(this.th().onSurfaceVariant).maxLines(1).width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(action).fontSize(12).fontColor(this.th().primary)
    }
    .width('100%')
    .padding({ top: SPACE3, bottom: SPACE3 })
    .onClick(onClick)
  }

  @Builder
  storageSheetOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.showStorage = false)
      Column({ space: SPACE2 }) {
        Text(this.tt('home.storageManage'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().onSurface)
          .width('100%')
        this.storageRow('📱', this.tt('home.appStorage'), '',
          `${this.usage.usedGb} ${this.usage.restGb}`, this.tt('home.browse'), () => {
            this.showStorage = false;
            this.openFolder(this.core === null ? '' : this.core.rootId());
          })
        Divider().color(this.th().divider)
        this.storageRow('📁', this.tt('home.localDevice'),
          this.localUri.length > 0 ? this.tt('home.localGrantedSub', this.localName) : '/storage/emulated/0', '',
          this.localUri.length > 0 ? this.tt('home.regrant') : this.tt('home.grant'), () => {
            this.showStorage = false;
            this.pickLocalFolder();
          })
        Row({ space: SPACE1 }) {
          Text('🛡').fontSize(12).fontColor(this.th().outline)
          Text(this.tt('home.privacyNote'))
            .fontSize(11)
            .fontColor(this.th().onSurfaceVariant)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: SPACE2 })
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  // ---- 条目「更多」菜单（右滑 更多 / ⋯） -------------------------------------------
  @Builder
  entryMenuOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.entryMenuId = '')
      Column({ space: SPACE1 }) {
        Text(this.entryMenuName)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Divider().color(this.th().divider)
        this.storageMenuRow(this.tt('common.open'), () => {
          const id: string = this.entryMenuId;
          this.entryMenuId = '';
          for (const e of (this.entryMenuIsRecent ? this.recents : this.allFavoriteEntries())) {
            if (e.id === id) {
              this.openEntry(e);
            }
          }
        })
        if (this.entryMenuIsRecent) {
          this.storageMenuRow(this.tt('files.menuSelect'), () => {
            const id: string = this.entryMenuId;
            this.entryMenuId = '';
            this.recentSelMode = true;
            this.recentSel = [id];
          })
        }
        this.storageMenuRow(this.isFavorite(this.entryMenuId) ? this.tt('home.unfavorite') : this.tt('files.favorites'), () => {
          const id: string = this.entryMenuId;
          this.entryMenuId = '';
          for (const e of (this.entryMenuIsRecent ? this.recents : this.allFavoriteEntries())) {
            if (e.id === id) {
              this.favoriteEntry(e);
            }
          }
        })
        if (this.entryMenuIsRecent) {
          this.storageMenuRow(this.tt('home.removeRecent'), () => {
            const id: string = this.entryMenuId;
            this.entryMenuId = '';
            this.removeRecentEntry(id);
          }, true)
        } else {
          this.storageMenuRow(this.tt('common.delete'), () => {
            const id: string = this.entryMenuId;
            this.entryMenuId = '';
            this.deleteEntry(id);
          }, true)
        }
        Button(this.tt('common.cancel'))
          .width('100%')
          .height(40)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => this.entryMenuId = '')
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  private allFavoriteEntries(): Entry[] {
    const out: Entry[] = [];
    for (const f of this.favorites) {
      out.push(f.entry);
    }
    return out;
  }

  // ---- mount long-press menu --------------------------------------------------------
  /**
   * 手动为挂载创建索引：分类/搜索只查索引，网络挂载默认不进索引，
   * 由用户在此显式触发（增量：mtime 未变的子树整棵跳过）。
   */
  private indexMount(c: MountConfig): void {
    if (this.core === null) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const rootId: string | null = ensureMounted(ctx, this.core, c, this.configs);
    if (rootId === null) {
      this.error = this.tt('mine.mountFailed');
      return;
    }
    enqueueScan({ id: rootId, label: c.label, full: true, force: true });
    this.notice = this.tt('mine.indexQueued', c.label);
  }

  private scanPercentText(): string {
    const pct: string = `${Math.round(Math.max(0, this.scanFrac) * 100)}`;
    if (this.scanLabel.length > 0) {
      return this.tt('home.indexBuilding', this.scanLabel, pct);
    }
    return this.tt('home.indexScanning', pct);
  }

  @Builder
  mountMenuOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.mountMenuRoot = '')
      Column({ space: SPACE1 }) {
        Text(this.mountMenuLabel)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .width('100%')
        Divider().color(this.th().divider)
        this.storageMenuRow(this.tt('common.open'), () => {
          const label: string = this.mountMenuRoot;
          this.mountMenuRoot = '';
          for (const c of this.configs) {
            if (c.label === label) {
              this.reconnectAndOpen(c);
            }
          }
        })
        this.storageMenuRow(this.tt('mine.indexMount'), () => {
          const label: string = this.mountMenuRoot;
          this.mountMenuRoot = '';
          for (const c of this.configs) {
            if (c.label === label) {
              this.indexMount(c);
            }
          }
        })
        this.storageMenuRow(this.tt('common.disconnect'), () => {
          const label: string = this.mountMenuRoot;
          this.mountMenuRoot = '';
          for (const c of this.configs) {
            if (c.label === label) {
              this.removeConfig(c);
            }
          }
        })
        Button(this.tt('common.cancel'))
          .width('100%')
          .height(40)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => this.mountMenuRoot = '')
      }
      .width('100%')
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  @Builder
  storageMenuRow(label: string, action: () => void, danger: boolean = false) {
    Row() {
      Text(label).fontSize(14).fontColor(danger ? this.th().error : this.th().onSurface).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .onClick(action)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: SPACE6 }) {
          this.greetingHeader()
          this.searchEntryBar()
          this.categoriesRow()
          this.usageCard()
          this.localStorageSection()
          this.networkMountsSection()
          this.favoritesSection()
          this.recentSection()

          if (this.error.length > 0) {
            Text(this.error).fontSize(12).fontColor(this.th().error).width('100%')
          }
          if (this.notice.length > 0) {
            Text(this.notice).fontSize(12).fontColor(this.th().success).width('100%')
          }
        }
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE2, bottom: 24 })
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)
      .scrollBar(BarState.Off)

      if (this.showStorage) {
        this.storageSheetOverlay()
      }
      if (this.mountMenuRoot.length > 0) {
        this.mountMenuOverlay()
      }
      if (this.entryMenuId.length > 0) {
        this.entryMenuOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
