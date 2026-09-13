/** dsh /api RPC 客户端：信封构造、Basic Auth、Cookie 自动换取与续期、错误映射。 */
import http from '@ohos.net.http';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import web_webview from '@ohos.web.webview';
import { BusinessError } from '@ohos.base';
import { DshConfigStore } from './DshConfigStore';
import { SECURE_ALIAS_COOKIE, SecureStore } from './SecureStore';

/** dsh 网关业务失败（result.ok=false）或认证链路异常。 */
export class DshApiClientError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super('[' + code + '] ' + message);
    this.code = code;
  }
}

/** Cookie 有效期 30 天，预留 1 小时余量提前续期。 */
const DAY_MS: number = 24 * 60 * 60 * 1000;
const COOKIE_LIFETIME_MS: number = 30 * DAY_MS;
const COOKIE_RENEW_MARGIN_MS: number = 60 * 60 * 1000;
const CONNECT_TIMEOUT_MS: number = 10000;
const READ_TIMEOUT_MS: number = 30000;

/** WebSocket 握手所需信息（服务器 origin + 鉴权头）。 */
export interface DshWsConnectInfo {
  /** 服务器 origin，如 'https://dsh.example.com'。 */
  serverUrl: string;
  /** WS 握手请求头（Authorization/Cookie/Origin）。 */
  headers: Record<string, string>;
}

/** 响应信封（宽松解析：字段全部可缺省，逐层判空）。 */
interface WireEnvelope {
  type?: string;
  result?: WireResult;
}

/** 信封 result 字段。 */
interface WireResult {
  ok?: boolean;
  value?: object;
  error?: WireErrorBody;
}

/** 信封错误体。 */
interface WireErrorBody {
  code?: string;
  message?: string;
}

/**
 * DshApiClient：会话 Cookie 进程内缓存，过期或 401 时用保存的令牌 URL 重换；
 * 所有 /api 调用统一走 call()，返回 result.value（object，由调用方按 wire 形状再转）。
 */
export class DshApiClient {
  private static cookieNameValue: string = '';
  private static cookieExpireAt: number = 0;

  /** 主动清空 Cookie（设置页更换令牌后调用）；持久层异步删除。 */
  static clearCookie(): void {
    DshApiClient.cookieNameValue = '';
    DshApiClient.cookieExpireAt = 0;
    SecureStore.deleteSecret(SECURE_ALIAS_COOKIE);
  }

  /** 登录态剩余天数（签发 + 30 天）；未知签发时间返回 -1。 */
  static cookieDaysLeft(mintedAt: number): number {
    if (mintedAt <= 0) {
      return -1;
    }
    const elapsed: number = Date.now() - mintedAt;
    return COOKIE_LIFETIME_MS / DAY_MS - Math.floor(elapsed / DAY_MS);
  }

  /** 时间戳 + 随机数拼 32 位十六进制 rpcId（仅需唯一性，无需严格 UUID）。 */
  private static rpcId(): string {
    let id: string = Date.now().toString(16);
    for (let i: number = 0; i < 20; i++) {
      id += Math.floor(Math.random() * 16).toString(16);
    }
    return id;
  }

  /** Basic Auth 头：base64(user:pass)，UTF-8 编码。 */
  private static basicHeader(username: string, password: string): string {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const raw: string = username + ':' + password;
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(encoder.encodeInto(raw));
  }

  /**
   * GET 令牌 URL 换取 dsh 会话 Cookie。跟随重定向（http 模块对禁用重定向会直接抛
   * 2300047 而非返回 303 响应），随后依次从响应 set-cookie 头、resp.cookies、
   * WebView Cookie 罐三个来源提取 dsh-auth-* Cookie。
   */
  private static async mintCookie(ctx: common.Context, serverUrl: string, username: string, password: string, tokenUrl: string): Promise<void> {
    if (tokenUrl === '') {
      throw new DshApiClientError('auth/no-token', '尚未保存 dsh 令牌，请到设置页粘贴令牌 URL');
    }
    let cookie: string = '';
    let httpCode: number = -1;
    let netErr: string = '';
    const req: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Authorization': DshApiClient.basicHeader(username, password),
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        usingCache: false,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
      };
      const resp: http.HttpResponse = await req.request(tokenUrl, options);
      httpCode = resp.responseCode;
      // 来源1：最终响应的 set-cookie 头（字符串或数组形态）
      const headers: Record<string, Object> = resp.header as Record<string, Object>;
      let raw: Object | undefined = headers['set-cookie'];
      if (raw === undefined) {
        raw = headers['Set-Cookie'];
      }
      let setCookie: string = '';
      if (typeof raw === 'string') {
        setCookie = raw;
      } else if (Array.isArray(raw)) {
        const arr: Object[] = raw as Object[];
        for (let i: number = 0; i < arr.length; i++) {
          if (typeof arr[i] === 'string') {
            setCookie = setCookie === '' ? arr[i] as string : setCookie + '\n' + (arr[i] as string);
          }
        }
      }
      // 来源2：http 模块代管的 cookies 字段（可能汇聚重定向全程）
      if (resp.cookies.indexOf('=') >= 0) {
        setCookie = setCookie === '' ? resp.cookies : setCookie + '\n' + resp.cookies;
      }
      cookie = DshApiClient.pickDshAuthCookie(setCookie);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      netErr = e.message;
    } finally {
      req.destroy();
    }
    // 来源3：WebView Cookie 罐（此前打开过完整版控制台则已有登录态）
    if (cookie === '') {
      cookie = DshApiClient.cookieFromWebView(tokenUrl);
    }
    // 来源4：服务器自动令牌端点兜底——拉最新令牌再换一次，成功则持久化
    if (cookie === '') {
      const autoUrl: string = await DshApiClient.fetchAutoTokenUrl(serverUrl, username, password);
      if (autoUrl !== '') {
        const req2: http.HttpRequest = http.createHttp();
        try {
          const h2: Record<string, string> = {
            'Authorization': DshApiClient.basicHeader(username, password),
          };
          const o2: http.HttpRequestOptions = {
            method: http.RequestMethod.GET,
            header: h2,
            usingCache: false,
            connectTimeout: CONNECT_TIMEOUT_MS,
            readTimeout: 15000,
            expectDataType: http.HttpDataType.STRING,
          };
          const r2: http.HttpResponse = await req2.request(autoUrl, o2);
          httpCode = r2.responseCode;
          cookie = DshApiClient.extractCookie(r2);
        } catch (err) {
          const e2: BusinessError = err as BusinessError;
          netErr = e2.message;
        } finally {
          req2.destroy();
        }
        if (cookie !== '') {
          await DshConfigStore.saveTokenUrl(autoUrl);
        }
      }
    }
    if (cookie === '') {
      const why: string = netErr !== ''
        ? '网络异常：' + netErr
        : '令牌交换未取得 Cookie（HTTP ' + httpCode + '），令牌可能已失效，请到设置页重新粘贴令牌 URL';
      throw new DshApiClientError('auth/no-cookie', why);
    }
    DshApiClient.cookieNameValue = cookie;
    DshApiClient.cookieExpireAt = Date.now() + COOKIE_LIFETIME_MS - COOKIE_RENEW_MARGIN_MS;
    // 持久化会话 Cookie：APP 重启后直接复用（签名密钥在服务器持久化，dsh 重启不影响其有效性）
    await SecureStore.saveSecret(SECURE_ALIAS_COOKIE, cookie);
    // 记录签发时间：登录态到期提醒依据
    await DshConfigStore.setCookieMintedAt(ctx, Date.now());
  }

  /** 从一段或整份 set-cookie 文本中挑出 dsh-auth-* 的 "名字=值"。 */
  private static pickDshAuthCookie(text: string): string {
    if (text === '') {
      return '';
    }
    const parts: string[] = text.split('\n');
    for (let i: number = 0; i < parts.length; i++) {
      const first: string = parts[i].split(';')[0].trim();
      if (first.indexOf('dsh-auth-') === 0 && first.indexOf('=') > 0) {
        return first;
      }
    }
    return '';
  }

  /** 从 WebView Cookie 罐按域名提取 dsh-auth Cookie（无则返回空串）。 */
  private static cookieFromWebView(tokenUrl: string): string {
    try {
      const origin: string = DshApiClient.originOf(tokenUrl);
      if (origin === '') {
        return '';
      }
      const jar: string = web_webview.WebCookieManager.fetchCookieSync(origin + '/');
      return DshApiClient.pickDshAuthCookie(jar.replace(/; /g, '\n'));
    } catch (err) {
      return '';
    }
  }

  /** 从 URL 提取协议+域名+端口（无路径），失败返回空串。 */
  private static originOf(url: string): string {
    const schemeAt: number = url.indexOf('://');
    if (schemeAt < 0) {
      return '';
    }
    const rest: string = url.substring(schemeAt + 3);
    const slashAt: number = rest.indexOf('/');
    const authority: string = slashAt < 0 ? rest : rest.substring(0, slashAt);
    if (authority === '') {
      return '';
    }
    return url.substring(0, schemeAt + 3) + authority;
  }

  /** 从服务器自动令牌端点拉取最新令牌 URL（Basic 保护）；失败返回空串。 */
  static async fetchAutoTokenUrl(serverUrl: string, username: string, password: string): Promise<string> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Authorization': DshApiClient.basicHeader(username, password),
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        usingCache: false,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING,
      };
      const resp: http.HttpResponse = await req.request(serverUrl + '/.pocketdsh/token', options);
      if (resp.responseCode === 200 && typeof resp.result === 'string') {
        const body: string = (resp.result as string).trim();
        if (body.indexOf('http') === 0 && body.indexOf('token=') >= 0) {
          return body;
        }
      }
      return '';
    } catch (err) {
      return '';
    } finally {
      req.destroy();
    }
  }

  /** 从响应头/cookies 字段提取 dsh-auth Cookie。 */
  private static extractCookie(resp: http.HttpResponse): string {
    const headers: Record<string, Object> = resp.header as Record<string, Object>;
    let raw: Object | undefined = headers['set-cookie'];
    if (raw === undefined) {
      raw = headers['Set-Cookie'];
    }
    let setCookie: string = '';
    if (typeof raw === 'string') {
      setCookie = raw;
    } else if (Array.isArray(raw)) {
      const arr: Object[] = raw as Object[];
      for (let i: number = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          setCookie = setCookie === '' ? arr[i] as string : setCookie + '\n' + (arr[i] as string);
        }
      }
    }
    if (resp.cookies.indexOf('=') >= 0) {
      setCookie = setCookie === '' ? resp.cookies : setCookie + '\n' + resp.cookies;
    }
    return DshApiClient.pickDshAuthCookie(setCookie);
  }

  /** Cookie 存在且未到期；否则先尝试持久层恢复，再走令牌换票。 */
  private static async ensureCookie(ctx: common.Context, serverUrl: string, username: string, password: string, tokenUrl: string): Promise<void> {
    if (DshApiClient.cookieNameValue !== '' && Date.now() < DshApiClient.cookieExpireAt) {
      return;
    }
    // APP 重启后内存 Cookie 丢失：优先恢复持久化的会话 Cookie（失效则由 401 自愈换新）
    const stored: string = await SecureStore.readSecret(SECURE_ALIAS_COOKIE);
    if (stored.indexOf('dsh-auth-') === 0 && stored.indexOf('=') > 0) {
      DshApiClient.cookieNameValue = stored;
      // 无法得知真实剩余有效期，给 7 天信任窗；过期由 401 自愈兜底
      DshApiClient.cookieExpireAt = Date.now() + 7 * DAY_MS;
      return;
    }
    await DshApiClient.mintCookie(ctx, serverUrl, username, password, tokenUrl);
  }

  /**
   * 供 DshStreamClient 获取 WS 握手信息：确保 Cookie 就绪后，
   * 返回服务器 origin 与 Authorization/Cookie/Origin 头组合。
   */
  static async wsConnectInfo(ctx: common.Context): Promise<DshWsConnectInfo> {
    const data = await DshConfigStore.load(ctx);
    const password: string = await DshConfigStore.getPassword();
    const tokenUrl: string = await DshConfigStore.getTokenUrl();
    await DshApiClient.ensureCookie(ctx, data.serverUrl, data.username, password, tokenUrl);
    const headers: Record<string, string> = {
      'Authorization': DshApiClient.basicHeader(data.username, password),
      // WS 握手头逐字上送：持久层恢复的 Cookie 可能带尾部换行等噪声，
      // 混入头值会打碎 HTTP 报文（nginx 直接 400，WS 表现为非 101）
      'Cookie': DshApiClient.cookieNameValue.replace(/[\r\n\t]/g, ' ').trim(),
      // 注意：绝不能显式传 Origin——netstack 会自动追加自己生成的 Origin，
      // 两个 Origin 被逗号合并成 "x, y"，dsh 的 Origin 校验直接拒绝（非 101）
      // （实测：诊断服务器抓到 "origin": "http://127.0.0.1, https://dsh.goldclew.com"）
    };
    const info: DshWsConnectInfo = {
      serverUrl: data.serverUrl,
      headers: headers,
    };
    return info;
  }

  /**
   * 供 WebView 场景（报告浏览器等）同步 dsh 会话 Cookie：确保原生 Cookie 就绪后
   * 返回 name=value；任何失败返回空串（调用方跳过同步，Basic Auth 仍可兜底）。
   */
  static async ensureWebCookie(ctx: common.Context): Promise<string> {
    try {
      const data = await DshConfigStore.load(ctx);
      const password: string = await DshConfigStore.getPassword();
      const tokenUrl: string = await DshConfigStore.getTokenUrl();
      await DshApiClient.ensureCookie(ctx, data.serverUrl, data.username, password, tokenUrl);
      return DshApiClient.cookieNameValue;
    } catch (err) {
      return '';
    }
  }

  /**
   * 调用 POST /api/<method>。401 自动清 Cookie 重换一次再重试；
   * result.ok=false 抛 DshApiClientError（code 为网关错误码）。
   * @param ctx 上下文（读取配置）
   * @param method 方法名，如 'session/list'（同时也是 URL 路径段）
   * @param requestField 'session/list' 用 '_request'，'session/page' 用 'request'
   * @param requestObj 请求对象；null 表示空对象
   * @returns result.value 原始对象（调用方自行按 wire 形状断言）
   */
  static async call(ctx: common.Context, method: string, requestField: string, requestObj: object | null): Promise<object> {
    const data = await DshConfigStore.load(ctx);
    const password: string = await DshConfigStore.getPassword();
    const tokenUrl: string = await DshConfigStore.getTokenUrl();
    await DshApiClient.ensureCookie(ctx, data.serverUrl, data.username, password, tokenUrl);

    const reqJson: string = requestObj === null ? '{}' : JSON.stringify(requestObj);
    // requestField 为空串表示 args 直接就是请求对象（如 commands/execute）
    let body: string;
    if (requestField === '') {
      body = '{"type":"client-request","rpcId":"' + DshApiClient.rpcId()
        + '","method":"' + method + '","payload":{"args":' + reqJson + '}}';
    } else {
      body = '{"type":"client-request","rpcId":"' + DshApiClient.rpcId()
        + '","method":"' + method + '","payload":{"args":{"' + requestField + '":' + reqJson + '}}}';
    }

    // 外层：头组合变体（0 带 Origin / 1 不带）；内层：401 换 Cookie 后同组合重试一次
    for (let variant: number = 0; variant < 2; variant++) {
      let authRetried: boolean = false;
      let done: boolean = false;
      while (!done) {
        const req: http.HttpRequest = http.createHttp();
        try {
          const header: Record<string, string> = {
            'Content-Type': 'application/json',
            'Authorization': DshApiClient.basicHeader(data.username, password),
            'Cookie': DshApiClient.cookieNameValue,
          };
          if (variant === 0) {
            header['Origin'] = data.serverUrl;
          }
          const options: http.HttpRequestOptions = {
            method: http.RequestMethod.POST,
            header: header,
            extraData: body,
            usingCache: false,
            connectTimeout: CONNECT_TIMEOUT_MS,
            readTimeout: READ_TIMEOUT_MS,
            expectDataType: http.HttpDataType.STRING,
          };
          const resp: http.HttpResponse = await req.request(data.serverUrl + '/api/' + method, options);
          if (resp.responseCode === 401) {
            if (!authRetried) {
              authRetried = true;
              DshApiClient.clearCookie();
              await DshApiClient.mintCookie(ctx, data.serverUrl, data.username, password, tokenUrl);
              continue;
            }
            throw new DshApiClientError('auth/failed', 'dsh 认证失败，请到设置页更新令牌');
          }
          if (resp.responseCode === 400 && variant === 0) {
            // 400 多为头组合不被接受：换无 Origin 组合重试
            done = true;
            break;
          }
          if (resp.responseCode < 200 || resp.responseCode >= 300) {
            // 带上响应正文，便于定位网关/代理拒绝原因
            let bodyText: string = '';
            if (typeof resp.result === 'string') {
              bodyText = resp.result;
            }
            const why: string = bodyText.length > 200 ? bodyText.substring(0, 200) : bodyText;
            throw new DshApiClientError('http/' + resp.responseCode,
              '服务器返回 HTTP ' + resp.responseCode + (why === '' ? '' : '：' + why));
          }
          let envelope: WireEnvelope;
          try {
            envelope = JSON.parse(resp.result as string) as WireEnvelope;
          } catch (err) {
            throw new DshApiClientError('gateway/bad-json', '网关响应不是有效 JSON（可能是网关页或空响应）');
          }
          const result: WireResult | null = envelope.result !== undefined && envelope.result !== null
            ? envelope.result : null;
          if (result === null) {
            throw new DshApiClientError('gateway/bad-response', '响应缺少 result 字段');
          }
          if (result.ok === true) {
            const value: object | null = result.value !== undefined && result.value !== null ? result.value : null;
            if (value !== null) {
              return value;
            }
            const empty: Record<string, Object> = {};
            return empty;
          }
          const errBody: WireErrorBody = result.error !== undefined && result.error !== null
            ? result.error
            : { code: 'gateway/unknown', message: '未知错误' };
          const code: string = errBody.code === undefined ? 'gateway/unknown' : errBody.code;
          const msg: string = errBody.message === undefined ? '未知错误' : errBody.message;
          throw new DshApiClientError(code, msg);
        } catch (err) {
          if (err instanceof DshApiClientError) {
            throw err;
          }
          const e: BusinessError = err as BusinessError;
          throw new DshApiClientError('network/error', '请求失败：' + e.message);
        } finally {
          req.destroy();
        }
      }
    }
    throw new DshApiClientError('gateway/unreachable', '请求未能完成');
  }
}
