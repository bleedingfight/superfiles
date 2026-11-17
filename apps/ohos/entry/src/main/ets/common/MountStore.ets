import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * Shared network-mount config store (line-based file, same format MineView
 * has always used). Home shows ALL saved configs with online/offline status;
 * Mine edits them.
 */
export interface MountConfig {
  proto: string;
  label: string;
  host: string;
  share: string;
  user: string;
  pass: string;
  port: string;
  rootId: string;
  /** S3 专用：区域 / 路径寻址。 */
  region?: string;
  pathStyle?: boolean;
}

const SEP: string = '\u0001';

export function loadMounts(ctx: common.UIAbilityContext): MountConfig[] {
  const path: string = `${ctx.filesDir}/mounts.conf`;
  let text: string = '';
  try {
    if (fileIo.accessSync(path)) {
      text = fileIo.readTextSync(path);
    }
  } catch (e) {
    return [];
  }
  const out: MountConfig[] = [];
  if (text.length === 0) {
    return out;
  }
  const lines: string[] = text.split('\n');
  for (const line of lines) {
    const f: string[] = line.split(SEP);
    if (f.length >= 8) {
      out.push({
        proto: f[0], label: f[1], host: f[2], share: f[3],
        user: f[4], pass: f[5], port: f[6], rootId: f[7],
        region: f.length > 8 ? f[8] : '',
        pathStyle: f.length > 9 ? f[9] === '1' : false,
      });
    }
  }
  return out;
}

export function saveMounts(ctx: common.UIAbilityContext, list: MountConfig[]): boolean {
  const lines: string[] = [];
  for (const c of list) {
    lines.push([c.proto, c.label, c.host, c.share, c.user, c.pass, c.port, c.rootId, c.region ?? '', c.pathStyle ? '1' : '0'].join(SEP));
  }
  try {
    const f = fileIo.openSync(`${ctx.filesDir}/mounts.conf`,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, lines.join('\n'));
    fileIo.closeSync(f);
    return true;
  } catch (e) {
    return false;
  }
}
