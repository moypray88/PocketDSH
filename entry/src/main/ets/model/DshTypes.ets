/** PocketDSH 全局类型与常量契约 —— 所有模块共同依赖，勿随意改动字段名。 */

/** 健康探针快照（连接中心状态卡数据源）。 */
export interface HealthSnapshot {
  /** 服务器网络可达（任意 HTTP 响应即视为可达）。 */
  online: boolean
  /** 往返延迟毫秒；不可达时为 -1。 */
  latencyMs: number
  /** 本次探测时间戳（毫秒）。 */
  checkedAt: number
  /** 'ok' | 'auth-required' | 具体错误信息。 */
  detail: string
}

/** 持久化配置数据（密码与令牌在 SecureStore 资产库中，不含在本结构内）。 */
export interface DshConfigData {
  /** 服务器根地址，如 https://dsh.goldclew.com（结尾不带斜杠）。 */
  serverUrl: string
  /** nginx Basic Auth 用户名。 */
  username: string
  /** 是否已保存密码（资产库中存在）。 */
  hasPassword: boolean
  /** 是否已保存 dsh 令牌 URL。 */
  hasToken: boolean
  /** 0 跟随系统 / 1 深色 / 2 浅色。 */
  themeMode: number
  /** 是否已完成首次引导。 */
  onboarded: boolean
}

export const THEME_FOLLOW_SYSTEM: number = 0
export const THEME_DARK: number = 1
export const THEME_LIGHT: number = 2

export const DEFAULT_SERVER: string = 'https://dsh.goldclew.com'
export const DEFAULT_USERNAME: string = 'moypray'

/** AppStorage 全局键名约定（EntryAbility 与各视图一致使用）。 */
export const KEY_THEME_IS_DARK: string = 'themeIsDark'
export const KEY_THEME_MODE: string = 'themeMode'
export const KEY_CONFIG_READY: string = 'configReady'
export const KEY_TOKEN_TICK: string = 'tokenRefreshTick'
