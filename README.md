# PocketDSH

<p align="center">
  <img src="design/icon_preview_fg.png" width="128" alt="PocketDSH">
</p>

**PocketDSH** —— 运行在华为阔折叠手机（HarmonyOS）上的 DeepSeek Harness（dsh）远程指挥台。

随时随地：查看服务器上的 AI 会话、下达新任务（支持图片）、切换模型、监控运行状态——30 天免登录，折叠屏双态适配。

> 架构设计、协议契约与踩坑记录见 [design/ARCHITECTURE.md](design/ARCHITECTURE.md)（新会话/新成员必读）。

---

## 功能总览

### 🔐 认证（一次配置，30 天无感）
- 三步引导：服务器地址 → 账号密码 → dsh 令牌（自动校验）
- 令牌一次性换取 30 天签名 Cookie；**Cookie 加密持久化，跨 APP / 跨 dsh 重启均有效**
- 401 自愈、WebView/原生双通道一致性、到期前 5 天首页预警

### 💬 原生工作台（主力体验）
- **会话列表**：服务器真实会话、搜索、运行状态呼吸点、相对时间、长按重命名（服务器级）/本机隐藏
- **对话历史**：完整事件流渲染——用户气泡、AI 卡片（思考过程/正文/用量）、工具调用（参数+终端风结果）、轮次徽章、时间线圆点导轨
- **发送任务**：乐观回显（秒显）→ 静默增量追踪回复；支持 **图片附件**（base64 直嵌）；"dsh 正在输入…"生成指示
- **模型切换**：顶栏胶囊一键拉取服务器模型目录并切换
- **新建任务**：草稿式页面（不输入不创建会话），支持选择工作目录（默认/最近使用/自定义）
- **折叠适配**：展开态双栏（左栏可收起最大化对话）+ 合盖态单栏两级导航，侧滑返回逐层回退

### 🏠 连接中心（首页）
- 服务器健康卡（在线状态/延迟/最近检测，静默定时刷新）
- 「＋ 新建任务」一键直达
- 近期会话真实数据卡片
- 登录态到期预警

### 🎨 体验细节
- **双主题**：深空指挥舱（深）/ 极简商务白（浅），可跟随系统
- **Markdown 渲染**：标题、列表、引用、分隔线、表格、粗体、行内代码、链接、代码块（终端风）
- **三级折叠**：思考过程 / 长回复（>300字）/ 工具调用 默认折叠，点开即展
- 完整版控制台：WebView 内嵌 dsh 官方网页（设置页入口，备用）

---

## 架构一览

```
UI 层        Index(外壳/返回协调) · 首页 · 会话+对话 · 设置 · 引导 · WebView完整版
服务层       DshApiClient(RPC+认证自愈) · SessionsRepository(解析) ·
             ConfigStore · SecureStore(资产库) · HealthMonitor
基础         Theme 双主题令牌 · MdParser 轻量 Markdown · 视图模型契约
服务器       nginx(Basic Auth) → dsh web（RPC + 令牌/Cookie 认证）
```

详细分层、协议契约、ADR 决策记录 → **[design/ARCHITECTURE.md](design/ARCHITECTURE.md)**

---

## 构建与运行

### 环境要求
- DevEco Studio（含 HarmonyOS SDK，工程目标 API 24 / SDK 6.1.1）
- 华为账号（自动签名）+ 折叠屏真机或模拟器

### 命令行构建

```bat
cd /d D:\workspace\PocketDSH
set "DEVECO_SDK_HOME=D:\programs\DevEco Studio\sdk"
set "PATH=D:\programs\DevEco Studio\jbr\bin;D:\programs\DevEco Studio\tools\node;%PATH%"
"D:\programs\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（日常建议直接 DevEco 点 Run，自动签名安装）

### 服务器前置条件

1. 云主机运行 `dsh web`（建议 systemd 托管，本工程假设单元名 `dsh-web.service`）
2. nginx 反代 + Basic Auth（APP 的用户名密码即此层凭据）
3. 首次登录需要 dsh 启动时打印的令牌 URL：

```bash
sudo journalctl -u dsh-web.service --no-pager | grep -oh 'https\?://[^ ]*token=[^ ]*' | tail -1
# 输出的 127.0.0.1:3080 换成你的公网域名后，在 APP 设置里粘贴
```

### 可选：全自动令牌续期

部署"自动令牌端点"后，连 30 天一次的令牌更新都不再需要（脚本见 ARCHITECTURE.md §8 / 历史会话）。当前采用"到期前 5 天首页预警 + 手动粘贴"的轻方案。

---

## 工程结构

```
entry/src/main/ets/
├── pages/Index.ets          外壳：4 Tab、折叠断点、返回深度协调
├── views/
│   ├── WorkspaceChatView    会话列表 + 对话（主力，最大文件）
│   ├── HomeView             连接中心首页
│   ├── OnboardingView       三步引导
│   ├── SettingsView         设置
│   └── WorkspaceView        WebView 完整版控制台（备用）
├── service/
│   ├── DshApiClient         RPC 客户端（信封/Cookie 四源/401 自愈）
│   ├── DshSessionsRepository  wire→视图模型（三层 null 防御）
│   ├── DshConfigStore       偏好持久化 + 本机隐藏
│   ├── SecureStore          系统资产库加密存储
│   └── HealthMonitor        健康探针
├── model/                   DshTypes（全局键/常量）· SessionVms（视图模型）
├── parse/MdParser.ets       轻量 Markdown 解析
└── theme/Theme.ets          双主题令牌
design/                      视觉稿源文件 + ARCHITECTURE.md + 图标预览
```

---

## 开发须知（高频坑位速查）

完整清单见 ARCHITECTURE.md §6，最常踩的几条：

- ArkTS：Column 的 `alignItems` 用 `HorizontalAlign`；Column 子元素默认水平居中；`@Builder` 不能链属性；`throw` 仅限 Error 子类
- 服务器 JSON 有大量显式 `null`——判空必须 undefined/null 双防
- `@ohos.net.http`：POST body 放 `extraData`；`maxRedirects:0` 会抛异常
- Scroll 无界高度里禁用 `alignSelf(Stretch)` / `height('100%')`（行高会被撑爆）
- dsh 协议：发送只用 `session/prompt`（`commands/execute` 是假通道）；用户消息只渲染 `source.kind==='user'`

---

## 路线图

- [ ] WebSocket 逐字流（打字机效果，替代轮询）
- [x] ~~图片附件~~ · ~~模型切换~~ · ~~停止生成~~ · ~~重命名~~ · ~~草稿式新建+工作目录~~ · ~~Cookie 持久化~~ · ~~到期提醒~~ · ~~Markdown 表格/链接~~
- [ ] 会话搜索 / fork（协议已确认）
- [ ] 图片在历史消息中的内联渲染
- [ ] 自动令牌端点部署（脚本已备，按需启用）

---

## 致谢与说明

- 基于 [DeepSeek Harness（dsh）](https://github.com/deepseek-ai/deepseek-harness) 的开放 Web 通道构建，感谢 DeepSeek 团队的开源推进
- 本项目为个人自用工具，凭据仅存储于本机系统资产库，不上传任何第三方
