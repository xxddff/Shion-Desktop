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
| 连接方式 | 和官方 Webapp、桌面端一样走「远程网关」：URL + 登录。首选 Tailscale + 会话 token；SSH 隧道只作备用 |
| 邮件 | 一个能收发大多数邮箱的工具：Hermes 自带的 himalaya 技能（IMAP/SMTP）加 email-inbox-triage 技能 |
| 日历、提醒事项 | Apple 的，经 iCloud 云端接入 |
| Notion | 主要放课程相关的内容（录音转写、笔记） |
| 课表 | 放在日历里；以后再接 Moodle、学校教务系统 |
| 地区 | 东京（通勤数据按日本的电车、巴士） |
| 首批场景 | 邮件、日程、待办；通勤路线与延误；课后整理录音成待办；课程提醒；每日安排与催促；应用使用记录与每日回顾；事实核查；新闻和学习/工作/生活日报 |

## 架构

```
┌──────────── 这台 Mac ────────────┐            ┌──────────────── VPS ─────────────────┐
│ Shion.app (SwiftUI)              │ Tailscale  │ hermes serve / gateway owner          │
│  ├ 窗口：今天 · 待办 · 日程 · 日报 │ 会话 token │  ├ Canonical Gateway Protocol (WS)    │
│  │       等你确认 · 各助手 Bot Chat │            │  ├ profiles = 紫苑 + 各助手            │
│  ├ 菜单栏常驻 + ⌥Space 随手交代     │            │  │   各自的 SOUL、记忆、技能、MCP、凭据   │
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
| 全天录音（以后） | 新助手 | 转写 → 记忆 → 待办 | 暂不做 |

**关于日报放不放进 Shion：** 生成不放在 Shion，交给 Hermes 的例行任务：Mac 关着也能按时写，还能同时推到手机（Telegram 等平台）。Shion 只负责阅读界面，再加上提供应用使用记录这一份 VPS 拿不到的数据。

## Canonical Gateway Protocol 要点（写 Swift 客户端时用）

依据 Hermes `main`（2026-11）的 `apps/desktop/docs/canonical-gateway-protocol.md`、`tui_gateway/contracts/canonical*.py` 和生成的 `apps/shared/src/gateway-contract.generated.ts`。

- **连接**：WebSocket `/api/ws`，子协议 `hermes-gateway-v1`，方法表是 `CANONICAL_METHODS`。连上后先 `client.capabilities {server_requests: true}`，否则审批和提问会被直接撤回。
- **鉴权**：本机由 profile 目录下的私有 control socket 签发一次性 ticket（30 秒）。远端和官方 Webapp、桌面端一样走 `hermes serve` 的登录提供方（见下一节）。
- **身份**：`session.create` 带 `source`（必须在 `runtime.describe` 的 `session_create.sources` 里）和 `client: {name: "shion"}`。
- **Bot Chat**：一个助手 = 一个 profile = 唯一一个标题为 `Bot Chat` 的会话。用 `session.list {title, include_hidden: true}` 按标题找，`profiles.list` 也直接给出 `canonical_session`。不存会话 id 指针。
- **可靠提交**：客户端的 `input_id` 和服务端的 `admission_id` 分开，以回执为准（`prompt.receipt`、`prompt.resolve_unknown`）。
- **审批、提问**：回复要对准 `prompt_id` 和 `execution_generation`；断线重连后用 `session.events.since` 恢复还没回答的请求。
- **不在 canonical 里的**：看板走 `/api/plugins/kanban/*`，例行任务列表走 `/api/cron/jobs`（canonical 里只有 `cron.submit` 立即运行和 `cron.status`）。
- **类型生成**：`apps/shared/src/gateway-contract.openrpc.json` 可以生成 Swift `Codable` 类型，不用手写。

## 连接远端：和官方保持一致

官方 Webapp 和桌面端连远端都是「远程网关」：`hermes serve` 绑到一个能访问到的地址，绑到非本机地址时自动启用登录关卡，然后用以下任一方式登录：

| 方式 | 适合 | Shion 怎么带凭证 |
| --- | --- | --- |
| 部署会话 token（`HERMES_DASHBOARD_SESSION_TOKEN`） | Tailscale 等私有网络 | REST 带 `X-Hermes-Session-Token` 头；`/api/ws` 带 `?token=` |
| 用户名密码 | 可信局域网、VPN | 先登录换会话，再带会话 |
| OAuth（Nous Portal 或自建 OIDC） | 暴露到公网（配 HTTPS 反代） | 浏览器授权后带 bearer token |

**第一版：VPS 加入 Tailscale**，`hermes serve --host <tailscale-ip>`，用会话 token。Mac 和手机都能连，不开公网端口，也不用维持隧道。以后要从公网访问，再加 HTTPS 反代和 OAuth。SSH 隧道是官方桌面端支持的四种连接方式之一，Shion 留作备用。

**还没验证的风险**
1. 第三方客户端能用哪个 `source`（官方桌面端用 `gui`）。要在我们的 VPS 上看 `runtime.describe`。
2. 远端经 `hermes serve` 时，canonical 方法和插件 RPC 是否都能用。
3. 官方 Bot Mode 把头像、分组等存在 profile 的 `ui_meta` 里。Shion 要读写同样的键，才能和命令行、手机端保持一致。
4. **Apple 提醒事项经云端读写不一定可靠。** iCloud 日历走 CalDAV 没问题；但按 BusyMac、2Do 的说明，iOS 13 / macOS Catalina 之后升级过的提醒事项列表不再走 CalDAV，有的 MCP 声称能读写，说法不一。先用实际要用的工具测一遍；不行的话，就由 Mac 上的 Shion 用 EventKit 读写提醒事项（这正好是"接入本机"的第一个用途），或者以 `shion` 插件里的待办为准，只往提醒事项单向同步。

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
2. **协议探路**：一个命令行小程序，经 Tailscale 用会话 token 连上 VPS，跑通握手、`profiles.list`、打开 Bot Chat、流式消息、回答审批，同时验证上面三个风险。
3. **SwiftUI 骨架**：`NavigationSplitView` 主窗口、Bot Chat、等你确认、可回复的系统通知、`MenuBarExtra`、全局快捷键。
4. **`shion` 插件和助手团队**：插件提供待办、今天汇总、日报、应用记录；把紫苑和各助手的 profile、SOUL、例行任务做成一套可一键部署的模板。
5. **今天 / 待办 / 日程 / 日报** 接真实数据，加上 Mac 应用使用记录。
6. 以后：接入这台 Mac 让助手在本机做事；全天录音。
