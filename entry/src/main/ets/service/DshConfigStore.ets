/** 应用持久化配置层：preferences 存普通配置，SecureStore 资产库存敏感密钥。 */
import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import { DEFAULT_SERVER, DEFAULT_USERNAME, THEME_FOLLOW_SYSTEM, DshConfigData } from '../model/DshTypes';
import { SECURE_ALIAS_PASSWORD, SECURE_ALIAS_TOKEN, SECURE_ALIAS_COOKIE, SecureStore } from './SecureStore';

/** preferences 文件名。 */
const PREFS_NAME: string = 'dsh_config';

/** preferences 键名约定。 */
const KEY_SERVER_URL: string = 'serverUrl';
const KEY_USERNAME: string = 'username';
const KEY_THEME_MODE: string = 'themeMode';
const KEY_ONBOARDED: string = 'onboarded';

/**
 * DshConfigStore：连接中心 / 设置页 / 引导流程共用的配置读写入口。
 * 所有方法均为静态，签名与 WorkspaceView 等视图的调用方式保持兼容。
 */
export class DshConfigStore {
  /** 打开（不存在则创建）dsh_config 偏好文件。 */
  private static async open(ctx: common.Context): Promise<preferences.Preferences> {
    const options: preferences.Options = { name: PREFS_NAME };
    return await preferences.getPreferences(ctx, options);
  }

  /**
   * 读取完整配置快照：普通字段来自 preferences，
   * hasPassword / hasToken 依据资产库中对应密钥是否存在判定；
   * serverUrl 为空时回退到 DEFAULT_SERVER。
   */
  static async load(ctx: common.Context): Promise<DshConfigData> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    let serverUrl: string = prefs.getSync(KEY_SERVER_URL, '') as string;
    const username: string = prefs.getSync(KEY_USERNAME, DEFAULT_USERNAME) as string;
    const themeMode: number = prefs.getSync(KEY_THEME_MODE, THEME_FOLLOW_SYSTEM) as number;
    const onboarded: boolean = prefs.getSync(KEY_ONBOARDED, false) as boolean;
    if (serverUrl === '') {
      serverUrl = DEFAULT_SERVER;
    }
    const password: string = await SecureStore.readSecret(SECURE_ALIAS_PASSWORD);
    const tokenUrl: string = await SecureStore.readSecret(SECURE_ALIAS_TOKEN);
    const data: DshConfigData = {
      serverUrl: serverUrl,
      username: username,
      hasPassword: password !== '',
      hasToken: tokenUrl !== '',
      themeMode: themeMode,
      onboarded: onboarded
    };
    return data;
  }

  /** 保存服务器地址与 Basic Auth 用户名；地址写入前先做规范化。 */
  static async saveAccount(ctx: common.Context, serverUrl: string, username: string): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync(KEY_SERVER_URL, DshConfigStore.normalizeServerUrl(serverUrl));
    prefs.putSync(KEY_USERNAME, username);
    await prefs.flush();
  }

  /** 保存主题模式：0 跟随系统 / 1 深色 / 2 浅色。 */
  static async setThemeMode(ctx: common.Context, mode: number): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync(KEY_THEME_MODE, mode);
    await prefs.flush();
  }

  /** 标记首次引导已完成。 */
  static async setOnboarded(ctx: common.Context, value: boolean): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync(KEY_ONBOARDED, value);
    await prefs.flush();
  }

  /** 保存 Basic Auth 密码到资产库。 */
  static async savePassword(password: string): Promise<void> {
    await SecureStore.saveSecret(SECURE_ALIAS_PASSWORD, password);
  }

  /** 保存 dsh 令牌 URL 到资产库。 */
  static async saveTokenUrl(url: string): Promise<void> {
    await SecureStore.saveSecret(SECURE_ALIAS_TOKEN, url);
  }

  /** 读取 Basic Auth 密码，未保存时返回空串。 */
  static async getPassword(): Promise<string> {
    return await SecureStore.readSecret(SECURE_ALIAS_PASSWORD);
  }

  /** 读取 dsh 令牌 URL，未保存时返回空串。 */
  static async getTokenUrl(): Promise<string> {
    return await SecureStore.readSecret(SECURE_ALIAS_TOKEN);
  }

  /** 清空全部本地数据：preferences 整表清除 + 密钥与会话 Cookie 删除。 */
  static async wipe(ctx: common.Context): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    await prefs.clear();
    await prefs.flush();
    await SecureStore.deleteSecret(SECURE_ALIAS_PASSWORD);
    await SecureStore.deleteSecret(SECURE_ALIAS_TOKEN);
    await SecureStore.deleteSecret(SECURE_ALIAS_COOKIE);
  }

  /** 记录会话 Cookie 的签发时间（登录态到期提醒依据）。 */
  static async setCookieMintedAt(ctx: common.Context, ts: number): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync('cookieMintedAt', ts);
    await prefs.flush();
  }

  /** 读取 Cookie 签发时间；未记录为 0。 */
  static async getCookieMintedAt(ctx: common.Context): Promise<number> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    return prefs.getSync('cookieMintedAt', 0) as number;
  }

  /** 本机隐藏的会话 ID 列表（如 PC 端已归档的会话）。 */
  static async getHiddenSessions(ctx: common.Context): Promise<string[]> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    const raw: string = prefs.getSync('hiddenSessions', '') as string;
    if (raw === '') {
      return [];
    }
    return raw.split(',').filter((s: string) => s !== '');
  }

  /** 在本机隐藏一个会话（不影响服务器与其他设备）。 */
  static async hideSession(ctx: common.Context, sessionId: string): Promise<void> {
    const cur: string[] = await DshConfigStore.getHiddenSessions(ctx);
    if (cur.indexOf(sessionId) >= 0) {
      return;
    }
    cur.push(sessionId);
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync('hiddenSessions', cur.join(','));
    await prefs.flush();
  }

  /** 恢复单个本机隐藏的会话（设置页逐个恢复）。 */
  static async unhideSession(ctx: common.Context, sessionId: string): Promise<void> {
    const cur: string[] = await DshConfigStore.getHiddenSessions(ctx);
    const idx: number = cur.indexOf(sessionId);
    if (idx < 0) {
      return;
    }
    cur.splice(idx, 1);
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync('hiddenSessions', cur.join(','));
    await prefs.flush();
  }

  /** 清除全部本机隐藏记录（所有会话重新可见）。 */
  static async clearHiddenSessions(ctx: common.Context): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync('hiddenSessions', '');
    await prefs.flush();
  }

  /** 会话列表展示模式：0 按时间分组 / 1 按项目分组（默认）。 */
  static async getListViewMode(ctx: common.Context): Promise<number> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    return prefs.getSync('listViewMode', 1) as number;
  }

  /** 保存会话列表展示模式。 */
  static async setListViewMode(ctx: common.Context, mode: number): Promise<void> {
    const prefs: preferences.Preferences = await DshConfigStore.open(ctx);
    prefs.putSync('listViewMode', mode);
    await prefs.flush();
  }

  /** 服务器地址规范化：去首尾空白；无协议头补 https://；去掉结尾斜杠。 */
  static normalizeServerUrl(raw: string): string {
    let url: string = raw.trim();
    if (url === '') {
      return '';
    }
    if (url.indexOf('://') < 0) {
      url = 'https://' + url;
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
