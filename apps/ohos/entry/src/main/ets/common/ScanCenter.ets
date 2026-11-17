import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { IndexProgressListener, SuperFiles } from '@superfiles/core';
import { getCore } from './Core';
import { errText } from './Format';

/**
 * 全局扫描中心：所有索引任务（本地 keep-alive / 挂载手动重建）走同一条
 * 串行队列，状态经 AppStorage 广播，任何页面触发、切页不中断。
 *
 * 状态键（AppStorage）：
 *  - sfScanningId    正在扫描的根 id（'' = 空闲）
 *  - sfScanLabel     正在扫描的显示名（挂载名 / 本地）
 *  - sfScanFraction  0..1 进度（-1 = 空闲）
 *  - sfScanLastAt    上次成功完成的时间戳 ms（0 = 从未）
 */

export interface ScanJob {
  id: string;
  label: string;
  full: boolean;
  /** 手动触发=true 跳过冷却；keep-alive/自动=false 受 10 分钟冷却约束。 */
  force?: boolean;
}

const KEY_ID: string = 'sfScanningId';
const KEY_LABEL: string = 'sfScanLabel';
const KEY_FRAC: string = 'sfScanFraction';
const KEY_LAST: string = 'sfScanLastAt';
const COOLDOWN_MS: number = 10 * 60 * 1000;

let queue: ScanJob[] = [];
let running: boolean = false;
let core: SuperFiles | null = null;
let ctx: common.UIAbilityContext | null = null;

function setState(id: string, label: string, frac: number): void {
  AppStorage.setOrCreate(KEY_ID, id);
  AppStorage.setOrCreate(KEY_LABEL, label);
  AppStorage.setOrCreate(KEY_FRAC, frac);
}

function lastAt(): number {
  return AppStorage.get<number>(KEY_LAST) ?? 0;
}

/** 应用启动时调用一次：注入 core 与上下文，并触发本地 keep-alive 扫描。 */
export function initScanCenter(context: common.UIAbilityContext): void {
  ctx = context;
  try {
    core = getCore(ctx);
  } catch (e) {
    hilog.error(0x0000, 'SuperFiles', 'scan center init failed: %{public}s', errText(e));
    return;
  }
  // keep-alive：本地根自动增量扫描（冷启动时索引可能落后；受冷却约束）
  const rootId: string = core.rootId();
  enqueueScan({ id: rootId, label: '', full: false, force: false });
}

/** 入队一个扫描任务；同 id 已在队中/正在跑则忽略。full=true 跳过增量整棵重扫。 */
export function enqueueScan(job: ScanJob): void {
  if (job.id.length === 0) {
    return;
  }
  if (running && currentId() === job.id) {
    return;
  }
  for (const q of queue) {
    if (q.id === job.id) {
      return;
    }
  }
  if (!job.force && !job.full && !running && Date.now() - lastAt() < COOLDOWN_MS) {
    return; // 自动增量扫描 10 分钟冷却
  }
  queue.push(job);
  hilog.info(0x0000, 'SuperFiles', 'scan enqueue %{public}s running=%{public}s q=%{public}d', job.id, `${running}`, queue.length);
  if (!running) {
    startNext();
  }
}

function currentId(): string {
  return AppStorage.get<string>(KEY_ID) ?? '';
}

function startNext(): void {
  const job: ScanJob | undefined = queue.shift();
  if (job === undefined || core === null) {
    running = false;
    return;
  }
  running = true;
  setState(job.id, job.label, 0);
  const listener: IndexProgressListener = {
    onProgress(d: bigint, e: bigint, f: number): void {
      AppStorage.setOrCreate(KEY_FRAC, Math.min(0.99, Math.max(0, f)));
    },
    onFinished(t: bigint): void {
    }
  };
  // 后台线程池执行（UI 不阻塞），Promise 完成后再跑下一个队列任务
  hilog.info(0x0000, 'SuperFiles', 'scan start %{public}s full=%{public}s', job.id, `${job.full}`);
  try {
    core.indexDirBackground(job.id, listener, job.full)
      .then((n: bigint) => {
        hilog.info(0x0000, 'SuperFiles', 'scan done %{public}s -> %{public}s', job.id, `${n}`);
        AppStorage.setOrCreate(KEY_LAST, Date.now());
        setState('', '', -1);
        running = false;
        startNext();
      })
      .catch((e: Error) => {
        hilog.error(0x0000, 'SuperFiles', 'scan %{public}s failed: %{public}s', job.id, errText(e));
        setState('', '', -1);
        running = false;
        startNext();
      });
  } catch (e) {
    hilog.error(0x0000, 'SuperFiles', 'scan %{public}s dispatch failed: %{public}s', job.id, errText(e));
    setState('', '', -1);
    running = false;
    startNext();
  }
}

/** 当前是否空闲（供 UI 判断三态）。 */
export function scanIdle(): boolean {
  return currentId().length === 0;
}
