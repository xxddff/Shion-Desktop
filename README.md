# Shion

一个 macOS 桌面端的 Hermes Agent 控制台：**看 Bot 在干什么、看看板在怎么流转、处理它们发来的审批**。

这是 UI 原型：界面完整可交互，数据来自内置的模拟器（`src/data/simulator.ts`），帧的形状按 Hermes 的 TUI Gateway JSON-RPC 和 Kanban `task_events` 来写，接真协议时只需替换数据源。

```bash
npm install
npm run dev        # http://localhost:1420
npm run typecheck
npm run build
```

## 定位

官方 Hermes Desktop 以「聊天」为中心。Shion 只做「运维台」这一件事：

| 场景 | Shion 里的位置 |
| --- | --- |
| 一眼看全局：几个 Bot 在线、几张卡在跑、哪里卡住了 | 总览 |
| Bot 要批准危险命令、向你提问、索要密钥 | 待处理（server→client 请求的统一收件箱） |
| 盯某个 Bot 的实时输出、工具调用，必要时引导或打断 | Bot 详情 |
| 看板流转、拖卡片、看心跳和运行记录 | 看板 + 任务详情 |
| 调协议 | Bot 详情里的「协议帧」面板 |

## 协议映射

**Bot 实时活动**：TUI Gateway，WebSocket `/api/ws`，子协议 `hermes-gateway-v1`

| UI 行为 | 协议 |
| --- | --- |
| 连接后第一件事 | 等 `gateway.ready` → `client.capabilities { server_requests: true }`（必须，否则审批会被直接撤回）→ `runtime.describe` |
| Bot 列表 / 会话标签 | `session.active_list`、`session.list` |
| 打开会话（多端同看，不抢占） | `session.activate`，历史用 `session.transcript`（cursor 分页） |
| 流式输出、工具卡片 | `message.delta` / `message.complete`、`tool.start` / `tool.complete` |
| 引导 / 后台提交 / 打断 | `session.steer` / `prompt.background` / `session.interrupt` |
| 待处理收件箱 | 服务端发来的 `approval`、`clarify`、`secret` 请求；回复必须带同一个字符串 id；没实现的方法回 `-32601` |
| 断线重连 | ticket 一次性，重连前重新 `hermes gateway attach --recover`；连上后 `session.events.since`，用 `open_requests` 恢复挂起的审批，用 `inflight` 接上正在输出的回复 |

**看板**：Kanban 插件，REST `/api/plugins/kanban/*` + WS `/events?since=<event_id>`

| UI 行为 | 协议 |
| --- | --- |
| 看板列 | `GET /board`，状态 `triage → todo → ready → running → blocked → review → done` |
| 拖卡片、改负责人 | `PATCH /tasks/:id` |
| 评论（Bot 之间交接的主要方式） | `POST /tasks/:id/comments` |
| 实时更新 | `/events` 推送 `task_events`，记住最后一个 id，重连时 `?since=` 补齐 |
| 心跳、运行记录 | `heartbeat` 事件、`GET /tasks/:id` 里的 `runs[]` |

> 注意：kanban 插件的 HTTP 路由本身不鉴权，不要把 dashboard 绑到 `0.0.0.0`。

协议类型在 `src/protocol/`，是按官方文档整理的，接入前请对照 `tui_gateway/server.py` 再核对一遍字段。

## 代码结构

```
src/
  protocol/   gateway.ts（JSON-RPC 方法/事件/服务端请求）、kanban.ts（任务、事件、运行）
  data/       model.ts（UI 领域模型）、seed.ts（示例数据）、store.ts（状态 + 动作）、simulator.ts（假 gateway）
  views/      Overview、Inbox、Bots（列表 + 详情）、Board（看板 + 任务详情）
  components/ Shell（侧边栏、工具栏）、Overlays（⌘K、新建任务、连接、通知）
```

`store.ts` 里的 reducer（`withFrame`、`withTaskEvent`、`withItem`…）就是真客户端收到帧以后要调用的那一层。

## 原型里可以试的

- 在「待处理」或 Coder 的会话里批准 / 拒绝 `git push --force-with-lease`，Coder 会按你的选择继续
- 回答 Atlas 的提问，它会接着拆子任务，新卡片出现在看板上
- 给 Sentinel 提供 token，被阻塞的卡片会解除阻塞并被重新认领
- 拖动卡片换列，在任务详情里看事件流和运行记录
- ⌘K 搜索，⌘1/2/3 切换视图，连接面板里切换外观、暂停模拟

## 下一步

1. **套 Tauri 2 壳**：`titleBarStyle: Overlay` + `window-vibrancy`（侧边栏材质），前端已经为原生红绿灯留了位置；HTML 上有 `data-tauri-drag-region`。
2. **真客户端**：`src/data/` 下加 `gateway-client.ts`（参考 Hermes 仓库里的 `@hermes/shared/gateway-client`）和 `kanban-client.ts`，替换 `simulator.ts`。
3. **macOS 原生能力**：菜单栏 Extra 显示运行中任务数；待处理请求发系统通知，通知上直接批准；Dock 角标；全局快捷键呼出 ⌘K。
4. **多 Gateway**：一个窗口里同时连多台机器（本机 + 远程服务器），侧边栏按 Gateway 分组。
