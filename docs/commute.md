# 通勤：接入你的运行信息 API（评估）

你已经有一个 API 格式的运行信息数据源，还没接入，接口细节还不知道。这份文档评估怎么接进来：

- 插件里的轮询器怎么调它；
- 一条状况怎么换成我们自己的结构；
- 从数据源有变化，到 Mac 上看到、收到通知，要多久；
- Hermes 跑在容器里要注意什么；
- 通勤助手、插件、App 各管什么。

只是评估，没有改 `hermes-plugin/`、`macos/` 的代码。实装等你确认后再做，分步见第 6 节。

依据：
- Hermes `main` 的 `927dba28`（2026-11-09）的代码和文档。**不带前缀的路径都是 Hermes 仓库里的**；`hermes-plugin/`、`macos/` 开头的是本仓库的（`claude/macos-app` 的 `bd86e36`）。
- 只读了代码和文档，没有在我们的 VPS 和容器里跑过。没确认的写着「没核实」，汇总在第 8 节。

## 结论

1. **接在 shion 插件里，不经过 LLM。** 插件加一个轮询线程，只在通勤时段调你的 API：每趟行程从出门前 60 分钟到到达后 10 分钟，默认每 60 秒一次。
   - 每条线路的状况换成统一的结构，和上一次比，真的变了才写库。
   - 插件现有的推送线程每秒看一次库的 revision。它一变，就向所有连着的 Shion 发 `plugin.shion.changed`，话题是新加的 `commute`；App 收到后取一次 `commute.get`。
2. **能多快。** 按 60 秒轮询算，从 API 上出现变化，到 Mac 上看到、收到通知：平均约 30 秒，最坏约 1 分钟零几秒。
   - 瓶颈是轮询间隔和数据源自己的更新延迟。后面几段（写库、推送、App 取数）加起来一般不到 2 秒。
   - API 能主动推送（webhook）的话，可以降到几秒，但要多过 Cloudflare Access 和 Hermes 认证这两道门，见 2.5。
3. **不让助手用 cron 定时查。**
   - Hermes 的 cron 每 60 秒 tick 一次，最短能写 `every 1m`。
   - 每次运行都新起一个助手会话、调一次模型，慢，还花 token。
   - 不调模型的 `no_agent` 脚本，输出只能送到消息平台，写不进插件的库，到不了 App。
4. **推送只在 `plugins.isolation: in_process`（默认）下能用。** `host` 模式下插件跑在单独的宿主进程里，全局广播在那里没有接收方，直接丢掉。这一点核实过代码。
5. **容器：**
   - 轮询线程在 gateway 容器里跑。
   - 数据库和 key 都放在挂载卷 `/opt/data` 里；key 单独放一个文件，不放进环境变量。
   - 轮询器的状态存在 SQLite 里，容器重启后接着轮询，不会重复通知。
   - 容器要能出网访问你的 API。
   - 时间按插件自己的时区设置（`Asia/Tokyo`）算。镜像里有没有 IANA 时区库没核实，要进容器查一次（3.3）。
6. **分工：**
   - 通勤助手：排行程、算出门时间、出异常时给建议；
   - 插件：轮询、判断变化、推送；
   - App：今天页的通勤卡片、菜单栏的回家路线、通知。通知每趟最多 4 条，出门提醒另算，规则见 5.3。
7. **Mac 合着时收不到。** 路上多半就是这种情况，App 收不到推送，也发不了通知。路上要在手机上收，得走 Hermes 的消息平台（Telegram 等），见 5.4。
8. **要你提供的信息在 1.5。** 最要紧的是：
   - 正常、延误、停运（運転見合わせ）时各一段真实返回；
   - 认证方式；
   - 允许多久调一次；
   - 有没有 webhook。

## 1. 接入你的 API：适配层

### 1.1 结构

插件里加三块（文件名是建议的）：

| 部分 | 做什么 |
| --- | --- |
| `commute_source.py`（适配器） | 只管你的 API：拼请求、带认证、解析返回，换成 1.4 的 `LineStatus`。以后换数据源，只换这一个文件 |
| `commute.py`（存储和判断） | 行程、每条线路当前的状况、变化记录，都存进现有的 `shion.db`；和上一次比，判断是不是值得推送的变化 |
| `poller.py`（轮询线程） | 算现在在不在通勤时段、该不该调；调适配器；出错时退避 |

适配器的接口：

```python
class CommuteSource:
    name = "my_api"                       # 写进每条状况的 source
    def fetch(self, lines: list[str]) -> "FetchResult": ...

@dataclass
class FetchResult:
    statuses: list["LineStatus"]          # 只含要盯的线路
    source_time: str | None               # 数据源说这批数据是什么时候的（有就填）
    retry_after: float | None             # 秒：取自 Retry-After、Cache-Control: max-age 或数据里的有效期
```

- **HTTP**：用 Python 标准库 `urllib.request`。插件现在只用标准库，不往 Hermes 的环境里装包：容器里 Hermes 的 venv 是封住的，不往里写（`Dockerfile:504`），PM 换一代环境时装进去的东西也会消失（`hermes-plugin/README.md`「安装到服务器」）。
- **请求**：每次 10 秒超时，读 JSON。API 有 ETag 或 Last-Modified 的话，就发条件请求：没变时回 304，省流量。
- **范围**：API 能按线路过滤，就只取要盯的那几条；不能就取全部，在本地筛。
- **认证**：照你的 API 来，放请求头（`Authorization: Bearer …`、`X-API-Key: …`）或查询参数（`?key=…`）。
  - key 只在发请求时读，不写进日志、错误信息，也不放进 `commute.get` 的返回。
  - 查询参数里的 key 会留在代理和对方服务器的访问日志里，两种都行时用请求头。

### 1.2 什么时候调、多久调一次

- **只在通勤时段调。** 每趟行程从出门前 60 分钟，到预计到达后 10 分钟，两个数都能改；当天几趟的时段合在一起。时段外一次都不调。
- **时段内默认 60 秒一次。** 可以设成 30–300 秒，但不超过 API 允许的频率。每次加 ±10% 的随机偏移，免得总在整点撞上别人。
- **刚变差的 10 分钟内调得勤一点。** 比如 30 秒一次（API 允许的话），好早点看到「運転再開」。
- **出错时退避：**
  - 超时、5xx、连不上：隔 2、4、8 分钟再试，最长 10 分钟一次；连续 3 次失败，记成「数据源取不到」。App 显示「运行信息暂时取不到」，不当成正常。
  - 401、403：停下来等你换 key，`commute.get` 里写 `source.state: "auth"`，不反复撞。
  - 429：照 `Retry-After` 等。
- **行程从哪来**：通勤助手按日历排好，用插件的工具写进来（5.1）。哪天没有计划，就用设置里的默认时段兜底，比如工作日 07:30–09:00、17:30–19:00，盯常坐的几条线。
- **量**：一天两个 90 分钟的时段，60 秒一次，是 180 次请求。

### 1.3 轮询线程在哪个进程里跑

好几种进程都会加载插件：gateway（Shion 连的就是它），看板 worker（`hermes -p <profile> chat -q` 子进程），命令行，dashboard。

现有的推送线程只有在 gateway 里才有用，因为只有它连着 Mac。所以它等到第一次 `sync.state` 或 `changes.since` 才起（`hermes-plugin/shion/rpc.py:47,56`、`hermes-plugin/shion/watcher.py:32-45`）。

轮询器不一样：它只写库，在哪个进程里写都行，推送照样由 gateway 里的推送线程发。建议：

- **`register()` 时就起轮询线程**，每个进程最多一个，和推送线程一样按线程名去重。这样 gateway 重启后、Mac 还没连上时，也照常轮询，助手和手机通知（5.4）拿到的是最新的状况。
- **线程每 30 秒醒一次**，三条都满足才调 API：
  - 现在在通勤时段里；
  - 读得到数据源的设置和 key（3.5）；
  - 拿到了库里的**租约**：一行记着 `owner` 和 `expires_at`，持有者每 30 秒续一次，过期 60–90 秒后别的进程才能接手。几个进程、几个容器（dashboard 容器也挂着同一个卷）同时加载了插件时，靠它保证只有一个在调 API。
- **不靠判断「我是不是 gateway」：**
  - `register()` 时分不出来（插件 README 的限制 2）；
  - `gateway.status.get_running_pid()`（`gateway/status.py:1953`，在插件可用的公开接口里）能拿来比 PID，但插件加载和 gateway 写 PID 文件谁先谁后没核实，跨容器比 PID 也不可靠。

更简单的做法，是和推送线程一起等第一次 `sync.state` 再起。代价是：gateway 重启后，Mac 没连上之前不轮询。

### 1.4 一条状况怎么映射成我们的结构

**LineStatus**（每条要盯的线路一份，存当前的，另记变化历史）：

| 字段 | 类型 | 说明 | 从 API 的什么来 |
| --- | --- | --- | --- |
| `line` | string | 线路 id：`<来源>:<API 里的 id>`，比如 `my_api:JR-East.ChuoRapid`。不另建对照表；通勤助手排行程时用同一个 id | API 的线路 id |
| `line_name` | string | 显示用的名字，照 API 给的日文，比如「中央線快速」 | 线路名 |
| `operator` | string \| null | 「JR東日本」 | 运营者 |
| `status` | 见下表 | 归成六种之一 | 状态字段，或从原文里认 |
| `delay_minutes` | int \| null | 延误几分钟。API 不给、原文里也认不出时是 `null`，界面只写「延误」 | 延误分钟字段；或者原文里的「約15分」「最大20分」 |
| `section` | `{from, to}` \| null | 受影响的区间，`null` 是整条线 | 区间字段 |
| `direction` | string \| null | 「上り」「下り」，`null` 是两个方向 | 方向字段 |
| `cause` | string \| null | 「人身事故」「車両点検」 | 原因字段 |
| `text` | string | 原文，通知和详情里显示 | 说明文字 |
| `resume_at` | 时间 \| null | 预计什么时候恢复 | 恢复预计 |
| `issued_at` | 时间 \| null | 这条信息是什么时候发的 | 发布时间 |
| `source_updated_at` | 时间 \| null | 数据源最后一次更新的时间 | 数据时间 |
| `fetched_at` | 时间 | 插件取到的时间 | 插件填 |
| `source` | string | `my_api` | 插件填 |

时间照插件现有的约定：ISO 8601，带设置时区的偏移（`hermes-plugin/README.md`「时间和日期」）。API 给的时间没带时区，就按 `Asia/Tokyo` 理解。

```json
{
  "line": "my_api:JR-East.ChuoRapid", "line_name": "中央線快速", "operator": "JR東日本",
  "status": "delayed", "delay_minutes": 15,
  "section": {"from": "新宿", "to": "三鷹"}, "direction": null, "cause": "人身事故",
  "text": "中央線快速電車は、荻窪駅で発生した人身事故の影響で、新宿～三鷹駅間の上下線に遅れが出ています。",
  "resume_at": null,
  "issued_at": "2026-11-09T07:41:00+09:00", "source_updated_at": "2026-11-09T07:43:00+09:00",
  "fetched_at": "2026-11-09T07:43:12+09:00", "source": "my_api"
}
```

**status 的六种**（你的 API 用哪些词，没核实）：

| `status` | 意思 | 常见的原文 |
| --- | --- | --- |
| `normal` | 正常运行 | 平常運転、平常どおり運転 |
| `delayed` | 还在开，但有延误 | 遅延、遅れ、ダイヤ乱れ |
| `partial` | 部分区间停运、折返运行、直通中止 | 一部運休、折返し運転、直通運転中止 |
| `suspended` | 停运 | 運転見合わせ、運休 |
| `resumed` | 刚恢复，可能还乱 | 運転再開 |
| `unknown` | 取到了，但认不出 | 其他；原文照样存 |

严重程度从轻到重：`normal`、`resumed`、`delayed`、`partial`、`suspended`。`unknown` 不参与比较，界面照原文显示。

**什么算「变了」**（这时才加 revision、才推送）：
- `status` 变了；
- `delay_minutes` 变了 5 分钟以上，或者从有变成没有、从没有变成有；
- `section` 或 `resume_at` 变了；
- 数据源从取得到变成取不到，或者反过来。

只有原文的措辞或时间戳变了，不算：照样存下最新的原文，但不加 revision、不推送，不然每次轮询都会推一次。

每次真的变化，另记一条带编号的变化记录，保留 7 天，写明是哪条线、变好还是变差、影响哪几趟行程。App 按编号决定发不发通知（5.3），通勤助手也能读。

### 1.5 要你提供的信息

| 要的信息 | 用来做什么 |
| --- | --- |
| 接口地址和文档 | 拼请求 |
| 正常、延误、停运、恢复时各一段真实返回（去掉 key） | 定映射；先用录下来的返回在 CI 上把整条链路跑通，不用真 key |
| 认证：key 放请求头还是查询参数、头叫什么；会不会过期，怎么换 | 写适配器，定 key 文件的格式 |
| 频率限制：每分钟、每天能调几次，超了回什么 | 定轮询间隔和退避 |
| 使用条款：个人使用、在自己的服务器上缓存、转给自己的 App 显示，允不允许 | 有的数据源只许特定用途用，比如第 7 节的 ODPT 比赛数据 |
| 更新：数据源多久更新一次；事件发生后，大概多久能在 API 上读到；有没有有效期、ETag、Last-Modified | 2.1 的第一段；能不能发条件请求 |
| 覆盖：有哪些线路（中央線快速、井の頭線、京王線……）；有没有区间、方向、延误分钟、原因、预计恢复、振替輸送 | 哪些字段能直接填，哪些只能从原文里认 |
| 线路和车站的 id、名字；有没有列出线路的接口 | `line` 怎么写；通勤助手排行程时用同一套 id |
| 轮询还是推送：有没有 webhook、SSE 或 WebSocket；webhook 有没有签名（HMAC），从哪些 IP 发，失败会不会重试 | 2.5 |
| 出错：有没有维护时段，错误长什么样 | 分清「取不到」和「正常」 |
| 要不要登记调用方的 IP | 容器出网（3.2） |

## 2. 能多快反应

### 2.1 每一段要多久

| 段 | 多久 | 依据 |
| --- | --- | --- |
| 数据源：事件发生，到 API 上能读到 | 没核实，要问你的数据源。公开的运行信息一般要几分钟 | |
| 轮询：API 上有了变化，到插件取到 | 平均是间隔的一半，最坏是一个间隔。60 秒一次时，平均 30 秒，最坏 60 秒 | 1.2 |
| 请求本身 | 一般几百毫秒，最长 10 秒（超时） | 没核实 |
| 判断、写库 | 毫秒级 | 本地 SQLite（`hermes-plugin/shion/store.py`） |
| 推送线程发现 revision 变了 | 不超过 1 秒 | `shion-change-watcher` 每秒看一次（`hermes-plugin/shion/plugin.py:58`、`watcher.py`） |
| 广播给每条 `/api/ws` 连接，经 Cloudflare Tunnel 到 Mac | 一般不到 1 秒，看 VPS 到 Mac 的线路 | 直接写给每条连接（`tui_gateway/server.py:632-648`）；线路延迟没核实 |
| App 收到后取一次 `commute.get` | 一次 RPC 来回 | 和现在一样，收到推送只重取 `topics` 里的那几样（`macos/Shion/Model/AppStore+Plugin.swift:45`） |
| 显示，发系统通知 | 立刻 | `UNUserNotificationCenter` |

合起来，按 60 秒轮询算：数据源更新之后，App 上看到、发出通知，平均约 30 秒，最坏约 63 秒。改成 30 秒轮询的话，平均约 15 秒，最坏约 33 秒。

推送丢了怎么办。现在的做法，`commute` 照用：
- 推送是全局事件，不进任何重放记录，断线期间的会丢（插件 README 的限制 1）；
- App 重连后先 `sync.state`，有差别再 `changes.since` 补上（`macos/Shion/Model/AppStore.swift:579-590`）；此外每 5 分钟补一次（`AppStore+Plugin.swift:70`）；
- App 每 15 秒发一次 `gateway.ping`，45 秒收不到任何帧就当连接断了（`macos/Shion/Gateway/Gateway.swift:352-354`），然后隔 1、2、4、8、15 秒重连（`Gateway.swift:368`）。所以最坏的情况，线路悄悄断了，要等约 45 秒，再加上重连的时间，才补得上。

### 2.2 对比：让助手用 cron 定时查

| | 插件的轮询线程 | 助手的 cron（调模型） | cron 的 `no_agent` 脚本 |
| --- | --- | --- | --- |
| 最短间隔 | 自己定，建议 30–300 秒 | gateway 每 60 秒 tick 一次；间隔按整分钟算，最短 `every 1m` | 同左 |
| 每次花什么 | 一次 HTTP 请求 | 新起一个助手会话，调一次模型：要几十秒，还花 token（具体多久没核实） | 起一个子进程，不调模型 |
| 结果去哪 | 直接写进插件的库，1 秒内推到 App | 要靠助手再调插件的工具写库 | stdout 原样发到消息平台（Telegram 等），写不进插件的库 |
| 只在通勤时段 | 按行程算 | 得写成 cron 表达式，行程变了就要改任务 | 同左 |

核实过的：
- 内置的调度器是「Default in-process 60s ticker」（`cron/scheduler_provider.py:430-439`）。gateway 启动它时不传 `interval`（`gateway/run_bootstrap.py:410-441`），用户文档也写着每 60 秒 tick 一次（`website/docs/user-guide/features/cron.md:423`）。
- 间隔按分钟存。`every 30m`、`2h` 这类写法换算成分钟（`cron/jobs.py:674-686` 的 `parse_duration`），存成 `{"kind": "interval", "minutes": n}`（`:784`），所以最短能写 `every 1m`。没看到下限检查。
- 每次运行是一个新的会话（`cron.md:20`）。`no_agent=True` 时只跑脚本，stdout 原样投递，不碰模型（`cron.md:979-997`）。

所以 cron 适合一天几次、要动脑的事：每天晚上排明天的行程，出门前 30 分钟看一眼要不要改线。分钟级的盯状况交给插件。

### 2.3 插件里跑后台线程：现有做法和限制

- **在哪些进程里跑**：`register(ctx)` 在每个加载插件的进程里都会跑（gateway、看板 worker、命令行），插件分不出自己是哪一种（插件 README 的限制 2）。
- **用普通线程**：`ctx.spawn_task(coro)` 起的是 Hermes 托管的 asyncio 任务，卸载插件时会被取消，但它要求当时有正在运行的事件循环（`hermes_cli/plugins_context.py:232-242`），而 `register()` 时没有（插件 README 的限制 2）。所以插件用普通的 daemon 线程。
- **卸载时停下**：用 `ctx.on_unload(callback)` 登记清理（`plugins_context.py:223-230`）。现有插件就是这样停推送线程的（`hermes-plugin/shion/plugin.py:83`），轮询线程也要登记。
- **按名字去重**：一个 gateway 进程里，每个 profile 各加载一份插件，各有各的 `ctx`，所以线程要按名字去重（`watcher.py:32-45`）。
- **RPC 不跑在事件循环上**：插件 RPC 的处理函数在 gateway 的 turn 线程池里跑（`gateway/session_plugin_rpc.py:19-24`）。`commute.get` 只读库，要快，不要在 RPC 里同步去调你的 API。
- **后台线程没有会话上下文**：调用方的会话不会跟进插件自己起的线程（`website/docs/user-guide/features/plugins.md:1099`），profile 的密钥作用域也一样不跟过去。3.5 的 key 读法就是因为这个。
- **异常自己兜住**：线程里所有异常都要接住，一次失败不能让线程退出。现有推送线程的 `_safe` 就是这么做的（`watcher.py`）。

### 2.4 推送在 `plugins.isolation` 不同取值下

只有两个取值：`in_process` 和 `host`（`hermes_cli/plugin_isolation.py:30-32`）。

| `plugins.isolation` | 插件跑在哪 | `broadcast_plugin_event`，也就是 `plugin.shion.changed` | `emit_to_session` |
| --- | --- | --- | --- |
| `in_process`（默认） | gateway 进程里 | 发给这个进程里所有在 `gateway.ready` 之后登记过的 `/api/ws` 连接（`tui_gateway/ws.py:656-671`、`tui_gateway/server.py:618-648`） | 能用 |
| `host` | 每个 profile 一个插件宿主进程（`hermes_cli/plugin_isolation.py:1-17`） | 宿主进程里没有登记过的连接，广播直接丢掉，只记一条 debug 日志（`tui_gateway/server.py:638-642`）。宿主只把会话事件转回 gateway（`hermes_cli/plugin_host_child.py:627-628`） | 能用，转回 gateway 发（`hermes_cli/plugin_host.py:438-457`） |

- `host` 模式下，插件的 RPC 处理函数也在宿主里跑，推送线程就会起在宿主进程里，照样发不出去。所以和插件 README 写的一样，要保持 `in_process`。
- `host` 模式下 `emit_to_session` 能用，但它只发给正在看某个会话的客户端。Shion 不一定正开着那个会话，代替不了全局推送。
- 广播按进程投递：gateway 之外的进程（命令行、看板 worker）里没人收（`hermes_cli/plugin_events.py:21-27`）。轮询器在别的进程里写了库也没关系，gateway 里的推送线程会发。

### 2.5 你的 API 能推送的话

- **Hermes 自带 webhook 适配器。** 它是一个单独的 HTTP 服务，默认端口 8644，地址是 `/webhooks/<route>`，按 HMAC 签名校验（`website/docs/user-guide/messaging/webhooks.md:9,31,53-54,82`）。每条路由可以选：
  - `deliver_only: true`：不调模型，把模板渲染成消息直接发到 Telegram 等（`:91`）；
  - `cron_job`：触发一个 cron 任务，可以是 `no_agent` 脚本（`:92`）；
  - `script`：先用脚本处理一遍收到的内容（`:206`）。
- **要让推送进插件的库**，路径是：webhook 路由 → `cron_job` 指向一个 `no_agent` 脚本 → 脚本调插件提供的一个小命令写库 → 推送线程 1 秒内发出。能做，但环节多，整条链路没核实。
- **插件自己的 HTTP 路由不合适。** `/api/plugins/shion/...` 在 dashboard 的认证后面，没登录的请求直接回 401（`website/docs/user-guide/features/extending-the-dashboard.md:750`）。数据源一般带不了 Hermes 的凭证。
- **还要过 Cloudflare。** 不管走哪条路，请求都要先过 Cloudflare Tunnel 和 Access：要么数据源能带上 service token 的两个头，要么在 Access 里给这一条路径单独开 Bypass，再靠 HMAC 校验。
- **好处**：省掉轮询间隔（2.1 的第二段），从数据源发出到 Mac 上大约几秒。

建议先上轮询。有了真实的延迟数据，再决定要不要做推送。

## 3. Hermes 是容器版

### 3.1 进程和容器

- **Hermes 自带的 compose** 起两个容器：`gateway`（`gateway run`）和 `dashboard`（`docker-compose.yml:29-72`）。
  - 两个都把 `~/.hermes` 挂到 `/opt/data`，都设了 `restart: unless-stopped` 和 `network_mode: host`。
  - 镜像里 `HERMES_HOME=/opt/data`（`Dockerfile:501`），`/opt/data` 是卷（`:550`）。
  - 容器里的 PID 1 是 s6-overlay，gateway 是它管的一个服务。
- **一个 gateway 进程服务所有 profile**：`gateway.multiplex_profiles` 默认是 `true`（`hermes_cli/config_defaults.py:2091,2160`）。
- **轮询线程在 gateway 容器里跑。** dashboard 容器也加载插件的话，靠租约（1.3）保证不会重复调。dashboard 进程会不会跑普通插件的 `register()`，没核实。
- **你的容器不一定用这份 compose**，网络、端口、卷可能都不一样，要看实际的 compose 或 `docker inspect`。

### 3.2 出网

- 容器要能访问你的 API（HTTPS）。
  - 自带的 compose 用宿主的网络，宿主能出网就行。
  - bridge 网络默认也能出网，但宿主的防火墙、云厂商的安全组可能挡着出站。
- 镜像装了 `ca-certificates`（`Dockerfile:81`），HTTPS 证书校验没问题。要走代理的话，`urllib` 认 `HTTPS_PROXY`。
- API 要登记调用方 IP 的话，登记 VPS 的公网出口 IP。Cloudflare Tunnel 只管进来的请求，和出去的无关。
- 在服务器上检查：`docker exec hermes curl -sS -o /dev/null -w '%{http_code}\n' https://<你的 API 地址>`。

### 3.3 时区

- **插件不受容器时区影响。** 自带的 compose 没设 `TZ`，容器里默认是 UTC。插件的时间按 UTC 存，「今天」、通勤时段和显示的时间都按设置里的 `timezone`（默认 `Asia/Tokyo`）算（`hermes-plugin/shion/timeutil.py`），所以容器是不是 UTC 都一样。
- **要有 IANA 时区库。** Python 的 `zoneinfo` 读的是 `/usr/share/zoneinfo`，或者 `tzdata` 这个包。
  - Hermes 的 Dockerfile 没有单独装 `tzdata`（`Dockerfile:81` 的 apt 列表）；Python 依赖里的 `tzdata` 只在 Windows 上装（`pyproject.toml:117-122`）。
  - Debian 的 `python3` 一般会把 tzdata 带进来，但没核实。
  - 在服务器上查一次：`docker exec hermes /opt/hermes/.venv/bin/python -c "import zoneinfo; print(zoneinfo.ZoneInfo('Asia/Tokyo'))"`。
  - 要是没有，**现有插件的大多数方法都会报错**（`hermes-plugin/shion/timeutil.py` 的 `zone` 把不认识的时区当成参数错误），这和通勤无关，现在就该查。实装时，插件对 `Asia/Tokyo` 退回固定的 +09:00（日本没有夏令时）。
- **助手的时间另算。** 助手的 cron 和它眼里的「现在几点」，按 `HERMES_TIMEZONE` 或 profile 的 `config.yaml` 里的 `timezone`，两个都没有就用服务器本地时间（`hermes_time.py:1-5`），容器里就是 UTC。通勤助手的 cron 要按东京时间写的话，在它的 profile 里设 `timezone: Asia/Tokyo`。

### 3.4 容器重启后怎么恢复

- **会被拉起来**：gateway 挂了由 s6 拉起；容器停了，按 `restart: unless-stopped` 重启。
- **数据都在卷里**：容器的根文件系统每次重启都重置（`Dockerfile:78` 的注释），只有 `/opt/data` 里的东西留着。插件装在 `/opt/data/profiles/<名字>/plugins/`，数据在 `/opt/data/plugin-data/shion/`，都在卷里。
- **轮询器接着来**：它的状态全在 SQLite 里，有行程、每条线路上一次的状况、上一次成功的时间、退避到了哪一步、租约。
  - 重启后第一次取到的结果和库里的比，没变就不推送，也就不会重复通知。
  - 停机期间变了的，第一次轮询就补上，只算一次变化。
  - 停机期间变了又变回去的，会漏掉。
- **租约要等过期**：旧进程没来得及放掉的租约，过期后（60–90 秒）新进程才接手，所以重启后最多晚一分多钟开始轮询。可以在租约里记下容器的主机名和进程的启动时间：同一个容器里新起的进程认出旧主人已经不在，就马上接手。
- **推送线程等 Mac 来**：按现在的设计，它要等 Mac 重连后的第一次 `sync.state` 才起。Mac 会自己重连，并调 `sync.state` 和 `changes.since`（`macos/Shion/Model/AppStore.swift:579-590`），停机期间的变化这时补上。
- **通知不重复**：App 按变化记录的编号发通知，同一条只发一次（5.3），所以重启、重连都不会重复。

### 3.5 数据和 key 放在卷里

- **数据库**：`/opt/data/plugin-data/shion/shion.db`。插件用的是 `get_default_hermes_root()/plugin-data/shion`（`hermes-plugin/shion/plugin.py`），容器里这个根目录就是 `/opt/data`，对应宿主上的 `~/.hermes/plugin-data/shion/`。也可以用 `SHION_DATA_DIR` 指到别处，但要在卷里。
- **卷要在本机磁盘上**：SQLite 开的是 WAL，要求文件在本机文件系统上。bind mount 的本地目录没问题，NFS、SMB 这类网络盘上不行。你的卷是哪种，没核实。
- **备份**：照插件 README，用 `sqlite3 shion.db ".backup …"`。
- **key 单独放一个文件**，比如 `/opt/data/plugin-data/shion/commute-source.json`：
  - 权限 0600，属主是容器里的 `hermes` 用户（`HERMES_UID`，自带的 compose 里默认 10000，`docker-compose.yml:39`）；
  - 插件每次轮询前读一次，换 key 不用重启；文件不在就不轮询，`commute.get` 里写 `source.state: "off"`。

  ```json
  {"base_url": "https://api.example.jp/v1", "auth": {"header": "X-API-Key", "key": "…"},
   "interval_seconds": 60}
  ```
- **为什么不放环境变量或 `.env`：**
  - 默认开着 profile 复用（上面的 `gateway.multiplex_profiles`）。这时 profile 的 `.env` 不会并进进程的环境变量，要用 `get_secret()`，在这个 profile 的密钥作用域里读。后台线程没有作用域，`get_secret()` 直接抛错，不会退回去读环境变量（`agent/secret_scope.py:1-10,230-262`）。
  - 放进容器的环境变量（compose 里的 `environment:`），助手的 terminal、execute_code 子进程会继承下去。Hermes 只按名单剥掉它自己认识的密钥（`tools/environments/local.py:343-347`、`local_env_policy.py:412-418`），不认识的名字照样传，助手 `printenv` 就能看到。
- **文件也挡不住助手。** 默认的 local 后端下，所有助手都是同一个 Unix 用户（`docs/files-and-images.md` 第 3.2 节），它们的工具能读卷里的任何文件，Hermes 自己的 `.env` 也一样。现在的部署都是这样；要隔开，得把助手换成 docker 后端，每个助手一个沙盒。
- **key 只发给你的 API**：适配器只认 `base_url` 那个 host，跳转到别的 host 时不带 key。
- **key 不进 App**：App 只从 `commute.get` 拿整理好的结果，看不到 key，也看不到原始返回。

## 4. 数据：行程和 `commute.get`

**行程**（Trip）由通勤助手写，一天几趟：

```json
{
  "id": "2026-11-09-am", "date": "2026-11-09", "label": "上学",
  "from": "吉祥寺", "to": "新宿",
  "leave_at": "2026-11-09T08:00:00+09:00", "arrive_at": "2026-11-09T08:47:00+09:00",
  "legs": [
    {"line": "my_api:Keio.Inokashira", "line_name": "井の頭線", "from": "吉祥寺", "to": "明大前",
     "depart_at": "2026-11-09T08:08:00+09:00", "arrive_at": "2026-11-09T08:25:00+09:00"},
    {"line": "my_api:Keio.Keio", "line_name": "京王線", "from": "明大前", "to": "新宿",
     "depart_at": "2026-11-09T08:29:00+09:00", "arrive_at": "2026-11-09T08:38:00+09:00"}
  ],
  "event": {"title": "数据结构与算法 第7回", "start": "2026-11-09T09:00:00+09:00", "place": "3号馆 201"},
  "advice": "中央線快速 延误约 8 分钟，改走 井の頭線 → 明大前 → 京王線，08:47 到新宿。",
  "planned_by": "commute", "updated_at": "2026-11-09T07:53:00+09:00"
}
```

- 盯哪几条线，由 `legs` 推出来；盯的时段是出门前 60 分钟到到达后 10 分钟。
- `advice` 是通勤助手写的一句建议，可以为空。

**RPC `commute.get`**（给 App）：返回今天（或给的日期）的行程、每条要盯的线路的状况、最近的变化记录、数据源的状态：

```json
{"date": "2026-11-09", "next": "2026-11-09-pm",
 "trips": [{"id": "2026-11-09-am"}, {"id": "2026-11-09-pm"}],
 "lines": {"my_api:JR-East.ChuoRapid": {"line": "my_api:JR-East.ChuoRapid", "status": "normal"}},
 "changes": [{"id": 31, "at": "2026-11-09T07:43:12+09:00", "line": "my_api:JR-East.ChuoRapid",
              "from": "normal", "to": "delayed", "worse": true, "trips": ["2026-11-09-am"]}],
 "source": {"name": "my_api", "state": "ok", "last_ok_at": "2026-11-09T10:51:40+09:00",
            "polling": false, "interval_seconds": 60},
 "revision": 52}
```

上面的 `trips`、`lines` 只写出了各自的 id、`status`，实际返回完整的行程（同上）和 LineStatus（1.4）。`source.state` 是 `ok`、`down`（连续失败）、`auth`（key 被拒）或 `off`（没配置）。

**给通勤助手的工具**（照现有工具的样子：返回 JSON 字符串，出错返回 `{"error": …}`，不让这一轮失败）：

| 工具 | 做什么 |
| --- | --- |
| `shion_commute_plan` | 写某一天的行程，整天替换 |
| `shion_commute_status` | 读每条线路现在的状况和最近的变化 |
| `shion_commute_advise` | 给某一趟写一句建议，可以带一条换乘方案和新的出门时间 |

**设置**：放在插件现有的设置里，全部 profile 共用（`settings.update`）：
- 轮询间隔；
- 出门前、到达后各盯多少分钟；
- 延误几分钟以上才通知；
- 没有计划时的默认时段和常坐的线路。

数据源的地址和 key 不放这里，放 3.5 说的文件里。

## 5. 分工

### 5.1 通勤助手（调模型，profile `commute`）

- **排行程。** 每天晚上用 cron 跑一次（比如 21:00）：
  - 读明天的日历（iCloud CalDAV），看每个事件的地点，定下几趟：家到学校、学校到实习的地方、回家……；
  - 查路线（它用哪个交通工具或 MCP，没核实；主 README 的「场景由谁负责」写的是「已有的交通 MCP」），按要到的时间往前推，留出余量，算出门时间；
  - 用 `shion_commute_plan` 写进插件。
  
  当天日历变了（加了课、换了地点），再排一次。
- **出异常时给建议。** 插件判断出某条线变差了，而且正在出门前的时段里，就叫醒通勤助手一次：
  - 它用 `shion_commute_status` 看情况，决定换不换线、几点出门，用 `shion_commute_advise` 写建议，需要时连行程一起改；
  - 同一趟、同一种状况只叫醒一次；
  - 叫醒一次就是一轮模型调用，一天也就几次，可以接受。
- **怎么叫醒。** 往通勤助手的 Bot Chat 里放一句「［通勤］中央線快速 延误约 15 分钟（人身事故），影响 08:00 出门的上学」。
  - 只能由通勤 profile 那份插件，用它自己的 `ctx.inject_message` 来放：插件不能往别的 profile 的会话里放消息（`website/docs/user-guide/features/plugins.md:1122`），而轮询线程不一定起在通勤那份插件里。所以轮询器把「要叫醒」记进库，由通勤那份插件看到后去叫。
  - 和专注检查叫醒詩音一样，通勤 profile 要开 `allow_gateway_injection`，而且它的 Bot Chat 要在 gateway 的活动会话里，否则会被拒（插件 README 的 `focus.report` 一节、限制 5）。
  - 被拒时 App 的通知照发，只是没有建议。
- **回答你的问题。** 比如「明天几点出门？」，照旧在它的 Bot Chat 里问，它用 `shion_commute_plan`、`shion_commute_status` 查。
- **不做分钟级的盯状况。**

### 5.2 插件（不调模型）

- 存行程、每条线路的状况，变化记录留 7 天。
- 通勤时段里轮询你的 API（第 1 节），判断有没有变（1.4）；变了就写库，加 revision（话题 `commute`），由推送线程推给 App。
- 线路变差、而且在出门前的时段里，叫醒通勤助手（5.1）。
- 提供 RPC `commute.get` 和给助手的工具（第 4 节）。
- 不发通知：Mac 上的通知是 App 的事，手机见 5.4。

### 5.3 App

**今天页的通勤卡片**（只显示下一趟）：
- 第一行：「上学 · 08:00 出门」、还有几分钟、几点到。
- 路线：吉祥寺 → 井の頭線 → 明大前 → 京王線 → 新宿。每条线后面写状况：
  - 正常：绿色；
  - 延误：暖橙，带分钟，比如「延误 15 分」；
  - 停运、部分停运：红色。
- 通勤助手写了建议，就多一行。
- 不正常时，整张卡片放进框里，因为要你拿主意（界面原则：只有要你动手的才放进框）；正常时就是普通的一节。
- 数据源取不到：用次要颜色写「运行信息暂时取不到 · 08:12 起」，不当成正常。

**菜单栏面板里的回程**：现在写死的「正常」（`macos/Shion/Views/MenuBar.swift:78`）换成真的状况；延误时用暖橙，带分钟。

**没连服务器，或插件里没有 `commute`**：照旧用示例数据。

**通知规则：**

| 什么时候 | 发什么 | 发几次 |
| --- | --- | --- |
| 出门前 N 分钟（默认 10） | 「该出门了 · 08:00 · 井の頭線 → 京王線」；状况不正常时带上状况 | 每趟 1 条。App 按行程自己排本地通知，不靠推送 |
| 出门前 60 分钟到出门：这趟要坐的线变差（正常变延误，延误变停运，延误多了 10 分钟以上） | 「中央線快速 延误约 15 分钟（人身事故）」；有建议就带上 | 每变差一次 1 条 |
| 同上，恢复正常 | 「中央線快速 恢复正常」 | 之前为这一趟发过异常，才发 1 条 |
| 通勤助手改了出门时间或路线 | 「改成 07:50 出门，走 井の頭線 → 京王線」 | 每改一次 1 条 |
| 路上（出门到到达） | 同上几条，只看还没坐的那几段 | 同上 |

- **合并、替换**：60 秒内的几次变化合成一条。同一趟用同一个通知 id（`commute-<行程 id>`），新的替换旧的，通知中心里只留最新的一条，和助手回复的通知一样（`macos/Shion/Support/Notifications.swift:92` 的 `reply-<botId>`）。
- **上限**：每趟最多 4 条，出门提醒不算在内。
- **不发：**
  - 延误不到 5 分钟（可以改）；
  - 只是原文的措辞变了；
  - 数据源取不到：只在卡片上显示，出门前 15 分钟内还取不到，才发一条；
  - App 在前台、今天页正开着：卡片上已经看得到了。
- **按编号去重**：每条变化有编号（第 4 节的 `changes`），App 记着发到了哪一条。重连、重启都不会重复发。
- **Mac 睡着又醒来**：补上之后，只为还没结束的行程发一条现在的状况，不把睡着期间的每一次变化都补发一遍。

### 5.4 路上：Mac 合着的时候

Mac 合着、睡着时，App 收不到推送，也发不了通知。路上多半就是这样，所以「路上也要通知」得靠手机。两个办法：

- **插件直接发，不调模型。** 插件在 gateway 里调 `send_message` 工具：`ctx.dispatch_tool("send_message", {"action": "send", "target": "telegram", "message": …})`（`hermes_cli/plugins_context.py:483-492`、`tools/send_message_tool.py:205-240`），发到通勤 profile 配好的 Telegram 等平台的默认会话（home channel）。没核实：从后台线程、没有会话的情况下调，能不能通过它的授权检查。
- **叫醒通勤助手时发到它的手机会话。** 用它在 Telegram 上那个会话的 `session_key`（或者 `origin`）调 `inject_message`，它的回复就发到手机上（`website/docs/user-guide/features/plugins.md:1104-1124`）。前提是那个聊天里你先发过一条消息；每次是一轮模型调用。

两种都要通勤 profile 先接上消息平台，现在还没接。接上之前，路上的通知只在 Mac 开着时才有。

## 6. 实装的工作量和分步（等你确认后再做）

| 步 | 内容 | 改哪些 | 怎么验证 |
| --- | --- | --- | --- |
| 0 | 你提供 1.5 的信息和几段真实返回 | 无 | 无 |
| 1 | 插件：<br>• 按你的 API 写适配器<br>• 存储、`commute.get`、工具<br>• 轮询线程和租约、设置<br>• 把录下来的返回做成测试用的数据源 | `hermes-plugin/shion/` 加 3–4 个文件；改 `store.py`（加话题）、`plugin.py`（起线程）、`rpc.py`、`tools.py`、`plugin.yaml`、插件 README；`tests/` 加测试。大约 600–900 行 Python，另加 400 行左右的测试 | 在 Linux 上跑 pytest，再跑插件的 CI |
| 2 | App：<br>• 通勤卡片、菜单栏的回程<br>• 通知规则<br>• 示例数据，包括延误时的样子<br>• 替身 `fake_commute.py`，加一个推一次延误的端到端测试 | `macos/` 加 `Model/Commute.swift`、`Model/AppStore+Commute.swift`、`Views/CommuteCard.swift`；小改 `TodayView`、`MenuBar`、`Notifications`、`AppStore+Plugin`；加 `ci/fake_commute.py`、`ShionUITests/CommuteTests.swift`，把测试加进 `macos.yml` 的测试循环。大约 600–900 行 Swift，再加 250 行左右的替身和 200 行左右的测试 | 截图（正常、延误各一组），端到端测试；macOS CI 跑 2–3 次 |
| 3 | 通勤助手：<br>• SOUL 里写清分工<br>• 晚上排行程、出门前检查的 cron<br>• `allow_gateway_injection` | 服务器上 profile 的配置（不在这个仓库里，以后可以放进助手模板） | 在 VPS 上跑一天看看 |
| 4（可选） | 手机通知（5.4）；你的 API 能推送的话做 webhook（2.5） | 插件、Hermes 配置、Cloudflare Access | 视选的路而定 |

第 1 步不依赖 App，可以先做；第 2 步要等第 1 步定下 `commute.get` 的格式。

## 7. 附：公开的数据源

之前查过一轮公开的数据源，记在这里供对照。如果你的 API 就是其中之一，1.4 的映射照样能用。

- **ODPT 上 JR 东日本和京王的运行信息只供比赛用。** 公共交通オープンデータセンター（ODPT）上，这两家的运行信息（`odpt:TrainInformation`）只在「公共交通オープンデータチャレンジ限定ライセンス」下提供。
  - JR 东日本的数据是经 JR東日本アイステイションズ 提供的。
  - 接口在 `api-challenge.odpt.org`，要用比赛发的 token（[JR 东日本](https://ckan.odpt.org/dataset/jr-train-status-information-by-jr-east-i-stations)、[京王](https://ckan.odpt.org/dataset/keio__r_train_status)的数据集页面，2026-11-09 查的）。
  - 这一届比赛从 2026-07-01 到 2027-03-12（[发布](https://prtimes.jp/main/html/rd/p/000000020.000146050.html)）。
  - 2020 年那一届的条款写明，用于应募比赛以外的目的不行（[引文](https://github.com/Tokyo-Metro-Gov/covid19/issues/2497)）。这一届的条文在开发者网站上，没取到原文。
- **東京メトロ、都営等在「公共交通オープンデータ基本ライセンス」下。** 要先注册开发者账号，拿 consumerKey（[東京メトロ的数据集](https://ckan.odpt.org/dataset/r_train_status-tokyometro)）。接口按惯例是 `api.odpt.org`，但数据集页面上没写，没核实。
- **ODPT 的字段**（[字段表](https://maru0123-2004.github.io/python-odpt/models/train_information.html)）：
  - 对应 1.4：`odpt:railway` 对 `line`，`odpt:trainInformationStatus` 对 `status`，`odpt:trainInformationText` 对 `text`，`odpt:trainInformationCause` 对 `cause`，`odpt:stationFrom` 和 `odpt:stationTo`（或者文字的 `odpt:trainInformationRange`）对 `section`，`odpt:resumeEstimate` 对 `resume_at`，`odpt:timeOfOrigin` 对 `issued_at`，`dc:date` 对 `source_updated_at`；
  - `odpt:trainInformationStatus` 按规范是平常运行时不给，但有说法是并非每家都照这个来，没核实；
  - 另有 `dct:valid`（有效期），可以拿来定下一次什么时候取。2020 年的一个例子里，它比 `dc:date` 晚 5 分钟（同上的引文）。

## 8. 没核实的地方

1. 你的 API 的一切（1.5）：字段、认证、频率限制、使用条款、更新延迟、能不能推送。
2. 数据源从事件发生到 API 上能读到要多久（2.1 的第一段）。
3. 从 VPS 经 Cloudflare 到 Mac 的线路延迟（2.1）。
4. cron 每次调模型的运行要多久、花多少（2.2）；`every 0m` 会怎样（没看到下限检查）。
5. 镜像里有没有 IANA 时区库（3.3）。缺的话，现有插件也会出问题。
6. dashboard 容器会不会跑普通插件的 `register()`；插件加载和 gateway 写 PID 文件谁先谁后（1.3、3.1）。
7. 从后台线程调 `send_message`，能不能通过它的授权检查（5.4）。
8. webhook → cron → `no_agent` 脚本 → 写库这条链路（2.5）。
9. 你的容器是不是用 Hermes 自带的 compose：网络模式，卷是不是本机目录（3.1、3.2、3.5）。
10. 通勤助手排路线用的是哪个交通工具或 MCP（5.1）。
11. 叫醒通勤助手时，它的 Bot Chat 不在活动会话里会被拒，具体什么时候在、什么时候不在，照专注检查的经验推的，没在通勤 profile 上试过（5.1）。
