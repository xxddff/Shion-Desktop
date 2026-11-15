# 逻辑检查：不起应用，直接跑应用自己的源文件

`ShionUITests` 里的端到端测试要起应用、占着屏幕，一组三四分钟，而且只看得到窗口里的东西。这里的检查不起应用：把 `macos/Shion` 里相关的源文件原样编进一个小程序（需要的地方配几个替身），对着写好的回答跑，每一项打印 `ok` 或 `FAIL`。规则本身（一条通知是哪张卡、一句话算不算送到、快照和帧谁新）在这里查，界面上的表现留给端到端测试。

```bash
./run.sh              # 全部
./run.sh notices      # 只跑一组
```

需要 Swift 6 的编译器（Mac 上就是 Xcode 带的 `swiftc`；Linux 上用 `SWIFTC=/path/to/swiftc`）。CI 上手动触发时 `run` 选 `logic` 只跑这些，全量运行里也带着。

| 目录 | 查什么 |
| --- | --- |
| `notices/` | 事件卡片：同一条通知只有一张卡，记录行和卡片怎么对上、放在哪，Hermes 各种通知原文读成什么（`NoticeCards.swift`、`Notices.swift`）；一轮结束后往上读到哪一页为止，对着照 Hermes 的样子分页的对话记录（`AppStore+Events.swift` 的 `followNotices`）；压缩以后读到的同一行还是原来那张卡，Hermes 自己压缩以后也不多出卡来，它存的副本（通知、引导、出错的一轮、停掉的回复、隐藏的提示）读成什么，一行自己说了是什么（写着提交编号的提示、`steer` 类型的话）就不看字，压缩存下的摘要行读成一张压缩的卡，审核技能的资料里你说过的话（页上的行读成对话里的哪一项用的是应用自己的 `AppStore.transcriptItems`、`chatItems`，技能资料是 `AppStore+SkillReviews.swift` 的 `talkBefore`；压缩前后的页是真的 Hermes 给的：`compaction.json` 是 `../real` 的 `compact` 阶段的，`autocompaction.json` 是 `auto` 阶段的，`copies.json` 是 `copies` 阶段的；`explicit.json` 是 `explicit` 阶段的，字面上像 Hermes 自己写的、你发的提示和引导） |
| `send/` | 发送和确认：排队、引导、打断；普通消息回执丢了以后，只认写着它提交编号的行，写着编号的行不会被另一句同样的话冒认；送进一轮的话没等到回音，就一直标着、什么都不认它，重启以后也还在，「再发一次」作为新的一句排在这一轮后面，「不发了」不连服务器也能把它拿掉、不再存，重试它送进的那一轮时它也跟着拿掉；重试收回的是那条消息现在的行，压缩以后也是：从对话记录读来的按它那一行写的提交编号，一轮的结束说的就是现在的行；要找时顺着游标一页一页读，不在最近一页不算总结掉了，最多 20 页，游标重复、`reset`、换了会话都停；通知的副本不当成你说的话来重试；Hermes 压缩对话时选的是打断，照排队发，`session.redirect` 不发（替身服务器像 Hermes 那样分页：`limit`、`next_cursor`、`reset`；压缩前后的页和收回的回答是真的 Hermes 给的：`compaction.json` 是 `../real` 的 `compact` 阶段的，`autocompaction.json` 是 `auto` 阶段的，`copies.json` 是 `copies` 阶段的，`longturn.json` 是 `long` 阶段的，一轮里压缩、调了 28 次工具、停下来以后的每一页；`explicit.json` 是 `explicit` 阶段的，把 Hermes 包引导的原文当提示发、停下来的那一轮，重试收回的是它自己；页上的行用应用自己的 `transcriptItems` 读）（`AppStore+Compose.swift`、`AppStore+Reconnect.swift`、`AppStore+Control.swift` 的重试、`Deliveries.swift`、`Delivery.swift`） |
| `cards/` | Hermes 在对话旁边说的话（`StatusCards.swift`、`Compose.swift`，读这些帧的 `AppStore.noteSaid`、`shownChat`，页上的行用应用自己的 `transcriptItems` 读）：压缩从第一句到结束一张卡，不会一直「正在压缩」，对话记录里的摘要行和实时的卡是一张，标成压缩的警告不算；压缩时只排队和引导，打断照排队走；提醒按 `key` 一张、换话、撤下，备用模型、目标、/btw、/bg、接着做被打断的那一轮各一张、补播还是那张、最多留 30 条，等模型一张、等完就没了（帧是真的 Hermes 给的：`held.json` 是 `../real` 的 `held` 阶段的，压缩按住时发的三句和它们的回答也在里面；`status.json` 是 `status` 阶段的） |
| `talk/` | 技能审核会话：发出的话不丢、再试一次、订阅断了重新接上、快照不盖过更新的帧、重新接上被拒（`SkillReviewTalk.swift`、`Rejoin.swift`） |
| `chat/` | Bot Chat 重新接上时快照和帧的先后，重新接上被拒时说什么、什么时候再试（`AppStore.swift`、`AppStore+Reconnect.swift` 里的几个方法，`Rejoin.swift`） |

改了这些文件里的规则，先在这里加一项会失败的检查，再改代码。

`chat/`、`notices/` 和 `send/` 是把应用里的几个方法原样取出来编（`extract.py`），所以还需要 `python3`。替身 `fake_reconnect.py` 里「很多」（一页全是工具调用的行，消息在它上面）、「同一句话说两遍」那两段脚本和「断线：接不上」另有一个不用 Mac 的核对：`python3 macos/ci/check_fake_reconnect.py`。
