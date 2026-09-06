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
  Tool,
  /** 轮次失败（turn/end reason≠completed；text=格式化错误信息）。 */
  Error
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
  /** 助手正在生成中（存在晚于最后一条消息的 chunk 流事件）。 */
  generating: boolean;
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

/** 工作区（dsh web「工作区」同构：一个工程目录 = 一组会话，顺序即服务器展示序）。 */
export interface WorkspaceVm {
  workspaceId: string;
  /** 显示名（默认取目录 basename）。 */
  title: string;
  /** 工程目录绝对路径。 */
  path: string;
  /** 成员会话 ID（服务器维护的手动排序）。 */
  sessionIds: string[];
}

/** workspace/follow 基线：工作区列表 + 全局归档集（web 端各处隐藏的会话）。 */
export interface WorkspaceBaselineVm {
  workspaces: WorkspaceVm[];
  archivedSessionIds: string[];
}

/** 用户提问的单个选项（web 端 ask_user_question 选项同构）。 */
export interface QuestionOptionVm {
  /** 选项文案（回答时以此回传，作为 selected 元素）。 */
  label: string;
  /** 补充说明；缺失为空串。 */
  description: string;
}

/** 单个提问（user-questions/request 内的一题）。 */
export interface QuestionVm {
  /** 题目 ID（回答批次的键）。 */
  id: string;
  /** 分组小标题；缺失为空串。 */
  header: string;
  /** 问题正文。 */
  question: string;
  /** 补充说明；计划审批题时为计划正文（Markdown 纯文本）。 */
  detail: string;
  /** 是否多选。 */
  multiSelect: boolean;
  /** 计划审批特例（intent.kind==='plan-review' 且携带 detail）。 */
  planReview: boolean;
  /** 计划审批的「确认执行」选项 label（intent.approve）。 */
  approveLabel: string;
  /** 选项列表（可为空 = 纯自由作答题）。 */
  options: QuestionOptionVm[];
}

/** 待用户处理的一次交互请求（dsh → 客户端 waterfall）。 */
export interface PendingAskVm {
  /** 'questions' 用户提问组 | 'approval' 工具权限审批。 */
  kind: string;
  /** waterfall 事件 ID（回答回执键）。 */
  eventId: string;
  /** 所属会话 ID（waterfall 的 agentId 即 sessionId）。 */
  sessionId: string;
  /** 提问列表；approval 时为空数组。 */
  questions: QuestionVm[];
  /** 审批：工具名 / 调用 ID / 原因。 */
  toolName: string;
  callId: string;
  reason: string;
  /** 本机收到时间（毫秒）。 */
  receivedAt: number;
}

/** 会话列表分区：一个工作区，或未归属任何工作区的「未分组」桶。 */
export interface SessionSectionVm {
  /** 折叠状态记忆键（workspaceId 或 'ungrouped'）。 */
  key: string;
  title: string;
  /** 工程目录；未分组为空串。 */
  path: string;
  sessions: SessionSummaryVm[];
  /** 是否未分组桶（配色与工作区区分）。 */
  ungrouped: boolean;
  /** 分区头图标：'folder' 工程 / 'hash' 未分组 / 'clock' 时间段 / '' 无图标。 */
  icon: string;
}
