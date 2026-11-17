import { common } from '@kit.AbilityKit';
import { SuperFiles, uniffiLoad, uniffiUnload } from '@superfiles/core';

/**
 * Process-wide handle to the Rust core.
 *
 * The core is opened once per process: `local_root` is the app sandbox storage
 * directory and the SQLite index lives next to it. Opening is cheap but the
 * index must not be opened twice, so every page goes through `getCore()`.
 */
let core: SuperFiles | null = null;

export function getCore(ctx: common.UIAbilityContext): SuperFiles {
  if (core === null) {
    // Loads libsuperfiles_arkts.so, which links libsuperfiles.so (see
    // scripts/build-ohos.sh — both are packaged into entry/libs/arm64-v8a).
    uniffiLoad();
    core = SuperFiles.open(`${ctx.filesDir}/storage`, `${ctx.filesDir}/index.sqlite`);
  }
  return core;
}

export function closeCore(): void {
  if (core !== null) {
    core.destroy();
    core = null;
    uniffiUnload();
  }
}

export function storageRoot(ctx: common.UIAbilityContext): string {
  return `${ctx.filesDir}/storage`;
}
