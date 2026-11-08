# Shion（紫苑）

macOS 上的私人秘书。你主要和总秘书「紫苑」打交道，她带着一组助手（课程、通勤、邮件、资讯、回顾）处理学习、工作和生活里的事；每个助手的对话也可以单独打开。

背后跑的是部署在 VPS 上的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)，Shion 通过 Canonical Gateway Protocol 连接它，完全取代官方桌面端的 Bot Mode。

> 现阶段：`prototype/` 是 UI 原型（React，示例数据，可交互），用来对齐界面和流程。正式的 App 不套浏览器，倾向用 SwiftUI 写（备选 MyGo）。

## 已经定下来的

| 问题 | 决定 |
| --- | --- |
| 和官方 Hermes Desktop 的关系 | 完全取代它的 Bot Mode |
| 组织方式 | 一个总秘书带一组助手；每个助手的 Bot Chat 也能单独访问 |
| Hermes 跑在哪 | 远端 VPS；以后可能也接入这台 Mac，让助手在本机做事（暂不实现） |
| 技术栈 | 原型不限；正式版不套浏览器，候选 SwiftUI 或 [MyGo](https://github.com/egoist/mygo)（Go，自绘原生 UI），倾向 SwiftUI，见下文 |
| 连接方式 | 沿用现在的 Cloudflare Tunnel + Cloudflare Access，用 service token 过认证（官方桌面端也用同样的方式：给连接加额外请求头） |
| 云桌面 | VPS 上的 Hermes 开了 Bot Screen（每个助手一块桌面），Shion 里要能看画面、接管、交还 |
| 委派方式 | 看板为主：紫苑建卡交给助手，助手在单独的工作会话里完成；一问一答的小事才用助手之间的直接消息 |
| 邮件 | 一个能收发大多数邮箱的工具：Hermes 自带的 himalaya 技能（IMAP/SMTP）加 email-inbox-triage 技能 |
| 日历、提醒事项 | Apple 的，经 iCloud 云端接入 |
| Notion | 主要放课程相关的内容（录音转写、笔记） |
| 课表 | 放在日历里；以后再接 Moodle、学校教务系统 |
| 地区 | 东京（通勤数据按日本的电车、巴士） |
| 首批场景 | 邮件、日程、待办；通勤路线与延误；课后整理录音成待办；课程提醒；每日安排与催促；应用使用记录与每日回顾；事实核查；新闻和学习/工作/生活日报 |

## 架构

```
┌──────────── 这台 Mac ────────────┐            ┌──────────────── VPS ─────────────────┐
│ Shion.app (SwiftUI)              │ Cloudflare │ hermes serve / gateway owner          │
│  ├ 窗口：今天 · 待办 · 日程 · 日报 │ Tunnel +   │  ├ Canonical Gateway Protocol (WS)    │
│  │       等你确认 · 各助手 Bot Chat │ Access     │  ├ profiles = 紫苑 + 各助手            │
│  ├ 云桌面：看画面、接管、交还       │            │  │   各自的 SOUL、记忆、技能、MCP、凭据   │
│  ├ 菜单栏常驻 + ⌥Space 随手交代     │            │  ├ Bot Screen：每个助手一块 Xfce 桌面   │
│  ├ 系统通知（可直接在通知里回复）   │            │  ├ cron = 各助手的例行任务             │
│  └ 应用使用记录（只记应用名和时长） │            │  ├ kanban = 交给助手的事                │
└──────────────────────────────────┘            │  └ shion 插件：待办、日报、应用记录的存取 │
                                                 └──────────────────────────────────────┘
```

**Shion 不做"聪明"的部分。** 理解、拆解、提醒的时机、写日报，都由 VPS 上的 Hermes 助手完成，Mac 合上了也照常运行。Shion 负责三件事：
1. 把这些结果做成好用的界面；
2. 在你需要拍板时打断你（通知、菜单栏、等你确认）；
3. 提供 VPS 拿不到的本机数据（目前只有应用使用记录）。

**为什么要一个 `shion` Hermes 插件。** Canonical 协议是围绕会话（对话）设计的，没有"列出待办""读日报"这类方法。Hermes 官方的扩展方式是插件 RPC：插件用 `ctx.register_rpc` 注册 `plugin.shion.<name>`，用 `ctx.emit_to_session` 推送事件，客户端从 `runtime.describe` 的 `plugin-rpc-v1` 能力判断可用。待办、今天的汇总、日报、应用记录上传都走这里。助手们操作同一份数据（同一个插件里的工具），这样你在 Shion 里看到的和助手看到的是同一份。

## 委派：看板为主，消息为辅

紫苑把事交给助手，默认走 **Hermes 看板**，不是聊天消息：

- 紫苑开着 `kanban` 工具集（`hermes -p shion tools enable kanban`），在自己的 Bot Chat 里用 `kanban_create(assignee=…, body=…, parents=…)` 建卡。最好把她的工具限制在看板、记忆、日程这些调度工作上，她只拆事、不亲自干活。
- 派发器为每张卡在负责助手名下起一个**工作会话**（worker session），和这个助手的 Bot Chat 分开。助手用 `kanban_heartbeat`、`kanban_complete`、`kanban_block` 汇报进度和结果。
- **评论**是交接信息的渠道：卡片每次重新运行，助手都会读完整的评论串。你补充信息、解除阻塞，都是在卡片上留评论。
- 卡片完成或阻塞时，紫苑会被叫醒（`kanban.auto_subscribe_on_create`，默认开启），她在 Bot Chat 里告诉你结果、问你要不要调整。
- 卡片之间可以有依赖（`parents`）：前一张完成后，后一张自动从「排队」变成「就绪」。

**适合用看板的事**：要花时间、有交付物、可能卡住要人帮忙、需要留记录的事，比如课后整理、下载课件、核实消息、做复习卡片。

**`message_agent`（Bot Mode 里助手之间直接发消息）** 只用于一问一答的小事，比如"通勤，明天几点出门？"。消息落在对方的 Bot Chat 里，没有状态可追踪，来回次数也有上限（`gateway.bot_loop_guard.max_hops`，默认 4）。

Shion 里的对应：
- 紫苑的对话里，每张卡显示成一个会实时更新状态的卡片；
- 「看板」页分四列：排队、进行中、等你、完成。点开卡片可以看评论、运行记录和工作记录，也能解除阻塞；
- 每个助手页顶部有标签：Bot Chat，加上它今天跑过的每张卡的工作记录；
- 卡在要人做的步骤时（`kanban_block`，类型 `needs_input`，比如两步验证），会出现在「等你确认」。你在云桌面上处理完、交还后，Shion 自动留评论并解除阻塞，派发器重新运行这张卡。

看板接口：`/api/plugins/kanban/board`、`/tasks/:id`、`/tasks/:id/comments`、`PATCH /tasks/:id`，实时更新走 `/api/plugins/kanban/events?since=<id>`。都要带 Access 的头和 Hermes 的 token。

## 场景由谁负责

| 场景 | 助手 | Hermes 侧 | Shion 里看到的 |
| --- | --- | --- | --- |
| 邮件 | 邮件 | himalaya（IMAP/SMTP，大多数邮箱都能接）+ email-inbox-triage，例行整理收件箱 | 发出前到「等你确认」；需要处理的变成待办 |
| 日程 | 紫苑 | iCloud 日历（CalDAV，应用专用密码） | 日程（周视图）、今天的时间线 |
| 待办 | 紫苑 | `shion` 插件存储，执行日期与截止日期分开；是否和 Apple 提醒事项同步见下面的风险 | 待办、菜单栏、今天 |
| 通勤路线、延误 | 通勤 | 已有的交通 MCP；按日程生成出门提醒 | 今天的通勤卡片、通知、菜单栏 |
| 课后整理 | 课程 | Notion MCP 读录音转写；按课表在课后触发 | 新待办先标"待确认日期"，在等你确认里定日期 |
| 课程提醒 | 课程 | 按日历里的课表生成例行任务；以后从 Moodle（iCal 订阅、Web Service）和教务系统补充作业截止 | 通知、菜单栏的"下一件" |
| 每日安排与催促 | 紫苑 | 早报、12/18/21 点催促、睡前排明天 | 今天页顶部的一段话、通知 |
| 应用记录与回顾 | 回顾 | 插件接收记录，22:30 写日报 | Mac 端采集；日报里的屏幕时间 |
| 事实核查 | 资讯 | 网络搜索与网页读取 | 对话；新闻日报里的核查标注 |
| 新闻 / 学习 / 工作 / 生活日报 | 资讯、回顾 | 例行任务生成 | 日报页 |
| 要登录、两步验证、验证码的网站（学校统一认证、Moodle、教务） | 课程等 | 助手在自己的云桌面上用浏览器操作；登录状态保留在它的浏览器里 | 「等你确认」里出现「去接管」，在云桌面页接管、登录、交还 |
| 全天录音（以后） | 新助手 | 转写 → 记忆 → 待办 | 暂不做 |

**关于日报放不放进 Shion：** 生成不放在 Shion，交给 Hermes 的例行任务：Mac 关着也能按时写，还能同时推到手机（Telegram 等平台）。Shion 只负责阅读界面，再加上提供应用使用记录这一份 VPS 拿不到的数据。

## Canonical Gateway Protocol 要点（写 Swift 客户端时用）

依据 Hermes `main`（2026-11）的 `apps/desktop/docs/canonical-gateway-protocol.md`、`tui_gateway/contracts/canonical*.py` 和生成的 `apps/shared/src/gateway-contract.generated.ts`。

- **连接**：WebSocket `/api/ws`，子协议 `hermes-gateway-v1`，方法表是 `CANONICAL_METHODS`。连上后先 `client.capabilities {server_requests: true}`，否则审批和提问会被直接撤回。
- **鉴权**：本机由 profile 目录下的私有 control socket 签发一次性 ticket（30 秒）。远端经 Cloudflare Access，再加可选的 Hermes 会话 token（见下一节）。
- **身份**：`session.create` 带 `source`（必须在 `runtime.describe` 的 `session_create.sources` 里）和 `client: {name: "shion"}`。
- **Bot Chat**：一个助手 = 一个 profile = 唯一一个标题为 `Bot Chat` 的会话。用 `session.list {title, include_hidden: true}` 按标题找，`profiles.list` 也直接给出 `canonical_session`。不存会话 id 指针。
- **可靠提交**：客户端的 `input_id` 和服务端的 `admission_id` 分开，以回执为准（`prompt.receipt`、`prompt.resolve_unknown`）。
- **审批、提问**：回复要对准 `prompt_id` 和 `execution_generation`；断线重连后用 `session.events.since` 恢复还没回答的请求。
- **不在 canonical 里的**：看板走 `/api/plugins/kanban/*`，例行任务列表走 `/api/cron/jobs`（canonical 里只有 `cron.submit` 立即运行和 `cron.status`）。
- **类型生成**：`apps/shared/src/gateway-contract.openrpc.json` 可以生成 Swift `Codable` 类型，不用手写。

## 连接远端：Cloudflare Tunnel + Access

VPS 上的 `hermes serve` 通过 Cloudflare Tunnel 暴露成一个 HTTPS 域名，前面挡着 Cloudflare Access。Shion 用 Access 的 service token 通过认证：

- **每个请求都带两个头**：`CF-Access-Client-Id`、`CF-Access-Client-Secret`。普通 HTTP 请求要带，WebSocket 的握手请求也要带，包括对话用的 `/api/ws` 和云桌面用的 `/api/display/ws`。官方桌面端的做法一样：每个连接可以加"额外请求头"，界面上写明就是给 Cloudflare Access 用的。
- **Hermes 自己的登录**：现在两道门都开着，外面是 Cloudflare Access，里面是 Hermes 的会话 token（`HERMES_DASHBOARD_SESSION_TOKEN`）和登录。Shion 两组凭证一起带：REST 加 `X-Hermes-Session-Token`，`/api/ws` 和看板的 `/events` 加 `?token=`。
- **凭证存放**：service token 和会话 token 存进 macOS 钥匙串。官方桌面端存在 Hermes 目录下一个权限 0600 的明文文件里。
- **为什么用原生 WebSocket**：浏览器里的 Webapp（包括云桌面）能正常连，是因为浏览器先走了 Access 的登录，之后靠 Access 的 cookie 过关。网页里的 WebSocket 不能自定义请求头，用不了 service token。原生 App 用 `URLSessionWebSocketTask`，每个连接都能直接带上 service token 的两个头，不需要浏览器登录那一步。

## 云桌面（Bot Screen）

VPS 上每个助手（profile）有自己的一块 Xfce 桌面：助手的 `computer_use` 和有界面的浏览器都在这块桌面上操作，画面留在 VPS 上，你的 Mac 关了也不影响。遇到登录、两步验证、验证码、付款这类步骤，助手会停下来请你接管。你接管期间，助手的桌面和浏览器操作都会被拒绝（`human_has_control`）；你交还后它接着做。助手的浏览器登录状态会保留，你帮它登录过一次的网站，之后它可以自己用。

Shion 里的位置：
- **云桌面页**：所有助手的桌面缩略图，加一个大的实时画面，可以启动、接管、交还；
- **每个助手的侧栏**：一块桌面预览，点开进入云桌面页；
- **等你确认、系统通知**：助手卡在要人来做的步骤时，出现「去接管」。

接管和交还的操作：
- **点大画面就接管。** 缩略图和侧栏预览只负责打开大画面，点它们不会接管。助手正在这块桌面上干活时，第一下只提示「再点一次接管」，免得看一眼就打断它；它停下来等你，或者本来就空闲时，点一下就接管。
- **点画面外面就交还，有 3 秒缓冲。** 点到 Shion 里画面以外的地方，画面下方出现倒计时，3 秒内点回画面就取消。这样登录到一半误点了别处，也不会把控制权丢给助手。
- **切到别的 App 不交还。** 比如去验证器 App 或手机上看验证码。窗口失去焦点不算"点外面"，这一点和断线时控制权仍在你手里的语义一致。
- **离开这个画面就立刻交还**，比如切到别的页面或别的助手，和官方关掉画面面板时的行为一样。
- 「接管」「交还」按钮照旧保留。原生 App 里还可以加一个交还快捷键（比如虚拟机软件常用的 ⌃⌥）。接管期间键盘输入都发给远端，Esc 也要能传过去，所以不能用 Esc 交还。

协议（官方桌面端的做法）：
- `display.status`、`display.thumbnail`（预览图，几秒刷新一次）、`display.start` / `display.stop`；
- `display.observe` 换一张 30 秒、一次性的 ticket，再用它开 WebSocket `/api/display/ws?ticket=…`，里面跑的是 RFB（VNC）画面流；
- 接管、交还用 `display.lease.acquire` / `display.lease.release`。断线时控制权留在你手里，直到你回来交还；两个人同时看时，最后接管的人拿到控制权。

**还没验证的风险**
1. 第三方客户端能用哪个 `source`（官方桌面端用 `gui`）。要在我们的 VPS 上看 `runtime.describe`。
2. 远端经 `hermes serve` 时，canonical 方法和插件 RPC 是否都能用。
3. 官方 Bot Mode 把头像、分组等存在 profile 的 `ui_meta` 里。Shion 要读写同样的键，才能和命令行、手机端保持一致。
4. **云桌面相关的方法不在 canonical 方法表里。** `display.*` 属于通用方法表，官方桌面端在远程连接上能用。要验证 Shion 经 Cloudflare 连上后，同一条连接能不能调到它们。
5. **Swift 里要有 RFB（VNC）解码。** 候选是 RoyalVNCKit（Swift 写的 VNC 客户端库，MIT 许可，需要评估），需要给它换一个跑在 WebSocket 上的传输层。实在不行，就用一个只显示云桌面的 WKWebView 加 noVNC 作过渡，但它连不过 Access 的请求头，得先拿到 Access 的 cookie 再塞进去。
6. **Apple 提醒事项经云端读写不一定可靠。** iCloud 日历走 CalDAV 没问题；但按 BusyMac、2Do 的说明，iOS 13 / macOS Catalina 之后升级过的提醒事项列表不再走 CalDAV，有的 MCP 声称能读写，说法不一。先用实际要用的工具测一遍；不行的话，就由 Mac 上的 Shion 用 EventKit 读写提醒事项（这正好是"接入本机"的第一个用途），或者以 `shion` 插件里的待办为准，只往提醒事项单向同步。

## 技术栈：SwiftUI 还是 MyGo

两者都不套浏览器（MyGo 的原生 UI 模式），差别在于对 macOS 系统能力的覆盖：

| | SwiftUI | MyGo（native UI） |
| --- | --- | --- |
| 界面 | 系统控件，自带 macOS 的外观和无障碍 | MyGo 在 GPU 上自绘，不是 AppKit 控件 |
| 菜单栏、通知、全局快捷键 | 有，通知里可以直接回复文字 | 有（tray、通知、全局快捷键） |
| 小组件、快捷指令 / Siri、EventKit（本机提醒事项）、应用切换记录 | 原生支持 | 需要另外桥接；小组件和 App Intents 必须用 Swift 写扩展 |
| 跨平台 | 只有 macOS | macOS、Windows、Linux |
| 协议客户端 | 从 OpenRPC 生成 Swift 类型 | 从 OpenRPC 生成 Go 类型 |

只做 macOS、又要深度用系统能力的话，选 SwiftUI。以后想出 Windows、Linux 版或者更想写 Go，就选 MyGo。

## 仓库结构

```
prototype/      UI 原型（Vite + React + TypeScript，示例数据）
  src/data/     模型、示例数据、模拟器（课后整理、核查、催促会自己播放）
  src/views/    今天、待办、日程、日报、等你确认、Bot Chat
```

```bash
cd prototype
npm install
npm run dev        # http://localhost:1420
```

## 路线图

1. **对齐界面**（现在）：用原型把信息结构和关键流程定下来。
2. **协议探路**：一个命令行小程序，经 Cloudflare Tunnel 用 Access service token 连上 VPS，跑通握手、`profiles.list`、打开 Bot Chat、流式消息、回答审批，同时验证上面三个风险。
3. **SwiftUI 骨架**：`NavigationSplitView` 主窗口、Bot Chat、等你确认、可回复的系统通知、`MenuBarExtra`、全局快捷键；云桌面先做缩略图和接管、交还，再做实时画面。
4. **`shion` 插件和助手团队**：插件提供待办、今天汇总、日报、应用记录；把紫苑和各助手的 profile、SOUL、例行任务做成一套可一键部署的模板。
5. **今天 / 待办 / 日程 / 日报** 接真实数据，加上 Mac 应用使用记录。
6. 以后：接入这台 Mac 让助手在本机做事；全天录音。
