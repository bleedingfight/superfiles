import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 轻量全局设置（行式 `key=value` 文件，与 MountStore 同一套路，位于应用沙箱）。
 * 当前承载：显示隐藏文件开关、昵称。改值处即时写盘，冷启动在 EntryAbility 读回。
 */

const KEY_SHOW_HIDDEN: string = 'showHidden';
const KEY_NICK: string = 'nick';
const FILE_NAME: string = 'settings.conf';

function fileOf(ctx: common.UIAbilityContext): string {
  return `${ctx.filesDir}/${FILE_NAME}`;
}

/** 读取整表（缺文件/解析失败返回空 Map）。 */
function readAll(ctx: common.UIAbilityContext): Map<string, string> {
  const map: Map<string, string> = new Map();
  try {
    const path: string = fileOf(ctx);
    if (!fileIo.accessSync(path)) {
      return map;
    }
    const lines: string[] = fileIo.readTextSync(path).split('\n');
    for (const line of lines) {
      const at: number = line.indexOf('=');
      if (at > 0) {
        map.set(line.substring(0, at), line.substring(at + 1));
      }
    }
  } catch (e) {
    // 读不到按空表处理
  }
  return map;
}

/** 整表落盘。 */
function writeAll(ctx: common.UIAbilityContext, map: Map<string, string>): void {
  try {
    const lines: string[] = [];
    map.forEach((v: string, k: string) => {
      lines.push(`${k}=${v}`);
    });
    const f = fileIo.openSync(fileOf(ctx),
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, lines.join('\n') + '\n');
    fileIo.closeSync(f);
  } catch (e) {
    // 尽力而为，失败不阻塞 UI
  }
}

export function loadShowHidden(ctx: common.UIAbilityContext): boolean {
  return readAll(ctx).get(KEY_SHOW_HIDDEN) === '1';
}

export function saveShowHidden(ctx: common.UIAbilityContext, show: boolean): void {
  const map: Map<string, string> = readAll(ctx);
  map.set(KEY_SHOW_HIDDEN, show ? '1' : '0');
  writeAll(ctx, map);
}

export function loadNick(ctx: common.UIAbilityContext): string {
  return readAll(ctx).get(KEY_NICK) ?? '';
}

export function saveNick(ctx: common.UIAbilityContext, nick: string): void {
  const map: Map<string, string> = readAll(ctx);
  map.set(KEY_NICK, nick);
  writeAll(ctx, map);
}

const KEY_LS_IDLE_SECS: string = 'lsIdleSecs';

/** 近邻传输「无传输活动自动关闭」时长（秒，0=永不，默认 300s）。 */
export function loadLsIdleSecs(ctx: common.UIAbilityContext): number {
  const v: string | undefined = readAll(ctx).get(KEY_LS_IDLE_SECS);
  const n: number = Number(v);
  if (Number.isFinite(n) && n >= 0) {
    return Math.floor(n);
  }
  return 300;
}

export function saveLsIdleSecs(ctx: common.UIAbilityContext, secs: number): void {
  const map: Map<string, string> = readAll(ctx);
  map.set(KEY_LS_IDLE_SECS, `${secs}`);
  writeAll(ctx, map);
}
