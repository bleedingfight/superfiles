import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { CompletedTransfer, ConflictPolicy, Entry, EntryKind, SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { formatBytes, formatDate, formatClock, errText } from '../common/Format';
import { FileIcon } from '../common/FileIcon';
import { SelDot } from '../common/SelDot';
import { t } from '../common/L10n';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_L, RADIUS_M,
  SPACE1, SPACE2, SPACE3, SPACE4, T_APPBAR, T_BODY, T_CARD_TITLE, T_FILENAME, T_SECONDARY
} from '../common/Tokens';

interface CleanItem {
  id: string;
  name: string;
  size: number;
  /** 目录大小还在后台渐进估算时为 false，行内数字显示出扫描标记。 */
  measured: boolean;
  isDir: boolean;
  modified: number;
}

/**
 * 清理页的「传输到本机」条目：同目标同文件可能被传过多次（重试/测试），
 * 每次都是一条任务记录；空间视角它们只有一个文件，折叠为一组——
 * head 取最近一次（时间/大小显示），ids 收齐该组全部记录行，
 * 删除时一并清掉。
 */
interface ArrGroup {
  head: CompletedTransfer;
  ids: string[];
}

const SORT_SIZE: string = 'size';
const SORT_TIME: string = 'time';
const SORT_NAME: string = 'name';

const SHEET_NONE: string = 'none';
const SHEET_MORE: string = 'more';
const SHEET_SORT: string = 'sort';
const SHEET_PICK: string = 'pick';

@Entry
@Component
struct Cleanup {
  @State items: CleanItem[] = [];
  @State arrivals: ArrGroup[] = [];
  @State loaded: boolean = false;
  @State sweeping: boolean = false;
  @State error: string = '';
  @State notice: string = '';
  @State confirming: boolean = false;
  /** 'dir' = 删本机对象；'arrival' = 删一次传输拷入的全部目标文件；'batch' = 批量。 */
  @State confirmKind: string = 'dir';
  @State targetId: string = '';
  @State targetName: string = '';
  @State selecting: boolean = false;
  @State selected: string[] = [];
  @State sortKey: string = SORT_SIZE;
  @State sortAsc: boolean = false;
  @State sheet: string = SHEET_NONE;
  @State pickCrumbs: string[] = [];
  @State pickEntries: Entry[] = [];
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfLang') lang: string = 'auto';
  private core: SuperFiles | null = null;
  /** 扫描队列：顶层目录逐个在后台补齐体积（约每 80ms 一个）。 */
  private sweepQueue: string[] = [];
  private sweepTimer: number = -1;
  private pollTimer: number = -1;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.lang, key, ...args);
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
      return;
    }
    this.scan();
  }

  aboutToDisappear(): void {
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private basename(path: string): string {
    const trimmed: string = path.replace(/\/+$/, '');
    const at: number = trimmed.lastIndexOf('/');
    return at >= 0 ? trimmed.substring(at + 1) : trimmed;
  }

  // ---- 扫描（顶层秒出 + 后台渐进补目录体积） ------------------------------

  private dirSize(id: string, budget: number[]): number {
    if (this.core === null) {
      return 0;
    }
    let total: number = 0;
    let items: Entry[] = [];
    try {
      items = this.core.list(id);
    } catch (e) {
      return 0;
    }
    for (const e of items) {
      if (budget[0] <= 0) {
        return total;
      }
      budget[0] = budget[0] - 1;
      if (e.kind === EntryKind.Directory) {
        total += this.dirSize(e.id, budget);
      } else {
        total += Number(e.size);
      }
    }
    return total;
  }

  private scan(): void {
    if (this.core === null) {
      return;
    }
    try {
      const root: string = this.core.rootId();
      const all: Entry[] = this.core.list(root);
      const out: CleanItem[] = [];
      const queue: string[] = [];
      for (const e of all) {
        if (e.name.startsWith('.')) {
          continue; // 隐藏目录（内核 .tmp 兜底等）不进清理列表
        }
        const isDir: boolean = e.kind === EntryKind.Directory;
        const size: number = isDir ? 0 : Number(e.size);
        if (isDir) {
          queue.push(e.id);
        }
        out.push({
          id: e.id,
          name: e.name,
          size: size,
          measured: !isDir,
          isDir: isDir,
          modified: e.modifiedMs === undefined ? 0 : Number(e.modifiedMs)
        });
      }
      this.applySort(out);
      this.startSweep(queue);
      this.refreshArrivals();
      this.loaded = true;
      this.error = '';
    } catch (e) {
      this.error = this.tt('cl.scanFailed') + '：' + errText(e);
    }
  }

  private startSweep(queue: string[]): void {
    if (this.sweepTimer >= 0) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
    this.sweepQueue = queue;
    this.sweeping = queue.length > 0;
    if (queue.length === 0) {
      return;
    }
    this.sweepTimer = setInterval(() => this.sweepStep(), 80);
  }

  private sweepStep(): void {
    const next: string | undefined = this.sweepQueue.shift();
    if (next === undefined) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
      this.sweeping = false;
      return;
    }
    const size: number = this.dirSize(next, [500]);
    const items: CleanItem[] = this.items.slice();
    for (let i = 0; i < items.length; i++) {
      if (items[i].id === next && items[i].isDir) {
        items[i].size = size;
        items[i].measured = true;
      }
    }
    this.applySort(items);
    if (this.sweeping && this.sweepQueue.length === 0) {
      this.sweeping = false;
      clearInterval(this.sweepTimer);
      this.sweepTimer = -1;
    }
  }

  // ---- 排序 ----------------------------------------------------------------

  private applySort(rows: CleanItem[]): void {
    const asc: number = this.sortAsc ? 1 : -1;
    rows.sort((a: CleanItem, b: CleanItem) => {
      if (this.sortKey === SORT_SIZE) {
        return (a.size - b.size) * asc;
      }
      if (this.sortKey === SORT_TIME) {
        return (a.modified - b.modified) * asc;
      }
      const an: string = a.name.toLowerCase();
      const bn: string = b.name.toLowerCase();
      const cmp: number = an === bn ? 0 : (an < bn ? -1 : 1);
      return cmp * asc;
    });
    this.items = rows;
  }

  private sortArrivals(groups: ArrGroup[]): ArrGroup[] {
    const asc: number = this.sortAsc ? 1 : -1;
    groups.sort((a: ArrGroup, b: ArrGroup) => {
      if (this.sortKey === SORT_SIZE) {
        return (Number(a.head.bytesTotal) - Number(b.head.bytesTotal)) * asc;
      }
      if (this.sortKey === SORT_TIME) {
        return (Number(a.head.finishedAtMs) - Number(b.head.finishedAtMs)) * asc;
      }
      const an: string = this.arrivalTitle(a.head).toLowerCase();
      const bn: string = this.arrivalTitle(b.head).toLowerCase();
      const cmp: number = an === bn ? 0 : (an < bn ? -1 : 1);
      return cmp * asc;
    });
    return groups;
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

  // ---- 传输到本机（完成记录，2s 轮询同步） ---------------------------------

  /** 折叠签名：目标目录 + 传输对象（源文件名集合）一致 = 生命周期同一个文件。 */
  private arrivalSignature(r: CompletedTransfer): string {
    const names: string[] = [];
    for (const src of r.sources) {
      names.push(this.basename(src));
    }
    names.sort();
    return `${r.destDir}|${names.join('\u0001')}`;
  }

  private refreshArrivals(): void {
    if (this.core === null) {
      return;
    }
    try {
      let rows: CompletedTransfer[] = this.core.completedTransfers(50);
      const local: CompletedTransfer[] = [];
      for (const r of rows) {
        if (r.destDir.startsWith('/')) {
          local.push(r); // 只关心落到本机的
        }
      }
      rows = local;
      // 折叠：同签名多条任务（重试/复测）只显示最近的一次；ids 收全组，
      // 删除/移动时一次性清干净，不留「幽灵记录」。
      const bySignature: Map<string, ArrGroup> = new Map();
      for (const r of rows) {
        const sig: string = this.arrivalSignature(r);
        const existing: ArrGroup | undefined = bySignature.get(sig);
        if (existing === undefined) {
          bySignature.set(sig, { head: r, ids: [r.id] });
        } else {
          existing.ids.push(r.id);
          if (Number(r.finishedAtMs) > Number(existing.head.finishedAtMs)) {
            existing.head = r;
          }
        }
      }
      const groups: ArrGroup[] = [];
      for (const g of bySignature.values()) {
        groups.push(g);
      }
      if (this.pollTimer < 0) {
        this.pollTimer = setInterval(() => this.refreshArrivals(), 2000);
      }
      if (this.groupSig(groups) !== this.groupSig(this.arrivals)) {
        this.arrivals = this.sortArrivals(groups);
      }
    } catch (e) {
      // 最近传输读不到不阻塞页面
    }
  }

  private groupSig(groups: ArrGroup[]): string {
    let sig: string = '';
    for (const g of groups) {
      sig += `${g.head.id}:${Number(g.head.bytesTotal)}:${Number(g.head.finishedAtMs)}:${g.ids.length}|`;
    }
    return sig;
  }

  /** 一次传输的目标文件集合：join(destDir, basename(source))。 */
  private arrivalTargets(r: CompletedTransfer): string[] {
    const dir: string = r.destDir.replace(/\/+$/, '');
    const out: string[] = [];
    for (const src of r.sources) {
      const name: string = this.basename(src);
      if (name.length > 0) {
        out.push(`${dir}/${name}`);
      }
    }
    return out;
  }

  private groupById(id: string): ArrGroup {
    let found: ArrGroup = this.arrivals[0];
    for (const g of this.arrivals) {
      if (g.head.id === id) {
        found = g;
      }
    }
    return found;
  }

  /** 条目标题：传的是文件(目录)就叫它自己的名字；多文件 = 首名 + 等 N 项。 */
  private arrivalTitle(r: CompletedTransfer): string {
    if (r.sources.length === 0) {
      return this.tt('cl.arrivals');
    }
    const first: string = this.basename(r.sources[0]);
    if (r.sources.length > 1) {
      return first + this.tt('tr.andMore', `${r.sources.length}`);
    }
    return first;
  }

  /** 所在目录的展示名：displayPath 裁掉应用沙箱前缀；取失败兜底 basename。 */
  private arrivalDirLabel(r: CompletedTransfer): string {
    if (this.core !== null) {
      try {
        let p: string = this.core.displayPath(r.destDir);
        const marker: string = 'storage/';
        const at: number = p.lastIndexOf(marker);
        if (at >= 0) {
          p = p.substring(at + marker.length);
        } else if (p.startsWith('/')) {
          p = p.replace(/^\/+/, '');
        }
        if (p.length > 0) {
          return p;
        }
      } catch (e) {
        // fall through
      }
    }
    return this.basename(r.destDir);
  }

  // ---- 多选 ----------------------------------------------------------------

  private isSelected(tag: string): boolean {
    return this.selected.indexOf(tag) >= 0;
  }

  private toggleSelect(tag: string): void {
    const next: string[] = this.selected.slice();
    const at: number = next.indexOf(tag);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(tag);
    }
    this.selected = next;
    if (next.length === 0) {
      this.exitSelecting();
    }
  }

  private beginSelecting(tag: string): void {
    this.selecting = true;
    this.selected = [tag];
  }

  private selectAll(): void {
    const all: string[] = [];
    for (const g of this.arrivals) {
      all.push(`A:${g.head.id}`);
    }
    for (const it of this.items) {
      all.push(`L:${it.id}`);
    }
    this.selected = all;
  }

  private exitSelecting(): void {
    this.selecting = false;
    this.selected = [];
  }

  /** 多选里某个 tag 的展示名（批量提示、移动确认用）。 */
  private nameOfTag(tag: string): string {
    if (tag.startsWith('A:')) {
      for (const g of this.arrivals) {
        if (g.head.id === tag.substring(2)) {
          return this.arrivalTitle(g.head);
        }
      }
    }
    for (const it of this.items) {
      if ((`L:${it.id}`) === tag) {
        return it.name;
      }
    }
    return tag;
  }

  /** 删除一个条目：arrival = 实际目标文件 + 该组全部记录行；local = 文件/目录本体。 */
  private deleteOne(tag: string): void {
    if (this.core === null) {
      return;
    }
    if (tag.startsWith('A:')) {
      const g: ArrGroup = this.groupById(tag.substring(2));
      for (const target of this.arrivalTargets(g.head)) {
        try {
          this.core.stat(target);
          this.core.remove(target, false);
        } catch (e) {
          // 目标文件已不存在（改名/移动过）——跳过
        }
      }
      for (const id of g.ids) {
        try {
          this.core.forgetTransfer(id);
        } catch (e) {
          // 行已不在也不阻塞
        }
      }
      return;
    }
    const id: string = tag.substring(2);
    let isDir: boolean = false;
    for (const it of this.items) {
      if (it.id === id) {
        isDir = it.isDir;
      }
    }
    this.core.remove(id, isDir);
  }

  private doDelete(): void {
    if (this.core === null) {
      return;
    }
    if (this.confirmKind === 'batch') {
      for (const tag of this.selected) {
        try {
          this.deleteOne(tag);
        } catch (e) {
          // continue
        }
      }
      this.notice = this.tt('cl.deleted', `${this.selected.length}`);
      this.confirming = false;
      this.exitSelecting();
      this.refreshArrivals();
      this.scan();
      return;
    }
    if (this.confirmKind === 'arrival') {
      const g: ArrGroup = this.groupById(this.targetId);
      let removed: number = 0;
      for (const target of this.arrivalTargets(g.head)) {
        try {
          this.core.stat(target);
          this.core.remove(target, false);
          removed++;
        } catch (e) {
          // 目标文件已不存在（改名/移动过）——跳过
        }
      }
      for (const id of g.ids) {
        try {
          this.core.forgetTransfer(id);
        } catch (e) {
          // 行已不在也不阻塞
        }
      }
      this.notice = this.tt('cl.deleted', `${removed} ${this.targetName}`);
      this.confirming = false;
      this.refreshArrivals();
      this.scan();
      return;
    }
    try {
      this.core.remove(this.targetId, true);
      this.notice = this.tt('cl.deleted', this.targetName);
      this.confirming = false;
      this.scan();
    } catch (e) {
      this.error = this.tt('files.deleteFailed') + '：' + errText(e);
      this.confirming = false;
    }
  }

  // ---- 批量移动（走传输引擎：可暂停/续传，完成后回传这里） ------------------

  private openPicker(): void {
    const root: string = this.core !== null ? this.core.rootId() : '';
    this.pickCrumbs = [root];
    this.loadPickDir();
    this.sheet = SHEET_PICK;
  }

  private loadPickDir(): void {
    if (this.core === null) {
      return;
    }
    try {
      const dirId: string = this.pickCrumbs[this.pickCrumbs.length - 1];
      const all: Entry[] = this.core.list(dirId);
      const dirs: Entry[] = [];
      for (const e of all) {
        if (e.kind === EntryKind.Directory && !e.name.startsWith('.')) {
          dirs.push(e);
        }
      }
      this.pickEntries = dirs;
    } catch (e) {
      this.pickEntries = [];
    }
  }

  private crumbNameAt(i: number): string {
    if (i === 0) {
      return this.tt('files.thisDevice');
    }
    if (this.core === null) {
      return '…';
    }
    try {
      const e: Entry = this.core.stat(this.pickCrumbs[i]);
      return e.name.length > 0 ? e.name : '…';
    } catch (err) {
      return '…';
    }
  }

  private doBatchMove(): void {
    if (this.core === null) {
      return;
    }
    const destDir: string = this.pickCrumbs[this.pickCrumbs.length - 1];
    const sources: string[] = [];
    for (const tag of this.selected) {
      if (tag.startsWith('A:')) {
        const g: ArrGroup = this.groupById(tag.substring(2));
        for (const target of this.arrivalTargets(g.head)) {
          sources.push(target);
        }
      } else {
        sources.push(tag.substring(2));
      }
    }
    try {
      this.core.startMove(sources, destDir, ConflictPolicy.Overwrite);
      this.notice = this.tt('cl.moved', `${sources.length}`);
      this.sheet = SHEET_NONE;
      this.exitSelecting();
    } catch (e) {
      this.error = this.tt('files.transferCreateFailed') + '：' + errText(e);
    }
  }

  // ---- 行组件 ----------------------------------------------------------------

  @Builder
  swipeDeleteBtn(label: string, onAction: () => void) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topRight: 14, bottomRight: 14 })
    .onClick(onAction)
  }

  @Builder
  selDotIf(tag: string) {
    if (this.selecting) {
      SelDot({ selected: this.isSelected(tag), dark: this.dark })
    }
  }

  @Builder
  arrivalRow(g: ArrGroup) {
    Row({ space: SPACE3 }) {
      this.selDotIf(`A:${g.head.id}`)
      Text('⇣')
        .fontSize(16)
        .fontColor(this.th().primary)
      Column({ space: 2 }) {
        Text(this.arrivalTitle(g.head))
          .fontSize(T_FILENAME)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${formatBytes(Number(g.head.bytesTotal))} · ${this.tt('cl.atDir', this.arrivalDirLabel(g.head))}` +
          ` · ${this.tt('cl.arrivedAt')} ${formatClock(Number(g.head.finishedAtMs))}` +
          (Number(g.head.filesTotal) > 1 ? ` · ${Number(g.head.filesTotal)}${this.tt('cl.files')}` : ''))
          .fontSize(T_SECONDARY)
          .fontColor(this.th().onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelect(`A:${g.head.id}`);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.beginSelecting(`A:${g.head.id}`);
      }
    }))
  }

  @Builder
  storageRow(it: CleanItem) {
    Row({ space: SPACE3 }) {
      this.selDotIf(`L:${it.id}`)
      FileIcon({ name: it.name, isDir: it.isDir, dark: this.dark, box: 32 })
      Column({ space: 2 }) {
        Text(it.name).fontSize(T_FILENAME).fontColor(this.th().onSurface)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(it.isDir && !it.measured
          ? this.tt('cl.sweeping')
          : `${formatBytes(it.size)}${it.modified > 0 ? ' · ' + formatDate(it.modified) : ''}`)
          .fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant).width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelect(`L:${it.id}`);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.beginSelecting(`L:${it.id}`);
      }
    }))
  }

  @Builder
  sheetMenuRow(label: string, primary: boolean, action: () => void) {
    Text(label)
      .fontSize(15)
      .fontColor(this.th().onSurface)
      .fontWeight(primary ? FontWeight.Medium : FontWeight.Regular)
      .width('100%')
      .height(46)
      .padding({ left: 4, right: 4 })
      .onClick(action)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // ---- 顶栏：常规 | 多选 ------------------------------------------------
        if (this.selecting) {
          Row({ space: SPACE2 }) {
            Text(this.tt('files.selectedN', `${this.selected.length}`))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.th().onSurface)
              .layoutWeight(1)
            Text(this.tt('common.selectAll')).fontSize(T_BODY).fontColor(this.th().primary)
              .onClick(() => this.selectAll())
            Text(this.tt('common.move')).fontSize(T_BODY).fontColor(this.th().primary)
              .onClick(() => this.openPicker())
            Text(this.tt('common.delete')).fontSize(T_BODY).fontColor(this.th().error)
              .onClick(() => {
                this.confirmKind = 'batch';
                this.targetName = `${this.selected.length}`;
                this.confirming = true;
              })
            Text('✕').fontSize(16).fontColor(this.th().onSurfaceVariant)
              .onClick(() => this.exitSelecting())
          }
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })
        } else {
          Row({ space: 8 }) {
            Button('‹')
              .fontSize(22)
              .width(38)
              .height(38)
              .backgroundColor(this.th().searchFieldBg)
              .fontColor(this.th().onSurface)
              .onClick(() => router.back())
            Text(this.tt('cl.title')).fontSize(T_APPBAR).fontWeight(FontWeight.Bold)
              .fontColor(this.th().onSurface)
              .layoutWeight(1)
            if (this.sweeping) {
              LoadingProgress().width(18).height(18)
            }
            Text(this.tt('files.menuSort', this.sortLabel())).fontSize(T_BODY)
              .fontColor(this.th().primary)
              .onClick(() => this.sheet = SHEET_SORT)
            Text(this.tt('files.menuSelect')).fontSize(T_BODY).fontColor(this.th().primary)
              .onClick(() => {
                this.selecting = true;
                this.selected = [];
              })
          }
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 8 })
        }

        if (this.error.length > 0) {
          Text(this.error).fontSize(T_BODY).fontColor(this.th().error)
            .width('100%').padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }
        if (this.notice.length > 0) {
          Text(this.notice).fontSize(T_BODY).fontColor(this.th().success)
            .width('100%').padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }

        if (!this.loaded) {
          Column() {
            LoadingProgress().width(36).height(36)
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else {
          Scroll() {
            Column() {
              // ---- 传输到本机 ------------------------------------------------
              if (this.arrivals.length > 0) {
                Text(this.tt('cl.arrivals'))
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.th().onSurface)
                  .width('100%')
                  .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 4 })
                Text(this.tt('cl.arrivalsHint'))
                  .fontSize(T_SECONDARY)
                  .fontColor(this.th().onSurfaceVariant)
                  .width('100%')
                  .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, bottom: SPACE2 })
                List({ space: 0 }) {
                  ForEach(this.arrivals, (g: ArrGroup, index: number) => {
                    ListItem() {
                      Column() {
                        this.arrivalRow(g)
                        if (index !== this.arrivals.length - 1) {
                          Divider().color(this.th().divider)
                        }
                      }
                      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
                    }
                    .swipeAction({
                      end: {
                        builder: () => {
                          this.swipeDeleteBtn(this.tt('common.delete'), () => {
                            this.confirmKind = 'arrival';
                            this.targetId = g.head.id;
                            this.targetName = this.arrivalTitle(g.head);
                            this.confirming = true;
                          })
                        },
                        actionAreaDistance: 56
                      }
                    })
                  }, (g: ArrGroup) => g.head.id)
                }
                .width('100%')
                .padding({ bottom: SPACE3 })
              }

              // ---- 本机存储 --------------------------------------------------
              Text(this.tt('cl.storage'))
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.th().onSurface)
                .width('100%')
                .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 4, bottom: SPACE2 })
              if (this.items.length === 0) {
                Text(this.tt('cl.empty')).fontSize(15)
                  .fontColor(this.th().onSurfaceVariant)
                  .width('100%')
                  .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
              } else {
                List({ space: 0 }) {
                  ForEach(this.items, (it: CleanItem, index: number) => {
                    ListItem() {
                      Column() {
                        this.storageRow(it)
                        if (index !== this.items.length - 1) {
                          Divider().color(this.th().divider)
                        }
                      }
                      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
                    }
                    .swipeAction({
                      end: {
                        builder: () => {
                          this.swipeDeleteBtn(this.tt('common.delete'), () => {
                            this.confirmKind = 'dir';
                            this.targetId = it.id;
                            this.targetName = it.name;
                            this.confirming = true;
                          })
                        },
                        actionAreaDistance: 56
                      }
                    })
                  }, (it: CleanItem) => it.id)
                }
                .width('100%')
              }
              Row().height(24)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.th().surface)

      // ---- 排序面板 ----------------------------------------------------------
      if (this.sheet === SHEET_SORT || this.sheet === SHEET_PICK) {
        Column() {
          Blank().layoutWeight(1).onClick(() => this.sheet = SHEET_NONE)
          Column({ space: SPACE3 }) {
            if (this.sheet === SHEET_SORT) {
              Text(this.tt('files.sortTitle')).fontSize(17).fontWeight(FontWeight.Medium)
                .fontColor(this.th().onSurface).width('100%')
              Divider().color(this.th().divider)
              this.sheetMenuRow(this.tt('files.sortName'), this.sortKey === SORT_NAME, () => {
                this.sortKey = SORT_NAME;
                this.applySort(this.items.slice());
                this.arrivals = this.sortArrivals(this.arrivals.slice());
                this.sheet = SHEET_NONE;
              })
              this.sheetMenuRow(this.tt('files.sortTime'), this.sortKey === SORT_TIME, () => {
                this.sortKey = SORT_TIME;
                this.applySort(this.items.slice());
                this.arrivals = this.sortArrivals(this.arrivals.slice());
                this.sheet = SHEET_NONE;
              })
              this.sheetMenuRow(this.tt('files.sortSize'), this.sortKey === SORT_SIZE, () => {
                this.sortKey = SORT_SIZE;
                this.applySort(this.items.slice());
                this.arrivals = this.sortArrivals(this.arrivals.slice());
                this.sheet = SHEET_NONE;
              })
              Divider().color(this.th().divider)
              this.sheetMenuRow(this.tt('files.asc'), this.sortAsc, () => {
                this.sortAsc = true;
                this.applySort(this.items.slice());
                this.arrivals = this.sortArrivals(this.arrivals.slice());
                this.sheet = SHEET_NONE;
              })
              this.sheetMenuRow(this.tt('files.desc'), !this.sortAsc, () => {
                this.sortAsc = false;
                this.applySort(this.items.slice());
                this.arrivals = this.sortArrivals(this.arrivals.slice());
                this.sheet = SHEET_NONE;
              })
            } else {
              // ---- 移动目标选择器 ----------------------------------------------
              Text(this.tt('cl.moveTitle')).fontSize(17).fontWeight(FontWeight.Medium)
                .fontColor(this.th().onSurface).width('100%')
              Text(this.pickCrumbs.map((_v: string, i: number) => this.crumbNameAt(i)).join(' / '))
                .fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              Divider().color(this.th().divider)
              List({ space: 0 }) {
                ForEach(this.pickEntries, (e: Entry) => {
                  ListItem() {
                    Row({ space: SPACE2 }) {
                      Text('📁').fontSize(16)
                      Text(e.name).fontSize(T_FILENAME).fontColor(this.th().onSurface)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                      Text('›').fontSize(16).fontColor(this.th().outline)
                    }
                    .width('100%')
                    .padding({ top: SPACE3, bottom: SPACE3 })
                    .onClick(() => {
                      this.pickCrumbs.push(e.id);
                      this.loadPickDir();
                    })
                  }
                }, (e: Entry) => e.id)
              }
              .height(260)
              .width('100%')
              Divider().color(this.th().divider)
              Row({ space: SPACE2 }) {
                Button(this.tt('common.cancel'))
                  .layoutWeight(1)
                  .height(40)
                  .backgroundColor(this.th().searchFieldBg)
                  .fontColor(this.th().onSurface)
                  .onClick(() => this.sheet = SHEET_NONE)
                Button(this.tt('cl.moveHere'))
                  .layoutWeight(1)
                  .height(40)
                  .backgroundColor(this.th().primary)
                  .fontColor(this.th().onPrimary)
                  .onClick(() => this.doBatchMove())
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(SPACE4)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
      }

      // ---- 删除确认 ----------------------------------------------------------
      if (this.confirming) {
        Column() {
          Blank().layoutWeight(1).onClick(() => this.confirming = false)
          Column({ space: SPACE3 }) {
            Text(this.confirmKind === 'arrival'
              ? this.tt('cl.deleteArrivalTitle', this.targetName)
              : (this.confirmKind === 'batch'
                ? this.tt('cl.deleteN', `${this.selected.length}`)
                : this.tt('cl.deleteTitle', this.targetName)))
              .fontSize(17).fontWeight(FontWeight.Medium)
              .fontColor(this.th().onSurface)
            Text(this.confirmKind === 'arrival'
              ? this.tt('cl.deleteArrivalWarn')
              : this.tt('cl.deleteWarn')).fontSize(T_BODY).fontColor(this.th().onSurfaceVariant)
            Row({ space: SPACE2 }) {
              Button(this.tt('common.cancel'))
                .layoutWeight(1)
                .height(40)
                .backgroundColor(this.th().searchFieldBg)
                .fontColor(this.th().onSurface)
                .onClick(() => this.confirming = false)
              Button(this.tt('common.delete'))
                .layoutWeight(1)
                .height(40)
                .backgroundColor(this.th().error)
                .fontColor(this.th().onPrimary)
                .onClick(() => this.doDelete())
            }
            .width('100%')
          }
          .width('100%')
          .padding(SPACE4)
          .backgroundColor(this.th().surfaceCard)
          .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
