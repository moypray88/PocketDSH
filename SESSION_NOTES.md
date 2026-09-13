# PocketDSH 修复任务 · 现场交接笔记

> 更新：2026-09-13（晚）。新增：新建任务可选「模式」（Agent 预设）与「模型」——协议逆向自 dsh web 前端源码。
> 此前完成：策略报告浏览器（Tab + 会话链接独立窗口 + 精品收藏）。全部构建通过（signed hap 产出）。剩余：真机回归。

## 2026-09-13 新建任务模式/模型选择（本轮新增）

- 协议（源码级确认，未实测）：
  - 模式 = **Agent 预设**：`agentPresets/list`（空 args）→ `{presets:[{id,trust,isDefault,name?,description?,broken?}]}`；`agentPresets/select` args **直传** `{"agent":<sessionId>,"agentPreset":<presetId>}`（typert named wire args：参数名即键，与 `$events/result` 同构）；**仅空白会话可用**，之后报 `agent-preset/locked`
  - 模型 = 既有 `session/selectModel`（web 对空白会话同样直接调用）；草稿页复用模型目录浮层
- App 实现：草稿页新增「模式」「模型」两行 → 预设浮层（默认行 + 名单，broken 过滤在仓库层）/ 复用模型浮层（applyModel 草稿分支只暂存不 RPC）；sendDraft 链路 create → presetSelect → selectModel → sendText；失败走既有「会话已建、发送失败」分支（文本退回输入框）
- 已知限制：预设/模型应用失败时消息不发出，重发会按服务器默认（重新进草稿可重选）；`reasoningEffort`（推理力度）未接入

## 真机回归清单（新增项）

- 新建任务页重排版：页头压缩为单行、模式/模型选择片在输入框上方（合盖态免滚动全可见）；选择片点击弹出对应浮层、选定后文案即时更新
- 底栏 4 项（首页/会话/策略报告/设置，无新建）；展开态左侧栏「新建对话」保留；会话列表页「新建」入口正常
- 策略报告 Tab：每次点进（从其他 Tab 切入、或原地再点）都回到 /reports/ 目录首页；Tab 内继续浏览时侧滑/‹ 仍逐页后退
- 新建任务页出现「模式」「模型」两行；模式浮层列出服务器预设（标准/PTC/极简…带「默认」角标）；选定后文案更新
- 选模式/模型后发送：会话创建且首轮回复体现所选模式与模型（对照 web 端同选项行为）
- 不选直接发送：行为与之前完全一致
- 精品收藏：☆ 收藏当前报告（标题取页面 title；nginx 目录页 "Index of /…" 自动转为路径名）→ 重启 App 后 ⋮「我的收藏」仍在 → 点条目直达、✏️ 重命名（对话框预填旧名）、🗑 删除；已收藏页 ☆ 呈金色，再点取消；Tab 与独立窗口收藏互通；旧收藏里名称是链接的条目可用 ✏️ 手工改名

## 2026-09-13 策略报告浏览器（本轮新增）

- 「▦ 策略报告」第 5 导航项（合盖底栏/展开侧栏）：ReportView → ReportBrowser 组件直开 `{server}/reports/`（nginx autoindex，实测免 Basic Auth；darkMode Off 防反色破坏报告样式）
- 会话内链接可点（Span onClick；Span 无 onLongClick）：同源/`/reports/`/`/*.html` 站内路径 → 独立窗口 ReportViewerAbility（singleton，onNewWant 换页复用）；外链 → `openLink` 系统浏览器；裸 URL 自动链接化在 MdParser.parseRuns（新增 scanBareUrl/isUrlChar）
- 认证兜底：WebView onHttpAuthRequest 自动答 Basic + `DshApiClient.ensureWebCookie()` 同步原生 dsh Cookie 进 WebView 罐（configCookieSync）
- 返回协调：报告 Tab 走 `reportBackDepth/reportBackTick`（webview 可后退则后退）；独立窗口页自管（可退→后退，否则 terminateSelf）
- 坑：promise `.catch((_e) =>)` 参数是隐式 any（try/catch 的 catch 不受限）→ 显式 `(_e: Object)`；`showActionMenu` buttons 是定长元组 → 固定三钮（第三钮 Tab=回首页/窗口=关窗）；`import { Want }` 具名导入报错 → 默认导入
- 精品收藏（09-13 三轮）：`service/ReportFavorites.ets`（preferences `report_favs`，title 优先 document.title、退化文件名）；ReportBrowser ☆ 收藏当前页 + ⋮「我的收藏」底部抽屉（点开直达/🗑删除）；动态态按钮（‹›/☆）从 @Builder 值传参改内联直读 @State（规避 §6 已知坑）
- Review 修复（09-13 二轮）：裸 URL 中文文件名截断（`…/生猪周期监测.html` 会在中文处断链）→ scanBareUrl 中文并入逻辑（仅 http/reports 开头 + 右侧收敛出文件扩展名才接受）；nginx autoindex 无 viewport → Web 加 `overviewModeAccess(true)` 缩放至屏宽
- 已知限制（按需再做）：非 HTML 资源（PDF/CSV）无下载处理，点击无反应；target=_blank 链接行为未定义；autoindex 无样式，深色主题下白底属预期

## 真机回归清单（新增项）

- 底栏/侧栏「▦ 策略报告」打开 /reports/ 目录页；点目录进子级、点 .html 打开报告；‹›/↻/⋮ 菜单可用；地址胶囊点按复制
- 会话中 Markdown 链接与裸 URL（如 `https://dsh.goldclew.com/reports/industry-analysis/生猪周期监测.html`）点击 → 独立窗口打开；外部链接 → 系统浏览器；连点两个不同链接同一窗口换页
- 独立窗口 ✕ 关闭、侧滑返回（可后退→后退，无历史→关窗）；报告 Tab 侧滑：webview 有历史先退页，无历史退出应用
- 深浅双主题下工具条/错误卡观感；断网时报告页呈现「页面加载失败」重试卡
- 主题对比度（09-13 修复）：收藏行改为描边透明底、地址胶囊/重命名输入框深底配 termText——浅色主题下不再出现深底黑字；回归时重点过一遍浅色主题的收藏抽屉/地址胶囊/重命名对话框
- 精品收藏：☆ 收藏当前报告（标题取页面 title；nginx 目录页 "Index of /…" 自动转为路径名）→ 重启 App 后 ⋮「我的收藏」仍在 → 点条目直达、✏️ 重命名（对话框预填旧名）、🗑 删除；已收藏页 ☆ 呈金色，再点取消；Tab 与独立窗口收藏互通；旧收藏里名称是链接的条目可用 ✏️ 手工改名
- 报告页内点击外部网页链接：在当前浏览器视图内打开、返回键回到报告（target=_blank 亦同，multiWindowAccess 默认本地窗口语义）

## 当前状态

- ✅ App：策略报告浏览器 + 此前三功能代码完成
- ✅ App：构建通过（signed hap 产出）
- ✅ App：架构评审修复（2026-09-12，见下节）
- ⬜ 真机回归（含上方新增项）

## 2026-09-12 架构评审修复清单（App：WorkspaceChatView.ets）

1. sendDraft 失败路径分阶段：创建失败留在草稿页保留输入；已创建但发送失败清回显、文本退回输入框
2. 会话切换竞态：新增 viewGen 代际计数，reloadHistory/chaseNewMessages/loadOlder 回写前校验
3. openSession 先 detachStream 再加载（防旧会话事件污染），加载后校验 selectedId 再 attachStream
4. pickImage fd 用 try/finally 保证关闭（原先 stat/read 抛异常会泄漏）
5. hideSession 隐藏当前会话时断流 + 停轮询 + 清回显
6. sendCurrent 发送在途切走会话时不再清新会话输入框
7. P2：openSession 清待发附件（不跨会话携带）；wsPicker 选项关闭浮层时清自定义输入残留；
   图片 ForEach key 改 `i+id`；静态助手卡 md 块 key 统一走 mdKey()；删重复 setBackDepth

## 2026-09-12 服务端修复（_ref\dsh-src\deepseek-harness-master，未 typecheck）

`packages\api\session-controller\src\commands.ts` readImage()：
1. 有界读取：readFile → open+handle.read（stat 大小+1 上限，超限拒；防 TOCTOU 无界读）
2. 根路径 workspace 修复（workspace.path 以分隔符结尾时不再拼出 `//` 导致 deny-all）
3. 相对路径输入 → `gateway/bad-request`（原先误报 image-invalid）
4. 宿主 fs 故障 → `gateway/internal`（对齐 attachment() 惯例，原先伪装成 image-invalid）
5. 包 README.md / README.zh.md 激活策略句补 readImage

**服务端部署前必做**（需 Node ^22.19/>=24 + pnpm 11.7 环境）：
- `pnpm install && pnpm typecheck`（本轮改动未跑过 typecheck）
- `pnpm run gen-cordis-catalog` 再生成文档（docs/subsystems/session.md 的生成块未含 readImage，doc-sync 门禁会红）
- 建议补 `session-read-image.host.spec.ts` 测试：前缀混淆（/ws/a vs /ws/ab）、symlink 逃逸、`..`、
  大小写扩展名、无扩展名、目录、超限、工作区外路径
- 部署后用 `_ref\dsh-src\probe-rpc.ps1` 模式 POST /api/session/readImage 验证白名单

## 已改文件清单

### dsh 服务端（D:\workspace\_ref\dsh-src\deepseek-harness-master）

1. `packages\api\session-controller\src\types.ts` —— RemoteErrorDetailsMap 新增
   `'session/image-invalid': { reason }`、`'session/image-denied': { path }`；
   新增 `SessionReadImageRequest { path }`、`SessionReadImageValue { mediaType, bytes, data }`
2. `packages\api\session-controller\src\commands.ts` —— 常量 + readImage() 实现（本轮已加固）
3. `packages\api\session-controller\src\index.ts` —— `@Remote('readImage')` 委托
4. `packages\api\session-controller\README.md` / `README.zh.md` —— 激活策略句补 readImage

### App（D:\workspace\PocketDSH）

1. `entry\src\main\ets\parse\MdParser.ets` —— MdKind.Image；`![alt](src)` 行内/独立行、
   裸本地路径识别；导出 `imageExtOf()`
2. `entry\src\main\ets\model\SessionVms.ets` —— ChatEntryVm 加 `images: string[]`
3. `entry\src\main\ets\service\DshSessionsRepository.ets` —— wire 类型 + `readImage()/readAttachment()`
   + `collectImageIds()`；`createSession(ctx, workspaceId, cwd, workspacePath)`（workspaceId 归组）
4. `entry\src\main\ets\service\DshStreamClient.ets` —— `onUserMessage`/`onAssistantMessage` 带 images
5. `entry\src\main\ets\service\DshImageCache.ets`（新）—— 取图落盘缓存（cacheDir/mdimg/）、inflight 去重
6. `entry\src\main\ets\views\ChatImageView.ets`（新）—— MdImageView / AttachmentImageView（三态+重试+点按）
7. `entry\src\main\ets\views\WorkspaceChatView.ets` —— 图片渲染/复制/归组 + 本轮架构修复
8. `build-profile.json5` —— 签名证书路径 `D:/workspace/手机证书/`

## 真机回归清单

markdown 图片与本地路径图片显示、点图全屏、历史消息复制按钮、用户气泡/错误卡长按复制、
分区「＋」新建会话落在正确工程分区、发送图片回显真图、发送失败后输入可重试、快速切换会话无串扰。

## 关键背景（已探明，勿重复探索）

- 服务端把会话挂进工作区的唯一途径是 session/create 传 workspaceId（与 cwd 互斥）；
  workspace.attachSession 用 realpathNormalize 严格相等匹配。工作区基线 60s 缓存，
  新建会话后必须 refreshList(true) 才能立即归组。
- 消息内图片块 wire 格式：`{type:'image', attachment:{attachmentId, mediaType, ...}}`；
  字节要再调 `session/attachment`（服务端校验该会话日志引用过）。
- readImage 授权粒度是「任意已注册工作区」（与 attachment 的「该会话引用过」不同），
  单用户网关可接受；details.path 会回显 canonical 路径（存在性预言机），多客户端部署需评估。
- App 是 HarmonyOS ArkTS，无 lint/test 基建，只能 DevEco/hvigor 编译验证。
- 构建：README.md「命令行构建」节（DEVECO_SDK_HOME + hvigorw assembleHap）。
