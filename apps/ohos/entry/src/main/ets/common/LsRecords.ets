/**
 * 近邻传输收发流水（跨页面共享：近邻传输页 + 传输中心都读它）。
 * LocalSend 不走内核引擎 transfers() 注册表，传输中心的「近邻传输」分组
 * 从这里取数 —— AppStorage 存 JSON（进程内会话级，够用且零持久化噪音）。
 */

export interface LsRecord {
  /** 'in' = 收到 / 'out' = 发出 */
  dir: string;
  name: string;
  size: number;
  /** epoch millis */
  at: number;
  peer: string;
}

const KEY: string = 'sfLsRecords';

export function lsRecords(): LsRecord[] {
  const json: string | undefined = AppStorage.get<string>(KEY);
  if (json === undefined || json.length === 0) {
    return [];
  }
  try {
    const parsed: LsRecord[] = JSON.parse(json) as LsRecord[];
    return Array.isArray(parsed) ? parsed : [];
  } catch (e) {
    return [];
  }
}

export function addLsRecord(rec: LsRecord): void {
  const list: LsRecord[] = lsRecords();
  list.unshift(rec);
  AppStorage.setOrCreate(KEY, JSON.stringify(list.slice(0, 50)));
}
