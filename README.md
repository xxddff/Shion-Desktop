# Shion（詩音）

macOS 上的私人秘书。你主要和总秘书「詩音」打交道，她带着一组助手（课程、通勤、邮件、资讯、回顾）处理学习、工作和生活里的事；每个助手的对话也可以单独打开。

背后跑的是部署在 VPS 上的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)，Shion 通过 Canonical Gateway Protocol 连接它，完全取代官方桌面端的 Bot Mode。

> 现阶段：`prototype/` 是 UI 原型（React，示例数据，可交互），用来对齐界面和流程。正式的 App 用 SwiftUI + AppKit 写，不套浏览器，最低支持 macOS 27。

## 已经定下来的

| 问题 | 决定 |
| --- | --- |
| 和官方 Hermes Desktop 的关系 | 完全取代它的 Bot Mode |
| 组织方式 | 一个总秘书带一组助手；每个助手的 Bot Chat 也能单独访问 |
| Hermes 跑在哪 | 远端 VPS；以后可能也接入这台 Mac，让助手在本机做事（暂不实现） |
| 技术栈 | 原型不限；正式版用 SwiftUI + AppKit，不套浏览器；[MyGo](https://github.com/egoist/mygo)（Go，自绘原生 UI）留作以后跨平台的备选，见下文 |
| 最低系统 | macOS 27，直接用新系统的能力（Liquid Glass、Siri 和 Spotlight、本机模型等），不写旧系统的兼容分支 |
| 连接方式 | 沿用现在的 Cloudflare Tunnel + Cloudflare Access，用 service token 过认证（官方桌面端也用同样的方式：给连接加额外请求头） |
| 云桌面 | VPS 上的 Hermes 开了 Bot Screen（每个助手一块桌面），Shion 里要能看画面、接管、交还 |
| 委派方式 | 看板为主：詩音建卡交给助手，助手在单独的工作会话里完成；一问一答的小事才用助手之间的直接消息 |
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
│  │       等你确认 · 各助手 Bot Chat │ Access     │  ├ profiles = 詩音 + 各助手            │
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
3. 提供 VPS 拿不到的本机数据（应用使用记录，和专注检查的结论）。

本机模型只在连不上 VPS、数据不该离开 Mac、要立刻有反应这三种时候用，见「本机模型」。

**为什么要一个 `shion` Hermes 插件。** Canonical 协议是围绕会话（对话）设计的，没有"列出待办""读日报"这类方法。Hermes 官方的扩展方式是插件 RPC：插件用 `ctx.register_rpc` 注册 `plugin.shion.<name>`，用 `ctx.emit_to_session` 推送事件，客户端从 `runtime.describe` 的 `plugin-rpc-v1` 能力判断可用。待办、今天的汇总、日报、应用记录上传都走这里。助手们操作同一份数据（同一个插件里的工具），这样你在 Shion 里看到的和助手看到的是同一份。

## 委派：看板为主，消息为辅

詩音把事交给助手，默认走 **Hermes 看板**，不是聊天消息：

- 詩音开着 `kanban` 工具集（`hermes -p shion tools enable kanban`），在自己的 Bot Chat 里用 `kanban_create(assignee=…, body=…, parents=…)` 建卡。最好把她的工具限制在看板、记忆、日程这些调度工作上，她只拆事、不亲自干活。
- 派发器为每张卡在负责助手名下起一个**工作会话**（worker session），和这个助手的 Bot Chat 分开。助手用 `kanban_heartbeat`、`kanban_complete`、`kanban_block` 汇报进度和结果。
- **评论**是交接信息的渠道：卡片每次重新运行，助手都会读完整的评论串。你补充信息、解除阻塞，都是在卡片上留评论。
- 卡片完成或阻塞时，詩音会被叫醒（`kanban.auto_subscribe_on_create`，默认开启），她在 Bot Chat 里告诉你结果、问你要不要调整。
- 卡片之间可以有依赖（`parents`）：前一张完成后，后一张自动从「排队」变成「就绪」。

**适合用看板的事**：要花时间、有交付物、可能卡住要人帮忙、需要留记录的事，比如课后整理、下载课件、核实消息、做复习卡片。

**`message_agent`（Bot Mode 里助手之间直接发消息）** 只用于一问一答的小事，比如"通勤，明天几点出门？"。消息落在对方的 Bot Chat 里，没有状态可追踪，来回次数也有上限（`gateway.bot_loop_guard.max_hops`，默认 4）。

Shion 里的对应：
- 詩音的对话里，每张卡显示成一个会实时更新状态的卡片；
- 「看板」页分四列：排队、进行中、等你、完成。点开卡片可以看评论、运行记录和工作记录，也能解除阻塞；
- 每个助手页顶部有标签：Bot Chat，加上它今天跑过的每张卡的工作记录；
- 卡在要人做的步骤时（`kanban_block`，类型 `needs_input`，比如两步验证），会出现在「等你确认」。你在云桌面上处理完、交还后，Shion 自动留评论并解除阻塞，派发器重新运行这张卡。

看板接口：`/api/plugins/kanban/board`、`/tasks/:id`、`/tasks/:id/comments`、`PATCH /tasks/:id`，实时更新走 `/api/plugins/kanban/events?since=<id>`。都要带 Access 的头和 Hermes 的 token。

### 同时能做几件（Hermes 默认值，2026-11 的 main）

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `kanban.max_in_progress`（整个看板同时在做的上限） | 不设时，Linux 上按内存推导：总内存 ÷ 512 MB，最少 2、最多 8；macOS、Windows 上不限 | 文档里还写着"不设就不限"，但代码（`hermes_cli/kanban_db_dispatch.py` 的 `derive_default_max_in_progress`）已经改成按内存推导。2 GB 的 VPS 就是 4，4 GB 及以上是 8 |
| `kanban.max_in_progress_per_profile`（每个助手同时在做的上限） | 不限 | 同一个助手可以同时跑好几张卡 |
| `kanban.dispatch_interval_seconds` | 60 秒 | 卡片变成就绪后，最多等一分钟被派发；调用 `POST /api/plugins/kanban/dispatch` 可以马上派发 |
| 内存压力保护 | 自动 | 内存偏紧时这一轮最多派 1 件，告急时这一轮一件都不派（延后，不会丢） |

依赖（`parents`）不属于并发限制：前一张没做完，后一张会一直留在「排队」。

**Shion 建议的配置**（原型就是按这个跑的）：

```yaml
kanban:
  max_in_progress: 4               # 按 VPS 内存和同时开着的云桌面数量定
  max_in_progress_per_profile: 1   # 每个助手一次只做一件
```

每个助手只有一块云桌面、一个浏览器配置。同一个助手的两张卡要是同时跑，会抢同一块屏幕和同一套登录状态。所以建议每个助手一次一件，不同助手之间照样并行。另外，Shion 在你新建卡、解除阻塞、交还云桌面之后会主动调用 `/dispatch`，不用等下一轮。看板里排队的卡会写明在等什么：等前一张做完、这个助手手上还有一件、整个看板满了，或者等下一轮派发。

## 场景由谁负责

| 场景 | 助手 | Hermes 侧 | Shion 里看到的 |
| --- | --- | --- | --- |
| 邮件 | 邮件 | himalaya（IMAP/SMTP，大多数邮箱都能接）+ email-inbox-triage，例行整理收件箱 | 发出前到「等你确认」；需要处理的变成待办 |
| 日程 | 詩音 | iCloud 日历（CalDAV，应用专用密码） | 日程（周视图）、今天的时间线 |
| 待办 | 詩音 | `shion` 插件存储，执行日期与截止日期分开；是否和 Apple 提醒事项同步见下面的风险 | 待办、菜单栏、今天 |
| 通勤路线、延误 | 通勤 | 已有的交通 MCP；按日程生成出门提醒 | 今天的通勤卡片、通知、菜单栏 |
| 课后整理 | 课程 | Notion MCP 读录音转写；按课表在课后触发 | 新待办先标"待确认日期"，在等你确认里定日期 |
| 课程提醒 | 课程 | 按日历里的课表生成例行任务；以后从 Moodle（iCal 订阅、Web Service）和教务系统补充作业截止 | 通知、菜单栏的"下一件" |
| 每日安排与催促 | 詩音 | 早报、12/18/21 点催促、睡前排明天；到了计划时间你却没在做，由 Mac 的专注检查叫醒她 | 今天页顶部的一段话、通知、菜单栏里的专注检查 |
| 应用记录与回顾 | 回顾 | 插件接收记录，22:30 写日报 | Mac 端采集；日报里的屏幕时间 |
| 事实核查 | 资讯 | 网络搜索与网页读取 | 对话；新闻日报里的核查标注 |
| 新闻 / 学习 / 工作 / 生活日报 | 资讯、回顾 | 例行任务生成 | 日报页 |
| 要登录、两步验证、验证码的网站（学校统一认证、Moodle、教务） | 课程等 | 助手在自己的云桌面上用浏览器操作；登录状态保留在它的浏览器里 | 「等你确认」里出现「去接管」，在云桌面页接管、登录、交还 |
| 全天录音（以后） | 新助手 | 转写 → 记忆 → 待办 | 暂不做 |

**关于日报放不放进 Shion：** 生成不放在 Shion，交给 Hermes 的例行任务：Mac 关着也能按时写，还能同时推到手机（Telegram 等平台）。Shion 只负责阅读界面，再加上提供应用使用记录这一份 VPS 拿不到的数据。

## 专注检查：本机判断，詩音只收到结论

到了计划里该做某件事的时间，Shion 看这台 Mac 前台的窗口和计划对不对得上。判断在本机做，詩音只收到一句结论，催不催、怎么催由她决定。

1. **计划从哪来。** Shion 已经有待办和今天的日程（都来自 `shion` 插件）。此刻落在课或专注时段里，就以它为准；否则取今天执行时间已到、还没做完的那条待办。没有计划时不检查。
2. **看前台。** `NSWorkspace` 通知前台应用切换；窗口标题用辅助功能接口读（`AXUIElement` 焦点窗口的标题），浏览器的窗口标题里就有网页标题。第一次打开专注检查时请求辅助功能权限。用辅助功能接口读别的 App 的窗口，App 不能开沙盒，所以 Shion 不上 App Store，用 Developer ID 签名、公证后自己装。锁屏或键鼠 5 分钟没动算"不在 Mac 前"，不算偏离。
3. **本机判断。** 标题变了才问一次本机模型，同样的标题用缓存。用 Foundation Models 的引导生成，直接拿到结构化结果：

   ```swift
   @Generable struct FocusJudgement {
       @Guide(description: "前台窗口和此刻计划的关系") var fit: Fit   // same / related / unrelated
       @Guide(description: "前台窗口在做哪类事") var kind: Kind        // study / work / life / fun / social / other
   }
   ```

   本机模型能看懂内容：在 YouTube 上看这门课的讲解算「相关」，看猫的视频算「无关」，只靠应用名分类做不到。标题看不出在做什么时（比如只有应用名），可以让本机模型看一眼前台窗口的截图，这要屏幕录制权限，默认不开。
4. **告诉詩音。** 偏离满 5 分钟，Mac 经插件 RPC 报一次（`plugin.shion.focus.report`），只带计划名、偏离了几分钟、在做哪类事；回到计划上再报一次。插件用 Hermes 的 `ctx.inject_message` 把这句话放进詩音的 Bot Chat，叫醒她（插件要开 `allow_gateway_injection`）。她的例行催促也能用插件工具查最新结论。
5. **詩音决定。** 比如"小测原定 10:45 开始，已经过了 7 分钟。15 分钟就能做完，现在开始吧？"。Mac 合上或离线时没有结论，她照旧按时间提醒。

隐私：
- 窗口标题、应用名和这段时间线只存在这台 Mac 上，保留 7 天，可以随时清空。
- 发给詩音的只有：此刻的计划、偏离了几分钟、在做哪类事。设置里专注检查的开关下面写明发什么、不发什么，界面里不另加说明；插件放进詩音对话里的那句话，Shion 也不显示。
- 菜单栏里可以暂停 1 小时，设置里可以关掉。

原型里：菜单栏弹出面板的第一行就是专注检查，点开能看到最近的几个窗口和暂停按钮；设置里的「原型演示」可以换一个"前台窗口"。

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
- **Hermes 自己的登录**：两道门都开着，外面是 Cloudflare Access，里面是 Hermes 的登录。Shion 默认用浏览器登录（Hermes 给原生 App 的 RFC 8252 登录，官方桌面端连远端也用它）：在弹出的登录页输入用户名和密码，网关把一次性的登录码交回 Shion 在 127.0.0.1 上开的临时端口，Shion 用它和 PKCE 换到登录凭证。REST 带 `Authorization: Bearer`，`/api/ws` 带 `?token=`。也可以改用会话令牌（`HERMES_DASHBOARD_SESSION_TOKEN`）：REST 带 `X-Hermes-Session-Token`，`/api/ws` 同样带 `?token=`。
- **登录窗口自己过 Access，不带 service token**：Cloudflare 的「严格 service token 认证」是组织级设置，新组织默认开、关不掉。开着时，带 service token 的请求只看 token 本身：Access 不认 Allow 规则和 cookie，也不给浏览器发 cookie，出错直接 401/403。登录页提交密码是页面自己发的请求，带不上 service token；所以要是登录窗口带着 token 打开，页面能显示，提交密码却会被 Access 转去它的登录页，浏览器报跨域错误。现在登录窗口不带 service token，像普通浏览器一样先登录 Access（比如邮箱验证码），之后靠 Access 的 cookie 走完 Hermes 的登录页。Shion 自己的请求照旧带 service token。
- **凭证存放**：service token、会话令牌和登录凭证都存进 macOS 钥匙串，登录凭证记着是哪个地址发的，只发给那个地址。官方桌面端存在 Hermes 目录下一个权限 0600 的明文文件里。
- **为什么用原生 WebSocket**：浏览器里的 Webapp（包括云桌面）能正常连，是因为浏览器先走了 Access 的登录，之后靠 Access 的 cookie 过关。网页里的 WebSocket 不能自定义请求头，用不了 service token。原生 App 用 `URLSessionWebSocketTask`，每个连接都能直接带上 service token 的两个头，不需要在浏览器里过 Access。

## 云桌面（Bot Screen）

VPS 上每个助手（profile）有自己的一块 Xfce 桌面：助手的 `computer_use` 和有界面的浏览器都在这块桌面上操作，画面留在 VPS 上，你的 Mac 关了也不影响。遇到登录、两步验证、验证码、付款这类步骤，助手会停下来请你接管。你接管期间，助手的桌面和浏览器操作都会被拒绝（`human_has_control`）；你交还后它接着做。助手的浏览器登录状态会保留，你帮它登录过一次的网站，之后它可以自己用。

Shion 里的位置：
- **云桌面页**：所有助手的桌面缩略图，加一个大的实时画面，可以启动、接管、交还；
- **每个助手的侧栏**：一块桌面预览，点开进入云桌面页；
- **等你确认、系统通知**：助手卡在要人来做的步骤时，出现「去接管」。

接管和交还的操作：
- **点大画面就接管。** 缩略图和侧栏预览只负责打开大画面，点它们不会接管。助手正在这块桌面上干活时，第一下只提示「再点一次接管」，免得看一眼就打断它；它停下来等你，或者本来就空闲时，点一下就接管。
- **接管那一下点击不发给远端**，免得一点就按到「登录」「付款」这类按钮。接管以后的点击照常发过去，所以要在哪个输入框打字，接管后再点它一下。
- **点画面外面就交还，有 3 秒缓冲。** 点到 Shion 里画面以外的地方，画面下方出现倒计时，3 秒内点回画面就取消。这样登录到一半误点了别处，也不会把控制权丢给助手。
- **切到别的 App 不交还。** 比如去验证器 App 或手机上看验证码。窗口失去焦点不算"点外面"，这一点和断线时控制权仍在你手里的语义一致。
- **离开这个画面就立刻交还**，比如切到别的页面或别的助手，和官方关掉画面面板时的行为一样。
- 「接管」「交还」按钮照旧保留。原生 App 里还可以加一个交还快捷键（比如虚拟机软件常用的 ⌃⌥）。接管期间键盘输入都发给远端，Esc 也要能传过去，所以不能用 Esc 交还。

协议（官方桌面端的做法）：
- `display.status`、`display.thumbnail`（预览图，几秒刷新一次）、`display.start` / `display.stop`；
- `display.observe` 换一张 30 秒、一次性的 ticket 和一个 `viewer_id`，再用 ticket 开 WebSocket `/api/display/ws?display_ticket=…`，里面跑的是 RFB（VNC）画面流；
- 接管、交还用 `display.lease.acquire` / `display.lease.release`，都带上这个 `viewer_id`，它只在发它的那条 gateway 连接上有效。断线时控制权留在你手里，直到你回来交还；两个人同时看时，最后接管的人拿到控制权，前一个人的画面连接会被桥用 4000 关掉；
- **画面桥本身就是闸门**：它逐条解析客户端发来的 RFB 消息，不是租约持有者发的键盘、鼠标、剪贴板消息直接丢掉，只看模式不靠客户端自觉。

### 画面客户端（建议：自己写一个精简的 RFB 客户端）

缩略图和侧栏预览一直用 `display.thumbnail` 的图片，不连 VNC；只有打开大画面时才连 RFB。

**为什么自己写。** 服务端只有一种：Hermes 画面桥后面的 TigerVNC（Xvnc，`-SecurityTypes None`、`-AlwaysShared`），握手是固定的，要支持的编码也就几种。传输是 WebSocket，`URLSessionWebSocketTask` 能直接带上 Access 的两个头。点画面接管、点外面交还、租约、交还快捷键、下面说的粘贴输入，这些用现成的库也得自己加。

不选的几条路：
- **RoyalVNCKit**：MIT 许可，自带处理键鼠的 macOS 画面视图，但 2026-10-05 已归档只读，而且只走 TCP。用它等于 fork 过来自己维护，还要换掉传输层。它的解码和键位表可以参考，按 MIT 的要求保留版权声明。
- **libvncclient、TigerVNC 自带的 viewer**：都是 GPL，也一样要自己接 WebSocket。
- **noVNC**：官方桌面端用的就是它，但它是网页，和"不套浏览器"冲突；网页里的 WebSocket 带不了 service token 的请求头，还得先拿到 Access 的 cookie 塞进 WebView。只在自己的客户端做好之前，用 SwiftUI 的 `WebView` 跑它过渡。

分几步做：

| 阶段 | 内容 | 估计 |
| --- | --- | --- |
| 探路 | 命令行小程序：`display.observe` 拿 ticket，带 Access 头连上画面 WebSocket，走完 RFB 3.8 握手，把收到的数据存下来当测试样本 | 1–2 天 |
| 只看 | 编码 Raw、CopyRect、ZRLE（用系统自带的 zlib），伪编码 DesktopSize；画到 IOSurface 上交给 `CALayer` 显示，按窗口等比缩放 | 约 1 周 |
| 接管 | 租约；鼠标、滚轮（坐标换算回远端）；键盘（字符换成 X keysym，功能键按键码映射）；输入法（`NSTextInputClient`）；Cursor 伪编码；TigerVNC 的扩展剪贴板（UTF-8） | 约 1 周 |
| 以后 | 带宽不够再加 Tight + JPEG（JPEG 用系统的 ImageIO 解）；断线后自动重连 | — |

键盘和中文、日文输入：
- **⌘ 当成 Ctrl 发过去**，⌘C、⌘V、⌘L、⌘T 在远端浏览器里照 Mac 的习惯用；⌘Tab、⌘Q 仍然归 Mac。
- **⌘V 先同步剪贴板**：把 Mac 剪贴板里的文字用剪贴板消息放进远端，再发 Ctrl+V。⌘C 反过来，远端复制完把内容取回 Mac。只在你接管期间同步，助手自己复制的东西不会进你的剪贴板。
- **中文、日文在你点的地方直接打。** 画面视图接上 Mac 的输入法（实现 `NSTextInputClient`）：点一下远端的输入框，照常用输入法打字，拼写中的文字和候选窗口就出现在你点的位置；确认后的文字用剪贴板消息放进远端，再发 Ctrl+V 粘进去，不碰 Mac 自己的剪贴板。英文、数字和快捷键不经过这一步，照常按键发。
  - 不逐字发 Unicode keysym：TigerVNC 1.10 起剪贴板支持完整的 Unicode，而逐字发的话 Xvnc 要临时给每个字分配键位，有人遇到过分配失败后键盘没反应（[TigerVNC #93](https://github.com/TigerVNC/tigervnc/issues/93)）。
  - 远端不会告诉我们光标在哪，所以先用你最后一次点的位置；用 Tab 换了输入框，就再点一下。以后可以再准一点：Xvnc 只发画面上变了的区域，光标闪烁就是点击位置附近一个反复出现的细长小块，找到它就能把拼写中的文字对准远端光标。
- 密码也一样：从 Mac 的密码管理器复制，⌘V 粘过去。

和画面桥打交道的规矩（依据 Hermes 的 `hermes_cli/web_routers/display.py` 和 `tools/bot_desktop/rfb_filter.py`）：
- 只发桥认得的消息：SetPixelFormat、SetEncodings、FramebufferUpdateRequest、KeyEvent、PointerEvent、ClientCutText（含扩展剪贴板），以及 TigerVNC 的 EnableContinuousUpdates、Fence。发别的，桥分不清消息边界，会直接断开。剪贴板一次最多 256 KB。
- 不发 SetDesktopSize：它会连助手的屏幕分辨率一起改掉。窗口大小只影响本地缩放。
- 只看时不开 Cursor 伪编码，让服务器把助手的光标画进画面，看得到它在点哪；你接管后再打开，光标在本机画，不跟着网络卡。
- 离开画面时用 1000 正常关闭 WebSocket，桥会顺带交还；网络断了不算，控制权还在你手里。被别人接管时桥用 4000 关掉连接，换一张新 ticket 回到只看。
- 只断了画面连接时，带上原来的 `viewer_id` 再调 `display.observe`，租约还在；gateway 连接也断了的话，旧 id 就不认了，重连后用新 id 再接管一次。
- 只看时画面不在眼前（窗口最小化或被挡住、切到别的页面）就断开，只留缩略图。连着的时候桥会当作有人在看，云桌面不会闲置自动停。
- ticket 一次性有效，不写进日志。

## 还没验证的风险

1. 第三方客户端能用哪个 `source`（官方桌面端用 `gui`）。要在我们的 VPS 上看 `runtime.describe`。
2. 远端经 `hermes serve` 时，canonical 方法和插件 RPC 是否都能用。
3. 官方 Bot Mode 把头像、分组等存在 profile 的 `ui_meta` 里。Shion 要读写同样的键，才能和命令行、手机端保持一致。
4. **云桌面相关的方法不在 canonical 方法表里。** `display.*` 属于通用方法表，官方桌面端在远程连接上能用。要验证 Shion 经 Cloudflare 连上后，同一条连接能不能调到它们。
5. **RFB 客户端是整个项目最大的一块**，做法见上面「画面客户端」。探路时要确认：VPS 上的 TigerVNC 支持扩展剪贴板（中文、日文粘贴靠它）；中途开关 Cursor 伪编码，Xvnc 会立刻生效；ZRLE 走 Cloudflare 这条线带宽够不够，不够就提前做 Tight + JPEG。
6. **浏览器登录经过真的 Cloudflare Access。** 第一次带着 service token 打开登录窗口时，提交密码被严格模式拦下了，现在已经改成不带。CI 上的替身照严格模式演 Access，登录页在另一个域名上；还要在我们的域名上确认一次：登录完 Access 回到原来地址时，查询参数（PKCE、state）原样带回。
7. **Apple 提醒事项经云端读写不一定可靠。** iCloud 日历走 CalDAV 没问题；但按 BusyMac、2Do 的说明，iOS 13 / macOS Catalina 之后升级过的提醒事项列表不再走 CalDAV，有的 MCP 声称能读写，说法不一。先用实际要用的工具测一遍；不行的话，就由 Mac 上的 Shion 用 EventKit 读写提醒事项（这正好是"接入本机"的第一个用途），或者以 `shion` 插件里的待办为准，只往提醒事项单向同步。

## 技术栈：SwiftUI + AppKit

和 MyGo 比（两者都不套浏览器，MyGo 指它的原生 UI 模式），差别在于对 macOS 系统能力的覆盖：

| | SwiftUI | MyGo（native UI） |
| --- | --- | --- |
| 界面 | 系统控件，自带 macOS 的外观和无障碍 | MyGo 在 GPU 上自绘，不是 AppKit 控件 |
| 菜单栏、通知、全局快捷键 | 有，通知里可以直接回复文字 | 有（tray、通知、全局快捷键） |
| 小组件、快捷指令 / Siri、EventKit（本机提醒事项）、应用切换记录 | 原生支持 | 需要另外桥接；小组件和 App Intents 必须用 Swift 写扩展 |
| 跨平台 | 只有 macOS | macOS、Windows、Linux |
| 协议客户端 | 从 OpenRPC 生成 Swift 类型 | 从 OpenRPC 生成 Go 类型 |

只做 macOS、又要深度用系统能力，所以选 SwiftUI。以后真要出 Windows、Linux 版，再考虑 MyGo。

### 最低 macOS 27：用上的新能力

不写旧系统的兼容分支，也不准备两套外观。工具链是 Xcode 27（Swift 6.4）。

| 能力 | 用在哪 |
| --- | --- |
| Liquid Glass：`.glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass)` / `.glassProminent`；27 起 `Glass.interactive()` 在 Mac 上响应点击 | 只给浮在内容上面的控件：输入框、⌘K 面板、云桌面的接管条、菜单栏弹出面板（规则见「界面原则」）。侧栏和工具栏系统自己会换成玻璃 |
| 同心圆角：SwiftUI 的 `GeometryProxy.concentricCornerRadii`，AppKit 的 `NSView.cornerConfiguration`（`.containerConcentric`） | 云桌面画面（AppKit 视图）的圆角和窗口同心 |
| `ToolbarSpacer` | 工具栏按钮分组，「跟詩音说」单独一组 |
| 任意容器里的轻扫和拖动排序：`swipeActions` + `swipeActionsContainer()`，`.reorderable()` + `reorderContainer(for:isEnabled:move:)` | 待办行轻扫完成或推迟，今天的待办拖动排序；不用为了这些换成 `List` |
| AppKit `NSStatusItem` 的 `expandedInterfaceDelegate` | 菜单栏用 `NSStatusItem`（橙色数字角标好画），弹出面板显示时告诉系统，键盘焦点才对 |
| Siri 和 Spotlight（App Intents）：App Schema（`@AppIntent(schema:)`、`@AppEntity(schema:)`），`IndexedEntity` 和 27 新增的 `IndexedEntityQuery`，屏幕感知（`appEntityIdentifier`） | 待办、任务卡、日程做成实体：Spotlight 里搜得到；新 Siri 能拿它们回答"我今天还有什么没做"，也知道你正在看哪张卡。Siri AI 还是测试版，27.2 起支持日语，简体中文还没有，所以 Mac 的 Siri 语言要设成日语 |
| 通知关联实体：`UNMutableNotificationContent.appEntityIdentifiers` | 詩音的催促、等你确认的通知带上对应的待办或任务卡，Siri 知道"这个"指的是哪件 |
| 控制中心和菜单栏里的控件（`ControlWidget`） | 「跟詩音说」「暂停催促一小时」 |
| 桌面小组件（WidgetKit） | 下一件事、通勤延误、等你确认的数量 |
| Foundation Models（本机模型） | 只做离线、隐私、要即时反应的小事，见下面「本机模型」 |
| Swift 6.4：`defer` 里能 `await`，`withTaskCancellationShield`；还有默认主线程隔离、`@Observable` 和 `Observations`、`Span` | 离开画面时 `defer { await 交还 }` 并加上取消保护，保证一定交还；界面状态在主线程，Gateway 连接和 RFB 解码各放在自己的 actor 里；RFB 解码用 `Span` 读写字节，不用 unsafe 指针 |
| SwiftUI `WebView` / `WebPage` | 只在 RFB 客户端做好之前，用来跑 noVNC 过渡 |

等 27.3 正式发布再用：Mac 上原生的实时活动（ActivityKit），把助手在做的事和进度放进菜单栏；Siri 把任意 App Intent 当工具调用（`@AppIntent(.tool)`）和 App 技能，现在是开发者预览，不能分发。

查过、27 没有新接口的：读前台应用和窗口标题（仍然是 `NSWorkspace` 加辅助功能接口）、Screen Time（macOS 上仍然没有 DeviceActivity）、EventKit、可操作的通知、`MenuBarExtra`。

### 本机模型

理解、拆解、写日报这些仍然交给 VPS 上的 Hermes，因为要用到助手的记忆、工具和日程。本机模型只在三种时候用：连不上 VPS；数据不该离开 Mac；要立刻有反应，等不了一次网络来回。

| 用在哪 | 为什么放在本机 |
| --- | --- |
| 连不上 VPS 时，把 ⌥Space 里的一句话先记成待办草稿（标题、执行日、截止日），连上后再交给詩音 | 离线 |
| 以后记窗口标题时，在本机把应用和窗口记录压成按时间段的摘要（在做什么，属于学习、工作还是生活），只把摘要交给「回顾」写日报 | 窗口标题不出 Mac |
| 专注检查：判断前台窗口和此刻的计划对不对得上，只把结论告诉詩音（见上面「专注检查」） | 窗口标题不出 Mac，而且要即时 |

用哪个模型：
- **默认用系统自带的本机模型**（Foundation Models）。macOS 27 上它重做过：WWDC26 的示例里上下文是 8192 个 token（26 上是 4096，输入和输出一起算），还能看图。支持中文、日文，能直接输出成 Swift 类型（`@Generable`），也能调工具。常识和推理弱，所以只让它做归类、摘要、抽取这类小事。要 Apple 芯片并开着 Apple 智能，用不了就跳过。
- **不够用时换模型，其余代码不变。** 同一个 `LanguageModelSession` 可以换成 Apple 开源的 `MLXLanguageModel`（GPU）或 `CoreAILanguageModel`（神经引擎，底下是 27 新增的 Core AI 框架），在本机跑开源模型。系统模型的中文、日文摘要不够好时就换，代价是要下载几个 GB、占内存。
- **Private Cloud Compute 模型**上下文 32K、不用 API key，下载量 200 万以下的开发者不付费；但数据要离开 Mac，所以不用在上面和窗口标题有关的事上。
- 上下文大小用 `contextSize` 查，token 数用 `tokenCount(for:)` 算，不写死。

### 原型到 SwiftUI 的对照

macOS 上是 SwiftUI 加 AppKit（UIKit 是 iOS 的；Mac Catalyst 做菜单栏常驻、浮动面板都要绕路，不考虑）。

| 原型里的部分 | 原生实现 | 难度 |
| --- | --- | --- |
| 窗口、侧栏、工具栏、红绿灯 | `NavigationSplitView` + `.toolbar`；侧栏和工具栏系统自动用 Liquid Glass | 低 |
| 页面切换、深链接（`#card-…`） | 侧栏选中状态 + 自定义 URL scheme 和 `.onOpenURL`，通知点进来直接到卡片 | 低 |
| 待办、等你确认、日报列表 | `LazyVStack` 加 `swipeActionsContainer()`、`reorderContainer`，`.contextMenu`，`.onHover` 显示「现在运行」 | 低 |
| 任务详情、待办详情 | `.inspector` | 低 |
| 看板拖卡片 | `.draggable` + `.dropDestination` | 低 |
| 日程周视图、时间线 | 自定义 `Layout` 或 `Canvas` | 中 |
| 屏幕时间图表 | Swift Charts（`BarMark`） | 低 |
| 流式回复、呼吸点 | `Text` 增量更新；`ellipsis` 符号加 `.symbolEffect` | 低 |
| 助手回复里的 Markdown | 系统自带只支持行内样式，列表、代码块要用第三方渲染库或自己写 | 中 |
| 复制消息 | 每条消息 `.textSelection(.enabled)`，再加一个「复制」按钮；不做跨多条消息的连续选中 | 低 |
| 菜单栏常驻和弹出面板 | AppKit `NSStatusItem`，面板里放 SwiftUI，用 `expandedInterfaceDelegate` 管键盘焦点；橙色数字角标画成图片 | 中 |
| 可直接回复的系统通知 | `UNUserNotificationCenter` + `UNTextInputNotificationAction` | 低 |
| ⌥Space 全局唤出 | 系统没有 SwiftUI 接口；用 Carbon 的 `RegisterEventHotKey`（不需要辅助功能权限），或 KeyboardShortcuts 这类封装库 | 中 |
| ⌘K 浮动输入框（像 Spotlight） | AppKit `NSPanel`（不激活主窗口）里放 SwiftUI，背景用 `.glassEffect` | 中 |
| 应用使用记录 | `NSWorkspace` 的前台应用通知，不需要权限，只记应用名和时长；专注检查读窗口标题用辅助功能接口 | 低 |
| 本机提醒事项（以后） | EventKit，申请提醒事项的完整访问权限 | 低 |
| 开机启动、常驻 | `SMAppService`；关掉窗口后留在菜单栏 | 低 |
| 凭证 | 钥匙串 | 低 |
| Gateway 连接 | `URLSessionWebSocketTask`（可以带 Access 和 Hermes 的请求头）+ 自己写的 JSON-RPC 层，类型从 OpenRPC 生成 | 中 |
| 云桌面画面 | 见上面「画面客户端」：自己写精简的 RFB 客户端，画面是 AppKit 的 `NSView`，接管条浮在上面用玻璃 | 高 |
| 点画面接管、点外面交还 | 画面视图成为第一响应者；`NSEvent.addLocalMonitorForEvents` 只看本 App 里的点击，所以切到别的 App 不会交还 | 中 |

## 界面原则（SwiftUI 版照这个来）

- **层级靠字号和留白，不靠框。** 只有需要你动手的东西才放进框里：「需要你」托盘、看板卡片、确认卡片、云桌面画面。其余都是标题加列表。
- **颜色只表达三件事。** 紫色（詩音的主题色）表示选中和主操作；暖橙表示在等你；红色表示逾期、"此刻"、你在操作云桌面。领域和助手的颜色只出现在小圆点、头像和日程色条上。
- **玻璃只给浮在内容上面的控件**：输入框、⌘K 面板、云桌面的接管条、菜单栏弹出面板；同一处的几个玻璃控件放进一个 `GlassEffectContainer`。列表、看板卡片、确认卡片这些内容层不用玻璃，玻璃上也不叠玻璃。只有主操作按钮用 `.glassProminent` 染成紫色。
- **字号五档**：11（角标）、12（次要信息）、13（正文）、15（小节标题）、20（详情标题），外加今天页 30 号的日期。
- **说明只写在设置里。** 发什么、不发什么，一个功能怎么运作，写在设置里对应开关的下面。主窗口和菜单栏只放状态和操作，不加解释性的注释、提示，也不加"仅本机可见"这类标注。
- **界面里不出现编号和协议词。** 任务卡编号、profile、模型名只放在详情底部的技术信息里。工具步骤默认折叠成一行。
- **动的东西只有两种**：助手在做事时的三个呼吸点，和流式输出的光标。系统控件自带的反馈（按下玻璃按钮、弹出层出现）照常保留，但不自己另加动画。
- **一个入口找詩音**：今天页的输入框；其他页面右上角的「跟詩音说」按钮（⌘K）；在 Mac 任何地方按 ⌥Space。
- **詩音的标记**：一个写着「詩」的圆形标记，和她的头像同一个样子；出现这个标记的地方就是在跟她说话。菜单栏里用单色描边版，符合 macOS 菜单栏模板图标的习惯。

## 仓库结构

```
prototype/      UI 原型（Vite + React + TypeScript，示例数据）
  src/data/     模型、示例数据、模拟器（课后整理、核查、催促会自己播放）
  src/views/    今天、待办、日程、日报、等你确认、Bot Chat
macos/          macOS App（SwiftUI + AppKit，最低 macOS 27），project.yml 由 XcodeGen 生成工程
  Shion/        App：Model（数据和示例数据）、Support（启动参数、格式、配色）、Views（各页面）
  ShionUITests/ 截图测试（每个页面浅色、深色各一张），浏览器登录的端到端测试
  ci/           CI 上替身用的假 Hermes（fake_hermes.py，只用标准库）
.github/workflows/macos.yml   在 macOS 27 runner 上编译、截图、跑登录测试
```

```bash
cd prototype
npm install
npm run dev        # http://localhost:1420
```

```bash
brew install xcodegen
cd macos
xcodegen           # 生成 Shion.xcodeproj（不进仓库）
open Shion.xcodeproj
```

### 装测试版，连自己的服务器

- **下载**：手动运行 Actions 里的「macOS app」工作流，或者推一个提交说明里带 `[package]` 的提交。跑完后在这次运行的附件里下载 `Shion-macOS-<编号>`（保留 30 天），解压出 `Shion.dmg`，把 Shion 拖进「应用程序」。
- **第一次打开**：测试版只做了本机签名，没有 Developer ID 签名和公证，macOS 会拦下来。到「系统设置 → 隐私与安全性」里点「仍要打开」，或者在终端运行：`xattr -dr com.apple.quarantine /Applications/Shion.app`。
- **填设置（⌘,）**：地址填 Webapp 的地址（比如 `https://hermes.example.dev`）；Access Client ID / Secret 填 Cloudflare Access 的 service token；登录方式选「浏览器登录」，点「用浏览器登录…」，在弹出的窗口里先登录 Cloudflare Access（比如邮箱验证码），再输入 Hermes 的用户名和密码。登录完会自动连上。登录凭证默认 12 小时到期，Shion 每次连之前快到期就自己续，续一次管 30 天，一直在用就不用再登录。凭证和密钥存在钥匙串里；装了新版本后第一次读，macOS 可能问要不要允许，选「始终允许」。
- **Access 要允许浏览器登录**：登录窗口不带 service token，要像普通浏览器一样先登录 Access。在 Cloudflare Zero Trust 里打开这个 Hermes 应用的策略，除了给 Shion 用的 Service Auth（service token）那条，再加一条 Allow：Include 选 Emails，填你自己的邮箱。登录方式用 One-time PIN（邮箱验证码），在「设置 → 身份验证」里打开。用普通浏览器打开 Hermes 的地址，看到 Access 的登录页、能用邮箱验证码进去，就说明设好了。
- **服务器要开账号密码登录**：在 `~/.hermes/config.yaml` 的 `dashboard.basic_auth` 下设 `username` 和 `password`（或者更好的 `password_hash`），再设 `secret`，然后重启 gateway。`secret` 用 `openssl rand -base64 32` 生成；不设的话每次启动都换一个随机值，gateway 一重启所有登录都失效，Shion 要重新登录。也可以用环境变量 `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`、`_PASSWORD`、`_SECRET`。
- **还是想用会话令牌**：登录方式选「会话令牌」，填服务器上的 `HERMES_DASHBOARD_SESSION_TOKEN`，点「连接」。
- **服务器那边**：`/api/ws` 要由 `hermes gateway` 提供，Canonical 协议只在它上面有；单独跑的 `hermes serve` / `hermes dashboard` 说的是旧协议。`HERMES_DASHBOARD_SESSION_TOKEN` 要事先设好，不设的话每次启动都是随机值。经 Cloudflare Tunnel 转到本机端口时，Webapp 的 `public_url` 要填对外的地址，不然 Host 对不上会被拒（4403）。
- **连不上时**：Shion 连之前会先用 HTTP 查一遍，设置里会写出是哪一步不对：Cloudflare Access 没放行；服务器没开浏览器登录（`/api/status` 的 `auth_flows` 里没有 `native_pkce`）；登录过期了；服务器没开会话令牌登录（`auth_providers` 里没有 `session-token`）；令牌对不上（`/api/auth/me` 返回 401）；或者 WebSocket 被拒（带 HTTP 状态码）。也可以在终端自己查，这是 Hermes 文档给的检查方法，加上 Access 的两个头：

  ```bash
  curl -s https://<地址>/api/status -H "CF-Access-Client-Id: <ID>" -H "CF-Access-Client-Secret: <Secret>" | jq '.auth_required, .auth_providers, .auth_flows'
  ```

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' https://<地址>/api/auth/me -H "CF-Access-Client-Id: <ID>" -H "CF-Access-Client-Secret: <Secret>" -H "Authorization: Bearer <会话令牌>"
  ```

  浏览器登录要第一条的 `auth_flows` 里有 `"native_pkce"`；会话令牌要 `auth_providers` 里有 `"session-token"`，第二条是 `200`。
- **令牌对不上时，找 gateway 实际用的值**：变量在启动时读一次，以启动 gateway 的那个环境为准，不是你后来打开的 shell。启动时注入的值（systemd、启动脚本）优先，`~/.hermes/.env` 里的同名一行不会覆盖它；值是 `file:<路径>` 的话，令牌是那个文件的内容。值原样使用，引号和空格也算在里面。在服务器上看：

  ```bash
  pgrep -af "hermes.*gateway"
  sudo tr '\0' '\n' < /proc/<上面的 PID>/environ | grep HERMES_DASHBOARD_SESSION_TOKEN
  grep HERMES_DASHBOARD_SESSION_TOKEN ~/.hermes/.env
  ```

  设置看 `hermes config show`（或 `~/.hermes/config.yaml` 里的 `dashboard:` 一节）。改了令牌要重启 gateway。
- **开会话令牌登录**：在运行 `hermes gateway` 的环境里设 `HERMES_DASHBOARD_SESSION_TOKEN`（可以写进 `~/.hermes/.env`；也可以写成 `file:<路径>` 指向一个只放令牌的文件），确认 `dashboard.session_token_auth.enabled` 没设成 `false`，再重启 gateway。令牌用 `python3 -c "import secrets; print(secrets.token_urlsafe(32))"` 生成，至少 32 个字符。它能完全操作这台 Hermes，当密码保管；换了令牌，Shion 里也要换。
- **现在能用的**：助手列表（每个 profile 一个助手）、每个助手的 Bot Chat（历史、发消息、流式回复、工具调用）、批准和提问（在「等你确认」里回答）。今天、待办、日程、日报、看板和云桌面还是示例数据，要等 `shion` 插件和看板接口接上。
- **连接方式**照官方桌面端连远端的做法：`wss://<地址>/api/ws?token=<登录凭证或会话令牌>`，不带子协议，每个请求带 Cloudflare Access 的两个头；连上后等 `gateway.ready`、发 `client.capabilities`，按服务器要求每 15 秒 `gateway.ping`；连上过又断了会自动重连，并重新打开刚才的对话。登录凭证被拒时先续一次再试，续不上才算登录过期。

### 原生 App 的界面检查

界面靠 CI 截图来看，不在本地开模拟器：
- **什么时候跑**：只有 `macos/` 或这个工作流改了才跑，也可以在 Actions 里手动触发；同一分支上新的提交会取消还没跑完的那次。
- **跑什么**：在 `xcode-27` runner（macOS 27、Apple 芯片）上生成工程、编译，再跑 `ShionUITests`：每个页面用启动参数直接打开（`-ShionSnapshot YES -ShionRoute today -ShionAppearance dark`），等界面稳定后截窗口；另外点开菜单栏面板截整个屏幕，按 ⌘, 截设置窗口（还有已登录和会话令牌两种设置）。
- **浏览器登录的端到端测试**：runner 上没有真的 Cloudflare 和 Hermes，`macos/ci/fake_hermes.py` 两个都演：Access 按严格 service token 认证来（带 token 的请求只看 token、不发 cookie，错的 token 直接 403；不带 token 的浏览器转去另一个域名上的 Access 登录页，登录后靠 cookie 放行）；登录页自己填用户名密码提交；检查 PKCE、回调地址和 state；发登录凭证；`/api/ws` 说 JSON-RPC。`SignInTests` 在设置里填好地址，点「用浏览器登录…」，等登录完、连上、助手列表换成服务器的，再打开詩音的对话发一句、等回复，每一步截一张（`signin-*.png`）。替身的请求记录 `fake_hermes.log` 也在附件里。这一步失败只报警告，截图和安装包照样出。
- **截图模式**：日期固定在 2026 年 11 月 9 日（周一）10:52，外观对整个 App 生效（菜单栏面板也跟着变），呼吸点不动。动画停下来 App 才算空闲，XCTest 不用干等，一次运行从 4.3 分钟降到 2.3 分钟。
- **runner 的屏幕**：1024×768、1 倍，所以窗口截出来是 1024×674，比默认窗口小，正好看窄窗口下的布局。
- **看哪里**：截图打包成这次运行的 `shots` 附件（保留 14 天），文件名是「页面-外观.png」。编译失败时，最后一步会列出错误。
- **省时间**：macOS runner 的分钟数有限，攒够一批改动再推；只改 README 这类文件不会触发。

## 路线图

1. **对齐界面**（现在）：用原型把信息结构和关键流程定下来。
2. **协议探路**：一个命令行小程序，经 Cloudflare Tunnel 用 Access service token 连上 VPS，跑通握手、`profiles.list`、打开 Bot Chat、流式消息、回答审批，同时验证风险 1–4，再走一遍风险 5 的探路（画面 WebSocket 的 RFB 握手）。
3. **SwiftUI 骨架**（已开始，`macos/`）：主窗口和各页面先用示例数据做出来；接着是可回复的系统通知、菜单栏、全局快捷键；云桌面先做缩略图和接管、交还，再做实时画面。
4. **`shion` 插件和助手团队**：插件提供待办、今天汇总、日报、应用记录；把詩音和各助手的 profile、SOUL、例行任务做成一套可一键部署的模板。
5. **今天 / 待办 / 日程 / 日报** 接真实数据，加上 Mac 应用使用记录。
6. 以后：接入这台 Mac 让助手在本机做事；全天录音。
