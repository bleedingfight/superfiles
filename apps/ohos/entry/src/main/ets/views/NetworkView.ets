import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import {
  CloudProviderDef,
  cloudProviderById,
  exchangeCodeForTokens,
  buildAuthorizeUrl,
  openAuthorizePage,
  parseOAuthCallback,
  authorizeViaLoopback,
  authorizeViaDeviceCode,
  visibleCloudProviders,
  usesLoopback,
  beginAuth,
  BeginAuthResult,
  PendingAuth,
  TokenSet
} from '../common/CloudAuth';
import { MountInfo, SuperFiles } from '@superfiles/core';
import { getCore } from '../common/Core';
import { errText } from '../common/Format';
import { t } from '../common/L10n';
import { loadMounts, saveMounts, MountConfig } from '../common/MountStore';
import {
  theme, Palette, SCREEN_MARGIN, RADIUS_M, RADIUS_PILL, RADIUS_L,
  SPACE1, SPACE2, SPACE3, SPACE4, T_CARD_TITLE, T_BODY, T_SECONDARY
} from '../common/Tokens';

const PROTO_SMB: string = 'SMB';
const PROTO_WEBDAV: string = 'WebDAV';
const PROTO_SFTP: string = 'SFTP';
const PROTO_S3: string = 'S3';
const PROTO_DROPBOX: string = 'Dropbox';
const PROTO_GDRIVE: string = 'GoogleDrive';
const PROTO_ONEDRIVE: string = 'OneDrive';
const PROTO_115: string = '115';
const PROTO_CLOUD: string = 'Cloud';

/** 网络存储管理（从「我的」独立出来：首页「管理」进入）。 */
@Component
export struct NetworkView {
  @State mounts: MountInfo[] = [];
  @State configs: MountConfig[] = [];
  @State proto: string = PROTO_SMB;
  @State region: string = 'us-east-1';
  @State pathStyle: boolean = false;
  @State label: string = '';
  @State host: string = '';
  @State share: string = '';
  @State user: string = '';
  @State pass: string = '';
  @State port: string = '';
  @State shares: string[] = [];
  @State netbios: string = '';
  @State scanning: boolean = false;
  @State editingRootId: string = '';
  @State busy: boolean = false;
  @State msg: string = '';
  @State error: string = '';
  @State showForm: boolean = false;
  @State menuRootId: string = '';
  @State showCloudPicker: boolean = false;
  @State cloudNotice: string = '';
  @StorageLink('sfOAuthUri') @Watch('onOAuthUri') oauthUri: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
      this.loadConfigs();
      this.reload();
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
    }
  }

  private loadConfigs(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.configs = loadMounts(ctx);
  }

  private saveConfigs(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!saveMounts(ctx, this.configs)) {
      this.error = this.tt('files.readFailed');
    }
  }

  private upsertConfig(cfg: MountConfig): void {
    const next: MountConfig[] = [];
    for (const c of this.configs) {
      if (c.rootId !== cfg.rootId && c.label !== cfg.label) {
        next.push(c);
      }
    }
    next.push(cfg);
    this.configs = next;
    this.saveConfigs();
  }

  private dropConfig(rootId: string): void {
    const next: MountConfig[] = [];
    for (const c of this.configs) {
      if (c.rootId !== rootId) {
        next.push(c);
      }
    }
    this.configs = next;
    this.saveConfigs();
  }

  private reload(): void {
    if (this.core === null) {
      return;
    }
    try {
      this.mounts = this.core.mounts();
      this.loadConfigs();
    } catch (e) {
      this.error = this.tt('files.readFailed') + '：' + errText(e);
    }
  }

  private resetForm(): void {
    this.label = '';
    this.host = '';
    this.share = '';
    this.user = '';
    this.pass = '';
    this.port = '';
    this.shares = [];
    this.netbios = '';
    this.editingRootId = '';
  }

  private startEdit(m: MountInfo): void {
    for (const c of this.configs) {
      if (c.rootId === m.rootId) {
        this.proto = c.proto;
        this.label = c.label;
        this.host = c.host;
        this.share = c.share;
        this.user = c.user;
        this.pass = c.pass;
        this.port = c.port;
        this.editingRootId = m.rootId;
        this.showForm = true;
        this.msg = this.tt('mine.editHint');
        return;
      }
    }
    this.error = this.tt('mine.noSavedConfig');
  }

  private doMount(): void {
    if (this.core === null) {
      return;
    }
    if (this.label.trim().length === 0 || this.host.trim().length === 0) {
      this.error = this.tt('mine.nameHostRequired');
      return;
    }
    if (this.proto === PROTO_WEBDAV) {
      const h: string = this.host.trim().toLowerCase();
      if (!h.startsWith('http://') && !h.startsWith('https://')) {
        this.error = this.tt('mine.webdavNeedsScheme');
        return;
      }
    }
    this.busy = true;
    try {
      if (this.editingRootId.length > 0) {
        this.core.unmount(this.editingRootId);
        this.dropConfig(this.editingRootId);
      }
      let rootId: string = '';
      if (this.proto === PROTO_SMB) {
        const p: number = this.port.trim().length === 0 ? 445 : Number(this.port);
        rootId = this.core.mountSmb(this.label.trim(), this.host.trim(), this.share.trim(), this.user, this.pass, p);
      } else if (this.proto === PROTO_WEBDAV) {
        rootId = this.core.mountWebdav(this.label.trim(), this.host.trim(), this.user, this.pass);
      } else if (this.proto === PROTO_SFTP) {
        const p: number = this.port.trim().length === 0 ? 22 : Number(this.port);
        rootId = this.core.mountSftp(this.label.trim(), this.host.trim(), p, this.user, this.pass);
      } else if (this.proto === PROTO_S3) {
        rootId = this.core.mountS3(
          this.label.trim(), this.host.trim(), this.region.trim(), this.share.trim(),
          this.user, this.pass, '', this.pathStyle);
      } else if (this.proto === PROTO_DROPBOX) {
        rootId = this.core.mountDropbox(this.label.trim(), this.host.trim(), this.share.trim(), this.user, this.pass);
      } else {
        rootId = this.core.mountGoogleDrive(this.label.trim(), this.host.trim(), this.share.trim(), this.user, this.pass);
      }
      this.upsertConfig({
        proto: this.proto, label: this.label.trim(), host: this.host.trim(), share: this.share.trim(),
        user: this.user, pass: this.pass, port: this.port, rootId: rootId,
        region: this.region.trim(), pathStyle: this.pathStyle,
      });
      this.msg = this.tt('mine.mountOk', this.label);
      this.error = '';
      this.showForm = false;
      this.resetForm();
      this.reload();
    } catch (e) {
      this.error = this.tt('mine.mountFailed') + '：' + errText(e);
    }
    this.busy = false;
  }

  private doUnmount(m: MountInfo): void {
    if (this.core === null) {
      return;
    }
    try {
      this.core.unmount(m.rootId);
      this.dropConfig(m.rootId);
      this.msg = this.tt('mine.unmounted', m.label);
      this.reload();
    } catch (e) {
      this.error = this.tt('mine.unmountFailed') + '：' + errText(e);
    }
  }

  private removeMount(m: MountInfo): void {
    if (this.core !== null) {
      try {
        this.core.unmount(m.rootId);
      } catch (e) {
        // best effort
      }
    }
    this.dropConfig(m.rootId);
    this.msg = this.tt('home.removeMount') + '：' + m.label;
    this.reload();
  }

  private menuMount(): MountInfo | null {
    for (const m of this.mounts) {
      if (m.rootId === this.menuRootId) {
        return m;
      }
    }
    return null;
  }

  private reconnectAll(): void {
    if (this.core === null) {
      return;
    }
    const live: string[] = [];
    for (const m of this.mounts) {
      live.push(m.label);
    }
    let ok: number = 0;
    let failed: number = 0;
    for (const c of this.configs) {
      if (live.indexOf(c.label) >= 0) {
        continue;
      }
      try {
        let rootId: string = '';
        if (c.proto === PROTO_SMB) {
          rootId = this.core.mountSmb(c.label, c.host, c.share, c.user, c.pass,
            c.port.trim().length === 0 ? 445 : Number(c.port));
        } else if (c.proto === PROTO_WEBDAV) {
          rootId = this.core.mountWebdav(c.label, c.host, c.user, c.pass);
        } else if (c.proto === PROTO_SFTP) {
          rootId = this.core.mountSftp(c.label, c.host,
            c.port.trim().length === 0 ? 22 : Number(c.port), c.user, c.pass);
        } else if (c.proto === PROTO_S3) {
          rootId = this.core.mountS3(
            c.label, c.host, c.region ?? '', c.share, c.user, c.pass, '', c.pathStyle ?? false);
        } else if (c.proto === PROTO_DROPBOX) {
          rootId = this.core.mountDropbox(c.label, c.host, c.share, c.user, c.pass);
        } else {
          rootId = this.core.mountGoogleDrive(c.label, c.host, c.share, c.user, c.pass);
        }
        c.rootId = rootId;
        ok++;
      } catch (e) {
        failed++;
      }
    }
    this.saveConfigs();
    this.msg = failed === 0 ? this.tt('mine.reconnectOk', `${ok}`) : this.tt('mine.reconnectPartial', `${ok}`, `${failed}`);
    this.reload();
  }

  private listShares(): void {
    if (this.core === null || this.host.trim().length === 0) {
      this.error = this.tt('mine.fillHostFirst');
      return;
    }
    this.scanning = true;
    try {
      const p: number = this.port.trim().length === 0 ? 445 : Number(this.port);
      const nb: string | undefined = this.core.smbNetbiosName(this.host.trim());
      this.netbios = nb === undefined ? '' : nb;
      this.shares = this.core.smbListShares(this.host.trim(), p, this.user, this.pass);
      this.msg = this.shares.length === 0 ? this.tt('mine.noShares') : this.tt('mine.sharesFound', `${this.shares.length}`);
      this.error = '';
    } catch (e) {
      this.error = this.tt('mine.listFailed') + '：' + errText(e);
    }
    this.scanning = false;
  }

  @Builder
  protoChip(name: string) {
    Text(name)
      .fontSize(T_BODY)
      .fontColor(this.proto === name ? this.th().onPrimary : this.th().onSurface)
      .backgroundColor(this.proto === name ? this.th().primary : this.th().searchFieldBg)
      .padding({ left: SPACE4, right: SPACE4, top: 7, bottom: 7 })
      .borderRadius(RADIUS_PILL)
      .onClick(() => this.proto = name)
  }

  /** 「网络存储」入口 chip：点击弹出 Dropbox / Google Drive 品牌列表。 */
  @Builder
  cloudChip() {
    Text(this.tt('mine.cloudStorage'))
      .fontSize(T_BODY)
      .fontColor(this.showCloudPicker ? this.th().onPrimary : this.th().onSurface)
      .backgroundColor(this.showCloudPicker ? this.th().primary : this.th().searchFieldBg)
      .padding({ left: SPACE4, right: SPACE4, top: 7, bottom: 7 })
      .borderRadius(RADIUS_PILL)
      .onClick(() => {
        this.cloudNotice = '';
        this.showCloudPicker = true;
      })
  }

  /** Dropbox 品牌图标（蓝色开口盒，Polygon 绘制：上排两个菱形相接，下排两片斜板垂在外沿）。 */
  @Builder
  dropboxIcon() {
    Column({ space: 0 }) {
      Row({ space: 0 }) {
        Polygon().points([[0, 5], [6.5, 0], [13, 5], [6.5, 10]]).fill('#0061FF').width(13).height(11)
        Polygon().points([[0, 5], [6.5, 0], [13, 5], [6.5, 10]]).fill('#0061FF').width(13).height(11)
      }
      .width(26)
      Row({ space: 0 }) {
        Polygon().points([[0, 0], [6.5, 5], [6.5, 11], [0, 6]]).fill('#0061FF').width(6.5).height(11)
        Blank().width(13)
        Polygon().points([[6.5, 0], [0, 5], [0, 11], [6.5, 6]]).fill('#0061FF').width(6.5).height(11)
      }
      .width(26)
      .justifyContent(FlexAlign.Center)
    }
    .width(28)
    .height(24)
    .justifyContent(FlexAlign.Center)
  }

  /** OneDrive 品牌图标。 */
  @Builder
  pan115Icon() {
    Text('115')
      .fontSize(10)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .width(24)
      .height(24)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor('#2E7CF6')
      .margin({ right: 2 })
  }

  @Builder
  onedriveIcon() {
    Text('☁')
      .fontSize(20)
      .fontColor('#0078D4')
      .width(28)
      .height(22)
      .textAlign(TextAlign.Center)
      .margin({ right: 2 })
  }

  /** Google Drive 品牌图标（三角框标：绿/蓝/黄三条色带，中间镂空，Polygon 绘制）。 */
  @Builder
  gdriveIcon() {
    Stack() {
      Polygon().points([[13, 0.92], [13, 8.25], [8.1, 15.58], [1.63, 19.25]]).fill('#34A853').width(26).height(20)
      Polygon().points([[13, 0.92], [24.38, 19.25], [17.9, 15.58], [13, 8.25]]).fill('#4285F4').width(26).height(20)
      Polygon().points([[1.63, 19.25], [24.38, 19.25], [17.9, 15.58], [8.1, 15.58]]).fill('#FBBC04').width(26).height(20)
    }
    .width(28)
    .height(22)
    .margin({ right: 2 })
  }

  /** 云盘行：品牌图标 + 名称（顺序由 visibleCloudProviders 决定）。 */
  @Builder
  cloudRow(p: CloudProviderDef) {
    Row({ space: SPACE3 }) {
      if (p.id === 'gdrive') {
        this.gdriveIcon()
      } else if (p.id === 'dropbox') {
        this.dropboxIcon()
      } else if (p.id === 'onedrive') {
        this.onedriveIcon()
      } else {
        this.pan115Icon()
      }
      Text(p.name)
        .fontColor(this.th().onSurface)
        .layoutWeight(1)
    }
    .width('100%')
    .height(56)
    .onClick(() => this.startCloudAuth(p.id))
  }

  /** 云盘选择：按「已配置优先 + 品牌顺序」渲染。 */
  @Builder
  cloudPickerSheet() {
    Column() {
      Blank().layoutWeight(1).onClick(() => {
        this.showCloudPicker = false;
      })
      Column({ space: SPACE2 }) {
        Text(this.tt('mine.cloudPickTitle'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .width('100%')
        Divider().color(this.th().divider)
        ForEach(visibleCloudProviders(), (p: CloudProviderDef) => {
          this.cloudRow(p)
          Divider().color(this.th().divider)
        }, (p: CloudProviderDef) => p.id)
        if (this.cloudNotice.length > 0) {
          Text(this.cloudNotice)
            .fontSize(12)
            .fontColor(this.th().error)
            .width('100%')
            .padding({ top: SPACE1 })
        }
        Button(this.tt('common.cancel'))
          .width('100%')
          .height(40)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => {
            this.showCloudPicker = false;
          })
      }
      .width('100%')
      .padding({ left: SPACE4, right: SPACE4, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  /** 发起云盘 OAuth 授权：loopback（Google）或深链（其它）。 */
  private startCloudAuth(providerId: string): void {
    const p: CloudProviderDef | null = cloudProviderById(providerId);
    if (p === null) {
      return;
    }
    if (p.clientId.length === 0) {
      this.cloudNotice = this.tt('mine.oauthNotConfigured', p.name);
      return;
    }
    const ctx: common.UIAbilityContext =
      this.getUIContext().getHostContext() as common.UIAbilityContext;

    if (p.authMode === 'device') {
      this.cloudNotice = this.tt('mine.oauthAuthorizing', p.name);
      authorizeViaDeviceCode(p, (qrcode: string) => {
        this.cloudNotice = '请在 115 App 中确认登录';
        ctx.openLink(qrcode);
      }).then((tokens: TokenSet) => {
        this.cloudNotice = '';
        this.showCloudPicker = false;
        this.mountCloud(p, tokens);
      }).catch((e: Error) => {
        this.cloudNotice = this.tt('mine.oauthFailed') + '：' + errText(e);
      });
      return;
    }

    if (usesLoopback(p)) {
      // Google：app 内起 127.0.0.1:8765 接收回调，不依赖深链
      this.cloudNotice = this.tt('mine.oauthAuthorizing', p.name);
      authorizeViaLoopback(p, ctx).then((tokens: TokenSet) => {
        this.cloudNotice = '';
        this.showCloudPicker = false;
        this.mountCloud(p, tokens);
      }).catch((e: Error) => {
        this.cloudNotice = this.tt('mine.oauthFailed') + '：' + errText(e);
      });
      return;
    }

    AppStorage.setOrCreate('sfOAuthPending', '');
    beginAuth(p).then((r: BeginAuthResult) => {
      AppStorage.setOrCreate('sfOAuthPending', JSON.stringify(r.pending));
      ctx.openLink(r.url);
      this.cloudNotice = this.tt('mine.oauthAuthorizing', p.name);
    }).catch((e: Error) => {
      this.cloudNotice = this.tt('mine.oauthFailed') + '：' + errText(e);
    });
  }

  /** 拿到 token 后挂载云盘并持久化配置（两条授权路径共用）。 */
  private mountCloud(p: CloudProviderDef, tokens: TokenSet): void {
    if (this.core === null) {
      return;
    }
    try {
      let rootId: string = '';
      if (p.id === 'dropbox') {
        rootId = this.core.mountDropbox(
          p.name, tokens.accessToken, tokens.refreshToken, p.clientId, p.clientSecret);
      } else if (p.id === 'onedrive') {
        rootId = this.core.mountCloud(
          'onedrive', p.name, tokens.accessToken, tokens.refreshToken,
          p.clientId, p.clientSecret);
      } else if (p.id === 'pan115') {
        rootId = this.core.mountCloud(
          '115', p.name, tokens.accessToken, tokens.refreshToken,
          p.clientId, p.clientSecret);
      } else {
        rootId = this.core.mountGoogleDrive(
          p.name, tokens.accessToken, tokens.refreshToken, p.clientId, p.clientSecret);
      }
      this.upsertConfig({
        proto: p.id === 'dropbox' ? PROTO_DROPBOX : (p.id === 'onedrive' ? PROTO_ONEDRIVE : (p.id === 'pan115' ? PROTO_115 : PROTO_GDRIVE)),
        label: p.name, host: tokens.accessToken, share: tokens.refreshToken,
        user: p.clientId, pass: p.clientSecret, port: '', rootId: rootId
      });
      AppStorage.setOrCreate('sfOAuthPending', '');
      this.msg = this.tt('mine.oauthOk', p.name);
      this.error = '';
      this.reload();
    } catch (e) {
      console.error(`[cloud] mount failed: ${(e as Error).message} | ${(e as Error).stack}`);
      this.error = this.tt('mine.mountFailed') + '：' + errText(e);
    }
  }

  /** OAuth 深链回调：换 token 并挂载云盘。 */
  private onOAuthUri(): void {
    if (this.oauthUri.length === 0) {
      return;
    }
    const uri: string = this.oauthUri;
    this.oauthUri = '';
    this.showCloudPicker = false;
    const cb = parseOAuthCallback(uri);
    if (cb === null) {
      return;
    }
    const stored: string = AppStorage.get<string>('sfOAuthPending') ?? '';
    let providerId: string = cb.providerId;
    let verifier: string = '';
    let expectedState: string = '';
    if (stored.length > 0) {
      try {
        const pa: PendingAuth = JSON.parse(stored) as PendingAuth;
        providerId = pa.providerId;
        verifier = pa.verifier;
        expectedState = pa.state;
      } catch (e) {
        // 兼容旧格式：AppStorage 里只存了 providerId
        providerId = stored;
      }
    }
    const p: CloudProviderDef | null = cloudProviderById(providerId);
    if (p === null) {
      return;
    }
    if (cb.error.length > 0) {
      this.error = this.tt('mine.oauthFailed') + '：' + cb.error;
      return;
    }
    if (expectedState.length > 0 && cb.state !== expectedState) {
      this.error = this.tt('mine.oauthFailed') + '：state mismatch';
      return;
    }
    if (cb.code.length === 0) {
      this.error = this.tt('mine.oauthFailed') + '：no code';
      return;
    }
    exchangeCodeForTokens(p, cb.code, verifier.length > 0 ? verifier : undefined)
      .then((tokens: TokenSet) => {
        AppStorage.setOrCreate('sfOAuthPending', '');
        this.mountCloud(p, tokens);
      }).catch((e: Error) => {
        this.error = this.tt('mine.oauthFailed') + '：' + errText(e);
      });
  }

  @Builder
  form() {
    Column({ space: SPACE2 }) {
      Row({ space: SPACE2 }) {
        this.protoChip(PROTO_SMB)
        this.protoChip(PROTO_WEBDAV)
        this.protoChip(PROTO_SFTP)
        this.protoChip(PROTO_S3)
        this.cloudChip()
      }
      TextInput({ text: this.label, placeholder: this.tt('mine.displayNamePh') })
        .height(42)
        .onChange((v: string) => this.label = v)
      TextInput({
        text: this.host,
        placeholder: this.proto === PROTO_WEBDAV ? this.tt('mine.webdavPh')
          : (this.proto === PROTO_S3 ? 'https://s3.amazonaws.com'
            : (this.proto === PROTO_DROPBOX || this.proto === PROTO_GDRIVE ? this.tt('mine.cloudTokenPh') : this.tt('mine.hostPh')))
      })
        .height(42)
        .onChange((v: string) => this.host = v)
      if (this.proto === PROTO_DROPBOX || this.proto === PROTO_GDRIVE) {
        TextInput({ text: this.share, placeholder: this.tt('mine.cloudRefreshPh') })
          .height(42)
          .onChange((v: string) => this.share = v)
        Text(this.tt('mine.cloudFieldHint')).fontSize(T_SECONDARY)
          .fontColor(this.th().onSurfaceVariant).width('100%')
      }
      if (this.proto === PROTO_S3) {
        TextInput({ text: this.share, placeholder: 'bucket' })
          .height(42)
          .onChange((v: string) => this.share = v)
        TextInput({ text: this.region, placeholder: 'region (us-east-1)' })
          .height(42)
          .onChange((v: string) => this.region = v)
        Row({ space: SPACE2 }) {
          Text('Path-style (MinIO / R2)')
            .fontSize(T_SECONDARY)
            .fontColor(this.th().onSurface)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.pathStyle })
            .onChange((v: boolean) => this.pathStyle = v)
        }
        .width('100%')
      }
      if (this.netbios.length > 0) {
        Text(this.tt('mine.netbios') + this.netbios).fontSize(T_SECONDARY).fontColor(this.th().success).width('100%')
      }
      if (this.proto === PROTO_SMB) {
        Row({ space: SPACE2 }) {
          TextInput({ text: this.share, placeholder: this.tt('mine.sharePh') })
            .height(42)
            .layoutWeight(1)
            .onChange((v: string) => this.share = v)
          Button(this.scanning ? this.tt('mine.listing') : this.tt('mine.listShares'))
            .fontSize(T_SECONDARY)
            .height(42)
            .backgroundColor(this.th().searchFieldBg)
            .fontColor(this.th().onSurface)
            .enabled(!this.scanning)
            .onClick(() => this.listShares())
        }
        if (this.shares.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.shares, (sv: string) => {
              Text(sv)
                .fontSize(T_SECONDARY)
                .fontColor(this.share === sv ? this.th().onPrimary : this.th().onSurface)
                .backgroundColor(this.share === sv ? this.th().primary : this.th().searchFieldBg)
                .padding({ left: SPACE3, right: SPACE3, top: 6, bottom: 6 })
                .borderRadius(RADIUS_PILL)
                .margin({ right: SPACE2, bottom: SPACE2 })
                .onClick(() => this.share = sv)
            }, (sv: string) => sv)
          }
          .width('100%')
        }
      }
      Row({ space: SPACE2 }) {
        TextInput({ text: this.user, placeholder: this.proto === PROTO_S3 ? 'Access Key'
            : (this.proto === PROTO_DROPBOX || this.proto === PROTO_GDRIVE ? 'client_id' : this.tt('mine.username')) })
          .height(42)
          .layoutWeight(1)
          .onChange((v: string) => this.user = v)
        if (this.proto === PROTO_SMB || this.proto === PROTO_SFTP) {
          TextInput({ text: this.port, placeholder: this.proto === PROTO_SMB ? '445' : '22' })
            .height(42)
            .width(90)
            .type(InputType.Number)
            .onChange((v: string) => this.port = v)
        }
      }
      TextInput({ text: this.pass, placeholder: this.proto === PROTO_S3 ? 'Secret Key'
          : (this.proto === PROTO_DROPBOX || this.proto === PROTO_GDRIVE ? 'client_secret' : this.tt('mine.password')) })
        .height(42)
        .type(InputType.Password)
        .onChange((v: string) => this.pass = v)
      Row({ space: SPACE2 }) {
        Button(this.tt('common.cancel'))
          .layoutWeight(1)
          .height(40)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => {
            this.showForm = false;
            this.resetForm();
          })
        Button(this.busy ? this.tt('mine.connecting') : (this.editingRootId.length > 0 ? this.tt('mine.saveReconnect') : this.tt('mine.mount')))
          .layoutWeight(1)
          .height(40)
          .backgroundColor(this.th().primary)
          .fontColor(this.th().onPrimary)
          .enabled(!this.busy)
          .onClick(() => this.doMount())
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  swipeMoreMountBtn(m: MountInfo) {
    Column() {
      Text(this.tt('common.more'))
        .fontSize(13)
        .fontColor(this.th().onPrimary)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().primary)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topRight: 14, bottomRight: 14 })
    .onClick(() => {
      this.menuRootId = m.rootId;
    })
  }

  @Builder
  swipeDeleteMountBtn(m: MountInfo) {
    Column() {
      Text(this.tt('home.removeMount'))
        .fontSize(13)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor(this.th().error)
    .justifyContent(FlexAlign.Center)
    .borderRadius({ topLeft: 14, bottomLeft: 14 })
    .onClick(() => {
      this.removeMount(m);
    })
  }

  // ---- 挂载条目「更多」菜单 -------------------------------------------------------
  @Builder
  menuRow(label: string, action: () => void, danger: boolean = false) {
    Text(label)
      .fontSize(15)
      .fontColor(danger ? this.th().error : this.th().onSurface)
      .width('100%')
      .height(44)
      .onClick(action)
  }

  @Builder
  mountMenuOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.menuRootId = '')
      Column({ space: SPACE2 }) {
        Text(this.menuMount() === null ? '' : (this.menuMount() as MountInfo).label)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Divider().color(this.th().divider)
        this.menuRow(this.tt('common.edit'), () => {
          const m: MountInfo | null = this.menuMount();
          this.menuRootId = '';
          if (m !== null) {
            this.startEdit(m);
          }
        })
        this.menuRow(this.tt('common.disconnect'), () => {
          const m: MountInfo | null = this.menuMount();
          this.menuRootId = '';
          if (m !== null) {
            this.doUnmount(m);
          }
        })
        this.menuRow(this.tt('home.removeMount'), () => {
          const m: MountInfo | null = this.menuMount();
          this.menuRootId = '';
          if (m !== null) {
            this.removeMount(m);
          }
        }, true)
        Button(this.tt('common.cancel'))
          .width('100%')
          .height(40)
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurfaceVariant)
          .onClick(() => this.menuRootId = '')
      }
      .width('100%')
      .padding({ left: SPACE4, right: SPACE4, top: SPACE4, bottom: 32 })
      .backgroundColor(this.th().surface)
      .borderRadius({ topLeft: RADIUS_L, topRight: RADIUS_L })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#33000000')
  }

  build() {
    Stack() {
      Scroll() {
      Column({ space: SPACE4 }) {
        Row() {
          Text(this.tt('mine.reconnectAll'))
            .fontSize(T_BODY)
            .fontColor(this.th().primary)
            .layoutWeight(1)
            .onClick(() => this.reconnectAll())
          Text(this.showForm ? this.tt('common.collapse') : this.tt('common.add'))
            .fontSize(T_BODY)
            .fontColor(this.th().primary)
            .onClick(() => {
              if (this.showForm) {
                this.showForm = false;
                this.resetForm();
              } else {
                this.resetForm();
                this.showForm = true;
              }
            })
        }
        .width('100%')

        if (this.error.length > 0) {
          Text(this.error).fontSize(T_BODY).fontColor(this.th().error).width('100%')
        }
        if (this.msg.length > 0) {
          Text(this.msg).fontSize(T_BODY).fontColor(this.th().success).width('100%')
        }

        Column({ space: SPACE2 }) {
          if (this.showForm) {
            this.form()
            Divider().color(this.th().divider)
          }
          if (this.mounts.length === 0) {
            Text(this.tt('mine.supports')).fontSize(T_SECONDARY)
              .fontColor(this.th().onSurfaceVariant).width('100%')
          } else {
            List() {
              ForEach(this.mounts, (m: MountInfo) => {
                ListItem() {
                  Row({ space: SPACE2 }) {
                    Column({ space: 2 }) {
                      Text(m.label).fontSize(T_BODY).fontColor(this.th().onSurface).width('100%')
                      Text(m.scheme).fontSize(T_SECONDARY).fontColor(this.th().onSurfaceVariant).width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Text(this.tt('common.edit')).fontSize(T_BODY).fontColor(this.th().primary)
                      .onClick(() => this.startEdit(m))
                    Text(this.tt('common.disconnect')).fontSize(T_BODY).fontColor(this.th().error)
                      .onClick(() => this.doUnmount(m))
                  }
                  .width('100%')
                  .constraintSize({ minHeight: 72 })
                  .padding({ top: SPACE1, bottom: SPACE1 })
                }
                .swipeAction({
                  start: {
                    builder: () => {
                      this.swipeDeleteMountBtn(m);
                    },
                    actionAreaDistance: 56
                  },
                  end: {
                    builder: () => {
                      this.swipeMoreMountBtn(m);
                    },
                    actionAreaDistance: 56
                  }
                })
              }, (m: MountInfo) => m.rootId)
            }
            .width('100%')
            .height(this.mounts.length * 72 + 2)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .divider({ strokeWidth: 0.5, color: this.th().divider, startMargin: 12 })
          }
        }
        .width('100%')
        .padding(SPACE4)
        .backgroundColor(this.th().surfaceCard)
        .borderRadius(RADIUS_M)
      }
      .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: SPACE2, bottom: 24 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surface)
    .scrollBar(BarState.Off)

    if (this.menuRootId.length > 0) {
      this.mountMenuOverlay()
    }
    if (this.showCloudPicker) {
      this.cloudPickerSheet()
    }
    }
    .width('100%')
    .height('100%')
  }
}
