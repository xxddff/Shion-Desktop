# 图片、文件和「空间」：调研

Shion 现在只能发文字，回复里的图片也只显示成链接。这份文档查清楚三件事：Hermes 已经能怎么收、怎么给图片和文件；有没有一个每个助手都能读的统一文件区（「空间」）；Shion 要做什么、分几步做。只是调研和设计，没有改 App、插件的代码。

依据：
- Hermes `main` 的 `6cff782b`（2026-11-09）的代码和文档。**不带前缀的路径都是 Hermes 仓库里的**（官方桌面端在 `apps/desktop/`）；`macos/`、`hermes-plugin/` 开头的是本仓库的（`claude/macos-app` 的 `25dab04`）。
- Cloudflare 的官方文档，2026-11-09 查的，链接附在用到的地方。
- 只读了代码，没有在我们的 VPS 上跑过。没确认的写着「没核实」，汇总在最后一节。

## 结论

1. **收：Hermes 已经支持，Shion 现在这条连接就能用，不用改服务器。**
   - 图片分两步。先存到那个助手的 `cache/images/`：用 `POST /api/chat/image-upload`，或者 WebSocket 上的 `image.attach_bytes`。再在 `prompt.submit` 里带 `attachments: [{path, mime}]`。
   - 每条消息最多 10 张，只收 PNG、JPEG、GIF、WebP，每张不超过 25 MiB，合计不超过 128 MiB。官方桌面端就是这么做的。
   - 文件用 `file.attach` 换一个 `@file:` 引用，写进消息的文字。文本文件的内容会直接放进这一轮；二进制文件（PDF、Word 之类）只告诉助手路径，助手自己用工具读。
2. **给：助手交文件时写 `MEDIA:/绝对路径`。** Shion 建的 Bot Chat 是桌面会话（`gui`），Hermes 就是这么教助手的；较早的 `cli` 会话里，助手只会把路径写在文字里。截图和生成的图，路径在工具结果的 `image_path` 里。这些文件都能用 `/api/fs/read-data-url`（图片）和 `/api/fs/download`（别的文件）取回来，只要请求头带上 Access 和 Hermes 的凭证。
3. **服务器上的图大多只留 24 小时。** 你发的图、截图都会被清掉，截图的路径也不进对话记录。所以 Shion 要在 Mac 上留一份，历史里的图才一直看得到。
4. **没有现成的「空间」。** Hermes 没有每个助手都能读的统一文件区，最接近的有两个：
   - 看板附件：整台服务器共用，但按卡片放；
   - 群聊附件：按群放。

   另一方面，**profile 在文件上并不隔离**：默认的 local 后端下，每个助手都以同一个 Unix 用户运行，能读写这台机器上的任何目录，包括别的助手的 home。所以做一个共享目录，技术上马上就能用；按助手分权限，在现在的部署下却做不到。
5. **推荐分三步做：**
   1. 对话里发图、发文件、显示图片：只改 App。
   2. 扩展 `shion` 插件，做「空间」：服务器上一个普通目录（助手用文件工具直接读），插件管元数据和分块传输，Shion 加一个「文件」页。不按助手分权限，在设置里写明。
   3. 以后按需要：备份到云、按助手分权限（要先把助手换成 docker 后端）、在 Finder 里直接看到空间。
6. 要你决定的问题在第 9 节。

## 1. Hermes 现在怎么收图片和文件

Shion 连的是 `hermes gateway` 上的 `/api/ws`，也就是会话 authority，下面只说这条连接和同一个地址上的 REST 能用的东西。官方桌面端在本机时还有一套旧方法：`image.attach`、`clipboard.paste`、`pdf.attach`、`input.detect_drop`（`tui_gateway/methods_prompt.py:976-1155`）。authority 不接这些（`gateway/session_controls.py:221-288` 的方法表里没有），远程用不上。

### 1.1 图片：先存到服务器，再随消息提交

**第一步，存到服务器。** 两个接口任选，存的地方一样：都是**会话所属那个 profile** 的 `cache/images/`，这也是提交时唯一认的目录（`hermes_cli/web_routers/files.py:333-339`）。

| | `POST /api/chat/image-upload?profile=<助手>` | `image.attach_bytes`（WebSocket） |
| --- | --- | --- |
| 请求 | JSON `{data_url, filename}`（`hermes_cli/web_models.py:95-97`） | `{session_id, profile, content_base64, filename?, ext?}`；`filename` 和 `ext` 只当提示，以文件头为准（`tui_gateway/contracts/prompt_voice.py:127-138`） |
| 回 | `{ok, path, name, bytes, mime_type}`（`hermes_cli/web_routers/files.py:568-613`） | `{attached, path, mime, name, count, text, bytes}`（`gateway/session_images.py:44-45`，`tui_gateway/contracts/canonical_projections.py:37-38,124`） |
| 大小 | 25 MiB，Webapp 上还在解析前按 base64 的长度拒绝（`hermes_cli/web_upload_limit.py:17-26`） | 25 MiB（`tui_gateway/prompt_attachments.py:21`） |
| 类型 | 按文件头认 PNG、JPEG、GIF、WebP、BMP（`hermes_cli/web_routers/files.py:532-565`），但提交时 BMP 会被拒 | PNG、JPEG、GIF、WebP（`gateway/session_images.py:36-39`） |
| 条件 | 所有监听上都有（`hermes_cli/web_server.py:822`） | 会话要先在这条连接上 `session.resume` 过，否则 `permission_denied`；要有 `session:submit` 权限（`gateway/session_images.py:13-17`） |
| 文件名 | `dashboard_<时间>_<随机>_<名字>.<扩展名>` | `upload_<随机>.<扩展名>`，目录 0700（`tui_gateway/prompt_attachments.py:174-191`） |

官方桌面端在 Canonical 连接上用的是 `/api/chat/image-upload`（`apps/desktop/src/app/session/hooks/use-prompt-actions/upload-server-image.ts:26-48`、`index.ts:150-154`），只有旧协议的远程连接才用 `image.attach_bytes`（`index.ts:181-207`）。它不压缩，只为界面做 512 像素的缩略图，上传的是原图（`apps/desktop/src/lib/image-resize.ts:22-55`）。

带 `profile` 的调用会被转给那个 profile（`gateway/session_controls.py:313-322`），所以发给课程的图存在课程的 home 下。

**第二步，随消息提交。** `prompt.submit` 带 `attachments: [{path, mime}]`（`tui_gateway/contracts/canonical_sessions.py:222-247`）。Hermes 的检查（`gateway/session_ingress_media.py:140-182`）：

- 每条最多 10 张；`mime` 只能是 `image/png`、`image/jpeg`、`image/gif`、`image/webp`；每项只能有 `path`、`mime` 两个键（`:122-123,147-151`）。`prompt.submit` 本身也只认固定的几个参数，没有 `image_paths`（`gateway/session_controls.py:860-875`）。
- `path` 必须是绝对路径，而且就在这个 profile 的 `cache/images/` 下面（`:152-156`）。所以只能用第一步给的路径，指不到服务器上别的文件。
- 提交时 Hermes 把文件按 sha256 复制进 `cache/documents/native-inputs/<sha256>/<文件名>`（`:101-115,274-345`），之后暂存文件被删、被改，都不影响这一轮。
- 一条消息的图片合计不超过 `gateway.max_inbound_media_bytes`，默认 128 MiB（`gateway/platforms/base.py:502`，`gateway/session_ingress_media.py:277-281`）。Hermes 的开发文档写的是「每个文件」不超过这个值（`website/docs/developer-guide/gateway-internals.md:108-109`），代码算的是整条消息的合计。
- 执行时这些图变成 `MessageEvent.media_urls` / `media_types`，和 Telegram 等平台收图走同一条路（`gateway/session_ingress_media.py:256-262`）。

官方桌面端的消息文字：先是附件的引用，一个一行，空一行，再是你打的字；只发图不打字时，文字是 `What do you see in this image?`（`apps/desktop/src/app/session/hooks/use-prompt-actions/submit.ts:289-304`）。提交被拒时，它把这条消息的图标成「要重新上传」（`submit.ts:118-145`）。

**助手怎么「看」图**：由 `agent.image_input_mode`（`auto` / `native` / `text`）决定（`agent/image_routing.py:1-9`）。
- `native`：把图编成 base64，作为 `image_url` 放进这一轮；文字后面每张图加一行 `[Image attached at: <服务器路径>]`（`agent/image_routing.py:533-563`）。
- `text`：先用辅助视觉模型写一段描述，或者只给路径，让助手自己调 `vision_analyze`（`tui_gateway/session_history.py:30-48`）。

**粘贴**：authority 上没有读剪贴板的方法。`clipboard.paste` 读的是 gateway 那台机器的剪贴板（`tui_gateway/contracts/prompt_voice.py:115-116`），所以 Mac 上粘贴的图要由 Shion 自己读出来，再按上面两步发。

### 1.2 文件：`file.attach` 换一个 `@file:` 引用

`file.attach` 不在 Canonical 方法表里，但 authority 的方法表接它（`gateway/session_ancillary.py:24-35`，处理函数在 `:137-180`），同一条 `/api/ws` 就能调。官方桌面端也这样用：`file.attach {session_id, name, path, data_url}`，然后把回来的 `ref_text` 放进消息的文字（`apps/desktop/src/app/session/hooks/use-prompt-actions/index.ts:209-229`）。

- **参数**：`session_id`、`profile`，再加下面三选一，外加文件名 `name`（`gateway/session_ancillary.py:146-150`，`tui_gateway/contracts/prompt_voice.py:171-198`）：
  - `path`：gateway 那台机器上已有的文件；
  - `data_url`：文件内容，base64，可以带 `data:<mime>;base64,` 前缀；
  - `staged_upload`：下面 REST 上传给的收据。
- **Shion 不要带 `path`**：Hermes 先按 `path` 在 gateway 上找文件，找到就用服务器上的那份，找不到才用 `data_url`（`tui_gateway/prompt_attachments.py:289-312`）。只传 `name` 和 `data_url`。
- **存到哪**：profile home 的 `attachments/`；profile 配了 `attachments.storage: workspace` 时，存到会话工作目录下的 `.hermes/attachments/`（`tui_gateway/prompt_attachments.py:110-123,324`）。同名的文件自动加 `-2`、`-3`（`:326-343`）。已经在工作目录里的文件不复制，直接引用（`:264-276,304-306`）。
- **大小**：`data_url` 解码后最多 256 MiB（`tui_gateway/prompt_attachments.py:20,316-320`）。为了让这么大的 base64 放得进一条消息，gateway 把 WebSocket 消息的上限设成了 384 MiB（`hermes_cli/web_server_boundary.py:24-26`）。实际能发多大，见第 4.1 节。
- **回什么**：`{attached, name, path, ref_path, ref_text: "@file:<路径>", uploaded}`（`gateway/session_ancillary.py:178-180`）。文件本身不进 `prompt.submit` 的 `attachments`（那里只收图片），而是把 `ref_text` 放在消息文字的前面。Hermes 认的引用有 `@image:`、`@file:`、`@url:`（`gateway/platforms/event.py:16-22`），桌面端还发 `@folder:`。
- **助手那边**（`agent/context_references.py`）：
  - 文本文件：内容直接放进这一轮，最多占上下文的一半，超过四分之一时提醒（`:235-260`）。
  - 二进制文件和太大的文本：只放一段说明，写明路径，让助手自己用工具读（`:683-698`）。
  - 一条消息最多展开 16 个引用（`:125`）。

**REST 上传，只在 Webapp 上有**：`POST /api/chat/file-upload?profile=<助手>`，multipart 的 `file` 字段（`hermes_cli/web_routers/uploads.py:22-55`）。
- 存到 `<profile home>/uploads/web-<随机>-<文件名>`，文件权限 0600（`hermes_cli/staged_uploads.py:1-7,127-160`）。
- 最多 16 MiB（`hermes_constants.py:29`）；中间件在解析之前，就按 16 MiB + 64 KiB 拒绝（`hermes_cli/web_upload_limit.py:13-26`）。
- 返回 `path`、`size` 和一张 `staged_upload` 收据，再用 `file.attach {staged_upload}` 换成引用（`tui_gateway/prompt_attachments.py:243-261`）。
- 7 天后自动删（`hermes_cli/staged_uploads.py:36,49-64`），所以 `file.attach` 总是再复制一份到 `attachments/`。
- 这类给浏览器用的文件路由，只在 `webapp` 这个监听上有。gateway 自己的监听、`hermes serve`、`hermes dashboard` 上都是 404（`hermes_cli/web_server_surface.py:40-43,59-77`，`hermes_cli/web_server.py:823-824`）。
- 按根 README，Shion 填的是 Webapp 的地址，应该能用；要在 VPS 上确认隧道指向的是 Webapp 的端口（没核实）。官方桌面端只有浏览器版用这个路由（`apps/desktop/src/lib/browser-uploads.ts:138-156,263-279`）。

**PDF**：authority 上没有 `pdf.attach`（它把每页渲染成图，是旧方法，`tui_gateway/contracts/prompt_voice.py:141-168`），远程只能当普通文件用 `file.attach` 发。

### 1.3 存在哪、留多久、谁能读

都在会话所属那个 profile 的 home 下：

| 东西 | 位置 | 留多久 |
| --- | --- | --- |
| 上传后、提交前的图 | `cache/images/` | 24 小时：gateway 每小时清一次，只看这一层（`agent/provider_media.py:25`，`gateway/run.py:4461-4484`，`gateway/run_housekeeping_disk.py:20-42`，`utils.py:325-341`） |
| 提交后的图 | `cache/documents/native-inputs/<sha256>/` | 对话记录里还提到它就留着，但结算后满 24 小时，不管提没提到都删；删会话时一起删（`gateway/session_ingress_media.py:429-487`） |
| `file.attach` 的文件 | `attachments/`，或工作目录下的 `.hermes/attachments/` | 没找到自动清理（没核实） |
| REST 上传的暂存 | `uploads/web-*` | 7 天 |

所以，**你发给助手的图，服务器上大约一天后就没了。** 对话记录里留着路径。`native` 模式下这条消息里还存着 base64 的图，但 `session.transcript` 默认把它换成 `[image]`，带 `inline_images: true` 才给原图（`tui_gateway/contracts/canonical_stored_reads.py:23-24`），而且每页最多 2 MiB（同文件 `:61-81`）。Shion 要显示历史里的图，就得在 Mac 上留一份（第 4.5 节）。

24 小时的清理看起来只处理 gateway 自己那个 profile（`gateway/run.py:4483` 和 `:4496-4505` 的写法不一样），别的助手的缓存会不会清，没核实。不管清不清，都不能依赖。

**谁能读**：目录 0700、文件 0600，只有跑 Hermes 的那个 Unix 用户能读（`gateway/platforms/base.py:567-621`）。上传要过 Access 和 Hermes 的认证，和别的 `/api/*` 一样。`staged_upload` 收据只能在它所属的 profile 里兑换，或者在这台 gateway 服务的兄弟 profile 里（`gateway/session_ancillary.py:183-198`）。但是，同一台机器上的每个助手都能读这些目录，见第 3.2 节。

## 2. 助手怎么把图片和文件给你看

### 2.1 从哪看得出「这里有张图、有个文件」

| 来源 | 内容 | 重读对话时还在不在 |
| --- | --- | --- |
| 工具结果 `tool.complete` 的 `image_path` | 这次工具调用产出或看过的图，是 gateway 主机上的绝对路径（`tui_gateway/contracts/events.py:430`）。<br>填它的工具：`vision_analyze`（取参数里的 `image_url`）、`image_generate`（取结果里的 `image`），以及结果里带 `image_path` 或 `screenshot_path` 的工具，比如浏览器和 `computer_use` 的截图（`agent/terminal_image.py:355-385`，`tools/browser_use_cli.py:889-892`，`tools/computer_use/tool.py:657,690,721`）。<br>只认本机的图片文件，网址和 `data:` 不算；失败的调用没有（`agent/terminal_image.py:292,344-352`）。<br>只在本地会话的事件里有（`gateway/run_turn_progress.py:948-952,1101-1107`）。Shion 建的 Bot Chat 应该算本地会话，没核实 | **不在。** 存下来的工具行只有 `name`、`context`、`args`、`labels`、`tool_call_id`、`timestamp`、`display_metadata`；只有 `write_file`、`patch`、`skill_manage` 多带 `content`（`tui_gateway/session_history.py:333-346`）。<br>`vision_analyze` 看的图，路径还留在 `args` 里；截图和生成的图就找不到了。<br>断线重连时补发的事件里有：内存里每个会话最多 512 条、4 MiB，gateway 重启就没了（`tui_gateway/event_replay.py:23-36`） |
| 回复里的 `MEDIA:/绝对路径` | Shion 建的 Bot Chat 是 `gui` 会话，Hermes 按「桌面应用」给助手写说明（`gateway/session_policy.py:86`，`agent/prompt_builder.py:685-703`）：<br>- 交文件就写 `MEDIA:/absolute/path/to/file`；图片、音频、视频内嵌显示，别的文件变成带下载按钮的卡片；<br>- 网上的图用 `![alt](url)`；<br>- **本机文件只能用 `MEDIA:`**，Markdown 里写本机路径的图会被拦。<br>格式：`MEDIA:` 后面跟 `/` 或 `~/` 开头的路径，前后可以有引号或强调符号（`gateway/platforms/base.py:1216-1221`）；代码块、引用、JSON 字符串里的不算（`:3150-3191`）；另有 `[[audio_as_voice]]`、`[[as_document]]` 两个控制标记（`:3194-3201`） | **在**，是回复的原文。Canonical 这条路上 Hermes 不处理 `MEDIA:`，原样发给客户端：在 `tui_gateway/` 和 `gateway/session_*.py` 里没找到处理它的代码。<br>助手忘了写的时候，gateway 会给 `image_generate`、`text_to_speech` 的产物补 `MEDIA:` 行（`gateway/run_turn_runner.py:1212-1239`），这些补的行进不进 `message.complete` 和存下来的回复，没核实 |
| 回复里直接写的绝对路径 | Bot Chat 是 `cli` 会话时（根 README 说，较早的 Bot Chat 多半是），Hermes 告诉助手：这里没有附件通道，`MEDIA:` 不会被处理，交文件就把绝对路径或网址写在文字里，让用户自己打开（`agent/prompt_builder.py:670-678`）。<br>gateway 往 Telegram 这类平台发消息时，也会把存在的、扩展名认得的绝对路径当文件发出去（`gateway/platforms/base.py:1172-1181,3243-3274`） | 在，是回复的原文 |
| 回复里的 `![说明](https://…)` | 网上的图 | 在 |
| 回复里的 `::preview{file="x.html"}` | 官方桌面端的内嵌小部件：助手写一个 HTML 文件，桌面端把它放进对话（`agent/prompt_builder.py:692-703`） | 在。Shion 先显示成一张文件卡片 |
| `write_file` / `patch` 的工具行 | 写了哪个文件、写了什么 | 在（带 `content`） |

### 2.2 这些文件在服务器上的哪里

都在助手自己那个 profile 的 home 下（`hermes_constants.py:498-510`）：

| 目录 | 放什么 | 留多久 |
| --- | --- | --- |
| `cache/images/` | 收到的图；`computer_use` 的截图也在这里，只留最新的 20 张（`gateway/platforms/base.py:488`，`tools/computer_use/tool.py:587,848-854`） | 24 小时 |
| `cache/screenshots/`、`cache/audio/`（含朗读）、`cache/videos/`、`cache/documents/` | 截图、音频、视频、文档（`gateway/platforms/base.py:677,703,724-725`） | 24 小时 |
| `cache/generated/images/`、`cache/generated/videos/` | 生成的图和视频（`agent/image_gen_provider.py:80-85`，`agent/video_gen_provider.py:72-82`）。Hermes 的文档写的是 `cache/images`、`cache/videos`，和代码不符 | **不清理**（`agent/provider_media.py:19-22`） |
| `cache/browser-use/workspace/<任务>/` | 浏览器工具的工作目录；它的截图默认放在浏览器工具自己的临时目录里（`tools/browser_use_cli.py:280-291`，`tools/browser_use_shot.py:28-33,65-68`） | 没找到清理（没核实） |
| 助手用 `write_file` 写的文件 | 写在哪就在哪，默认是会话的工作目录（第 3.1 节） | 不清理 |

### 2.3 官方桌面端怎么取、怎么显示

**用到的路由**（Hermes 的用户文档里都没写这些路由，以后可能会变）：

| 路由 | 做什么 |
| --- | --- |
| `GET /api/fs/read-data-url?path=&profile=&session_id=` | 回 JSON `{"dataUrl": "data:image/png;base64,…"}`，最多 16 MiB；带 `Cache-Control: private, no-cache` 和 `ETag`，同一张图再取回 304（`hermes_cli/web_routers/files.py:1197-1233`） |
| `GET /api/fs/download?path=&profile=&session_id=` | 整个文件作为附件下载，不限大小；正在用的数据库文件不给（`:1356-1380`） |
| `GET /api/files/stream` | 音频、视频，支持 Range，不限大小（`:833-859`） |
| `GET /api/media?path=` | 只读 `images/`、`screenshots/`、`cache/` 下的图，回 JSON 的 data URL，最多 25 MiB。**不带 `profile`，只看 gateway 自己那个 profile**（`:405-448`） |
| `GET /api/media/proxy?url=` | 只代取 FAL 和 googleapis 这几个域名的图（`:456-510`） |
| `/api/files`、`/api/files/read`、`/api/files/upload`、`/api/files/mkdir`、`DELETE /api/files` | Webapp「文件」页用的一组，不带 `profile`（`:616-987`） |
| `/api/fs/list`、`/api/fs/read-text`、`/api/fs/write-text` | 带 `profile`（`:1012-1195`） |

**能读哪些文件**：默认不锁根目录，从 home 开始，可以填任何绝对路径。只有设了 `HERMES_DASHBOARD_FILES_ROOT`，或者 Hermes 根目录就是 `/opt/data`，才锁在一个目录里（`hermes_cli/web_server_files.py:409-428`）。总是拒绝的：
- 路径里的 `..`；
- 凭证文件：`.env*`、`auth.json`、`config.yaml`，还有 `mcp-tokens/`、`pairing/` 这类目录（`hermes_cli/web_routers/files.py:84-122,183-201`）；
- 带了 `session_id`、但会话不属于这个 profile（`:1171-1182`）。

也就是说，能登录 Hermes 的客户端，可以读这台机器上 Hermes 用户能读的几乎所有文件。Shion 正好可以用它取 `image_path` 和 `MEDIA:` 指的文件，不用改服务器。

**认证**：Shion 经 Cloudflare 连上来，服务器是「门控」模式（监听的不是本机地址，或者 `public_url` 不是本机地址，`hermes_cli/web_server_boundary.py:111-123`）。这时 HTTP 路由**只认请求头**：
- 验证过的 bearer、Hermes 的 cookie，或者 `X-Hermes-Session-Token`（`hermes_cli/dashboard_auth/middleware.py:281-328`）；
- `?token=` 只在本机模式下认，而且只在 `/api/files/download` 上认（`hermes_cli/web_server.py:313-327,459-478`）；
- 下载票据 `POST /api/files/ticket` 只在 Webapp 上有，给浏览器用：60 秒、3 次，流 1 小时，存在内存里（`hermes_cli/web_server_file_tickets.py:37-48`）。Shion 能带请求头，用不着它。

**桌面端的做法**：
- **服务器上的图**：`<img>` 从不直接指向 gateway。在 Electron 的主进程里带上凭证和额外请求头取 `read-data-url`，再交给页面（`apps/desktop/src/lib/media.ts:143-194`，`apps/desktop/src/lib/desktop-fs.ts:192-212`）。缓存只记图的尺寸，不存图的内容（`media.ts:201-205`）。
- **历史里你发的图**：用户消息末尾的几行 `[Image attached at: <路径>]` 加同样多个 `[screenshot]` 占位，换成 `@image:` 引用来显示（`apps/desktop/src/lib/chat-messages/hydration.ts:38-50`）。
- **`MEDIA:`**：整行换成 `[Image: 名字](#media:…)` 链接（`apps/desktop/src/lib/chat-messages/parts.ts:214-284`），再按类型显示：图片、音视频播放器，或者带「下载」「预览」的文件卡片（`apps/desktop/src/components/assistant-ui/markdown-text.tsx:306-330`）。
- **工具结果的图**：取结果或参数里的 `image_url`、`url`、`path`、`image_path` 字段（`apps/desktop/src/components/assistant-ui/tool/fallback-model/index.ts:805-822`），不看事件上的 `image_path`。
- **Markdown 里的网上图片**：直接放进 `<img>`，失败了再经 `/api/media/proxy` 试一次（`apps/desktop/src/hooks/use-media-image.ts:62,83-108`）。主窗口没有限制图片来源的 CSP，`<img>` 也没设 `referrerpolicy`（`apps/desktop/src/lib/local-preview.ts:167`，`apps/desktop/src/components/chat/zoomable-image.tsx:70`）。Shion 在隐私上应该做得比它好（第 4.4 节）。
- **点开图**：一个可以缩放、带下载按钮的窗口（`zoomable-image.tsx:32-120`）。
- **下载**：把 `/api/fs/download` 流式存到临时文件，再改名（`apps/desktop/src/lib/media.ts:441-472`）。
- **「作品」（Artifacts）页**：没有服务器接口，是客户端翻最近 30 个会话的消息找出来的（`apps/desktop/src/app/artifacts/index.tsx:130-147`）。
- **Cloudflare 那两个头**：每个连接存着「额外请求头」，`webRequest` 钩子给所有发往这个地址的请求加上，`<img>` 和 WebSocket 都在内（`apps/desktop/electron/main.ts:8209-8252`）。有几处漏了：会话令牌模式下的下载只带了 `X-Hermes-Session-Token`（`apps/desktop/electron/gateway-file-download-transport.ts:53-61`），所以经 Access 时可能下载不了。Shion 不要照抄这一处。

官方 dashboard 网页里的对话是一个终端（跑 TUI），不显示 `MEDIA:`（`agent/prompt_builder.py:719-724`），不用参考。

## 3. 有没有每个助手都能读的「空间」

**没有。** 文档、代码里搜了 space、shared、workspace、library、drive、files、attachments、artifacts、vault、projects，都没有这样的功能。Hermes 的文档说，几个助手要共享记忆，用外部的记忆服务（`website/docs/user-guide/profiles.md:12-14`）；共享文件没有提。

### 3.1 搜到的东西

| 东西 | 是什么 | 存在哪 | 每个 profile 一份，还是共用 |
| --- | --- | --- | --- |
| **看板附件** | 卡片上的文件，最多 25 MB 一个（`hermes_cli/kanban_db.py:136`） | `<Hermes 根>/kanban/attachments/<卡>/`，别的看板在 `<根>/kanban/boards/<slug>/attachments/<卡>/`（`hermes_cli/kanban_db.py:400-409,575-583`） | **整台服务器共用**，这是 Hermes 里唯一一个。<br>任何 profile 都能用 `kanban_attachments` 列出（它不查卡是谁的，`tools/kanban_tools.py:1064-1066`）。<br>派发卡片时，附件的绝对路径直接写进助手的上下文（`hermes_cli/kanban_db_context.py:111-124`）。<br>卡完成时，`kanban_complete(artifacts=[…])` 列出的文件也会复制进来（`website/docs/user-guide/features/kanban.md:135`）。<br>看板接口：`GET`/`POST /tasks/{id}/attachments`、`GET`/`DELETE /attachments/{id}`（`plugins/kanban/dashboard/plugin_api.py:464-528`） |
| 看板工作区 | 助手做这张卡时的工作目录 | `scratch` 在 `<根>/kanban/workspaces/<卡>/`，卡完成就删；`dir:<路径>` 是现有的共享目录（文档举的例子是 Obsidian 库），保留；`worktree` 是 git 工作树，保留（`website/docs/user-guide/features/kanban.md:134-137`） | 共用（同一台机器、同一个用户） |
| **群聊附件**（Bot Mode 的群） | 群里发的文件。Canonical 里有 `groups.attachment.upload` / `groups.attachment.download`（`tui_gateway/contracts/canonical.py:548-589`） | 群主那个 profile 的 `state.db` 旁边，一个私有目录（`gateway/hosted_room_attachments.py:1-8,93-96`） | **按群**：群里每个成员都是收件人（`gateway/session_hosted_attachments.py:60-67`）。<br>限制：每条 8 个、每个 15 MB、每条合计 25 MB、每个群 512 MiB（`gateway/hosted_room_attachments.py:34-41`）。<br>只在群对话里用；Shion 还没做群聊 |
| 项目（projects） | 只存元数据：项目名和文件夹（主机上的任意路径） | `$HERMES_HOME/projects.db`（`hermes_cli/projects_db.py:23-25`） | 每个 profile 一份 |
| 会话工作目录 | 终端从哪开始 | 每个会话一个 cwd。没配 `terminal.cwd` 的具名 profile，默认是它自己的 home（`tui_gateway/session_workdir.py:161-167`）；gateway 在 local 后端下没配 cwd 时，是 `$HOME`（`gateway/cwd_placeholder.py:24-34`，`gateway/run_bootstrap.py:599`） | 每个会话一个 |
| 对话附件、上传、连接器下载 | 第 1 节的 `attachments/`、`uploads/`；`downloads/connectors/`（`hermes_constants.py:294-295`） | 各自的 home | 每个 profile 一份 |
| Vault | 加密的凭证，不是文件（`agent/vault_store.py:209`） | `<home>/vault/` | 每个 profile 一份 |
| 插件数据 | Hermes 给插件的 `plugin_data_dir()` 和 `ctx.state`（`plugins/plugin_storage.py:27-33`，`hermes_cli/plugins_state.py:142-143`） | `<home>/plugin-data/<插件>/` | 每个 profile 一份。<br>**`shion` 插件故意不用它**：它用 Hermes 根目录（`hermes-plugin/shion/plugin.py:30-37`），所以 `shion.db` 是所有助手共用的一份（`hermes-plugin/README.md` 的「数据存在哪」）。文件区可以照这个办法 |
| 共享技能目录 | `skills.external_dirs`，只读的技能（`hermes_cli/config_defaults.py:1430-1433`） | 自己指定 | 共用，但只放技能 |

### 3.2 profile 之间怎么隔离：文件上不隔离

- Hermes 的文档写得很明白：「Profiles do **not** sandbox the agent」，local 后端下助手的文件权限和你的用户账户一样（`website/docs/user-guide/profiles.md:232-236`）。
- 安全策略：对一个不可信的模型来说，唯一的边界是操作系统，进程里的各种检查都不算边界（`SECURITY.md:58-66`）。文件工具的那些检查「是纵深防御，不是安全边界」（`agent/file_safety.py:1-5`）。
- 以前有一道「不许写别的 profile」的检查，已经删了（`tools/file_tools_write_guards.py:430-433`）。
- 现在的拒绝名单只管当前 profile 的 home 和 Hermes 根目录（`agent/file_safety.py:36-45`）：
  - 不让读凭证文件和 `mcp-tokens`、`vault` 这类目录（`:337-372`）；
  - 不让写 `state.db`、`sessions` 等（`:251-252`）；
  - 叫 `.env` 的文件在哪都不让读（`:337-340`）。
- `vision_analyze` 在 local 后端下能读任何路径（`tools/image_source.py:198-209`）。

所以在 local 后端下：
- 助手 A 能读写 `/srv/shared` 这样的目录，只受 Unix 权限限制；
- 也能读助手 B 的 home 下的大部分东西，`.env` 之类除外。这一条是读代码得出的，没实际跑过。

换成 docker 后端时：
- 容器就是边界，每个 profile 一个容器（`tools/environments/docker.py:124-133,645-647`）；
- 共享目录要在每个 profile 的 `terminal.docker_volumes` 里挂进去（`hermes_cli/config_defaults.py:352-357`），Hermes 文档把「共享工作区」列为它的用途之一（`website/docs/user-guide/configuration.md:719-722`）；
- 但执行代码的工具、MCP 子进程、插件仍然在主机上跑，不受容器限制（`SECURITY.md:70-88`）。

**我们的助手现在用的是哪个后端，没核实**，要看 VPS 上每个 profile 的 `terminal.backend`。

### 3.3 云桌面的文件系统和助手的文件工具是不是同一个

**是同一个。** local 后端下：
- 云桌面跑在 gateway 那台机器上，用同一个 Unix 用户和真实的 `HOME`（`tools/bot_desktop/runtime.py:784-790`）；
- 桌面下方的 dock 里有终端、浏览器、文件管理器（`tools/bot_desktop/launcher.sh:147-154`）；
- 文档原话：「the bots share the host's user account, files and network」（`website/docs/user-guide/features/bot-screen.md:20-23`）。

分开的只有每个助手的桌面设置和浏览器配置，在各自的 `<home>/bot-desktop/` 下（`tools/bot_desktop/runtime.py:4-9`，`tools/bot_desktop/browser.py:25-31`）。浏览器下载的文件存到哪，没找到设置，推测是大家共用的 `~/Downloads`（没核实）。docker 或 ssh 后端时，桌面跑在沙箱里，用户是 `pn`（`tools/bot_desktop/sandbox_host.py:32-35`）。

### 3.4 MCP 和云盘

- Hermes 自带的可选 MCP 里，和文件有关的只有 Dropbox，是官方的远程 MCP，用 OAuth 登录（`optional-mcps/dropbox/manifest.yaml:1-21`）。
- Google Drive 走 `google-workspace` 技能（`skills/productivity/google-workspace/SKILL.md:3`），令牌按 profile 存（`skills/productivity/google-workspace/scripts/google_api.py:38-42`）。Box 有一个技能（`optional-skills/productivity/box/SKILL.md:3`）。
- 文件系统 MCP 只在文档里当配置的例子（`website/docs/user-guide/features/mcp.md:35-40`）。
- 没有 S3、R2、iCloud 的。
- MCP 按 profile 配：每个 profile 的 `config.yaml` 里有自己的 `mcp_servers`（`tools/mcp_tool_config.py:709-710`），OAuth 令牌在各自的 `mcp-tokens/`（`tools/mcp_oauth.py:230-233`）。
- iCloud Drive：服务器上没有官方接口可用（没核实），只能在 Mac 这边用。

## 4. 限制

### 4.1 大小

| 哪一层 | 上限 | 出处 |
| --- | --- | --- |
| Cloudflare 的 HTTP 请求体 | Free、Pro 100 MB，Business 200 MB；超了直接 413，到不了 VPS。看的是域名的套餐，不是 Workers 的套餐 | [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)、[Error 413](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/) |
| Cloudflare 的 WebSocket 消息 | 没写明上限。只写了：一段时间没数据会断开；Cloudflare 发版重启服务器时会断开；所有套餐都能用 WebSocket。Workers 里的 WebSocket 消息上限是 32 MiB，和经代理的连接不是一回事 | [WebSockets](https://developers.cloudflare.com/network/websockets/) |
| Cloudflare 等源站 | 125 秒内源站没开始回应，是 524；往源站写数据 30 秒写不完，也是 524；只有 Enterprise 能调 | [Error 524](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/) |
| Hermes 的 `/api/ws` 单条消息 | 384 MiB | `hermes_cli/web_server_boundary.py:24-26` |
| Hermes 的 WebSocket ping | 每 20 秒一次，20 秒内要回（`dashboard.ws_ping_interval`、`ws_ping_timeout`）；监听本机地址时不 ping | `hermes_cli/web_server_lifecycle.py:578-603`，`hermes_cli/web_server.py:1045-1069` |
| 一张图 | 25 MiB | `tui_gateway/prompt_attachments.py:21`，`hermes_cli/web_upload_limit.py:20` |
| 一条消息的图 | 10 张，合计 128 MiB | `gateway/session_ingress_media.py:123,277-281` |
| `file.attach` 的 `data_url` | 256 MiB | `tui_gateway/prompt_attachments.py:20` |
| `/api/chat/file-upload` | 16 MiB（只在 Webapp 上有） | `hermes_constants.py:29` |
| `/api/fs/read-data-url` | 16 MiB | `hermes_cli/web_routers/files.py:1197-1233` |
| 看板附件 | 25 MB | `hermes_cli/kanban_db.py:136` |
| `session.transcript` 一页 | 2 MiB | `tui_gateway/contracts/canonical_stored_reads.py:61-81` |
| Shion 收 WebSocket 消息 | 现在设成 64 MiB（系统默认 1 MiB，这个值只管收、不管发）；看板的事件流是 16 MiB | `macos/Shion/Gateway/Gateway.swift:145-146`，`macos/Shion/Gateway/Kanban.swift:103` |

由此推出：

- **base64 会大三分之一。** 25 MiB 的图编成 base64 约 33 MiB。走 HTTP 时，它是一个普通的请求体，远低于 100 MB。
- **大的东西不要塞进一条 WebSocket 消息。**
  - 一条消息发送期间，同一条连接上的别的东西（ping 的回应、`gateway.ping`、你的下一句话）都排在它后面。上行慢的时候，发 30 MB 要几十秒，可能被服务器当成断线；断了整条重来。这一条是推断，没实测。
  - Cloudflare 发版重启服务器也会断开连接。
  - 所以对话里的文件要么走 HTTP，要么限制大小；更大的文件分成几 MB 一块传，断了从断的那块接着传。
- **Hermes 现有的接口都不分块**：`file.attach` 是一整条消息，`/api/chat/*-upload` 是一个请求，都不能续传。要分块只能自己做（第 6、8 节）。
- Cloudflare 收大请求时，是边收边转给源站，还是收完再转，文档没写（没核实）。分块也能绕开这个问题。

### 4.2 每个请求都要带 Access 的头和 Hermes 的凭证

- 下载图片、文件和别的 REST 请求一样，要带：
  - `CF-Access-Client-Id`、`CF-Access-Client-Secret` 两个头；
  - Hermes 的凭证：`Authorization: Bearer <登录凭证>`，或者 `X-Hermes-Session-Token`。
- Shion 已经有这两处代码：`ServerSettings.applyAccessHeaders`（`macos/Shion/Gateway/ServerSettings.swift:95-113`）和 `macos/Shion/Gateway/SignIn.swift:21-28`。
- 门控模式下，HTTP 不认 `?token=`（第 2.3 节），凭证只能放请求头。所以 **不能用 SwiftUI 的 `AsyncImage`**（它不让加请求头），也不能让 `WKWebView` 直接显示服务器上的图。服务器上的图片、文件，都要经 Shion 自己的 `URLSession` 取回来，再交给 ImageIO 解码显示。
- 根 README 写过，严格 service token 认证下，带 token 的请求只看 token，所以下载请求不会被转去 Access 的登录页。token 不对时是 401 或 403，要显示成「连不上服务器」，不是「图片坏了」。

### 4.3 Cloudflare 的缓存

- Cloudflare 默认**按扩展名**缓存：png、jpg、jpeg、gif、webp、svg、pdf、zip、docx、mp4 等，不看 MIME 类型（[Default cache behavior](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/)）。
- 有下面几种情况才不缓存：源站回了 `Cache-Control: private`、`no-store`、`no-cache` 或 `max-age=0`；带了 `Set-Cookie`；不是 GET 请求。
- 请求带 `Authorization` 头时，「Origin Cache Control」开着的话（Free、Pro、Business 默认开，而且关不掉），回应要写了 `public`、`s-maxage` 或 `must-revalidate` 才缓存（[Origin Cache Control](https://developers.cloudflare.com/cache/concepts/cache-control/)）。
- **用会话令牌登录时，请求里没有 `Authorization` 头，上面这条就管不着。**

现有的路由：
- `/api/fs/read-data-url` 回 `private, no-cache`；
- `/api/fs/download` 的路径不以扩展名结尾。

这两个不会被缓存。要看扩展名时，Cloudflare 只看路径还是连查询参数一起看，文档没写。

以后插件自己的下载路由（第 8 节）：
- 路径不要以 `.png`、`.pdf` 这类扩展名结尾，用 id；
- 一律回 `Cache-Control: private, no-store`。

不然别人只要过了 Access，就可能从 Cloudflare 的缓存直接拿到你的文件。Access 和缓存谁先谁后，文档里没找到，按最坏的情况处理。最省事的办法：在 Cloudflare 上给这个域名加一条 Cache Rule，`/api/*` 一律不缓存（Bypass cache）。

### 4.4 网上的图片

助手回复里的 `![](https://…)` 指向别人的网站。Shion 一去取，对方就知道你的 IP，和你什么时候看了这条回复；图片地址本身也可能是追踪用的，邮件里很常见。

- 默认不自动取网上的图。显示成一块占位，写着网站名和「显示图片」；设置里可以改成「总是显示」，或者对某个网站总是显示。
- 取的时候：
  - 用不带 Cookie、不发 Referer 的临时 `URLSession`（`.ephemeral`）；
  - 只认 `image/*`，最多 20 MB；
  - 只用 ImageIO 解码；
  - 不显示 SVG，SVG 里可以有脚本和外链。
- 也可以让服务器代取，对方看到的就是 VPS 的 IP。但 Hermes 的 `/api/media/proxy` 只认 FAL 和 googleapis 几个域名（第 2.3 节）；要代取任意网站，得在插件里做，还要防 SSRF：不能让人借它访问 VPS 内网。
- 本机和局域网的地址（`localhost`、`127.0.0.1`、`192.168.x.x`、`file://`）一律不取。

### 4.5 Mac 上的缓存

- **放哪**：磁盘上放 `~/Library/Caches/<bundle id>/media/`，按内容的 sha256 存（服务器上的 native-inputs 也按 sha256 存，能对上）。另记一张表：服务器地址 + profile + 服务器路径 → sha256。
- **上限**：总量设一个上限（比如 1 GB），超了按最近使用的顺序删。
- **你发出去的图单独放，不按上限删。** 服务器只留 24 小时（第 1.3 节），过了这个时间，历史里的图只能从 Mac 上的这份显示。删对话时一起删。
- **截图和 `MEDIA:` 的图**：取到后也存一份，因为截图的路径不进对话记录，服务器上 24 小时后也会清。
- **内存里**：解码后的缩略图放 `NSCache`。
- **不用 `URLCache`**：它按 URL 存，换了凭证也照样命中，也不好按对话清理。
- **什么时候清**：换服务器、退出登录时，清掉服务器文件的缓存，你发出去的图除外。

## 5. 缺什么

**Shion**：
- 输入框不能加附件；`send` 只发文字（`macos/Shion/Model/AppStore.swift:169-194`）；`ChatItem` 没有附件字段（`macos/Shion/Model/Models.swift:130-143`）。
- 回复里的 Markdown 图片只显示成文字链接（`macos/Shion/Views/MarkdownDocument.swift:254-259`）。
- 不认 `MEDIA:`、`@image:`、`@file:`、`[Image attached at: …]`，会把原文直接显示出来。比如别的客户端发过图的对话，读进来就是这样。回复里直接写的文件路径，也只是一段文字。
- 不管工具结果的 `image_path`。
- 没有带认证的图片加载和缓存，没有「文件」页。

**Hermes**：
- 没有统一的空间。
- 上传不分块、不能续传。
- 截图、生成的图的路径不进对话记录；缓存 24 小时就删。
- 文件路由没写进用户文档；`/api/media` 只看 gateway 自己那个 profile。
- local 后端下，没有按助手的文件权限。

**`shion` 插件**：没有任何和文件有关的东西。

## 6. 「空间」的几种做法

| | A. 服务器上一个共享目录 | B. 扩展 `shion` 插件做文件区（A 的目录，加插件管理） | C. 云盘，经 MCP | D. 只用看板附件 | E. 群聊附件 |
| --- | --- | --- | --- | --- | --- |
| 助手怎么用 | local 后端下，文件工具、终端、`vision_analyze` 直接读写；docker 后端要挂载（第 3.2 节）。交给你时写 `MEDIA:` 就行（默认模式下，存在的文件都能交，`gateway/platforms/base.py:763-787`） | 和 A 一样，另外有插件的工具：列出、搜索、存进空间 | Dropbox 的 MCP、Google Drive 的技能；要先下载到本机，才能用文件工具和 `vision_analyze` 看 | `kanban_attachments`，按绝对路径读 | 群里每个成员发言时自动拿到 |
| Shion 怎么用 | 读：Hermes 的 `/api/fs/list`、`/api/fs/download`。写：Webapp「文件」页用的 `/api/files/upload-stream`，multipart 一个请求，最多 100 MiB（`hermes_cli/web_routers/files.py:935-955`，`hermes_cli/web_server.py:661`）。这些都没写进文档，也不能续传 | 插件的 RPC 加 HTTP 路由：列表、分块上传、带 Range 的下载、推送 | 直接用云的接口（比如预签名地址，不经 Tunnel，没有 100 MB 的限制），或者 Mac 上的同步盘 | 看板接口已经接好了，加上附件就行 | 要先做群聊 |
| 谁放的、说明、在哪用过 | 没有，只有文件名和修改时间 | 有 | 云盘自己的 | 按卡片 | 按群 |
| 按助手分权限 | 做不到 | 只能是「软」的：插件的工具和列表按助手过滤，但助手用文件工具能绕过去 | 能按凭证分；但凭证在各 profile 的目录里，local 后端下互相读得到 | 做不到 | 按群成员，只是逻辑上的 |
| 大文件 | 取决于怎么传上去 | 分块，不受 100 MB 限制 | 云决定 | 25 MB 一个 | 15 MB 一个 |
| 和 Mac 同步 | 没有；要看就下载，或者另装 Syncthing 这类同步程序 | 「文件」页实时推送列表，文件按需下载，Mac 上不放整份 | 云盘自己的客户端同步到 Mac | 随看板 | 随群 |
| 备份 | 普通目录，rsync、restic 都行 | 同 A，再加上 `shion.db` | 云盘自己管 | 跟着看板 | 跟着群主的 `state.db` |
| 文件离不离开 VPS | 不离开 | 不离开 | **离开**，放到第三方 | 不离开 | 不离开 |
| 要做的事 | 选一个目录，写进每个助手的 SOUL 或一个技能 | 插件和 App 都要写；工作量最大 | 每个助手配 MCP 和凭证；App 接云的接口 | App 加上传附件 | 整个群聊功能 |
| 适合 | 先试一下 | 长期用 | 本来就用某个云盘存资料 | 交给助手的材料 | 几个助手一起讨论 |

还有一种：用 Syncthing、Mutagen 之类，把 Mac 上的一个文件夹和 VPS 上的共享目录（A）同步。这样在 Finder 里放文件就行，Shion 不用做上传；代价是 VPS 和 Mac 上各要装一个同步程序，两边同时改还会冲突。

**为什么推荐 B，而且 B 用的是 A 的目录**：
- 助手不需要学新东西。空间就是一个普通目录，读写都用它们本来就会的文件工具、`vision_analyze`，交给你还是写 `MEDIA:`。
- Shion 需要的东西 A 给不了：谁放的、在哪个对话或卡片里用过、分块上传、实时推送。这些由插件补上，和待办、日报放在同一个 `shion.db` 里，所有助手看到的是同一份。
- 读写都走我们自己的插件接口，不依赖 Hermes 没写进文档的 `/api/fs/*`（第一步取对话里的图还是要用它们）。
- 文件不离开 VPS，备份就是复制一个目录、一个数据库。

**权限**：在现在的部署下，每个助手都能读空间里的所有东西，其实也能读整个 home（第 3.2 节）。按助手分权限，只有在助手换成 docker 后端、只挂它能看的子目录之后才有意义。所以第一版不分，在设置里写明「空间里的东西每个助手都能看到」；要放机密的东西，就别放进空间。

## 7. Shion 这边的界面（需求和设计）

按根 README 的「界面原则」：
- 说明只写在设置里，主窗口里不加解释；
- 颜色只有三种意思：紫色是选中和主操作，暖橙是在等你，红色是逾期、「此刻」、你在操作云桌面（App 里出错的提示也用这个红，比如设置里连不上时）；
- 动的东西只有呼吸点和流式输出的光标。

### 7.1 对话里上传

**入口**
- 把文件拖到对话区的任意位置：整个对话区出现一圈紫色描边，松手就加进输入框。
- 在输入框里按 ⌘V：剪贴板里是图片就当图片，是从 Finder 复制的文件就当文件。
- 输入框左边加一个「＋」按钮，打开文件选择，可以多选。
- 从「文件」页拖一个文件进来：不重新上传，消息里直接写它在服务器上的路径（第 8 节的第二步）。

**输入框里怎么显示**
- 输入框上方一排：图片是 56 pt 的缩略图，文件是图标、文件名和大小；每一项右上角有一个「×」。
- 加进来就开始上传，缩略图上显示一圈进度。全部传完，发送按钮才能点；传完之前它是灰的，不弹提示。
- 传不了的（太大、类型不支持、断线），那一项标红，悬停时显示原因，点它重试。
- 发出去以后，附件显示在你那条消息里，不显示 `@file:` 这类原文。

**发之前，先在 Mac 上处理图片**
- 转格式：Hermes 只收 PNG、JPEG、GIF、WebP（第 1.1 节）。HEIC、TIFF、BMP 用 ImageIO 转成 JPEG，带透明的转成 PNG；GIF 原样发，因为它可能是动图。
- 缩小：长边超过 2048 像素的，缩到 2048。视觉模型自己也会缩小，大图只是多花流量和 token。这个数可以在设置里改，也可以选「发原图」。
- 去掉 EXIF 里的位置信息，拍摄时间、相机型号也一起去掉。设置里写明「发出去的照片不带位置」。
- 一条消息最多 10 张，超了就在第 11 张上标红。

**怎么发**
- **图片**：用 `POST /api/chat/image-upload?profile=<助手>` 上传。它走 HTTP，能显示进度，也不占着 WebSocket。拿到路径后，发送时放进 `prompt.submit` 的 `attachments`。
  - 暂存的图 24 小时后会被删（第 1.3 节）。草稿放久了，发送时服务器会回 `invalid_params`，这时自动重新上传一次再发。
- **文件**：
  - 先试 `POST /api/chat/file-upload?profile=<助手>`（只在 Webapp 上有，16 MiB），再用 `file.attach {staged_upload}` 换成引用；
  - 回 404 时，改用 `file.attach {name, data_url}`，不带 `path`，先限制在 16 MB 以内（原因见第 4.1 节）；
  - 更大的文件，等第二步的空间做好后先放进空间；在那之前，标红、写明上限。
  - 拿到引用后，放在消息文字的前面，一个一行，空一行再接你打的字，和官方桌面端一样。
- **换到别的助手的对话**：每个助手是不同的 profile，暂存的文件在各自的 home 下，所以已经加进输入框的附件，要按新的助手重新上传。
- **调 `image.attach_bytes`、`file.attach` 之前**，这个 Bot Chat 要已经在当前连接上 resume 过。Shion 连上后本来就会在后台 resume 每个 Bot Chat，断线重连后要等 resume 完再传。

### 7.2 对话里显示图片

**图从哪来、怎么认、从哪取**

| 图从哪来 | 怎么认出来 | 从哪取 |
| --- | --- | --- |
| 你发的 | 直播时，就是你刚加的那几个。<br>读历史时，看用户消息里的这几种写法：<br>- 末尾几行 `[Image attached at: <路径>]` 加同样多个 `[screenshot]`；<br>- 开头的 `@image:<路径>`、`@file:<路径>`；<br>- 只给路径时的 `[The user attached an image … image_url: <路径>]`。<br>Hermes 自己拆这几种写法的函数是 `agent/image_routing.py:566-591` 的 `split_image_notes`；桌面端在 `apps/desktop/src/lib/chat-messages/hydration.ts:36-50` | 先找 Mac 上的那份（按服务器路径和 sha256 对）；没有，再去服务器取；服务器上也没了（超过 24 小时），就显示一块灰色的「图片已过期」 |
| 工具结果的图 | 直播时：`tool.complete` 的 `image_path`，或者结果、参数里的 `image_url`、`path`、`screenshot_path`。<br>读历史时只剩参数（第 2.1 节） | `/api/fs/read-data-url` |
| 回复里的 `MEDIA:` | 一行里的 `MEDIA:/…`，规则照 `gateway/platforms/base.py:1216-1221,3150-3191`：代码块、引用里的不算 | 图片用 `/api/fs/read-data-url`，别的文件用 `/api/fs/download` |
| 回复里的 Markdown 图片 | `![说明](地址)` | `http(s)` 按第 4.4 节，默认不自动取；`/` 开头或 `file://` 的服务器路径，用 `/api/fs/read-data-url`；`data:` 直接解码，最多 20 MB |
| 回复里直接写的绝对路径（`cli` 会话） | 不在代码块里、以 `/` 或 `~/` 开头、扩展名在 Hermes 认的那张表里（`gateway/platforms/base.py:1172-1181`） | 先用 `HEAD /api/fs/download` 看文件在不在（`hermes_cli/web_routers/files.py:1356-1357`），在才显示成卡片；图片同上 |

取的时候都带上 `profile`、`session_id`、Access 的两个头和 Hermes 的凭证（第 4.2 节）。超过 16 MiB 的图，`read-data-url` 不给，改用 `/api/fs/download` 下载。

**样子**
- **你发的图**：在你的消息气泡里。一张时最宽 320 pt，按比例；两到四张排成两列；更多的折成「＋3」。
- **回复里的图**：单独占一块，最宽和正文一样，最高 480 pt。下面一行小字是图的说明（Markdown 里的 alt 文字），没有说明就不显示。
- **工具调用的截图**：折起来的那一行后面跟一排小缩略图，是这几次调用的截图；展开后，每条调用下面是它自己的图。
- **加载中**：显示一块同样大小的浅灰底，不转圈。
- **点图**：用 Quick Look（`QLPreviewPanel`）打开，可以放大，左右翻同一条消息里的图，存到「下载」，分享。
- **右键**：拷贝图片、存储为…、存进空间（第二步）。
- **长对话**：只有滚到附近的行才取图（`LazyVStack` 里的 `.task`），滚走了就取消。

**文件**：你发的、助手交的文件，都显示成一张小卡片，上面是图标、文件名、大小。点一下下载到「下载」文件夹，并用默认的应用打开；按住 ⌥ 点只下载，不打开。`::preview{…}` 小部件也先显示成这样的卡片。

### 7.3 「文件」页（空间）

侧栏里加一项「文件」，和「看板」并列。

- **列表**：每个文件写着名称、类型、大小、谁放的（你，或者哪个助手）、什么时候放的、出现在哪（哪个对话、哪张卡）。可以切换成缩略图网格。按名称搜索，按时间、大小、类型排序。
- **分类**：全部、最近、你放的、助手做的、按助手。看板卡片的附件也列在这里，按卡片分组，点了跳到那张卡。
- **放进来**：拖进窗口，或者点工具栏的「＋」。上传进度显示在工具栏右边，一个小进度条，传完就消失。
- **看**：按空格用 Quick Look 预览。右边的详情栏（`.inspector`）里是信息和操作：下载、发给詩音（把引用放进詩音的输入框）、改名、删除。
- **删除**：先进回收站，过一段时间（第 9 节）才真删；回收站里的可以恢复。
- **容量**：页面底部一行小字，比如「用了 1.2 GB」。上限和清理规则写在设置里。
- **没连上服务器时**：显示上次的列表，标出哪些已经下载到 Mac 上，这些可以打开；没传完的上传，连上后接着传。

## 8. 推荐方案：分三步

### 第一步：对话里的图片和文件（只改 App）

**App**：
1. 输入框的附件：拖拽、⌘V、「＋」；图片的格式转换、缩小、去位置信息（第 7.1 节）。
2. 上传和发送：图片用 `/api/chat/image-upload` 加 `prompt.submit.attachments`；文件用 `/api/chat/file-upload` 加 `file.attach`，没有这个路由时用 `file.attach {name, data_url}`，16 MB 以内。
3. 显示：
   - 你发的图，包括读历史时认出来的那几种写法；
   - 工具结果的图；
   - 回复里的 `MEDIA:`、直接写的文件路径和 Markdown 图片，网上的图点了才显示；
   - Quick Look 和文件卡片（第 7.2 节）。

   较早的 `cli` Bot Chat 里，助手被告知 `MEDIA:` 没用，只会写路径（第 2.1 节）。想让它像桌面端那样交文件，就新开一个 `gui` 的 Bot Chat（根 README「助手以为你在用什么界面」）。
4. 一个带认证的图片加载器，加上 Mac 上的媒体缓存：你发的图长期留，截图和 `MEDIA:` 的图取到就存（第 4.5 节）。
5. 设置里的说明：发出去的照片不带位置；网上的图要点了才显示；你发的图在服务器上只留一天，Mac 上留着一份。
6. 测试照现在的做法：`macos/ci/fake_hermes.py` 加上这几个路由的替身；截图测试加上带图的对话；端到端测试里发一张图，看替身收到的 `attachments`。

**服务器**：不用改。建议在 Cloudflare 上给 `/api/*` 加一条不缓存的 Cache Rule（第 4.3 节）。

**风险**：`/api/fs/*` 和 `/api/chat/image-upload` 没写进 Hermes 的文档，Hermes 改了，Shion 就要跟着改。官方桌面端也用它们，一般不会说改就改。

### 第二步：「空间」第一版（扩展 `shion` 插件）

**插件，存储**：
- 目录放在 `<Hermes 根>/plugin-data/shion/space/`，和 `shion.db` 放在一起，`SHION_DATA_DIR` 改了也跟着变。里面是普通的文件和子文件夹，助手按路径直接读。
- `shion.db` 里加一张表，记每个文件的：id、路径、大小、sha256、类型、谁放的、说明、从哪来（哪个对话或卡片）、删除时间。
- 每次列出时按修改时间对一遍目录。这样别的途径放进来的文件，比如助手直接写的、rsync 同步的，也会出现在列表里，只是没有说明。

**插件，给 Shion 的 RPC**（走 `/api/ws`）：
- `space.list`、`space.stat`；
- `space.update`：改名、移动、改说明；
- `space.delete`、`space.restore`：删除先进回收站，到期再真删；
- `space.import`：把服务器上的一个文件复制进空间，比如对话附件、`MEDIA:` 文件、截图。复制在服务器上做，不经过 Mac；
- `space.usage`：用了多少。

**插件，传字节**：
- 推荐用插件自己的 HTTP 路由，挂在 `/api/plugins/shion/` 下，和看板的接口一样：
  - Hermes 会把插件 `dashboard/manifest.json` 里 `api` 指的文件，当作 FastAPI 路由挂上去（`hermes_cli/web_server_dashboard.py:1058-1085`）；
  - 前提是插件在 gateway 自己那个 profile 的 `plugins.enabled` 里（`:846-860`）。现在插件 README 说那个 profile 不用装，这一步要改成也装上；
  - 认证和别的 `/api/*` 一样（看板的接口就是这样）。
- 上传分块：每块不超过 8 MB，可以续传，最后提交时校验 sha256。
- 下载：流式、支持 Range（可以续传）；回 `Cache-Control: private, no-store`；路径用 id，不带扩展名（第 4.3 节）。
- 不想动 gateway 那个 profile 的话，也可以全走 RPC，分块读写，每块不超过 4 MB；缺点是占着对话的那条连接（第 4.1 节）。

**插件，推送**：在 revision 和 `changes.since` 里加一个 `space` 话题，「文件」页实时更新（插件现有的推送机制，见 `hermes-plugin/README.md`）。

**插件，给助手的工具**：
- `space_list`：按文件夹、关键字列出；
- `space_info`：返回绝对路径和说明，让助手用 `read_file`、`vision_analyze` 去读；
- `space_save`：把自己工作目录里的文件存进空间，附一句说明。
- 在每个助手的 SOUL，或者一个技能里写清楚：要长期保留、要给别人用的东西放进空间；交给你的时候照样写 `MEDIA:`。

**插件，其他**：
- 容量：设置项 `space_quota_gb`，满了就拒收；回收站的保留天数也是一个设置。
- 测试：pytest，照现有的 `FakeCtx`。

**App**：
- 做「文件」页（第 7.3 节）；
- 对话里的图片、文件加「存进空间」，调 `space.import`；
- 从「文件」页拖进对话：引用它在服务器上的路径；
- 第一步里超过 16 MB 的文件，改成先传进空间，再引用。

**服务器**：更新插件；在 gateway 自己那个 profile 也启用插件（用 HTTP 路由才需要）；重启 gateway。

### 第三步：以后，按需要

- **备份**：服务器上加一条定时任务，用 rclone 或 restic，把空间目录和 `shion.db` 推到 R2 或别的地方。Hermes 自己的备份（`/api/ops/backup/download`，`hermes_cli/web_routers/ops.py:602-618`）带不带 `plugin-data`，没核实。
- **按助手分权限**：前提是把助手换成 docker 后端，用 `terminal.docker_volumes` 只挂它能看的子目录；插件的列表和工具再按 profile 过滤。
- **看板附件进「文件」页**：看板的接口已经接好了。
- **Finder 里直接看到空间**：用 File Provider 扩展，按需下载；Spotlight 也能搜到。
- **云盘作为另一个来源**：Dropbox 的 MCP、Google Drive 的技能。只是来源之一，不当主存储。

## 9. 要你决定的问题

1. **空间放在哪**：VPS 上（推荐），还是云盘（Dropbox、Google Drive、R2）？放云盘的话，文件会离开 VPS。
2. **每个助手都能读空间里的所有东西，可以吗？** 现在的部署下，真正按助手隔离做不到，除非把助手换成 docker 后端（第 3.2 节）。推荐第一版不分。
3. **空间的目录**：`~/.hermes/plugin-data/shion/space/`（推荐，和 `shion.db` 一起备份），还是你指定一个已有的文件夹，比如你想同步到 Mac 的那个？
4. **对话里的东西要不要自动进空间**：你发的文件、助手用 `MEDIA:` 交的文件、生成的图。推荐都不自动进，在消息上点「存进空间」；也可以只让生成的图自动进。
5. **网上的图片**：点了才显示（推荐），还是直接显示？
6. **发图前缩小到长边 2048 像素、去掉位置信息**（推荐），还是默认发原图？
7. **空间的容量和回收站**：推荐 10 GB，删了的留 30 天。要不要定期备份到云（R2），多久一次？
8. **传文件的字节**：走插件自己的 HTTP 路由（推荐，要在 gateway 自己的 profile 也启用插件），还是全走 WebSocket 上的 RPC？

## 10. 没核实的地方

- Cloudflare Tunnel 指向的是 Webapp 的端口，还是 gateway 自己的监听。这决定 `/api/chat/file-upload` 能不能用；不能用时，第一步有退路。
- 我们的每个助手用的是哪个终端后端（local 还是 docker）。这决定空间目录要不要挂载、权限能不能分。
- Shion 的 Bot Chat 里，`tool.complete` 带不带 `image_path`：按代码应该带，因为它是本地会话。
- gateway 替助手补的 `MEDIA:` 行，会不会进 `message.complete` 和存下来的回复。
- 别的助手（不是 gateway 自己那个 profile）的缓存，会不会被 24 小时清理；`attachments/`、`cache/browser-use/` 有没有清理。
- 一个助手能不能真的读到另一个助手的 `auth.json`、`mcp-tokens/`、`SOUL.md`：只读了代码，没实际试。
- 云桌面的浏览器把下载的文件存在哪。
- Cloudflare 收大请求时是不是边收边转；一条几十 MB 的 WebSocket 消息在真实线路上会不会因为 ping 超时被断开；Access 和缓存谁先谁后。
- iCloud Drive 在服务器上能不能用。
- Hermes 自己的备份带不带 `plugin-data`。
