import { common } from '@kit.AbilityKit';
import { SuperFiles } from '@superfiles/core';
import { loadMounts, MountConfig, saveMounts } from './MountStore';

/**
 * 确保挂载已连接（索引扫描/打开前调用）。
 * 进程重启后挂载会失效，直接 core.list/扫描会报「no backend mounted 」。
 * 连接成功后把最新的 rootId 写回配置并持久化。
 */
export function isMounted(core: SuperFiles, rootId: string): boolean {
  if (rootId.length === 0) {
    return false;
  }
  try {
    for (const m of core.mounts()) {
      if (m.rootId === rootId) {
        return true;
      }
    }
  } catch (e) {
    // ignore
  }
  return false;
}

/** 重新建立连接；失败返回 null（调用方提示）。 */
export function ensureMounted(ctx: common.UIAbilityContext, core: SuperFiles,
  c: MountConfig, all: MountConfig[]): string | null {
  if (isMounted(core, c.rootId)) {
    return c.rootId;
  }
  let rootId: string = '';
  try {
    if (c.proto === 'SMB') {
      const port: number = c.port.trim().length === 0 ? 445 : Number(c.port);
      rootId = core.mountSmb(c.label, c.host, c.share, c.user, c.pass, port);
    } else if (c.proto === 'WebDAV') {
      rootId = core.mountWebdav(c.label, c.host, c.user, c.pass);
    } else if (c.proto === 'SFTP') {
      const port: number = c.port.trim().length === 0 ? 22 : Number(c.port);
      rootId = core.mountSftp(c.label, c.host, port, c.user, c.pass);
    } else if (c.proto === 'Dropbox') {
      rootId = core.mountDropbox(c.label, c.host, c.share, c.user, c.pass);
    } else if (c.proto === 'GoogleDrive') {
      rootId = core.mountGoogleDrive(c.label, c.host, c.share, c.user, c.pass);
    } else if (c.proto === 'OneDrive') {
      rootId = core.mountCloud('onedrive', c.label, c.host, c.share, c.user, c.pass);
    } else if (c.proto === '115') {
      rootId = core.mountCloud('115', c.label, c.host, c.share, c.user, c.pass);
    } else {
      return null;
    }
  } catch (e) {
    return null;
  }
  c.rootId = rootId;
  saveMounts(ctx, all);
  return rootId;
}

/**
 * 按条目 id 自动补连挂载（索引/搜索/最近打开可能拿到未连接的远端条目）。
 * 返回 false 表示找不到对应配置或连接失败——调用方应提示「挂载未连接」。
 */
export function ensureMountedForId(ctx: common.UIAbilityContext, core: SuperFiles, id: string): boolean {
  if (id.length === 0 || id.startsWith('/')) {
    return true; // 沙箱内文件无需挂载
  }
  try {
    for (const m of core.mounts()) {
      if (id === m.rootId || id.startsWith(`${m.rootId}/`)) {
        return true;
      }
    }
  } catch (e) {
    // fall through to reconnect
  }
  const configs: MountConfig[] = loadMounts(ctx);
  for (const c of configs) {
    if (c.rootId.length === 0) {
      continue;
    }
    if (id === c.rootId || id.startsWith(`${c.rootId}/`)) {
      return ensureMounted(ctx, core, c, configs) !== null;
    }
  }
  return false;
}
