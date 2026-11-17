import { http, socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import BuildProfile from 'BuildProfile';
import { GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, DROPBOX_CLIENT_ID, ONEDRIVE_CLIENT_ID, PAN115_CLIENT_ID } from './CloudSecrets';

/**
 * 网络存储（云盘）OAuth 授权（对齐 Android CloudContracts/CloudAuthManager）。
 *
 * 两种回调方式：
 *  - 深链 `superfiles://oauth/callback`（Dropbox 等）
 *  - loopback `http://localhost:8765/`（Google：Web 客户端不接受自定义 scheme，
 *    app 内起 TCP 服务收回调）
 *
 * 凭据在 CloudSecrets.ets（已 gitignore，不进仓库）。
 */

export const OAUTH_REDIRECT_URI: string = 'superfiles://oauth/callback';
export const OAUTH_LOOPBACK_URI: string = 'http://localhost:8765/';
/** Dropbox 后台注册的是 127.0.0.1，必须精确匹配 */
export const OAUTH_LOOPBACK_URI_127: string = 'http://127.0.0.1:8765/';

export interface CloudProviderDef {
  id: string;
  name: string;
  /** OAuth 客户端凭据；空串 = 未在开放平台注册。 */
  clientId: string;
  clientSecret: string;
  authorizeUrl: string;
  tokenUrl: string;
  scopes: string;
  /** 追加在授权 URL 后的额外参数（如 Google 的 access_type=offline）。 */
  extraAuthParams: string;
  /** 回调地址：loopback 或深链。设备码模式为空。 */
  redirectUri: string;
  /** 'redirect'（默认）或 'device'（115 扫码）。 */
  authMode?: string;
  /** 开发中（OAuth 流程未完成）：仅 debug 构建可见，release 不进选择列表。 */
  devOnly?: boolean;
  /** 设备码模式：申请设备码。 */
  deviceCodeUrl?: string;
  /** 设备码模式：轮询二维码状态。 */
  qrStatusUrl?: string;
}

export const CLOUD_PROVIDER_DROPBOX: string = 'dropbox';
export const CLOUD_PROVIDER_GDRIVE: string = 'gdrive';
export const CLOUD_PROVIDER_ONEDRIVE: string = 'onedrive';
export const CLOUD_PROVIDER_PAN115: string = 'pan115';

export const CLOUD_PROVIDERS: CloudProviderDef[] = [
  {
    id: CLOUD_PROVIDER_GDRIVE,
    name: 'Google Drive',
    clientId: GOOGLE_CLIENT_ID,
    clientSecret: GOOGLE_CLIENT_SECRET,
    authorizeUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    scopes: 'https://www.googleapis.com/auth/drive',
    extraAuthParams: '&access_type=offline&prompt=consent',
    // Google Web 客户端只接受 loopback
    redirectUri: OAUTH_LOOPBACK_URI,
  },
  {
    id: CLOUD_PROVIDER_DROPBOX,
    name: 'Dropbox',
    clientId: DROPBOX_CLIENT_ID,
    clientSecret: '',
    authorizeUrl: 'https://www.dropbox.com/oauth2/authorize',
    tokenUrl: 'https://api.dropboxapi.com/oauth2/token',
    scopes: 'files.metadata.read files.metadata.write files.content.read files.content.write',
    // offline：否则只给 4 小时 access_token，没有 refresh_token
    extraAuthParams: '&token_access_type=offline',
    // Dropbox 后台注册的是 127.0.0.1（不是 localhost）
    redirectUri: OAUTH_LOOPBACK_URI_127,
  },
  {
    id: CLOUD_PROVIDER_ONEDRIVE,
    name: 'OneDrive',
    clientId: ONEDRIVE_CLIENT_ID,
    // Microsoft public client: PKCE, no secret (Entra 里要开 Allow public client flows)
    clientSecret: '',
    authorizeUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
    tokenUrl: 'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    scopes: 'offline_access Files.ReadWrite.All',
    extraAuthParams: '&response_mode=query',
    redirectUri: OAUTH_LOOPBACK_URI,
    // OAuth 接入中：release 不出现在选择列表
    devOnly: true,
  },
  {
    id: CLOUD_PROVIDER_PAN115,
    name: '115',
    clientId: PAN115_CLIENT_ID,
    clientSecret: '',
    authorizeUrl: '',
    tokenUrl: 'https://passportapi.115.com/open/deviceCodeToToken',
    scopes: '',
    extraAuthParams: '',
    redirectUri: '',
    authMode: 'device',
    deviceCodeUrl: 'https://passportapi.115.com/open/authDeviceCode',
    qrStatusUrl: 'https://qrcodeapi.115.com/get/status/',
    // 设备码接入中：release 不出现在选择列表
    devOnly: true,
  },
];

export function cloudProviderById(id: string): CloudProviderDef | null {
  for (const p of CloudProviders()) {
    if (p.id === id) {
      return p;
    }
  }
  return null;
}

/**
 * 选择列表门控（两条规则叠加）：
 *  - devOnly（OAuth 接入中）：仅 debug 构建出现，release 不可见不可达；
 *  - SHOW_UNCONFIGURED_CLOUD=false（release）：没填 clientId 的也不出现。
 */
export function visibleCloudProviders(): CloudProviderDef[] {
  return CLOUD_PROVIDERS.filter((p: CloudProviderDef) =>
    (!p.devOnly || BuildProfile.DEBUG) &&
    (BuildProfile.SHOW_UNCONFIGURED_CLOUD || p.clientId.length > 0));
}

export function CloudProviders(): CloudProviderDef[] {
  return CLOUD_PROVIDERS;
}

export function buildAuthorizeUrl(
  p: CloudProviderDef,
  challenge?: string,
  state?: string,
): string {
  let url: string = `${p.authorizeUrl}?client_id=${encodeURIComponent(p.clientId)}` +
    `&redirect_uri=${encodeURIComponent(p.redirectUri)}&response_type=code`;
  if (p.scopes.length > 0) {
    url += `&scope=${encodeURIComponent(p.scopes)}`;
  }
  if (state !== undefined) {
    url += `&state=${encodeURIComponent(state)}`;
  }
  if (challenge !== undefined) {
    url += `&code_challenge=${encodeURIComponent(challenge)}&code_challenge_method=S256`;
  }
  url += p.extraAuthParams;
  return url;
}

export interface OAuthCallback {
  providerId: string;
  code: string;
  error: string;
  state: string;
}

/** 解析 superfiles://oauth/callback?code=… / ?error=…&provider=… */
export function parseOAuthCallback(uri: string): OAuthCallback | null {
  const q: number = uri.indexOf('?');
  if (q < 0) {
    return null;
  }
  const params: Map<string, string> = parseQuery(uri.substring(q + 1));
  const provider: string = params.get('provider') ?? '';
  const code: string = params.get('code') ?? '';
  const error: string = params.get('error') ?? '';
  const state: string = params.get('state') ?? '';
  if (provider.length === 0) {
    return null;
  }
  return { providerId: provider, code: code, error: error, state: state };
}

export interface TokenSet {
  accessToken: string;
  refreshToken: string;
}

/** 授权码换访问令牌（后台表单 POST，通用 OAuth2 解析）。 */
export async function exchangeCodeForTokens(
  p: CloudProviderDef,
  code: string,
  codeVerifier?: string,
): Promise<TokenSet> {
  let body: string = `grant_type=authorization_code&code=${encodeURIComponent(code)}` +
    `&client_id=${encodeURIComponent(p.clientId)}` +
    `&redirect_uri=${encodeURIComponent(p.redirectUri)}`;
  if (codeVerifier !== undefined && codeVerifier.length > 0) {
    body += `&code_verifier=${encodeURIComponent(codeVerifier)}`;
  }
  if (p.clientSecret.length > 0) {
    body += `&client_secret=${encodeURIComponent(p.clientSecret)}`;
  }
  const req: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await req.request(p.tokenUrl, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/x-www-form-urlencoded' },
      extraData: body,
      connectTimeout: 15000,
      readTimeout: 15000,
    });
    if (resp.responseCode !== 200) {
      throw new Error(`token http ${resp.responseCode}`);
    }
    const text: string = typeof resp.result === 'string' ? resp.result : '';
    const data: object = JSON.parse(text) as object;
    const access: string = (data as Record<string, string>)['access_token'] ?? '';
    const refresh: string = (data as Record<string, string>)['refresh_token'] ?? '';
    if (access.length === 0) {
      throw new Error('token response missing access_token');
    }
    return { accessToken: access, refreshToken: refresh };
  } finally {
    req.destroy();
  }
}

/** 拉起系统浏览器进行 OAuth 授权（深链回调）。 */
export function openAuthorizePage(p: CloudProviderDef, ctx: common.UIAbilityContext): void {
  ctx.openLink(buildAuthorizeUrl(p));
}

/** 深链授权时需要在浏览器往返期间保存的会话。 */
export interface PendingAuth {
  providerId: string;
  verifier: string;
  state: string;
}

export interface BeginAuthResult {
  url: string;
  pending: PendingAuth;
}

/**
 * 深链授权第一步：生成 PKCE + state，返回要打开的 URL 和需要持久化的会话。
 * 浏览器回来后用 pending.verifier 换 token（Dropbox 必须 PKCE，不能带 secret）。
 */
export async function beginAuth(p: CloudProviderDef): Promise<BeginAuthResult> {
  const verifier: string = randomUrlSafe(48);
  const challenge: string = await sha256B64Url(verifier);
  const state: string = randomUrlSafe(16);
  const pending: PendingAuth = { providerId: p.id, verifier: verifier, state: state };
  const result: BeginAuthResult = {
    url: buildAuthorizeUrl(p, challenge, state),
    pending: pending,
  };
  return result;
}

// ---------------------------------------------------------------- loopback

/** 该 provider 是否需要 app 内 loopback 回调（Google）。 */
export function usesLoopback(p: CloudProviderDef): boolean {
  return p.redirectUri.startsWith('http://localhost') ||
    p.redirectUri.startsWith('http://127.0.0.1');
}

/**
 * loopback 授权：PKCE → 起本地服务 → 开浏览器 → 收 code → 换 token。
 * 用户只需在浏览器里点一次「允许」。
 */
export async function authorizeViaLoopback(
  p: CloudProviderDef,
  ctx: common.UIAbilityContext,
): Promise<TokenSet> {
  const verifier: string = randomUrlSafe(48);
  const challenge: string = await sha256B64Url(verifier);
  const state: string = randomUrlSafe(16);
  const url: string = buildAuthorizeUrl(p, challenge, state);

  // 先把监听器 bind 好、把 waiter 挂上，再开浏览器；
  // 否则浏览器的预连接可能在 listen 完成前就打过来。
  await ensureLoopbackServer(portOf(p.redirectUri));
  const codePromise = new Promise<string>((resolve, reject) => {
    loopbackWaiter = { resolve: resolve, reject: reject, state: state };
  });
  ctx.openLink(url);
  const code: string = await codePromise;
  return exchangeCodeForTokens(p, code, verifier);
}

// 单例监听：整个进程只 bind 一次。
// 每次授权都重新 listen，会在上一次连接留下的 TIME_WAIT 期间 bind 失败，
// 而 HarmonyOS 的 TCPSocketServer 在 bind 失败时会悄悄改用随机端口，
// 浏览器就再也连不上 8765 了。
interface LoopbackWaiter {
  resolve: (code: string) => void;
  reject: (err: Error) => void;
  state: string;
}

let loopbackServer: socket.TCPSocketServer | null = null;
let loopbackPort: number = 0;
let loopbackStarting: Promise<void> | null = null;
let loopbackWaiter: LoopbackWaiter | null = null;

function ensureLoopbackServer(port: number): Promise<void> {
  if (loopbackServer !== null) {
    return Promise.resolve();
  }
  if (loopbackStarting !== null && loopbackPort === port) {
    return loopbackStarting;
  }
  loopbackPort = port;
  loopbackStarting = new Promise<void>((resolve, reject) => {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (client: socket.TCPSocketConnection) => {
      client.on('message', (info: socket.SocketMessageInfo) => {
        const text: string = new util.TextDecoder('utf-8')
          .decodeToString(new Uint8Array(info.message));
        const match: RegExpMatchArray | null = text.match(/^GET\s+(\S+)\s+HTTP/);
        const target: string = match === null ? '' : match[1];
        const qi: number = target.indexOf('?');
        const params: Map<string, string> =
          parseQuery(qi >= 0 ? target.substring(qi + 1) : '');

        const code: string | undefined = params.get('code');
        const error: string | undefined = params.get('error');
        const state: string = params.get('state') ?? '';
        const ok: boolean = code !== undefined && code.length > 0;

        // 浏览器的预连接 / favicon 没有 code：回 204 就好，别关闭监听。
        const body: string = ok
          ? '<html><body>Authorization complete. You can close this page.</body></html>'
          : '';
        const status: string = ok ? '200 OK' : '204 No Content';
        const resp: string = `HTTP/1.1 ${status}\r\nContent-Type: text/html\r\n` +
          `Content-Length: ${body.length}\r\nConnection: close\r\n\r\n${body}`;
        client.send({ data: resp }).then(() => client.close()).catch(() => {
        });

        if (!ok && error === undefined) {
          return;
        }
        const waiter: LoopbackWaiter | null = loopbackWaiter;
        if (waiter === null) {
          return;
        }
        loopbackWaiter = null;
        if (error !== undefined) {
          waiter.reject(new Error(error));
          return;
        }
        if (waiter.state.length > 0 && state !== waiter.state) {
          waiter.reject(new Error('OAuth state mismatch'));
          return;
        }
        waiter.resolve(code as string);
      });
    });

    let attempt: number = 0;
    const tryListen = () => {
      server.listen({ address: '127.0.0.1', port: port, family: 1 })
        .then(() => {
          loopbackServer = server;
          resolve();
        })
        .catch((e: Error) => {
          attempt += 1;
          if (attempt >= 40) {
            loopbackStarting = null;
            reject(e);
            return;
          }
          setTimeout(tryListen, 1500);
        });
    };
    tryListen();
  });
  return loopbackStarting;
}


// ---------------------------------------------------------------- 设备码（115）

export interface DeviceCodeData {
  uid: string;
  time: number;
  qrcode: string;
  sign: string;
}

export interface DeviceCodeResp {
  state?: boolean;
  code?: number;
  message?: string;
  data?: DeviceCodeData;
}

export interface QrStatusData {
  status?: number;
  msg?: string;
}

export interface QrStatusResp {
  state?: number;
  code?: number;
  message?: string;
  data?: QrStatusData;
}

export interface TokenData {
  access_token?: string;
  refresh_token?: string;
  expires_in?: number;
}

export interface TokenResp {
  state?: boolean;
  code?: number;
  message?: string;
  data?: TokenData;
}

/**
 * 115 扫码授权：申请设备码 → onQr 回调把二维码内容交给 UI →
 * 长轮询状态 → 确认后换 token。全程不需要 redirect_uri / AppSecret。
 */
export async function authorizeViaDeviceCode(
  p: CloudProviderDef,
  onQr: (qrcode: string) => void,
): Promise<TokenSet> {
  const verifier: string = randomUrlSafe(48);
  const challenge: string = await sha256B64Url(verifier);

  const body: string = `client_id=${encodeURIComponent(p.clientId)}` +
    `&code_challenge=${encodeURIComponent(challenge)}` +
    `&code_challenge_method=sha256`;
  const text: string = await postFormText(p.deviceCodeUrl ?? '', body);
  const resp: DeviceCodeResp = JSON.parse(text) as DeviceCodeResp;
  const data: DeviceCodeData | undefined = resp.data;
  if (data === undefined) {
    throw new Error(resp.message ?? '115 申请设备码失败');
  }

  onQr(data.qrcode);
  await pollQrStatus(p.qrStatusUrl ?? '', data.uid, `${data.time}`, data.sign);

  const tokenText: string = await postFormText(
    p.tokenUrl,
    `uid=${encodeURIComponent(data.uid)}&code_verifier=${encodeURIComponent(verifier)}`,
  );
  const tokenResp: TokenResp = JSON.parse(tokenText) as TokenResp;
  const tokens: TokenData | undefined = tokenResp.data;
  if (tokens === undefined || tokens.access_token === undefined) {
    throw new Error(tokenResp.message ?? '115 换取 token 失败');
  }
  return { accessToken: tokens.access_token, refreshToken: tokens.refresh_token ?? '' };
}

async function pollQrStatus(
  base: string,
  uid: string,
  time: string,
  sign: string,
): Promise<void> {
  const url: string = `${base}?uid=${encodeURIComponent(uid)}` +
    `&time=${encodeURIComponent(time)}&sign=${encodeURIComponent(sign)}`;
  const deadline: number = Date.now() + 5 * 60 * 1000;
  while (Date.now() < deadline) {
    const text: string = await getText(url);
    const resp: QrStatusResp = JSON.parse(text) as QrStatusResp;
    const status: number = resp.data === undefined ? 0 : (resp.data.status ?? 0);
    if (status === 2) {
      return;
    }
    if (resp.state === 0) {
      throw new Error(resp.message ?? '115 二维码已失效');
    }
    await sleep(2000);
  }
  throw new Error('等待 115 授权超时');
}

async function postFormText(url: string, body: string): Promise<string> {
  const req = http.createHttp();
  try {
    const resp = await req.request(url, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/x-www-form-urlencoded' },
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 20000,
    });
    const text: string = resp.result as string;
    if (resp.responseCode !== 200) {
      throw new Error(`115 HTTP ${resp.responseCode}: ${text}`);
    }
    return text;
  } finally {
    req.destroy();
  }
}

async function getText(url: string): Promise<string> {
  const req = http.createHttp();
  try {
    const resp = await req.request(url, {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 30000,
    });
    if (resp.responseCode !== 200) {
      throw new Error(`115 HTTP ${resp.responseCode}`);
    }
    return resp.result as string;
  } finally {
    req.destroy();
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });
}

// ---------------------------------------------------------------- 工具

function randomUrlSafe(bytes: number): string {
  return toBase64Url(cryptoFramework.createRandom().generateRandomSync(bytes).data);
}

async function sha256B64Url(text: string): Promise<string> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: new util.TextEncoder().encodeInto(text) });
  const digest = await md.digest();
  return toBase64Url(digest.data);
}

function toBase64Url(data: Uint8Array): string {
  const b64: string = new util.Base64Helper().encodeToStringSync(data);
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function parseQuery(query: string): Map<string, string> {
  const out = new Map<string, string>();
  if (query.length === 0) {
    return out;
  }
  for (const kv of query.split('&')) {
    const eq: number = kv.indexOf('=');
    if (eq > 0) {
      try {
        out.set(kv.substring(0, eq), decodeURIComponent(kv.substring(eq + 1)));
      } catch (e) {
        out.set(kv.substring(0, eq), kv.substring(eq + 1));
      }
    }
  }
  return out;
}

function portOf(uri: string): number {
  const scheme: number = uri.indexOf('://');
  const rest: string = scheme >= 0 ? uri.substring(scheme + 3) : uri;
  const slash: number = rest.indexOf('/');
  const hostPort: string = slash >= 0 ? rest.substring(0, slash) : rest;
  const colon: number = hostPort.lastIndexOf(':');
  if (colon < 0) {
    return 80;
  }
  const parsed: number = Number(hostPort.substring(colon + 1));
  return Number.isNaN(parsed) ? 80 : parsed;
}
