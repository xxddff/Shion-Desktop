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
- 对话里，助手用 `kanban_create` 交出去的每张卡显示成一个会实时更新状态的卡片：调用的结果里有卡的编号，就按编号找；重新读对话时（对话记录只留调用、不留结果）按标题和交给谁找。卡片有动静时，Hermes 会以你的名义往对话里发一条「✔ [看板] @助手 Kanban <编号> …」再让助手接着说，这一行也显示成那张卡，不显示成你说的话；看板上已经没有的卡，才按原文显示。卡在别的看板上也找得到（别的看板每分钟读一次）；
- 今天页的「助手在做」：所有看板上在做的卡和等你的卡（等你的在前），没连上时是示例数据；
- 「看板」页（已接上服务器，没连上时是示例数据）把 Hermes 的八列归成四列：排队（待整理、待办、定时、就绪）、在做、等你（卡住、待检查）、完成。每张卡写着交给谁、做到哪、在等什么，有子卡的显示进度（2/3），有评论的显示条数；
- 拖卡片换列，能拖到哪里以 `/workflow` 的 `manual` 为准（拖到「排队」是就绪，前面的卡没做完就退一步到待办；「在做」只能由派发器放进去，不能拖进）；右键菜单里的「移到」可以选到具体的列，也能归档。服务器不让移的（409），卡片退回原处，弹出它为什么不让，前面的卡没做完会写出是哪几张；
- 工具栏的「＋」新建卡片：标题、内容、交给哪个助手；交给了助手又没有前置卡，就直接是就绪；
- 点开卡片在右边看详情：内容、在等什么或交付了什么、评论（可以留言，浏览器登录时署你的登录名，助手读评论时看到的就是这个名字；会话令牌登录没有名字，记作 `dashboard`；卡住的卡留言后点「让它继续」，回到就绪）、前后置的卡（点了跳过去）、每次运行的起止和结果，最底下小字是编号、看板和 profile；
- 服务器上有几块看板时，工具栏里能切换；
- 每个助手页顶部有标签：Bot Chat，加上它今天跑过的每张卡的工作记录（还没做）；
- 卡在要人做的步骤时（`kanban_block`，类型 `needs_input`，比如两步验证），会出现在「等你确认」。你在云桌面上处理完、交还后，Shion 自动留评论并解除阻塞，派发器重新运行这张卡（还没做）。

看板接口（`/api/plugins/kanban`，认证和 `/api/*` 一样：会话令牌放 `X-Hermes-Session-Token`，浏览器登录的凭证是 bearer，再加 Access 的两个头；每个路由都可以带 `?board=<slug>`，不带是服务器当前的看板）。以下按 Hermes 代码（`plugins/kanban/dashboard/plugin_api.py`、`hermes_cli/kanban_workflow.py`、`hermes_cli/kanban_db.py`）核对过，它的文档有几处和代码不符：

| 接口 | Shion 用来 |
| --- | --- |
| `GET /workflow` | 列（`key`、`label`、`drag_target`）和人能做的移动 `manual{src:[dst…]}`；归档总是可以 |
| `GET /boards` | 每块看板的 `counts{status:n}` 和 `is_current`；所有看板的 `running` 加起来，就是 `max_in_progress` 数的那个数 |
| `GET /board` | 卡片（按列）、`assignees`、`latest_event_id`（事件流从这里接着读）、服务器的 `now` |
| `GET /assignees` | 每个助手在这块看板上各状态的数量，拿 `running` 和每个助手的上限比 |
| `GET /tasks/{id}` | 详情：完整的 `latest_summary`、评论、`events`、`links` 和 `link_tasks`（前后置卡的标题和状态）、`runs`。**阻塞的原因只在 `blocked` 事件的 `payload.reason` 里**，卡片字段只有 `block_kind`（dependency、needs_input、capability、transient）。所以卡住的卡、在等前置卡的卡，Shion 都会读一次详情 |
| `POST /tasks` | 新建：`title`、`body`、`assignee`（还可以 `parents`、`priority`） |
| `PATCH /tasks/{id}` | 改状态：不能直接设成 `running`（400）；`manual` 里没有的、前置卡没做完的，返回 409，并写出卡在哪些前置卡上 |
| `POST /tasks/{id}/comments` | 留言（`author` 随便写；不带时记作 `dashboard`。Shion 带上登录名，显示时登录名和 `dashboard` 都是「你」）。新建卡片的 `created_by` 由服务器定死成 `dashboard`，改不了 |
| `WS /events?board=&since=&token=` | 实时更新。升级请求不看 `Authorization`，凭证放在 `?token=`，Access 的头照带；帧是 `{"events":[…],"cursor":N}`；凭证不对以 1008 关闭。不带 `since` 是从现在开始，`since=0` 会重放全部历史，所以带上 `/board` 给的 `latest_event_id` |

Shion 收到事件就（合并 0.3 秒内的）重读一遍看板和有变化的卡的详情；断了从上次的 cursor 接着连，所以不会漏。别的看板上的卡不会出现在这块看板的事件流里，算整台服务器的上限要用 `/boards`，Shion 每分钟重读一次。

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
| 邮件 | 邮件 | himalaya（IMAP/SMTP，大多数邮箱都能接）+ email-inbox-triage，例行整理收件箱 | 发出前到「等你确认」；需要处理的变成待办 |
| 日程 | 詩音 | iCloud 日历（CalDAV，应用专用密码） | 日程（周视图）、今天的时间线、菜单栏的「下一件」：Mac 用 EventKit 读这台 Mac 上勾选的日历，不经过服务器（见「这台 Mac 的日历和应用使用记录」） |
| 待办 | 詩音 | `shion` 插件存储，执行日期与截止日期分开；是否和 Apple 提醒事项同步见下面的风险 | 待办、菜单栏、今天 |
| 通勤路线、延误 | 通勤 | 已有的交通 MCP；按日程生成出门提醒 | 今天的通勤卡片、通知、菜单栏 |
| 课后整理 | 课程 | Notion MCP 读录音转写；按课表在课后触发 | 新待办先标"待确认日期"，在等你确认里定日期 |
| 课程提醒 | 课程 | 按日历里的课表生成例行任务；以后从 Moodle（iCal 订阅、Web Service）和教务系统补充作业截止 | 通知、菜单栏的"下一件" |
| 每日安排与催促 | 詩音 | 早报、12/18/21 点催促、睡前排明天；到了计划时间你却没在做，由 Mac 的专注检查叫醒她 | 今天页顶部的一段话、通知、菜单栏里的专注检查 |
| 应用记录与回顾 | 回顾 | 插件接收记录（`usage.upload`），22:30 写日报 | Mac 端采集，每 10 分钟上传；日报里的屏幕时间 |
| 事实核查 | 资讯 | 网络搜索与网页读取 | 对话；新闻日报里的核查标注 |
| 新闻 / 学习 / 工作 / 生活日报 | 资讯、回顾 | 例行任务生成 | 日报页 |
| 要登录、两步验证、验证码的网站（学校统一认证、Moodle、教务） | 课程等 | 助手在自己的云桌面上用浏览器操作；登录状态保留在它的浏览器里 | 「等你确认」里出现「去接管」，在云桌面页接管、登录、交还 |
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

**日历。** Shion 用 EventKit 读这台 Mac 上「日历」App 里的日历（iCloud、Google 等账户都在那里），和服务器无关，连没连上都一样。
- 设置里按账户列出所有日历，每个有颜色、名字和勾选框；只读勾上的那些。第一次列出时默认勾上除了生日和订阅日历（节假日）以外的。勾选按日历的标识（`calendarIdentifier`）存下来，换了名字也不丢；每个日历还能选算作「课」「专注时段」还是「日程」（先按名字猜：课表、時間割、class 算课，专注、focus 算专注时段），专注检查只拿前两种当计划。
- 用在今天页的时间线、日程页的周视图和菜单栏的「下一件」。日程的颜色是日历自己的颜色；全天的日程在周视图顶上一行、在今天页写「全天」；同一时间的几项在周视图里并排；跨过午夜的在两天里各画一段；时间轴默认 8 点到 22 点，有更早或更晚的日程时跟着放宽。
- 读的是一周前到两周后。日历一有变化（`EKEventStoreChanged`，同步时会连着来好几个，等 0.5 秒再读）马上重读；新的一天、在系统设置里给了或收回权限，30 秒内也会重读。
- 没允许读取时是示例数据，日程页的工具栏和「设置 → 这台 Mac」里各有一个「读取这台 Mac 的日历」的入口：第一次弹出系统的询问，拒绝过的话打开系统设置。截图模式不申请权限，用一组假的日历（`macos/Shion/Local/LocalFixtures.swift`）。

**应用使用记录。** 记下哪个应用在前台、从几点到几点，不需要任何权限（`NSWorkspace`），默认开着。
- 每 5 秒看一次，切换应用时马上看；在本机压成一段一段的：一个应用在前台的一段时间是一段，不记窗口标题。在一个应用里不到 5 秒的（切换时路过）不算；锁屏、屏幕睡眠、键鼠 5 分钟没动的时间不算（那一段截在最后一次键鼠操作）；Mac 睡着时没看到的时间不算；一段最长 12 小时。
- 存在这台 Mac 上（`~/Library/Application Support/Shion/usage.json`），保留 7 天。连上装了插件的服务器时马上传一次，之后每 10 分钟传一次上次之后新的和变了的段（正在进行的那段也传，结束后带着同样的开始时间再传一次，服务器按应用和开始时间认出是同一段）：`plugin.shion.usage.upload`，`segments` 里每段只有 `bundle_id`、`app_name`、`start`、`end` 四个字段（插件多一个字段就整次拒绝），时间是带这台 Mac 时区偏移的 ISO 8601，`device` 是 `mac`。服务器上默认保留 30 天。「回顾」用插件的 `shion_usage_day` 写日报里的屏幕时间。
- 设置里能关掉（关掉后不记也不传），能排除应用（从这周用过的应用里挑，或者在「应用程序」里选）：排除的应用不记录，这台 Mac 上已有的那部分也删掉，已经传出去的留在服务器上（插件没有删的方法）。
- 窗口标题只给专注检查用，不进使用记录。服务器只知道哪个应用、从几点用到几点；「回顾」按应用的类别算屏幕时间（`usage.day` 的 `by_category`，应用的类别用插件工具 `shion_usage_set_category` 改），这是插件本来的设计，不在 Mac 上另做摘要。

## Canonical Gateway Protocol 要点（写 Swift 客户端时用）

依据 Hermes `main`（2026-11）的 `apps/desktop/docs/canonical-gateway-protocol.md`、`tui_gateway/contracts/canonical*.py` 和生成的 `apps/shared/src/gateway-contract.generated.ts`。

- **连接**：WebSocket `/api/ws`，子协议 `hermes-gateway-v1`，方法表是 `CANONICAL_METHODS`。连上后先 `client.capabilities {server_requests: true}`，否则审批和提问会被直接撤回。
- **鉴权**：本机由 profile 目录下的私有 control socket 签发一次性 ticket（30 秒）。远端经 Cloudflare Access，再加可选的 Hermes 会话 token（见下一节）。
- **身份**：`session.create` 带 `source`（必须在 `runtime.describe` 的 `session_create.sources` 里）和 `client: {name: "shion"}`（服务器有 `session-client-v1` 时；只是个标签，什么都不影响）。
- **助手以为你在用什么界面**：系统提示里的平台说明和 `Platform:` 一行来自会话的 `source`，建会话时定下，之后改不了：`gui` 是桌面应用（`desktop`，按 Markdown 写），`cli` 是终端（不用 Markdown），不带 `source` 默认 `cli`。Shion 建的 Bot Chat 用 `gui`。可是按标题建 `Bot Chat` 时已经有一个，就直接沿用旧的；而 Hermes 自己替还没有 Bot Chat 的 profile 建的（定时任务送达、助手之间私信、`hermes chat -c "Bot Chat"`）都是 `cli`。所以较早的 Bot Chat 多半是 `cli`，要换只能新开一个。
- **对话分页**：`session.resume` 带 `omit_messages: true` 只接上会话、不带历史；再用 `session.transcript {order: "latest", limit, cursor}` 一页一页往前取（服务器有 `session-transcript-v1` 时），每页最多 500 行，按存的行数算，工具调用一行算一行。不带 `omit_messages` 的 resume 会把整段历史发两遍（`messages` 和 `display_messages` 各一份）。官方桌面端用的是 REST 的 `/api/sessions/{id}/messages?order=latest&offset=`。
- **Bot Chat**：一个助手 = 一个 profile = 唯一一个标题为 `Bot Chat` 的会话。用 `session.list {title, include_hidden: true}` 按标题找，`profiles.list` 也直接给出 `canonical_session`。不存会话 id 指针。
- **可靠提交**：客户端的 `input_id` 和服务端的 `admission_id` 分开，以回执为准（`prompt.receipt`、`prompt.resolve_unknown`）。
- **审批、提问**：回复要对准 `prompt_id` 和 `execution_generation`；断线重连后用 `session.events.since` 恢复还没回答的请求。
- **一次运行的编号和会话的版本**：每轮开始时会话的 `execution_generation` 加一，这一轮的每个事件帧都在 `params` 里带着它（和 `payload` 并列）；每轮结束 `revision` 加一。快照（`session.resume`、`session.create` 的回复）带当前的两个值，每轮结束的 `session.info` 也带（`gateway/session_authority.py` 的 `_publish_pending`：客户端只能从这里知道每轮之后的 `revision`）。
- **停止**：`session.interrupt {session_id, execution_generation}`（`profile` 只管路由；参数是封闭的，多一个少一个都是 `invalid_params`）。编号不是这一轮的就拒绝（`stale_generation`），对上了就硬停这一轮的 agent（压缩也停，后台委派不停），回复是会话的 handle。停下后这一轮照常结束：`message.complete` 的 `status` 是 `interrupted`（`outcome` 是 `cancelled`），`text` 是已经流出来的部分，什么都没出来时是一句占位（`Operation interrupted: …`），随后是 `running: false` 的 `session.info`。已经出来的部分存成一行助手消息，带 `display_metadata.interrupted`；停在工具调用之后的，收尾的那行也带这个标记（没有文字时是一行隐藏的占位）。
- **重试**：Hermes 的 `/retry` 是两步，官方桌面端的「重新生成」在 canonical 上也是这样拆的：先 `session.mutate {session_id, request_id, expected_revision, expected_generation, operation: "rewind", payload: {target_message_id}}`，把那条用户消息（`row_id`）和它后面的都收回（要空闲，在跑时是 `session_busy`；`revision` 或编号对不上是 `revision_conflict` / `stale_generation`，拒绝的 `error.data` 里带着新的两个值），回执的 `target_message.content` 是原来打的字；再 `prompt.submit` 一次。canonical 的 `prompt.submit` 没有截断参数（旧接口的 `truncate_before_row_id` 这些会被拒）；`session.branch_stored` 是另开一个会话，Bot Chat 只能有一个，不用。一轮结束时 `message.complete.persisted_turn` 给出这一轮存成的行：`user_row_id` 是提问那行，`submission_id` 是提交时带的那个，所以 Shion 用聊天里那条消息的 id 当 `submission_id`，就知道它存成了哪一行。
- **出错**：一轮出错时 `message.complete` 的 `status` 是 `error`。`error_surface` 是个对象 `{layer, code, retryable, …}`（`agent/error_surface.py`），不是文字；可读的说法看是哪种 gateway：TUI gateway 的帧把消息放在 `error`（`tui_gateway/session_auto_continue.py`），Shion 连的会话 gateway 不带 `error`，`text` 就是 Hermes 自己写的出错说明（`gateway/session_settlement_recovery.py` 的 `completion_payload`，`outcome` 是 `failed`），`partial` 为真时 `text` 才是已经流出来的回复；`failure_reason` 是个代号（比如 `rate_limit`），只给本机的查看端。官方桌面端也是先 `error`、再 `text`。对话记录里这一轮以一行助手消息收尾：`display_kind` 是 `failed_turn`，文字是 Hermes 的固定说明，`display_metadata` 里有 `error` 和 `error_surface`。固定说明有三句（`agent/turn_failure_copy.py`）：没处理（`FAILED_TURN_NOTICE`）、这一轮调用过工具时的「有些操作可能已经执行了」（`PARTIAL_FAILED_TURN_NOTICE`，gateway 看这一轮有没有工具行或带 `tool_calls` 的助手行来选），还有自动投递被打断的那句。会话 gateway 跑一轮用的是和平台 gateway 同一个 `_handle_message`，出错时也把这句说明隔一个空行接在 `text` 后面（`gateway/run_turn.py` 的 `_hmwa_add_failed_turn_notice`，发消息的不是 bot 就加，上下文超长除外）。`error_surface.retryable` 只是对 API 报错的分类（限流算可重试），不管这一轮有没有调用过工具。
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
| 页面切换、深链接（`#card-…`） | 侧栏选中状态 + 自定义 URL scheme 和 `.onOpenURL`，通知点进来直接到卡片 | 低 |
| 待办、等你确认、日报列表 | `LazyVStack` 加 `swipeActionsContainer()`、`reorderContainer`，`.contextMenu`，`.onHover` 显示「现在运行」 | 低 |
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
| 开机启动、常驻 | `SMAppService`；关掉窗口后留在菜单栏 | 低 |
| 凭证 | 钥匙串 | 低 |
| Gateway 连接 | `URLSessionWebSocketTask`（可以带 Access 和 Hermes 的请求头）+ 自己写的 JSON-RPC 层，类型从 OpenRPC 生成 | 中 |
| 云桌面画面 | 见上面「画面客户端」：自己写精简的 RFB 客户端，画面是 AppKit 的 `NSView`，接管条浮在上面用玻璃 | 高 |
| 点画面接管、点外面交还 | 画面视图成为第一响应者；`NSEvent.addLocalMonitorForEvents` 只看本 App 里的点击，所以切到别的 App 不会交还 | 中 |

### 对话的显示

- **工具调用**：连着的几条工具调用折成一行「用了 3 个工具 · web_search、read_file、web_extract」，点一下展开，再点收起，展开不记住。一轮还在跑时，最近的那几条照常一条一条显示，等这一轮的回复完成（`message.complete`）再折起来；后面已经接上助手的话的那几条不用等（和官方桌面端一样）。只有一条的不折，它本来就是一行。看板卡片（`kanban_create`）照常显示，夹在中间时前后各折各的。从 transcript 读进来的轮次已经结束，直接是折好的。
- **折起来那一行的 id** 取这一段最后一条工具调用的 id（`tools-<id>`）：更早的页加在上面，被页边界切开的一段补上前半截后 id 不变，往上加页时照旧用 `scrollTo` 停在原来那一行；直播时的工具行就用 transcript 给它的 id（`tool-<tool_call_id>`），重连重读后也一样。
- **Markdown**：助手的回复按 GitHub 的写法显示：标题、段落、有序 / 无序 / 嵌套列表、任务列表、代码块（等宽，长行横向滚）、行内代码、引用、表格（对齐照 `:--` / `:-:` / `--:`）、链接（没写成链接的网址也能点）、分隔线、删除线；图片只显示文字和链接。换行和标点照原样（不把直引号换成弯引号）。回复完成后一块一块地能选。流式输出时，最后一个空行（不在代码块里）之前的块已经完整，先排好，后面的跟着光标显示原文；完成后整条再排一次。
- **不卡**：解析结果按消息 id 和文字缓存（`MarkdownCache`，最多 400 条），长对话滚动、`LazyVStack` 重建行时不再解析；流式输出时只解析新完整的那一块。在 Linux 上用 release 编译量过：20 KB 的回复解析一次约 12 毫秒，每来一段文字找可以排版到哪里约 0.1 毫秒。
- **选型**（2026 年 11 月）：

  | | 结论 |
  | --- | --- |
  | Apple 的 swift-markdown（cmark-gfm）+ 自己写 SwiftUI 渲染 | **用这个**。swiftlang 维护，Swift 工具链和 DocC 在用，2026 年还在发版（0.8.0 五月、0.9.0 九月）；依赖只有 swift-cmark；GFM 的表格和对齐、任务列表、删除线都在语法树里；样式跟 `Theme.swift` 一致；解析那一半不碰 SwiftUI，在 Linux 上也能编译和测试 |
  | MarkdownUI | 2025 年 12 月起是维护模式，最后一次改代码在 2024 年 10 月，作者转去做 Textual |
  | Textual（MarkdownUI 的后继） | 在维护（0.5.0，2026 年 6 月），能跨块连续选中；但还是 0.x，接口还在变，要用它自己的一套样式 |
  | `AttributedString(markdown:)` 的 `PresentationIntent` | 不加依赖，能解析表格和对齐，但没有任务列表；`Text` 显示不了表格，块要从一串 run 里拼回来，还是要自己排版 |

  代价是不能跨块连续选中，只能一块一块地选。包用 XcodeGen 的 `packages` 加在 `macos/project.yml`，版本限在 0.9.x。

### 停止、重试、查找

- **停止**：一轮在跑时（从第一个事件到 `message.complete`，或者服务器说会话在跑，比如在等批准），输入框的发送按钮变成停止，⌘. 也能停。停的是这一轮事件帧上带的那次运行（`session.interrupt`，见上面「Canonical Gateway Protocol 要点」）。已经出来的部分留着，下面标「已停止」；什么都还没出来（停在工具调用里）就是一行「已停止」。重新读对话时按 `display_metadata.interrupted` 认出来，照样标。
- **重试**：最后一条助手回复下面有「重试」，条件是它回的是你打的一句话（不是看板的通知行）、这一轮已经结束、后面没有你再说的话。点了就照 `/retry` 做：服务器上收回那条消息和它后面的（`session.mutate` rewind，带着最近一次 `session.info` 里的 `revision` 和运行编号；对不上就用拒绝里给的新值再试一次），聊天里也去掉这一段，再把原话发一次。从对话记录读来的消息，`row-<id>` 就是它的行；这次连接里发的，等这一轮的 `persisted_turn` 说；都没有就读最近一页按原文找。收回只是对话，工具做过的事（建了卡片、写了待办、发了消息）收不回来，重试会让助手从头再做一遍：所以这一轮调用过工具（聊天里这一轮有工具行或新建的卡片，或者 Hermes 的说明是「有些操作可能已经执行了」）时，先弹一个确认框，列出这一轮用过的工具（名字和折叠行里的一样，新建的卡片写成 建卡片「…」），写明这些可能会再做一次，按「重试」才做，「取消」什么都不动。回复下面、「已停止」那一行、出错那一行，三处的重试都是这个规则；没调用过工具的轮次直接重试。
- **出错**：一轮出错时，已经出来的部分照样留着，下面是一块出错说明：第一行「这一轮出错了：…」写出了什么事，下面一句写怎么办，都是 Shion 自己的中文，按 `error_surface.code` 选，带上它给的服务商和模型名（意思照官方桌面端那张表，`apps/desktop/src/i18n/zh_error_codes.ts`），比如限流是「OpenRouter 那边请求太多了 / 等一会儿再试。」；钥匙和账户都在服务器上，所以怎么办也指向服务器。Hermes 自己的原文（实时出错时是 `text`，重新读对话时是 `display_metadata.error`）收在可以展开的「详情」里，能选中复制。Shion 没有中文说法的代号，照原样显示 Hermes 的原文。Hermes 那三句固定说明认出来就换成中文：「这次没有处理，还要做的话再发一次」「这一轮没做完，有些操作可能已经执行了，重发前先核实」「一次自动投递被打断了…」，不放进详情。这样实时的那行和重新读出来的那行说的是同一句话（两边都有 `error_surface`）。Hermes 说再试可能好（`error_surface.retryable`）时，下面就是「重试」，规则同上；说再试也没用（登录失效、内容被拒这类）时不给重试。系统通知里是第一行。停在什么都还没出来时的那行「已停止」下面也有「重试」。
- **查找**：⌘F（或工具栏的放大镜）在对话上面浮出一个玻璃的查找框，边打边找已经加载的行：消息的原文、工具调用、卡片的标题，不分大小写、全角半角和重音。命中的字标成系统的查找黄，看着的那条整条加深，滚到中间；折起来的工具调用里有命中时自动展开。框里是「第几条 / 共几条」。↑（回车、⌘G）往更早找，↓（⇧⌘G）往后，Esc 关掉。
- **更早的页**：边打边找只找已经加载的行，不为查找预先取历史：Bot Chat 一直是同一个会话，几个月下来有上千行，全取下来要几十次请求，对话也会变得很长。在最早一条命中上再按 ↑，才往前一页一页地取（每按一次最多 10 页、500 行），直到找到下一条，或者到了第一条消息。
- **没连上时**：输入框、勾待办、确认日期、新待办、新建卡片、挪卡片、回答批准都不让做（见下面「没连上时显示上次的数据」），停止和重试也只在连着时有。

### 没连上时显示上次的数据

- 连上过一次以后，Shion 把服务器给的数据在这台 Mac 上存一份：助手列表、今天页詩音写的那段话、待办、日报、看板上所有看板的卡片（列、在等什么、交给谁），还有每个对话最近的 50 条。连上后会在后台给每个已有的 Bot Chat 取最近一页，所以没打开过的对话也存得下（Bot Chat 还是只在打开对话时才新建）。
- 存在 `~/Library/Application Support/dev.shion.Shion/last-data.json`（权限 0600），记着是哪个地址的；不存 service token、会话令牌、登录凭证和密码，它们只在钥匙串里。等你确认的批准和提问不存：只能连着时回答。服务器没有的部分不存（没装 shion 插件就没有待办、日报），没连上时那部分照旧是示例数据。
- 什么时候存：连上并读完第一遍以后，数据有变化 3 秒后存一次；断线的那一刻、点「断开」之前、退出 Shion 时各存一次。
- 启动时还没连上、断了线、点了「断开」，窗口里显示的都是这一份，只能看：侧栏底部服务器下面一行写「上次的数据 · 今天 10:52」，设置里的状态写「未连接，现在是上次的数据（…）」。连上并读完第一遍以后换成服务器的。
- 只有从没连上过这个地址（还有截图模式）才显示示例数据。截图模式不读也不写这个文件，只在内存里留一份，端到端测试用它看断开后的样子。设置里「没连上时」一节写着存了什么、存在哪里，可以清除。

### 快捷呼出

- **⌥Space 小窗**：在任何 App 里按 ⌥Space（「设置 → 快捷键」里能改），鼠标所在那块屏幕的上方约五分之一处浮出一个玻璃小窗：输入一句话回车，这句话进总秘书（`chiefId`，默认是詩音）的 Bot Chat，和在主窗口里说的一样；她的回复在小窗里流式显示，用的是对话页的同一套行（工具调用折成一行、看板卡片、Markdown）。这一轮里总秘书要你批准的、问你的列在回复下面（不在回复的滚动区里，回复再长也不会被滚走），每个选项都能直接点；没有选项、要你打字回答的问题，输入框的提示变成「回答詩音…」，打字回车就是回答（`clarify.respond` 的 `answer`），不用打开对话。输入框右边的按钮（⌘O）打开完整对话；Esc 或再按一次快捷键收起。小窗是不激活 Shion 的 `NSPanel`：键盘到它这里，前台的 App 不变，收起后键盘回到原处；它浮在所有窗口上面，也能出现在全屏 App 上，点别处不会自己消失。收起时这一问已经答完的，下次打开是空的；还在等回复的，下次打开接着显示。小窗开着、显示着这一问时，她的回复、批准和提问不再另发系统通知。发之前先接上她的 Bot Chat 并读最近一页（和打开对话页一样：`session.resume`、`session.transcript`，没有就新建），流式回复才有地方落。菜单、设置里写的是当前总秘书的名字（「跟詩音说…」），换了总秘书就跟着换。
- **没连上时说的话**：排队，不丢（窗口显示着上次的数据时也一样，连上、读回服务器的数据以后才发）。在小窗里显示成淡一些的气泡，下面写什么时候写的和「等连上服务器后发出」（「17:05 写的 · 等连上服务器后发出」）；存在这台 Mac 上（`UserDefaults` 的 `QuickAskWaiting`，退出 Shion 也还在；截图和测试模式只放在内存里），连上后自动发给总秘书，回复照常出现在小窗里。攒了几句就合成一条发、一句一行：Hermes 在一轮回复还没完时收到新消息，默认会打断这一轮（`display.busy_input_mode` 默认是 `interrupt`），分开发会把前一句的回答截断。写下超过 5 分钟才发出去的句子，前面带上写下的时间（「（10:32 写的）提醒我 5 分钟后出门」，不是今天写的再加「昨天」或日期），不然隔了两小时才连上，总秘书会照字面去做；不到 5 分钟的照原样发。总秘书的对话打不开时也留在队里，下次打开小窗再试。没选「记成待办草稿」（本机模型）是因为：跟总秘书说的话不一定是待办（「到家了吗」「明天几点出门」），记成草稿就改了原意，总秘书看到的也不是你的原话；排队什么都不猜，日期不会被抽错，也不靠 Apple 智能（没开、不是 Apple 芯片就用不了），在 CI 上测得出来；理解、拆解本来就交给 VPS 上带着记忆和日程的总秘书（见「本机模型」）。
- **⌘1…⌘7、⌘K**：菜单栏多了「前往」：⌘1…⌘7 依次是今天、等你确认、待办、日程、日报、看板、云桌面，然后是 ⌘K「快速跳转…」和「跟詩音说…」（名字跟着总秘书，标着全局快捷键）。⌘K 在主窗口上面浮一块玻璃：没输入时列出页面和助手；输入后搜页面、助手（名字、简介、profile 名）和没做完的待办的标题（最多 6 条），↑↓ 选，回车打开，待办打开在「待办」页右边的详情里；什么都没搜到时只剩一行「跟詩音说「…」」，回车把这句话交给她并打开她的对话。全角字母、大小写不影响匹配；输入法选字时的回车和方向键归输入法。原来「跟詩音说」按钮上的 ⌘K 让给了快速跳转，按钮本身不变。
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
  src/views/    今天、待办、日程、日报、等你确认、Bot Chat
macos/          macOS App（SwiftUI + AppKit，最低 macOS 27），project.yml 由 XcodeGen 生成工程
  Shion/        App：Model（数据和示例数据）、Local（这台 Mac 的日历、前台窗口、本机模型和它们的假数据）、Support（启动参数、格式、配色）、Views（各页面）
  ShionUITests/ 截图测试（每个页面浅色、深色各一张），浏览器登录、看板、助手管理、⌥Space 小窗的端到端测试；这台 Mac 的数据（日历、专注检查、应用使用记录）的截图和端到端测试
  ci/           CI 上替身用的假 Hermes（fake_hermes.py，看板 fake_kanban.py，profile fake_profiles.py，小窗的回复 fake_quick.py，只用标准库）；check_fake_shion.py 比较替身和插件收不收得一样
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
- **现在能用的**：助手列表（每个 profile 一个助手）、每个助手的 Bot Chat（打开时先取最近 50 行，往上滑再一页一页取更早的；发消息、流式回复；工具调用在这一轮回复完成后折成一行，点开能看每一条；回复按 Markdown 显示，表格、列表、代码块都排好，见「对话的显示」）、批准和提问（连上后在后台接上每个助手已有的 Bot Chat，所以没打开过的对话里的批准和提问也会到「等你确认」，侧栏也能看到谁在忙；接上之后再给每个取最近一页，留作没连上时看的数据），系统通知（批准可以直接在通知里点「允许这一次」或「拒绝」，提问和回复可以直接在通知里回；对话或「等你确认」正开在眼前时不发；Dock 图标上是等你确认的件数）、看板（服务器的卡片、实时更新、拖动换列、新建、详情、评论署登录名、切换看板）、今天页的「助手在做」和对话里的卡片（取自所有看板）、设置里的看板上限（取自服务器）、停止和重试一轮回复、对话里查找（见「停止、重试、查找」）、没连上时显示上次的数据（见「没连上时显示上次的数据」）、设置里的服务器体检。服务器装了 `shion` 插件（`hermes-plugin/`，装法见那里的 README）时，今天页顶部詩音写的那段话、待办（勾掉、确认日期、新加都写回插件）和日报也来自服务器；助手经插件改了数据，Shion 一秒左右就收到推送，断线时漏掉的推送在重连时和每 5 分钟补一次。没装插件时这几页照旧是示例数据。日程、今天的时间线和菜单栏的「下一件」来自这台 Mac 的日历（「设置 → 这台 Mac」里允许读取、勾选日历；不连服务器也一样）。专注检查（设置里打开，要辅助功能权限和 Apple 智能）和应用使用记录（默认开）在这台 Mac 上记，连上装了插件的服务器时把结论发给总秘书、把应用段发给回顾。云桌面还是示例数据。
- **助手**：设置（⌘,）的「助手」一栏选谁当总秘书、哪些助手在 Shion 里不显示（Hermes 自己的默认 profile 删不掉，不用就不显示），按服务器地址存在这台 Mac 上；没选过时名叫 `shion` 的 profile 当总秘书，没有就是默认 profile。总秘书决定今天页那段话、专注检查发给谁、shion 插件在哪个 profile 里调用；「跟…说」的按钮、今天页的输入框、⌥Space 的小窗、⌘K 和菜单栏都用总秘书的名字和头像。换成没装插件的助手，今天、待办和日报回到示例数据。这台 Mac 第一次见到一个助手时，照 Bot Mode 的 `ui_meta['hermes-bots'].hidden` 决定显示不显示，之后以这台 Mac 的选择为准。「新建助手…」（那一栏，或侧栏右键）经 `profiles.create` 建 profile：名字、显示名、简介、SOUL、模型，可以复制一个现有的；不复制时 Hermes 把服务器自己的密钥和模型给它。每个助手有自己的设置页（侧栏右键「助手设置…」，或对话页顶部的按钮）：显示名（写进 `ui_meta`，和 Bot Mode 同一处）、头像（Bot Mode 的颜色和形状，写回 `ui_meta` 前比对版本号；图片经 `profiles.set_asset`；侧栏和对话里都用它）、简介、SOUL、模型、MCP 服务器（添加、编辑网址、命令、参数和登录方式、删除、开关、测试、OAuth 登录、从目录安装，要先下载的条目在后台装完会自己出现）、技能（开关、锁定）、工具，还有危险命令的审批方式、记忆、每轮步数上限；最下面删除这个助手（默认 profile 和总秘书除外）。删除时 Hermes 没能当场清掉这个名字的会话和路由记录（`settlement_pending`）的话，设置里列在「还在清理」，同名的新建先拦住；Shion 连着服务器时经 `cli.exec` 重试 Hermes 给的 `hermes profile purge-identity`，成功了自动放行。每个请求都写明是哪个 profile：路径里带名字，或者 `?profile=`；Shion 从不调 `POST /api/profiles/active`。删除、替换 SOUL、服务器提醒要确认的模型都先问你。MCP 的令牌和环境变量用密码框输入，只发一次，Shion 不显示、不保存，也不从服务器取回（不调 `/api/env/reveal`；编辑时只合并改了的项，新的令牌和值经 `mcp.servers.set_api_key` 存进那个 profile 的 .env，config.yaml 里只留引用）。
- **快捷键**：在任何 App 里按 ⌥Space 跟总秘书说一句话，回复在小窗里流式显示，这一轮里的批准和提问也在小窗里回答，⌘O 打开完整对话，Esc 收起；没连上服务器时说的话排队，连上后自动发出；主窗口里 ⌘1…⌘7 切页面，⌘K 快速跳转（页面、助手、待办标题），都列在「前往」菜单里；全局快捷键在「设置 → 快捷键」里改，被别的 App 占了那里会说。见「快捷呼出」。
- **连接方式**照官方桌面端连远端的做法：`wss://<地址>/api/ws?token=<登录凭证或会话令牌>`，不带子协议，每个请求带 Cloudflare Access 的两个头；连上后等 `gateway.ready`、发 `client.capabilities`，按服务器要求每 15 秒 `gateway.ping`；连上过又断了会自动重连，并重新打开刚才的对话。登录凭证被拒时先续一次再试，续不上才算登录过期。

### 原生 App 的界面检查

界面靠 CI 截图来看，不在本地开模拟器：
- **什么时候跑**：只有 `macos/` 或这个工作流改了才跑，也可以在 Actions 里手动触发；同一分支上新的提交会取消还没跑完的那次。
- **跑什么**：在 `xcode-27` runner（macOS 27、Apple 芯片）上生成工程、编译，再跑 `ShionUITests`：每个页面用启动参数直接打开（`-ShionSnapshot YES -ShionRoute today -ShionAppearance dark`），等界面稳定后截窗口（对话截詩音和课程的两段：折起来的工具调用，排好的表格、列表、代码块、引用和任务列表；`assistant-shion` 是詩音的助手设置页，示例数据）；另外点开菜单栏面板截整个屏幕，按 ⌘, 截设置窗口（还有已登录和会话令牌两种设置、用编出来的结果画的服务器体检页 `settings-check-*.png`（不连任何地址），和「快捷键」一栏）；詩音的对话以一轮出错收尾（示例，`-ShionFailureDemo YES`），截出错说明和展开的「详情」（`failed-turn-*.png`）；截 ⌥Space 小窗（整个屏幕：带一问一答的示例、从「前往」菜单打开的空小窗、没连服务器时发了一句），⌘K（没输入、搜「课」，再用 ↓ 和回车打开一条待办），并检查 ⌘1、⌘2、⌘6 切到的页面和 Esc 收起小窗（`quick-*`、`jump-*`、`settings-shortcut-*`）。
- **浏览器登录、看板、助手、小窗和对话控制的端到端测试**：runner 上没有真的 Cloudflare 和 Hermes，`macos/ci/fake_hermes.py` 两个都演：Access 按严格 service token 认证来（带 token 的请求只看 token、不发 cookie，错的 token 直接 403；不带 token 的浏览器转去另一个域名上的 Access 登录页，登录后靠 cookie 放行）；登录页自己填用户名密码提交；检查 PKCE、回调地址和 state；发登录凭证；`/api/ws` 说 JSON-RPC。替身还照 Hermes 的接口检查参数：`session.resume`、`session.transcript`、`session.create`、`prompt.submit` 不认识的键一律 `invalid_params`，`source` 和 `client` 也照规则查。`SignInTests` 在设置里填好地址，点「用浏览器登录…」，等登录完、连上、助手列表换成服务器的；先到「等你确认」：没打开过的课程的对话发来一个批准，点「允许这一次」，替身记下回答；再看今天、待办、日报是不是插件里的（替身里的插件在 `macos/ci/fake_shion.py`）：勾掉一条待办，等课程经插件加的那条推过来；再打开詩音的对话（135 行，先只来最近 50 行；照 Hermes 的样子，压缩行和存它的那条消息共用 `row_id`，工具行没有 `row_id`），发一句、等回复，往上滑到第一条，看压缩行、第一条都在，后面那轮的两次工具调用折成了一行；打开通勤的对话（新建）；最后看设置里的看板上限是不是服务器的值。每一步截一张（`signin-*.png`）。替身还演看板插件（`macos/ci/fake_kanban.py`：两块看板，`/workflow` 的移动规则、400 和 409 的拒绝、做完后把子卡升到就绪、`/events` 的 WebSocket，调了 `/dispatch` 会在记录里标出来）；`BoardTests` 登录后打开看板，看服务器的卡和每种「在等什么」，点开卡住的卡看评论和运行记录，留一条言（替身记下作者，要显示成「你」）并让它继续，把一张卡拖到「完成」（拖不动就用右键菜单），新建一张；再到詩音的对话里说「派一张卡」，替身照 Hermes 的样子演她调 `kanban_create`（开始时带参数，结束时结果里有卡的编号），几秒后课程做完，替身发看板的通知行，再让詩音接着说一句：对话里要先出现那张卡，再变成「完成」，通知行也显示成卡；在设置里断开再连上，对话从服务器重新读一遍（对话记录只留调用、不留结果），两张卡都还在、都是「完成」；然后换到另一块看板，再看今天页的「助手在做」列出两块看板上在做的卡；最后回到詩音的对话说「列一下这周的作业」，替身照 Hermes 的样子演一轮：三次工具调用（中间隔一会儿，跑着的时候能看到），再一段一段地回一张表：表格的格子要单独显示出来（不是带竖线的原文），回复完成后三次调用折成一行，点开能看到每一条（`board-*.png`）。替身还演 profile 这一套（`macos/ci/fake_profiles.py`：`profiles.list`、`profiles.create`、`profiles.configure` 照 Hermes 的参数检查和拒绝方式，`ui_meta` 按版本号比对，贵的模型要确认；`/api/profiles`、SOUL、简介、`/api/mcp/*`、`/api/skills`、`/api/tools/toolsets`、`/api/config?profile=`；`mcp.servers.add` / `remove` / `set_api_key`、`profiles.get_asset` / `set_asset`、`/api/actions/{name}/status`、只演 `hermes profile purge-identity` 的 `cli.exec`；`/api/config` 照 Hermes 的 `_deep_merge` 合并 `mcp_servers`；删默认 profile 照 Hermes 返回 400；shion 插件只装在詩音和 Hermes 默认 profile 里（`LocalDataTests` 把后者换成总秘书）；几个专门的情形：归档（archive-ci）在 Bot Mode 里是隐藏的，通勤有头像图片，删 mail-ci 时身份记录没清完、第四次重试才成功，目录里的 slow-ci 在后台安装，通勤的 SOUL 在第二次读的时候已经被别的客户端改过；比 Hermes 严的一处：按 profile 的接口不带 `?profile=` 直接拒绝）；`BotsTests` 登录后看归档一开始就不显示，把总秘书换成课程（今天页回到示例数据，输入框、「跟…说」和菜单栏「前往」里那一项都改成课程）再换回詩音，看默认 profile 的设置页上删不了，在设置里把它设成不显示，从侧栏右键新建一个助手，改它的简介和 SOUL（替换前要确认），加一个 MCP 服务器并测试，关掉一个技能，重新打开这一页看这些都从服务器读回来了，删掉它，再看设置里列着「还在清理」、同名的新建被拦住，等 Shion 的重试成功后自动放行（`bots-*.png`）；`BotPageTests` 走一遍通勤的设置页：SOUL 被别处改过时先问再覆盖，换一个要确认的贵模型，选头像的颜色和形状，加一个 MCP 服务器、改网址加令牌、再改成 OAuth、关掉、删掉，从目录装一个马上装好的和一个后台装的（装完自己出现），开一个工具集，改「其他」里的四项，锁一个技能，最后重新打开这一页看都从服务器读回来了（`page-*.png`）。`QuickAskTests`（启动参数带 `-ShionHotKey YES`，测试模式平时不注册全局快捷键）登录前先按 ⌥Space 说「小窗：到家了吗？」，小窗里这句标着写下的时间和「等连上服务器后发出」；启动参数 `-ShionQuickWrittenAgo 7200`（只在测试模式下有用）让要排队的句子算作两小时前写的，所以登录后它自己发出去时带着「（…写的）」，替身原样回「收到：（…写的）小窗：到家了吗？」，再打开小窗，回复在里面，没有在等的了。然后把访达切到前台，在访达里按 ⌥Space（只有系统的全局快捷键做得到，「前往」菜单里那份只在 Shion 在前台时有用），看小窗出来、再按一次收起；再回到 Shion 按 ⌥Space（到不了小窗时改用「前往」菜单），说「小窗：明天几点出门？」，替身（`macos/ci/fake_quick.py`）照 Hermes 的样子一段一段地回「收到：…」，每 0.6 秒三个字：小窗里要先看到光标、后看到整句；接着说「小窗：帮我把实验报告交了」，替身让詩音在这一轮里先发一个批准（`approval.request`，照 `gateway/session_pending_controls.py` 的样子），在小窗里点「允许这一次」，再问一句没有选项的「交给哪位老师？」（`clarify.request`），输入框提示变成「回答詩音…」，打「中村老师」回车，詩音回「交给中村老师了。」；点「打开完整对话」，小窗收起，主窗口打开詩音的对话，这一问一答都在；再按 ⌥Space，小窗是空的，Esc 收起（`quick-*.png`）。它的第二个测试由测试进程自己先独占注册 ⌥Space，扮演占着它的 App：「设置 → 快捷键」要显示「被别的 App 占用了」；测试进程放开后点「再试一次」，提示消失，⌥Space 叫得出小窗（`quick-taken*.png`）。替身还演停止、重试和服务器体检要的那几处（`macos/ci/fake_control.py`：每轮的事件帧带运行编号，快照和每轮结束的 `session.info` 带编号和 `revision`；`session.interrupt` 编号不对就 `stale_generation`；`session.mutate` 的 rewind 照 Hermes 查 `revision`、编号、空闲和目标行；「出个错看看」照会话 gateway 的样子出错：`status` 是 `error`，`text` 是 Hermes 对限流的说明、空一行再接它的固定说明，`error_surface` 说可以重试，没有 `error`，对话记录里以 `failed_turn` 那一行收尾；「查一下明天的天气」先调一次 `web_search` 再回答）；`ChatControlTests` 登录后先看服务器体检的每一项（shion 插件只在詩音和 Hermes 默认 profile 里，课程、通勤那几行是「没装或没启用」；替身的插件报没有时区数据，要显示「服务器缺时区数据」），再在詩音的对话里说「讲一个长故事」（替身每 0.3 秒回一句，回半分钟），按 ⌘. 停下，看已经出来的部分标着「已停止」，点「重试」：替身收回那一轮，同样的话这次很快回完；再说「出个错看看」，看出错说明是中文的「OpenRouter 那边请求太多了」和「等一会儿再试。」（不是「没有说明」，英文的固定说明也不出现），展开「详情」看到 Hermes 的原文，点「重试」不用确认，这次回了；再说「查一下明天的天气」，点「重试」先弹确认框，里面列着 `web_search`，点「取消」什么都没变，再点「重试」、确认，原话只剩一条，新的回答出来了；然后 ⌘F 找「第 12」（都在最近一页上），回车跳到更早的一条，再找「第 3 条」（在两页以前），按 ↑ 一页一页往前取，直到它出现；最后在设置里断开，窗口还是服务器的数据：对话还在、侧栏写着「上次的数据」、输入框和待办的勾都不能用（`chatctl-*.png`；确认框在 XCUI 里是什么元素、按钮的 identifier 还在不在，记在 `chatctl-question.txt`）。设置窗口平时记得上次停在哪个标签；截图和测试模式下总是从「服务器」开始，也不记，截图测试看完「快捷键」重新启动一次，确认还是从「服务器」开始（`BotsTests` 停在「助手」，排在它后面的 `BotPageTests` 和 `QuickAskTests` 登录时也要从「服务器」开始）。每个测试各用一个新起的替身，课程的批准、它加的待办这类只发一次的事不会被前一个测试用掉，`BotsTests`、`BotPageTests` 改过的 profile 也不会留给别的测试。替身的请求记录（`fake_hermes-SignInTests.log`、`fake_hermes-BoardTests.log`、`fake_hermes-BotsTests.log`、`fake_hermes-BotPageTests.log`、`fake_hermes-QuickAskTests.log`、`fake_hermes-ChatControlTests.log`、`fake_hermes-LocalDataTests.log`，密钥只记名字）也在附件里。用 OAuth 登录 MCP 服务器要开浏览器，CI 上没测。这一步失败只报警告，截图和安装包照样出。
- **这台 Mac 的数据的端到端测试**：runner 上给不了日历和辅助功能权限，也没有 Apple 智能，所以 `LocalDataTests` 用启动参数 `-ShionLocalScript YES`（只在截图模式下认）换上一组跟着真时钟走的假数据（`macos/Shion/Local/LocalFixtures.swift`）：几个日历（一个没勾）、一段正在进行的专注时段、前台一个看了 7 分钟的猫视频、今天早些时候的使用记录（里面有一个被排除的应用），判断用固定的规则代替本机模型。替身里的插件照插件自己的检查收 `focus.report`、`usage.upload` 和 `settings.get` / `settings.update`（多一个字段、类型不对、时间不对都拒绝；`session_id` 照 Hermes 先查是不是这个 profile 的会话），报告不是在 `chief_profile` 里发的回 `wrong_profile`，总秘书的 Bot Chat 还没有过一轮对话（插件还不知道它的路由键）回 `no_session_key`，否则照 `inject_message` 的样子把那句话放进总秘书的 Bot Chat、让它回一句；收到上传后让「回顾」按上传的段写今天的生活日报里的屏幕时间。测试先看今天页没连服务器时就是这台 Mac 的日历（没勾的那个日历里的不出现），登录后还是；再打开詩音的对话，等她回「已经过了 7 分钟」那句、再等前台换成报告后她回「回来了就好」，两次都不能看到「［专注检查］」那行；菜单栏里是「在做「…」」；日报里有「Xcode 40 分钟」，没有被排除的应用；设置里写着最近一次告诉了詩音什么、上次什么时候发给回顾；在设置里取消勾选那个专注日历，今天页上它的日程就没了；最后在「设置 → 助手」里把总秘书换成 Hermes 默认 profile（替身里它也装着插件），「这台 Mac」的专注检查那一节写着插件叫醒 Hermes（CI）（替身的 `chief_profile` 跟着改了），再换回詩音，那里又写詩音（`local-*.png`）。替身和插件收不收得一样，改了任何一边后在 Linux 上跑 `python3 macos/ci/check_fake_shion.py`，它把同一批调用分别交给插件（`hermes-plugin/shion`，不装 Hermes，詩音和通勤两个 profile 共用一份数据）和替身，比较两边接受还是拒绝、拒绝的理由、叫没叫醒（没叫醒的理由）和设置（CI 不跑它）。
- **截图模式**：日期固定在 2026 年 11 月 9 日（周一）10:52，外观对整个 App 生效（菜单栏面板也跟着变），呼吸点不动。这台 Mac 的数据也换成假的、停在那一刻：几个日历（演示的那一周）、10:45 起前台一直是猫视频（所以专注检查是「7 分钟没在做」）、今天的使用记录；不申请任何权限，不读真的日历和窗口，不存文件，也不往服务器发。`-ShionCalendarAccess none` 演还没允许读取日历的样子。`LocalScreenshotTests` 截设置里的日历、专注检查、应用使用记录三节，点开菜单栏里的专注检查，再截没允许读取日历时的日程页和设置（`settings-calendars-*`、`settings-focus-*`、`settings-usage-*`、`menubar-focus-*`、`calendar-noaccess-light`）。动画停下来 App 才算空闲，XCTest 不用干等，一次运行从 4.3 分钟降到 2.3 分钟。
- **runner 的屏幕**：1024×768、1 倍，所以窗口截出来是 1024×674，比默认窗口小，正好看窄窗口下的布局。
- **看哪里**：截图打包成这次运行的 `shots` 附件（保留 14 天），文件名是「页面-外观.png」。编译失败时，最后一步会列出错误；编译警告（xcodebuild 的警告不会自己变成注解）由「Compiler warnings」一步列成这次运行的注解，所以一次运行没有注解，就是没有警告。端到端测试失败时，那一步从结果包里打出失败的断言和消息（`-quiet` 不打）；XCTest 在找不到元素时存的界面层级（「App UI hierarchy」）也在附件里，同名的按新旧编号，不互相覆盖。
- **省时间**：macOS runner 的分钟数有限，攒够一批改动再推；只改 README 这类文件不会触发。

## 路线图

1. **对齐界面**（现在）：用原型把信息结构和关键流程定下来。
2. **协议探路**：一个命令行小程序，经 Cloudflare Tunnel 用 Access service token 连上 VPS，跑通握手、`profiles.list`、打开 Bot Chat、流式消息、回答审批，同时验证风险 1–4，再走一遍风险 5 的探路（画面 WebSocket 的 RFB 握手）。
3. **SwiftUI 骨架**（已开始，`macos/`）：主窗口和各页面先用示例数据做出来；接着是可回复的系统通知、菜单栏、全局快捷键；云桌面先做缩略图和接管、交还，再做实时画面。
4. **`shion` 插件和助手团队**：插件提供待办、今天汇总、日报、应用记录；把詩音和各助手的 profile、SOUL、例行任务做成一套可一键部署的模板。
5. **今天 / 待办 / 日程 / 日报** 接真实数据，加上 Mac 应用使用记录。
6. 以后：接入这台 Mac 让助手在本机做事；全天录音。
