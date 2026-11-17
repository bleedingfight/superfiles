import { UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { detectSystemLang } from '../common/L10n';
import { initScanCenter } from '../common/ScanCenter';
import { loadShowHidden, loadNick } from '../common/Settings';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    AppStorage.setOrCreate('sfDark', this.isSystemDark());
    AppStorage.setOrCreate('sfNick', loadNick(this.context).length > 0 ? loadNick(this.context) : '我');
    AppStorage.setOrCreate('sfTab', 0);
    AppStorage.setOrCreate('sfOpenId', '');
    AppStorage.setOrCreate('sfImportUri', '');
    AppStorage.setOrCreate('sfImportName', '');
    AppStorage.setOrCreate('sfBack', 'none');
    AppStorage.setOrCreate('sfBackRequest', 0);
    AppStorage.setOrCreate('sfShowHidden', loadShowHidden(this.context));
    AppStorage.setOrCreate('sfCategory', '');
    AppStorage.setOrCreate('sfScanningId', '');
    AppStorage.setOrCreate('sfScanLabel', '');
    AppStorage.setOrCreate('sfScanFraction', -1);
    AppStorage.setOrCreate('sfScanLastAt', 0);
    AppStorage.setOrCreate('sfSysLang', detectSystemLang());
    this.captureShare(want);
    this.captureOAuth(want);
    this.captureLocalSend(want);
    // keep-alive：启动后延迟触发本地根增量索引（增量预检通常秒回，不阻塞冷启动）
    setTimeout(() => {
      try {
        initScanCenter(this.context);
      } catch (e) {
        hilog.error(0x0000, 'SuperFiles', 'init scan center failed');
      }
    }, 600);
  }

  onNewWant(want: Want): void {
    this.captureShare(want);
    this.captureOAuth(want);
    this.captureLocalSend(want);
  }

  /** OAuth 深链回调：superfiles://oauth/callback?code=… 投递给云存储授权流程。 */
  private captureOAuth(want: Want): void {
    const uri: string = want.uri === undefined ? '' : want.uri;
    if (uri.startsWith('superfiles://oauth/callback')) {
      AppStorage.setOrCreate('sfOAuthUri', uri);
      hilog.info(0x0000, 'SuperFiles', 'oauth callback received');
    }
  }

  /** 一键组网深链：superfiles://localsend?ip=..&port=..&fp=.. → 近邻传输页注册对端。 */
  private captureLocalSend(want: Want): void {
    const uri: string = want.uri === undefined ? '' : want.uri;
    if (uri.startsWith('superfiles://localsend')) {
      AppStorage.setOrCreate('sfLocalSendUri', uri);
      AppStorage.setOrCreate('sfOpenLocalSend', 1);
      hilog.info(0x0000, 'SuperFiles', 'localsend pairing link received');
    }
  }

  /** Share-to-app ("分享到 Super Files") lands here with a file uri. */
  private captureShare(want: Want): void {
    const uri: string = want.uri === undefined ? '' : want.uri;
    // superfiles:// 是本应用自有深链（OAuth 回调 / LocalSend 组网码），不当导入素材
    if (uri.startsWith('superfiles://')) {
      return;
    }
    if (uri.length === 0) {
      return;
    }
    const slash: number = uri.lastIndexOf('/');
    let name: string = slash >= 0 ? uri.substring(slash + 1) : `导入-${Date.now()}`;
    const q: number = name.indexOf('?');
    if (q >= 0) {
      name = name.substring(0, q);
    }
    try {
      name = decodeURIComponent(name);
    } catch (e) {
      // keep the raw name
    }
    AppStorage.setOrCreate('sfImportUri', uri);
    AppStorage.setOrCreate('sfImportName', name);
  }

  onConfigurationUpdate(config: Configuration): void {
    AppStorage.setOrCreate('sfDark', config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    AppStorage.setOrCreate('sfSysLang', detectSystemLang());
  }

  private isSystemDark(): boolean {
    const mode: ConfigurationConstant.ColorMode =
      this.context.config.colorMode === undefined
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : this.context.config.colorMode;
    return mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, 'SuperFiles', 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, 'SuperFiles', 'loadContent succeeded');
    });
  }
}
