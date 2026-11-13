# 对着真的 Hermes，接一个假的模型

`macos/ci/fake_*.py` 是照着 Hermes 的源码和抓到的数据写的替身，CI 上的端到端测试跑的是它。这个目录反过来：Hermes 是真的，模型是假的。用来核对「只有模型回话才会发生」的那些轮次，Hermes 实际给观看者发了什么帧、存了什么行，再看 Shion 和替身是不是照这个样子。

没有 CI 步骤跑它，改了和这些轮次有关的代码（`Model/Notices.swift`、`Model/NoticeCards.swift`、重连）或者服务器的 Hermes 升级之后手动跑一遍。

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

1. `mock_model.py` 在 `127.0.0.1:9911` 上扮一个 OpenAI 兼容的模型，按请求最后一句话决定回什么（一句话、一次工具调用、几兆字节的长回复），每个请求记一行日志。
2. Hermes 的 `config.yaml` 写成 `provider: custom`、`base_url: http://127.0.0.1:9911/v1`。
3. 建三个 profile（默认的、`study`、`commute`），`profile.yaml` 里都写上 `ui_meta['hermes-bots']`：Hermes 只在这样的安装上给 Bot Chat 提供 `message_agent`。
4. 起 `hermes gateway run`，然后 `probe.py` 像 Shion 那样连上去（`hermes gateway attach` 给的地址和票据；一张票只管一个 profile），建 Bot Chat，发话，把收到的帧和读到的行打印出来、存成 JSON。

`probe.py` 的几个阶段：

| 阶段 | 做什么 |
| --- | --- |
| `plain` | 普通的一轮 |
| `peer` | 让詩音给课程带个话（`message_agent`）：课程的 Bot Chat 里 Hermes 自己起一轮，回话作为后台任务结果回到詩音那边；再来一次，这次课程那边没人看着，回来后补播 |
| `peer2` | 不要回复的消息、对方没回话、一次问两位 |
| `background` | 后台跑一条命令，结束时 Hermes 自己起一轮 |
| `gap` | 一个不读数据的观看者，等一段几兆字节的回复把它落下 4 MB 以上，Hermes 结束它的订阅（`session.replay_gap`），再看它怎么接回来 |

结果在 `captures/`（不进仓库）：每个阶段一份 `capture-*.json` 和打印的 `*.txt`，还有 `gateway.log`、`mock-model.log`。

## 拿应用自己的代码读

有 Swift 编译器的地方（Mac，或装了 Swift 的 Linux，`SWIFTC` 指编译器）：

```bash
./read_notices.sh captures/capture-peer.json captures/capture-peer2.json captures/capture-background.json
```

它把 `Shion/Model/Notices.swift` 原样编进去，对每个开始帧和每一行打印对话里会显示成什么。

## 2026-11-13 这一次看到的（Hermes `611bf53`）

- 别的助手发来的消息：那一轮的 `message.start` 是空的，只有存下的行（`internal_notification`）写着 `Message from 🤖 名字 (@handle): …`。正文下面可能有 Hermes 加的 `Constraints: …`、`Reply needed: …`，不要回复的前面有 `[no reply needed] `。默认 profile 的 handle 是 `hermes`。
- 对方的回话不是一条消息：是等回话的那个后台进程结束（`process_complete`），开始帧和行都带着短说明 `Background Process Finished: …/bot_mode_dm.py --run-delivery ...`，正文 `Output:` 下面一行 JSON：`{"outcome": "@study answered.", "reply": "…", "status": "settled", …}`。对方没说话是 `"@study finished its turn without replying."`、没有 `reply`。一次问几位是 `--fan-out`，JSON 里是 `replies` 数组。
- 无话可说的一轮：`message.delta` 把 `[SILENT]` 流出来，`message.complete` 的 `text` 是空的，存下的行是 `[SILENT]`。
- `session.replay_gap`：`{"type": "session.replay_gap", "session_id": …, "payload": {"replay_epoch": …, "latest_seq": …}}`，没有 `seq`。之后 `session.events.since` 回 `snapshot_required: true`（落下的太多，留的帧不够），同一条连接上 `session.resume` 之后帧继续来。
- 假模型要注意的：回复里大段重复的内容会被 Hermes 当成失控的重复而掐断，所以长回复每一段都不一样。
