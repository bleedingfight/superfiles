import { common, Want } from '@kit.AbilityKit';
import {
  Entry,
  EntryKind,
  LocalSendHandle,
  LocalSendInfo,
  LocalSendPeer,
  LocalSendOptions,
  SuperFiles
} from '@superfiles/core';
import { getCore } from '../common/Core';
import { t } from '../common/L10n';
import { theme, Palette, SCREEN_MARGIN, RADIUS_M, RADIUS_S, RADIUS_PILL, SPACE2, SPACE3, SPACE4 } from '../common/Tokens';
import { formatBytes, formatClock, errText } from '../common/Format';
import { connection } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { generateBarcode, scanBarcode, scanCore } from '@kit.ScanKit';
import { loadLsIdleSecs, saveLsIdleSecs } from '../common/Settings';
import { SfPrimaryButton, SfSecondaryButton } from '../common/SfButton';
import { addLsRecord } from '../common/LsRecords';
import { router } from '@kit.ArkUI';

interface Crumb {
  id: string;
  name: string;
}

interface RecvItem {
  name: string;
  size: number;
  at: number;
}

@Component
export struct LocalSendView {
  @State running: boolean = false;
  @State peers: LocalSendPeer[] = [];
  @State picked: string[] = [];
  @State pickedNames: string[] = [];
  @State alias: string = 'Super Files';
  @State info: string = '';
  @State error: string = '';
  @State notice: string = '';
  @State browsing: boolean = false;
  @State crumbs: Crumb[] = [];
  @State entries: Entry[] = [];
  // ---- 一键组网（v1 热点向导 + v2 组网码）----
  @State pairing: string = '';            // '' / 'host' / 'client'
  @State selfIps: string[] = [];
  @State selIp: string = '';
  @State pairQr: image.PixelMap | null = null;
  @State ipInput: string = '';
  @State portInput: string = '53317';
  @State manualError: string = '';
  @State registered: LocalSendPeer[] = [];   // 手动/扫码注册（peers() 不含）
  @State idleSecs: number = 300;            // 无传输活动自动关闭（秒，0=永不）
  @State idlePicker: boolean = false;
  // 已接收清单（快照对账得出；行点击跳所在目录）
  @State received: RecvItem[] = [];
  private recvSeen: Set<string> = new Set();
  private recvSeeded: boolean = false;
  @StorageLink('sfLocalSendUri') @Watch('lsLinkChanged') lsLink: string = '';
  @StorageLink('sfDark') dark: boolean = false;
  @StorageLink('sfSysLang') sysLang: string = 'zh';
  @Prop embedded: boolean = false;
  private core: SuperFiles | null = null;

  private th(): Palette {
    return theme(this.dark);
  }

  private tt(key: string, ...args: string[]): string {
    return t(this.sysLang, key, ...args);
  }
  private handle: LocalSendHandle | null = null;
  private timer: number = -1;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.core = getCore(ctx);
      this.crumbs = [{ id: this.core.rootId(), name: this.tt('files.thisDevice') }];
      this.loadDir();
    } catch (e) {
      this.error = this.tt('common.coreNotReady') + '：' + errText(e);
    }
    // 服务不再跟随页面生命周期（保持与 Android VM 行为一致）：接管已运行的句柄
    if (this.core !== null) {
      const existing: LocalSendHandle | undefined = this.core.localSendHandle();
      if (existing !== undefined) {
        this.handle = existing;
        this.running = existing.isRunning();
      }
    }
    this.timer = setInterval(() => this.poll(), 1500);
    this.idleSecs = loadLsIdleSecs(this.getUIContext().getHostContext() as common.UIAbilityContext);
    // 冷启动即带组网深链时 @Watch 不触发，补一次
    this.lsLinkChanged();
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    // 注意：这里【不】stop()。服务生命周期对齐 Android（在 VM/内核层）：
    // 交给「无传输活动自动关闭」(idle_timeout) 与用户手动「停止」；
    // 页面栈进出（深链二次 pushUrl / 返回）不再误杀接收服务。
  }

  private poll(): void {
    if (this.handle !== null) {
      try {
        const fresh: LocalSendPeer[] = this.handle.peers();
        // 手动/扫码注册的对端：一旦被组播自然发现（同热点/无隔离），交给发现列表
        const known: LocalSendPeer[] = this.registered.filter((r: LocalSendPeer) => {
          return !fresh.some((p: LocalSendPeer) => p.ip === r.ip && p.port === r.port);
        });
        this.registered = known;
        this.peers = fresh;
        this.running = this.handle.isRunning();
        const inf: LocalSendInfo = this.handle.info();
        this.info = `端口 ${inf.port} · 指纹 ${inf.fingerprint.substring(0, 12)}…`;
        const errs: string[] = this.handle.errors();
        if (errs.length > 0) {
          this.error = errs[errs.length - 1];
        }
      } catch (e) {
        // handle may be gone
      }
    }
    this.pollRecv();
  }

  /**
   * 接收到账对账：接收目录快照 diff，新文件进「已接收」清单、
   * 近邻流水（传输中心分组）并弹一次提示 —— 解决"弹完就找不到"。
   */
  private pollRecv(): void {
    if (this.core === null || !this.running) {
      return;
    }
    try {
      const rootId: string = this.core.rootId();
      const ents: Entry[] = this.core.list(rootId);
      if (!this.recvSeeded) {
        for (const e of ents) {
          this.recvSeen.add(e.name);
        }
        this.recvSeeded = true;
        return;
      }
      const freshItems: RecvItem[] = [];
      for (const e of ents) {
        if (e.kind === EntryKind.File && !e.name.endsWith('.tmp') && !this.recvSeen.has(e.name)) {
          this.recvSeen.add(e.name);
          freshItems.push({ name: e.name, size: Number(e.size), at: Date.now() });
        }
      }
      if (freshItems.length > 0) {
        this.received = freshItems.concat(this.received).slice(0, 20);
        const sender: string = this.peers.length > 0 ? this.peers[0].alias : '';
        for (const it of freshItems) {
          addLsRecord({ dir: 'in', name: it.name, size: it.size, at: it.at, peer: sender });
        }
        this.notice = this.tt('ls.recvToast', `${freshItems.length}`);
      }
    } catch (e) {
      // 快照失败：下一轮再试
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private start(): void {
    if (this.core === null) {
      return;
    }
    try {
      const c = this.ctx();
      const options: LocalSendOptions = {
        alias: this.alias.trim().length === 0 ? 'Super Files' : this.alias.trim(),
        deviceModel: 'HarmonyOS',
        port: 53317,
        storeDir: c.filesDir,
        destDir: this.core.rootId(),
        pin: undefined,
        enableDiscovery: true,
        // 无传输活动自动关闭（用户可配，0=永不；组网待命同样适用）
        idleTimeoutSecs: BigInt(this.idleSecs)
      };
      this.handle = this.core.startLocalSend(options);
      this.running = true;
      this.notice = this.tt('ls.started');
      this.error = '';
      this.poll();
    } catch (e) {
      this.error = this.tt('ls.startFailed') + '：' + errText(e);
    }
  }

  private stop(): void {
    if (this.handle !== null) {
      try {
        this.handle.stop();
      } catch (e) {
        // best effort
      }
      this.handle = null;
    }
    if (this.core !== null) {
      try {
        this.core.stopLocalSend();
      } catch (e) {
        // best effort
      }
    }
    this.running = false;
    this.peers = [];
  }

  // ---- 一键组网（v1 热点向导 + v2 组网码）----

  /** 深链到达（系统深链 / App 内扫码 / 冷启动补触发）：解析并注册对端。 */
  lsLinkChanged(): void {
    if (this.lsLink.length === 0) {
      return;
    }
    const link: string = this.lsLink;
    this.lsLink = '';
    this.applyLink(link);
  }

  /** 解析 superfiles://localsend?ip=..&port=..&fp=..（与 Android 同契约）。 */
  private applyLink(link: string): void {
    const prefix: string = 'superfiles://localsend';
    if (link.indexOf(prefix) !== 0) {
      this.error = this.tt('ls.bad');
      return;
    }
    const rest: string = link.substring(prefix.length);
    const q: Map<string, string> = new Map();
    if (rest.startsWith('?')) {
      for (const kv of rest.substring(1).split('&')) {
        const at: number = kv.indexOf('=');
        if (at > 0) {
          q.set(kv.substring(0, at), kv.substring(at + 1));
        }
      }
    }
    const ip: string = q.get('ip') ?? '';
    if (ip.length === 0) {
      this.error = this.tt('ls.bad');
      return;
    }
    const port: number = Number(q.get('port')) || 53317;
    const fp: string = q.get('fp') ?? '';
    this.registerPeer(ip, port, fp.length > 0 ? fp : undefined);
  }

  /** 手动 IP / 组网码注册：先确保接收服务在跑，再来一次去重合入。 */
  private registerPeer(ip: string, port: number, fp: string | undefined): void {
    if (!this.running) {
      this.start();
    }
    let tries: number = 0;
    const attempt: () => void = (): void => {
      if (this.handle === null) {
        tries++;
        if (tries < 10) {
          setTimeout(attempt, 500);
        } else {
          this.error = this.tt('ls.startFailed');
        }
        return;
      }
      try {
        const peer: LocalSendPeer = this.handle.registerAt(ip, port, fp);
        const merged: LocalSendPeer[] = this.registered.filter((p: LocalSendPeer) => {
          return !(p.ip === peer.ip && p.port === peer.port);
        });
        merged.push(peer);
        this.registered = merged;
        this.notice = this.tt('ls.peerAdded', peer.alias.length > 0 ? peer.alias : ip);
        this.error = '';
        this.manualError = '';
      } catch (e) {
        this.manualError = this.tt('ls.registerFailed') + '：' + errText(e);
      }
    };
    attempt();
  }

  /** 发现列表 + 手动注册（去重，组播发现的优先展示）。 */
  private allPeers(): LocalSendPeer[] {
    const seen: LocalSendPeer[] = this.peers.slice();
    for (const r of this.registered) {
      const dup: boolean = seen.some((p: LocalSendPeer) => p.ip === r.ip && p.port === r.port);
      if (!dup) {
        seen.push(r);
      }
    }
    return seen;
  }

  /** 本机私网 IPv4（枚举全部网络接口），组网码展示用。 */
  private async loadSelfIps(): Promise<void> {
    try {
      const nets: Array<connection.NetHandle> = await connection.getAllNets();
      const found: string[] = [];
      for (const n of nets) {
        try {
          const props: connection.ConnectionProperties = await connection.getConnectionProperties(n);
          for (const la of props.linkAddresses) {
            const a: string = la.address.address;
            if (a.length > 0 && a.indexOf(':') < 0 && found.indexOf(a) < 0 &&
              (a.startsWith('192.168.') || a.startsWith('10.') || a.startsWith('172.'))) {
              found.push(a);
            }
          }
        } catch (e) {
          // 单个接口失败跳过
        }
      }
      found.sort();
      this.selfIps = found;
      if (this.selIp.length === 0 && found.length > 0) {
        this.selIp = found[0];
      }
      this.genPairQr();
    } catch (e) {
      this.selfIps = [];
    }
  }

  /** 组网码深链文本（含端口与证书指纹，TOFU 固定）。 */
  private pairLinkOf(): string {
    let port: number = 53317;
    let fp: string = '';
    if (this.handle !== null) {
      try {
        const inf: LocalSendInfo = this.handle.info();
        port = inf.port;
        fp = inf.fingerprint;
      } catch (e) {
        // 用默认值
      }
    }
    const link: string = `superfiles://localsend?ip=${this.selIp}&port=${port}`;
    return fp.length > 0 ? `${link}&fp=${fp}` : link;
  }

  /** 生成组网码二维码（ScanKit）；失败退化为链接文本。 */
  private genPairQr(): void {
    if (this.selIp.length === 0) {
      this.pairQr = null;
      return;
    }
    this.pairQr = null;
    generateBarcode.createBarcode(this.pairLinkOf(), {
      scanType: scanCore.ScanType.QR_CODE,
      width: 480,
      height: 480,
      margin: 2,
      level: generateBarcode.ErrorCorrectionLevel.LEVEL_M
    }).then((pm: image.PixelMap) => {
      this.pairQr = pm;
    }).catch(() => {
      this.pairQr = null;
    });
  }

  /** 跳系统热点设置（包名随版本变化，跳不动则提示手动开）。 */
  private openHotspotSettings(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = { bundleName: 'com.huawei.hmos.settings', abilityName: 'SettingsAbility' };
    ctx.startAbility(want).catch(() => {
      this.notice = this.tt('ls.openSettingsFail');
    });
  }

  /** App 内扫码（ScanKit 系统扫码页，无需相机权限样板代码）。 */
  private startScan(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    scanBarcode.startScanForResult(ctx).then((res: scanBarcode.ScanResult) => {
      this.applyLink(res.originalValue);
    }).catch(() => {
      // 用户取消 / 扫码服务不可用：静默返回
    });
  }

  private idleLabel(): string {
    if (this.idleSecs <= 0) {
      return this.tt('ls.idleNever');
    }
    return `${Math.round(this.idleSecs / 60)} ${this.tt('ls.idleMin')}`;
  }

  /** 修改「无传输活动自动关闭」：写盘；运行中立即重启生效。 */
  private pickIdle(secs: number): void {
    this.idleSecs = secs;
    saveLsIdleSecs(this.getUIContext().getHostContext() as common.UIAbilityContext, secs);
    this.idlePicker = false;
    if (this.running) {
      this.stop();
      this.start();
    }
  }

  private loadDir(): void {
    if (this.core === null) {
      return;
    }
    try {
      const id: string = this.crumbs[this.crumbs.length - 1].id;
      const all: Entry[] = this.core.list(id);
      const sorted: Entry[] = all.slice();
      sorted.sort((a: Entry, b: Entry) => {
        const ad: number = a.kind === EntryKind.Directory ? 0 : 1;
        const bd: number = b.kind === EntryKind.Directory ? 0 : 1;
        if (ad !== bd) {
          return ad - bd;
        }
        return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
      });
      this.entries = sorted;
    } catch (e) {
      this.error = this.tt('ls.readDirFailed') + '：' + errText(e);
    }
  }

  private addPicked(e: Entry): void {
    if (e.kind === EntryKind.Directory) {
      const next: Crumb[] = this.crumbs.slice();
      next.push({ id: e.id, name: e.name });
      this.crumbs = next;
      this.loadDir();
      return;
    }
    if (this.picked.indexOf(e.id) >= 0) {
      return;
    }
    const ids: string[] = this.picked.slice();
    ids.push(e.id);
    const names: string[] = this.pickedNames.slice();
    names.push(e.name);
    this.picked = ids;
    this.pickedNames = names;
  }

  private sendTo(peer: LocalSendPeer): void {
    if (this.handle === null || this.picked.length === 0) {
      return;
    }
    try {
      this.handle.send(peer, this.picked);
      // 发出流水：传输中心「近邻传输」分组（LocalSend 不进内核 transfers()）
      const now: number = Date.now();
      for (let i: number = 0; i < this.picked.length; i++) {
        const nm: string = this.pickedNames.length > i ? this.pickedNames[i] : this.picked[i];
        addLsRecord({ dir: 'out', name: nm, size: 0, at: now, peer: peer.alias });
      }
      this.notice = this.tt('ls.sent', `${this.picked.length}`, peer.alias);
      this.picked = [];
      this.pickedNames = [];
    } catch (e) {
      this.error = this.tt('ls.sendFailed') + '：' + errText(e);
    }
  }

  @Builder
  peerRow(p: LocalSendPeer) {
    Row({ space: 10 }) {
      Text('🖥').fontSize(22)
      Column({ space: 2 }) {
        Text(p.alias).fontSize(15).fontColor(this.th().onSurface).width('100%')
        Text(`${p.ip}:${p.port} · ${p.deviceType}`).fontSize(12).fontColor(this.th().onSurfaceVariant).width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button(this.tt('common.send'))
        .fontSize(12)
        .height(32)
        .backgroundColor(this.picked.length === 0 ? this.th().searchFieldBg : this.th().primary)
        .fontColor(this.picked.length === 0 ? this.th().outline : Color.White)
        .enabled(this.picked.length > 0)
        .onClick(() => this.sendTo(p))
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  picker() {
    Column() {
      Row({ space: 8 }) {
        Button('‹')
          .fontSize(17)
          .width(34)
          .height(34)
          .backgroundColor(this.th().searchFieldBg)
          .fontColor(this.th().onSurface)
          .onClick(() => {
            if (this.crumbs.length > 1) {
              this.crumbs = this.crumbs.slice(0, this.crumbs.length - 1);
              this.loadDir();
            }
          })
        Text(this.tt('ls.pickerTitle')).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.th().onSurface).layoutWeight(1)
        Text(this.tt('ls.done')).fontSize(13).fontColor(this.th().primary).onClick(() => this.browsing = false)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })

      List() {
        ForEach(this.entries, (e: Entry) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(e.kind === EntryKind.Directory ? '📁' : (this.picked.indexOf(e.id) >= 0 ? '☑' : '📄'))
                .fontSize(17)
              Text(e.name).fontSize(14).fontColor(this.th().onSurface).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (e.kind !== EntryKind.Directory) {
                Text(formatBytes(Number(e.size))).fontSize(11).fontColor(this.th().onSurfaceVariant)
              }
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .onClick(() => this.addPicked(e))
          }
        }, (e: Entry) => e.id)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.th().surfaceCard)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text(this.tt('ls.title')).fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.th().onSurface).layoutWeight(1)
            Button(this.running ? this.tt('common.stop') : this.tt('common.start'))
              .fontSize(13)
              .height(36)
              .backgroundColor(this.running ? this.th().errorContainer : this.th().primary)
              .fontColor(this.running ? this.th().error : this.th().onPrimary)
              .onClick(() => {
                if (this.running) {
                  this.stop();
                } else {
                  this.start();
                }
              })
          }
          .width('100%')

          if (this.error.length > 0) {
            Text(this.error).fontSize(13).fontColor(this.th().error).width('100%')
          }
          if (this.notice.length > 0) {
            Text(this.notice).fontSize(13).fontColor(this.th().success).width('100%')
          }

          Column({ space: 6 }) {
            Text(this.tt('ls.deviceName')).fontSize(13).fontColor(this.th().onSurfaceVariant).width('100%')
            TextInput({ text: this.alias, placeholder: this.tt('ls.aliasPh') })
              .height(40)
              .onChange((v: string) => this.alias = v)
            if (this.running) {
              Text(this.info).fontSize(12).fontColor(this.th().onSurfaceVariant).width('100%')
              Text(this.tt('ls.hint'))
                .fontSize(12)
                .fontColor(this.th().outline)
                .width('100%')
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.th().searchFieldBg)
          .borderRadius(12)

          // ---- 一键组网卡：仅在雷达/注册都还没找到对方时出现（已同网不打扰） ----
          if (this.allPeers().length === 0) {
            Column({ space: 8 }) {
            Text(this.tt('ls.pairTitle'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.th().onSurface)
              .width('100%')
            Text(this.tt('ls.pairHint'))
              .fontSize(11)
              .fontColor(this.th().onSurfaceVariant)
              .width('100%')
            Row({ space: 8 }) {
              Button(this.tt('ls.pairHost'))
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor(this.pairing === 'host' ? this.th().primary : this.th().searchFieldBg)
                .fontColor(this.pairing === 'host' ? this.th().onPrimary : this.th().onSurface)
                .onClick(() => {
                  this.pairing = this.pairing === 'host' ? '' : 'host';
                  if (this.pairing === 'host') {
                    this.loadSelfIps();
                  }
                })
              Button(this.tt('ls.pairClient'))
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor(this.pairing === 'client' ? this.th().primary : this.th().searchFieldBg)
                .fontColor(this.pairing === 'client' ? this.th().onPrimary : this.th().onSurface)
                .onClick(() => {
                  this.pairing = this.pairing === 'client' ? '' : 'client';
                })
            }
            .width('100%')

            if (this.pairing === 'host') {
              if (!this.running) {
                Text(this.tt('ls.needStart')).fontSize(11).fontColor(this.th().onSurfaceVariant).width('100%')
              } else if (this.selfIps.length === 0) {
                Text(this.tt('ls.noSelfIp')).fontSize(11).fontColor(this.th().onSurfaceVariant).width('100%')
              } else {
                Scroll() {
                  Row({ space: 6 }) {
                    ForEach(this.selfIps, (ip: string) => {
                      Text(ip)
                        .fontSize(11)
                        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                        .borderRadius(RADIUS_S)
                        .backgroundColor(ip === this.selIp ? this.th().primary : this.th().surfaceCard)
                        .fontColor(ip === this.selIp ? this.th().onPrimary : this.th().onSurface)
                        .onClick(() => {
                          this.selIp = ip;
                          this.genPairQr();
                        })
                    }, (ip: string) => ip)
                  }
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .width('100%')
                if (this.pairQr !== null) {
                  Image(this.pairQr)
                    .width(220)
                    .height(220)
                    .borderRadius(RADIUS_S)
                    .margin({ top: SPACE2 })
                }
                Text(this.pairLinkOf())
                  .fontSize(10)
                  .fontColor(this.th().onSurfaceVariant)
                  .width('100%')
              }
              Text(this.tt('ls.hostHint')).fontSize(11).fontColor(this.th().onSurfaceVariant).width('100%')
              SfSecondaryButton({
                label: this.tt('ls.openHotspot'),
                onAction: (): void => this.openHotspotSettings()
              })
            } else if (this.pairing === 'client') {
              SfPrimaryButton({
                label: this.tt('ls.scan'),
                onAction: (): void => this.startScan()
              })
              Text(this.tt('ls.scanHint')).fontSize(11).fontColor(this.th().outline).width('100%')
              Divider().color(this.th().divider)
              Text(this.tt('ls.manualTitle')).fontSize(11).fontColor(this.th().onSurfaceVariant).width('100%')
              Row({ space: 8 }) {
                TextInput({ text: this.ipInput, placeholder: '192.168.1.10' })
                  .height(40)
                  .layoutWeight(1)
                  .backgroundColor(this.th().surfaceCard)
                  .onChange((v: string) => this.ipInput = v)
                TextInput({ text: this.portInput, placeholder: '53317' })
                  .height(40)
                  .width(100)
                  .backgroundColor(this.th().surfaceCard)
                  .onChange((v: string) => this.portInput = v)
              }
              .width('100%')
              SfSecondaryButton({
                label: this.tt('ls.register'),
                onAction: (): void => {
                  const ip: string = this.ipInput.trim();
                  if (ip.length === 0) {
                    return;
                  }
                  this.registerPeer(ip, Number(this.portInput) || 53317, undefined);
                }
              })
              if (this.manualError.length > 0) {
                Text(this.manualError).fontSize(11).fontColor(this.th().error).width('100%')
              }
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.th().searchFieldBg)
          .borderRadius(12)
          }

          // 「无传输活动自动关闭」设置：始终可见（不随组网卡让位）
          Column({ space: 4 }) {
            Row() {
              Text(this.tt('ls.idleTitle')).fontSize(12).fontColor(this.th().onSurface).layoutWeight(1)
              Text(this.idleLabel())
                .fontSize(12)
                .fontColor(this.th().primary)
                .onClick(() => {
                  this.idlePicker = true;
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.th().searchFieldBg)
          .borderRadius(12)

          Column({ space: 8 }) {
            Row() {
              Text(this.tt('ls.picked', `${this.picked.length}`)).fontSize(14).fontColor(this.th().onSurface).layoutWeight(1)
              Text(this.tt('ls.pickFiles')).fontSize(13).fontColor(this.th().primary).onClick(() => {
                this.browsing = true;
                this.loadDir();
              })
            }
            .width('100%')
            if (this.pickedNames.length > 0) {
              Text(this.pickedNames.join('、'))
                .fontSize(12)
                .fontColor(this.th().onSurfaceVariant)
                .maxLines(2)
                .width('100%')
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.th().searchFieldBg)
          .borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text(this.tt('ls.nearby')).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.th().onSurface).width('100%')
            if (!this.running) {
              Text(this.tt('ls.startFirst')).fontSize(13).fontColor(this.th().onSurfaceVariant).width('100%')
            } else if (this.allPeers().length === 0) {
              Text(this.tt('ls.searching')).fontSize(13).fontColor(this.th().onSurfaceVariant).width('100%')
            } else {
              ForEach(this.allPeers(), (p: LocalSendPeer) => {
                this.peerRow(p)
              }, (p: LocalSendPeer) => `${p.ip}:${p.port}`)
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(this.th().searchFieldBg)
          .borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          // 已接收清单：每条记录独立圆角卡片，多条相邻贴合，接触处以分隔
          // 线在视觉上分开（与传输中心的记录风格一致），常驻展示"收到了什么、
          // 多大、什么时候"，点行直达所在目录
          if (this.received.length > 0) {
            Column({ space: 0 }) {
              Text(this.tt('ls.recvTitle'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.th().onSurface)
                .width('100%')
                .padding({ bottom: SPACE2 })
              ForEach(this.received, (r: RecvItem, index: number) => {
                Column() {
                  Row({ space: 10 }) {
                    Text('⇣')
                      .fontSize(16)
                      .fontColor(this.th().primary)
                    Column({ space: 2 }) {
                      Text(r.name)
                        .fontSize(14)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.th().onSurface)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(`${formatBytes(r.size)} · ${formatClock(r.at)}`)
                        .fontSize(11)
                        .fontColor(this.th().onSurfaceVariant)
                        .width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    Text('›')
                      .fontSize(18)
                      .fontColor(this.th().outline)
                  }
                  .width('100%')
                  .padding(SPACE4)
                  .backgroundColor(this.th().surfaceCard)
                  .borderRadius(RADIUS_M)
                  .onClick(() => {
                    const rootId: string = this.core !== null ? this.core.rootId() : '';
                    AppStorage.setOrCreate('sfOpenId', rootId);
                    AppStorage.setOrCreate('sfTab', 1);
                    router.back();
                  })
                  if (index !== this.received.length - 1) {
                    Divider().color(this.th().divider)
                  }
                }
              }, (r: RecvItem) => `${r.at}-${r.name}`)
            }
            .width('100%')
          }
        }
        .padding({ left: SCREEN_MARGIN, right: SCREEN_MARGIN, top: 8, bottom: 24 })
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      // 页面底 = 主页的 surface；卡片（surfaceCard 白）从此有层次。
      .backgroundColor(this.th().surface)

      if (this.browsing) {
        this.picker()
      }

      if (this.idlePicker) {
        this.idleOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 「无传输活动自动关闭」时长选择弹层。 */
  @Builder
  idleOverlay() {
    Column() {
      Blank().layoutWeight(1).onClick(() => this.idlePicker = false)
      Column() {
        Text(this.tt('ls.idleTitle'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.th().onSurface)
          .width('100%')
          .padding({ top: SPACE3, bottom: SPACE2 })
        Divider().color(this.th().divider)
        ForEach([300, 600, 1800, 3600, 0], (secs: number) => {
          Text(this.idleLabelOf(secs))
            .fontSize(14)
            .fontColor(secs === this.idleSecs ? this.th().primary : this.th().onSurface)
            .width('100%')
            .padding({ top: SPACE3, bottom: SPACE3 })
            .onClick(() => this.pickIdle(secs))
        }, (secs: number) => `${secs}`)
        Divider().color(this.th().divider)
        Button(this.tt('common.cancel'))
          .fontSize(13)
          .height(38)
          .width('100%')
          .backgroundColor(Color.Transparent)
          .fontColor(this.th().onSurfaceVariant)
          .margin({ top: SPACE2, bottom: SPACE2 })
          .onClick(() => this.idlePicker = false)
      }
      .width('100%')
      .padding({ left: SPACE4, right: SPACE4 })
      .backgroundColor(this.th().surfaceCard)
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
  }

  private idleLabelOf(secs: number): string {
    if (secs <= 0) {
      return this.tt('ls.idleNever');
    }
    return `${Math.round(secs / 60)} ${this.tt('ls.idleMin')}`;
  }
}
