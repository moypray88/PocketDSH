# PocketDSH 架构设计文档

> 本文档沉淀工程最重要的"记忆"：认证链路、dsh 协议契约、核心模块职责、关键设计决策（ADR）与踩坑记录。
> 新会话/新成员从这里开始，不需要重新逆向任何东西。

- 项目：鸿蒙（HarmonyOS）折叠屏 APP，远程指挥云主机上的 DeepSeek Harness（dsh）
- 工程：`D:\workspace\PocketDSH`，SDK 6.1.1（API 24），bundle `com.pocket.dsh`
- 服务器：`https://dsh.goldclew.com` = nginx（Basic Auth）→ 反代 dsh web（127.0.0.1:3080，systemd 单元 `dsh-web.service`）

---

## 1. 总体架构

```
┌─────────────────────── 华为 Pure X Max（阔折叠）───────────────────────┐
│                                                                      │
│  ┌─ UI 层 ─────────────────────────────────────────────┐             │
│  │ Index.ets（唯一主 @Entry，5 Tab + 返回深度协调）          │             │
│  │  ├ HomeView        首页：状态卡/新建任务/近期会话/到期预警 │             │
│  │  ├ WorkspaceChatView  会话列表 + 对话（主力页面）       │             │
│  │  ├ ReportView      策略报告：/reports/ 浏览器（WebView） │             │
│  │  ├ SettingsView    主题/账号/令牌/隐藏恢复/完整版入口   │             │
│  │  ├ OnboardingView  三步引导（地址→账号→令牌校验）       │             │
│  │  └ WorkspaceView   WebView 内嵌 dsh 官方控制台（备用）  │             │
│  │ ReportViewerAbility（第二 UIAbility）：会话链接拉起的        │             │
│  │   独立报告窗口（singleton，ReportWindowPage + ReportBrowser）│             │
│  ├─ 服务层 ─────────────────────────────────────────────┤             │
│  │  DshApiClient        RPC 客户端（信封/认证/自愈）      │             │
│  │  DshStreamClient     WebSocket 逐字流（remote.mux）   │             │
│  │  DshEventClient      dsh 主动交互流（提问/审批）       │             │
│  │  DshSessionsRepository  wire→视图模型（三层 null 防御） │             │
│  │  DshConfigStore      偏好持久化 + 本机隐藏            │             │
│  │  SecureStore         系统资产库加密（密码/令牌/Cookie） │             │
│  │  HealthMonitor       延迟探针                        │             │
│  ├─ 基础 ───────────────────────────────────────────────┤             │
│  │  Theme.ets 双主题令牌 │ MdParser.ets 轻量 Markdown      │             │
│  │  SessionVms.ets 视图模型契约 │ DshTypes.ets 全局键/常量 │             │
│  └──────────────────────────────────────────────────────┘             │
└──────────────────────────────┬───────────────────────────────┘
                               │ HTTPS（手机直连；PC 开发需代理）
┌──────────────────────────────▼───────────────────────────────┐
│ nginx（Basic Auth: moypray）                                 │
│  ├── /  → 反代 127.0.0.1:3080（dsh web）                     │
│  └── /.pocketdsh/token → 令牌自动端点（已设计，暂未部署）        │
├──────────────────────────────────────────────────────────────┤
│ dsh web（systemd: dsh-web.service）                          │
│  ├── HTTP RPC：session/list · page · prompt · create ·       │
│  │   rename · cancel · selectModel · modelCatalog            │
│  ├── WS 流：/api/remote.mux（复用通道：session/follow ·       │
│  │   workspace/follow · $events 主动交互事件流）              │
│  ├── 主动交互 waterfall：user-questions/request ·            │
│  │   approval/request → 回执 $events/result                  │
│  └── 认证：?token=xxx 一次性换 30 天签名 Cookie                │
│      （签名密钥持久化 → Cookie 跨重启有效；WS 握手同源同凭证）  │
└──────────────────────────────────────────────────────────────┘
```

### 折叠屏双态

- **断点**：根容器 `onAreaChange`，宽 ≥640vp = 展开态
- 展开态：左侧 96vp 图标栏 + 内容区（对话页可再收起 320vp 会话左栏，`listPaneWidth` 动画）
- 合盖态：底部 Tab（4 项，其中"新建"为动作项不保持选中）+ 单栏两级导航（列表↔对话）
- 底栏/输入区垫高 `bottomAvoidPx`（系统手势条避让，EntryAbility 启动时读取）

---

## 2. 认证链路（最核心的工程记忆）

### 2.1 两层门禁

```
APP 请求 ──① nginx Basic Auth（moypray/密码，每次请求自动携带）
        ──② dsh 会话 Cookie（dsh-auth-*，HttpOnly，30 天）
```

- **用户名密码只开第一道门**。dsh 无账号密码体系，唯一发票入口是 `GET /?token=xxx`
- `?token=` 是**一次性门票**：`dsh web` 每次启动随机生成（进程内存，重启即换）
- 换到的 Cookie 是**长期通行证**：30 天有效；**签名密钥持久化在服务器凭据库**（`modifyRecord` 复用已有），因此 **Cookie 跨 dsh 重启依然有效**（已真机+浏览器实验双重验证）

### 2.2 Cookie 获取的四个来源（依序兜底）

| # | 来源 | 场景 |
|---|---|---|
| 1 | 内存静态缓存（未过期） | 常规运行 |
| 2 | 令牌 URL 换票（GET 令牌 URL，跟随重定向，从 set-cookie/resp.cookies 提取） | 启动后首次 / 401 自愈 |
| 3 | WebView Cookie 罐（`fetchCookieSync`） | 用过"完整版"的设备 |
| 4 | **自动令牌端点** `GET /.pocketdsh/token`（Basic 保护；服务器定时从 journal 发布最新令牌）| 令牌也失效时；**端点已设计未部署** |

- ⚠️ 鸿蒙 `@ohos.net.http` 设 `maxRedirects:0` 会**抛 2300047 异常**而非返回 303——必须跟随重定向再从最终响应提取
- 换到 Cookie 后：**加密持久化**（SecureStore 资产库）+ 记录签发时间（preferences `cookieMintedAt`，到期提醒依据）

### 2.3 自愈环

```
401 → clearCookie（内存+持久层）→ 重换 Cookie → 同请求重试一次
     → 仍失败 → 令牌失效 → 来源 4 端点兜底 → 仍失败 → 明确报错引导设置页
```

### 2.4 到期提醒

- Cookie 生命周期 30 天；首页每轮刷新计算剩余天数
- 剩余 ≤5 天或已过期 → 琥珀色预警条 + "去更新"直达设置页
- 未记录签发时间（-1）不显示；下次换票后自动开始生效

---

## 3. dsh API 协议契约（全部实测）

### 3.1 传输与信封

```
POST {server}/api/{method}
Headers: Content-Type: application/json
         Authorization: Basic base64(user:pass)
         Origin: {server}          ← Connection 插件校验
         Cookie: dsh-auth-*=v1...

请求体: {"type":"client-request","rpcId":"<32位hex>","method":"<method>",
         "payload":{"args": <args>}}
响应体: {"type":"server-response","rpcId":...,
         "result":{"ok":true,"value":{...}} | {"ok":false,"error":{code,message,details}}}
```

- `args` 形态按端点而定：多数是 `{"request": {...}}`，`session/list` 用 `{"_request":{}}`，`session/modelCatalog` / `commands/execute` 是**裸对象无包装**
- 方法名为**驼峰**（`session/modelCatalog`），带命名空间前缀

### 3.2 端点速查

| 方法 | args 包装 | 请求要点 | 备注 |
|---|---|---|---|
| `session/list` | `_request` | `{}` | items 含 projections.asOfSeq（=page 游标上限）/values.title/cwd/sessionStats/turnOutline/modelSelection.lastUsed |
| `session/page` | `request` | `{address:{kind:'session',sessionId},throughSeq,maxMessages,beforeSeq?}` | throughSeq **必须 ≤ 当前游标**；超限报 `past cursor N`（正则提取 N 反查）；999999999 合法（边界校验在 1e10 以上） |
| `session/prompt` | `request` | `{requestId(客户端生成，防重),sessionId,mode:'queue',content:[{type:'text',text}\|{type:'image',mediaType,data:base64,name?}],clientTimeZone}` | **唯一真实发送通道**；返回 `{accepted:true}` |
| `session/create` | `request` | `{cwd?}` 或 `{workspaceId?}`（**二选一互斥**） | 返回 sessionId；**延迟创建**：仅首条消息发出时调用。workspaceId 把会话归入该工作区（cwd 由服务器取工作区 path）；只传 cwd 的会话永远进「未分组」 |
| `session/selectModel` | `request` | `{sessionId,provider,model}` | 切换后生效于下一条消息 |
| `session/modelCatalog` | （裸 args） | `{}` | groups[].models[] + default |
| `session/cancel` | `request` | `{sessionId}` | 停止生成 |
| `session/rename` | `request` | `{sessionId,title}` | 服务器级重命名 |
| ~~`commands/execute`~~ | 裸 | `{agentId,line,images}` | ⚠️ **陷阱：TUI 壳命令通道，返回 ok 但消息不进对话** |
| `session/readImage` | `request` | `{path}`（服务器绝对路径） | **自建服务端扩展**：按已注册工作区目录白名单取图，返回 `{mediaType,bytes,data:base64}`；扩展名限 png/jpg/jpeg/webp/gif、20MiB 上限；工作区外/越权报 `session/image-denied`。App 用于 Markdown 里的本地路径图片 |
| `agentPresets/list` | （空 args） | `{}` | Agent 预设名单（web「模式」选择器同源）：`{presets:[{id,trust,isDefault,name?,description?,broken?}],authorable}`；内置标准/PTC/极简/创造模式（中文名来自预设元数据）；`broken` 非空 = 组合不可用，App 过滤不展示 |
| `agentPresets/select` | （**args 直传**） | `{"agent":<sessionId>,"agentPreset":<presetId>}` | 把预设应用到会话；**仅空白会话可用**（首条消息后报 `agent-preset/locked`），返回生效的 preset id。App 在草稿发送链路里 create→select→selectModel→prompt 依次执行 |
| `session/attachment` | `request` | `{sessionId,attachmentId}` | 服务端校验该会话日志引用过此附件；返回 `{attachment:{mediaType,...},data:base64}`。App 用于消息内 image 内容块的取图渲染 |

未接入已发现：`session/search`、`session/fork`。

### 3.5 WebSocket 流式协议（remote.mux，全部实测）✅

**入口**：`wss://{authority}/api/remote.mux`；握手头 = **Basic Auth + dsh-auth Cookie**（实测通过；nginx 直接放行 WS Upgrade）。服务端有 WS 心跳 ping，空闲连接不会被 nginx 切断。
**⚠️ 绝不能在握手头里显式传 Origin**：netstack 会自动追加它自己按连接目标推导的 Origin（恰好是正确值），显式传会被逗号合并成 `"x, y"` 畸形值，dsh 的 Origin 校验直接拒绝（表现为 `ws error 200` + netstack 日志 `HS: ws upgrade response not 101`）。此坑无文档可查，靠 `hdc rport` + 本机诊断服务器逐字抓手机握手头定位（详见 §6）。

**复用帧**（JSON 文本帧，一连接多逻辑流，streamId 客户端生成）：

| 方向 | 帧 |
|---|---|
| C→S | `{"type":"open","streamId":S,"endpoint":"session/follow","payload":{"args":{"request":{"address":{"kind":"session","sessionId":ID},"maxMessages":50,"assistantStream":true}}}}` |
| C→S | `{"type":"cancel","streamId":S}` |
| S→C | `{"type":"item","streamId":S,"value":<见下>}` / `{"type":"end",...}` / `{"type":"error",...,"error":{code,message,details}}` |

**item.value 三态**（session/follow 流）：

1. `snapshot`：`{header, cursor, records, hasMore, projections, assistantStream?}`——开仓快照，cursor 即当前游标（= page 的 throughSeq 上限）；records 与 `session/page` 同构（可复用解析管线）
2. `{type:'event', event}`：持久事件实时推送（gap-free，与历史同 wire）
3. `{type:'assistant-stream', frame}`：v2 服务器活帧（本服务器为 v1，不会出现；客户端已做向前兼容）

**v1 服务器的实时 chunk 语义（打字机数据源，实测）**：生成期间每个增量都是持久事件 `assistant/chunk`，`data.chunk` 形态：
- `{type:'block-start', index, blockType:'reasoning'|'text'}` 开块
- `{type:'text-delta'|'reasoning-delta', index, text}` 逐词增量
- `{type:'block-end', index, block:{type,text}}` 权威整块回填
- `{type:'usage', usage:{inputTokens,outputTokens,…}}`、`{type:'finish', reason}` 控制

结算链：`assistant/message`（surfaceOp:'append'）→ `step/end` → `turn/end`。**turn/end 是"生成彻底终止"信号**。轮次完成后服务器把 chunk 事件压缩成 `chunkrow/text-chunks`、`chunkrow/reasoning-chunks` 行（`{turn,step,index,dt[],texts[]}`，texts 拼接即整块），快照/历史里看到的是压缩行。

**失败轮次可见性（实测补齐）**：失败轮（如模型无权限）**没有 assistant/message**，错误详情只在 `turn/end` 的 `reason` 里：`{kind:'completed'|'blocked'|'max-tokens'|'interrupted'|'aborted'|'error', error: llmFailure{code,message,status}}`。且失败轮的 chunk **不会被压缩**——`generating` 判定若只比 chunk/content seq 先后会把已结束的失败轮永远判成生成中，必须计入 turn/end（最近 chunk 晚于最近 turn/end 才算生成中，仓库层与快照重放两处同构）。app 侧失败渲染为红色 ⛔ 错误卡（流式路径实时 + 轮询/历史路径同源），实时失败额外 toast。

**PocketDSH 消费模型**（`DshStreamClient`）：
- 断线自动重连（1.5s 指数退避至 15s），重连后 snapshot 重放补缺口；重放期间增量暂存，按"chunk seq > 内容 seq 且晚于最近 turn/end"判定生成仍在进行才交付（旧轮次重放不闪 UI）
- view 按 seq 去重：user/message 追加气泡并清乐观回显；delta 追加流式缓冲（80ms 节流 flush + 贴底门控，用户上翻即让位）；block-end 以权威内容替换缓冲；assistant/message 结算转正条目并清流式卡；turn/end 清空 typing、非 completed 落错误卡
- 流健康时 `pollAfterSend` 直接跳过；流断开回调触发轮询兜底，恢复后无缝衔接（seq 去重）

### 3.6 dsh 主动交互协议（$events 流，全部实测）✅

dsh 执行中需要用户输入时（`ask_user_question` 提问组、工具越权审批）通过 **Gateway 事件通道**向各客户端推送 waterfall 请求；web 端弹出问题卡片，PocketDSH 原生实现同构交互。协议逆向自 web 前端插件源码（`dsh-client-ui-user-questions` / `api-gateway`），并已全链路实测（create → prompt → waterfall → result → agent 续跑）。

**传输**：复用 `/api/remote.mux`（与会话 follow 同一 WS 路由，独立逻辑流）。PocketDSH 由 `DshEventClient` 开一条**应用级常驻连接**专用于此流（与 DshStreamClient 互不影响）。

**流生命周期**（item.value 一态三帧）：

| 帧 | 形状 | 语义 |
|---|---|---|
| 首帧 ready | `{type:'ready', clientId, host:{home}}` | 服务端分配 clientId（回答回执身份）；重连后为新一代 |
| waterfall | `{type:'waterfall', event, eventId, agentId, request}` | 需要用户处理的一次请求；**agentId === sessionId**（源码注释明示） |
| cancel | `{type:'cancel', eventId}` | 服务端撤销（已在他端作答/任务中止）→ 移除本地弹卡 |

- open 帧：`{type:'open', streamId:S, endpoint:'$events', payload:{args:{}}}`（空 args）
- `emit` 帧（如 `api-session/status`）为状态广播，忽略
- 未支持的 waterfall 事件必须回 `next` 让位（否则服务端等待本端）

**事件类型**：

| event | request 形状 | UI |
|---|---|---|
| `user-questions/request` | `{questions:[{id, header?, question, detail?, multiSelect?, options?:[{label, description?}], intent?:{kind:'plan-review', approve}}]}` | 提问卡片：单选/多选/自定义文本/跳过；单题 + intent.kind='plan-review' + detail 非空 + 非多选 + ≤2 选项 = 计划审批卡（detail 为计划正文，approve 指向「确认执行」选项） |
| `approval/request` | `{toolName, callId?, reason?}` | 审批卡片：拒绝 / 允许一次 |

**回答**：unary RPC `POST /api/$events/result`（信封 args 直传，无包装）：

```
args = {clientId, eventId, outcome}
outcome 三态:
  {kind:'result', value:{answers:[{id, selected:string[], custom?}]}}   // 提问
  {kind:'result', value:'allowed-once' | 'rejected'}                    // 审批
  {kind:'next'}                                                        // 让位给下一个监听端（如 web）
  {kind:'rejected', error:{name, message, code?}}                       // 显式取消（web「放弃整组问题」= ASK_CANCELLED）
```

- 回答批次语义（web QuestionComposer 同构）：跳过题 `selected:[]`；单选题自定义文本覆盖选项（`selected:[]` + `custom`）；多选题选项与自定义可共存
- 已在别端作答再提交：服务端报错（本地通常经 cancel 帧先行移除）
- **重连语义**：新一代 ready 后服务端重投递未决 waterfall；旧代遗留条目给 5s 宽限，未被重投的按陈旧丢弃
- 实测坑：web 端 waterfall 是**多客户端竞速**——手机与网页同时连着时两端都会弹卡，先答者胜，另一端收 cancel 帧收卡

**PocketDSH 消费模型**（`DshEventClient` + 双 UI）：

- pending 列表由 `DshEventClient` 持有，变更 bump AppStorage `askTick`，视图重读
- 对话页：当前会话命中 → 输入区上方渲染卡片（提交/跳过/放弃/去网页处理）
- 全局横幅：非当前会话或不在会话 Tab → Index 顶部横幅，点击跳转会话（`askJumpId/askJumpTick`），✕ 仅本机隐藏提示
- 客户端断开或流级 end/error → 指数退避重连（1.5s→15s）

### 3.3 历史事件流（session/page records）

**渲染映射**：

| 事件 | 渲染 | 关键字段 |
|---|---|---|
| `user/message` | 用户气泡 | ⚠️ **只渲染 `source.kind==='user'`**；`plugin`/`skill-catalog` 是系统注入的伪用户消息（几千字上下文），渲染它们=问题与回复之间出现"空白墙"（血的教训） |
| `assistant/message` | AI 卡片 | content[] 里 `reasoning` 与 `text` 块、usage、source.model；**text 与 reasoning 全空 = 工具步骤空壳帧，必须跳过** |
| `tool/call` + `tool/result` | 工具行（点击展开） | 按 `callId` 配对回填 resultText |
| `turn/start` | 轮次徽章 | data.turn |
| `assistant/chunk`、`chunkrow/*` | **不渲染条目**，但用于 `generating` 判定 | chunk 事件 seq > 最后一条消息 seq ⇒ 正在生成 → "dsh 正在输入…"指示 |
| 其余（step/*、agent/inbox/*、permission/*、request/*、web/*、session/*…） | 忽略 | |

- 分页：每页 50；加载更早用 `beforeSeq = 本页最旧 seq`；合并按 seq 去重
- `generating` 判定：`maxChunkSeq > maxContentSeq`

### 3.4 认证相关事实

- 令牌交换：GET 令牌 URL（带 Basic）→ 303 + `set-cookie: dsh-auth-*=v1...; Max-Age=2592000`（30 天）
- Cookie 名 = `dsh-auth-` + base64url(sha256(authority))，绑定访问域名
- 签名密钥持久 → **Cookie 跨 dsh 重启有效**（浏览器与 APP 同等韧性，已实验证明）

---

## 4. 核心模块职责

| 文件 | 职责 | 关键设计 |
|---|---|---|
| `service/DshApiClient.ets` | RPC 客户端 | 信封构造（args 包装三形态）；Cookie 四源获取；**401 自愈**（同请求重试一次）；头组合变体重试（带/不带 Origin）；`DshApiClientError(code,message)`；自动令牌端点兜底；`clearCookie()` 同步清内存+异步清持久层；`cookieDaysLeft()`；`wsConnectInfo()`（WS 握手头出口） |
| `service/DshStreamClient.ets` | **WebSocket 逐字流** | `/api/remote.mux` 单连接复用 + `session/follow`；断线指数退避重连 + snapshot 重放补缺口；chunk 归一化（block-start/delta/block-end/usage）；v1 持久 chunk 事件与 v2 assistant-stream 活帧双兼容；重放缓冲按 generating 判定交付；监听器回调（seq 语义与历史一致）；`fetchWorkspaceFollowBaseline` 临时连接一次性拉工作区基线（列表分组/归档过滤数据源，60s 缓存） |
| `service/DshEventClient.ets` | **dsh 主动交互流**（提问/审批） | `$events` 流常驻连接（协议见 §3.6）；ready/waterfall/cancel 帧解析；pending 列表持有 + `askTick` 变更广播；回答/审批/放弃/让位四动作走 `$events/result`；未支持事件自动让位；重连后旧代条目 5s 宽限 |
| `service/DshSessionsRepository.ets` | wire→VM | **三层 null 防御**（信封层/解析层/单条跳过）；伪用户消息过滤；空壳 assistant 帧跳过；`generating` 判定；游标反查（past-cursor 正则）；sendText 支持图片 part |
| `service/DshConfigStore.ets` | 持久化 | preferences `dsh_config`（server/username/theme/onboarded/hiddenSessions/cookieMintedAt）+ 资产库密钥代理；`normalizeServerUrl` |
| `service/SecureStore.ets` | 加密存储 | `@ohos.security.asset`；别名：password / token URL / session cookie；读失败一律返回 ''（不抛） |
| `service/HealthMonitor.ets` | 探针 | Basic Auth GET，任意响应=在线；200 ok / 401 auth-required |
| `views/WorkspaceChatView.ets` | 主力页面 | 会话列表（搜索/长按菜单[重命名/本机隐藏]/Tab 显隐+30s 静默刷新[ADR-11]）+ 对话（导轨圆点时间线/三级折叠/Markdown/模型浮层/乐观回显/**WS 流式打字机卡**）+ **dsh 提问/审批卡片**（输入区上方，选项/多选/自定义/跳过/计划审批/工具审批）+ 草稿式新任务（延迟创建+工作目录选择）+ 返回深度 `chatBackDepth`；流健康时免轮询，断流自动降级轮询 |
| `views/HomeView.ets` | 首页 | 缓存秒显（AppStorage homeXxxCache）+ 静默定时刷新（数据变化才写状态）+ 到期预警 + 快捷任务（预填工作台输入框） |
| `views/OnboardingView.ets` | 引导 | 三步；令牌真实校验（GET 令牌 URL，401 时按响应体区分 dsh 令牌错误 vs nginx 密码错误）；自动获取令牌按钮；`onbStep` 同步支持侧滑回退 |
| `views/SettingsView.ets` | 设置 | 主题三选（matchMedia 系统深浅）；令牌重贴（**同时清 WebView Cookie + 原生内存 Cookie**）；隐藏会话恢复；完整版入口；危险区 wipe |
| `pages/Index.ets` | 外壳 | 5 Tab（首页/会话/新建动作/策略报告/设置）；断点 640vp 双态；`onBackPress` 返回深度协调（浮层→对话/草稿→列表→引导步骤→报告后退→才允许退出）；**configReady 启停 DshEventClient**；**dsh 待回答横幅**（非当前会话提示，点击跳转/✕本机隐藏） |
| `views/ReportBrowser.ets` | **报告浏览器组件**（Tab 与独立窗口共用） | 工具条（✕可选/‹›/地址胶囊点按复制/↻/⋮菜单）+ 顶部细进度线 + WebView（darkMode Off：报告自带浅色样式不破坏）+ `onHttpAuthRequest` 自动答 Basic + 原生 dsh Cookie `configCookieSync` 同步进罐（`/reports/` 免认证的兜底）+ 主资源错误覆盖卡（重试/复制）；`urlToLoad` @Prop @Watch 即换页（独立窗口 onNewWant 复用）；返回键经 `KEY_REPORT_BACK_TICK` 下发 webview 后退，无历史时窗口形态回调退出 |
| `views/ReportView.ets` | 策略报告 Tab | 配置加载后打开 `{server}/reports/`（nginx autoindex 直显，实测免 Basic Auth）；深度写 `KEY_REPORT_BACK_DEPTH` 供外壳返回协调 |
| `reportability/ReportViewerAbility.ets` | **独立报告窗口** | 第二 UIAbility（singleton，exported false）；`want.uri` → AppStorage（KEY_REPORT_WINDOW_URL/TICK），onCreate/onNewWant 统一入口；会话内同源链接由 `WorkspaceChatView.openReportLink` startAbility 拉起，已有窗口复用换页 |
| `parse/MdParser.ets` | Markdown | 标题/有序无序列表/引用/分隔线/**表格**/代码围栏；行内 **粗体**、`行内码`、[链接]；未配对符号原样输出 |
| `theme/Theme.ets` | 双主题 | 深空指挥舱 / 极简商务白 全量色板；`ThemeManager.apply(mode, systemDark)` 写 AppStorage `themeIsDark` |

### AppStorage 全局键

`themeIsDark` `themeMode` `configReady` `tokenRefreshTick`（设置重贴令牌→WebView 通道重登）`chatBackDepth`/`backPopTick`（返回协调）`onbStep`/`onbBackTick`（引导返回）`chatCreateTick`（跨页新建请求）`bottomAvoidPx`（手势条避让）`chatPrefill`（首页快捷任务预填）`homeHealthCache`/`homeSessionsCache`/`homeServerCache`（首页秒显缓存）`askTick`（dsh 交互列表变更）`chatSelectedId`（工作台当前选中会话）`askJumpId`/`askJumpTick`（横幅跳转会话）`reportBackDepth`/`reportBackTick`（报告 Tab 返回协调）`reportWindowUrl`/`reportWindowTick`（独立报告窗口换页下发）

---

## 5. 关键设计决策（ADR）

| # | 决策 | 理由 |
|---|---|---|
| ADR-1 | **WebView 降级为备用**：主体验走原生 RPC | 桌面版 dsh 网页在手机 WebView 里内容溢出、底部元素点不到；原生可控可美化。完整版保留于设置页 |
| ADR-2 | **草稿式新建（延迟创建）** | 立即 create 会产生空壳会话堆积；草稿页首条消息发出才 create（可带 cwd），不输入返回=零副作用 |
| ADR-3 | **归档=本机隐藏** | 实证：dsh 的归档是 web 端本地状态，`session/list` 全量返回。与官方同构：各端各管各的；长按隐藏 + 设置页恢复；防御性 `archived` 字段过滤保留 |
| ADR-4 | **乐观回显 + seq 增量追踪** | 手机→香港链路秒级延迟；发送瞬间本地回显（发送中…标记），chase 按 **最大 seq 比较 + 尾部合并**（兼容已翻历史），20s 高频窗口 + 30s 常规静默轮询 |
| ADR-5 | **三层 null 防御** | 服务器 JSON 大量显式 `null`（如 `modelSelection.lastUsed: null`）；undefined 判空不够。信封层/解析层/单条跳过——单条坏数据绝不放大为整页失败 |
| ADR-6 | **返回深度协调**（无路由栈） | 单 @Entry + 组件树切换，系统侧滑默认退出 APP。子组件同步深度到 AppStorage，`onBackPress` 消费式逐层弹出 |
| ADR-7 | **双通道认证一致性** | WebView（完整版）与原生 HTTP 各有 Cookie；重贴令牌/清除数据时两通道同步失效，避免状态分裂 |
| ADR-8 | **流式升级为 WebSocket，轮询降级为兜底**（v1 原决策"流式 lite"已被取代） | chunk wire 格式已逆向（源码级 + 真机实测）：`/api/remote.mux` mux 帧 + `session/follow`；打字机体验是质变（逐词 vs 2.5s 轮询）。轮询保留兜底（断流/竞态），seq 去重保证两路无缝。v1 服务器实时 chunk 是持久事件，v2 的 assistant-stream 活帧已做向前兼容 |
| ADR-9 | **图标程序化生成** | 内置浏览器大视口截图不稳定；Node 内 zlib 手写 PNG 编码器 + 像素数学，确定性输出可复现 |
| ADR-10 | **自动令牌端点：已设计、缓部署** | Cookie 持久化后其唯一价值=30 天一次的手动续期；安全边际（密码≈全权门票）不划算。到货提醒（ADR 见到期预警）替代 |
| ADR-11 | **会话列表新鲜度 + 工作区分组（web 侧边栏同构）** | 工作台组件常驻（Index 只切 Visibility），`aboutToAppear` 仅启动时执行一次——web/PC 端新建的会话此前永远进不了手机列表（"手机会话不全"根因）。修复：Index 切 Tab 下发 `curTab`，工作台 @Watch 静默重拉；30s 定时器在列表页也静默刷新（失败且已有数据不闪错误态）；`session/list` 的 `blank` 项与 web 端一致过滤。列表结构对齐 web「工作区」：`workspace/follow` 流首帧 baseline（DshStreamClient 临时 WS 连接一次性拉取 + 60s 缓存）给出工作区表与 `archivedSessionIds`——按工作区分组渲染（成员按注册表手动排序、未分组按 recency 殿后、点头部折叠），归档会话各端一致隐藏；基线不可用时退化为平铺富信息行 |
| ADR-12 | **dsh 主动交互（提问/审批）原生双 UI + 独立事件流** | 协议逆向自 web 插件源码并全链路实测（§3.6）。`DshEventClient` 用独立常驻 WS 连接承载 `$events` 流，不与 `DshStreamClient` 的会话 follow 互相牵连（follow 生命周期绑会话页，提问必须全局可达）；pending 列表放服务层 + `askTick` 广播，对话页弹卡（输入区上方）与 Index 全局横幅（跨页可达、点击跳会话）两级呈现；「去网页处理」走 `next` 让位语义，与 web 多端竞速模型（先答者胜、他端收 cancel）天然兼容；重连后旧代条目 5s 宽限等重投递，未重投按陈旧丢弃（服务端新一代会重发未决 waterfall，web 刷新后卡片重现即同机制） |
| ADR-13 | **策略报告 = 浏览器式 WebView，会话链接拉起独立窗口** | 实测 `/reports/` 是 nginx autoindex 且**免 Basic Auth**（根路径才有 401），报告 HTML 自带 viewport 与完整浅色样式 → 落地页直接 WebView 直显 nginx 目录页（丑但可用，后续不佳再换原生目录导航），`darkMode(Off)` 防止强制反色破坏报告样式；会话内链接（Markdown 链接 + 裸 URL 自动链接化，`/reports/` 与 `/*.html` 站内路径也识别）同源 → **独立窗口**（第二 UIAbility，singleton + onNewWant 复用换页，不占会话 Tab 层级），外部链接 → 系统浏览器；认证双兜底：WebView `onHttpAuthRequest` 自动答 Basic + `DshApiClient.ensureWebCookie` 把原生 dsh Cookie 同步进 WebView 罐；Span 仅支持 onClick（无 onLongClick），链接复制走 ⋮ 菜单/地址胶囊点按 |

---

## 6. 踩坑记录（ArkTS / 鸿蒙 API）

**编译层**：
- Column 的 `alignItems` 参数是 `HorizontalAlign`（Row 才是 VerticalAlign）；Column 子元素**默认水平居中**（标题需显式 Start）
- `@Builder` 调用**不能链属性**（`.margin` 报 void）——外包一层 Column 再挂
- `throw` 只接受 Error 子类（`arkts-limited-throw`），联合可空类型先收窄
- 对象字面量必须锚定已声明 interface；`Record`→interface 的 `as` 强转不被信任（用类型化空常量）
- 嵌套函数改箭头闭包更稳；`catch` 必须带参数

**运行/API 层**：
- `@ohos.net.http` 的 `maxRedirects:0` **抛异常而非返回 3xx**——需要 303 响应体时不可用
- POST 请求体放 `extraData`，漏了就是空 body → 网关报 "body is not JSON"
- `HttpResponse.header` 是 Object：`(header as Record<string,Object>)['set-cookie']`，值可能是 string 或 Array
- 服务器 JSON 大量**显式 null**；`undefined !== null` 判空必须双防
- **Scroll 无界高度容器内禁止 `alignSelf(Stretch)` / `height('100%')`**——行高被解析到视口级 = 每行一屏高的"大空隙"（时间线连线因此改为纯圆点）
- 百分比 maxWidth + 内容自适应宽 = 宽度循环依赖 → 展开大屏文字溢出（卡片用定宽 100%）
- 系统 JSON-RPC 边界对字段**逐字校验**：多一层包装、字段名大小写、驼峰/短横线都会 400（`gateway/arguments-invalid` / `input-invalid`）
- **WS 握手**：`@ohos.net.webSocket` 的 `WebSocketRequestOptions.header` 支持 Authorization/Cookie 自定义头（wss 同源同凭证）；**Origin 绝不能传**——netstack 会自动追加按目标推导的 Origin，与显式值逗号合并成畸形头，dsh Origin 校验直接拒绝（`ws error 200` + netstack 日志 `HS: ws upgrade response not 101`）；netstack 的 connect 回调在 **TCP 连上即触发**（并非 101 之后），连接成功不能作为握手完成依据；'error' 与 'close' 可能连发，回调里用 socket 身份比对 + 局部 done 标记防重复调度；流级 `end`/`error` 帧要当作断线处理（重连后 snapshot 补缺口）；Cookie 进握手头前必须清掉 `\r\n\t`（持久层恢复值可能带噪声，打碎报文即 400）
- **WS 诊断手法**（本坑定位全过程，可复用）：`hdc rport tcp:3092 tcp:3092` + PC 起一个逐字记录升级请求的 Node 服务器 + app 临时连 `ws://127.0.0.1:3092`，即可拿到手机发出的原始握手头；netstack 自身日志（hilog 过滤 NETSTACK）会给出 lws 失败原文；`ws error 200` 是 `WEBSOCKET_CONNECTION_ERROR` 的 JS 侧通用码，无信息量，别在这里猜
- **WS 流式竞态**：轮询 chase 会用 `generating` 覆盖 typing——流健康时必须跳过该赋值，否则 turn/end 清指示后又被轮询置回（闪烁）；快照重放的旧轮次事件靠 view 层 seq 去重 + 客户端重放缓冲（generating 判定后才交付）避免 UI 闪旧内容
- **generating 判定必须计入 turn/end**：失败轮次无 assistant/message、chunk 不压缩，只比 chunk/content seq 会把已结束轮次永远判成"生成中"（药丸卡死）；正确式：`maxChunkSeq > maxContentSeq && maxChunkSeq > maxTurnEndSeq`
- **@Builder 按值传对象参数不响应更新**：分支首次渲染即捕获参数，之后整对象重赋值不触发 @Builder 内刷新（流式卡冻结在首帧内容）——依赖刷新的动态内容必须直接读 `this.xxx` @State（字符串最可靠），或换键重建
- **ForEach 同键不刷新**：正在"生长"的内容（流式 Markdown 段落）key 不含内容长度时复用旧节点、永远冻结——键附加内容长度让生长块换键重建、稳定块照常复用
- **ForEach 键**：条目对象字段原地改（如 tool.resultText 回填）不会触发重渲染——键里带上结果态（'R'+seq）让它换键重建

**工具链**：
- 构建：见 README；`DEVECO_SDK_HOME` 指向 DevEco 自带 sdk，java 用 DevEco 自带 jbr
- PowerShell 脚本文件**别写中文注释**（无 BOM 时按 GBK 解析会吞行）
- PC 直连香港服务器不稳，开发期走本地代理（`curl -x http://127.0.0.1:10808`）；手机直连
- 内置浏览器大视口截图不稳定 → 图标等资源用程序化生成

---

## 7. UI 规格速查

- 内容栏：860 居中（顶栏/消息/输入三段同宽）；消息区再嵌导轨（18vp）+ 12 间距
- 内边距体系：AI 卡片 20/14；思考/工具条 18/12；终端块 14；气泡 20/14；轮次徽章 14/6
- 行高：正文 23（15 号）、思考 18（12 号）、终端 18（12 号）
- 输入框左缘 = 消息内容左缘（30vp 导轨占位）；发送键右缘 = 气泡右缘
- 长文折叠阈值 300 字；思考过程默认折叠成"字数"提示条
- 主题令牌见 `Theme.ets`（bgGrad/bgCard/border/text×3/accent/accent2/onAccent/success/warn/danger/term×2/navActiveBg/shadow）

---

## 8. 路线图（剩余）

1. ~~WebSocket 逐字流~~ ✅ **已完成**（协议契约见 §3.5；`DshStreamClient` + 流式打字机卡；轮询保留为断流兜底）
2. ~~dsh 主动交互（提问/审批）~~ ✅ **已完成**（协议契约见 §3.6；`DshEventClient` + 对话页卡片 + 全局横幅）
3. 会话搜索（`session/search`）、fork（`session/fork`）
4. 图片在历史消息中的内联渲染（现仅 🖼 标记）
5. 自动令牌端点部署（脚本已备，按需启用）
6. 时间线连线（需逐行测量高度的安全实现）
7. Cookie 到期提醒已上线；自动端点部署后可移除
8. 提问/审批在对话历史中的回放渲染（waterfall 是瞬态事件不落 session/page，需单独持久化本机作答记录）
