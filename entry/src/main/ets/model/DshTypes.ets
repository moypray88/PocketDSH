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

/** 系统侧滑/返回键协调：Index.onBackPress 与二级视图之间的信号键。 */
export const KEY_CHAT_BACK_DEPTH: string = 'chatBackDepth'
export const KEY_BACK_POP_TICK: string = 'backPopTick'
export const KEY_ONB_STEP: string = 'onbStep'
export const KEY_ONB_BACK_TICK: string = 'onbBackTick'

/** 跨页动作信号：请求工作台新建会话（首页"新建任务"/Tab"新建对话"）。 */
export const KEY_CHAT_CREATE_TICK: string = 'chatCreateTick'

/** Index 当前选中的 Tab（0=会话，与 Index.TabId 对齐）；工作台据此感知页面显隐。 */
export const KEY_CUR_TAB: string = 'curTab'
export const TAB_SESSIONS: number = 0

/** 跨页信号：本机隐藏集被设置页改动（全部恢复），工作台需重载 hiddenIds。 */
export const KEY_HIDDEN_TICK: string = 'hiddenTick'

/** dsh 主动交互（提问/审批）：DshEventClient 列表变更时 +1，视图重读 pending 列表。 */
export const KEY_ASK_TICK: string = 'askTick'
/** 工作台当前选中会话 ID（工作台写入；全局横幅据此判断问题是否已在对话页可见）。 */
export const KEY_CHAT_SELECTED_ID: string = 'chatSelectedId'
/** 跨页跳转会话请求（全局横幅点击下发）：askJumpId 携带目标会话。 */
export const KEY_ASK_JUMP_ID: string = 'askJumpId'
export const KEY_ASK_JUMP_TICK: string = 'askJumpTick'
