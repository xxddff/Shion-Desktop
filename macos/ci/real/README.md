# 对着真的 Hermes，接一个假的模型

`macos/ci/fake_*.py` 是照着 Hermes 的源码和抓到的数据写的替身，CI 上的端到端测试跑的是它。这个目录反过来：Hermes 是真的，模型是假的。用来核对「只有模型回话才会发生」的那些轮次，Hermes 实际给观看者发了什么帧、存了什么行，再看 Shion 和替身是不是照这个样子。

没有 CI 步骤跑它，改了和这些轮次有关的代码（`Model/Notices.swift`、`Model/NoticeCards.swift`、重连、`Model/SkillReviewTalk.swift` 和 `Gateway/EventCursors.swift` 里读快照的部分）或者服务器的 Hermes 升级之后手动跑一遍。

## 怎么跑

需要 Docker。先建好带 Hermes 的镜像（钉在哪个提交写在那个脚本里）：

```bash
../../../hermes-plugin/test-with-hermes.sh true
```

再跑：

```bash
./run.sh
```

容器不联网。里面做的事（`inside.sh`）：

1. `mock_model.py` 在 `127.0.0.1:9911` 上扮一个 OpenAI 兼容的模型，按请求最后一句话决定回什么（一句话、一次工具调用、几兆字节的长回复、说到一半等探针放行再说完的回复），每个请求记一行日志。它报的用量都是 100 个提示 token，只有最后一句话里有「满了」的请求报 6000。压缩要的摘要不按这些规则（要摘要的那几轮里什么话都有），一律回一句固定的话。
2. Hermes 的 `config.yaml` 写成 `provider: custom`、`base_url: http://127.0.0.1:9911/v1`。
3. 建三个 profile（默认的、`study`、`commute`），`profile.yaml` 里都写上 `ui_meta['hermes-bots']`：Hermes 只在这样的安装上给 Bot Chat 提供 `message_agent`。`commute` 的 `config.yaml` 另外写上 `compression.in_place: false`：它压缩对话时换成新的会话，别的 profile 照 Hermes 默认的原地压缩。再建两个 profile，`diary` 和 `errand`，`compression.threshold_tokens: 4000`，上下文过了这个数 Hermes 自己压缩；`errand` 也写上 `compression.in_place: false`。它们也标成 Bot Mode 的，好让詩音能给它们带话（`copies` 阶段）。压缩的其余设置是 Hermes 默认的。
4. 起 `hermes gateway run`，然后 `probe.py` 像 Shion 那样连上去（`hermes gateway attach` 给的地址和票据；一张票只管一个 profile），建 Bot Chat，发话，把收到的帧和读到的行打印出来、存成 JSON。

gateway 是经 `hold_gateway.py` 起的：Hermes 的文件一个不改，只在进程里把 `gateway/session_viewer_close.py` 的 `cancel_persisted_close` 包了一层。Hermes 接上一个观看者时（`session.resume`、`session.create`）先在一把锁里把它加进会话的帧流、读好快照，出了锁再等两件事才回答，头一件就是这个函数。包的那一层在 `/out/hold-attach` 这个文件存在时停在那里，文件没了才往下走；文件不存在时什么都不等，和直接起 gateway 一样。停的是一个工作线程，gateway 的事件循环照常转，所以这期间会话发布的帧先到观看者，快照后到。

`probe.py` 的几个阶段：

| 阶段 | 做什么 |
| --- | --- |
| `plain` | 普通的一轮 |
| `peer` | 让詩音给课程带个话（`message_agent`）：课程的 Bot Chat 里 Hermes 自己起一轮，回话作为后台任务结果回到詩音那边；再来一次，这次课程那边没人看着，回来后补播 |
| `peer2` | 不要回复的消息、对方没回话、一次问两位 |
| `background` | 后台跑一条命令，结束时 Hermes 自己起一轮 |
| `gap` | 一个不读数据的观看者，等一段几兆字节的回复把它落下 4 MB 以上，Hermes 结束它的订阅（`session.replay_gap`），再看它怎么接回来 |
| `behind` | 一轮的结束赶在 `session.resume` 的回答前面：建一个审核技能用的那种会话（隐藏、没有工具），发一句让模型说到一半停住的话；这一轮还在跑时再读一次会话，回答被 `hold_gateway.py` 按在读完快照之后；放模型说完，等 `message.complete` 和 `session.info` 到了，再放回答 |
| `compact` | 一轮里模型跑一条要三秒的命令（「慢慢做」），命令跑着时像 Shion 那样把「继续」引导进去（`session.steer`）；然后压缩对话（`session.mutate` 的 `compress`）。再说一句普通的「继续」，再引导一次「继续」，再压缩一次。第三次压缩之前让一条后台命令跑完（「后台跑一下」：Hermes 拿它的结果自己起一轮），压缩以后再来一条；第四次之前停掉一轮（`session.interrupt`），压缩以后先按它压缩前的行号、再按新的行号把它收回（`session.mutate` 的 `rewind`）。每次压缩以后，还按压缩前的行号各收回一次留下来的和总结掉的一句话。默认 profile 原地压缩，`commute` 换成新的会话。每次压缩前后读最新一页，再直接读 `state.db` 里所有的行（归档的、旧会话的也在内）；检查用的页和回答另外存成 `compaction-send.json`（`../logic/send` 用）和 `compaction-notices.json`（`../logic/notices` 用） |
| `auto` | Hermes 自己压缩：两句要长回复的话，一句普通的「继续」，一轮里引导进去一句「继续」，一条后台命令和它的结果起的一轮，一句「满了」（它的回复说上下文满了）。下一轮一开始 Hermes 就压缩（preflight）；再来一条后台结果；再一轮里命令的结果回来时上下文又满了，Hermes 在这一轮中间压缩（post_tool），命令跑着时读一次最新一页；再来第三条后台结果。按压缩前的行号收回每一句你说的、留下来的或总结掉的话，最后按新的行号收回中间压缩的那一轮。`diary` 原地压缩，`errand` 换成新的会话。每次压缩前后读最新一页和 `state.db` 里所有的行，压缩前读最新六行，压缩后拿它的游标往上读；检查用的页和回答另外存成 `autocompaction-send.json`、`autocompaction-notices.json` |
| `queued` | 一轮在跑（「慢慢做」）时，像 Shion 那样先发两句排队的话（`prompt.submit`，Hermes 排在这一轮后面），再把「继续」引导进这一轮；再说两句要长回复的话和一句「满了」，下一轮一开始 Hermes 压缩，这一轮里再引导进一句「继续」；最后一条后台结果。`diary` 原地压缩，`errand` 换成新的会话。读每次的最新一页和库里的行，记下每次运行的帧里 `pending` 说的是哪一条提交；页另外存成 `queued-send.json` |
| `copies` | Hermes 自己压缩时，Bot Chat 里替你存的每一种行变成什么（`diary` 原地压缩，`errand` 换成新会话）：两句要长回复的话；然后一条后台结果，一轮里引导进去的「继续」，两条后台结果合并成的一轮（两条命令在后台跑着时，另一轮跑一条八秒的命令），詩音用 `message_agent` 给它带的话（她的 Bot Chat 在另一条连接上），它给课程带话、课程的回话作为后台结果回来；一句「满了」，下一轮一开始 Hermes 压缩。再来出错的一轮（假模型回 400），说到一半被停掉的回复，发的时候标成隐藏的一句（`display_kind: hidden`）；再「满了」，再压缩。每次压缩前后读最新一页、读库，记下每一轮开始帧带了什么、每次运行是哪一条提交、结束时存成了哪几行 |

结果在 `captures/`（不进仓库）：每个阶段一份 `capture-*.json` 和打印的 `*.txt`，还有 `gateway.log`、`mock-model.log`。

## 拿应用自己的代码读

有 Swift 编译器的地方（Mac，或装了 Swift 的 Linux，`SWIFTC` 指编译器）：

```bash
./read_notices.sh captures/capture-peer.json captures/capture-peer2.json captures/capture-background.json
```

它把 `Shion/Model/Notices.swift` 原样编进去，对每个开始帧和每一行打印对话里会显示成什么。

```bash
./read_behind.sh captures/capture-behind.json
```

这个把审核会话的 `Shion/Model/SkillReviewTalk.swift` 和 `Shion/Gateway/EventCursors.swift` 原样编进去（应用的其余部分用 `ci/logic/talk/stubs.swift` 顶替），按抓到的顺序把帧和快照喂给它，逐项检查，有不对的以非零退出。走两遍：一遍照实际发生的（旧快照之后再问一次，拿到新的）；一遍假设每次再问拿到的都和第一份一样旧（把抓到的那份旧快照重复给它），看它只靠旧快照和帧能不能把话显示对。第二个参数可以换一份 `SkillReviewTalk.swift`，比如改动之前的，看它在哪一项上不对。

`compact`、`auto`、`queued`、`copies` 几个阶段存下的页和回答是 `../logic/send`、`../logic/notices` 的检查的数据，放过去就行：

```bash
cp captures/compaction-send.json ../logic/send/compaction.json
cp captures/compaction-notices.json ../logic/notices/compaction.json
cp captures/autocompaction-send.json ../logic/send/autocompaction.json
cp captures/autocompaction-notices.json ../logic/notices/autocompaction.json
cp captures/queued-send.json ../logic/send/queued.json
cp captures/copies-send.json ../logic/send/copies.json
cp captures/copies-notices.json ../logic/notices/copies.json
../logic/run.sh send notices
```

`send` 把应用自己发送、重新接上和重试的方法原样编进去，替身服务器照抓到的样子给出压缩前后的页和收回的回答，看一句引导进去、回答丢了的话，压缩以后会不会被认成送到了，重试收回的是不是那条消息现在的行；`notices` 把读通知的方法和把页上的行读成对话里各项的方法原样编进去，看压缩前读过的一条后台结果，压缩以后在对话里还是不是一张卡，Hermes 自己压缩存下的副本读成什么。

## 2026-11-13 这一次看到的（Hermes `611bf53`）

- 别的助手发来的消息：那一轮的 `message.start` 是空的，只有存下的行（`internal_notification`）写着 `Message from 🤖 名字 (@handle): …`。正文下面可能有 Hermes 加的 `Constraints: …`、`Reply needed: …`，不要回复的前面有 `[no reply needed] `。默认 profile 的 handle 是 `hermes`。
- 对方的回话不是一条消息：是等回话的那个后台进程结束（`process_complete`），开始帧和行都带着短说明 `Background Process Finished: …/bot_mode_dm.py --run-delivery ...`，正文 `Output:` 下面一行 JSON：`{"outcome": "@study answered.", "reply": "…", "status": "settled", …}`。对方没说话是 `"@study finished its turn without replying."`、没有 `reply`。一次问几位是 `--fan-out`，JSON 里是 `replies` 数组。
- 无话可说的一轮：`message.delta` 把 `[SILENT]` 流出来，`message.complete` 的 `text` 是空的，存下的行是 `[SILENT]`。
- `session.replay_gap`：`{"type": "session.replay_gap", "session_id": …, "payload": {"replay_epoch": …, "latest_seq": …}}`，没有 `seq`。之后 `session.events.since` 回 `snapshot_required: true`（落下的太多，留的帧不够），同一条连接上 `session.resume` 之后帧继续来。
- 假模型要注意的：回复里大段重复的内容会被 Hermes 当成失控的重复而掐断，所以长回复每一段都不一样。

## 2026-11-14 这一次看到的：一轮的结束赶在快照前面（`behind`，Hermes `611bf53`）

跑了六次（五次单跑这个阶段，一次跟在别的阶段后面），帧的顺序和序号每次都一样。下面的行号是单跑时的；跟在别的阶段后面时行号接着别的会话往下排。

- `session.resume` 的回答被按住期间，这条连接上先到了六帧：`message.delta` 24、`thinking.delta` 25、`session.usage` 26、`session.info` 27、`message.complete` 28、`session.info` 29。27 那一帧是模型和上下文的信息，没有 `running`；28 的 `persisted_turn` 写着这一轮存成了哪几行（`user_row_id: 3`、`final_assistant_row_id: 4`）和是谁的消息（`submission_id`）；29 是 `running: false`、`pending: []`。
- 放开之后才到的回答，是 Hermes 在这些帧之前读的会话：`last_sequence: 23`，`replay_epoch` 和帧上的一样，`running: true`，`pending` 里还有这条消息（`status: started`），`display_messages` 只有 1、2、3 三行，没有回复那一行。
- 不按住再读一次：`last_sequence: 29`，`running: false`，四行都在，第 4 行就是 `message.complete` 说的那一行。
- 这说明的是：Hermes 读快照时观看者已经在帧流里，只要读完快照到回答之间有耽搁，之后发布的帧就先到，快照后到。这里的耽搁是按出来的；不按的时候这一段很短，这次没有去试它自己多久出现一回。先后靠 `last_sequence` 和帧的 `seq`（同一个 `replay_epoch` 里）能分出来，`persisted_turn` 里的行号和快照里的 `row_id` 是同一套。
- `read_behind.sh` 用应用自己的代码读这份数据，两遍一共 21 项都对：回复完整、只有一份，不再显示「正在回复」。换成改动之前的 `SkillReviewTalk.swift`，照实际发生的那一遍是对的，「每次再问都一样旧」那一遍有 2 项不对（回复没了）。
- 没有做到的：让真的 Hermes 连着几次都给出比帧旧的快照。一轮只结束一次，要每次再读都被新的帧赶上，得在每个间隙里另有会话状态的帧（别的消息进队、下一轮开始），这里只按住了一次；「每次都旧」那一遍是把抓到的同一份旧快照重复给应用。

## 2026-11-14 这一次看到的：压缩前后（`compact`，Hermes `611bf53`）

跑了四次，两种压缩每次的行号都是下面这些，时间是每次跑的时间。

- 原地压缩和换成新会话，在页上看起来一样，行号也一样。留下来的消息重新存一遍，换成新的行号：引导进去的「继续」压缩前是第 8 行，压缩后是第 16 行；第二次压缩，普通消息「继续」18 → 27，第二次引导进去的「继续」23 → 32。`timestamp`、`text`、`display_kind`（`steer`）、`display_metadata`（`submission_id`、`gateway_input_owner`）一个字不差。库里，原地压缩把旧行归档（`active=0, compacted=1`）、插入新行；换成新会话时旧会话的行不动，新会话里插入新行。两种的新行 `message_uid` 都和原来的一样，但页上没有这个字段。
- 总结掉的消息还在页上，用原来的行号（第 4、5 行；第二次压缩后第 16 行的「继续」也是），时间和文字不变。所以同一条消息压缩以后可能换了行号，也可能没换。
- 页上多出一行 `row_kind: compaction`（摘要，`role: system`），行号是存摘要的那一行的，时间是压缩的时候。
- 页本身不说压缩过：`session_id` 还是请求的那个对话（换成新会话以后也是），没有别的谱系字段；不带游标读第一页时 `reset` 每次都是 `true`。只有连着的观看者收到一帧 `session.updated`（`operation: compress`，带 `target_session_id`、`previous_target_session_id`）。
- 行号不会重复用：`messages.id` 是 `AUTOINCREMENT`，`sqlite_sequence` 从 9 到 17 到 33，新行号总比以前发过的都大，换成新会话时也接着排。记下的旧行号不会变成另一条消息的，只可能不在页上了。
- 所以跨压缩认得出一行的，是它的时间和文字：Hermes 自己显示时，也是按角色、内容和时间把一条消息压缩出的几份合成一行（`hermes_state_messages.py` 的 `_dedupe_display_generations`）。
- `../logic/send` 拿这几页跑应用自己的代码：改之前，压缩以后，那句没送到的「继续」被第 16 行（旧的那句）确认成送到了，补全了事件的标成送进了这一轮，重读了对话的气泡被换掉；同样的话说两遍、一行确认了一句之后，压缩过的那一行又确认了另一句。改之后这些都还是「不确定有没有送到」，真送到了的照样由它自己的那一行确认。

## 2026-11-14 这一次看到的：压缩以后的通知和收回（`compact` 的第三、四次压缩，Hermes `611bf53`）

跑了三次，两种压缩每次的行号都是下面这些（往上读的那一步是后两次加的）。

- 后台结果那一行（`display_kind: process_complete`）和别的消息一样：留下来的换了行号（38 → 48，它引出的回复 39 → 49），`timestamp`、`text`、`display_kind`、`display_metadata`（`display_text`）一个字不差。压缩以后再来的结果是新的一行（54），它那一轮的开始帧和结束帧（`persisted_turn.user_row_id: 54`）和压缩前的一样。
- 压缩前读了最新的六行（34 到 39），压缩以后拿那一页的 `next_cursor` 往上读：`reset` 是 `false`，读到的是 34 那条消息（现在是 44）上面的几行，那六行一行也不在里面。游标跟着消息走，不跟行号。
- 引导进去的「继续」被第三次压缩拿去带摘要时（32 → 42），页上这一行的文字是 Hermes 给模型的原文（`[OUT-OF-BAND USER MESSAGE — …`），不再是 `display_kind: steer`；摘要那一行（`row_kind: compaction`）和它同一个行号。第四次的摘要没有借别的行，自己一行，时间是压缩的时候，排在页的最后。
- 收回（`session.mutate` 的 `rewind`）：按压缩前的行号收回一句留下来的话（3 → 12、20 → 29、56 → 66），回的和收回一句总结掉的（5、50）一模一样：`invalid_params`，`field: target_message_id`，`detail: "compacted: target user message was summarized when the session was compressed"`，什么都没收回。两种压缩、三次都是这样。原地压缩把留下来的旧行和总结掉的一样标成 `active=0, compacted=1`；换成新会话时旧行留在旧会话里，算压缩前的祖先。从拒绝里分不出这两种。
- 按新的行号（66）照常收回：`rewound_count: 4`，`target_message` 是那句话，`content` 是原话，`display_metadata` 里还是那个 `submission_id`。原地压缩的，收回以后页上又出现了原来那一行（56）和它的工具调用，在摘要之上：留下来的那份收回了，归档的原行就不再被它挡着；换成新会话的没有。
- 停掉的那一轮：结束帧 `status: interrupted`，`persisted_turn` 是 `{row_ids: [56, 57, 58, 59], complete: false, user_row_id: 56, submission_id: …}`；页上 56 后面只有一行工具调用，收尾的占位是隐藏的。压缩以后它是 66，提交编号和时间不变。
- `../logic/notices` 拿这几页跑应用自己的代码：改之前，压缩前读过第一条结果的对话，在第二条结果那一轮结束、读最新几行时，给 48 那一行（第一条结果）又出了一张卡，在新的那张上面；改之后还是原来那张，第二条结果有它自己的一张。压缩以后才读的对话，改之前也是对的。
- `../logic/send` 拿第四次的页和回答跑应用自己的重试：改之前，压缩以后对停掉的那一轮点重试，那条消息不管是这台 Mac 发的（行号由结束帧给）还是从对话记录读来的（56），收回 56 都被拒，对话里写「没能重试：这条消息已经压缩进摘要里了」，什么都没有再问；改之后被拒了再读一页，按提交编号或者时间和文字找到 66，收回 66，原话再问一次。真总结掉了的（50）改前改后都照旧被拒，写着那一句。

## 2026-11-14 这一次看到的：Hermes 自己压缩（`auto`，Hermes `611bf53`）

跑了四次，两种压缩每次的行号都是下面这些（前面是原地压缩的，括号里是换成新会话的）。Hermes 压缩了两次：「满了」之后那一轮一开始（状态行 `📦 Preflight compression: ~6,040 tokens >= 4,000 threshold`），和「慢慢做，满了」那一轮命令的结果回来之后（`🗜️ Compacting context — summarizing earlier conversation so I can continue...`）。两次都只有 `status.update`（`kind` 是 `compacting`、`compacted`），没有 `session.updated`。

- 留下来的行重新存一遍、换了新行号，这一点和 `session.mutate compress` 一样，但留下的东西不一样。你说的话：`timestamp` 和 `text` 不变，`display_metadata` 没了，也就是不再写着提交编号：普通的「继续」5 → 24（25），之前几轮的提示都是这样，`第一句`、`第二句` 也是（开头那几行照 `protect_first_n` 原样留着，同样换了行号、去掉了编号）。只有正在跑的那一轮的提示还写着编号：一开始压缩时它是压缩之后才存的（39（40）），中间压缩时它的副本留着编号（47 → 56（48 → 57））。
- 引导进去的「继续」（10，`display_kind: steer`）的副本 29（30）没有 `display_kind` 了，页上的文字是 Hermes 给模型的原文：`[OUT-OF-BAND USER MESSAGE — …]`、换行、`继续（自动）`、换行、`[/OUT-OF-BAND USER MESSAGE]`。库里原来那一行存的就是这段原文，页上靠 `steer` 才显示成那句话。
- 后台结果那一行（16，`process_complete`，`display_text` 是 `Background Process Finished: …`）的副本 35（36）没有 `display_kind`，也没有 `display_text`，文字是给模型的原文（`[IMPORTANT: Background process … completed normally …]`，后面一段 `[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user. …]`），时间不变。中间那次压缩把第二条结果也这样存了一遍：45 → 54（46 → 55）。
- 助手的回复和工具调用：原地压缩时，之前几轮的副本都换成压缩那一刻的时间（17 → 36，时间从结果之后变成压缩时；页上它们因此比后面你说的话还晚），只有正在跑的那一轮自己的行（中间压缩时 48、49 → 57、58）时间不变；开头那句长回复页上出现了两次（归档的 2 和副本 21：副本换了时间，Hermes 显示时按角色、内容和时间合并不了）。换成新会话时，副本的时间都不变。
- 库里：原地压缩，留下来的原行标成 `active=0, compacted=0`（收回用的标记），总结掉的标成 `active=0, compacted=1`；换成新会话，旧会话里的行不动（`active=1`），新会话里插入副本。原地压缩时摘要存在一行里（一开始压缩时是一行助手的，中间压缩时是一行你的，开头都是 `[CONTEXT COMPACTION — REFERENCE ONLY]`），页上是 `row_kind: compaction`。
- `persisted_turn`：一开始就压缩的那一轮说提示是 39（40，压缩后才存的那一行），中间压缩的那一轮说是副本 56（57），`complete` 都是 `false`。
- 收回：按压缩前的行号，原地压缩时总结掉的（1、3）回 `compacted: target user message was summarized when the session was compressed`，留下来的（5、7、10、12、16、18、45、47）回 `target user message is no longer in session history`，都是 `invalid_params`、`field: target_message_id`，什么都没收回；换成新会话时这十句都回 `compacted:`。按新的行号收回中间压缩的那一轮的提示（56（57））照常收回。
- 游标：压缩前最新六行（一行工具调用和 15 到 19）的 `next_cursor`，原地压缩以后拿来往上读，`reset` 是 `false`，读到的是开头的 20、2、22、4：那六行的副本上面那些（24 到 31，「继续」「慢慢做」「后台跑一下」几轮）一行都不在里面，往上翻的对话就读不到它们了；换成新会话时 `reset` 是 `true`，给的是新会话最新的几行。
- 之后再来的后台结果（45（46）、64（65））还是 `process_complete`，带 `display_text`，开始帧和结束帧和压缩前一样。
- `../logic/send` 拿这几页跑应用自己的代码：改之前，这台 Mac 发过的「继续」（只知道行号 5）被一开始那次压缩存成没有编号的 24（25）以后，再引导进 第三句 那一轮、回答丢了的「继续」被 24（25）确认成送到了；真送到了的，也被确认成 24（25），不是它自己的那一行。改之后两种压缩都还是「不确定有没有送到」，送到了的由它自己的那一行确认。压缩前从对话记录读来的「继续」（写没写编号都一样）和引导进去的那句，改前改后都认得出来。
- `../logic/send` 也拿这几页跑应用自己的重试：中间压缩的那一轮，对话在命令跑着时读过（提示是 47（48）），停下来重试，改之前收回 47 被拒，原地压缩的写「没能重试：这条消息已经不在对话记录里了」；改之后被这样拒了也再读一页，按时间和文字找到 56（57），收回再问一次。这台 Mac 发的那句由这一轮的结束直接说是 56（57），改前改后都对。
- `../logic/notices` 拿这几页跑应用自己读通知的代码：压缩前读过第一条结果的对话，一开始那次压缩以后第二条结果的那一轮结束、读最新几行时，16 那张卡还是一张，第二条结果有它自己的一张，在它那一轮开始的地方，别的行一行也没放进对话；中间那次压缩以后第三条结果也一样。改之前（294ee31）也是这样：副本不是通知，不会被当成卡。
- 没做到的：一句不带提交编号的话。Shion 连的 gateway 收不下：`prompt.submit` 没有 `submission_id` 或 `input_id` 就是 `invalid_params`（`gateway/session_controls.py`，读的源码，没跑）；不写编号的行只有 Hermes 自己存的（它起的那一轮、引导进去的话）和它压缩时存的副本。别的几种自动压缩没触发：模型调用之前的 `pre_api`、提供方说太长了之后的 `overflow`、空闲之后的 `idle`；看源码它们和这里两种一样走 `_compress_context` 存副本（`agent/turn_preflight.py`、`agent/turn_context_compaction.py`，读的，没跑）。

## 2026-11-14 这一次看到的：一轮后面排着提示（`queued`，Hermes `611bf53`）

单跑这个阶段跑了两次，两种压缩的行号都是下面这些（跟在别的阶段后面跑时，行号接着那两个 profile 的会话往下排）。

- 哪一次运行是哪一条提交，`session.info` 的 `pending` 说：每条提交按 `input_id`（提交编号）列着，等着的时候 `execution_generation` 是 `null`、`status: queued`；它的那次运行一开始（这次运行的 `message.start` 之后马上），就是那次运行的编号、`status: started`。在跑的那条排在最前，排队的跟在后面。
- 排队的提示，行的时间是它自己那一轮开始的时候，不是发的时候：「慢慢做」第 1 行，引导进去的「继续」第 4 行，存在第 1 次运行里；排队的两句是第 6、8 行，时间都比第 4 行晚。所以对话里引导前面最后一条「开始一轮」的消息，不一定是它进的那一轮的开头。
- 引导进去的话总比它那次运行开头那一行晚：1 → 4；下一轮一开始就压缩了的，开头那一句压缩以后才存（22（23）），时间是这一轮开始的时候，比摘要那一行还早，引导进去的那句（25（26））还是比它晚。`compact`（5 → 8、20 → 23）和 `auto`（7 → 10）的页也都是这样。
- Hermes 自己起的一轮（后台结果）也是一条提交：`pending` 里的 `input_id` 是 `["completion","proc_…",时间]`，开始帧之后拿到这次运行的编号；页上没有哪一行写着它。
- `../logic/send` 拿这几页跑应用自己的代码：改之前（a4c1a83），引导前面有一句或两句排队的提示（这一轮是别的客户端开始的也一样），那句引导送到了、回答丢了，以后一直是「不确定有没有送到」：拿来比时间的是排队的那一行，比它晚。改之后拿的是 `pending` 说的这次运行的那一条，由第 4 行确认。引导前面是一张只说了、那一轮还没开始的看板卡，或者一句没发出去的话，改前改后都确认得了：它们没有行，不拿来比。

## 2026-11-14 这一次看到的：Hermes 自己压缩时存的副本（`copies`，Hermes `611bf53`）

照现在的顺序跑了两次，两种压缩每次的行号都是下面这些（前面是原地压缩的，括号里是换成新会话的，一样时只写一个）。之前一次把詩音的话和课程的回话放在第一次压缩之后，它们被第二次压缩总结掉了，没有副本；别的几种副本和这次一样。`diary`、`errand` 改成 Bot Mode 的、假模型的摘要改成一句固定的话以后，`auto` 和单跑的 `queued` 也重跑了一次：行号和上面写的一样，`../logic` 拿新抓的页跑也照旧全过。

- 第一次压缩留下的、你这一边的每一行，都换了行号重新存一遍，时间不变，`display_kind` 和整个 `display_metadata` 都没了；库里副本的文字和原行一字不差，`message_uid` 也和原行一样，但页上不给 `message_uid`。页上看，副本和原行只差在这里：
  - 后台结果 9 → 48（49）：原行 `process_complete`，`display_text` 是 `Background Process Finished: sleep 4; echo mock-background-finished`，开始帧带着同样的 `display_kind`、`display_text` 和正文。副本的文字和原行一样：`[IMPORTANT: Background process proc_… completed normally (exit code 0).` 一行、`Command:`、`Output:` 和输出、`]`，空一行，`[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user. Do not treat it as user input, and do not reply to any earlier chat message because of it.]`。最后这一段是 Hermes 给它自己发起的通知加的（`gateway/run_notifications.py` 的 `INTERNAL_NOTIFICATION_FOOTER`，`_mark_internal_notification` 空一行接在结尾），没有人会这样打字，副本上还认得出它的就只有这一段。
  - 两条结果合并成的一轮 28 → 67（68）：原行 `process_complete`，`display_text` 是 `2 Background Processes Finished`，开始帧一样。正文开头是 `[IMPORTANT: 2 background process results arrived while this session was busy. …]`，下面两条结果各一段，结尾是同一段说明。副本文字不变。
  - 课程的回话 36 → 75（76）：原行 `process_complete`，`display_text` 是 `Background Process Finished: /opt/hermes/.venv/bin/python /opt/hermes/tools/bot_mode_dm.py --run-delivery ...`，开始帧一样。正文是等回话的那个进程的结束（`Output:` 下面一行 JSON），结尾是同一段说明。副本文字不变。
  - 詩音的话 30 → 69（70）：原行 `internal_notification`（`display_metadata` 只有 `gateway_input_owner`），开始帧是空的。文字 `Message from 🤖 詩音 (@hermes): …` 不变，没有结尾那段说明：副本只剩这段开头。
  - 引导进去的「继续（副本）」14 → 53（54）：原行 `steer`，库里存的是 Hermes 给模型的原文，页上按类型给出你的话；`session.steer` 的回答是 `{status: "queued", text: "继续（副本）", execution_generation: 5}`，没有开始帧。副本没有类型，页上就是那段原文：`[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once at this position; not tool output and not a new delivery when replayed from conversation history]` 一行、`继续（副本）`、`[/OUT-OF-BAND USER MESSAGE]` 一行（`agent/prompt_builder.py` 的 `STEER_MARKER_OPEN`、`STEER_MARKER_CLOSE`，`steer_user_row`）。
- 第二次压缩留下的是出错那一轮的回复和后面几行（它的提示「出个错」被总结掉了，还按原来的行号在页上）：
  - 出错那一行 82 → 90（83 → 92）：原行 `failed_turn`，`display_metadata` 里有 `error`（`HTTP 400: mock refused this request`）和 `error_surface`（`format_error`，`retryable: false`）。库里副本没有类型；页上又是 `failed_turn`，是 Hermes 读的时候按那句固定说明补的（`agent/turn_failure_copy.py` 的 `untyped_failed_turn_display_kind`，`tui_gateway/session_history.py` 的 `_legacy_display_kind`），`display_metadata` 没有了。
  - 停掉的回复 84 → 92（85 → 94）：原行 `display_metadata: {interrupted: true}`，副本没有，就是一条普通的回复「第一段。」。
  - 标成隐藏的一句 85（86）：原行 `hidden`，页上不显示；副本 93（95）没有类型，页上显示成你说的一句话。
  - 原地压缩时这几行助手一边的副本换成压缩那一刻的时间，换成新会话时时间不变。
- gateway 叫醒会话的看板回传这里没有抓到：假模型的 profile 没有看板工具（`kanban_create` 不在给模型的工具里），这条路没法让 Hermes 自己订阅。按源码（读的，没跑）：正文是 `gateway.kanban.wake.message` 的那几行，可能接一行 `Result: …`，最后空一行接 `gateway.kanban.wake.guidance`（`gateway/kanban_watchers_notifier.py` 的 `build_wake_text`），经 `deliver_wake` 送进会话，不加上面那段说明；原行的样子 2026-11-13 抓过（`../fake_kanban.py` 的 `wake`），存成 `internal_notification`，开始帧是空的。它的副本按上面每一种行的样子，就是原文不变、没有类型。那段提醒是 `locales/*.yaml` 里的一句：英文（十四种语言都用英文），`zh`、`zh-hant`、`hu` 各有自己的。
- `../logic/notices` 拿这几页跑应用自己的代码（`AppStore.transcriptItems`、`chatItems`、`followNotices`、`talkBefore`）：改之前，对话整个重新读一遍时，48、67、75 显示成你说的一句话，文字是 Hermes 给模型的原文，53 显示成你说的那段原文、不算送进那一轮的；审核技能给助手的资料里，这几段原文都算你说的。改之后按上面那两段 Hermes 自己写的话认：结尾空一行后整段是那段说明的、`[kanban] ` 开头而结尾空一行后整段是那句提醒的，读成原来那条通知；整段就是引导的原文的，读成你的原话、标成送进了那一轮。对话里已经有原来那张卡的，读到副本还是那张卡，只一张（同一边、同一个时间）；整个重新读时卡片和压缩前一样，只有单独一条后台结果没了短说明，卡片上是 Hermes 写的那段结果（`Background process proc_… completed normally (exit code 0).`、命令和输出）。詩音的话本来就按 `Message from 🤖` 这段字认，改前改后都是同一张卡。只是开头像通知、像引导，或者引了那段说明的话，照旧是你说的。
- `../logic/send` 拿这几页跑应用自己的代码：「继续（副本）」从这台 Mac 引导进「慢慢做（副本）」那次运行，送到了（14）、回答丢了，重连时 Hermes 已经压缩过：改之前一直是「不确定有没有送到」，改之后由副本 53（54）确认。之后再引导一次同样的话、没送到：那句旧的副本读出来也是「继续（副本）」，不管旧的那句是从对话记录读来的（按它的时间和文字认），还是这台 Mac 发的、只知道行号 14（按「第三句」那次运行开头那一行的时间认），都不拿来确认这一句，改前改后都一样。后台结果或课程的回话起的一轮停下来、对话是压缩以后读的：改之前这一轮下面有「重试」（起它的那个副本算成你说的话，点了会把 Hermes 给模型的那段原文当成你的话收回再发一遍），改之后没有。
- 认不出来的，照样留着：隐藏的那一句副本显示成你说的；停掉的回复副本没有「已停止」；出错那一行还是出错，但原因和详情没了，只写 Hermes 那句固定说明的中文（这一轮出错了：这次没有处理，还要做的话再发一次）。这几种行上没有 Hermes 写给模型、人不会打的字可认。
- 没改、也没变坏的两件事：原地压缩以后，被总结掉的长回复还按原来的行号在页上，它的副本（换成压缩那一刻的时间）也在，同一段回复显示两遍（`auto` 也是这样）；压缩前拿到的游标，原地压缩以后往上读给的是另一段（`auto` 的游标那一条）。
