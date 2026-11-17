import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../common/L10n';
import { PendingTransfer, SuperFiles, TransferSnapshot, TransferState } from '@superfiles/core';
import { getCore } from '../common/Core';
import { theme, Palette, SCREEN_MARGIN, RADIUS_M, SPACE2, SPACE3, SPACE4 } from '../common/Tokens';
import { formatBytes, formatClock, formatDuration, errText } from '../common/Format';
import { SelDot } from '../common/SelDot';
import { lsRecords, LsRecord } from '../common/LsRecords';
import { ensureMountedForId } from '../common/MountOps';

/**
 * 传输行实体：@Observed + 字段级更新。
 *
 * poll() 每秒把引擎快照 diff 回行对象（新任务建行、消失删行、其余只 mutate
 * 字段）。ForEach 键值恒为 row.id，条目因此永不重建——运行中任务的进度、
 * 速度靠 ObjectLink 字段刷新，而左滑菜单在每秒刷新下保持展开（操作全部
 * 承载在左滑上，这是可靠性的前提：键值变化会让 ListItem 销毁重建、展开
 * 的 swipe 菜单被一并收回，「左滑→点按钮」就永远点不中）。
 */
@Observed
class TrRow {
  id: string;
  state: number;
  bytesDone: bigint;
  bytesTotal: bigint;
  filesDone: bigint;
  filesTotal: bigint;
  /** 引擎当前正在拷的文件名（终态被清空）。 */
  current: string;
  /** 最近一次见过的 current：终态标题兜底。 */
  lastCurrent: string;
  error: string;
  startedMs: number;
  finishedMs: number;
  /** 多选高亮也走字段级刷新。 */
  selected: boolean;

  constructor(s: TransferSnapshot) {
    this.id = s.id;
    this.state = Number(s.state);
    this.bytesDone = s.bytesDone;
    this.bytesTotal = s.bytesTotal;
    this.filesDone = s.filesDone;
    this.filesTotal = s.filesTotal;
    this.current = s.current !== undefined ? s.current : '';
    this.lastCurrent = this.current;
    this.error = s.error !== undefined ? s.error : '';
    this.startedMs = Number(s.startedAtMs);
    this.finishedMs = s.finishedAtMs !== undefined ? Number(s.finishedAtMs) : 0;
    this.selected = false;
  }

  /** 快照 → 行对象字段级回写（同值赋值不触发 UI 刷新）。 */
  updateFrom(s: TransferSnapshot): void {
    this.state = Number(s.state);
    this.bytesDone = s.bytesDone;
    this.bytesTotal = s.bytesTotal;
    this.filesDone = s.filesDone;
    this.filesTotal = s.filesTotal;
    this.current = s.current !== undefined ? s.current : '';
    if (this.current.length > 0) {
      this.lastCurrent = this.current;
    }
    this.error = s.error !== undefined ? s.error : '';
    this.startedMs = Number(s.startedAtMs);
    this.finishedMs = s.finishedAtMs !== undefined ? Number(s.finishedAtMs) : 0;
  }
}

/** 是否还有生命体征（可暂停/继续/终止）。 */
function trRowLive(state: number): boolean {
  return state === TransferState.Queued || state === TransferState.Running ||
    state === TransferState.Paused;
}

/** 单条传输卡片。操作入口全在父级 ListItem 的左滑菜单里。 */
@Component
struct TransferCard {
  @ObjectLink row: TrRow;
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  /** 多选态：与父级共同订阅 AppStorage，选择模式切换即时传导到每张卡。 */
  @StorageLink('sfTrSel') selecting: boolean = false;
  onToggle: (row: TrRow) => void = (_r: TrRow) => {};
  onLongPress: (row: TrRow) => void = (_r: TrRow) => {};

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  private stateText(): string {
    if (this.row.state === TransferState.Queued) {
      return this.tt('tr.queued');
    }
    if (this.row.state === TransferState.Running) {
      return this.tt('tr.running');
    }
    if (this.row.state === TransferState.Paused) {
      return this.tt('tr.paused');
    }
    if (this.row.state === TransferState.Completed) {
      return this.tt('tr.completed');
    }
    if (this.row.state === TransferState.Failed) {
      return this.tt('tr.failed');
    }
    return this.tt('tr.cancelled');
  }

  private stateColor(): string {
    if (this.row.state === TransferState.Failed) {
      return this.th().error;
    }
    if (this.row.state === TransferState.Completed) {
      return this.th().success;
    }
    return this.th().onSurfaceVariant;
  }

  private fraction(): number {
    const total: number = Number(this.row.bytesTotal);
    if (total <= 0) {
      return 0;
    }
    return Math.min(1, Number(this.row.bytesDone) / total);
  }

  /** 标题：优先 current，其次历史缓存，最后「N 项文件」。 */
  private title(): string {
    if (this.row.current.length > 0) {
      return this.row.current;
    }
    if (this.row.lastCurrent.length > 0) {
      return this.row.lastCurrent;
    }
    return this.tt('tr.items', `${Number(this.row.filesTotal)}`);
  }

  /** 开始/结束/耗时一行；落定后追加事实速度（bytesDone ÷ 实际耗时）。 */
  private timesLine(): string {
    const start: number = this.row.startedMs;
    const end: number = this.row.finishedMs;
    let text: string = `${this.tt('tr.startAt')} ${start > 0 ? formatClock(start) : '—'}`;
    text += ` · ${this.tt('tr.endAt')} ${end > 0 ? formatClock(end) : '—'}`;
    if (start > 0 && end > 0 && end >= start) {
      const elapsed: number = end - start;
      text += ` · ${this.tt('tr.cost')} ${formatDuration(elapsed)}`;
      // 事实速度：失败/取消记录同样成立——转过的字节是事实
      if (elapsed >= 1000) {
        const perSec: number = Number(this.row.bytesDone) * 1000 / elapsed;
        text += ` · ${this.tt('tr.avgSpeed', formatBytes(perSec))}`;
      }
    }
    return text;
  }

  build() {
    Column({ space: SPACE2 }) {
      Row({ space: SPACE2 }) {
        if (this.selecting) {
          SelDot({ selected: this.row.selected, dark: this.dark })
        }
        Text(this.title())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 右侧不放操作：暂停/终止/删除全部走左滑，长按进入多选删除。
      }
      .width('100%')

      Row({ space: 4 }) {
        Text(this.stateText()).fontSize(11).fontColor(this.stateColor())
        Text(`· ${formatBytes(Number(this.row.bytesDone))} / ${formatBytes(Number(this.row.bytesTotal))}`)
          .fontSize(11)
          .fontColor(this.stateColor())
        if ((this.row.state === TransferState.Running || this.row.state === TransferState.Paused)
          && Number(this.row.bytesTotal) > 0) {
          Text(`· ${Math.round(this.fraction() * 100)}%`)
            .fontSize(11)
            .fontColor(this.stateColor())
        }
        if (Number(this.row.filesTotal) > 1) {
          Text(`· ${Number(this.row.filesDone)}/${Number(this.row.filesTotal)}`)
            .fontSize(11)
            .fontColor(this.stateColor())
        }
      }
      .width('100%')

      Text(this.timesLine())
        .fontSize(11)
        .fontColor(this.th().onSurfaceVariant)
        .width('100%')

      if (this.row.error.length > 0) {
        Text(this.row.error).fontSize(11).fontColor(this.th().error).width('100%')
      }
      if (trRowLive(this.row.state)) {
        Progress({ value: this.fraction() * 100, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
      }
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .onClick(() => {
      if (this.selecting) {
        this.onToggle(this.row);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.onLongPress(this.row);
      }
    }))
  }
}

@Component
export struct TransfersView {
  @State active: TrRow[] = [];
  @State pending: PendingTransfer[] = [];
  @State error: string = '';
  @State selecting: boolean = false;
  @State selected: string[] = [];
  /** pending 用的上次内容签名：null 表示从未赋值过，首轮必须落库。 */
  private pendingSigValue: string | null = null;
  /** id → 传输行实体（跨 poll 复用同一实例，ObjectLink 才有意义）。 */
  private rowById: Map<string, TrRow> = new Map();
  // 与外层路由页协商「返回」：多选态下返回键/侧滑先退出多选，而不是弹掉页面。
  @StorageLink('sfTrSel') trSel: boolean = false;
  @StorageLink('sfTrSelExit') @Watch('onTrSelExit') trSelExit: number = 0;
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @StorageLink('sfLsRecords') @Watch('onLsRecords') lsRecordsJson: string = '';
  @Prop embedded: boolean = false;
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }
  private timer: number = -1;
  private keepAliveOn: boolean = false;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
      return;
    }
    this.poll();
    this.timer = setInterval(() => this.poll(), 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 近邻流水变化触发重渲染（build 内读取了 lsRecordsJson）。 */
  onLsRecords(): void {
  }

  /** 近邻收发流水（解析 AppStorage JSON）。 */
  private lsRows(): LsRecord[] {
    if (this.lsRecordsJson.length === 0) {
      return [];
    }
    return lsRecords();
  }

  private poll(): void {
    if (this.core === null) {
      return;
    }
    try {
      const snaps: TransferSnapshot[] = this.core.transfers();
      // 快照 diff 回行对象：新任务建行、消失删行、其余字段级更新。
      // this.active 的键值恒为 id，ForEach 只在任务增减时增删条目；
      // 运行中的进度/状态变化全走 @ObjectLink 字段刷新，条目不重建，
      // 展开的左滑菜单也就不会被每秒刷新收回。
      const next: TrRow[] = [];
      for (const s of snaps) {
        let row: TrRow | undefined = this.rowById.get(s.id);
        if (row === undefined) {
          row = new TrRow(s);
          this.rowById.set(s.id, row);
        } else {
          row.updateFrom(s);
        }
        row.selected = this.selected.indexOf(s.id) >= 0;
        next.push(row);
      }
      const alive: string[] = [];
      for (const s of snaps) {
        alive.push(s.id);
      }
      for (const id of this.rowById.keys()) {
        if (alive.indexOf(id) < 0) {
          // forget/cancel 后不再出现的任务下线
          if (this.selecting && this.selected.indexOf(id) >= 0) {
            const at: number = this.selected.indexOf(id);
            this.selected = this.selected.slice(0, at).concat(this.selected.slice(at + 1));
          }
          this.rowById.delete(id);
        }
      }
      this.active = next;
      const pending: PendingTransfer[] = this.core.pendingTransfers();
      // pending 是静态恢复记录：内容真变了才落 @State，避免 List 无谓刷新
      // 把展开的左滑「忽略」收回。
      const sigP: string = this.pendingSig(pending);
      if (sigP !== this.pendingSigValue) {
        this.pending = pending;
        this.pendingSigValue = sigP;
      }
      this.error = '';
      let anyRunning: boolean = false;
      for (const s of snaps) {
        if (s.state === TransferState.Running || s.state === TransferState.Queued ||
          s.state === TransferState.Paused) {
          anyRunning = true;
        }
      }
      this.updateKeepAlive(anyRunning);
    } catch (e) {
      this.error = this.tt('tr.readFailed') + '：' + errText(e);
    }
  }

  /** pending 列表的内容签名（顺序敏感）。 */
  private pendingSig(pending: PendingTransfer[]): string {
    let sig: string = '';
    for (const p of pending) {
      sig += `${p.id}:${Number(p.bytesDone)}/${Number(p.bytesTotal)}|`;
    }
    return sig;
  }

  /** Continuous task so copies survive the app going to background. */
  private updateKeepAlive(on: boolean): void {
    if (on === this.keepAliveOn) {
      return;
    }
    this.keepAliveOn = on;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (on) {
        wantAgent.getWantAgent({
          wants: [{ bundleName: 'com.superfiles.app', abilityName: 'EntryAbility' }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0
        }).then((agent) => {
          return backgroundTaskManager.startBackgroundRunning(ctx,
            backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        }).catch((e: Error) => {
          // 持续任务申请失败不阻断传输,但必须可观测:失败意味着退后台/锁屏后
          // 进程会被系统冻结,复制会「传输一段时间后卡死」(module.json5 的
          // backgroundModes 漏声明 dataTransfer 时就是这种症状)。
          hilog.error(0x0001, 'SuperFiles', 'startBackgroundRunning failed: %{public}s', errText(e));
        });
      } else {
        backgroundTaskManager.stopBackgroundRunning(ctx).catch((e: Error) => {
          hilog.warn(0x0001, 'SuperFiles', 'stopBackgroundRunning failed: %{public}s', errText(e));
        });
      }
    } catch (e) {
      // never let keep-alive logic break transfers
    }
  }

  toggleRow(row: TrRow): void {
    if (row.selected) {
      row.selected = false;
      const at: number = this.selected.indexOf(row.id);
      if (at >= 0) {
        this.selected = this.selected.slice(0, at).concat(this.selected.slice(at + 1));
      }
    } else {
      row.selected = true;
      this.selected = this.selected.concat([row.id]);
    }
    if (this.selected.length === 0) {
      this.exitSelecting();
    }
  }

  beginSelecting(row: TrRow): void {
    this.selecting = true;
    row.selected = true;
    this.selected = [row.id];
    this.syncTrSel();
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  /** 退出多选：清空所有行的高亮。 */
  private exitSelecting(): void {
    this.selecting = false;
    this.selected = [];
    for (const row of this.rowById.values()) {
      row.selected = false;
    }
    this.syncTrSel();
  }

  /** 发布多选状态给外层页面（返回键协商用）。 */
  private syncTrSel(): void {
    this.trSel = this.selecting;
  }

  /** 页面返回键：多选态先退出多选。 */
  private onTrSelExit(): void {
    if (this.trSelExit === 0) {
      return;
    }
    if (this.selecting) {
      this.exitSelecting();
    }
  }

  /** 左滑「暂停」：块边界闸门停摆，SQLite 行保持可恢复。 */
  private pauseRow(row: TrRow): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.pauseTransfer(row.id);
      this.poll();
    } catch (e) {
      this.error = errText(e);
    }
  }

  /** 左滑「继续」（已暂停的任务）：解除闸门从断点接着拷。 */
  private unpauseRow(row: TrRow): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.unpauseTransfer(row.id);
      this.poll();
    } catch (e) {
      this.error = errText(e);
    }
  }

  /** 左滑「终止」：取消任务并落终态（已拷数据保留，行进入已取消）。 */
  private abortRow(row: TrRow): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.cancelTransfer(row.id);
      this.poll();
    } catch (e) {
      this.error = errText(e);
    }
  }

  /** 左滑「删除」/多选删除（终态记录）：移出注册表并清掉续传行。 */
  private removeRow(row: TrRow): void {
    if (this.core === null) {
      return;
    }
    try {
      if (trRowLive(row.state)) {
        this.core.cancelTransfer(row.id);
      } else {
        this.core.forgetTransfer(row.id);
      }
      this.poll();
    } catch (e) {
      this.error = errText(e);
    }
  }

  private removeSelected(): void {
    if (this.core === null) {
      return;
    }
    for (const row of this.rowById.values()) {
      if (this.selected.indexOf(row.id) < 0) {
        continue;
      }
      try {
        if (trRowLive(row.state)) {
          this.core.cancelTransfer(row.id);
        } else {
          this.core.forgetTransfer(row.id);
        }
      } catch (e) {
        // continue
      }
    }
    for (const p of this.pending) {
      if (this.selected.indexOf(p.id) >= 0) {
        try {
          this.core.forgetTransfer(p.id);
        } catch (e) {
          // continue
        }
      }
    }
    this.exitSelecting();
    this.poll();
  }

  /**
   * 左滑操作区：运行中/排队 → 暂停+终止；已暂停 → 继续+终止；
   * 终态（完成/失败/取消）→ 删除。builder 捕获的是稳定的行对象，
   * 展开时按当时的 state 渲染。
   */
  @Builder
  swipeActiveBtns(row: TrRow) {
    Row() {
      if (row.state === TransferState.Queued || row.state === TransferState.Running) {
        Text(this.tt('tr.pause'))
          .fontSize(13)
          .fontColor(Color.White)
          .width(72)
          .height('100%')
          .backgroundColor(this.th().primary)
          .textAlign(TextAlign.Center)
          .onClick(() => this.pauseRow(row))
      }
      if (row.state === TransferState.Paused) {
        Text(this.tt('tr.resume'))
          .fontSize(13)
          .fontColor(Color.White)
          .width(72)
          .height('100%')
          .backgroundColor(this.th().primary)
          .textAlign(TextAlign.Center)
          .onClick(() => this.unpauseRow(row))
      }
      if (trRowLive(row.state)) {
        Text(this.tt('tr.abort'))
          .fontSize(13)
          .fontColor(Color.White)
          .width(72)
          .height('100%')
          .backgroundColor(this.th().error)
          .textAlign(TextAlign.Center)
          .onClick(() => this.abortRow(row))
      } else {
        Text(this.tt('common.delete'))
          .fontSize(13)
          .fontColor(Color.White)
          .width(72)
          .height('100%')
          .backgroundColor(this.th().error)
          .textAlign(TextAlign.Center)
          .onClick(() => this.removeRow(row))
      }
    }
    .height('100%')
    .borderRadius({ topRight: 14, bottomRight: 14 })
  }

  /** 左滑出「忽略」（可恢复记录的红色忽略）。 */
  @Builder
  swipeRemovePendingBtn(p: PendingTransfer) {
    Column() {
      Text(this.tt('tr.forget'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topRight: 14, bottomRight: 14 })
    .onClick(() => this.removeOnePending(p))
  }

  /**
   * 「继续」前先补连挂载：进程重启（或升级安装重启）后，sources/目标目录
   * 所在的网络存储已断开，直接 resumeTransfer 必然报
   * "no backend mounted for scheme '…'"。ensureMountedForId 会按持久化
   * 配置自动重挂；失败（配置丢失/网络不可达）才提示用户手动重连。
   */
  private resumeOne(p: PendingTransfer): void {
    if (this.core === null) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      for (const src of p.sources) {
        if (!ensureMountedForId(ctx, this.core, src)) {
          this.error = this.tt('tr.resumeMountFailed');
          return;
        }
      }
      if (!ensureMountedForId(ctx, this.core, p.destDir)) {
        this.error = this.tt('tr.resumeMountFailed');
        return;
      }
      this.core.resumeTransfer(p.id);
      this.error = '';
    } catch (e) {
      this.error = this.tt('tr.resumeFailed') + '：' + errText(e);
    }
    this.poll();
  }

  private removeOnePending(p: PendingTransfer): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.forgetTransfer(p.id);
    } catch (e) {
      this.error = this.tt('tr.forgetFailed') + '：' + errText(e);
    }
    this.poll();
  }

  private basename(path: string): string {
    const trimmed: string = path.replace(/\/+$/, '');
    const at: number = trimmed.lastIndexOf('/');
    return at >= 0 ? trimmed.substring(at + 1) : trimmed;
  }

  private destName(id: string): string {
    if (this.core === null) {
      return id;
    }
    try {
      const p: string = this.core.displayPath(id);
      return this.basename(p).length > 0 ? this.basename(p) : id;
    } catch (e) {
      return id;
    }
  }

  @Builder
  pendingCard(p: PendingTransfer) {
    Row({ space: SPACE3 }) {
      Column({ space: 2 }) {
        Text(this.basename(p.sources.length > 0 ? p.sources[0] : '') +
          (p.sources.length > 1 ? this.tt('tr.andMore', `${p.sources.length}`) : ''))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(`${p.isMove ? this.tt('common.move') : this.tt('common.copy')} · ` +
          `${formatBytes(Number(p.bytesDone))} / ${formatBytes(Number(p.bytesTotal))} · ` +
          `${this.tt('tr.toDest')} ${this.destName(p.destDir)}`)
          .fontSize(11)
          .fontColor(this.th().onSurfaceVariant)
          .maxLines(1)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(this.tt('tr.resume'))
        .fontSize(12)
        .fontColor(this.th().primary)
        .onClick(() => this.resumeOne(p))
      // 「忽略」走左滑：pending 数据是静态恢复记录，poll 的变更检测保证了
      // 左滑菜单不被每秒刷新弹回。
    }
    .width('100%')
    .padding(SPACE4)
    .backgroundColor(this.th().surfaceCard)
    .borderRadius(RADIUS_M)
    .onClick(() => {
      if (this.selecting) {
        this.togglePending(p);
      }
    })
    .gesture(LongPressGesture().onAction(() => {
      if (!this.selecting) {
        this.selecting = true;
        this.selected = [p.id];
        this.syncTrSel();
      }
    }))
  }

  /** pending 行无 TrRow 实体，多选高亮直接重渲染该行（静态数据无妨）。 */
  private togglePending(p: PendingTransfer): void {
    this.isSelected(p.id) ? this.removeSelectedId(p.id) : (this.selected = this.selected.concat([p.id]));
    if (this.selected.length === 0) {
      this.selecting = false;
      this.syncTrSel();
    }
  }

  private removeSelectedId(id: string): void {
    const at: number = this.selected.indexOf(id);
    if (at >= 0) {
      this.selected = this.selected.slice(0, at).concat(this.selected.slice(at + 1));
    }
  }

  build() {
    Column({ space: 12 }) {
      if (this.selecting) {
        // 多选操作条：已选 N · 删除 · 退出
        Row({ space: SPACE2 }) {
          Text(this.tt('files.selectedN', `${this.selected.length}`))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().onSurface)
            .layoutWeight(1)
          Text(this.tt('common.delete'))
            .fontSize(14)
            .fontColor(this.th().error)
            .onClick(() => this.removeSelected())
          Text('✕')
            .fontSize(16)
            .fontColor(this.th().onSurfaceVariant)
            .onClick(() => this.exitSelecting())
        }
        .width('100%')
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8 })
      } else {
        Text(this.tt('tr.title'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.th().onSurface)
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8 })
      }

      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13)
          .fontColor(this.th().error)
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
      }

      if (this.active.length === 0 && this.pending.length === 0) {
        Column({ space: 6 }) {
          Text(this.tt('tr.empty')).fontSize(15).fontColor(this.th().onSurfaceVariant)
          Text(this.tt('tr.emptyHint')).fontSize(13).fontColor(this.th().outline)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        List({ space: 0 }) {
          ForEach(this.pending, (p: PendingTransfer, index: number) => {
            ListItem() {
              Column() {
                this.pendingCard(p)
                if (index !== this.pending.length - 1) {
                  Divider().color(this.th().divider)
                }
              }
              .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.swipeRemovePendingBtn(p);
                },
                actionAreaDistance: 56
              }
            })
          }, (p: PendingTransfer) => p.id)
        }
        .width('100%')

        List({ space: 0 }) {
          ForEach(this.active, (row: TrRow, index: number) => {
            ListItem() {
              Column() {
                TransferCard({
                  row: row,
                  onToggle: (r: TrRow) => this.toggleRow(r),
                  onLongPress: (r: TrRow) => this.beginSelecting(r)
                })
                if (index !== this.active.length - 1) {
                  Divider().color(this.th().divider)
                }
              }
              .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.swipeActiveBtns(row);
                },
                actionAreaDistance: 56
              }
            })
          }, (row: TrRow) => row.id)
        }
        .layoutWeight(1)
        .width('100%')
      }

      // 近邻收发流水：LocalSend 不走内核 transfers()，独立分组展示
      if (this.lsRows().length > 0) {
        Column({ space: 8 }) {
          Text(this.tt('tr.lsSection'))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.th().onSurface)
            .width('100%')
            .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
          List({ space: 0 }) {
            ForEach(this.lsRows(), (r: LsRecord, index: number) => {
              ListItem() {
                Column() {
                  Row({ space: 10 }) {
                    Text(r.dir === 'in' ? '⇣' : '⇡')
                      .fontSize(16)
                      .fontColor(this.th().primary)
                    Column({ space: 2 }) {
                      Text(r.name)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.th().onSurface)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(`${r.peer.length > 0 ? r.peer + ' · ' : ''}${formatBytes(r.size)} · ${formatClock(r.at)}`)
                        .fontSize(11)
                        .fontColor(this.th().onSurfaceVariant)
                        .maxLines(1)
                        .width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding(SPACE4)
                  .backgroundColor(this.th().surfaceCard)
                  .borderRadius(RADIUS_M)
                  if (index !== this.lsRows().length - 1) {
                    Divider().color(this.th().divider)
                  }
                }
              }
            }, (r: LsRecord) => `${r.at}-${r.dir}-${r.name}`)
          }
          .width('100%')
          .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN })
        }
        .width('100%')
        .padding({ bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
    // 页面底 = 主页的 surface（暖灰米色）；卡片才是 surfaceCard（白）。
    // 之前根背景误用 surfaceCard，白底叠白卡导致条目看不清。
    .backgroundColor(this.th().surface)
  }
}
