import {
  SfError,
  SfErrorAlreadyExistsPayload,
  SfErrorCancelledPayload,
  SfErrorInvalidNamePayload,
  SfErrorIoPayload,
  SfErrorNetworkPayload,
  SfErrorNotFoundPayload,
  SfErrorPermissionDeniedPayload,
  SfErrorUnsupportedPayload
} from '@superfiles/core';

/**
 * Small formatting helpers shared by the UI.
 */

export function formatBytes(n: number): string {
  if (n <= 0) {
    return '0 B';
  }
  if (n < 1024) {
    return `${n} B`;
  }
  const units: string[] = ['KB', 'MB', 'GB', 'TB', 'PB'];
  let v: number = n / 1024;
  let i: number = 0;
  while (v >= 1024 && i < units.length - 1) {
    v = v / 1024;
    i++;
  }
  const text: string = v >= 10 ? v.toFixed(0) : v.toFixed(1);
  return `${text} ${units[i]}`;
}

export function formatDate(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d = new Date(ms);
  const pad = (x: number): string => (x < 10 ? `0${x}` : `${x}`);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** HH:mm:ss（传输记录的开始/结束时刻用）。 */
export function formatClock(ms: number): string {
  if (ms <= 0) {
    return '';
  }
  const d = new Date(ms);
  const pad = (x: number): string => (x < 10 ? `0${x}` : `${x}`);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

/** 人类可读的耗时：45秒 / 3分32秒 / 1小时2分。 */
export function formatDuration(ms: number): string {
  let s: number = Math.round(ms / 1000);
  if (s < 0) {
    s = 0;
  }
  if (s < 60) {
    return `${s}秒`;
  }
  const m: number = Math.floor(s / 60);
  const rs: number = s % 60;
  if (m < 60) {
    return rs > 0 ? `${m}分${rs}秒` : `${m}分钟`;
  }
  const h: number = Math.floor(m / 60);
  const rm: number = m % 60;
  return rm > 0 ? `${h}小时${rm}分` : `${h}小时`;
}

export function shortName(name: string, max: number): string {
  return name.length <= max ? name : `${name.substring(0, max - 1)}…`;
}

export interface RelTime {
  kind: number;
  arg: string;
}

export function formatRelTimeParts(ms: number): RelTime {
  // kind: 0=today 1=yesterday 2=daysAgo 3=date
  const now: number = Date.now();
  const startOf = (t: number): number => {
    const x: Date = new Date(t);
    x.setHours(0, 0, 0, 0);
    return x.getTime();
  };
  const d: Date = new Date(ms);
  const pad = (x: number): string => (x < 10 ? `0${x}` : `${x}`);
  const hhmm: string = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const days: number = Math.floor((startOf(now) - startOf(ms)) / 86400000);
  if (days <= 0) {
    return { kind: 0, arg: hhmm };
  }
  if (days === 1) {
    return { kind: 1, arg: hhmm };
  }
  if (days < 7) {
    return { kind: 2, arg: `${days}` };
  }
  return { kind: 3, arg: formatDate(ms) };
}

/**
 * 内核 SfError → 可读字符串（String(e) 只会得到 "SfErrorIo" 这类类名）。
 */
export function errText(e: Object): string {
  if (e instanceof SfError) {
    const p = e.payload;
    if (p instanceof SfErrorIoPayload) {
      return `io: ${p.detail}`;
    }
    if (p instanceof SfErrorNetworkPayload) {
      return `network: ${p.detail}`;
    }
    if (p instanceof SfErrorNotFoundPayload) {
      return `not found: ${p.detail}`;
    }
    if (p instanceof SfErrorPermissionDeniedPayload) {
      return `permission denied: ${p.detail}`;
    }
    if (p instanceof SfErrorAlreadyExistsPayload) {
      return `already exists: ${p.detail}`;
    }
    if (p instanceof SfErrorUnsupportedPayload) {
      return `unsupported: ${p.detail}`;
    }
    if (p instanceof SfErrorInvalidNamePayload) {
      return `invalid name: ${p.detail}`;
    }
    if (p instanceof SfErrorCancelledPayload) {
      return `cancelled: ${p.detail}`;
    }
    return e.variant;
  }
  return String(e);
}
