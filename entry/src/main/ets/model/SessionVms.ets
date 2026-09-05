/** 会话与聊天历史视图模型：由 DshSessionsRepository 从 dsh wire 数据归一化产出，供视图直接绑定渲染。 */

/** 会话列表项摘要（session/list）。 */
export interface SessionSummaryVm {
  /** 会话 ID（wire 侧可能是数字，此处统一为字符串）。 */
  sessionId: string;
  /** 投影标题；缺失时仓库层回填 '(未命名会话)'。 */
  title: string;
  /** 最近更新时间（毫秒时间戳）。 */
  updatedAt: number;
  /** 会话是否仍在运行。 */
  running: boolean;
  /** 工作目录。 */
  cwd: string;
  /** 累计轮数（sessionStats.turns，缺失为 0）。 */
  turns: number;
  /** turnOutline 最后一项的 prompt（截 60 字）。 */
  lastPrompt: string;
  /** 当前游标（projections.asOfSeq），作 session/page 的 throughSeq 上限；缺失为 -1。 */
  asOfSeq: number;
  /** 会话最近使用的模型 ID（modelSelection.lastUsed.model，缺失为空串）。 */
  model: string;
}

/** 工具调用视图模型：call 与 result 按 callId 配对，resultText 截 2000 字。 */
export interface ToolCallVm {
  /** 配对用调用 ID。 */
  callId: string;
  /** 工具名。 */
  name: string;
  /** 入参（wire 原样字符串，或对象序列化结果）。 */
  arguments: string;
  /** 结果文本；未收到 result 前为空串。 */
  resultText: string;
  /** 所属轮次。 */
  turn: number;
}

/** 聊天条目类别。 */
export enum ChatEntryKind {
  /** 轮次分隔（turn/start）。 */
  Turn,
  /** 用户消息。 */
  User,
  /** 助手消息（含 reasoning 与用量）。 */
  Assistant,
  /** 工具调用（含结果回填）。 */
  Tool
}

/** 单条聊天条目（session/page 记录归一化结果）。 */
export interface ChatEntryVm {
  /** 条目类别。 */
  kind: ChatEntryKind;
  /** 事件序号（升序排序键）。 */
  seq: number;
  /** 事件时间（wire 原样数值）。 */
  time: number;
  /** 所属轮次；未知为 0。 */
  turn: number;
  /** 正文（User/Assistant 的文本块拼接、Turn 的 '第 N 轮'）。 */
  text: string;
  /** 助手推理文本（reasoning 块拼接）。 */
  reasoning: string;
  /** 输入 token 用量。 */
  usageIn: number;
  /** 输出 token 用量。 */
  usageOut: number;
  /** 模型名。 */
  model: string;
  /** 工具调用详情；仅 kind=Tool 时非空。 */
  tool: ToolCallVm | null;
}

/** 一页聊天历史。 */
export interface HistoryPageVm {
  /** 本页条目（按 seq 升序）。 */
  entries: ChatEntryVm[];
  /** 是否还有更早的记录。 */
  hasMore: boolean;
  /** 本页最旧一条的 seq；空页为 0。 */
  oldestSeq: number;
}

/** 模型目录单项。 */
export interface ModelItemVm {
  id: string;
  name: string;
  description: string;
}

/** 模型目录分组（按提供商）。 */
export interface ModelGroupVm {
  id: string;
  name: string;
  models: ModelItemVm[];
}

/** 模型目录（session/modelCatalog）。 */
export interface CatalogVm {
  /** 部署默认模型 ID。 */
  defaultModel: string;
  groups: ModelGroupVm[];
}
