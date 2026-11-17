import { common, wantConstant, Want } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { SuperFiles } from '@superfiles/core';
import { ensureMountedForId } from './MountOps';

/**
 * 应用外打开兜底：把条目落地到缓存（本地/网络后端统一），用
 * FLAG_AUTH_READ_URI_PERMISSION 把读授权带给接收方，拉起系统 viewData。
 * 没有应用能处理时 startAbility 抛错，由调用方提示。
 */

const CHUNK: number = 2 * 1024 * 1024;

/** 常见文档/音频后缀 → MIME（系统按 MIME 路由到可处理的应用，如 WPS、音乐播放器）。 */
export function mimeOfName(name: string): string {
  const lower: string = name.toLowerCase();
  const dot: number = lower.lastIndexOf('.');
  const ext: string = dot >= 0 ? lower.substring(dot + 1) : '';
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'txt':
      return 'text/plain';
    case 'csv':
      return 'text/csv';
    case 'md':
      return 'text/markdown';
    case 'epub':
      return 'application/epub+zip';
    case 'mp3':
      return 'audio/mpeg';
    case 'flac':
      return 'audio/flac';
    case 'wav':
      return 'audio/x-wav';
    case 'aac':
      return 'audio/aac';
    case 'm4a':
      return 'audio/mp4';
    case 'ogg':
      return 'audio/ogg';
    case 'opus':
      return 'audio/opus';
    case 'amr':
      return 'audio/amr';
    case 'ape':
      return 'audio/x-ape';
    case 'wv':
      return 'audio/x-wavpack';
    case 'aiff':
    case 'aif':
      return 'audio/x-aiff';
    case 'au':
      return 'audio/basic';
    case 'mid':
    case 'midi':
      return 'audio/midi';
    default:
      return 'application/octet-stream';
  }
}

function hashOf(id: string): number {
  let h: number = 5381;
  for (let i = 0; i < id.length; i++) {
    h = (h * 33 + id.charCodeAt(i)) | 0;
  }
  return h;
}

function safeExt(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  const ext: string = name.substring(dot).toLowerCase();
  return /^\.[a-z0-9]{1,10}$/.test(ext) ? ext : '';
}

/** 落地文件名：保留原文件名（接收方应用里显示友好），哈希防重名冲突。 */
function safeBase(name: string): string {
  const dot: number = name.lastIndexOf('.');
  const stem: string = (dot >= 0 ? name.substring(0, dot) : name).toLowerCase();
  const cleaned: string = stem.replace(/[^a-z0-9一-龥_-]/g, '_').substring(0, 40);
  return cleaned.length > 0 ? cleaned : 'file';
}

/** 落地到缓存的完整路径（已存在且大小一致则直接复用）。 */
function materialize(ctx: common.UIAbilityContext, core: SuperFiles, id: string,
  name: string, size: number): string {
  const path: string = `${ctx.cacheDir}/ext_${safeBase(name)}_${hashOf(id)}${safeExt(name)}`;
  try {
    if (fileIo.accessSync(path)) {
      const st = fileIo.statSync(path);
      if (Number(st.size) === size) {
        return path;
      }
    }
  } catch (e) {
    // fall through and re-download
  }
  const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    let off: number = 0;
    while (off < size) {
      const want: number = Math.min(CHUNK, size - off);
      const chunk: Uint8Array = core.readBytes(id, BigInt(off), want);
      if (chunk.length === 0) {
        break;
      }
      fileIo.writeSync(f.fd, chunk.buffer as ArrayBuffer);
      off += chunk.length;
    }
    if (off < size) {
      throw new Error('incomplete');
    }
  } finally {
    fileIo.closeSync(f);
  }
  return path;
}

/**
 * 用第三方应用打开条目。可能抛异常：
 * 落地失败 / 未找到可处理的应用 / 用户取消 —— 调用方按需提示。
 */
export async function openEntryExternal(ctx: common.UIAbilityContext, core: SuperFiles,
  id: string, name: string, size: number): Promise<void> {
  if (size <= 0 || size > 512 * 1024 * 1024) {
    throw new Error('size-unsupported');
  }
  if (!ensureMountedForId(ctx, core, id)) {
    throw new Error('backend-offline');
  }
  const path: string = materialize(ctx, core, id, name, size);
  const uri: string = fileUri.getUriFromPath(path);
  const want: Want = {
    action: 'ohos.want.action.viewData',
    uri: uri,
    type: mimeOfName(name),
    flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
  };
  await ctx.startAbility(want);
}
