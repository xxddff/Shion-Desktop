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

1. `mock_model.py` 在 `127.0.0.1:9911` 上扮一个 OpenAI 兼容的模型，按请求最后一句话决定回什么（一句话、一次工具调用、几兆字节的长回复、说到一半等探针放行再说完的回复），每个请求记一行日志。
2. Hermes 的 `config.yaml` 写成 `provider: custom`、`base_url: http://127.0.0.1:9911/v1`。
3. 建三个 profile（默认的、`study`、`commute`），`profile.yaml` 里都写上 `ui_meta['hermes-bots']`：Hermes 只在这样的安装上给 Bot Chat 提供 `message_agent`。
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
