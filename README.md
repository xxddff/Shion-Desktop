# Shion（詩音）

macOS 上的私人秘书。你主要和总秘书「詩音」打交道，她带着一组助手（课程、通勤、邮件、资讯、回顾）处理学习、工作和生活里的事；每个助手的对话也可以单独打开。

背后跑的是部署在 VPS 上的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)，Shion 通过 Canonical Gateway Protocol 连接它，完全取代官方桌面端的 Bot Mode。

> 现在：原生 App 在 `macos/`（SwiftUI + AppKit，不套浏览器，最低支持 macOS 27），已经能连上 Hermes 日常使用，怎么装见下面「装测试版，连自己的服务器」；服务器上的 shion 插件在 `hermes-plugin/`；`prototype/` 是早先用来对齐界面和流程的 UI 原型（React，示例数据）。测试版安装包在 Actions 里「macOS app」工作流手动运行的结果中（`Shion-macOS-<编号>`）。

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
│  │       待你处理 · 各助手 Bot Chat │ Access     │  ├ profiles = 詩音 + 各助手            │
│  ├ 云桌面：看画面、接管、交还       │            │  │   各自的 SOUL、记忆、技能、MCP、凭据   │
│  ├ 菜单栏常驻 + ⌥Space 随手交代     │            │  ├ Bot Screen：每个助手一块 Xfce 桌面   │
│  ├ 系统通知（可直接在通知里回复）   │            │  ├ cron = 各助手的例行任务             │
│  └ 应用使用记录（只记应用名和时长） │            │  ├ kanban = 交给助手的事                │
└──────────────────────────────────┘            │  └ shion 插件：待办、日报、应用记录的存取 │
                                                 └──────────────────────────────────────┘
```

**Shion 不做"聪明"的部分。** 理解、拆解、提醒的时机、写日报，都由 VPS 上的 Hermes 助手完成，Mac 合上了也照常运行。Shion 负责三件事：
1. 把这些结果做成好用的界面；
2. 在你需要拍板时打断你（通知、菜单栏、待你处理）；
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
- 对话里，助手用 `kanban_create` 交出去的每张卡显示成一个会实时更新状态的卡片：调用的结果里有卡的编号，就按编号找；重新读对话时（对话记录只留调用、不留结果）按标题和交给谁找。卡片有动静时，Hermes 会以你的名义往对话里发一条「✔ [看板] @助手 Kanban <编号> …」再让助手接着说，这一行也显示成那张卡，不显示成你说的话；看板上已经没有的卡，才按原文显示。卡在别的看板上也找得到（别的看板每分钟读一次）；
- 今天页的「助手在做」：所有看板上在做的卡和卡住的卡（卡住的在前），没连上时是上次的数据；
- 「看板」页（已接上服务器，没连上时是上次的数据）把 Hermes 的八列归成五列：排队（待整理、待办、定时、就绪）、在做、卡住（`blocked`）、待验收（`review`）、完成。原来的「等你」一列把卡住和待验收混在一起，而 Hermes 的 `review` 是等验收助手来认领（`claim_review_task`），不是等你；助手建卡时直接设成阻塞的卡（`initial_status: blocked`）也会先落在卡住里。卡住的卡在标题上方有一个小标签说为什么：「等你回答」（needs_input）、「缺权限」（capability）、「出错了」（transient，或反复失败后放弃）、「停下了」（没说原因）；只有前两种是要你来解的，它们也在「待你处理」里，页面副标题数的也是它们。五列平分宽度，每列最窄 144 点（1024 宽的窗口正好放下五列；默认窗口里每列约 190 点）；开着详情、或者窗口更窄时不再把卡片挤扁，而是整块看板横向滚动。卡片上只留区分它的东西：标题（最多三行）、一句现状（最多两行：做了多久、在等什么、交上来什么）、交给谁，有子卡的显示进度（2/3），有评论的显示条数；其余的点开看。详情栏加宽了（320 到 560 点，默认 400），先说它现在卡在哪或交上来了什么，再是交代的事（长的折起来）、评论和回复框，「经过」默认折成一行（几次、最近一次怎么结束的），点开才列每一次；右上角有展开和关闭两个按钮；
- 拖卡片换列，能拖到哪里以 `/workflow` 的 `manual` 为准（拖到「排队」是就绪，前面的卡没做完就退一步到待办；「在做」只能由派发器放进去，不能拖进）；右键菜单里的「移到」可以选到具体的列，也能归档。服务器不让移的（409），卡片退回原处，弹出它为什么不让，前面的卡没做完会写出是哪几张；
- 工具栏的「＋」新建卡片：标题、内容、交给哪个助手；交给了助手又没有前置卡，就直接是就绪；
- 点开卡片在右边看详情：内容、在等什么或交付了什么、评论（可以留言，浏览器登录时署你的登录名，助手读评论时看到的就是这个名字；会话令牌登录没有名字，记作 `dashboard`；卡住的卡留言后点「让它继续」，回到就绪）、前后置的卡（点了跳过去）、每次运行的起止和结果，最底下小字是编号、看板和 profile；
- 右边不够看时，详情右上角的按钮把它展开到整页（看板的列让出来，左边导航还在）：交代的事按 Markdown 完整排出来，每次运行的结果不再截到三行，窗口够宽时前后置的卡和运行记录另成一栏；再点「收回」或按 Esc 回到看板旁边，卡片还开着。工作记录里点开的卡也一样；
- 服务器上有几块看板时，工具栏里能切换；
- 每个助手页顶上有两个标签：Bot Chat ｜ 工作记录。标签放在页面里、不放工具栏：工具栏留给「跟詩音说」「助手设置」和查找的放大镜，窄到 1024 宽的窗口也不挤；查找只找对话，所以看工作记录时放大镜是灰的。工作记录列出这个助手今天跑过的每张卡，所有看板都算，最近的在上面：每张卡写着现在的状态，下面是今天的每次运行（起止时间、怎么结束的、交接摘要或出错的原因）；点一张在右边看详情，和看板页的一样，别的看板上的卡也能留言。哪次运行算这个助手的，看运行记录的 `profile`（就是认领时的 assignee），所以卡后来交给了别人也还在；从没跑过的卡、昨天的运行、没有时长的运行（Hermes 为没人认领的卡记交接时补的）都不算。Hermes 没有按助手查的接口（`list_tasks` 能按 assignee 筛，看板路由没开），Shion 读每块看板的卡，再读今天动过的卡（在做、卡住、待检查，或今天开始、完成、有心跳的）的详情。今天跑过、后来归档了的卡也在，标着「已归档」：`/board` 默认不带归档的卡，工作记录开着时 Shion 另外用 `include_archived=true` 读有归档卡的看板（`/boards` 的数量里有 `archived`），只留今天开始或完成的，再读它们的详情；打开时读一次，之后每分钟一次，哪块看板的归档数量变了（15 秒那次检查看得到）也马上读。看板页照旧不显示归档的卡。一张卡要是昨天开始、今天又跑了一次、现在既不在做也没做完（比如重试后回到就绪，或被归档），卡片字段里看不出它今天跑过（Hermes 结束一次运行时把心跳清掉），这种不在工作记录里；
- 卡在要你做的事上时，会出现在「待你处理」：`blocked` 且类型是 `needs_input`（要你的决定或答案，比如两步验证码）或 `capability`（它过不去的墙：没有的账号、凭据，或者助手做不了的一步。Hermes 的 `hermes kanban block --kind` 写的是 needs_input 和 capability 都「留给人」）。写着谁、哪块看板、什么时候停的、为什么（只在 `blocked` 事件里），以及停下以后卡上的评论；可以直接回复（留评论，署登录名），也可以「让它继续」（先留言再 `PATCH` 成 ready，Hermes 解除阻塞，它再跑时先读评论），还有「打开卡片」到看板上看。`transient`（一时的故障，比如网站超时）不放进来：不需要你回答什么，重试就够了，卡住时詩音会被叫醒，她有 `kanban_unblock` 可以自己重试，Hermes 的通知也把它算作故障提醒而不是要你决定的事；它照旧在看板的「等你」里，详情里也能让它继续。没写类型的阻塞和失败熔断（`gave_up`，连续出错后 Hermes 把卡停下，`block_kind` 还是上一次的）也只在看板上。同一种阻塞在你让它继续之后又来一次（比如验证码过期了），Hermes 的防循环（`BLOCK_RECURRENCE_LIMIT` = 2）会把卡送去「待整理」并记 `block_loop_detected`；这种卡也在「待你处理」，写着「又卡在同一处」，让它继续就回到就绪。云桌面上处理完、交还后自动留评论并解除阻塞还没做（云桌面暂不实装）；
- 系统通知：卡片停下来等你（上面那两种，包括又卡在同一处的）、交去验收（`review`）时发通知，写着谁、哪张卡、原因或交接；做完了（`done`）也发，可以在设置里关掉（默认开着，詩音也会在她的对话里说做完的卡）。停下来等你的卡，通知上有「回复」，可以直接打字（和提问的通知一样）：回复署你的登录名留在卡上，再让它继续（`PATCH` 成 ready），和在「待你处理」里填回复、点「让它继续」一样；回复时它已经在继续了，就只留言；没发出去，会再来一条通知说为什么。看板页正开着那块看板时不发；等你回答的卡在「待你处理」开着时也不发。「开着」是说 Shion 在前台、侧栏选的是那一页（看板页还要是那块看板）；主窗口关了、只剩菜单栏时，侧栏还停在原来那页，Shion 在前台就仍算开着，不发，切到别的 App 以后才发。点通知打开那张卡（在别的看板上就先切过去）。只有正在看的那块看板有事件流，它的卡一变就知道；别的看板靠每 15 秒比一次 `/boards` 的数量，数量变了才去读，所以那里的通知最多晚十几秒；数量不变的变化（比如卡住、继续、又卡住，正好夹在两次检查之间）要等每分钟一次的重读，最多晚一分钟。通知按读到的变化发：每读一次看板，比较每张卡此刻的状态（卡住的种类和次数、交上来的摘要、完成的时间），变了才算；连上后第一次读到的不算，所以已经在等的卡不会一连上就响一遍。在设置里设成不显示的助手，它的卡只在看板上：不进「待你处理」，也不发通知。

看板接口（`/api/plugins/kanban`，认证和 `/api/*` 一样：会话令牌放 `X-Hermes-Session-Token`，浏览器登录的凭证是 bearer，再加 Access 的两个头；每个路由都可以带 `?board=<slug>`，不带是服务器当前的看板）。以下按 Hermes 代码（`plugins/kanban/dashboard/plugin_api.py`、`hermes_cli/kanban_workflow.py`、`hermes_cli/kanban_db.py`）核对过，它的文档有几处和代码不符：

| 接口 | Shion 用来 |
| --- | --- |
| `GET /workflow` | 列（`key`、`label`、`drag_target`）和人能做的移动 `manual{src:[dst…]}`；归档总是可以 |
| `GET /boards` | 每块看板的 `counts{status:n}` 和 `is_current`；所有看板的 `running` 加起来，就是 `max_in_progress` 数的那个数 |
| `GET /board` | 卡片（按列）、`assignees`、`latest_event_id`（事件流从这里接着读）、服务器的 `now`。不带归档的卡；`include_archived=true` 时多一列 `archived`（工作记录用，看板页不用）。归档（`archive_task`）把卡设成 `archived`、放掉认领，还开着的运行记成 `reclaimed`，记一条 `archived` 事件；卡上没有归档时间 |
| `GET /assignees` | 每个助手在这块看板上各状态的数量，拿 `running` 和每个助手的上限比 |
| `GET /tasks/{id}` | 详情：完整的 `latest_summary`、评论、`events`、`links` 和 `link_tasks`（前后置卡的标题和状态）、`runs`（按开始时间排，每次有 `profile`、`started_at`、`ended_at`、`outcome`、`summary`、`error`）。**阻塞的原因只在事件里**：`blocked` 的 `payload` 是 `{reason, kind, recurrences, source_status}`，防循环送去待整理的是 `block_loop_detected`（多一个 `limit`），失败熔断是 `gave_up`（原因在 `error`）。卡片字段只有 `block_kind`（dependency、needs_input、capability、transient；dependency 不进 blocked，在待办里等前置卡）和 `block_recurrences`，两个在解除阻塞后都保留，只有完成才清掉，所以「这次为什么停」以最新的那条事件为准。卡住的卡、在等前置卡的卡、今天动过的卡，Shion 都会读详情 |
| `POST /tasks` | 新建：`title`、`body`、`assignee`（还可以 `parents`、`priority`） |
| `PATCH /tasks/{id}` | 改状态：不能直接设成 `running`（400）；`manual` 里没有的、前置卡没做完的，返回 409，并写出卡在哪些前置卡上。卡住的卡设成 `ready` 走 `unblock_task`：回到就绪（前置卡没做完就是待办），记 `unblocked`，连续失败数清零；待整理的卡设成 `ready` 是直接改状态 |
| `POST /tasks/{id}/comments` | 留言（`author` 随便写；不带时记作 `dashboard`。Shion 带上登录名，显示时登录名和 `dashboard` 都是「你」）。新建卡片的 `created_by` 由服务器定死成 `dashboard`，改不了 |
| `WS /events?board=&since=&token=` | 实时更新。升级请求不看 `Authorization`，凭证放在 `?token=`，Access 的头照带；帧是 `{"events":[…],"cursor":N}`；凭证不对以 1008 关闭。不带 `since` 是从现在开始，`since=0` 会重放全部历史，所以带上 `/board` 给的 `latest_event_id` |

Shion 收到事件就（合并 0.3 秒内的）重读一遍看板和有变化的卡的详情；断了从上次的 cursor 接着连，所以不会漏。读一次看板同时只有一个，中途又要读就接在后面，旧的结果不会盖住新的。别的看板上的卡不会出现在这块看板的事件流里，算整台服务器的上限要用 `/boards`：Shion 每 15 秒读一次各看板的数量，别的看板数量变了就重读它们（卡住、交上来、做完都会改数量，所以通知最多晚十几秒），另外每分钟重读一次；它们的卡详情只在卡变了时重读。

### 同时能做几件（Hermes 默认值，2026-11 的 main）

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `kanban.max_in_progress`（整台服务器同时在做的上限，所有看板加在一起） | 不设时，Linux 上按内存推导：总内存 ÷ 512 MB，最少 2、最多 8；macOS、Windows 上不限 | 文档里还写着"不设就不限""整个看板"，但代码（`hermes_cli/kanban_db_dispatch.py` 的 `derive_default_max_in_progress`、`_tick_spawn_budget`）已经改成按内存推导，而且数的是所有看板上在做的卡。2 GB 的 VPS 就是 4，4 GB 及以上是 8。写成 0、负数或不是整数，都当没设（按内存推导） |
| `kanban.max_in_progress_per_profile`（每个助手同时在做的上限） | 不限 | 同一个助手可以同时跑好几张卡。这个上限在每块看板上分开算：设成 1，一个助手在两块看板上可以各做一件 |
| `kanban.dispatch_interval_seconds` | 60 秒 | 卡片变成就绪后，最多等一分钟被派发；调用 `POST /api/plugins/kanban/dispatch` 可以马上派发 |
| 内存压力保护 | 自动 | 内存偏紧时这一轮最多派 1 件，告急时这一轮一件都不派（延后，不会丢） |

依赖（`parents`）不属于并发限制：前一张没做完，后一张会一直留在「排队」。

这些值在 gateway 启动时读一次，改了 `config.yaml`（或经 `PUT /api/config`）要重启 gateway 才生效。没有接口能读到正在用的值；`GET /api/config` 给的是配置里写的（没设就是 `null`），按内存推导的那个要拿 `/api/status` 的 `memory.system_total_mb` 自己算。Shion 的设置页就是这样显示的。

**`POST /api/plugins/kanban/dispatch` 不管这两个上限。** 它是「马上派发一轮」，只受每块看板 8 件和内存压力保护的限制。官方桌面端每次改完看板都会调它，所以上限在它手里会被越过。

**Shion 建议的配置**（原型就是按这个跑的）：

```yaml
kanban:
  max_in_progress: 4               # 按 VPS 内存和同时开着的云桌面数量定
  max_in_progress_per_profile: 1   # 每个助手一次只做一件
```

每个助手只有一块云桌面、一个浏览器配置。同一个助手的两张卡要是同时跑，会抢同一块屏幕和同一套登录状态。所以建议每个助手一次一件，不同助手之间照样并行。Shion 不调 `/dispatch`（它会越过上限），等下一轮派发；`dispatch_interval_seconds` 可以调短。

看板里排队的卡写明在等什么（就绪的卡按这个顺序判断）：

| 卡片上写的 | 怎么判断 |
| --- | --- |
| 等「…」做完 | 待办，详情的 `links.parents` 里有没做完（不是 done、archived）的卡 |
| 「课程」手上还有一件，做完就开始 | 就绪；这个助手在这块看板上 `running` 的数量（`/assignees`）已经到了每个助手的上限 |
| 服务器同时在做的满了（4 件），空出来就开始 | 就绪；所有看板 `running` 加起来（`/boards`）到了整台服务器的上限（设置里显示的那个，不设时按内存算） |
| 等下一轮派发 | 就绪，上面都不是：等派发器下一轮（最多 `dispatch_interval_seconds`） |
| 还没交给助手 | 就绪但没有 `assignee` |

后两种上限 Hermes 不留记录，只能这样比出来；上限是 gateway 启动时读的，Shion 读的是配置里写的值（见上），两者不一致时以 gateway 为准。

## 场景由谁负责

| 场景 | 助手 | Hermes 侧 | Shion 里看到的 |
| --- | --- | --- | --- |
| 邮件 | 邮件 | himalaya（IMAP/SMTP，大多数邮箱都能接）+ email-inbox-triage，例行整理收件箱 | 发出前到「待你处理」；需要处理的变成待办 |
| 日程 | 詩音 | iCloud 日历（CalDAV，应用专用密码） | 日程（周视图）、今天的时间线、菜单栏的「下一件」：Mac 用 EventKit 读这台 Mac 上勾选的日历，不经过服务器（见「这台 Mac 的日历和应用使用记录」） |
| 待办 | 詩音 | `shion` 插件存储，执行日期与截止日期分开；是否和 Apple 提醒事项同步见下面的风险 | 待办、菜单栏、今天 |
| 通勤路线、延误 | 通勤 | 已有的交通 MCP；按日程生成出门提醒 | 今天的通勤卡片、通知、菜单栏 |
| 课后整理 | 课程 | Notion MCP 读录音转写；按课表在课后触发 | 新待办先标"待确认日期"，在待你处理里定日期 |
| 课程提醒 | 课程 | 按日历里的课表生成例行任务；以后从 Moodle（iCal 订阅、Web Service）和教务系统补充作业截止 | 通知、菜单栏的"下一件" |
| 每日安排与催促 | 詩音 | 早报、12/18/21 点催促、睡前排明天；到了计划时间你却没在做，由 Mac 的专注检查叫醒她 | 今天页顶部的一段话、通知、菜单栏里的专注检查 |
| 应用记录与回顾 | 回顾 | 插件接收记录（`usage.upload`），22:30 写日报 | Mac 端采集，每 10 分钟上传；日报里的屏幕时间 |
| 事实核查 | 资讯 | 网络搜索与网页读取 | 对话；新闻日报里的核查标注 |
| 新闻 / 学习 / 工作 / 生活日报 | 资讯、回顾 | 例行任务生成 | 日报页 |
| 要登录、两步验证、验证码的网站（学校统一认证、Moodle、教务） | 课程等 | 助手在自己的云桌面上用浏览器操作；登录状态保留在它的浏览器里 | 「待你处理」里出现「去接管」，在云桌面页接管、登录、交还 |
| 全天录音（以后） | 新助手 | 转写 → 记忆 → 待办 | 暂不做 |

**关于日报放不放进 Shion：** 生成不放在 Shion，交给 Hermes 的例行任务：Mac 关着也能按时写，还能同时推到手机（Telegram 等平台）。Shion 只负责阅读界面，再加上提供应用使用记录这一份 VPS 拿不到的数据。

## 专注检查：本机判断，詩音只收到结论

到了计划里该做某件事的时间，Shion 看这台 Mac 前台的窗口和计划对不对得上。判断在本机做，詩音只收到一句结论，催不催、怎么催由她决定。

1. **计划从哪来。** 日程来自这台 Mac 的日历（「设置 → 这台 Mac」里勾选，每个日历标明算作「课」「专注时段」还是「日程」），待办来自 `shion` 插件。此刻落在勾选的日历里的课或专注时段里，就以它为准（几项同时进行时取最晚开始的那项）；否则取今天执行时间已到、还没做完、日期也确认过的那条待办（几条时取时间最晚的）。没有计划时不检查。全天的日程不算计划。
2. **看前台。** 每 5 秒看一次，切换应用、锁屏、睡眠时马上看。前台应用用 `NSWorkspace`；窗口标题用辅助功能接口读（`AXUIElement` 焦点窗口的标题，在后台线程上读、半秒超时，卡住的 App 拖不住界面），浏览器的窗口标题里就有网页标题。第一次打开专注检查时系统会请求辅助功能权限；测试版只做了本机签名，每装一个新版本都要在「隐私与安全性 → 辅助功能」里重新打开。用辅助功能接口读别的 App 的窗口，App 不能开沙盒，所以 Shion 不上 App Store，用 Developer ID 签名、公证后自己装。锁屏、屏幕睡眠或键鼠 5 分钟没动算"不在 Mac 前"，不算偏离，也打断偏离的计时。
3. **本机判断。** 窗口或计划变了才问一次本机模型，同样的计划、应用和标题用缓存（判断不了的 10 分钟后再问）。用 Foundation Models 的引导生成，直接拿到结构化结果（`macos/Shion/Local/ModelJudge.swift`）：

   ```swift
   @Generable nonisolated struct FocusVerdict {
       @Guide(description: "前台窗口和此刻计划的关系：same …；related …；unrelated …") var fit: VerdictFit   // same / related / unrelated
       @Guide(description: "前台窗口在做哪类事：study …") var kind: VerdictKind                          // study / work / life / fun / social / other
   }
   ```

   本机模型能看懂内容：在 YouTube 上看这门课的讲解算「相关」，看猫的视频算「无关」，只靠应用名分类做不到。看不出来时让它选「相关」，宁可少报。每次一个新的 `LanguageModelSession`，什么都不带到下一次。没开 Apple 智能或这台 Mac 用不了时不检查，设置和菜单栏写出原因。标题看不出在做什么时（比如只有应用名），以后可以让本机模型看一眼前台窗口的截图，这要屏幕录制权限，还没做。
4. **告诉总秘书。** 偏离满 5 分钟（从这段偏离开始算，不早于计划开始的时间），Mac 经插件 RPC 报一次：`plugin.shion.focus.report`，`profile` 是总秘书的（插件的 `chief_profile`），`session_id` 是总秘书 Bot Chat 的会话 id（这条连接已经接上那个对话时才带；Hermes 先查它是不是这个 profile 的会话，不是就 `not_found`），再加四个值：`plan`（计划名，1–200 字）、`off_minutes`（0–1440 的整数）、`activity`（六类之一）、`on_track`。同一段偏离只报一次；回到计划上再报一次（`on_track: true`，`off_minutes` 是那段偏离有多长）；计划结束了就不再报"回来"。连不上或插件不在时不报，偏离还在的话一分钟后再试。插件用 Hermes 的 `ctx.inject_message` 把这句话放进总秘书的 Bot Chat，叫醒总秘书（那个 profile 的插件要开 `allow_gateway_injection`）。总秘书的例行催促也能用插件工具查最新结论。**插件叫谁，跟着这台 Mac 选的总秘书走：** 插件只在它设置里的 `chief_profile` 里叫人（所有 profile 共用一份设置，默认 `shion`），所以在「设置 → 助手」里换了总秘书，Shion 马上在新总秘书的 profile 里调 `plugin.shion.settings.update`（`chief_profile` 设成它）；之后每次连上服务器（断线重连也算），只要这台 Mac 明确选过总秘书、又和插件的 `chief_profile` 不一样（先 `settings.get` 看一眼），就再改一次。这台 Mac 没选过的，照规则（`shion`，没有就默认 profile）走，不动服务器的值。新总秘书的 profile 没装插件（Hermes 回 `-32601`）就改不了，失败了也不挡别的事，下次连上再试；原因写在「设置 → 这台 Mac」专注检查那一节的「插件叫醒」里。万一一次报告在改好之前发出去、得到 `wrong_profile`，Mac 先改设置，再报一次。参数照 `hermes-plugin/README.md` 和 `hermes-plugin/shion/` 核对过，Hermes 那一侧（`profile` 的转发、`session_id` 的检查、插件出错时的 `plugin_rpc_failed`）照 `gateway/session_controls.py`、`gateway/session_plugin_rpc.py`、`gateway/session_authority.py` 核对过（2026-11-09 的 main）。
5. **詩音决定。** 比如"小测原定 10:45 开始，已经过了 7 分钟。15 分钟就能做完，现在开始吧？"。Mac 合上或离线时没有结论，她照旧按时间提醒。

隐私：
- 窗口标题、应用名和这段时间线只存在这台 Mac 上（`~/Library/Application Support/Shion/focus.json`，文件夹只有你能读），保留 7 天，设置里可以随时清空。
- 发给詩音的只有：此刻的计划、偏离了几分钟、在做哪类事。设置里专注检查的开关下面写明发什么、不发什么，界面里不另加说明；插件放进詩音对话里的那句话（以「［专注检查］」开头），Shion 也不显示。
- 菜单栏里可以暂停 1 小时，设置里可以关掉（默认关着，打开时才请求权限）。

App 里：菜单栏弹出面板的第一行就是专注检查：计划和现在的情况两行（「「机器学习 课前小测」原定 10:45」「7 分钟没在做」），点开能看到最近的几个窗口和各自对不对得上，还有暂停按钮。「设置 → 这台 Mac」里的「专注检查」一节有开关、辅助功能权限、本机模型能不能用、最近一次告诉了詩音什么（没叫醒她时写原因），和清空窗口记录。

## 这台 Mac 的日历和应用使用记录

**日历。** Shion 用 EventKit 读这台 Mac 上「日历」App 里的日历（iCloud、Google 等账户都在那里），日程不经过服务器。连上过一次服务器以后，没连着时今天页和日程页也照样显示这台 Mac 的日程；一次都没连上过这个地址时，窗口里只有「先连上你的 Hermes 服务器」（见「没连上时显示上次的数据」），这两页要连上以后才有，只有菜单栏的「下一件」照常显示。
- 设置里按账户列出所有日历，每个有颜色、名字和勾选框；只读勾上的那些。第一次列出时默认勾上除了生日和订阅日历（节假日）以外的。勾选按日历的标识（`calendarIdentifier`）存下来，换了名字也不丢；每个日历还能选算作「课」「专注时段」还是「日程」（先按名字猜：课表、時間割、class 算课，专注、focus 算专注时段），专注检查只拿前两种当计划。
- 用在今天页的时间线、日程页的周视图和菜单栏的「下一件」。日程的颜色是日历自己的颜色；全天的日程在周视图顶上一行、在今天页写「全天」；同一时间的几项在周视图里并排；跨过午夜的在两天里各画一段；时间轴默认 8 点到 22 点，有更早或更晚的日程时跟着放宽。
- 读的是一周前到两周后。日历一有变化（`EKEventStoreChanged`，同步时会连着来好几个，等 0.5 秒再读）马上重读；新的一天、在系统设置里给了或收回权限，30 秒内也会重读。
- 没允许读取时没有日程，日程页的工具栏和「设置 → 这台 Mac」里各有一个「读取这台 Mac 的日历」的入口：第一次弹出系统的询问，拒绝过的话打开系统设置。截图模式不申请权限，用一组假的日历（`macos/Shion/Local/LocalFixtures.swift`）。

**应用使用记录。** 记下哪个应用在前台、从几点到几点，不需要任何权限（`NSWorkspace`），默认开着。
- 每 5 秒看一次，切换应用时马上看；在本机压成一段一段的：一个应用在前台的一段时间是一段，不记窗口标题。在一个应用里不到 5 秒的（切换时路过）不算；锁屏、屏幕睡眠、键鼠 5 分钟没动的时间不算（那一段截在最后一次键鼠操作）；Mac 睡着时没看到的时间不算；一段最长 12 小时。
- 存在这台 Mac 上（`~/Library/Application Support/Shion/usage.json`），保留 7 天。连上装了插件的服务器时马上传一次，之后每 10 分钟传一次上次之后新的和变了的段（正在进行的那段也传，结束后带着同样的开始时间再传一次，服务器按应用和开始时间认出是同一段）：`plugin.shion.usage.upload`，`segments` 里每段只有 `bundle_id`、`app_name`、`start`、`end` 四个字段（插件多一个字段就整次拒绝），时间是带这台 Mac 时区偏移的 ISO 8601，`device` 是 `mac`。服务器上默认保留 30 天。「回顾」用插件的 `shion_usage_day` 写日报里的屏幕时间。
- 设置里能关掉（关掉后不记也不传），能排除应用（从这周用过的应用里挑，或者在「应用程序」里选）：排除的应用不记录，这台 Mac 上已有的那部分也删掉，已经传出去的留在服务器上（插件没有删的方法）。
- 窗口标题只给专注检查用，不进使用记录。服务器只知道哪个应用、从几点用到几点；「回顾」按应用的类别算屏幕时间（`usage.day` 的 `by_category`，应用的类别用插件工具 `shion_usage_set_category` 改），这是插件本来的设计，不在 Mac 上另做摘要。日报下面的屏幕时间图用的也是插件算好的这一份（`usage.day`），见下面「日报里的屏幕时间」。

## Canonical Gateway Protocol 要点（写 Swift 客户端时用）

依据 Hermes `main`（2026-11）的 `apps/desktop/docs/canonical-gateway-protocol.md`、`tui_gateway/contracts/canonical*.py` 和生成的 `apps/shared/src/gateway-contract.generated.ts`。

- **连接**：WebSocket `/api/ws`，子协议 `hermes-gateway-v1`，方法表是 `CANONICAL_METHODS`。连上后先 `client.capabilities {server_requests: true}`，否则审批和提问会被直接撤回。
- **鉴权**：本机由 profile 目录下的私有 control socket 签发一次性 ticket（30 秒）。远端经 Cloudflare Access，再加可选的 Hermes 会话 token（见下一节）。
- **身份**：`session.create` 带 `source`（必须在 `runtime.describe` 的 `session_create.sources` 里）和 `client: {name: "shion"}`（服务器有 `session-client-v1` 时；只是个标签，什么都不影响）。
- **助手以为你在用什么界面**：系统提示里的平台说明和 `Platform:` 一行来自会话的 `source`，建会话时定下，之后改不了：`gui` 是桌面应用（`desktop`，按 Markdown 写），`cli` 是终端（不用 Markdown），不带 `source` 默认 `cli`。Shion 建的 Bot Chat 用 `gui`。可是按标题建 `Bot Chat` 时已经有一个，就直接沿用旧的；而 Hermes 自己替还没有 Bot Chat 的 profile 建的（定时任务送达、助手之间私信、`hermes chat -c "Bot Chat"`）都是 `cli`。所以较早的 Bot Chat 多半是 `cli`，要换只能新开一个。
- **对话分页**：`session.resume` 带 `omit_messages: true` 只接上会话、不带历史；再用 `session.transcript {order: "latest", limit, cursor}` 一页一页往前取（服务器有 `session-transcript-v1` 时），每页最多 500 行，按存的行数算，工具调用一行算一行。不带 `omit_messages` 的 resume 会把整段历史发两遍（`messages` 和 `display_messages` 各一份）。官方桌面端用的是 REST 的 `/api/sessions/{id}/messages?order=latest&offset=`。
- **Bot Chat**：一个助手 = 一个 profile = 唯一一个标题为 `Bot Chat` 的会话。用 `session.list {title, include_hidden: true}` 按标题找，`profiles.list` 也直接给出 `canonical_session`。不存会话 id 指针。
- **可靠提交**：客户端的 `submission_id`（或 `input_id`）和服务端的 `admission_id` 分开，以回执为准（`prompt.receipt`、`prompt.resolve_unknown`）。Hermes 按（登录的人、会话、`submission_id`）只收一次：同一个 id、同样的内容再发，回的是原来那次的回执，不会再跑一轮；同一个 id 换了内容是 `admission_conflict`。收下时马上发一帧 `session.info`，`pending` 里按 `input_id` 列出还在排队、在跑的；一轮结束的 `message.complete` 里，`persisted_turn.submission_id` 说跑的是哪一次。`prompt.submit` 只收在这条连接上接上了（resume 或 create）这个会话的，别的是 `permission_denied`。一轮还在跑时再发，排在它后面，不会打断它（要不要打断是客户端自己的事）。以上按 `hermes-agent` 的 b3746e35 核对过（`gateway/session_controls.py`、`gateway/session_authority.py`、`hermes_state_runtime.py`）。
- **审批、提问**：回复要对准 `prompt_id` 和 `execution_generation`，也要在这条连接上接上了会话；断线重连后先 `session.events.since`，再 `session.resume`，快照的 `prompts` 列着还没回答的。
- **断线重连**：每帧事件带会话自己的 `seq` 和 `replay_epoch`，会话留最近 512 帧（最多 4 MiB）。新连接上对每个会话问 `session.events.since {session_id, last_sequence, replay_epoch}`：回之后的帧，或者 `snapshot_required`（服务器重启过、帧已经不在了、游标比最新的还新）。在还没接上这个会话的连接上问过，接着的 `session.resume` 会先补上两次之间新发的帧再接上，中间不漏。断开的连接按孤儿处理：这一轮照常跑完，批准一直等着（`gateway/session_events.py`、`tui_gateway/event_replay.py`、`gateway/session_viewer_close.py`）。见「断线重连」。
- **sudo 密码、技能的密钥**：不是事件，是服务器发来的 JSON-RPC 请求（`sudo`、`secret`），用响应回答，`request.cancel` 撤回，见「助手要密码和密钥时」。
- **一次运行的编号和会话的版本**：每轮开始时会话的 `execution_generation` 加一，这一轮的每个事件帧都在 `params` 里带着它（和 `payload` 并列）；每轮结束 `revision` 加一。快照（`session.resume`、`session.create` 的回复）带当前的两个值，每轮结束的 `session.info` 也带（`gateway/session_authority.py` 的 `_publish_pending`：客户端只能从这里知道每轮之后的 `revision`）。
- **停止**：`session.interrupt {session_id, execution_generation}`（`profile` 只管路由；参数是封闭的，多一个少一个都是 `invalid_params`）。编号不是这一轮的就拒绝（`stale_generation`），对上了就硬停这一轮的 agent（压缩也停，后台委派不停），回复是会话的 handle。停下后这一轮照常结束：`message.complete` 的 `status` 是 `interrupted`（`outcome` 是 `cancelled`），`text` 是已经流出来的部分，什么都没出来时是一句占位（`Operation interrupted: …`），随后是 `running: false` 的 `session.info`。已经出来的部分存成一行助手消息，带 `display_metadata.interrupted`；停在工具调用之后的，收尾的那行也带这个标记（没有文字时是一行隐藏的占位）。
- **重试**：Hermes 的 `/retry` 是两步，官方桌面端的「重新生成」在 canonical 上也是这样拆的：先 `session.mutate {session_id, request_id, expected_revision, expected_generation, operation: "rewind", payload: {target_message_id}}`，把那条用户消息（`row_id`）和它后面的都收回（要空闲，在跑时是 `session_busy`；`revision` 或编号对不上是 `revision_conflict` / `stale_generation`，拒绝的 `error.data` 里带着新的两个值），回执的 `target_message.content` 是原来打的字；再 `prompt.submit` 一次。canonical 的 `prompt.submit` 没有截断参数（旧接口的 `truncate_before_row_id` 这些会被拒）；`session.branch_stored` 是另开一个会话，Bot Chat 只能有一个，不用。一轮结束时 `message.complete.persisted_turn` 给出这一轮存成的行：`user_row_id` 是提问那行，`submission_id` 是提交时带的那个，所以 Shion 用聊天里那条消息的 id 当 `submission_id`，就知道它存成了哪一行。压缩过的会话里，按压缩前的行号收回一条留下来的消息，和收回一条总结掉的一样被拒：`invalid_params`，`field: target_message_id`，`detail` 是 `compacted: target user message was summarized when the session was compressed`（原地压缩和换成新会话都是，`macos/ci/real` 的 `compact` 阶段）；Hermes 自己原地压缩时，留下来的原行标成收回过的，`detail` 是 `target user message is no longer in session history`（`auto` 阶段）。按新的行号照常收回。
- **出错**：一轮出错时 `message.complete` 的 `status` 是 `error`。`error_surface` 是个对象 `{layer, code, retryable, …}`（`agent/error_surface.py`），不是文字；可读的说法看是哪种 gateway：TUI gateway 的帧把消息放在 `error`（`tui_gateway/session_auto_continue.py`），Shion 连的会话 gateway 不带 `error`，`text` 就是 Hermes 自己写的出错说明（`gateway/session_settlement_recovery.py` 的 `completion_payload`，`outcome` 是 `failed`），`partial` 为真时 `text` 才是已经流出来的回复；`failure_reason` 是个代号（比如 `rate_limit`），只给本机的查看端。官方桌面端也是先 `error`、再 `text`。对话记录里这一轮以一行助手消息收尾：`display_kind` 是 `failed_turn`，文字是 Hermes 的固定说明，`display_metadata` 里有 `error` 和 `error_surface`。固定说明有三句（`agent/turn_failure_copy.py`）：没处理（`FAILED_TURN_NOTICE`）、这一轮调用过工具时的「有些操作可能已经执行了」（`PARTIAL_FAILED_TURN_NOTICE`，gateway 看这一轮有没有工具行或带 `tool_calls` 的助手行来选），还有自动投递被打断的那句。会话 gateway 跑一轮用的是和平台 gateway 同一个 `_handle_message`，出错时也把这句说明隔一个空行接在 `text` 后面（`gateway/run_turn.py` 的 `_hmwa_add_failed_turn_notice`，发消息的不是 bot 就加，上下文超长除外）。`error_surface.retryable` 只是对 API 报错的分类（限流算可重试），不管这一轮有没有调用过工具。
- **不在 canonical 里的**：看板走 `/api/plugins/kanban/*`，例行任务列表走 `/api/cron/jobs`（canonical 里只有 `cron.submit` 立即运行和 `cron.status`）。
- **图片和文件**（详见 `docs/files-and-images.md`）：图片先 `POST /api/chat/image-upload?profile=` 存进那个助手的 `cache/images/`，再放进 `prompt.submit` 的 `attachments: [{path, mime}]`（只认这两个键，PNG/JPEG/GIF/WebP，最多 10 张）；文件用 `file.attach` 换一个 `@file:` 引用，放在消息文字的最前面（同一条 `/api/ws` 上调，会话要先在这条连接上 resume 过）；服务器上的图和文件用 `/api/fs/read-data-url`、`/api/fs/download` 取。这几个 REST 路由都只认请求头里的凭证，没写进 Hermes 的用户文档。
- **类型生成**：`apps/shared/src/gateway-contract.openrpc.json` 可以生成 Swift `Codable` 类型，不用手写。

## 助手要密码和密钥时

助手在一轮里有时要你给一样东西才能接着做：终端工具跑 `sudo` 要密码（比如 `sudo apt-get install -y ffmpeg`），或者一个技能缺它要的环境变量（比如 notion 技能的 `NOTION_API_KEY`）。Hermes 把这一步停下来，问挂在这个对话上的窗口。以前 Shion 一律回「不处理」（-32601），Hermes 当成拒绝，那一步直接失败。现在：

- **卡片**：那个助手的对话里出现一张卡片，排在那次工具调用后面；「待你处理」里是同一张，侧栏、今天的「需要你」、菜单栏和 Dock 的件数都算它。卡片写着谁要、拿去做什么（工具名和那条命令；或者技能名、Hermes 的提示文字和去哪拿），要的是环境变量时写出变量名，让你知道交出去的是什么。下面一个密码框，「提交」「拒绝」，右上角是还剩多久。今天和 ⌥Space 小窗里只有一行：「填写」打开那张卡所在的对话，「拒绝」直接拒绝。
- **同时来好几个**：每个一张卡，答一个不影响别的。Hermes 的并行工具调用会同时问。
- **结束了**：提交、拒绝、过期，或者别的窗口先答了，卡片收成一行（见下一节），写「已提交」「已拒绝」「已过期」「在别处回答了」，离开「待你处理」，通知也撤掉。Hermes 等 2 分钟；这一轮结束了（停止、出错）也算过期。
- **通知**：对话和「待你处理」都不在眼前时，发一条只写「课程 要一个密码」或「课程 要一个密钥」的通知，没有按钮，不能在通知里填（通知里的输入框是明文的），点了打开 Shion 的「待你处理」。
- **断线**：卡片留着，先不能提交，写「连接中…」或「未连接服务器」；重连后先用 `session.events.since` 补上错过的帧（里面有 `request.cancel` 就照样收起卡片），再 `session.resume`：它的 `open_requests` 里还有这个请求，就又能填，没有了就算过期。在设置里断开时，还在等的先算过期，再连上时 `open_requests` 里还有就重新打开。Shion 没开着时来的、还在等的，连上后也从 `open_requests` 出现（这种不知道还剩多久，不显示倒计时）。

Shion 绝对不做的：
- **不留**：你填的值不显示、不打印、不记日志，也不存：不进 last-data.json，不进偏好设置（UserDefaults），不进钥匙串，不写进这台 Mac 上的任何文件。它只在卡片的输入框里，提交时交给连接，输入框随即清空，Shion 不留那个字符串。
- **不进对话**：答完，对话里只有「已提交」。
- **只发一次，只发给这台服务器**：经发来请求的那条连接发回去，不重试；没发出去就写明为什么，要你再填一次。断线重连后，要等 resume 确认它还在等，才能在新连接上答。
- **截图和辅助功能里也没有**：密码框（`NSSecureTextField`）在屏幕上、截图里、辅助功能读到的值里都只有圆点。
- **不接自动填充**：密码框不设 content type，系统「密码」App 不替你填，也不会在你填完后提出保存。这是服务器上的 sudo 密码和第三方服务的密钥，不是这台 Mac 上哪个网站的登录：自动填充按网站对应，Shion 没有对应的网站，能填进来的多半不对；提出保存的话又会把它存进钥匙串。存在「密码」App 里的，复制过来粘贴。没核实：不设 content type 时，macOS 27 会不会照样猜着提供自动填充，没在真机上看过。
- **不替你回答别的**：只处理 `sudo` 和 `secret`；别的 server request（批量的 `clarify`、vault 系列、`display.install.sudo` 等）照旧回 -32601，Hermes 当成没答。

**线上的样子**，按 hermes-agent `b3746e35`（2026-11-09）的源码核对：

| | |
| --- | --- |
| 形状 | server→client 的 JSON-RPC **请求**（`tui_gateway/contracts/server_requests.py`）。没有 `sudo.request` 事件、`sudo.respond` 方法和 `sudo.expire` 事件：那是官方桌面端和 TUI 收到请求后自己内部用的名字（`tui_gateway/server_requests.py` 开头写明：no paired `*.request` notification / `*.respond` method, no per-kind `*.expire`） |
| 谁收到 | 挂在这个对话上的窗口（`gateway/session_server_requests.py`），而且只在窗口自己开的对话里（`local_viewer_turn`：`session.create` 建的会话是 LOCAL 平台）；一个窗口都没挂着时不发，当成没答。Telegram 这类平台上的对话没有这一步 |
| sudo | `{"jsonrpc": "2.0", "id": "srq-<12 位十六进制>", "method": "sudo", "params": {"session_id": …, "command": …}}`：`command` 是原来的命令，服务器先脱敏（`_redact_approval_command`）。工具名不在里面，Shion 用这个对话上一次 `tool.start` 的名字 |
| secret | `"method": "secret"`，`params`：`session_id`、`env_var`（变量名）、`prompt`（技能写的提示，没写是 `Enter value for <变量名>`）、`metadata`：`skill_name`，可能还有 `help`（去哪拿，常是网址）、`required_for`（`tools/skills_tool_setup.py`） |
| 回答 | 同一个 WebSocket 上回 JSON-RPC 响应 `{"jsonrpc": "2.0", "id": "srq-…", "result": {"value": "…"}}`，服务器不回复它（`gateway/session_controls.py` 的 `dispatch`）。只有挂在这个对话上、有 `session:respond` 权限的连接答得了（`may_settle`）；断线后还没重新 resume 就答的，服务器只按 id 记一笔，然后丢掉 |
| 拒绝 | `"value": ""`。回 error 响应也一样当成空 |
| 多久 | sudo 和 secret 都等 120 秒（`gateway/session_sudo_prompt.py` 的 `SUDO_TIMEOUT_S`、`gateway/session_secret_prompt.py` 的 `SECRET_TIMEOUT_S`）。请求里不带这个数，Shion 从收到时算起；这一轮被打断也就不等了 |
| 撤回 | 事件 `request.cancel {id, method, reason}`，发给这个对话上的所有窗口：`reason` 是 `timeout`、`interrupted`；有窗口答了是 `resolved` |
| 重连 | `session.resume`（和 `session.events.since`）的回复里有 `open_requests: [{id, method, params}]`，还在等的请求原样再给一遍 |

**Hermes 拿到之后**（同一个提交）：
- sudo 密码经 `sudo -S -p ''` 的标准输入交给那条命令，不上命令行（`tools/terminal_tool_sudo.py`）；在 gateway 进程的内存里按对话记住，这次对话里下次 sudo 不再问，sudo 说密码不对就忘掉；不写盘。
- 密钥写进那个 profile 的 `.env`（`save_env_value_secure`），模型拿到的工具结果里只有变量名（`missing_names`、`setup_skipped`）。
- 所以**对话记录里没有这个值**：工具调用是模型写的原命令，结果是命令的输出或变量名；服务器自己的日志里只有请求的 id（`gateway/session_server_requests.py`：Values are never published, journaled or logged）。没核实的：技能自己的代码拿到环境变量以后会不会把它打出来，那是那个技能的事。

## 答完以后留在对话里的一行

批准、提问、密码和密钥，答完就从「待你处理」里消失，在对话里问的那个位置留下一行（⌥Space 小窗里也是，在回复下面），写明问的是什么、结果怎样：
- 批准：「已允许这一次」「这次对话都允许」「以后都允许」「已拒绝」；
- 提问：「你回答：中村老师」，或者「跳过了」；
- sudo 密码、密钥：等着的时候是卡片，结束了收成一行：「已提交」「已拒绝」「已过期」「在别处回答了」。绝不写你填的值，也不写长度。

**这一行只在这次运行里有。** Hermes 的对话记录里没有这些结果（按 hermes-agent `b3746e35` 核对：`session.transcript` 和 `session.resume` 的行出自 `tui_gateway/session_history.py` 的 `_history_to_messages`，工具行只有调用（名字、`context`、参数），不带结果，只有 `write_file`、`patch`、`skill_manage` 三种例外；`display_metadata` 里只有编辑的 diff。批准选了什么、提问答了什么都只在工具的结果里；sudo、secret 的请求本身根本不进对话记录）。所以这一行是 Shion 自己记在内存里的：重连、重新打开对话、重新读对话记录都还在；按服务器分开记，换一台服务器就不显示；退出 Shion 就没了，也不写进 last-data.json。在别的窗口（官方桌面端、TUI）答的批准和提问，Shion 不知道答了什么（`approval.settled` 只带 `prompt_id`），就不留这一行；示例数据里点的批准照旧在对话里加一句你说的话。

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
- **待你处理、系统通知**：助手卡在要人来做的步骤时，出现「去接管」。

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

**为什么自己写。** 服务端只有一种：Hermes 画面桥后面的 TigerVNC（Xvnc，`-SecurityTypes None`、`-AlwaysShared`），握手是固定的，要支持的编码也就几种。传输是 WebSocket，用 `URLSessionWebSocketTask` 带上 Access 的两个头。它要一直挂着一个接收，才拿得到服务器的关闭码（比如别人接管时的 4000）；Network.framework 的 WebSocket 在 macOS 上实测拿不到，只留作备用。点画面接管、点外面交还、租约、交还快捷键、下面说的粘贴输入，这些用现成的库也得自己加。

不选的几条路：
- **RoyalVNCKit**：MIT 许可，自带处理键鼠的 macOS 画面视图，但 2026-10-05 已归档只读，而且只走 TCP。用它等于 fork 过来自己维护，还要换掉传输层。它的解码和键位表可以参考，按 MIT 的要求保留版权声明。
- **libvncclient、TigerVNC 自带的 viewer**：都是 GPL，也一样要自己接 WebSocket。
- **noVNC**：官方桌面端用的就是它，但它是网页，和"不套浏览器"冲突；网页里的 WebSocket 带不了 service token 的请求头，还得先拿到 Access 的 cookie 塞进 WebView。只在自己的客户端做好之前，用 SwiftUI 的 `WebView` 跑它过渡。

分几步做（协议部分在 `rfb/`，一个不依赖 App 的 Swift 包，说明、测试样本和测试环境都在那里的 README）：

| 阶段 | 内容 | 现在 |
| --- | --- | --- |
| 探路 | 命令行小程序：`display.observe` 拿 ticket，带 Access 头连上画面 WebSocket，走完 RFB 3.8 握手，把收到的数据存下来当测试样本 | `rfb-probe` 做好了，在 Linux 的测试环境里对着 Xvnc 和 Hermes 自己的过滤器测过；还没对真服务器跑 |
| 只看 | 编码 Raw、CopyRect、ZRLE（用系统自带的 zlib），伪编码 DesktopSize；画到 IOSurface 上交给 `CALayer` 显示，按窗口等比缩放 | 协议部分做好了（解出来的画面和真实屏幕逐像素一致）；App 里的画面还没做 |
| 接管 | 租约；鼠标、滚轮（坐标换算回远端）；键盘（字符换成 X keysym，功能键按键码映射）；输入法（`NSTextInputClient`）；Cursor 伪编码；TigerVNC 的扩展剪贴板（UTF-8） | 消息的格式做好、测好了；租约、App 里的键鼠和输入法还没做 |
| 以后 | 带宽不够再加 Tight + JPEG（JPEG 用系统的 ImageIO 解）；断线后自动重连 | — |

键盘和中文、日文输入：
- **⌘ 当成 Ctrl 发过去**，⌘C、⌘V、⌘L、⌘T 在远端浏览器里照 Mac 的习惯用；⌘Tab、⌘Q 仍然归 Mac。
- **⌘V 先同步剪贴板**：把 Mac 剪贴板里的文字用剪贴板消息放进远端，再发 Ctrl+V。**⌘C 取回 Mac 现在做不到**：Hermes 用 `-SendCutText=0` 启动 Xvnc（只看的人不能拿到持有者复制的东西），服务器根本不往外发剪贴板，接管时也不发。要做得等 Hermes 改：桥只把 ServerCutText 转给持有租约的人，或者加一个读远端剪贴板的 gateway 方法。
- **中文、日文在你点的地方直接打。** 画面视图接上 Mac 的输入法（实现 `NSTextInputClient`）：点一下远端的输入框，照常用输入法打字，拼写中的文字和候选窗口就出现在你点的位置；确认后的文字用剪贴板消息放进远端，再发 Ctrl+V 粘进去，不碰 Mac 自己的剪贴板。英文、数字和快捷键不经过这一步，照常按键发。
  - 不逐字发 Unicode keysym：TigerVNC 1.10 起剪贴板支持完整的 Unicode，而逐字发的话 Xvnc 要临时给每个字分配键位，有人遇到过分配失败后键盘没反应（[TigerVNC #93](https://github.com/TigerVNC/tigervnc/issues/93)）。
  - 远端不会告诉我们光标在哪，所以先用你最后一次点的位置；用 Tab 换了输入框，就再点一下。以后可以再准一点：Xvnc 只发画面上变了的区域，光标闪烁就是点击位置附近一个反复出现的细长小块，找到它就能把拼写中的文字对准远端光标。
- 密码也一样：从 Mac 的密码管理器复制，⌘V 粘过去。

和画面桥打交道的规矩（依据 Hermes 的 `hermes_cli/web_routers/display.py` 和 `tools/bot_desktop/rfb_filter.py`）：
- 只发桥认得的消息：SetPixelFormat、SetEncodings、FramebufferUpdateRequest、KeyEvent、PointerEvent、ClientCutText（含扩展剪贴板），以及 TigerVNC 的 EnableContinuousUpdates、Fence。发别的，桥分不清消息边界，会直接断开。剪贴板一次最多 256 KB。桥还认 SetDesktopSize（251）和 QEMU 扩展键盘（255），都算输入、只放行给持有租约的人；Shion 都不发。
- 扩展剪贴板只能先宣告、等 Xvnc 来要：它不收直接推过去的文字，远端程序粘贴时才来取，所以这时连接要开着。只看时桥连能力声明也丢，每次粘贴前再声明一次。
- 声明了 Fence 就要应答（不应答，画面一秒左右就停），连续更新要靠它；两样都用，远的线路上帧数能翻倍。
- 不发 SetDesktopSize：它会连助手的屏幕分辨率一起改掉。窗口大小只影响本地缩放。
- 只看时不开 Cursor 伪编码，让服务器把助手的光标画进画面，看得到它在点哪；你接管后再打开，光标在本机画，不跟着网络卡。
- 离开画面时用 1000 正常关闭 WebSocket，桥会顺带交还，1001 也一样；网络断了不算，控制权还在你手里。被别人接管时桥用 4000 关掉连接，换一张新 ticket 回到只看。关闭码不是每次都拿得到（网络断了就没有），所以连接断了、又没有关闭码时，先看 gateway 上的 `display.lease`：持有者的 `viewer_hash` 不是自己的，就是被挤掉了。Host / Origin 不对时桥在握手前就拒了，看到的是 HTTP 403，不会出现 4403；Xvnc 没了时桥用 1000 关闭，这时再查一次 `display.status`。
- `display.*` 每次都带 `profile`，不带时回答的是 gateway 自己那个 profile 的屏幕。
- 有人接管时 `display.thumbnail` 不给图（`data_url: null`，`suppressed: human_has_control`），因为画面上可能有正在输入的密码；缩略图和侧栏预览要照顾到这种情况。
- 只断了画面连接时，带上原来的 `viewer_id` 再调 `display.observe`，租约还在；gateway 连接也断了的话，旧 id 就不认了，重连后用新 id 再接管一次。
- 只看时画面不在眼前（窗口最小化或被挡住、切到别的页面）就断开，只留缩略图。连着的时候桥会当作有人在看，云桌面不会闲置自动停。
- ticket 一次性有效，不写进日志。

## 还没验证的风险

1. 第三方客户端能用哪个 `source`（官方桌面端用 `gui`）。要在我们的 VPS 上看 `runtime.describe`。
2. 远端经 `hermes serve` 时，canonical 方法和插件 RPC 是否都能用。
3. 官方 Bot Mode 把头像、分组等存在 profile 的 `ui_meta` 里。Shion 现在读写其中的显示名（`ui_meta['hermes-bots'].title`，经 `profiles.configure`，按版本号比对后才写，这一节的其余键原样写回），头像和分组还没接。
4. **云桌面相关的方法不在 canonical 方法表里。** `display.*` 属于通用方法表，官方桌面端在远程连接上能用。要验证 Shion 经 Cloudflare 连上后，同一条连接能不能调到它们。
5. **RFB 客户端是整个项目最大的一块**，做法见上面「画面客户端」。测试环境（Xvnc 1.13.1）里已经确认：扩展剪贴板能传中文、日文、emoji，用「剪贴板 + Ctrl+V」打进 Chrome 的输入框一字不差；中途开 Cursor 伪编码立刻生效；ZRLE 静止时很省（一页文字首帧约 180 KB），Chrome 滚动时约 2.5 MB/s。还要确认：VPS 上的 TigerVNC 版本；在真的 Cloudflare 线路上用 `rfb-probe` 量一次带宽，再定要不要做 Tight + JPEG。
6. **浏览器登录经过真的 Cloudflare Access。** 第一次带着 service token 打开登录窗口时，提交密码被严格模式拦下了，现在已经改成不带。CI 上的替身照严格模式演 Access，登录页在另一个域名上；还要在我们的域名上确认一次：登录完 Access 回到原来地址时，查询参数（PKCE、state）原样带回。
7. **Apple 提醒事项经云端读写不一定可靠。** iCloud 日历走 CalDAV 没问题；但按 BusyMac、2Do 的说明，iOS 13 / macOS Catalina 之后升级过的提醒事项列表不再走 CalDAV，有的 MCP 声称能读写，说法不一。先用实际要用的工具测一遍；不行的话，就由 Mac 上的 Shion 用 EventKit 读写提醒事项（这正好是"接入本机"的第一个用途），或者以 `shion` 插件里的待办为准，只往提醒事项单向同步。
8. **专注检查在真的 Mac 上只在 CI 之外验证。** runner 上没有辅助功能权限和 Apple 智能，测试里换成了假的前台窗口和固定规则：系统模型对中文、日文窗口标题判断得准不准，有些 App（比如部分 Electron 应用）读不读得到窗口标题，都还要在自己的 Mac 上看。

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
| Liquid Glass：`.glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass)` / `.glassProminent`；27 起 `Glass.interactive()` 在 Mac 上响应点击 | 只给浮在内容上面的控件：输入框、⌥Space 小窗、⌘K 面板、云桌面的接管条、菜单栏弹出面板（规则见「界面原则」）。侧栏和工具栏系统自己会换成玻璃 |
| 同心圆角：SwiftUI 的 `GeometryProxy.concentricCornerRadii`，AppKit 的 `NSView.cornerConfiguration`（`.containerConcentric`） | 云桌面画面（AppKit 视图）的圆角和窗口同心 |
| `ToolbarSpacer` | 工具栏按钮分组，「跟詩音说」单独一组 |
| 任意容器里的轻扫和拖动排序：`swipeActions` + `swipeActionsContainer()`，`.reorderable()` + `reorderContainer(for:isEnabled:move:)` | 待办行轻扫完成或推迟，今天的待办拖动排序；不用为了这些换成 `List` |
| AppKit `NSStatusItem` 的 `expandedInterfaceDelegate` | 菜单栏用 `NSStatusItem`（橙色数字角标好画），弹出面板显示时告诉系统，键盘焦点才对 |
| Siri 和 Spotlight（App Intents）：App Schema（`@AppIntent(schema:)`、`@AppEntity(schema:)`），`IndexedEntity` 和 27 新增的 `IndexedEntityQuery`，屏幕感知（`appEntityIdentifier`） | 待办、任务卡、日程做成实体：Spotlight 里搜得到；新 Siri 能拿它们回答"我今天还有什么没做"，也知道你正在看哪张卡。Siri AI 还是测试版，27.2 起支持日语，简体中文还没有，所以 Mac 的 Siri 语言要设成日语 |
| 通知关联实体：`UNMutableNotificationContent.appEntityIdentifiers` | 詩音的催促、待你处理的通知带上对应的待办或任务卡，Siri 知道"这个"指的是哪件 |
| 控制中心和菜单栏里的控件（`ControlWidget`） | 「跟詩音说」「暂停催促一小时」 |
| 桌面小组件（WidgetKit） | 下一件事、通勤延误、待你处理的数量 |
| Foundation Models（本机模型） | 只做离线、隐私、要即时反应的小事，见下面「本机模型」 |
| Swift 6.4：`defer` 里能 `await`，`withTaskCancellationShield`；还有默认主线程隔离、`@Observable` 和 `Observations`、`Span` | 离开画面时 `defer { await 交还 }` 并加上取消保护，保证一定交还；界面状态在主线程，Gateway 连接和 RFB 解码各放在自己的 actor 里；RFB 解码用 `Span` 读写字节，不用 unsafe 指针 |
| SwiftUI `WebView` / `WebPage` | 只在 RFB 客户端做好之前，用来跑 noVNC 过渡 |

等 27.3 正式发布再用：Mac 上原生的实时活动（ActivityKit），把助手在做的事和进度放进菜单栏；Siri 把任意 App Intent 当工具调用（`@AppIntent(.tool)`）和 App 技能，现在是开发者预览，不能分发。

查过、27 没有新接口的：读前台应用和窗口标题（仍然是 `NSWorkspace` 加辅助功能接口）、Screen Time（macOS 上仍然没有 DeviceActivity）、EventKit、可操作的通知、`MenuBarExtra`。

### 本机模型

理解、拆解、写日报这些仍然交给 VPS 上的 Hermes，因为要用到助手的记忆、工具和日程。本机模型只在三种时候用：连不上 VPS；数据不该离开 Mac；要立刻有反应，等不了一次网络来回。

| 用在哪 | 为什么放在本机 |
| --- | --- |
| 专注检查：判断前台窗口和此刻的计划对不对得上，只把结论告诉总秘书（见上面「专注检查」） | 窗口标题不出 Mac，而且要即时 |

连不上 VPS 时 ⌥Space 里说的话不交给本机模型记成待办草稿，而是原样排队、连上后发出，理由见「快捷呼出」。

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
| 页面切换、深链接（`#card-…`） | 侧栏选中状态；通知点进来按它的 userInfo 直接到那一项（`Landing.swift`，见「点通知」），暂时不需要 URL scheme | 低 |
| 待办、待你处理、日报列表 | `LazyVStack` 加 `swipeActionsContainer()`、`reorderContainer`，`.contextMenu`，`.onHover` 显示「现在运行」 | 低 |
| 任务详情、待办详情 | `.inspector` | 低 |
| 看板拖卡片 | `.draggable` + `.dropDestination` | 低 |
| 日程周视图、时间线 | 自定义 `Layout` 或 `Canvas` | 中 |
| 屏幕时间图表 | Swift Charts（`BarMark`） | 低 |
| 流式回复、呼吸点 | 已经完整的块先排好，其余跟着光标增量更新；`ellipsis` 符号加 `.symbolEffect` | 低 |
| 助手回复里的 Markdown | Apple 的 swift-markdown（cmark-gfm）解析，自己写的 SwiftUI 视图排版，见下面「对话的显示」 | 中 |
| 复制消息 | 每条消息 `.textSelection(.enabled)`（排好的回复一块一块地选），再加一个「复制」按钮；不做跨多条消息的连续选中 | 低 |
| 菜单栏常驻和弹出面板 | AppKit `NSStatusItem`，面板里放 SwiftUI，用 `expandedInterfaceDelegate` 管键盘焦点；橙色数字角标画成图片 | 中 |
| 可直接回复的系统通知 | `UNUserNotificationCenter` + `UNTextInputNotificationAction` | 低 |
| ⌥Space 全局唤出 | 系统没有 SwiftUI 接口；自己调 Carbon 的 `RegisterEventHotKey`，独占注册（不需要辅助功能权限），录快捷键的控件用 KeyboardShortcuts 的，见下面「快捷呼出」 | 中 |
| ⌥Space 小窗（像 Spotlight） | AppKit `NSPanel`（不激活，浮在别的 App 上面）里放 SwiftUI，背景用 `.glassEffect` | 中 |
| ⌘K 快速跳转 | 主窗口上面浮一块 SwiftUI 的玻璃面板，输入框是 `NSTextField`，好拿到 ↑↓ 和回车又不抢输入法的键 | 低 |
| 应用使用记录 | `NSWorkspace` 的前台应用通知，不需要权限，只记应用名和时长；专注检查读窗口标题用辅助功能接口 | 低 |
| 本机提醒事项（以后） | EventKit，申请提醒事项的完整访问权限 | 低 |
| 开机启动、常驻 | `SMAppService.mainApp`；关掉窗口后只留在菜单栏（accessory），见「开机启动、只留在菜单栏」 | 低 |
| 凭证 | 钥匙串 | 低 |
| Gateway 连接 | `URLSessionWebSocketTask`（可以带 Access 和 Hermes 的请求头）+ 自己写的 JSON-RPC 层，类型从 OpenRPC 生成 | 中 |
| 云桌面画面 | 见上面「画面客户端」：自己写精简的 RFB 客户端，画面是 AppKit 的 `NSView`，接管条浮在上面用玻璃 | 高 |
| 点画面接管、点外面交还 | 画面视图成为第一响应者；`NSEvent.addLocalMonitorForEvents` 只看本 App 里的点击，所以切到别的 App 不会交还 | 中 |

### 对话的显示

- **工具调用**：连着的几条工具调用折成一行「用了 3 个工具 · web_search、read_file、web_extract」，点一下展开，再点收起，展开不记住。展开的几条出现在这一行下面。点开、收起时这一行留在原处（在鼠标下面），把下面的内容推下去、收回来，停在对话最底下和往上翻到中间都一样：内容变高变矮时滚动的位置不动（不锚定底部），往下跟的只有新消息（见下一条）。一轮还在跑时，最近的那几条照常一条一条显示，等这一轮的回复完成（`message.complete`）再折起来；后面已经接上助手的话的那几条不用等（和官方桌面端一样）。只有一条的不折，它本来就是一行。看板卡片（`kanban_create`）照常显示，夹在中间时前后各折各的。从 transcript 读进来的轮次已经结束，直接是折好的。
- **跟着最新一条**：停在最底下时，新消息、流式回复、新的工具调用都跟着往下走（`ScrollViewReader.scrollTo(最后一行, anchor: .bottom)`；刚来的几行排好、量出真实高度的那一秒里，高度一变再跟一次）。跟下去的那一下不一定到得了：新的一行刚来时，列表先把上一行放回原处（它去掉了底边距，下沿仍贴着可见区底边），新行排在它下面、看不见，同一次更新里发的滚动再把新行带上来；这些滚动是在排版过程中发的，有时落空（run 212 的记录：回复停在列表放它的地方）。所以每次跟下去以后，等各行排好，再从更新之外看三次（30、150、300 毫秒后，`lookAgain`）：还在跟、最新一行却排到了可见区下面（或者根本没排出来），就再滚一次；后来的变化有它自己的三次，之前的作废。往上翻着看的时候什么都不动，新消息来了也不把人拽回底部，翻回最底下又接着跟；自己发的消息和它的回复总是跟下去。回复下面出来「已停止」「重试」也算最后一行变了，同样跟下去；最后一行上面多出一行也算（通知的卡片是事后从记录行读到的，放在它引出的回复前面：run 213 的记录里三张卡片在回复到了两秒以后插进来，对话还在跟，回复却被顶到了可见区下面），出错行点开「详情」时，对话往下滚到刚好看全这一行。查找跳到一条命中后不再往下跟（翻回最底下又接着跟）。往前一页一页找时：没有命中的那一页照常把原来那一行放回原处；命中和新的一页一起来，就直接跳到命中，不再放回原处；一页正在放回原处时来了命中，等那一行排回原处（排版报回来）再跳。跳过去以后的几次排版里看命中在不在眼前，不在（隔得远，中间的行还没排出来，按估的高度跳会落空）就再跳，最多三次。这些先后都记在一个不被观察的对象里（`TranscriptPlace`），两个 onChange 谁先到谁做，不靠等多久。滚动的位置全由这几处自己定，不用 `defaultScrollAnchor`，开头也不锚：内容变高、变矮时顶端不动。跟着最新一条时，可见区高度变了（窗口、输入框、宿主）不是读的人滚的，放回最底下；一下子跳到最顶上（Home、⌘↑、滚动条）或者往上翻，都是读的人自己要看，留在那里。开头锚在底部（`.initialOffset`）试过：对话被拆掉重建时（断线重连后重新读一遍），最底下附近有一条比窗口还高的回复，内容的高度多算了差不多一条长回复，停在「最底下」时眼前是空白，滚一下也不恢复（run 146、149；主分支没有这个锚点，同样的数据不会这样，run 150）。已知问题：对话页放进 `.inspector` 时，打开会停在顶上：页面打开时 split view 把滚动视图重新接一遍，App 打开时发的滚动在那种布局里落空（run 152、153、155、156 都停在最顶上；打开后 0.3 秒、1 秒再放一次也没用，run 153，这几条已经去掉；3.5 秒后还在顶上，run 156）。之后 App 发的滚动是管用的：用查找跳到最新一条回复里的字，四次都到了最底下（run 156）。现在没有页面这样用，真要用时再专门处理。打开对话时停在最新一条：对话里有了消息才建滚动视图，建好时滚到最后一行，各行排好后再滚一次，在这之前不取更早的页；内容不满一屏时贴在底部（内容至少一屏高、靠下排）；往上加载更早的一页时，眼前最上面那一行留在原处：画新的一页之前，从上一次排版里记下这一行在可见区里的位置，加完用 `scrollTo(这一行, anchor:)` 放回去。`scrollTo` 把这一行的锚点对到可见区的同一个锚点上，行顶落在 y ×（可见高 − 行高）处，所以 y = 行顶 ÷（可见高 − 行高）；比可见区还高的一行（很长的回复）也一样，比如一行 700 高、可见 520、顶在 −100 时是 0.56。眼前没有哪一行从可见区里开始（一条长回复占满了可见区）时，记的是跨过顶边的那一行；和可见区一样高（差一点以内）的一行怎么放都是顶对顶，就放到顶上。停在最底下、正在跟着最新一条时，顶上的行变了（在最底下往前读了一页，断线重连后对话重新读一遍）就留在最底下，不放回原处：重新读的时候最后几行也换了，两边各滚一次会互相拉扯。是不是在最底下，只看自己滚动的那几下（内容高度没变时）。滚动视图刚建好时会先报一次自己在哪（还在最顶上，什么都没动），这一次不算读的人滚的：要放到最底下以后、位置确实变了才算。原来把它也算了进去，对话一打开就不再跟，要发一句话或者滚一下才恢复（run 210 的记录里每次打开都是这样；回复流到一半时回到对话，后面每一段都没有跟下去）。列表自己挪行也不算：新的一行刚来、还没排到位的那一会儿（最长 0.6 秒，最新一行排进可见区就结束），列表把上一行放回原处的那一下，内容高度还是给新行估的数、没有变，位置却离底部远了；原来把它当成读的人往上翻，关掉了跟随，新来的回复就留在输入框下面，之后也不再跟（run 208、209、212 的 `ComposeTests`：一轮的回复和结束一起到；通过的那几次只是列表先量出真实高度、后挪行）。这一会儿里离开底部的位移不关跟随，回到底部的照样打开。是不是在最底下、各行在哪，都记在不被观察的对象里，滚动时不改任何会让界面重算的状态；可见区高度差一点以上才改。
- **折起来那一行的 id** 取这一段最后一条工具调用的 id（`tools-<id>`）：更早的页加在上面，被页边界切开的一段补上前半截后 id 不变，往上加页时照旧用 `scrollTo` 停在原来那一行；直播时的工具行就用 transcript 给它的 id（`tool-<tool_call_id>`），重连重读后也一样。
- **Markdown**：助手的回复按 GitHub 的写法显示：标题、段落、有序 / 无序 / 嵌套列表、任务列表、代码块（等宽，长行不折，在代码块里横向滚）、行内代码、引用、表格（对齐照 `:--` / `:-:` / `--:`）、链接（没写成链接的网址也能点）、分隔线、删除线；图片排在回复下面（见下一条）。换行和标点照原样（不把直引号换成弯引号）。回复完成后一块一块地能选。
- **图片和文件**（`ChatMediaViews.swift`、`AttachmentViews.swift`、`AppStore+Media.swift`）：
  - **发**：拖到对话区（整片描一圈紫边）、在输入框里按 ⌘V（访达里拷的文件，或者没有文字的图），或者点输入框左边的「＋」。加进来就开始传，输入框上方一排：图片是缩略图，文件是名字和大小，上面一圈进度；传不了的标红，悬停看原因，能重试的点一下再传，× 拿掉；全部传完才能发。图片在 Mac 上先处理：HEIC、TIFF、BMP 转成 JPEG，带透明的和 PNG 转成 PNG，GIF 原样；长边超过 2048 的缩到 2048（设置里能关）；重新画一遍，位置、拍摄时间、相机型号这些都不带。然后 `image-upload`，发送时放进 `attachments`；只发图不打字时，文字是 Hermes 自己的 `What do you see in this image?`（显示时不出现）。文件最多 16 MB：2 MB 以内把内容直接交给 `file.attach`（名字原样）；更大的先传到 Webapp 的 `/api/chat/file-upload`（有进度，也不占对话那条 WebSocket），再拿收据 `file.attach`，代价是 Hermes 把这种文件的名字改成 ASCII（`web-<随机>-<名字>`，中文会变成 `-`）。暂存的图放久了被服务器清掉，发送时回 `invalid_params`，就从 Mac 上的那份重传一次再发。带图的那一轮下面没有「重试」：Hermes 把图存成那一行里的图片部分，回卷后交回来的只有字，它自己的 `/retry` 也在回卷前就拒绝重放（`agent/context_compressor_retry.py`）；只带文件的那一轮可以重试，`@file:` 引用就在字里，原样再发一遍，显示成文件卡片。发出去的消息用它在对话里那一项的 id 当 `submission_id`，重试才找得到它存成了哪一行。
  - **显示**：你发的图在你的消息上面（一张最宽 320，二到四张两列，更多的折成「+N」），文件是卡片；从 transcript 读进来时认出 Hermes 存的几种写法（末尾的 `[Image attached at: …]` 和 `[screenshot]`、开头的 `@file:` 行、描述图片的 `[The user sent an image …]`、老版本的 `--- Attached Context ---`），不显示原文。工具的截图（`tool.complete` 的 `image_path`）排在那条调用下面，折起来时排在那一行下面，小一点。回复里的 `MEDIA:<路径>`（规则照 Hermes 的 gateway：代码块、引用、JSON 字符串里的不算，扩展名不认识的等服务器说有才显示）、回复里直接写的服务器路径（服务器说文件在才显示）和 Markdown 图片排在回复下面：图片最宽和正文一样、最高 480，下面一行小字是 alt；网上的图先是一块占位，写着网站名，点「显示图片」才取（不带 Cookie、不发来源页、只收图片、最多 20 MB，本机和局域网的地址不取），设置里能改成直接显示。加载时是一块浅灰底，不转圈；服务器和 Mac 上都没有了，写「图片已过期」。点图用快速查看；点文件卡片存到「下载」并用默认的应用打开，按住 ⌥ 只存；右键还有「在访达中显示」「快速查看」「拷贝服务器上的路径」。
  - **取和存**：服务器上的东西都经 Shion 自己的 `URLSession` 取，带 Access 的两个头和 Hermes 的凭证（`AsyncImage`、网页都带不了）。取到的都按内容的 SHA-256 存在 `~/Library/Caches/dev.shion.Shion/media/`，另记一张表：服务器 + 助手 + 路径 → SHA-256，网上图片的地址 → SHA-256，工具调用 → 它的截图。Hermes 收下的图在 `native-inputs/<SHA-256>/` 下面，正好对得上。你发的图一直留着；别的超过 1 GB 先删最久没看的；设置里能清。退出登录、换服务器时不清：磁盘上的表和内存里记的（解好的图、正在取的、存过的）都按服务器 + 助手 + 路径分开，两个助手里同样的相对路径也不会串。所以服务器一天后清掉的图、transcript 里不留路径的截图，对话里照样看得到。同一张图几处同时要，只取一次。截图模式和测试用自己的临时目录，存到「下载」也是。
  - **没做的、没核实的**：`::preview` 这类小组件没处理；音频、视频只当文件卡片，没有内嵌播放。从浏览器拖来只带网址的图不收，剪贴板里只有图片网址时按文字粘贴。交来的东西按 Hermes 投递的顺序排（`MEDIA:`、Markdown 图片、文字里写的路径），不按在文字里出现的先后。`tool.complete` 的 `image_path` Hermes 只在 local viewer 的轮次里发（`gateway/run_turn_progress.py`）：Shion 建的 Bot Chat（`source` 是 `gui`）算不算，只读了代码，没在真服务器上看过；不算的话工具的截图不会出现。只带文件的一轮重试时，要是服务器上那个附件已经删了，Hermes 解析不到引用，这种情况没在真服务器上试过。`/api/chat/file-upload` 只在 Webapp 上有，404 时退回 `data_url` 走对话的 WebSocket（16 MB 以内），这条退路没有端到端测过。Mac 上的副本重启后还在，这一点没有端到端测过（截图和测试模式每个进程一个临时目录）。网上的图只认字面上的本机、局域网名字和 IP，解析到局域网地址的公网域名挡不住。附件小块和文件卡片的状态写在无障碍标签里（macOS 不读普通组和按钮的 value），移除、再试一次是无障碍操作，没用 VoiceOver 实际试过。端到端测试里点「显示图片」要 runner 连得上 w3.org，连不上只记一笔、不算失败。
- **宽表格**：放得下就照原样排；放不下时格子里换行，但每一格最多只需要窄到 240 点（中文大约 18 个字）；这样还放不下，表格就在自己的框里横向滚，回复里其他的内容不跟着动。
- **流式输出**：最后一个空行（不在代码块里）之前的块已经完整，先排好，后面的跟着光标显示原文。排出来的和整条回复的一样：隔着空行的列表项还是同一个列表；引用式链接（`[文字][1]`）的定义一到，前面的引用就变成链接，定义还在没排好的那部分里也算。完成后整条再排一次，这时才能选中。
- **不卡**：解析结果按消息 id 和文字缓存（`MarkdownCache`，最多 400 条），长对话滚动、`LazyVStack` 重建行时不再解析。流式输出时，前面完整的块留着，只从最后一块的开头重新解析（列表隔着空行还会接下去）；定义变了才整条重新解析。在 Linux 上用 release 编译量过：20 KB 的回复整条解析约 12 毫秒；一行一行地流进来，每来一行约 0.2 毫秒。
- **选型**（2026 年 11 月）：

  | | 结论 |
  | --- | --- |
  | Apple 的 swift-markdown（cmark-gfm）+ 自己写 SwiftUI 渲染 | **用这个**。swiftlang 维护，Swift 工具链和 DocC 在用，2026 年还在发版（0.8.0 五月、0.9.0 九月）；依赖只有 swift-cmark；GFM 的表格和对齐、任务列表、删除线都在语法树里；样式跟 `Theme.swift` 一致；解析那一半不碰 SwiftUI，在 Linux 上也能编译和测试 |
  | MarkdownUI | 2025 年 12 月起是维护模式，最后一次改代码在 2024 年 10 月，作者转去做 Textual |
  | Textual（MarkdownUI 的后继） | 在维护（0.5.0，2026 年 6 月），能跨块连续选中；但还是 0.x，接口还在变，要用它自己的一套样式 |
  | `AttributedString(markdown:)` 的 `PresentationIntent` | 不加依赖，能解析表格和对齐，但没有任务列表；`Text` 显示不了表格，块要从一串 run 里拼回来，还是要自己排版 |

  代价是不能跨块连续选中，只能一块一块地选（暂时不需要）。包用 XcodeGen 的 `packages` 加在 `macos/project.yml`，版本限在 0.9.x。

### 停止、重试、查找

- **停止**：一轮在跑时（从第一个事件到 `message.complete`，或者服务器说会话在跑，比如在等批准），发送按钮旁边多一个停止按钮，⌘. 也能停（发送按钮还在：这时发的消息怎么处理见下面「写给助手」）。停的是这一轮事件帧上带的那次运行（`session.interrupt`，见上面「Canonical Gateway Protocol 要点」）。已经出来的部分留着，下面标「已停止」；什么都还没出来（停在工具调用里）就是一行「已停止」。重新读对话时按 `display_metadata.interrupted` 认出来，照样标。
- **重试**：只有被你停掉的、或者出错结束的那一轮下面才有「重试」：正常回完的一轮没有什么可重试的，再问一遍只会让工具重做一次。其余条件是它回的是你打的一句话（不是 Hermes 替你发的通知：看板回传、别的助手的消息、后台任务的结果；也不是中途送进这一轮的引导）、这一轮已经结束、后面没有你再说的话。点了就照 `/retry` 做：服务器上收回那条消息和它后面的（`session.mutate` rewind，带着最近一次 `session.info` 里的 `revision` 和运行编号；对不上就用拒绝里给的新值再试一次），聊天里也去掉这一段，再把原话发一次。从对话记录读来的消息，`row-<id>` 就是它的行；这次连接里发的，等这一轮的 `persisted_turn` 说；都没有就读最近一页按原文找。压缩过以后，Hermes 留下来的消息换了新的行号，按原来的行号收回会被拒，拒的和真被总结掉的消息一模一样（`compacted: …`，原地压缩和换成新会话都是）；Hermes 自己在原地压缩过的，拒的是「不在对话记录里了」（`target user message is no longer in session history`），和已经收回过的一样。所以说那一行不在对话里（`invalid_params`）而被拒时，就读一次最近一页，找这条消息现在的行再收回一次：这台 Mac 发的按提交编号（行上写着，正在跑的那一轮压缩以后也还写着；那一轮结束时 `persisted_turn` 说的也已经是副本的行号），从对话记录读来的按它的时间和文字（`StoredUserRow.Identity`）。页上没有别的行是它，就是真的总结掉了或者收回过了，照旧写「没能重试：…」。原来只按记下的行号收，压缩以后点重试总是那一句，哪怕那条消息还在；这一轮还在跑时对话重新读过、Hermes 又在这一轮里自己压缩了的，停下来重试写的是「这条消息已经不在对话记录里了」。收回只是对话，工具做过的事（建了卡片、写了待办、发了消息）收不回来，重试会让助手从头再做一遍：所以这一轮调用过工具（聊天里这一轮有工具行或新建的卡片，或者 Hermes 的说明是「有些操作可能已经执行了」）时，先弹一个确认框，列出这一轮用过的工具（名字和折叠行里的一样，新建的卡片写成 建卡片「…」），写明这些可能会再做一次，按「重试」才做，「取消」什么都不动。回复下面、「已停止」那一行、出错那一行，三处的重试都是这个规则；没调用过工具的轮次直接重试。
- **出错**：一轮出错时，已经出来的部分照样留着，下面是一块出错说明：第一行「这一轮出错了：…」写出了什么事，下面一句写怎么办，都是 Shion 自己的中文，按 `error_surface.code` 选，带上它给的服务商和模型名（意思照官方桌面端那张表，`apps/desktop/src/i18n/zh_error_codes.ts`），比如限流是「OpenRouter 那边请求太多了 / 等一会儿再试。」；钥匙和账户都在服务器上，所以怎么办也指向服务器。Hermes 自己的原文（实时出错时是 `text`，重新读对话时是 `display_metadata.error`）收在可以展开的「详情」里，能选中复制。Shion 没有中文说法的代号，照原样显示 Hermes 的原文。Hermes 那三句固定说明认出来就换成中文：「这次没有处理，还要做的话再发一次」「这一轮没做完，有些操作可能已经执行了，重发前先核实」「一次自动投递被打断了…」，不放进详情。这样实时的那行和重新读出来的那行说的是同一句话（两边都有 `error_surface`）。Hermes 说再试可能好（`error_surface.retryable`）时，下面就是「重试」，规则同上；说再试也没用（登录失效、内容被拒这类）时不给重试。系统通知里是第一行。停在什么都还没出来时的那行「已停止」下面也有「重试」。
- **查找**：⌘F（或工具栏的放大镜）在对话上面浮出一个玻璃的查找框，边打边找已经加载的行：消息的原文、工具调用、卡片的标题，不分大小写、全角半角和重音。命中的字都标出来：看着的那条消息里的是系统的查找黄，别的消息里的是浅一些的黄，都不透明、配深色字，所以在你自己那条紫色的消息里也看得清，浅色深色都一样；看着的那条滚到中间，折起来的工具调用里有命中时自动展开。框里是「第几条 / 共几条」。↑（回车、⌘G）往更早找，↓（⇧⌘G）往后，Esc 关掉。按 ⌘F 时键盘在哪儿都一样（比如刚在侧栏点了对话），接着打的字直接进查找框；Esc 或 ✕ 关掉以后，键盘回到输入框。查找框用的是 AppKit 的输入框（`KeyField`，和 ⌥Space、⌘K 的一样），出来时自己拿键盘，再按 ⌘F 再拿一次：SwiftUI 的输入框用 `@FocusState` 要键盘，键盘还在侧栏时要不到（run 157：从侧栏点进对话按 ⌘F，打的字查找框里没有，Esc 以后输入框里也没有）。关掉时输入框也是自己拿回键盘：它后面垫着一个看不见的 AppKit 视图（`KeyTarget`），在窗口里找到它下面那个能编辑的框，直接设成第一响应者（和 ⌥Space 的窗口找自己的输入框一样）；用 `@FocusState` 要，从查找框那里要不到（run 159：查找框里有「作业」了，Esc 以后打的「好的」输入框里还是没有）。
- **更早的页**：边打边找只找已经加载的行，不为查找预先取历史：Bot Chat 一直是同一个会话，几个月下来有上千行，全取下来要几十次请求，对话也会变得很长。在最早一条命中上再按 ↑，才往前一页一页地取（每按一次最多 10 页、500 行），直到找到下一条，或者到了第一条消息。
- **没连上时**：勾待办、确认日期、新待办、新建卡片、挪卡片、回答批准都不让做（见下面「没连上时显示上次的数据」），停止和重试也只在连着时有；输入框照样能打，说的话排队，连上后发出（见「断线重连」）。

### 写给助手：草稿、回复、忙着的时候

- **草稿**：没发出去的字存在 `AppStore` 里（按服务器和助手），不在对话页面的状态里：换页面、换助手、断线重连都还在，退出 App 才没有。输入框也因此不再让整段对话跟着每个按键重画。
- **换行**：Enter 发送，Shift+Enter 换行（Option+Enter 是系统自带的换行，也还在）。SwiftUI 的多行输入框把 Shift+Enter 当成 Enter，所以用一个本地按键监听（`LineBreakKey`，和粘贴图片的监听同一种做法）在按键进来时拦下，换成输入框自己的换行动作：在光标处、盖掉选中的字、能撤销；输入法正在组字时不拦。
- **回复某一条**：指针放在一条消息上，右上角出现「复制」和「回复」（右键菜单里也有）。点了回复，输入框上方出现那条消息，发出去的是 Hermes 在各个消息平台上给回复用的写法（`gateway/run_inbound.py`）：`[Replying to your previous message: "原文"]`（回复自己说的是 `[Replying to: "原文"]`），空一行，再是你的话，所以助手读起来和读 Telegram 上的回复一样；聊天里读回来时，这段显示成你那条消息上方的引用。不打字、只发图片或文件的回复也带着这段引用（只有引用、没有你的话；图片不再配 Hermes 那句默认的「What do you see in this image?」），助手知道这张图、这个文件答的是哪一条。什么都没有（没打字、没附件）时发不出去，回复的标记也留着。
- **助手还在忙时发的消息**有三种去法，和 Hermes 自己的客户端一样（`display.busy_input_mode`，调用也一样：`ui-tui/src/app/useSubmission.ts`）。在设置的「对话」里选默认的，助手在忙时输入框旁边也有一个小菜单能改。只管在对话输入框里打的话：⌥Space 小窗、快捷指令、今天页的输入框、通知里的回复一律排队（`AppStore.send` 不给发送方式就是排队），因为它们的回答是按「这句话开的那一轮」去找的，送进正在跑的一轮，回答会接在更早的那个气泡里，小窗和快捷指令就拿不到了。
  - **排队**（默认）：`prompt.submit`，Hermes 把它排在这一轮后面，不打断。
  - **引导**：`session.steer`，不打断，在这一轮的下一步把这句话带给助手。
  - **打断**：`session.redirect`，让这一轮马上转过来处理这句话，已经做出来的保留。
  - 引导和打断带着这一轮的运行编号（`execution_generation`），只能带文字（带图片的照排队走）。编号是按下发送那一刻正在跑的那一轮的（`Sending`，和 Hermes 终端客户端的 `captureBusyControl` 一样在提交时记下），不是真正发出去时的：刚重连、对话还在重新接上时发的话要等一会儿才出得去，这期间那一轮结束了、或者换成了下一轮，就照排队发，不去打断一轮你没看到的。Hermes 答 `queued` / `redirected` 就是收下了，那条消息下面标「送进了正在进行的这一轮」，它不算新的一轮（重试不会拿它当起点；重新读对话时，Hermes 存下的 `steer` 行也这样显示）。这一轮刚好结束、没人收（直接拒绝，或者 `rejected` 带 `delivered: false`），就照排队发出去。
  - `rejected` 不带 `delivered: false`：这一轮没接。对一般的助手这就是没送到（`agent/interrupt_control.py` 的 `redirect` 返回假的几种情况都发生在交出去之前）；只有跑在 Codex 上的助手，Hermes 等它的确认超时了也这样答，那时它可能已经看到了。所以不写「没发出去」，写「这一轮没有接下这句话，也可能已经看到了」，旁边「再发一次」：点了才作为新的一句排在这一轮后面发出去（`prompt.submit`），Shion 不自己重发（引导不是一次提交，Hermes 分不出两次，重发可能让同一句话被执行两遍；Hermes 的终端客户端也是留给人决定，`ui-tui/src/app/submissionCore.ts` 的 `settleControlReply`）。
  - 连接恰好在这时断了，就不知道送没送到（引导没有回执可查）：标「不确定有没有送到」，不自动重发。重连后去读对话记录最新的一页（50 行），里面多出一行你说的同样的话才算送到了：发出去之前对话里已经有的同文消息不算（发的时候记下它们是哪几行；那时还不知道是哪一行的，按先后算最早的几行），一行也只算一次（同样的话连发两次、只到了一次，就只确认一条）。不看时间：以前只要一分钟内有同样的话就算到了，20 秒前说过「继续」、再用引导说一次「继续」而这次丢了，会被当成送到了，那条消息还会从对话里消失。打断的话 Hermes 存成普通的一行，引导的存成 `steer` 行，两种都认。补全了事件、没重读对话时，确认后留着原来那条消息，标成「送进了正在进行的这一轮」；对话重读过，就是读回来的那一行。读不到这一页、或者页上没有，就一直标着「不确定」。
  - 一行只确认一条，而且一直算数（`ChatControl.confirmedRows`，按会话记着）：同样的话连发两次、服务器只收到一条时，之后每次重连都只确认先发的那条，另一条保持「不确定有没有送到」，直到记录里真的多出它自己的一行。原来「已占用的行」只在一次核对里记着，第二次重连会拿同一行去确认另一条。
  - 压缩过也一样：Hermes 压缩对话时（原地压缩，或者换成新的会话），留下来的消息重新存一遍，换了新的行号，时间和文字原样不变；总结掉的那些还按原来的行号显示。所以发的时候已经有的同文行、确认过一条消息的行，除了行号也按 Hermes 存它的时间（行上的 `timestamp`，不是这台 Mac 的钟）和文字认（`StoredUserRow.Identity`）：十分钟前的「继续」压缩后换了行号，也认得出是那句旧的，不会被当成刚才那句丢了的「继续」送到了。原来只记行号，压缩以后旧的那行像是新多出来的，没送到的话被标成送到了，气泡还会被那行旧的顶掉。用 `session.mutate compress` 压缩时，写着提交编号的行压缩后编号还在，照旧按编号认。Hermes 自己压缩时（一轮开始时上下文已经太长，或者一轮里工具的结果回来以后）不一样：之前几轮的行重新存的时候不再写提交编号，引导进去的话变成 Hermes 给模型的原文，只有正在跑的那一轮的提示还写着编号。这次连接里发的「继续」，只知道它的行号（那一轮结束时 `persisted_turn` 说的），不知道 Hermes 存它的时间，压缩以后它的副本就谁也认不出来了，原来会把刚才那句丢了的「继续」确认成送到了。所以送进一轮的话（还有在最新一页里按原文找的话）说的时候，也记下当时正在跑的那一轮是哪一条开始的（`DeliveryCheck.Before.turn`）：它只能存在那一轮里，比那一轮开头那一行存得早的（按 Hermes 存的时间），不管行号、写没写编号，都不是它。那一行的时间，从对话记录读来的那一项上就有；这台 Mac 发的提示，由页上写着它的提交编号的那一行给。那一行也找不到时（比如断线期间又跑了一轮、正好又压缩，那条提示也成了不写编号的副本），就只按行号、编号、时间和文字认。行号 Hermes 从不重复用，记下的旧行号不会变成别的消息的。这是对着真的 Hermes 前后读到的页核对的（`macos/ci/real` 的 `compact` 和 `auto` 阶段，那几页在 `macos/ci/logic/send/compaction.json`、`autocompaction.json`）。
  - 一句话从说出口的那一刻起就被跟踪，当时对话里有哪些同样的话也一并记在发送记录上（`Deliveries.track` 的 `before`），不再等到真正发出时去看对话。所以对话正在重新接上、最新一页先读回来时，刚说的话不会因为历史里有一句一样的就被当成重复去掉，那句旧的话之后也不会被当成它送到的证据。用最新一页替换对话时（`loadLatestPage` 里的 `onPage`），还没确认送到的话只在记录里有一行可能是它时才由那一行代替：Hermes 把提交编号存在那一行上（`display_metadata.submission_id`）的按编号认，否则要是说这句话时还没有的同文行；其余的，包括「没发出去」和「这一轮没有接下」的，气泡和下面的提示都留着。
  - 同一句话连说两遍时，按「哪几条消息」而不是「几条」来区分（`DeliveryCheck.Before` 记的是那几条消息本身）：前一条后来被拒绝、没发出去，或者已经知道它存成了哪一行，都不会再让后一条一直停在「不确定有没有送到」；反过来，后说的那条存下来的行也不会被当成前一条。
  - 记录行上写着提交编号的（Hermes 存普通消息时都写），那一行就只属于那一次提交：别的话说得一模一样也不会被它确认。回执丢了的普通消息、塞进一轮的话、用最新一页替换对话这三处都这样认（`DeliveryCheck.named`、`ChatControl.namedRows`）。不管读的是哪一页（重连后的最新一页、往上翻的、为通知读的几行，都经过 `AppStore.transcriptPage`），写着提交编号的行从此就知道是哪条消息的，那条消息还在不在等确认都一样。原来只记还在等确认的：普通消息「继续」已经收到回执、断线又错过了它那一轮的结束时，另一句塞进一轮的「继续」即使页上有自己的一行，也会因为那条普通消息被算成「不知道存在哪一行」而一直停在「不确定有没有送到」，对话里多出一个气泡。

### 对话里的卡片

除了你和助手的话，对话里还有这些卡片：

| 卡片 | 从哪来 |
| --- | --- |
| 建的看板卡 | 助手调 `kanban_create`（原来就有）；卡片上的状态一直跟着看板 |
| 看板回传 | 卡片做完、停下、交来检查时，Hermes 替你告诉订阅了这张卡的助手。Bot Chat 里收到的是 gateway 叫醒会话用的那段话（`[kanban] Task t_… completed.`，下面一行行是标题、执行者、看板和交上来的第一行，最后一段是写给模型的），存成一行 `internal_notification`，那一轮的开始帧里什么都不带，所以卡片是读到这一行才有的；这是对着真的 Hermes 抓下来核对过的（见下面）。Hermes 的终端客户端和消息平台收到的是另一种写法（`✔ [study] @study Kanban t_… done — 标题`），两种都认。Hermes 的语言设成中文时这段话是中文的（`任务 t_… 已完成。`），也认；别的语言里它基本是英文，个别语言自己的说法认不出状态时，照 Hermes 的原话写。原来那张卡继续跟着看板变，另外每次回传在发生的地方留一张：原卡现在的样子，加一行当时发生了什么、交上来什么或为什么停。卡片已经不在看板上（归档了）时，仍然写着是哪张、不带状态：打开过工作记录、读到了这张归档卡就照它的标题，否则用通知自己带的标题（gateway 的那段话总带标题；另一种写法只有「做完了」带），再没有就写卡片编号；有编号的回传只认这个编号，不会因为标题相同显示成另一张卡 |
| 别的助手发来的消息 | `Message from 🤖 名字 (@handle): …`（`tools/bot_mode_dm.py`），以前显示成你自己说的话。和看板回传一样存成一行 `internal_notification`，那一轮的开始帧里什么都不带，卡片是读到这一行才有的。Hermes 在正文下面加的两种标注换成中文（`Constraints: …` 写成「限制：…」，`Reply needed: …` 写成「要回：…」），不要求回复的标记 `[no reply needed]` 写成最后一行「不用回复」 |
| 别的助手的回话 | 助手用 `message_agent` 发出去的消息，对方的回话不是直接来的：Hermes 起一个后台进程等它，等到了把这个进程的结束当作后台任务结果交给发送方（行类型 `process_complete`，短说明是那条命令 `Background Process Finished: …/bot_mode_dm.py --run-delivery ...`，正文的 `Output:` 下面一行 JSON 写着谁回了、回了什么）。Shion 认出这种结果，显示成「某某 发来的消息」和回话本身；一次问了几位，各出一张；对方那一轮没有回话写「@某某 这一轮没有回话」，没送到、没等到之类照 Hermes 的原话。助手忙的时候 Hermes 会把几条后台结果合并成一轮交给它：这时逐条读，回话各出一张卡，别的结果各出一张后台卡、照 Hermes 的原话写着哪个进程、怎么结束的、命令和输出，一条回话不会盖住另一条回话或一条失败的命令；合并的结果里一条回话都没有时也是每条一张，不只显示 Hermes 给的那句计数（`2 Background Processes Finished`）；单独一条后台结果照旧显示 Hermes 的短说明 |
| 发给别的助手的消息 | 助手调 `message_agent`，以前只是一行工具调用 |
| 后台任务的结果 | Hermes 自己发起的一轮（行类型 `process_complete`、`async_delegation_complete`、`internal_notification`），显示 Hermes 给客户端的短说明（`display_text`），没有就显示正文 |
| 自动沉淀 | 助手一轮之后复盘留下的摘要（`review.summary`：学了什么技能、记了什么）。服务器不保存它，Shion 收到时显示，并在本机留最近 30 条 |
| 待审核的技能 | 见下一节 |
| 密码、批准和提问的结果 | 原来就有 |

- Hermes 给模型加的包装不显示：结尾那句 `[INTERNAL NOTIFICATION — …]` 和几条结果合并时的 `[IMPORTANT: …]` 开头（`Model/Notices.swift`）。
- 不是这台 Mac 发起的一轮（看板回传、别的助手来消息、后台结果），Hermes 只把起因存成一行、不另外通知，所以这样的一轮开始和结束时各读一次最近 12 行（`followNotices`）；你自己发起的一轮不读。结束帧写着这一轮是从哪一行开始的（`persisted_turn.user_row_id`）：最近 12 行里没有这一行，就一页一页往上读，读到这一行或比它早的行为止，不设上限（行号是已知的，读到就停）；读到顶也停：没有下一页，或者这一页一行都没有。工具调用的行没有行号，一页全是工具调用不算到顶，照样往上读（一轮调了几十次工具，起因那一行就在这样的页上面，原来读到这里就停了）；给回来的下一页位置（`next_cursor`）读过了也停，同一页不读第二遍。所以离开期间自己起了很多轮，每一轮的通知也都找得到；看板回传和别的助手发来的消息开始帧是空的，没有临时卡可以提醒去多读，原来超过 6 轮时较早的就漏了。
- **同一条通知只有一张卡**（`Model/NoticeCards.swift`）。Hermes 对一条通知最多说三次，互相不带编号：拿到时的一条状态行（`status.update`）、它那一轮开始（`message.start`，前面有一轮在跑就等那一轮结束）、对话记录里存下的那一行。在 gateway 上实际抓到的是：后台任务结果（包括别的助手的回话）开始帧和行各说一遍；看板回传和别的助手发来的消息只有行。事件帧不带时间也不带行号，断线后补播的帧和实时的没有区别，所以按身份而不是按「文字相同、时间相近」来认：
  - 事件帧带来的卡是临时的（编号里写着，分「只说了」和「这一轮开始了」）。状态行在 5 分钟内重复只算一张；一轮开始时，之前只说了的那张就是它，挪到这一轮开始的地方，等了多久都一样。
  - 读到对话记录的一页后，这一页的行和对话里已有的内容整页对齐（`NoticeCards.put(page:)`）：两边说的是同样的事、顺序也一样，所以从最新的一行往回配，每一行都配在后一行配到的那一项之上。一行先认对话里编号相同的那一项，再认已知就是这一行的那一项：一轮结束的帧写着这一轮存成了哪几行（`persisted_turn` 的 `user_row_id`、`final_assistant_row_id`），实时到的回复气泡和开始帧带来的卡从这时起就是那几行（`ChatControl.storedRows`），按行号认，别的内容说得再像也不是它。只有还在进行的一轮才靠内容认：说同一件事的临时卡，由这一行顶替，留在原来的位置（帧是按发生的顺序到的；补播的回复记的是补播那一刻，按行的时间放反而会排到前面的回复之前），换成行的编号和行的时间，一行只顶替一张；其他的行认实时到的、同一方说的同一句话，但不认已知是另一行的那一项，也不认离得太远的旧话。从最新的往回配，是因为这一页可能只有最后几轮：同样的话来了 8 轮、这一页只有后 6 轮时，这 6 行配给后 6 张临时卡，更早的两张等读到更上面的一页。所以隔了很久才补播的通知不会多出一张，卡片上是它当时的时间。
  - 没有临时卡可顶替的行（gateway 叫醒会话的看板回传、别的助手发来的消息：那一轮的开始帧什么都不带），放在它后一行配到的那一项之前（那是它引出的回复）；后面的行对话里都还没有，就放在前一行配到的那一项之后；这一页的行对话里一条都没有，才按行的时间。不直接按时间，是因为行的时间是服务器的，实时气泡的时间是这台 Mac 收到帧的那一刻，两者比不出先后（CI 上出现过回传卡排到上一句回复前面）。
  - 两行就是两条通知，文字一样也各有一张；同样的话隔一轮再来也是新的一张。反过来，对话里已经有那一行、它引出的那一轮还什么都没出时，再到的帧说的就是它，不另出一张。
  - 压缩过也一样：Hermes 压缩对话时，留下来的行换了行号重新存一遍，时间和文字原样不变，这不是又一条通知。读到的一行和对话里读来的一项是同一边的、时间（服务器的）也一样，就是压缩前读过的那一行：通知还是原来那张卡（一行几条通知的，第几张还是第几张；文字一样不算数，同样的话隔一会儿再来是另一条），别的话还是原来那个气泡。原来只按行号认，压缩以后再来一条通知、读最新几行时，旧的那条在新的那张上面又多出一张。这是对着真的 Hermes 两种压缩前后读到的页核对的（`macos/ci/real` 的 `compact` 阶段，那几页在 `macos/ci/logic/notices/compaction.json`）。Hermes 自己压缩时，后台结果那一行重新存的时候没有了 `display_kind` 和 `display_text`，只剩它给模型的原文：这不再是一条通知，读到它不会多出一张卡，对话里原来那张卡照样留着；但对话之后整个重新读一遍（重连、重新打开）时，这一行就显示成你说的一句话，文字是那段原文。原地压缩时它的回复重新存时换成了压缩那一刻的时间，认不出是哪一行，也不会被放进对话；下一条通知的卡照样放在它那一轮开始的地方（`auto` 阶段，`macos/ci/logic/notices/autocompaction.json`）。
  - 一轮结束后还有没等到行的临时卡，而结束帧没写这一轮从哪一行开始（出错的一轮不写），再往上读一页。
- **静默**：助手整条回复只是一个静默标记时（`[SILENT]`、`NO_REPLY`、`静默` 等，清单和判断照 Hermes 自己的 `gateway/response_filters.py`：整条才算，正文里提到不算，首尾的标点不影响），不显示气泡，也不发通知；回复末尾单独一行的标记去掉；流式进来时，还可能变成标记的开头先不显示。历史、实时、通知、⌥Space 小窗用的是同一个判断（`Model/Silence.swift`）。

### 技能事后审核

Hermes 的后台复盘会自己新建、修改技能，**先写入生效**；Shion 让你事后看（插件那边见 `hermes-plugin/README.md` 的「技能审核」：卡片来自 Hermes 自己的技能账本，插件不另存技能内容）。

- 助手自己写了或改了技能，它的对话里（按写入的时间）和「待你处理」的「审核技能」里出现一张卡：哪个技能、新学的还是改的、「已生效 · 待审核」。
- **批准**：记下你认可，技能不动。**拒绝**：先说明会发生什么，再撤回这次变更（新建的归档，修改的恢复原样，被它归档或并进别的技能的从归档里恢复回来）；这次变更之间或之后技能被别人改过（你让助手改的、直接改文件的）就不撤，卡片下面写原因。撤的时候拿着 Hermes 写技能用的锁，助手这时要改同一个技能会等撤完。
- 后台复盘把一个技能并进另一个（删除）是一张卡，不是两张。还没处理的卡不管多旧都列着；处理过的只留最近 200 张。
- **审核**：打开一个单独的会话和这个助手讨论，不在它的 Bot Chat 里。会话按卡片的编号创建（`request_id`，不带标题：带标题 Hermes 会先去找同名的会话），没有任何工具（`toolsets: []`），所以讨论改不了技能和记忆，也不会触发新的自动沉淀（Hermes 只在会话有这两个工具时才复盘）。第一条消息是给助手的资料，折叠着：写入时刻之前这个助手 Bot Chat 里最近 50 条你和它的文字消息（不含工具调用、Hermes 自己发起的轮次和静默标记）、这次变更的 diff、技能现在的全文。再点同一张卡回到同一个会话。
- **审核会话里出了岔子**（`Model/SkillReviewTalk.swift`）：你说的每句话都留在说的地方，带着自己的提交编号，不会被拿掉，也不会被塞回输入框（等的时候新打的字还是你的）。Hermes 明确拒收的，气泡下面写「没发出去」和它给的原因，点「重发」用同一个编号再发；Hermes 对一个编号只收一次，所以不会变成两句。没等到回执的（超时、连接断了），先问这个会话自己：它的记录读得到全部，多出一行同样的话、或者 Hermes 把这个编号列在排队里，就是收到了；没有就是「没发出去」。断着线时写「等连上后确认」，连上再问。一轮以出错结束时，错误写在输入框上面（重新打开这张卡也还在，直到真的开始下一次尝试），旁边的「再试一次」像对话里的「重试」那样把失败的那一轮退回去（`session.mutate` rewind）、用同样的话重新问；这个会话没有工具，重问不会让什么操作做两遍。Hermes 不让在这个会话里退回的话，就在失败的那一轮后面用同样的话再问一遍。会话没建起来或没读到时，「再试一次」是重新打开；有一句没发出去时，是重发那一句。这个会话的事件订阅被 Hermes 单独结束时（`session.replay_gap`：连接还好，只是这边收得太慢），或者连接断了又回来时，Shion 把漏掉的事件补上、重新接上会话，在不在回答以会话自己说的为准，不会一直停在「正在回答」；Hermes 拒绝重新接上时怎么办，和 Bot Chat 一样（见「断线重连」的「重新接上被拒」），这期间不能发送，打的字留在输入框里。审核会话还没建起来（`session.create` 或绑定失败）时不能发送，打的字留在输入框里；点「再试一次」建好之后，资料先发，你的话再发。
- **「再试一次」的退回，对着真的 Hermes 手动试过**（`611bf53`，2026-11-13，在容器里断着网起 `hermes gateway run`，像 Shion 那样连 `/api/ws`、建 `hidden`、`toolsets: []` 的会话）：这样的会话里 `session.mutate` 的 `rewind` 被接受。第一次不知道会话的修订号，被拒 `revision_conflict`，回答里带着当前的 `revision` 和 `execution_generation`，带上它们再发就退回了（失败那一轮的两行都没了），之后同样的话当新的一句提交，起了新的一轮；一轮还在跑时退回被拒 `session_busy`，和 Shion 认的那几个原因一样。另外记下几件事：gateway 断着网、没有模型密钥也起得来，约 6 秒就绪。没有密钥时，一轮在 5 秒左右以出错结束。有密钥但连不上模型时，Hermes 自己重试 5 轮（中间等 16、33、67、68、70 秒），约 5 分钟后才以失败结束，这期间审核窗口里只有「正在回答」的点。这个 profile 完全没配模型时，建会话就被拒（`storage_unavailable`），而且同一个 `request_id`（也就是同一张卡）之后配好模型、重启 gateway 也还是被拒。`hermes serve` 也起得来，但说的是旧协议，Shion 不支持；`hermes dashboard` 断网起不来（要先联网构建网页界面）。
- **看板回传和审核会话的几件事，也对着真的 Hermes 试过**（同一个容器、同一个提交，断着网、没有模型密钥；抓下来的帧和记录再交给应用自己读通知、判送达的那部分代码，在 Linux 上直接编译运行）。看板回传：用 Hermes 自己的命令让一个 Bot Chat 订阅一张卡（`hermes kanban notify-subscribe … --delivery-mode notify+wake`，助手自己建卡时就是这样订阅的；只写 `notify` 不会起一轮），再把卡标成完成或卡住，Hermes 就在那个会话里自己起一轮。连着时和断开后补播（`session.events.since`）拿到的帧一样：`message.start` 是空的，没有状态行，帧里没有时间也没有行号；记录里那一行是上面说的那段话。原来的代码只认另一种写法，会把它显示成一张「后台任务有结果了」的卡，里面是整段英文和写给模型的话；现在读成看板回传：卡片编号、标题、执行者，下面写「做完了：交上来的第一行」或「停下了」（卡住时这段话里不带原因）。英文和中文两种都抓了真的来核对。审核会话：同一个提交编号发两次是同一次接收，那一轮结束后再发也是；等着的时候会话的 `pending` 和 `session.info` 帧都写着这个编号，开始以后记录里有这一行（行上也带着编号）；排队到第 34 句被拒，原因是 `queue_full`；按游标要补播拿得到之后的帧，换一个 epoch 就回 `snapshot_required`。应用的代码拿这些真的回答判出来的结果都对。出错的一轮结束时 `message.complete` 里没有 `persisted_turn`，应用本来就不指望它一定有。没试到的：别的助手发来的消息、后台任务结果这两种自己起的轮次，和订阅被撑爆时真的 `session.replay_gap`，都要先有一个能回答的模型。
- **要模型回话才会发生的几样，接一个假的模型也对着真的 Hermes 试过**（同一个提交、同样不联网；`macos/ci/real/`，`run.sh` 一条命令重跑）。容器里起一个 OpenAI 兼容的假模型（按脚本回一句话、发一次工具调用、流几兆字节的长回复），Hermes 的 `base_url` 指向 `127.0.0.1`，三个 profile 都标成 Bot Mode 的助手。让詩音用 `message_agent` 给课程带话：课程的 Bot Chat 里 Hermes 自己起一轮，开始帧是空的，只有存下的行写着 `Message from 🤖 …`；课程的回话回到詩音那边时是一条后台任务结果（等回话的那个进程结束了），短说明是一条命令，谁回了、回了什么在正文的一行 JSON 里。Shion 原来把它显示成「后台任务有结果了」加那条命令，现在显示成课程发来的消息；消息下面 Hermes 加的 `Reply needed:` 之类也换成了中文。不要回复的消息、对方没回话、一次问两位、普通的后台命令结束，也都抓了一遍，应用读出来的和上面表里写的一致。`session.replay_gap` 也真的触发了一次（一个不读数据的观看者落后 4 MB 以上）：帧的样子、之后补播要不到（`snapshot_required`）、同一条连接上重新接上后帧继续来，都和 Shion 的处理对得上。替身里这几种轮次改成了抓到的样子。没试的：界面本身（只在 CI 上对替身跑）、跨机器的 peer gateway、`async_delegation_complete`（子任务的结果）。
- 要求各助手的 shion 插件是 0.2 以上；没装或版本旧的助手没有卡片，别的不受影响。

### 没连上时显示上次的数据

- 连上过一次以后，Shion 把服务器给的数据在这台 Mac 上存一份：助手列表、今天页詩音写的那段话、待办、日报、看板上所有看板的卡片（列、在等什么、交给谁），还有每个对话最近的 50 条。连上后会在后台给每个已有的 Bot Chat 取最近一页，所以没打开过的对话也存得下（Bot Chat 还是只在打开对话时才新建）。
- 存在 `~/Library/Application Support/dev.shion.Shion/last-data.json`（权限 0600），记着是哪个地址的；不存 service token、会话令牌、登录凭证和密码，它们只在钥匙串里。待你处理的批准和提问不存：只能连着时回答。服务器没有的部分不存（没装 shion 插件就没有待办、日报），没连上时那部分是空的。各助手复盘后留下的「自动沉淀」卡片（`review.summary`，服务器不保存）和待审核的技能卡也存在这里。
- 只有日期、没有时刻的待办（插件给的 `2026-11-13`），存的是那一天本身，不只是它在当时时区的零点：换了时区再打开，它还是 11 月 13 日，过完那一天才算逾期。早先存下的文件里只有那个零点，照旧能读，下次存的时候补上。和插件之间的这种日期一律按公历读写（`Support/WholeDay.swift`），系统的日历设成和历、民国历、佛历也一样；界面上怎么写日期仍跟系统的历法。
- 什么时候存：连上并读完第一遍以后，数据有变化 3 秒后存一次；断线的那一刻、点「断开」之前、退出 Shion 时各存一次。
- 启动时还没连上、断了线、点了「断开」，窗口里显示的都是这一份，只能看（在对话里说的话除外：排队，见「断线重连」）：侧栏底部服务器下面一行写「上次的数据 · 今天 10:52」（断了线正在重连时写「重新连接中…」），设置里的状态写「未连接，现在是上次的数据（…）」。连上并读完第一遍以后换成服务器的。
- 从没连上过这个地址时，窗口里什么都没有，只有一句「先连上你的 Hermes 服务器」和打开设置的按钮（`ConnectFirst`）。示例数据只给截图和测试用：它和启动参数 `-ShionSnapshot` 都只编进调试构建（`#if DEBUG`，`Model/Fixture.swift` 是唯一的入口），打包出来的 App 里没有。截图模式不读也不写这个文件，只在内存里留一份，端到端测试用它看断开后的样子。设置里「没连上时」一节写着存了什么、存在哪里，可以清除。

### 断线重连

经 Cloudflare Tunnel 连着 VPS，合上盖子、换 Wi-Fi，WebSocket 都会断。Hermes 那边照常：这一轮接着跑，批准一直等着，会话留着最近 512 帧事件。Shion 回来时从断开的地方接着（协议见上面「Canonical Gateway Protocol 要点」，`Gateway+Replay.swift`、`AppStore+Reconnect.swift`）：

- **连接状态**：连上过又断了，侧栏底部服务器下面写「重新连接中… · 10:53:21 再试」，点了在试的时候只写「重新连接中…」，前面的点是暖橙色。隔 1、2、4、8 秒试一次，之后每 15 秒；一次没连上只算一次（以前一次失败会被算两次，越等越久）。从睡眠里醒来（`NSWorkspace.didWakeNotification`）、网络变了（`NWPathMonitor`：通没通、哪些网卡、路由器）就马上试，不等下一次；看着还连着的先 `gateway.ping`（5 秒），20 秒没收到过任何东西的直接重连。设置里「没连上时」一节写着这些。
- **补上漏掉的**：每个会话记着最后看到的那一帧（`seq`、`replay_epoch`），换连接也留着。重连后，每个接上的 Bot Chat 按顺序（眼前这个先，然后是总秘书）先 `session.events.since`，补回来的帧和实时的走同一条路，然后 `session.resume` 接上。按 `seq` 去重，补的和接上时送来的重叠了也只算一次。这一轮还在跑，接着流进同一个气泡；断开时已经回完，直接是整段；断开期间的工具行、看板卡片、批准、提问都补上，期间已经回答掉的批准从「待你处理」里拿掉。服务器没有 `event-replay-v1`，或者回 `snapshot_required`，就退回读最新一页：断开时已经回完的那一轮在页里；还在跑的那一轮留着已经出来的部分，后面接一个「…」，再接着流，回完以后换成整段。不会剩下一直「正在回复」的气泡：一轮结束时，前面落下的这种气泡也一起收好。插件的推送不重放，重连后照旧补读一次。连接没断、只是跟不上时也一样：Hermes 把积压太多的订阅结束掉，连接留着，发一条 `session.replay_gap`（`gateway/session_events.py`、`session_authority.py` 的 `_retire_overflowed`）；Shion 就在同一个连接上 `session.events.since` 补上，再 `session.resume` 接上，这个对话里的话等接上了再发。
- **快照不盖过更新的帧**：`session.resume` 的快照是 Hermes 读会话那一刻的样子，回答稍后才到，这中间的帧会先到。一轮正好在这时结束，结束帧已经收到，快照却还写着在跑、也没有那条回复；照快照来，审核会话会丢掉刚到的回复并一直停在「正在回答」，Bot Chat 会一直显示在回复、这一刻问的批准也会从「待你处理」里掉出去。快照带着读它时在事件流里的位置（`replay_epoch`、`last_sequence`）：比已经收到的「一轮开始 / 结束、`session.info`、批准和提问」帧更旧的快照不拿来覆盖，重新要一次（最多再要三次）；如果每次都旧，就以帧为准：帧带来的回复、失败提示、批准和提问都保留，不会被旧快照抹掉或带回来，有没有一轮在跑也以更新的一方为准（`Gateway/EventCursors.swift` 的 `SessionWords`）。审核会话和 Bot Chat 都这样处理；快照换了 epoch（事件流重新开始）时无从比较，按快照来。这个先后顺序在真的 Hermes 上复现过（`macos/ci/real` 的 `behind` 阶段：把回答按住，一轮的结束帧先到，快照还写着在跑、没有那条回复）。
- **重新接上被拒**（`Model/Rejoin.swift`）：连接回来以后，或者订阅被结束、连接还在时，每个对话要在这条连接上 `session.resume` 一次才算接上。Hermes 拒绝了（比如存储一时忙不过来，`storage_unavailable`）而连接本身还好时，对话保持原样：记录、断开前出了一半的回复、你说过的话都在，输入框上面多一行「没能重新接上这个对话：」加 Hermes 给的原因、下次自己再试的时间，旁边是「再试一次」。这一行和输入框一样宽，最多两行，原因再长也截在两行里，鼠标停在上面能看到全文，「再试一次」一直在它旁边（以前它要多高就多高：对话页的最小高度是在零宽度下量的，这样量一个字占一行，页面比屏幕还高，窗口里的内容上下都被裁掉，这一行和输入框都看不见）。没接上就收不到这个会话新发的帧（每次再试只补上漏掉的那些），也就不知道这一轮还在不在跑，所以不再显示「在回复」和停止按钮；接上以后照会话自己说的来。可能过一会儿就好的原因，隔 1、2、4、8 秒自己再试，最多四次（和官方桌面端一样），之后只能点「再试一次」，点了又重新算这四次；会话已经不在了（`not_found`）、这个登录不能读它这类，再试也一样，不自己试。这期间说的话照常等这个对话接上（最多半分钟）；不会再自己试的就不等，Hermes 不收没接上的连接发来的话，那句下面写「没发出去」，「重发」等接上了才能点。⌥Space 小窗里总秘书的对话接不上时，小窗里也写这一行。审核会话也这样（写的是「没能重新接上这个会话」），连接回来时同样先补漏掉的事件再接上。
- **断开那一刻发出去的话**：每条消息的 `submission_id` 就是它在聊天里的 id。回执没回来连接就断了，这条消息淡一些，下面写「等连上后确认」。重连后核对：补回来的帧（或断开前收到的）里 `session.info` 的 `pending` 或这一轮的 `persisted_turn` 提到了它，就是收到了，照常显示；补不全时看快照的 `pending`，再看最新一页上有没有你在它发出前后说的同样的话。都没有就写「没发出去」，旁边「重发」：同样的话、同一个 `submission_id` 再发一次，放到最下面。万一 Hermes 其实收到了，它回原来那次的回执，不会再跑一轮，所以一句话不会出现两次。Hermes 当场拒绝的（服务器在重启、排队太多等），也是「没发出去」，后面写原因。带图片或文件的消息也一样，id 也是聊天里那一行的：重发时附件还在服务器上，就用同一个 id、同样的引用；图在服务器上已经被清掉的（Hermes 回 `invalid_params`），照「图片和文件」那条的规矩从这台 Mac 上的那份重新上传，算新的提交、用新的 id，这条消息从此就是那个 id。没连上时加不了图片和文件，所以它们不排队。
- **没连上时说的话**：主窗口的输入框没连上时也能打，说的话和 ⌥Space 小窗的排在同一队里（`QuickAskWaiting` 记着是哪个对话，存在 `UserDefaults` 的 `QuickAskWaiting`，退出 Shion 也还在），显示在那个对话的最下面，淡一些，下面写「10:31 写的 · 等连上服务器后发出」。连上、读回服务器的数据、这个对话在新连接上接上以后，按顺序一句一条发出；写下超过 5 分钟才发出去的，前面带上写下的时间（「（10:31 写的）提醒我明天带伞」），规则和小窗一样。主窗口的不像小窗那样合成一条，一句一条，和输入框里的气泡一一对应：Hermes 收到的 `prompt.submit` 只排队、不打断正在跑的那一轮（已核对）。图片和文件要先传到服务器上，没连上时加不了（「＋」是灰的），带着它们的消息也不排队。勾待办、回答批准这些照旧只读，等连上再做。
- **批准、提问**：断开时还在等的，重连后还在「待你处理」里，这时回答，等这个对话在新连接上接上了才发出去（Hermes 只收接上了的连接的回答）。
- **没做的**：`session.detach` 用不上（断开的连接 Hermes 自己按孤儿处理）；退出 Shion 时还没核对完的消息，下次启动不再核对，以对话记录为准；断开期间点「重发」不行，连上后才能点。

### 快捷呼出

- **⌥Space 小窗**：在任何 App 里按 ⌥Space（「设置 → 快捷键」里能改），鼠标所在那块屏幕的上方约五分之一处浮出一个玻璃小窗：输入一句话回车，这句话进总秘书（`chiefId`，默认是詩音）的 Bot Chat，和在主窗口里说的一样；她的回复在小窗里流式显示，用的是对话页的同一套行（工具调用折成一行、看板卡片、Markdown）。这一轮里总秘书要你批准的、问你的列在回复下面（不在回复的滚动区里，回复再长也不会被滚走），每个选项都能直接点；没有选项、要你打字回答的问题，输入框的提示变成「回答詩音…」，打字回车就是回答（`clarify.respond` 的 `answer`），不用打开对话。输入框右边的按钮（⌘O）打开完整对话；Esc 或再按一次快捷键收起。小窗是不激活 Shion 的 `NSPanel`：键盘到它这里，前台的 App 不变，收起后键盘回到原处；它浮在所有窗口上面，也能出现在全屏 App 上，点别处不会自己消失。收起时这一问已经答完的，下次打开是空的；还在等回复的，下次打开接着显示。小窗开着、显示着这一问时，她的回复、批准和提问不再另发系统通知。发之前先接上她的 Bot Chat 并读最近一页（和打开对话页一样：`session.resume`、`session.transcript`，没有就新建），流式回复才有地方落。菜单、设置里写的是当前总秘书的名字（「跟詩音说…」），换了总秘书就跟着换。
- **没连上时说的话**：排队，不丢（窗口显示着上次的数据时也一样，连上、读回服务器的数据以后才发）。在小窗里显示成淡一些的气泡，下面写什么时候写的和「等连上服务器后发出」（「17:05 写的 · 等连上服务器后发出」）；存在这台 Mac 上（`UserDefaults` 的 `QuickAskWaiting`，退出 Shion 也还在；截图和测试模式只放在内存里），连上后自动发给总秘书，回复照常出现在小窗里。断线后窗口显示上次的数据（只读）时也一样排队；重新连上后，等第一批数据读回来、窗口不再只读，才发出去（只读时发不出去）。攒了几句就合成一条发、一句一行：小窗只显示一问一答，几句一起说的话，总秘书一次回答更自然。（分开发也不会打断：Hermes 收到的 `prompt.submit` 是排队的，等正在跑的那一轮回完才轮到下一条。）写下超过 5 分钟才发出去的句子，前面带上写下的时间（「（10:32 写的）提醒我 5 分钟后出门」，不是今天写的再加「昨天」或日期），不然隔了两小时才连上，总秘书会照字面去做；不到 5 分钟的照原样发。总秘书的对话打不开时也留在队里，下次打开小窗再试。主窗口对话里没连上时说的话也排在这一队里（`QuickAskWaiting` 记着是哪个对话），各自发回自己的对话，一句一条（见「断线重连」）。没选「记成待办草稿」（本机模型）是因为：跟总秘书说的话不一定是待办（「到家了吗」「明天几点出门」），记成草稿就改了原意，总秘书看到的也不是你的原话；排队什么都不猜，日期不会被抽错，也不靠 Apple 智能（没开、不是 Apple 芯片就用不了），在 CI 上测得出来；理解、拆解本来就交给 VPS 上带着记忆和日程的总秘书（见「本机模型」）。
- **⌘1…⌘7、⌘K**：菜单栏多了「前往」：⌘1…⌘7 依次是今天、待你处理、待办、日程、日报、看板、云桌面，然后是 ⌘K「快速跳转…」和「跟詩音说…」（名字跟着总秘书，标着全局快捷键）。⌘K 在主窗口上面浮一块玻璃：没输入时列出页面和助手；输入后搜页面、助手（名字、简介、profile 名）和没做完的待办的标题（最多 6 条），↑↓ 选，回车打开，待办打开在「待办」页右边的详情里；什么都没搜到时只剩一行「跟詩音说「…」」，回车把这句话交给她并打开她的对话。全角字母、大小写不影响匹配；输入法选字时的回车和方向键归输入法。原来「跟詩音说」按钮上的 ⌘K 让给了快速跳转，按钮本身不变。
- **选型**（2026 年 11 月）：

  | | 结论 |
  | --- | --- |
  | sindresorhus/KeyboardShortcuts | **用它录快捷键**（MIT）。2026 年还在发版：3.0.0（6 月）、3.1.0（9 月，含 macOS 27 的兼容修正）；录快捷键的控件（有简体中文）录的时候提示和系统快捷键（聚焦搜索、切换输入法等）或菜单撞了，按键盘布局显示键名。只用它的 binding 版控件，不用它注册：它注册时不带选项（共享），失败了也不告诉调用方，被别的 App 占了没法提示。快捷键 Shion 自己存（`UserDefaults` 的 `QuickAskShortcut`，不是密钥）；截图和测试模式不读不写，只在内存里用 ⌥Space，也不向系统注册，测试要按它时启动参数带 `-ShionHotKey YES`。包加在 `macos/project.yml`，版本限在 3.1.x |
  | Carbon 的 `RegisterEventHotKey` | **注册用这个**，自己调（`macos/Shion/Support/GlobalHotKey.swift`，不弹权限），带 `kEventHotKeyExclusive` 独占注册：别的 App 已经独占了这个组合时返回 `eventHotKeyExistsErr`，设置里就能说被占了；Shion 拿到之后，别的 App 再来注册同一个组合会失败，抢不走。设置在录新快捷键时先放开旧的，录完再注册 |

  ⌥Space 只用了 Option 一个修饰键。macOS 15.0、15.1 上沙盒 App 不能注册只带 Option（或 Option+Shift）的全局快捷键，15.2 起又放开了；Shion 本来就不开沙盒（专注检查要读别的 App 的窗口标题），不受影响。

  **被别的 App 占了**：Raycast、Alfred 这类启动器的默认快捷键也常是 ⌥Space。看得出来的：别的 App 独占注册了同一个组合，Shion 注册时被拒（`eventHotKeyExistsErr`），「设置 → 快捷键」里在快捷键下面显示「被别的 App 占用了，换一个组合吧」和「再试一次」；Shion 回到前台、打开这一栏时也会自己再试一次，那个 App 放开了就好了。看不出来的有两种，系统都不告诉 Shion：别的 App 普通（共享）注册的，Shion 的独占注册照样成功，按键归 Shion，那个 App 的同一个快捷键就不灵了；用事件监听（event tap）抢在系统快捷键之前截走按键的，Shion 的注册也成功，只是按了没反应。设置里的说明写了这两种，让人换一个组合。
- **以后要处理**：云桌面接管期间键盘都该发给远端，但 ⌥Space（系统级快捷键，按下去到不了远端）和 ⌘1…⌘7、⌘K 会先被 Shion 拿走，做接管时要让这些快捷键在接管期间让路（只留交还键）。
- **Hermes 那边**（按 `tui_gateway/contracts/canonical_sessions.py`、`gateway/session_surface.py`、`agent/prompt_builder.py` 核对）：`prompt.submit` 不认识的参数一律拒绝（`extra="forbid"`）；它有个 `surface` 参数，`hud` 是官方桌面端浮动 HUD 用的，只在会话有 `read_window_below`（读 HUD 下面那个 App 的窗口）这个工具时，给模型添一句「这条来自 HUD，"这个""这里"多半指下面那个 App」，没有这个工具就什么都不加。VPS 上的詩音读不到这台 Mac 的窗口，所以小窗不带 `surface`，发的和对话页一样：`profile`、`session_id`、`text`、`submission_id`。

## 界面原则（SwiftUI 版照这个来）

- **层级靠字号和留白，不靠框。** 只有需要你动手的东西才放进框里：「需要你」托盘、看板卡片、确认卡片、云桌面画面。其余都是标题加列表。
- **颜色只表达三件事。** 紫色（詩音的主题色）表示选中和主操作；暖橙表示在等你；红色表示逾期、"此刻"、你在操作云桌面。领域和助手的颜色只出现在小圆点、头像和日程色条上。
- **玻璃只给浮在内容上面的控件**：输入框、⌥Space 小窗、⌘K 面板、云桌面的接管条、菜单栏弹出面板；同一处的几个玻璃控件放进一个 `GlassEffectContainer`。列表、看板卡片、确认卡片这些内容层不用玻璃，玻璃上也不叠玻璃。只有主操作按钮用 `.glassProminent` 染成紫色。
- **字号五档**：11（角标）、12（次要信息）、13（正文）、15（小节标题）、20（详情标题），外加今天页 30 号的日期。
- **说明只写在设置里。** 发什么、不发什么，一个功能怎么运作，写在设置里对应开关的下面。主窗口和菜单栏只放状态和操作，不加解释性的注释、提示，也不加"仅本机可见"这类标注。
- **界面里不出现编号和协议词。** 任务卡编号、profile、模型名只放在详情底部的技术信息里。工具步骤默认折叠成一行。
- **动的东西只有两种**：助手在做事时的三个呼吸点，和流式输出的光标。系统控件自带的反馈（按下玻璃按钮、弹出层出现）照常保留，但不自己另加动画。
- **一个入口找詩音**：今天页的输入框；其他页面右上角的「跟詩音说」按钮；在 Mac 任何地方按 ⌥Space（设置里能改）；⌘K 里什么都没搜到时，回车也是交给她。（换了总秘书，这些入口都改成找新的总秘书，用这个助手的名字和头像。）
- **詩音的标记**：一个写着「詩」的圆形标记，和她的头像同一个样子；出现这个标记的地方就是在跟她说话。菜单栏里用单色描边版，符合 macOS 菜单栏模板图标的习惯。

## 仓库结构

```
prototype/      UI 原型（Vite + React + TypeScript，示例数据）
  src/data/     模型、示例数据、模拟器（课后整理、核查、催促会自己播放）
  src/views/    今天、待办、日程、日报、待你处理、Bot Chat
macos/          macOS App（SwiftUI + AppKit，最低 macOS 27），project.yml 由 XcodeGen 生成工程
  Shion/        App：Model（数据；示例数据只编进调试构建）、Local（这台 Mac 的日历、前台窗口、本机模型和它们的假数据）、Support（启动参数、格式、配色）、Views（各页面）
  ShionUITests/ 截图测试（每个页面浅色、深色各一张），浏览器登录、看板、助手管理、⌥Space 小窗、对话控制、图片和文件、断线重连、助手要密码和密钥、点通知和快捷指令的端到端测试；这台 Mac 的数据（日历、专注检查、应用使用记录）的截图和端到端测试；StandIn.swift 是测试直接对替身说的话（断线后什么时候恢复隧道）。runner 的沙盒由 Xcode 的 XCTRunner 模板给，ShionUITests.entitlements 只给它加上出站连接
  ci/           CI 上替身用的假 Hermes（fake_hermes.py，看板 fake_kanban.py，profile fake_profiles.py，小窗的回复 fake_quick.py，停止和重试 fake_control.py，图片和文件 fake_media.py，断线和重连 fake_reconnect.py，sudo 和 secret 请求 fake_secrets.py，认剧本前把用户的话规整成 NFC 的 fake_words.py，通知和快捷指令要的几轮 fake_extras.py，只用标准库）；check_fake_shion.py 比较替身和插件收不收得一样、`usage.day` 算得一不一样
.github/workflows/macos.yml   在 macOS 27 runner 上编译、截图、跑登录测试
hermes-plugin/  Hermes 的 shion 插件（服务器端）：待办、今天的汇总、日报、应用记录、专注检查；接口见 hermes-plugin/README.md
.github/workflows/hermes-plugin.yml   在 ubuntu runner 上跑插件的 pytest
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

- **下载**：手动运行 Actions 里的「macOS app」工作流，或者推一个提交说明里带 `[package]` 的提交。跑完后在这次运行的附件里下载 `Shion-macOS-<编号>`（保留 30 天），解压出 `Shion.dmg`，把 Shion 拖进「应用程序」。镜像先用 `diskutil image create from` 做（macOS 27 上 `hdiutil` 已弃用），做不成才退回 `hdiutil`，并在这次运行上报警告。
- **第一次打开**：测试版只做了本机签名，没有 Developer ID 签名和公证，macOS 会拦下来。到「系统设置 → 隐私与安全性」里点「仍要打开」，或者在终端运行：`xattr -dr com.apple.quarantine /Applications/Shion.app`。
- **填设置（⌘,）**：地址填 Webapp 的地址（比如 `https://hermes.example.dev`）；Access Client ID / Secret 填 Cloudflare Access 的 service token；登录方式选「浏览器登录」，点「用浏览器登录…」，在弹出的窗口里先登录 Cloudflare Access（比如邮箱验证码），再输入 Hermes 的用户名和密码。登录完会自动连上。登录凭证默认 12 小时到期，Shion 每次连之前快到期就自己续，续一次管 30 天，一直在用就不用再登录。凭证和密钥存在钥匙串里；装了新版本后第一次读，macOS 可能问要不要允许，选「始终允许」。
- **Access 要允许浏览器登录**：登录窗口不带 service token，要像普通浏览器一样先登录 Access。在 Cloudflare Zero Trust 里打开这个 Hermes 应用的策略，除了给 Shion 用的 Service Auth（service token）那条，再加一条 Allow：Include 选 Emails，填你自己的邮箱。登录方式用 One-time PIN（邮箱验证码），在「设置 → 身份验证」里打开。用普通浏览器打开 Hermes 的地址，看到 Access 的登录页、能用邮箱验证码进去，就说明设好了。
- **服务器要开账号密码登录**：在 `~/.hermes/config.yaml` 的 `dashboard.basic_auth` 下设 `username` 和 `password`（或者更好的 `password_hash`），再设 `secret`，然后重启 gateway。`secret` 用 `openssl rand -base64 32` 生成；不设的话每次启动都换一个随机值，gateway 一重启所有登录都失效，Shion 要重新登录。也可以用环境变量 `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`、`_PASSWORD`、`_SECRET`。
- **还是想用会话令牌**：登录方式选「会话令牌」，填服务器上的 `HERMES_DASHBOARD_SESSION_TOKEN`，点「连接」。
- **服务器那边**：`/api/ws` 要由 `hermes gateway` 提供，Canonical 协议只在它上面有；单独跑的 `hermes serve` / `hermes dashboard` 说的是旧协议。`HERMES_DASHBOARD_SESSION_TOKEN` 要事先设好，不设的话每次启动都是随机值。经 Cloudflare Tunnel 转到本机端口时，Webapp 的 `public_url` 要填对外的地址，不然 Host 对不上会在握手时就被拒：Hermes 在接受连接之前用 4403 关闭，客户端看到的是 HTTP 403。
- **连不上时**：设置里的「服务器体检」一项一项地查（页面顶上一行写有几项要处理，旁边是「重新检查」），每项写着现在怎样、不对的话怎么改：Cloudflare Access 放不放行（`/api/status`）；登录凭证有没有效、多久到期（`/api/auth/me`）；`/api/ws` 是不是 `hermes gateway` 的 Canonical 协议，`runtime.describe` 报了哪些能力（Shion 用到 `session-transcript-v1`、`plugin-rpc-v1`、`session-client-v1`）；每个助手的 profile 里有没有 shion 插件（`plugin.shion.info`，`-32601` 就是没装或没启用）；服务器有没有时区数据（`plugin.shion.info` 的 `tz_database`：Hermes 的镜像是 Debian 13，不一定带 tzdata，缺的话写「服务器缺时区数据」，修法是在容器里装 tzdata、写进自己的 Dockerfile，或者用没有夏令时的时区）；看板插件在不在（`/api/plugins/kanban/boards`）；看板同时进行的上限（`/api/config`）；这台 Mac 允不允许 Shion 发通知（只读，不替你申请）。Shion 连之前也会先用 HTTP 查一遍，设置里会写出是哪一步不对：Cloudflare Access 没放行；服务器没开浏览器登录（`/api/status` 的 `auth_flows` 里没有 `native_pkce`）；登录过期了；服务器没开会话令牌登录（`auth_providers` 里没有 `session-token`）；令牌对不上（`/api/auth/me` 返回 401）；或者 WebSocket 被拒（带 HTTP 状态码）。也可以在终端自己查，这是 Hermes 文档给的检查方法，加上 Access 的两个头：

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
- **现在能用的**：助手列表（每个 profile 一个助手）、每个助手的 Bot Chat（打开时先取最近 50 行，往上滑再一页一页取更早的；发消息、流式回复；工具调用在这一轮回复完成后折成一行，点开能看每一条；回复按 Markdown 显示，表格、列表、代码块都排好；能发图片和文件，你发的图、工具的截图、助手交来的文件和回复里的图都显示在对话里，Mac 上留一份，见「对话的显示」）、批准和提问（连上后在后台接上每个助手已有的 Bot Chat，所以没打开过的对话里的批准和提问也会到「待你处理」，侧栏也能看到谁在忙；接上之后再给每个取最近一页，留作没连上时看的数据），系统通知（批准可以直接在通知里点「允许这一次」或「拒绝」，提问和回复可以直接在通知里回；对话或「待你处理」正开在眼前时不发；Dock 图标上是待你处理的件数，卡片也算在里面）、看板（服务器的卡片、实时更新、拖动换列、新建、详情、评论署登录名、切换看板）、等你回答的卡片（在「待你处理」里回复、让它继续）、卡片的系统通知（卡住等你、交给你检查、做完了，做完的可以关；等你回答的可以直接在通知里回复；点了打开那张卡）、每个助手的工作记录（今天跑过的卡，所有看板，之后归档的也在）、今天页的「助手在做」和对话里的卡片（取自所有看板）、设置里的看板上限（取自服务器）、停止和重试一轮回复、对话里查找（见「停止、重试、查找」）、没连上时显示上次的数据（见「没连上时显示上次的数据」）、断线重连（补上漏掉的事件、核对断开时发出的话、没连上时说的话排队，见「断线重连」）、设置里的服务器体检。服务器装了 `shion` 插件（`hermes-plugin/`，装法见那里的 README）时，今天页顶部詩音写的那段话、待办（勾掉、确认日期、新加都写回插件）和日报也来自服务器；助手经插件改了数据，Shion 一秒左右就收到推送，断线时漏掉的推送在重连时和每 5 分钟补一次。没装插件时这几页照旧是示例数据。日程、今天的时间线和菜单栏的「下一件」来自这台 Mac 的日历（「设置 → 这台 Mac」里允许读取、勾选日历；不经过服务器，连上过一次以后没连着时也一样；一次都没连上过时窗口里只提示去连接，只有菜单栏的「下一件」照常）。专注检查（设置里打开，要辅助功能权限和 Apple 智能）和应用使用记录（默认开）在这台 Mac 上记，连上装了插件的服务器时把结论发给总秘书、把应用段发给回顾。云桌面还是示例数据。
- **助手**：设置（⌘,）的「助手」一栏选谁当总秘书、哪些助手在 Shion 里不显示（Hermes 自己的默认 profile 删不掉，不用就不显示），按服务器地址存在这台 Mac 上；没选过时名叫 `shion` 的 profile 当总秘书，没有就是默认 profile。总秘书决定今天页那段话、专注检查发给谁、shion 插件在哪个 profile 里调用；「跟…说」的按钮、今天页的输入框、⌥Space 的小窗、⌘K 和菜单栏都用总秘书的名字和头像。换成没装插件的助手，今天、待办和日报回到示例数据。这台 Mac 第一次见到一个助手时，照 Bot Mode 的 `ui_meta['hermes-bots'].hidden` 决定显示不显示，之后以这台 Mac 的选择为准。「新建助手…」（那一栏，或侧栏右键）经 `profiles.create` 建 profile：名字、显示名、简介、SOUL、模型，可以复制一个现有的；不复制时 Hermes 把服务器自己的密钥和模型给它。每个助手有自己的设置页（侧栏右键「助手设置…」，或对话页顶部的按钮）：显示名（写进 `ui_meta`，和 Bot Mode 同一处）、头像（Bot Mode 的颜色和形状，写回 `ui_meta` 前比对版本号；图片经 `profiles.set_asset`；侧栏和对话里都用它）、简介、SOUL、模型、MCP 服务器（添加、编辑网址、命令、参数和登录方式、删除、开关、测试、OAuth 登录、从目录安装，要先下载的条目在后台装完会自己出现）、技能（开关、锁定）、工具，还有危险命令的审批方式、记忆、每轮步数上限；最下面删除这个助手（默认 profile 和总秘书除外）。删除时 Hermes 没能当场清掉这个名字的会话和路由记录（`settlement_pending`）的话，设置里列在「还在清理」，同名的新建先拦住；Shion 连着服务器时经 `cli.exec` 重试 Hermes 给的 `hermes profile purge-identity`，成功了自动放行。每个请求都写明是哪个 profile：路径里带名字，或者 `?profile=`；Shion 从不调 `POST /api/profiles/active`。删除、替换 SOUL、服务器提醒要确认的模型都先问你。MCP 的令牌和环境变量用密码框输入，只发一次，Shion 不显示、不保存，也不从服务器取回（不调 `/api/env/reveal`；编辑时只合并改了的项，新的令牌和值经 `mcp.servers.set_api_key` 存进那个 profile 的 .env，config.yaml 里只留引用）。
- **快捷键**：在任何 App 里按 ⌥Space 跟总秘书说一句话，回复在小窗里流式显示，这一轮里的批准和提问也在小窗里回答，⌘O 打开完整对话，Esc 收起；没连上服务器时说的话排队，连上后自动发出；主窗口里 ⌘1…⌘7 切页面，⌘K 快速跳转（页面、助手、待办标题），都列在「前往」菜单里；全局快捷键在「设置 → 快捷键」里改，被别的 App 占了那里会说。见「快捷呼出」。
- **开机启动、只留在菜单栏**：「设置 → 这台 Mac」里日历、专注检查、应用使用记录后面的两个开关，默认都关（点通知落在哪、快捷指令能做什么写在再后面两节）。「开机启动」用 `SMAppService.mainApp` 把 Shion 登记成登录项，下面写着现在的状态；系统要你批准时写「要在系统设置里允许」，旁边的按钮直接打开「系统设置 → 通用 → 登录项」（`SMAppService.openSystemSettingsLoginItems()`），在系统设置里改了，回到 Shion 时跟着变。「关窗后只留在菜单栏」打开后，关掉最后一个主窗口时 Dock 图标也收起来（activation policy 换成 accessory），待你处理的件数从 Dock 角标挪到菜单栏图标旁边（菜单栏项只显示一张图和一段字，所以总秘书的标记和件数画成一张模板图：数字从一个实心小胶囊里镂空，菜单栏照它的深浅色给它上色），菜单栏面板最下面多一行「打开 Shion」，旁边写着侧栏底下那行连接状态（重新连接中、上次的数据和时间：窗口关着时只有这里看得到）；主窗口再出现（面板、点通知、快捷指令）就换回 regular，Dock 图标和菜单回来。截图模式两个开关都只在内存里，不碰系统的登录项（`-ShionLoginItemDemo requiresApproval`、`-ShionMenuBarOnly YES` 用来截图）。
- **点通知**：每条通知的 userInfo 带着找回那一项要的东西（`Landing.swift`），点开落到那里：回复打开那个对话、从那条消息的开头显示（按 `message.complete` 的 `persisted_turn.final_assistant_row_id` 找，它就是 transcript 里那一行的 `row_id`，Hermes 说客户端应该这样把流式的回复对上存下的那一行；没有时按流进来的那一行、再按开头几个字和时间找）。滚过去用的是对话自己的那一套（`TranscriptPlace.land`，和查找跳到命中一样）：顶对齐，它的顶不在眼前就再跳，最多三次；跳的时候要是正有一行在放回原处（更早的一页刚进来），先等那一行放好。之后更早的一页进来，顶上那一行（就是这条回复，比可见部分还高也一样）放回原处，它不会被挤走。批准、提问，包括助手要密码和密钥，都打开「待你处理」并选中那一件（紫色描边）；看板卡片打开那块看板上那张卡的详情（看板那边做好的 `openCard`）；日报打开那份日报，已经不是同类里最新的就用 `reports.get` 读那一天的。日报是新加的通知：连上之后插件里多了一份（回顾晚上写的、资讯早上写的）就发一条，日报页开在眼前时不发，一种一条、新的替换旧的；连上时已经有的不算。Shion 没开着、是被这一下点开的，就先停在那一页，连上服务器、读到那一项后再落到它上面（卡片要等看板读完才换到它的看板，原来的 `reveal` 在看板启动时会被清掉）；找不到的（已经处理掉了）停在那一页，换了页就作罢。
- **快捷指令、聚焦搜索、Siri**：四个 App Intents，带中文的 App Shortcuts 说法（`Intents/`）：「跟总秘书说」（一段文字，进总秘书的 Bot Chat，和 ⌥Space 小窗发的一样；10 秒内这一轮说完了就把回复带回来，这条回复不再另发通知，没说完就回「已发出」，回复照常通知）、「今天的待办」（和今天页一样，取自插件，返回待办列表）、「打开助手」（按名字、简介、profile 名在服务器的助手里找，和 ⌘K 一样，打开它的对话；说法里不带助手的名字，Siri 会再问是哪一个）、「打开待你处理」。没登录服务器时一律什么都不发，并说明是哪一步（没登录；读待办时还有没装插件）。登录了但没连上（正在重连，或在设置里断开了，窗口显示上次的数据）时，「跟总秘书说」的这句话和在窗口、⌥Space 小窗里说的一样先排着，连上后发出（见「断线重连」），动作回答「还没连上服务器，这句话先排着」；一次都没连上过这个服务器、也没有上次的数据时什么都不发，说连不上（带原因）。Shion 没开着时动作会先启动它、等它连上（最多 15 秒）。说法要 Siri 的语言是中文；Mac 的 Siri 设成日语时（见「最低 macOS 27」），快捷指令 App 和聚焦搜索里照样能用，要开口说还得加日语的说法。
- **日报里的屏幕时间**：学习、工作、生活日报下面画那一天的屏幕时间（`Views/ScreenTime.swift`，Swift Charts）：先是七类（学习、工作、生活、娱乐、社交、其他、未分类）各多少，按时长排，再是用得最多的 5 个应用；横条一种颜色（灰的：紫、橙、红在这里另有意思），时长写在条的末端，不画坐标轴，VoiceOver 把每一行连同时长读出来。数据是插件的 `usage.day`，按那份日报的日期取（早上看的是昨天的日报，图也是昨天的）；应用归哪类由插件定（它的内置表，或回顾用 `shion_usage_set_category` 改过的；浏览器和邮件算未分类）。插件推来 `usage` 的变化时（这台 Mac 每 10 分钟传一次）重取，所以今天的会跟着长。新闻日报下面不画，讲的是外面的事。窗口显示「上次的数据」时不画：这些时长是还在走的数，断线时的旧数看上去像现在的；日报正文是写好的定稿，不一样。没装插件、没连服务器时，和日报一样是示例数据（截图模式也是）。
- **连接方式**照官方桌面端连远端的做法：`wss://<地址>/api/ws?token=<登录凭证或会话令牌>`，不带子协议，每个请求带 Cloudflare Access 的两个头；连上后等 `gateway.ready`、发 `client.capabilities`，按服务器要求每 15 秒 `gateway.ping`；连上过又断了会自动重连，从断开的地方接着收（见「断线重连」）。登录凭证被拒时先续一次再试，续不上才算登录过期。
- **助手要密码或密钥时**：终端要 sudo 密码、技能要密钥时，对话里和「待你处理」里出现一张卡片，填了只经这条连接发一次，Shion 不留；见「助手要密码和密钥时」。答完的批准、提问、密码和密钥在对话里和小窗里留一行（只在这次运行里），见「答完以后留在对话里的一行」。

### 原生 App 的界面检查

界面靠 CI 截图来看，不在本地开模拟器：
- **什么时候跑**：只有 `macos/` 或这个工作流改了才跑，也可以在 Actions 里手动触发；同一分支上新的提交会取消还没跑完的那次。手动触发时可以选跑什么（`run`）：`all` 全部；`build` 只编译调试版和发布版（发布版里没有示例数据，这一步确认它照样编得过），两个各在一台 runner 上，发布版每次从头编，所以四五分钟；或者只跑某一组端到端测试，要一起跑的别的组把名字写在 `suites` 里（空格分开），每组一台 runner 同时跑。哪一组失败了就只重跑那一组：编译加一组大约六七分钟，全部跑一遍要十八分钟。`logic` 只跑逻辑检查（`macos/ci/logic`：不起应用，把应用自己的源文件编进小程序对着写好的回答跑，一两分钟），全量运行里也带着。
- **怎么分的**：UI 测试要占着屏幕，一台 runner 上一次只能跑一组，所以一次运行分到几台 runner 上同时跑（`.github/workflows/macos.yml`）：`build` 编译一次测试用的调试版，把产物打成 tar 交给后面的 job（`test-products` 附件，留 1 天；用 tar 是因为附件自己的 zip 会丢掉符号链接、权限，签名也就坏了）；`screenshots` 截每个页面；`e2e` 把 13 组端到端测试分成三份，各十二分钟上下，比截图那个 job 短一点（1：Extras、SignIn、LocalData、Secrets；2：BotPage、Board、QuickAsk、Media；3：Reconnect、Bots、ChatControl、Compose、Work；照 run 189 和 191 里各组的时间分的），每组照旧先起一个新的替身；`package` 编发布版、打 `Shion.dmg`，不等任何测试，每次从头编，不用编译缓存；最后 `shots`（Linux）把各 job 的截图和替身日志合成一个附件。跑测试的 job 不再编译，也不生成工程：解开 tar，用里面的 `.xctestrun` 跑 `xcodebuild test-without-building -xctestrun …`，解开后先验一遍签名。手动只跑一组时，`e2e` 只有那一组，不截图、不打包。
- **哪一步红了**：某一组端到端测试失败，它所在的那一份就是红的（以前整次运行是绿的，只有一条警告），失败的组名在那个 job 的注解里；同一份里后面的组照样跑，另外两份、截图和安装包都不受影响，那一份的截图和日志也照样导出、上传。「No password written down」在每个跑测试的 job 里查自己的替身日志、偏好设置和 Application Support，`shots` 里再把所有替身日志合起来查一遍。上传附件失败（遇到过 runner 解析不了域名）会再试一次。
- **编译缓存**：只有测试版的编译用。`build` 这个 job 编译时打开 Xcode 的编译缓存（`COMPILATION_CACHE_ENABLE_CACHING=YES`，存在 `macos/build/cas`），用 `actions/cache` 留到下一次运行。发布版不用：`package` 里没有缓存这一步，xcodebuild 也不带这些设置，`Shion.dmg` 和只编译的发布版检查每次都从头编。缓存按内容找：每次编译的输入（源文件、参数、SDK）算出一个键，输入一样才用存下的结果，所以改过的文件一定重新编译，警告也会随缓存的结果再报一遍。粒度是模块：只改测试，App 和两个包不重编；只改 App，包不重编，但 App 模块整个重编。`actions/cache` 的键是 Xcode 和 macOS 的版本加上源文件的哈希，源文件变了就从这个工具链最近的一份接着用，再存一份新的；超过 3 GB 就清掉重来。缓存只在同一分支（和默认分支）之间共用，新分支的第一次运行是冷的。
- **跑什么**：在 `xcode-27` runner（macOS 27、Apple 芯片）上生成工程、编译，再跑 `ShionUITests`（几台 runner 同时跑，见上面「怎么分的」）：每个页面用启动参数直接打开（`-ShionSnapshot YES -ShionRoute today -ShionAppearance dark`），等界面稳定后截窗口（对话截詩音、课程、资讯的三段：折起来的工具调用，排好的表格、列表、代码块、引用和任务列表，放不下的宽表格和很长的代码行；`assistant-shion` 是詩音的助手设置页，示例数据；`chat-mail` 是邮件的对话：你拍的讲义、工具看过的收件箱截图、交来的 Word 模板和一张等你点的网上图片，`chat-mail-attachments` 是它的输入框上方排着要发的：一张图和一个文件传好了，一张在传，一个太大标红，用 `-ShionDemoDrafts YES` 放进去）；再把詩音那段很长的代码行和资讯那张宽表格各横向滚一下，各截一张（`chat-*-scrolled.png`），最右边露没露出来、旁边的字动没动写在日志里（这一步失败会让后面的端到端测试跳过，所以断言放在 BoardTests 里）；另外点开菜单栏面板截整个屏幕，按 ⌘, 截设置窗口（还有已登录和会话令牌两种设置、用编出来的结果画的服务器体检页 `settings-check-*.png`（不连任何地址）、「快捷键」一栏，和滚到「图片和文件」的一张）；詩音的对话以一轮出错收尾（示例，`-ShionFailureDemo YES`），截出错说明和展开的「详情」（`failed-turn-*.png`）；课程的工作记录（`-ShionTab work`）：今天跑过的三张卡，再点开等验证码的那张在右边看详情（`work-study-*.png`）；在詩音的对话里 ⌘F 找「作业」，你的紫色消息和她的回复里都有命中（`find-*.png`）；`ReconnectScreenshotTests` 截正在重连的样子（示例，`-ShionReconnectDemo YES`，不连任何地址）：侧栏写着「重新连接中…」和下次试的时间，詩音的对话里一条「没发出去」带「重发」、一条「等连上后确认」、两条排着队的（`reconnect-chat-*.png`）；截 ⌥Space 小窗（整个屏幕：带一问一答的示例、从「前往」菜单打开的空小窗、没连服务器时发了一句），⌘K（没输入、搜「课」，再用 ↓ 和回车打开一条待办），并检查 ⌘1、⌘2、⌘6 切到的页面和 Esc 收起小窗（`quick-*`、`jump-*`、`settings-shortcut-*`）。
- **浏览器登录、看板、助手、小窗、对话控制、图片和文件、断线重连的端到端测试**：runner 上没有真的 Cloudflare 和 Hermes，`macos/ci/fake_hermes.py` 两个都演：Access 按严格 service token 认证来（带 token 的请求只看 token、不发 cookie，错的 token 直接 403；不带 token 的浏览器转去另一个域名上的 Access 登录页，登录后靠 cookie 放行）；登录页自己填用户名密码提交；检查 PKCE、回调地址和 state；发登录凭证；`/api/ws` 说 JSON-RPC。替身还照 Hermes 的接口检查参数：`session.resume`、`session.transcript`、`session.create`、`prompt.submit` 不认识的键一律 `invalid_params`，`source` 和 `client` 也照规则查。`SignInTests` 在设置里填好地址，点「用浏览器登录…」，等登录完、连上、助手列表换成服务器的；先到「待你处理」：没打开过的课程的对话发来一个批准，点「允许这一次」，替身记下回答；再看今天、待办、日报是不是插件里的（替身里的插件在 `macos/ci/fake_shion.py`）：勾掉一条待办，等课程经插件加的那条推过来；再打开詩音的对话（135 行，先只来最近 50 行；照 Hermes 的样子，压缩行和存它的那条消息共用 `row_id`，工具行没有 `row_id`），打开时最新一条在眼前，发一句、等回复，回复跟到了眼前；往上滑到第一条：先把指针移到对话左边停一下，再从 40 点推到 80 点、两个方向都试，看哪个方向往上、推不推得动（runner 上第一下推 40 点有时不动，80 点就动了；都推不动时换到课程的对话再回来、再推一次，只记数字，照样算失败）；然后一次滑 300 点，替身隔 1.5 秒才回更早的页（像真的网络），每滑一下都在等它之前和之后各读一次眼前最上面那一行，位置不变（差 4 点以内），第二页、第三页来时都一样；到顶后再往上滚一下（截图里要看到最顶上），看压缩行、第一条都在，后面那轮的两次工具调用折成了一行；打开通勤的对话（新建，只有一条，贴在底部、输入框上面）；最后看设置里的看板上限是不是服务器的值。每一步截一张（`signin-*.png`），对话里各处的位置写在 `signin-positions.txt` 里。SignInTests 另一个方法不连替身，用示例数据：把对话页套进一层 inspector（`-ShionChatInspector hidden` 和 `shown`；看板那条分支碰到过，页面打开时 split view 把它重新接一遍，对话回到了最顶上），从日报点进詩音的对话，各两次，记下滚动条在哪（`signin-9-inspector-*.png`，数字在 `signin-inspector.txt`）：这是上面说的已知问题，停在顶上不算失败（`XCTExpectFailure`，不严格：哪天到了最底下也不报错）；不在最底下时，再记打开 3.5 秒后在哪、用查找跳到最新一条回复里的字（至少覆盖）以后在哪；第三个方法打开示例的詩音对话，在最底下用滚轮一下推到最顶上（键盘在侧栏上，⌘↑ 在那里是换到上一页），等两秒还在顶上（`signin-10-jumped-to-top.png`，`signin-jump.txt`）；第四个方法也用示例数据，照平时的用法从侧栏点进詩音的对话，别处都不点，按 ⌘F 接着打「作业」，字要在查找框里；Esc 关掉以后再打「好的」，字要在输入框里（字是打给整个 App 的，不是打给哪个框，键盘留在侧栏时就看得出两个框里都没有；`signin-11-find-typed.png`、`signin-12-composer-typed.png`，`signin-find-keys.txt`、`signin-find-keys-esc.txt`）。替身还演看板插件（`macos/ci/fake_kanban.py`：两块看板，`/workflow` 的移动规则、400 和 409 的拒绝、做完后把子卡升到就绪、`/events` 的 WebSocket，调了 `/dispatch` 会在记录里标出来）；`BoardTests` 登录后打开看板，看服务器的卡和每种「在等什么」，点开卡住的卡看评论和运行记录，留一条言（替身记下作者，要显示成「你」）并让它继续，把一张卡拖到「完成」（拖不动就用右键菜单），新建一张；再到詩音的对话里说「派一张卡」，替身照 Hermes 的样子演她调 `kanban_create`（开始时带参数，结束时结果里有卡的编号），几秒后课程做完，替身发看板的通知行，再让詩音接着说一句：对话里要先出现那张卡，再变成「完成」，通知行也显示成卡；在设置里断开再连上，对话从服务器重新读一遍（对话记录只留调用、不留结果），两张卡都还在、都是「完成」；然后换到另一块看板，再看今天页的「助手在做」列出两块看板上在做的卡；最后回到詩音的对话说「列一下这周的作业」，替身照 Hermes 的样子演一轮：三次工具调用（中间隔一会儿，跑着的时候能看到），再一段一段地回两张表：表格的格子要单独显示出来（不是带竖线的原文）；第二张比回复宽，横向滚一下，最右边那一列要露出来，前面那句话不跟着动；后面一行很长的代码也一样，滚到能看到行尾（横向滚的时候指针先在块上停一下再推；推不动就两个方向都试，同一处总推不动就换到块上别的地方，还不行就拖它自己的横向滚动条；用了几下、在哪儿推的、是不是拖了滚动条，写在 `board-positions.txt` 里：run 144 有两次在块中间推了十下一点没动，看起来是第一下没送到，方向就被认反了）；回到詩音的对话时最新一条在眼前；回复一路跟到底，完成时最后一段在眼前，三次调用折成一行，点开能看到每一条：点开、收起前后都量这一行和它下面那段回复的位置，这一行不动（差几个点以内），回复点开时往下移，移的正好是展开那几条的高度，收起时回到原处；第二下照着屏幕上这一行的位置点，要能收起（看到的和点到的是一处）；在对话最底下量一次，往上滚 120 点再量一次。最后说「等一会儿再说一句」：发出去的和回复都跟到最底下；往上滚 200 点，这时测试才让替身发来没人问的一条（`POST /ci/later`，`StandIn.swift` 发；替身发完才回答），它不能把画面拽走（看着的那段字位置不变），滚回最底下它在：不靠替身几秒后自己发、测试又正好在那几秒里往上翻好了。最后用查找跳到第 120 条（替身里它是一条好几屏长的回复，跳过去以后它占满可见区），再找一句哪儿都没有的话，点「上一个」往前读第二页、第三页：每页来时它都不动（读它最上面的一段，差 4 点以内）。滚轮测不到这种情形：页是滚到快到顶时要的，一页最早的那条长回复那时才刚排出来，页来时眼前是它的底和下面那几行。数字写在 `board-positions.txt` 里，失败时也写在失败信息里（`board-*.png`）。替身还演 profile 这一套（`macos/ci/fake_profiles.py`：`profiles.list`、`profiles.create`、`profiles.configure` 照 Hermes 的参数检查和拒绝方式，`ui_meta` 按版本号比对，贵的模型要确认；`/api/profiles`、SOUL、简介、`/api/mcp/*`、`/api/skills`、`/api/tools/toolsets`、`/api/config?profile=`；`mcp.servers.add` / `remove` / `set_api_key`、`profiles.get_asset` / `set_asset`、`/api/actions/{name}/status`、只演 `hermes profile purge-identity` 的 `cli.exec`；`/api/config` 照 Hermes 的 `_deep_merge` 合并 `mcp_servers`；删默认 profile 照 Hermes 返回 400；shion 插件只装在詩音和 Hermes 默认 profile 里（`LocalDataTests` 把后者换成总秘书）；几个专门的情形：归档（archive-ci）在 Bot Mode 里是隐藏的，通勤有头像图片，删 mail-ci 时身份记录没清完、第四次重试才成功，目录里的 slow-ci 在后台安装，通勤的 SOUL 在第二次读的时候已经被别的客户端改过；比 Hermes 严的一处：按 profile 的接口不带 `?profile=` 直接拒绝）；`BotsTests` 登录后看归档一开始就不显示，把总秘书换成课程（今天页回到示例数据，输入框、「跟…说」和菜单栏「前往」里那一项都改成课程）再换回詩音，看默认 profile 的设置页上删不了，在设置里把它设成不显示，从侧栏右键新建一个助手，改它的简介和 SOUL（替换前要确认），加一个 MCP 服务器并测试，关掉一个技能，重新打开这一页看这些都从服务器读回来了，删掉它，再看设置里列着「还在清理」、同名的新建被拦住，等 Shion 的重试成功后自动放行（`bots-*.png`）；`BotPageTests` 走一遍通勤的设置页：SOUL 被别处改过时先问再覆盖，换一个要确认的贵模型，选头像的颜色和形状，加一个 MCP 服务器、改网址加令牌、再改成 OAuth、关掉、删掉，从目录装一个马上装好的和一个后台装的（装完自己出现），开一个工具集，改「其他」里的四项，锁一个技能，最后重新打开这一页看都从服务器读回来了（`page-*.png`）。`QuickAskTests`（启动参数带 `-ShionHotKey YES`，测试模式平时不注册全局快捷键）登录前先按 ⌥Space 说「小窗：到家了吗？」，小窗里这句标着写下的时间和「等连上服务器后发出」；启动参数 `-ShionQuickWrittenAgo 7200`（只在测试模式下有用）让要排队的句子算作两小时前写的，所以登录后它自己发出去时带着「（…写的）」，替身原样回「收到：（…写的）小窗：到家了吗？」，再打开小窗，回复在里面，没有在等的了。然后把访达切到前台，在访达里按 ⌥Space（只有系统的全局快捷键做得到，「前往」菜单里那份只在 Shion 在前台时有用），看小窗出来、再按一次收起；再回到 Shion 按 ⌥Space（到不了小窗时改用「前往」菜单），说「小窗：明天几点出门？」，替身（`macos/ci/fake_quick.py`）照 Hermes 的样子一段一段地回「收到：…」，每 0.6 秒三个字，回了第一段就停下，等测试看到光标再说一声（`POST /ci/quick/finish`）才回完（没人说的话一分钟后自己回完）：小窗里要先看到光标、后看到整句，不靠测试在三秒里看到；接着说「小窗：帮我把实验报告交了」，替身让詩音在这一轮里先发一个批准（`approval.request`，照 `gateway/session_pending_controls.py` 的样子），在小窗里点「允许这一次」，再问一句没有选项的「交给哪位老师？」（`clarify.request`），输入框提示变成「回答詩音…」，打「中村老师」回车，詩音回「交给中村老师了。」；点「打开完整对话」，小窗收起，主窗口打开詩音的对话，这一问一答都在；再按 ⌥Space，小窗是空的，Esc 收起；最后在设置里「断开」，主窗口留着上次的数据（只读），在小窗里说「小窗：信号不好，晚点到」，它标着在等；再「连接」，不打开小窗，等詩音的对话里出现替身回的「收到：（…写的）小窗：信号不好，晚点到」（`quick-*.png`）。它的第二个测试由测试进程自己先独占注册 ⌥Space，扮演占着它的 App：「设置 → 快捷键」要显示「被别的 App 占用了」；测试进程放开后点「再试一次」，提示消失，⌥Space 叫得出小窗（`quick-taken*.png`）。替身还演停止、重试和服务器体检要的那几处（`macos/ci/fake_control.py`：每轮的事件帧带运行编号，快照和每轮结束的 `session.info` 带编号和 `revision`；`session.interrupt` 编号不对就 `stale_generation`；`session.mutate` 的 rewind 照 Hermes 查 `revision`、编号、空闲和目标行；「出个错看看」照会话 gateway 的样子出错：`status` 是 `error`，`text` 是 Hermes 对限流的说明、空一行再接它的固定说明，`error_surface` 说可以重试，没有 `error`，对话记录里以 `failed_turn` 那一行收尾；「查一下明天的天气」先调一次 `web_search` 再回答）；`ChatControlTests` 登录后先看服务器体检的每一项（shion 插件只在詩音和 Hermes 默认 profile 里，课程、通勤那几行是「没装或没启用」；替身的插件报没有时区数据，要显示「服务器缺时区数据」），再在詩音的对话里说「讲一个长故事」（替身每 0.3 秒回一句，回半分钟），按 ⌘. 停下，看已经出来的部分标着「已停止」，点「重试」：替身收回那一轮，同样的话这次很快回完；再说「出个错看看」，看出错说明是中文的「OpenRouter 那边请求太多了」和「等一会儿再试。」（不是「没有说明」，英文的固定说明也不出现），展开「详情」看到 Hermes 的原文，点「重试」不用确认，这次回了；再说「查一下明天的天气」，点「重试」先弹确认框，里面列着 `web_search`，点「取消」什么都没变，再点「重试」、确认，原话只剩一条，新的回答出来了；然后 ⌘F 找「第 12」（都在最近一页上），回车跳到更早的一条，再找「第 3 条」（在两页以前），按 ↑ 一页一页往前取，直到它出现：替身隔 1.5 秒才回更早的页，第二页来时眼前最上面那一行不动（差 4 点以内），第三页来时对话跳到命中，命中要在眼前，不只是排出来了（位置记在 `chatctl-positions.txt`）；最后在设置里断开，窗口还是服务器的数据：对话还在、侧栏写着「上次的数据」、待办的勾不能用，输入框照样能打（说的话排队）（`chatctl-*.png`；确认框在 XCUI 里是什么元素、按钮的 identifier 还在不在，记在 `chatctl-question.txt`）。替身还演图片和文件的那几个路由（`macos/ci/fake_media.py`，照 Hermes 的形状：`image-upload` 按文件头认格式，`file-upload` 把名字改成 ASCII，`file.attach` 只认它的几个键、会话要在这条连接上 resume 过，`prompt.submit` 的 `attachments` 照 Hermes 查，收下的图按 SHA-256 存、用户那一行照 Hermes 的样子存，`read-data-url`、`download` 带 `profile` 和 `session_id`）；`MediaTests` 登录后打开通勤的对话，粘贴一张 4096×3072、带位置和相机信息的照片发出去，替身回复它收到的是什么（要是 2048×1536 的 JPEG，没有位置也没有拍摄信息）；再粘贴三个文件（替身起来时在 `/tmp/shion-media-ci` 里做好：UI 测试的 runner 在沙盒里，写不了自己容器外面）：一个小的、一个 3 MB 的（先传到 Webapp）、一个替身第一次拒收的（标红，点一下再传），发出去，替身回复每个文件的名字和大小，你的消息里是文件卡片、不是 `@file:` 原文；发图那一轮下面没有「重试」，这一轮有：点了不用确认（没调过工具），替身收回这一轮，同样的字连同 `@file:` 引用再来一次，回复标着「（重试）」，你的消息还是文件卡片、只剩一条；接着回复替身的那条消息，不打字、只粘贴一个文件发出去：替身回的「你说：」里要有那段引用，你的气泡在文件上方显示被回复的那条；再说「截个图」，截图要出现在那条调用下面，替身在 Shion 取过一次后就把它删掉；再说「把课件发给我」，`MEDIA:` 交来的 PDF 和图、文字里写的 CSV 都要显示出来，网上的图要等着点，不出现 `MEDIA:` 原文，点 PDF 存到「下载」，再点「显示图片」：这时 Shion 才自己去网上取（W3C 的标志，旧地址在 w3.org 里转一次）；最后断开再连上，从服务器重新读一遍：照片和截图都还在（截图服务器上已经没有了），也不出现 `[Image attached at:`（`media-*.png`）。替身还演断线（`macos/ci/fake_reconnect.py`，照 `hermes-agent` 的 b3746e35：每个会话的帧带 `seq` 和 `replay_epoch`，留最近 512 帧；`session.events.since` 回之后的帧或 `snapshot_required`，问过以后的 `session.resume` 先补上中间新发的帧；快照带 `replay_epoch`、`last_sequence`、`pending` 和还在等的 `prompts`；`prompt.submit` 只收接上了这个会话的连接的，同一个 `submission_id` 只收一次，同样的话再发回原来的回执，换了话是 `admission_conflict`，收下时发 `session.info` 列出排着的；一轮在跑时再发的排在它后面；「断线：…」开头的话在约定的时刻掐断连接、不发关闭帧，之后所有请求都是 Cloudflare 的 502，直到测试告诉替身恢复隧道（`POST /ci/tunnel/up`，只有替身有，测试里由 `StandIn.swift` 发）：测试看完断着时要看的、截好图才说，替身等这段剧本断着时要做的做完（断着时就回完的回复、留着要补的帧）才恢复，Shion 到下一次试时连上，所以哪一步都不靠测试打字快慢、也不靠 Shion 哪一秒再试；没人说的话 60 秒后自己恢复，只是免得一步失败拖垮后面的；「断线：跟不上」不掐断，照 Hermes 的样子结束这个连接的订阅、发一条 `session.replay_gap`，这一轮接着跑；带图和文件的「断线：图和文件」在收下之前掐断，同时把暂存的图清掉；「断线：接不上」掐断以后，这个对话的每次 `session.resume` 都照 Hermes 存储忙时的样子拒掉（5001 `storage_unavailable`，连接留着），直到测试说可以（`POST /ci/attach/go`，`StandIn.attach`），没人说的话 60 秒后自己不再拒）；`ReconnectTests`（启动参数 `-ShionQuickWrittenAgo 7200`）登录后先回掉课程的批准，然后在詩音的对话里：说「断线：讲到一半」，回到第 5 段连接断了，侧栏写「重新连接中…」和下次试的时间，这时说的两句排在对话下面、写着什么时候写的，看完这些才让隧道恢复；回复停在第 20 段等 Shion 回来问错过了什么（像一段比断线还长的回复），连上后后面的段接着流进同一个气泡（第 1 到第 80 段都在一个气泡里），排着的两句按顺序发出、带着「（…写的）」，回答也按顺序；「断线：讲完了」在隧道断着时就回完了，连上后是整段，没有还在回复的气泡；「断线：回传」回了一句就断了，断着时 Hermes 自己起了四轮，都照真 gateway 抓到的样子：一条看板回传和一条课程发来的消息（开始帧是空的，只有记录里那一行写着是什么；回传的卡片已经不在任何看板上，消息下面带着 `Reply needed: 一句话`），再是课程对詩音一条消息的回话两次、字句相同、相隔一小时（后台进程结束的那种结果，连上后补播的开始帧和对话记录里的行各说一遍；第一次之后詩音什么都没说）；对话里看板回传只有一张，写着那张卡的标题和「做完了：发票都归好了（CI）。」，不出现 `[kanban]` 和写给模型的那段话，课程的消息一张、写着「要回：一句话」，两次回话各有一张、标着「课程（CI） 发来的消息」，不出现那条命令和 `[SILENT]`，每张都排在它引出的回复前面，看板那张在断线前回的那句「好（CI）。」下面；「断线：很多」回了一句就断了，断着时 Hermes 自己起了九轮：课程发来的八条消息（开始帧都是空的，只有记录行；第四条那一轮回话前先调了 51 次工具，这些行只在对话记录里，没有行号），再是合并成一轮的两条后台结果（课程的一条回话和一条失败的命令）；连上后回话和失败的命令各有一张卡、不显示成一句计数，用查找栏数整个对话里的消息卡是八张（最近 12 行只够后四条，再往上一页全是那一轮的工具调用，前四条是越过这一页往上读出来的）；「断线：还没回执」收下了、回执没回来就断了，断着时写「等连上后确认」，连上后核对出收到了，照常显示，只出现一次；「断线：没收到」还没收下就断了，连上后写「没发出去」，点「重发」（同一个 `submission_id`）发出去、回了，只出现一次；「断线：等你批准」在等批准时断了，连上后「待你处理」里还有它，点「允许这一次」，这一轮在同一个气泡里回完；「断线：说很多」断着时回了 600 段，比会话留的帧多，补不上，改读最新一页，整段只出现一次，没有还在回复的气泡；「断线：跟不上」回到第 5 节时订阅被结束、连接没断，侧栏一直没写「重新连接中…」，第 1 到第 40 节在同一个气泡里；最后粘贴一张图和一个文件说「断线：图和文件」，收下之前断了，连上后写「没发出去」，点「重发」：同一个 `submission_id`、同样的引用被拒（图已经清掉），从这台 Mac 上的那份重传图、用新的 id 发出去，回复里图和文件都在，这条消息只出现一次（`reconnect-*.png`）。设置窗口平时记得上次停在哪个标签；截图和测试模式下总是从「服务器」开始，也不记，截图测试看完「快捷键」重新启动一次，确认还是从「服务器」开始（`BotsTests` 停在「助手」，排在它后面的 `BotPageTests` 和 `QuickAskTests` 登录时也要从「服务器」开始）。一个测试十分钟还没跑完（App 不再回应），就先发 ^C 停掉它（xcodebuild 照样写下结果），算失败，后面的照跑；`ChatControlTests` 后半段每一步在替身的记录里留一个 `/ci/mark/…`，这样即使被停掉也知道停在哪一步；`BoardTests` 重新读对话后两张卡没出现时，把对话区排出来的字、眼前的几行和滚动条读三次，再滚一下读一次，写在 `board-reread.txt` 里。替身认剧本时看的是用户那句话的 NFC 形式（`macos/ci/fake_words.py`，在 `fake_hermes.py` 收到 `prompt.submit` 的地方统一做）：XCUI 打字有时会把一个字打成长得一样的兼容汉字（run 129 里「跟不上」的「不」成了 U+F967），按原文比就认不出剧本；admission 和对话记录里存的还是原文。每个测试各用一个新起的替身，课程的批准、它加的待办这类只发一次的事不会被前一个测试用掉，`BotsTests`、`BotPageTests` 改过的 profile 也不会留给别的测试。替身的请求记录（`fake_hermes-SignInTests.log`、`fake_hermes-BoardTests.log`、`fake_hermes-BotsTests.log`、`fake_hermes-BotPageTests.log`、`fake_hermes-QuickAskTests.log`、`fake_hermes-ChatControlTests.log`、`fake_hermes-MediaTests.log`、`fake_hermes-LocalDataTests.log`、`fake_hermes-ReconnectTests.log`，密钥只记名字）也在附件里。用 OAuth 登录 MCP 服务器要开浏览器，CI 上没测。这一步失败只报警告，截图和安装包照样出。最后两步是同一句话说两遍：「断线：引导两遍」在一轮进行中用引导连说两遍「改到五点（CI）」，替身只存下第一条、在第二条时断开，断着时两条都写「不确定有没有送到」，连上后只确认一条，之后再重连两次也还是一条；「断线：又说一遍」回完后断开、事件流换了 epoch 要读最新一页，替身把这次接上按住，这中间把这句话再说一遍、请求丢了：两个气泡都在，先写「等连上后确认」，再写「没发出去」，点「重发」后得到回答。最后一步「断线：接不上」回到第 5 拍时断开，连上后替身不让这个对话接上：补回来的帧说这一轮还在跑，对话里那个回复留着，输入框上面写「没能重新接上这个对话」和 `storage_unavailable`、有「再试一次」，不显示在回复；这一行、「再试一次」和输入框都在窗口显示的范围里，窗口、侧栏第一行和顶上的标签页还在这一步之前的位置（量到的都记在 `reconnect-19-frames.txt`）；等自己试的四次都被拒、这一行不再写下次什么时候试，测试才让替身放行，点一次「再试一次」就接上（`reconnect-20-tried-again.txt`），回复在同一个气泡里到第 30 拍，再说一句得到回答。
- **这台 Mac 的数据的端到端测试**：runner 上给不了日历和辅助功能权限，也没有 Apple 智能，所以 `LocalDataTests` 用启动参数 `-ShionLocalScript YES`（只在截图模式下认）换上一组跟着真时钟走的假数据（`macos/Shion/Local/LocalFixtures.swift`）：几个日历（一个没勾）、一段正在进行的专注时段、前台一个看了 7 分钟的猫视频、今天早些时候的使用记录（里面有一个被排除的应用），判断用固定的规则代替本机模型。替身里的插件照插件自己的检查收 `focus.report`、`usage.upload` 和 `settings.get` / `settings.update`（多一个字段、类型不对、时间不对都拒绝；`session_id` 照 Hermes 先查是不是这个 profile 的会话），报告不是在 `chief_profile` 里发的回 `wrong_profile`，总秘书的 Bot Chat 还没有过一轮对话（插件还不知道它的路由键）回 `no_session_key`，否则照 `inject_message` 的样子把那句话放进总秘书的 Bot Chat、让它回一句；收到上传后让「回顾」按上传的段写今天的生活日报里的屏幕时间。测试先看今天页没连服务器时就是这台 Mac 的日历（截图模式下窗口里是示例数据，不是「先连上」那一页；没勾的那个日历里的不出现），登录后还是；再打开詩音的对话，等她回「已经过了 7 分钟」那句、再等前台换成报告后她回「回来了就好」，两次都不能看到「［专注检查］」那行；菜单栏里是「在做「…」」；日报里有「Xcode 40 分钟」，没有被排除的应用；设置里写着最近一次告诉了詩音什么、上次什么时候发给回顾；在设置里取消勾选那个专注日历，今天页上它的日程就没了；最后在「设置 → 助手」里把总秘书换成 Hermes 默认 profile（替身里它也装着插件），「这台 Mac」的专注检查那一节写着插件叫醒 Hermes（CI）（替身的 `chief_profile` 跟着改了），再换回詩音，那里又写詩音（`local-*.png`）。替身和插件收不收得一样，改了任何一边后在 Linux 上跑 `python3 macos/ci/check_fake_shion.py`，它把同一批调用分别交给插件（`hermes-plugin/shion`，不装 Hermes，詩音和通勤两个 profile 共用一份数据）和替身，比较两边接受还是拒绝、拒绝的理由、叫没叫醒（没叫醒的理由）和设置（CI 不跑它）。
- **写给助手和技能审核**：`ComposeTests` 用自己新起的替身（`macos/ci/fake_control.py` 演 `session.steer` / `session.redirect` 和「先给别的助手发消息再出错」的一轮，`macos/ci/fake_skills.py` 演插件的 `reviews.*`、`[SILENT]` 的一轮、`review.summary` 和审核用的单独会话，并断言这个会话没有标题、没有工具）。依次检查：草稿换页还在、Shift+Enter 换行不发送；回完的一轮没有重试；从消息上的按钮回复，发出去的是 Hermes 的回复写法、显示成引用；长回复进行中用「引导」发的话进了这一轮、标了出来、没有另起一轮；再起一段长回复，说一句替身不接的话（它照「这一轮没接」回 `rejected`、不带 `delivered`）：消息下面写的是「这一轮没有接下这句话，也可能已经看到了」而不是「没发出去」，没有自己重发，点「再发一次」才作为新的一句发出去；这时去今天页的输入框说一句，输入框虽然还选着「引导」，这句话也没有进正在讲的那一轮；停掉长回复后，替身像 Hermes 一样把排在后面的两句按顺序各回一轮（替身的普通回声在 `fake_control.py` 的一轮进行中会排在它后面）；发给别的助手的消息是卡片，随后出错的一轮重试前先问、问里点名这条消息；静默的一轮没有气泡，自动沉淀和技能卡出现，在「待你处理」里批准；第二次变更在单独的会话里拿到助手的意见并拒绝，Bot Chat 里没有这段讨论。
- **审核会话里出岔子**：还是 `ComposeTests`，拒绝之后不关那个会话，接着说六句话，每句由替身演一种情况（`fake_skills.py`；「断线：」开头的两句和 Bot Chat 里一样由 `fake_reconnect.py` 演）。「排队满了（CI）」四秒后被拒（`queue_full`）：这期间在输入框里打下一句，被拒后那句话还在原处、写着「没发出去」和原因，输入框里是新打的那句，点「重发」后有了回答（替身只认同一个提交编号，换了编号就一直拒绝）。「审核出错（CI）」这一轮以出错结束：错误写在输入框上面，Hermes 那段英文的失败说明不当成回复显示，点「再试一次」后替身收到 rewind、同一句话有了「（重试）」的回答，错误消失。「订阅断了（CI）」的回复分八段，第三段时替身只结束这个会话在这条连接上的订阅（`session.replay_gap`，连接不断）：回复照样完整，之后还能接着发。「断线：没收到」在收下之前断线：断着时写「等连上后确认」，连上后变成「没发出去」，点「重发」有回答（换了编号的话替身会再断一次线）。「断线：还没回执」收下了、回执丢了、断线期间答完：连上后这句话不再有任何提示，也没有「重发」，回答在。截图是 `compose-10` 到 `compose-15`。只依赖 Foundation 的那部分（哪句话算服务器收到了：`SkillReviewDelivery`）可以离开 Mac 检查。这之前，第一次打开这张卡的讨论时替身先拒绝建会话一次（`storage_unavailable`）：输入框打了字也发不出去、字还在，点「再试一次」建好后那句话发出并得到回答。六句里新增的一句是「快照迟到（CI）」：每次读会话，替身都先发新的帧再回答，前三次被回复的一段赶上，第四次被这一轮的结束赶上；回复完整留下，不停在「正在回答」，重连再读之后也还在。
- **看板要你做的事**：`WorkTests` 也用自己新起的替身。替身里的卡带着 Hermes 卡片的全部字段，`latest_summary` 和 `current_run_started_at` 照 Hermes 从运行记录算；卡住照 `block_task` 走（`blocked` 事件带原因、类型和次数；同一种阻塞在解除后又来一次就是防循环，送去待整理、记 `block_loop_detected`），卡住的卡 `PATCH` 成 ready 就解除阻塞。有三张卡停着：等验证码（needs_input）、没有账号（capability）、网站超时（transient，通勤的）；课程今天在两块看板上都跑过卡，昨天也跑过一张；还有两张归档的：今天做完后归档的，和昨天的。`/board` 认 `include_archived`。之后的事按剧本走：第一次让「下载成绩单」继续，它又停在验证码上（过期了）；第二次，它交上来等检查，同时「整理第8回录音」做完、詩音的一张卡停下来问你；标题里带「（CI 通知）」的新卡几秒后做完。App 以 `-ShionNotificationLog <文件>` 启动时（只在截图模式下认）不发系统通知，把每条写进这个文件（连同能不能在通知里回复），测试读它；测试不能在真的通知里打字，就发一条分布式通知（`dev.shion.test.answer`，内容是哪条通知、回复的字；测试的 runner 写的文件 App 不一定看得到），App 只在截图模式、带着通知日志时收，当作你在那条通知里打字发送来处理，再在日志里记一行它收到了。`WorkTests` 登录后在「待你处理」看到两张要你回答的卡和另一块看板上的一张，看不到网站超时的那张，这时一条通知也没有；回复验证码并让它继续，卡离开，几秒后写着「又卡在同一处」回来，「待你处理」开着，所以不通知；再回复一次，到课程的工作记录：两块看板上今天跑过的卡都在，今天做完后归档的那张也在、标着「已归档」，昨天的（归档的那张也是）、通勤的、没跑过的都不在，交接摘要和出错的那次也在；等检查、做完、詩音那张卡的三条通知到了，写着卡和看板，只有詩音那条能回复；在这条通知里回复（经上面的分布式通知，等 App 在日志里记下收到了），点开另一块看板上的那张，详情里有它的评论和看板；再点开归档的那张，详情照样打开；到看板页，归档的卡不在，詩音那张回到了排队、详情里有你刚才的回复，署名是「你」；新建一张卡，它做完时看板开着，不通知；在设置里关掉「卡片做完时通知」，再建一张，离开看板等它做完，也不通知；最后「待你处理」里没有詩音那张了，点另一块看板上那张卡的「打开卡片」，看板切过去、详情打开（`work-*.png`，替身的记录是 `fake_hermes-WorkTests.log`）。截图另外有课程的工作记录（`-ShionTab work`，浅色和深色，各点开一张卡）。真去点系统通知在 CI 上做不到：通知里带的卡和看板测到了，点了以后打开卡片的那个函数和「打开卡片」是同一个，也测到了。
- **点通知、快捷指令**：`ExtrasTests` 也用自己新起的替身（这几轮在 `macos/ci/fake_extras.py`：詩音过几秒回一大段，`message.complete` 照 Hermes 带 `persisted_turn`；她问一个问题、要一个批准，没回答前每次 `session.resume` 的 `prompts` 都带着；课程经插件写一份今天的生活日报，昨天那份还能用 `reports.get` 读到；还有一句回得比快捷指令等的慢）。快捷指令 CI 上叫不动（系统那边要真机），所以测试替系统调 `perform()`：发一条分布式通知（`dev.shion.test.intent`），App 在截图模式下收到就调那个动作，把它说的话写进 `-ShionIntentResults` 的文件。先在没登录时调三个动作，都不发、都写明「还没登录」，「打开待你处理」照样打开；登录后「跟总秘书说」带回詩音的回复、这条回复没有通知，慢的那句回「已发出」、之后才有通知，「今天的待办」是插件里的，「打开助手」找到通勤，再看没登录时那句没到詩音的对话里；最后读 App 里的 App Intents 元数据（`Metadata.appintents`），四个动作和说法都在。点通知照 `WorkTests` 的办法（通知写进文件，测试发 `dev.shion.test.answer`，动作是 `click`）：在詩音的对话里要一大段，切到今天，通知来了带着 `row` 和流进来的那一行；点它，对话打开在那条回复的开头（第 1 段在视野里，第 30 段不在）；问题和批准各点一次，选中的就是点的那一件；再让詩音装 ffmpeg（`fake_secrets.py` 同时要 sudo 密码和一个密钥），点要密码的那条通知（它没有按钮），「待你处理」里选中的是那一张密码卡，截图后两张都拒绝（不输入任何密码）；新日报的通知打开它。再用 `-ShionLaunchNotification <userInfo>` 启动四次（一次一个测试），当作是被点通知启动的：App 等主窗口出来再接这次点击，接了在通知日志里记一行，测试先看它接了、页面对了，再登录看它们落到哪：那条长回复（这回对话是从服务器重新读的，只能按 `row_id` 找到；落下以后更早的一页才进来，截图以后再看一次它还在顶上），还在等的问题，昨天的生活日报（读出来的，不是今天那份），下面是那一天的屏幕时间（替身在课程写日报时放进了昨天的使用记录：Notion 一个半小时，Safari 一小时、其中一段和自己重叠，LINE 20 分，Spotify 15 分，Steam 跨过东京午夜、算前 10 分；`usage.day` 照插件算出 3 小时 15 分，七类和前五个应用的时长都要对得上），另一块看板上的卡（看板换过去、详情打开）。`ExtrasScreenshotTests` 截「设置 → 这台 Mac」里的这两个开关（浅色、深色，再加一张要在系统设置里允许、菜单栏开关开着的）和后面的点通知、快捷指令两节，和只留在菜单栏：关掉窗口后整个屏幕（Dock 里没有 Shion、菜单栏图标旁边有件数）、面板里的「打开 Shion」、点了以后窗口和 Dock 图标回来；Dock 图标在不在问的是系统（Shion 的 activation policy），不去读 Dock，还有日报下面的屏幕时间（示例的那一天，浅色、深色），和断线重连时「待你处理」里那张卡变灰的样子：示例数据加 `-ShionReadOnlyDemo YES`（只读，只在截图模式下认）和 `-ShionReconnectDemo YES`（侧栏写着重新连接中），卡的回复框、「回复」和「让它继续」是灰的（上次的数据不存卡片的提问，只能连着时回答，所以变灰的是断线重连的时候）（`extras-*`、`settings-start-*`、`settings-ways-in-light`、`menubar-only-*`、`reports-usage-*`、`readonly-confirm-*`）。卡片详情里的留言框只在看板连着时才有，示例数据里没有，所以那一张在端到端测试里截：`ExtrasTests` 最后从「待你处理」打开课程那张等验证码的卡，再借快捷指令的钩子让詩音说「断线：讲到一半」（替身在第 5 段时断开，隧道一直断着，测试截完图才让它恢复，`StandIn.tunnelUp`），侧栏写着重新连接中时，看板上它的留言框和「让它继续」是灰的，「待你处理」里它的回复框、「回复」「让它继续」也是灰的，连回来后又能用（`extras-18-card-down`、`extras-19-confirm-down`）。CI 上验不了、只能在真机上看的：快捷指令 App 和聚焦搜索里列出这四个动作、Siri 认中文说法、被动作启动时窗口和 Dock 怎么出现；真的点系统通知（含 App 没开着时）；登录项真的登记上、系统要你批准、在系统设置里批准；收起 Dock 图标后从启动台再打开 Shion。
- **截图模式**：日期固定在 2026 年 11 月 9 日（周一）10:52，外观对整个 App 生效（菜单栏面板也跟着变），呼吸点不动。这台 Mac 的数据也换成假的、停在那一刻：几个日历（演示的那一周）、10:45 起前台一直是猫视频（所以专注检查是「7 分钟没在做」）、今天的使用记录；不申请任何权限，不读真的日历和窗口，不存文件，也不往服务器发。`-ShionCalendarAccess none` 演还没允许读取日历的样子。`LocalScreenshotTests` 截设置里的日历、专注检查、应用使用记录三节，点开菜单栏里的专注检查，再截没允许读取日历时的日程页和设置（`settings-calendars-*`、`settings-focus-*`、`settings-usage-*`、`menubar-focus-*`、`calendar-noaccess-light`）。动画停下来 App 才算空闲，XCTest 不用干等，一次运行从 4.3 分钟降到 2.3 分钟。
- **runner 的屏幕**：1024×768、1 倍，所以窗口截出来是 1024×674，比默认窗口小，正好看窄窗口下的布局。
- **密码和密钥**：`SecretsTests` 也用自己新起的替身（`macos/ci/fake_secrets.py`：照 Hermes 发 `sudo`、`secret` 请求，收响应，发 `request.cancel`，resume 时给 `open_requests`）。登录后先在「待你处理」里允许课程的那个批准，课程的对话里要留下「已允许这一次」；再打开通勤的对话说「装 ffmpeg（CI）」，替身照并行的工具调用同时要 sudo 密码和 `NOTION_API_KEY`：两张卡都在对话里、都有倒计时，「待你处理」里也有；在「待你处理」里填密码、提交（密码框的值只有圆点），替身核对是不是 SecretsTests 填的那个，记录里只写来了一个值、对不对，不写值也不写长度，那条命令随后成功；回到对话，密钥那张卡还在等，点「拒绝」；再说「会过期（CI）」，这次替身只等 8 秒（Hermes 是 120 秒），卡片变成「已过期」、输入框收起；最后说「断线（CI）」，替身要了 sudo 密码就像断网那样断开连接（不发关闭帧），隧道一直断着（每个请求都是 502）：卡片留着、写「连接中…」、先不能填；截好图测试才让替身恢复隧道，Shion 自动重连，补上错过的帧、resume 的 `open_requests` 里还有它，才在新连接上填好提交，那条命令成功；重连后「已提交」和课程那条「已允许这一次」都还在（`secrets-*.png`）。`QuickAskTests` 答完小窗里的批准和提问后，小窗里和詩音的对话里要留下「已允许这一次」「你回答：中村老师」。接着一步在替身的记录、App 的偏好设置和 Application Support 里找这个密码，找到了，或者同一个请求答了两次，这次运行就失败。截图另有 `SecretScreenshotTests`：示例数据里课程要 sudo 密码（一张已过期、一张在等）和 `NOTION_API_KEY`，截课程的对话（答过的批准和提问各一行、过期的密码一行、两张在等的卡）、「待你处理」和今天，⌥Space 小窗里答过的那一问留下的一行，还有设置里讲这件事的那一节，浅色、深色（`secrets-chat-*`、`secrets-confirm-*`、`secrets-today-*`、`secrets-quick-*`、`settings-secrets-*`）；替身的记录是 `fake_hermes-SecretsTests.log`。
- **看哪里**：截图和替身日志合成这次运行的 `shots` 附件（保留 14 天），文件名是「页面-外观.png」；各 job 自己的那份（`shots-screenshots`、`shots-e2e-1` 到 `-3`）留 3 天，`shots` 那一步出问题时还能从这里下。安装包是 `Shion-macOS-<运行号>` 附件里的 `Shion.dmg`。编译失败时，那个 job 的最后一步会列出错误；编译警告（xcodebuild 的警告不会自己变成注解）由「Compiler warnings」一步列成这次运行的注解，所以一次运行没有注解，就是没有警告。端到端测试失败时，那一步从结果包里打出失败的断言和消息（`-quiet` 不打）；XCTest 在找不到元素时存的界面层级（「App UI hierarchy」）也在附件里，同名的按新旧编号，不互相覆盖。
- **省时间**：macOS runner 的分钟数有限，攒够一批改动再推；只改 README 这类文件不会触发。分开跑省的是等的时间，不是分钟数：以前一台 runner 顺着跑完要 47 分钟（run 185），现在全量一次从开始到结束 16 分钟上下（run 192 是 15 分 41 秒：编译 2 分钟，然后截图 12 分 47 秒，三份端到端 12 分 50 秒、13 分 18 秒、13 分 8 秒，打包 4 分 44 秒和它们同时跑），各 job 加起来约 59 分钟（每个 job 都要取代码、取产物，同时跑的 runner 也慢一些）。一次全量运行同时要五台 macOS runner（截图、三份端到端、打包）；run 189 里有一份端到端排了 3 分 45 秒才开始，那时另一个分支上的 run 186 也在跑、占着一台，等打包那台空出来才轮到它，那次用了 17 分 33 秒。各组的时间每次差不少（BotPageTests 从 80 秒到 330 秒都有过，一份里的第一组也比后面的慢），所以三份只能大致一样长。编译缓存省的不多：测试版编译冷的 91 秒，源码没变时 45 到 82 秒；App 的源码一改，App 模块整个重编，没有省（run 190 是 122 秒），省下的只有两个包。发布版不走缓存，每次四分钟出头（235 到 262 秒）。

## 路线图

1. **对齐界面**（现在）：用原型把信息结构和关键流程定下来。
2. **协议探路**：一个命令行小程序，经 Cloudflare Tunnel 用 Access service token 连上 VPS，跑通握手、`profiles.list`、打开 Bot Chat、流式消息、回答审批，同时验证风险 1–4，再走一遍风险 5 的探路（画面 WebSocket 的 RFB 握手）。
3. **SwiftUI 骨架**（已开始，`macos/`）：主窗口和各页面先用示例数据做出来；接着是可回复的系统通知、菜单栏、全局快捷键；云桌面先做缩略图和接管、交还，再做实时画面。
4. **`shion` 插件和助手团队**：插件提供待办、今天汇总、日报、应用记录；把詩音和各助手的 profile、SOUL、例行任务做成一套可一键部署的模板。
5. **今天 / 待办 / 日程 / 日报** 接真实数据，加上 Mac 应用使用记录。
6. 以后：接入这台 Mac 让助手在本机做事；全天录音。
