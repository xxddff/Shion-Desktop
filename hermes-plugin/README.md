# shion 插件（Hermes 服务器端）

Shion 的数据都存在这个 Hermes 插件里：待办、「今天」页顶部的一段话、日报、应用使用记录、专注检查的结论。所有助手经插件的**工具**读写，Shion 经插件 **RPC**（`plugin.shion.<名字>`，走 `/api/ws`）读写，看到的是同一份。

依据 Hermes `main`（2026-11-09，`8c1a9c0b`）的代码：`hermes_cli/plugin_rpc.py`、`hermes_cli/plugins_context.py`、`hermes_cli/plugins_injection.py`、`hermes_cli/plugin_events.py`、`gateway/session_plugin_rpc.py`、`gateway/session_controls.py`、`gateway/run_plugin_injection.py`。文档和代码对不上的地方以代码为准，下文会注明。

```
hermes-plugin/
  shion/            插件本体（装到服务器上的就是这个目录）
    plugin.yaml     清单
    __init__.py     register(ctx)
    plugin.py       接到 Hermes：RPC、工具、钩子、专注检查叫醒、推送
    rpc.py          RPC 方法
    tools.py        给助手的工具（schema 和处理函数）
    store.py        SQLite 存储（不依赖 Hermes）
    watcher.py      revision 变了就推送
    timeutil.py     时区、日期
  tests/            pytest，不装 Hermes 也能跑
```

## 安装到服务器

> Hermes 跑在容器里时（用户的服务器就是），下面的 `hermes …` 命令都在容器里执行，比如 `docker exec -it <容器名> hermes -p shion plugins list`；插件目录和数据目录要在挂载的卷里，容器重建后才还在。

**安装和启用都是按 profile 的。** 这是 Hermes 本身的设计，不是这个插件特有的：

- 插件目录是 `<profile 目录>/plugins/`（`hermes_cli/plugins_cmd.py` 的 `_plugins_dir`、`plugins_discovery.py`），默认 profile 是 `~/.hermes`，其他的在 `~/.hermes/profiles/<名字>`；
- 每个 profile 有自己的插件管理器（`hermes_cli/plugins.py` 的 `get_plugin_manager`，按 profile 目录缓存），`plugins.enabled` 写在各自的 `config.yaml` 里；
- 官方 Desktop 的「插件」页有 profile 选择器，插件的 Agent 部分跟着它走：装、开关都是对选中的那个 profile（`apps/desktop/src/app/capabilities/plugins/plugins-tab.tsx`）。网页 dashboard 的安装（`/api/dashboard/agent-plugins/install`）只装进 dashboard 自己那个 profile；
- 没有「装一次、所有 profile 共用」的办法。pip 的 entry point 插件虽然在共用的 venv 里，但 Hermes 的文档说受 PM 管理的安装不要这样装（PM 换一代环境时它会消失）；
- 例外：用 `hermes profile create --clone` 之类从一个 profile 复制出新 profile 时，`plugins/` 和 `plugins.enabled` 会跟着复制过去（`hermes_cli/profiles.py` 的 `_clone_plugins`）。

所以詩音和五个助手的 profile 都要装、都要启用。助手要用插件的工具，詩音的 profile 还要处理 Shion 的 RPC。

**1. 每个 profile 装一次（顺便启用）。** 仓库是私有的也能装：Hermes 先匿名 clone，被拒后依次试 `GITHUB_TOKEN` / `GH_TOKEN`（profile 的 `.env` 里的）、`gh auth token`、git 配好的凭证助手，凭证只放在这次 clone 的请求头里，不写进 URL 也不留在 `.git/config`（`hermes_cli/git_credentials.py`）。所以先在服务器上 `gh auth login`，或者给每个 profile 的 `.env` 写一个只读这个仓库的 fine-grained token，然后：

```bash
for p in shion study commute mail news journal; do
  hermes -p $p plugins install xxddff/Shion-Desktop/hermes-plugin/shion --enable
done
```

`owner/repo/子目录` 是 Hermes 认的写法，装出来的目录名取子目录的最后一段，正好是 `shion`。不用 git 的话，也可以把 `hermes-plugin/shion` 整个复制到每个 profile 的 `plugins/shion/`，再做第 2 步。

Shion 连接所在的那个 profile（通常是默认 profile `~/.hermes`）不用装，只要 Mac 端按下面「调用方式」给每次调用带上 `profile`。

**2. 每个 profile 都启用。** 第 1 步带了 `--enable` 就已经启用了。手动复制的，或者装的时候没启用的：

```bash
for p in shion study commute mail news journal; do hermes -p $p plugins enable shion; done
```

**3. 詩音的 profile 允许插件叫醒她。** 专注检查要用 `ctx.inject_message` 往詩音的 Bot Chat 里放一句话，Hermes 默认拒绝。只在 `shion` 这个 profile 的 `config.yaml`（`~/.hermes/profiles/shion/config.yaml`）里加：

```yaml
plugins:
  enabled:
    - shion            # 第 2 步已经写上
  entries:
    shion:
      allow_gateway_injection: true
```

代码里读的是 `plugins.entries.shion.allow_gateway_injection`，必须是 `true`（布尔值，不是字符串），读的是插件自己那个 profile 的配置（`PluginContext._gateway_injection_allowed`）。其他助手的 profile 不用开。

**4. 不用改别的配置。** 插件的工具集叫 `shion`：没用 `hermes tools` 存过工具选择的 profile，插件工具集默认就开着；存过的，`plugins enable` 会把它加回去（见 Hermes 用户文档的插件一节）。`plugins.isolation` 保持默认的 `in_process`（原因见「限制」）。

**5. 重启 gateway。** `hermes plugins enable` 会通知正在运行的 gateway 重新扫描插件，RPC 和钩子马上生效，但工具要到下一个会话才出现，而且已经在跑的 Bot Chat 不会换工具表。所以装完、更新完都重启一次：

```bash
hermes gateway restart
```

**6. 检查。**

```bash
hermes -p shion plugins list          # shion 是 enabled
hermes -p shion plugins doctor shion  # 用 Hermes 自己的发现和注册流程跑一遍
```

再从 Shion（或任何 `/api/ws` 客户端）调 `plugin.shion.info`，带 `profile: "shion"`，应该返回版本和今天的日期。

**更新**：`for p in shion study commute mail news journal; do hermes -p $p plugins update shion; done`（手动复制的就重新复制），再重启 gateway。数据不在插件目录里，更新不会丢。

## 数据存在哪

- 一个 SQLite 文件：`<Hermes 根目录>/plugin-data/shion/shion.db`，Hermes 根目录一般是 `~/.hermes`，也就是 `~/.hermes/plugin-data/shion/shion.db`。根目录用的是 `hermes_constants.get_default_hermes_root()`，不随 profile 变，所有 profile 共用一份。看板也是这样共用的（`hermes_cli/kanban_db.py` 的 `kanban_home`）。Hermes 给插件的 `plugin_data_dir()` 和 `ctx.state` 是按 profile 分开的，所以没用。
- 要放到别处，在启动 gateway 的环境里设 `SHION_DATA_DIR=<目录>`（文件名还是 `shion.db`）。看板的 worker 是 gateway 起的子进程，继承同样的环境，所以一处设好就行；手动跑的 `hermes -p … chat` 也要带上同样的值。
- WAL 模式，可以多个进程同时读写：gateway 里的助手对话、Shion 的 RPC、看板 worker（它们是单独的 `hermes -p <profile> chat -q` 子进程）都直接开这个文件。
- 备份：停掉 gateway 后复制 `shion.db`，或者不停机用 `sqlite3 shion.db ".backup /path/to/backup.db"`。
- 保留：应用使用记录默认 30 天，专注检查记录默认 7 天，变更记录（给 `changes.since` 用）7 天；待办、今天的汇总、日报一直保留。
- 不存窗口标题，也存不了：`usage.upload` 和 `focus.report` 遇到多余的字段直接报错。不存任何令牌或密码，日志里也不写。

## 设置

设置存在数据库里（所有 profile 共用），不在 `config.yaml`。用 `settings.get` / `settings.update` 读写。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `timezone` | `Asia/Tokyo` | IANA 时区名。决定「今天」是哪天、没带时区的时间怎么理解、返回的时间带什么偏移 |
| `usage_retention_days` | `30` | 应用使用记录保留天数，1–365 |
| `focus_retention_days` | `7` | 专注检查记录保留天数，1–90 |
| `chief_profile` | `shion` | 总秘书的 profile：专注检查叫醒谁 |

## 约定

### 调用方式

```json
{"jsonrpc": "2.0", "id": 12, "method": "plugin.shion.todos.list",
 "params": {"profile": "shion", "status": "open", "date": "2026-11-09"}}
```

- **先确认服务器支持**：`runtime.describe` 的 `capabilities` 里要有 `plugin-rpc-v1`。有它时，`-32601` 表示这个 profile 没加载 shion 插件（没装、没启用，或者方法名拼错）；没有它就当插件 RPC 不可用。
- **每次都带 `profile: "shion"`。** Hermes 按 `params.profile` 把调用转给那个 profile（`gateway/session_controls.py` 的 `_sibling_for`），插件的处理函数在那个 profile 里运行；不带就是连接本身的 profile。插件只装在助手们的 profile 里，所以要带。`focus.report` 必须在 `chief_profile` 里运行，其他方法在哪个装了插件的 profile 都一样（数据是同一份）。连接只绑定一个 profile 时，Hermes 对别的 `profile` 回 `profile_mismatch`；Shion 打开各助手的 Bot Chat 用的也是这条路，能打开就能调。
- **`session_id` 只有 `focus.report` 要带**：詩音 Bot Chat 的会话 id。带了 `session_id` 的调用，Hermes 会先按这个会话检查权限（是不是这个 profile 的、是不是你的会话）。其他方法不要带（带了也只是多一次检查）。
- `profile`、`session_id` 由 Hermes 留在 params 里，插件忽略它们。除此之外，不认识的参数一律报 `invalid_params`。
- 连接要有 `session:control` 能力（Hermes 对插件方法的要求，同插件斜杠命令），Shion 的登录凭证和会话令牌都有。
- 每次调用占着这个连接的请求通道直到返回。这里的方法都只读写本地 SQLite，很快。

### 错误

插件抛出的错误，Hermes 一律回 `4001`：

```json
{"jsonrpc": "2.0", "id": 12, "error": {"code": 4001, "message": "plugin_rpc_failed",
  "data": {"reason": "plugin_rpc_failed", "field": "plugin.shion.todos.get",
           "detail": "ShionError: not_found: no todo 'td_x'"}}}
```

`data.detail` 是 `ShionError: <错误码>: <说明>`，用 `^ShionError: ([a-z_]+): (.*)$` 取出错误码：

| 错误码 | 什么时候 |
| --- | --- |
| `invalid_params` | 参数缺了、多了、类型或取值不对；`detail` 里的说明写着是哪个参数 |
| `not_found` | 按 id（或日期加种类）找不到 |
| `conflict` | `todos.add` 带的 `id` 已经有一条内容不同的待办 |

`detail` 不是以 `ShionError:` 开头的，是插件内部出错（比如数据库打不开），当作服务器错误处理、稍后重试。Hermes 自己的错误照常：`-32601`（插件没加载）、`4001 permission_denied`、`4001 profile_mismatch` 等。

### 时间和日期

- **时间**：ISO 8601，返回时总是带设置里时区的偏移，精确到秒，比如 `2026-11-09T10:45:00+09:00`。传进来的时间带偏移（或 `Z`）就照用；不带偏移，按设置的时区理解。Mac 端请总是带偏移。只给日期（`2026-11-10`）当时间用会被拒绝。
- **日期**：`YYYY-MM-DD`，指设置时区里的那一天（`date`、`from`、`to`）。「今天」也按这个时区算，可以从 `info` / `sync.state` 的 `today` 拿到。
- 时间在库里按 UTC 存，所以改了时区，已有的时间不变，只是显示的偏移和「哪一天」跟着变。

### revision

每次写入（真的改了东西的）都让全库的 `revision` 加一，并记下改了哪些**话题**：`todos`、`today`、`reports`、`usage`、`focus`、`settings`。写入方法的返回里带着写完后的 `revision`。推送和 `changes.since` 都靠它，见「推送」。

## 数据格式

### Todo

对齐 `macos/Shion/Model/Models.swift` 的 `Todo`。

```json
{
  "id": "td_3f9a0c1b2d4e",
  "title": "数据结构 作业4：实现二叉堆",
  "area": "study",
  "source": "study",
  "source_detail": "数据结构与算法 第7回",
  "do_at": "2026-11-11T19:00:00+09:00",
  "due_at": "2026-11-13T23:59:00+09:00",
  "done": false,
  "nudges": 0,
  "proposed": true,
  "created_at": "2026-11-09T10:52:00+09:00",
  "updated_at": "2026-11-09T10:52:00+09:00",
  "completed_at": null
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 插件生成的是 `td_` 加 12 位十六进制；Mac 新增时也可以自己给（1–64 个 `A-Z a-z 0-9 _ -`） |
| `title` | string | 1–500 字 |
| `area` | `study` / `work` / `life` | |
| `source` | string | 谁加的：助手的 profile 名（`shion`、`study`、`mail`…），或从 Shion 加的固定是 `你自己加的` |
| `source_detail` | string \| null | 从哪来的，界面上显示在待办下面，比如「来自 中村老师 的邮件」。Mac 的示例数据里 `source` 写的就是这类话，接上插件后 `source` 是谁加的、这一行是从哪来的，两个分开 |
| `do_at` | 时间 \| null | 执行时间 |
| `due_at` | 时间 \| null | 截止时间，和执行时间分开 |
| `done` | bool | |
| `nudges` | int | 催过几次 |
| `proposed` | bool | `true`：日期是助手建议的，等你在「等你确认」里确认 |
| `created_at` / `updated_at` | 时间 | `updated_at` 只在真的改了内容时变 |
| `completed_at` | 时间 \| null | `done` 变成 `true` 时记下，改回 `false` 时清空 |

### 今天的汇总

```json
{"date": "2026-11-09", "text": "早上好。10:45 有机器学习的课前小测……", "author": "shion",
 "updated_at": "2026-11-09T07:00:00+09:00"}
```

每天一段，再写就整段替换（早报，12、18、21 点各更新一次）。`author` 是写它的 profile。

### 日报

对齐 `Report` / `ReportBlock`。

```json
{
  "id": "2026-11-08-life",
  "date": "2026-11-08",
  "kind": "life",
  "headline": "昨天比前天早睡半小时，屏幕时间少了 40 分钟",
  "author": "journal",
  "created_at": "2026-11-08T22:30:00+09:00",
  "updated_at": "2026-11-08T22:30:00+09:00",
  "blocks": [
    {"heading": "睡眠", "items": ["比前天早睡半小时"]},
    {"heading": "屏幕时间", "items": ["4 小时 10 分，少了 40 分钟"]}
  ]
}
```

- 每天每种（`study` / `work` / `life` / `news`）一篇，`id` 是 `<date>-<kind>`。再写就替换，`created_at` 保留。
- `headline` 可以为空（`null`）。Mac 的 `Report` 有 `headline` 字段，所以加了它；`ReportBlock` 只有 `heading` 和 `items`。
- `author` 对应 Mac 的 `botId`（profile 名）。Mac 的 `Report.date` 是时间，这里 `date` 是那一天，写的时间看 `updated_at`。
- 列表（`reports.list`）里没有 `blocks`，换成 `block_count`。

### 应用使用的一段

```json
{"bundle_id": "com.apple.dt.Xcode", "app_name": "Xcode",
 "start": "2026-11-09T09:00:00+09:00", "end": "2026-11-09T09:30:00+09:00"}
```

前台是这个应用的一段时间。只有这四个字段，多了就报错。一段最长 24 小时，结束时间不能晚于服务器当前时间 5 分钟以上。

### 专注检查结论

```json
{"at": "2026-11-09T10:52:00+09:00", "plan": "机器学习 课前小测", "off_minutes": 7,
 "activity": "fun", "on_track": false, "woke": true}
```

`activity` 是 `study` / `work` / `life` / `fun` / `social` / `other`，`woke` 表示这一次有没有把话放进詩音的 Bot Chat。

## RPC

方法名前面都是 `plugin.shion.`。下面只写 params（不含 `profile`）。写入方法都返回写完后的 `revision`。

### `info`

参数：无。

```json
{"plugin_version": "0.1.0", "schema_version": 1, "profile": "shion", "timezone": "Asia/Tokyo",
 "today": "2026-11-09", "revision": 42, "tz_database": true}
```

`profile` 是处理这次调用的 profile，可以用来确认 `profile` 参数生效了。`tz_database` 是服务器上有没有时区数据库：Hermes 的镜像是 Debian 13，用 `--no-install-recommends` 装包，不一定带 tzdata。没有的话，没有夏令时的时区（`Asia/Tokyo`、`Asia/Shanghai` 等几个，以及 `UTC`）照样按固定的时差算，结果一样；其他时区会被拒，要在容器里装上 tzdata。

### `sync.state`

参数：无。连上（和重连）后先调它。它也会启动推送（见「推送」）。

```json
{"revision": 42, "today": "2026-11-09", "timezone": "Asia/Tokyo",
 "topics": {"todos": 41, "today": 40, "reports": 35, "usage": 42, "focus": 30, "settings": 2}}
```

`topics` 是每个话题最后一次改动时的 revision（7 天内没动过的是 `0`）。

### `changes.since`

| 参数 | 类型 | |
| --- | --- | --- |
| `revision` | int ≥ 0 | 必填，你手上数据的 revision |

```json
{"revision": 45, "reset": false, "topics": ["todos", "today"]}
```

`revision` 之后改过哪些话题。`reset: true`（这时 `topics` 是全部话题）表示变更记录已经不够早（超过 7 天），或者你的 revision 比服务器还新（换过数据文件），要全部重新取。

### `settings.get` / `settings.update`

`settings.get` 参数：无，返回 `{"settings": {...}}`。

`settings.update` 参数：`timezone`、`usage_retention_days`、`focus_retention_days`、`chief_profile` 中的一个或几个（至少一个）。返回 `{"settings": {...全部...}, "revision": n}`。时区名不认识报 `invalid_params`。

### `todos.list`

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `status` | `open` / `done` / `all` | `open` | |
| `area` | string 或 string 数组 | 全部 | `study` / `work` / `life` |
| `proposed` | bool | 不过滤 | `true` 只要等你确认日期的 |
| `date` | 日期 | | 这一天要做或到期的（时间落在当地这一天里） |
| `from` / `to` | 日期或时间 | | 范围，`from` 含，`to` 不含；`to` 是日期时包含那一整天。和 `date` 不能同时给 |
| `date_field` | `do_at` / `due_at` / `either` | `either` | 范围看哪个时间 |
| `include_undated` | bool | `false` | 给了范围时，把没有那个时间的待办也带上 |
| `limit` | int 1–2000 | 500 | |

返回 `{"todos": [Todo...], "revision": n}`。排序：有执行时间的在前，按执行时间；再按截止时间；再按创建时间。

常用：「今天」页 = `{"date": "<today>", "include_undated": true}`；「等你确认」= `{"proposed": true}`；「待办」页 = 不带参数（全部未完成）。

### `todos.get`

参数：`id`（必填）。返回 `{"todo": Todo}`，没有就 `not_found`。

### `todos.add`

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `title` | 是 | |
| `area` | 是 | |
| `do_at` / `due_at` | | 时间或 `null` |
| `proposed` | | 默认 `false` |
| `source_detail` | | |
| `id` | | 自己给 id。同一个 id 内容一样（标题、area、两个时间）再加一次，返回已有的那条、不算新写入，所以断线后可以放心重发；内容不一样报 `conflict` |

`source` 固定是 `你自己加的`。返回 `{"todo": Todo, "revision": n}`。

### `todos.update`

| 参数 | 说明 |
| --- | --- |
| `id` | 必填 |
| `title`、`area` | |
| `do_at`、`due_at` | 时间，`null` 清空 |
| `done` | `true` 完成（记 `completed_at`），`false` 改回未完成 |
| `proposed` | `false` = 确认助手建议的日期；改日期不会自动确认，要确认就一起传 `proposed: false` |
| `nudges` | 直接设成某个数 |
| `add_nudge` | `true` 加一次（不能和 `nudges` 同时给） |
| `source_detail` | `""` 或 `null` 清空 |

至少要改一项。`source` 不能改。返回 `{"todo": Todo, "revision": n}`；内容和原来一样时 revision 不变。

### `todos.delete`

参数：`id`。返回 `{"deleted": "<id>", "revision": n}`；没有就 `not_found`。

### `today.get`

参数：`date`（可选，默认今天）。返回 `{"summary": 今天的汇总 | null}`。

### `reports.list`

| 参数 | 说明 |
| --- | --- |
| `from` / `to` | 日期，两头都含 |
| `kind` | `study` / `work` / `life` / `news` |
| `limit` | 1–1000，默认 200 |

返回 `{"reports": [日报（没有 blocks，有 block_count）...]}`，新的在前，同一天按种类名排。

### `reports.get`

参数：`date`、`kind`（都必填）。返回 `{"report": 日报}`；没有就 `not_found`。

### `usage.upload`

| 参数 | 说明 |
| --- | --- |
| `segments` | 必填，「应用使用的一段」的数组，一次最多 5000 段 |
| `device` | 可选，默认 `mac`。以后有第二台 Mac 时用来区分 |

返回：

```json
{"received": 3, "added": 2, "updated": 1, "unchanged": 0, "expired": 0, "revision": 50}
```

- **重复上传不会重复计**：一段按 `(device, bundle_id, start)` 认，同一段再传就是替换。所以还没结束的一段可以先传，等结束了带着同样的 `start`、新的 `end` 再传一次（算 `updated`）。
- 统计时同一台设备、同一个应用重叠的时间只算一次，所以就算切段的方式变了，也不会多算。
- 已经超过保留天数的段直接丢掉（`expired`），并顺手删掉过期的旧记录。
- 有一段不合格，整次上传都不写入，返回 `invalid_params`，说明里写着是第几段。

建议：每 5–15 分钟上传一次上次上传之后结束或更新过的段，正在进行的那段也一起传。

### `usage.day`

参数：`date`（可选，默认今天）。返回（`回顾` 的工具 `shion_usage_day` 返回同样的东西）：

```json
{
  "date": "2026-11-09", "timezone": "Asia/Tokyo", "total_seconds": 2400,
  "by_app": [
    {"bundle_id": "com.apple.dt.Xcode", "app_name": "Xcode", "category": "work", "seconds": 1800},
    {"bundle_id": "jp.naver.line.mac", "app_name": "LINE", "category": "social", "seconds": 600}
  ],
  "by_category": {"study": 0, "work": 1800, "life": 0, "fun": 0, "social": 600, "other": 0, "uncategorized": 0}
}
```

- 跨过当地午夜的段按天切开算。
- `category` 为 `null` 的应用算进 `uncategorized`。分类先看手动设的，再看内置表（Xcode、VS Code、Slack 算工作，Notion、Anki 算学习，LINE、微信算社交，Spotify、Steam 算娱乐等，见 `store.py` 的 `BUILTIN_CATEGORIES`）；浏览器和邮件故意不分类，在里面做什么说不准。
- `total_seconds` 是所有应用合起来、重叠只算一次的时长。

### `usage.categories.list` / `usage.categories.set`

`usage.categories.list` 参数：无，返回 `{"categories": {"<bundle_id>": "<category>", ...}}`（内置表加手动设的）。

`usage.categories.set` 参数：`bundle_id`、`category`（`study` / `work` / `life` / `fun` / `social` / `other`，或 `null` 恢复内置分类）。返回 `{"bundle_id", "category", "revision"}`。

### `focus.report`

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `plan` | string | 此刻的计划名，1–200 字 |
| `off_minutes` | int 0–1440 | 偏离了几分钟 |
| `activity` | `study` / `work` / `life` / `fun` / `social` / `other` | 在做哪类事 |
| `on_track` | bool | `true`：回到计划上了 |
| `session_id` | string | 詩音 Bot Chat 的会话 id（路由用，见下） |
| `profile` | string | 必须是 `chief_profile`（`shion`） |

只收这些，多了（比如窗口标题）报 `invalid_params`。返回：

```json
{"recorded": true, "woke": true, "revision": 51,
 "latest": {"at": "2026-11-09T10:52:00+09:00", "plan": "机器学习 课前小测", "off_minutes": 7,
            "activity": "fun", "on_track": false, "woke": true}}
```

`woke: false` 时带 `reason`：

| `reason` | 意思 | 怎么办 |
| --- | --- | --- |
| `wrong_profile` | 这次调用不是在 `chief_profile` 里处理的 | 带上 `profile: "shion"` |
| `no_session_key` | 插件还不知道詩音任何一个本地会话的路由键 | 詩音在 Bot Chat 里回过一次话之后就有了（见下） |
| `inject_refused` | Hermes 拒绝了 `inject_message` | 多半是没开 `allow_gateway_injection`，或者詩音的 Bot Chat 此刻不在 gateway 的活动会话里；看 gateway 日志里 `inject_message` / `Plugin message injection` 开头的那行 |

不管叫没叫醒，结论都已经存下（`recorded: true`），詩音的例行催促可以用 `shion_focus_status` 查到。

**怎么叫醒她。** 插件用 `ctx.inject_message(text, session_key=<路由键>)` 把一句话作为一条用户消息排进詩音的 Bot Chat，她会马上开始一轮回复：

- 偏离：`［专注检查］「机器学习 课前小测」：已经偏离 7 分钟，现在在做娱乐。`
- 回来：`［专注检查］已经回到「机器学习 课前小测」上了。`

（`activity` 对应：学习、工作、生活、娱乐、社交、别的事。）这句话会留在 Bot Chat 的记录里，Shion 显示对话时要按开头的 `［专注检查］` 把它藏起来（README 主文档写着「插件放进詩音对话里的那句话，Shion 也不显示」）。

**路由键从哪来。** `inject_message` 要的是会话的路由键（`session_key`，比如 `agent:shion:local:…`），不是会话 id，插件 RPC 只拿得到会话 id。所以插件注册了 `pre_llm_call` 钩子：每个会话每开始一轮，记下 `HERMES_SESSION_KEY`（`gateway.session_context.get_session_env`）和会话 id 的对应。`focus.report` 先按你给的 `session_id` 找；找不到（比如压缩后会话 id 变了），就用詩音 profile 里最近一轮本地会话（平台 `local`）的路由键。所以詩音的 Bot Chat 装好插件后要先有过一轮对话。

**Hermes 的检查**（`gateway/run_plugin_injection.py`）：本地会话的注入只在插件自己的 profile 里、并且这个会话此刻是 gateway 的活动会话（Shion 打开着它，或者它刚跑过）时才接受，否则返回 `False`（`inject_refused`）。

### `focus.latest`

参数：无。返回 `{"latest": 专注检查结论（多一个 age_minutes：距现在几分钟） | null}`。

## 推送

数据变了（助手加了一条待办、回顾写了日报、你在另一台设备上改了设置），所有连着这台 gateway 的 `/api/ws` 客户端会收到：

```json
{"jsonrpc": "2.0", "method": "event",
 "params": {"type": "plugin.shion.changed", "session_id": "",
            "payload": {"revision": 46, "topics": ["todos"], "reset": false}}}
```

- `payload.revision`：服务器现在的 revision；`topics`：上次推送之后改过的话题；`reset: true` 时全部重新取。
- 收到后只重新取 `topics` 里的那几样（比如 `todos` → `todos.list`）。按 revision 处理：不大于手上的就忽略（比如刚用 `changes.since` 取过）。
- 一般 1 秒内到。几次写入挨得很近时会合成一个事件。
- 这是**全局**事件，`session_id` 是空的，不属于任何会话，不进任何会话的重放记录：断线期间的事件会丢。所以：
  1. 连上和每次重连后调 `sync.state`，和手上的 revision 比，不一样就 `changes.since` 补上；
  2. 隔一段时间（比如 5 分钟，或者窗口回到前台时）也调一次 `changes.since` 兜底。

**为什么这样做。** Hermes 给插件两种推送：

| | `ctx.emit_to_session(session_id, event, payload)` | `broadcast_plugin_event(plugin_id, event, payload)` |
| --- | --- | --- |
| 发给谁 | 只发给正在看这个会话的客户端，进这个会话的事件流（重连能重放） | 这个 gateway 进程里所有连着的 `/api/ws` 客户端 |
| 限制 | 会话必须是插件所在 profile 的活动会话；会话 id 按 profile 分开，课程助手的插件发不到詩音的会话 | 断线期间的丢掉 |

助手们在各自的 profile 里写，Shion 可能正看着别的页面，`emit_to_session` 对不上。所以用后一种：`hermes_cli.plugin_events.broadcast_plugin_event`。`/api/ws`（`tui_gateway/ws.py`）在每个连接收到 `gateway.ready` 后把它登记为全局广播的接收方，gateway 上的 Canonical 连接也算。`plugin_events.py` 的说明里写着 `hermes gateway run` 下没人收，代码已经不是这样了。

**谁来发。** 写入不止发生在 gateway 进程里：看板 worker 是单独的子进程，开了 `dashboard.turn_isolation` 时对话也在子进程里跑，那里没有 Mac 的连接。所以不在写入时发，而是 gateway 进程里一个线程（`shion-change-watcher`）每秒看一次库里的 revision，变了就发。这个线程在第一次收到 `sync.state` 或 `changes.since` 时启动（只有 gateway 进程会收到 RPC），一个进程只起一个；每小时顺手清一次过期的使用记录。所以 **Shion 连上后一定要先调 `sync.state`**，不然 gateway 重启后没人推送。

## 给助手的工具

工具集 `shion`，每个装了插件的 profile 都有。返回都是 JSON 字符串；出错时返回 `{"error": "<错误码>", "message": "…"}`，不会让这一轮失败。工具里不带时区的时间按设置的时区理解。

| 工具 | 参数 | 做什么 | 谁用 |
| --- | --- | --- | --- |
| `shion_todo_list` | `status`、`area`、`proposed`、`date`、`from`、`to`、`date_field`、`include_undated` | 和 `todos.list` 一样，多返回 `today`、`count` | 所有助手 |
| `shion_todo_add` | `title`、`area`（必填）、`do_at`、`due_at`、`proposed`、`source_detail` | 加待办，`source` 是调用它的 profile；自己定的日期要设 `proposed: true` | 詩音、课程、邮件等 |
| `shion_todo_update` | `id`（必填）、`title`、`area`、`do_at`、`due_at`（`""` 清空）、`done`、`proposed`、`add_nudge`、`source_detail` | 改待办；每催一次传 `add_nudge: true` | 詩音等 |
| `shion_todo_delete` | `id` | 删掉不该有的（重复的、取消的）；做完用 `done` | |
| `shion_today_write` | `text`（必填）、`date` | 写「今天」页顶部那段话，整段替换 | 詩音 |
| `shion_today_read` | `date` | 读那段话 | |
| `shion_report_write` | `kind`、`blocks`（必填）、`date`、`headline` | 写日报，同一天同一种替换 | 资讯（`news`）、回顾（`study` / `work` / `life`） |
| `shion_report_read` | `kind`+`date` 读一篇；只给 `date` 或 `from`/`to`（可加 `kind`）列出 | 读以前的日报 | 回顾 |
| `shion_usage_day` | `date` | 某天按应用、按类别的时长 | 回顾 |
| `shion_usage_set_category` | `bundle_id`、`category`（六类之一，或 `default` 恢复内置） | 给应用定类别 | 回顾 |
| `shion_focus_status` | `recent`（1–20，可选） | 最新的专注检查结论，`recent` 再带前几条 | 詩音 |

工具是给所有 profile 的；要限制某个助手能用哪些，用 Hermes 自己的工具选择（`hermes -p <profile> tools`）。各助手的 SOUL 里写清楚谁用哪几个（比如只有回顾写 `study`/`work`/`life` 日报）。

钩子：`pre_llm_call`，只记下会话的路由键（见 `focus.report`），不改这一轮的内容，不往对话里加任何东西。

## 限制

Hermes 现在缺的、或者和需求有出入的地方。没有改 Hermes。

1. **全局推送断线会丢。** `broadcast_plugin_event` 不进任何重放记录，Hermes 没有给插件的「可重放的全局事件」。靠 `sync.state` / `changes.since` 补。
2. **推送要等第一次 RPC。** 插件在 `register()` 时分不出自己是不是在 gateway 进程里（看板 worker、命令行也会加载它），而 `ctx.spawn_task` 要有运行中的事件循环，`register()` 时没有。所以推送线程等第一次 `sync.state` / `changes.since` 才起。
3. **`plugins.isolation: host` 下没有推送。** 那时插件跑在单独的插件宿主进程里，`broadcast_plugin_event` 在那个进程里找不到客户端，Hermes 只转发 `emit_to_session`。要保持默认的 `in_process`。
4. **插件 RPC 拿不到会话的路由键**，只有会话 id，而 `inject_message` 要路由键。现在靠 `pre_llm_call` 钩子记下来（见 `focus.report`），所以詩音的 Bot Chat 要先有过一轮对话；会话被压缩换了 id 后，第一次报告会退回到「最近一轮本地会话」。
5. **詩音的 Bot Chat 不在活动会话里时叫不醒。** Hermes 只往插件自己 profile 里活动的本地会话注入（`_plugin_local_session`）。gateway 重启后、Shion 还没打开她的对话前，`focus.report` 会是 `inject_refused`；结论照样存着。
6. **插件要在每个 profile 里分别装、分别启用**（Hermes 没有跨 profile 的安装），设置也只能各自写进各自的 `config.yaml`，所以设置放在共用的数据库里，不用 Hermes 的 `config_schema`（Desktop 的插件设置页因此看不到这几项）。
7. **调用者不分人。** Hermes 对插件方法只检查连接有 `session:control`，通过认证的客户端都能调所有方法（Hermes `SECURITY.md` §2.6）。这里只暴露插件自己的数据。
8. 同一个 gateway 里 Mac 要是经两个 profile 都调过 `sync.state`，只会起一个推送线程（按线程名判断）；但起推送的那个 profile 的插件被卸载时线程跟着停，要等下一次 `sync.state` 才重起。

## 开发和测试

```bash
cd hermes-plugin
pip install pytest
python -m pytest -q
```

测试不装 Hermes：`tests/conftest.py` 的 `FakeCtx` 照 `PluginContext` 的接口记下 `register_rpc`、`register_tool`、`register_hook`、`on_unload`、`inject_message`，`FakeHermes` 代替 `broadcast_plugin_event` 和 `get_session_env`；RPC 按 Hermes 的调用方式调（params 里留着 `profile`、`session_id`，`session_id` 另外作为关键字参数传）。存储用真的 SQLite。

CI：`.github/workflows/hermes-plugin.yml`，只在 `hermes-plugin/**` 或这个工作流改了时跑，ubuntu runner，Python 3.11 和 3.13。
