# 逻辑检查：不起应用，直接跑应用自己的源文件

`ShionUITests` 里的端到端测试要起应用、占着屏幕，一组三四分钟，而且只看得到窗口里的东西。这里的检查不起应用：把 `macos/Shion` 里相关的源文件原样编进一个小程序（需要的地方配几个替身），对着写好的回答跑，每一项打印 `ok` 或 `FAIL`。规则本身（一条通知是哪张卡、一句话算不算送到、快照和帧谁新）在这里查，界面上的表现留给端到端测试。

```bash
./run.sh              # 全部
./run.sh notices      # 只跑一组
```

需要 Swift 6 的编译器（Mac 上就是 Xcode 带的 `swiftc`；Linux 上用 `SWIFTC=/path/to/swiftc`）。CI 上手动触发时 `run` 选 `logic` 只跑这些，全量运行里也带着。

| 目录 | 查什么 |
| --- | --- |
| `notices/` | 事件卡片：同一条通知只有一张卡，记录行和卡片怎么对上、放在哪，Hermes 各种通知原文读成什么（`NoticeCards.swift`、`Notices.swift`） |
| `send/` | 发送和确认：引导、打断、排队，回执丢了以后靠对话记录确认，一行只确认一条（`AppStore+Compose.swift`、`AppStore+Reconnect.swift`、`Deliveries.swift`、`Delivery.swift`） |
| `talk/` | 技能审核会话：发出的话不丢、再试一次、订阅断了重新接上、快照不盖过更新的帧（`SkillReviewTalk.swift`） |
| `chat/` | Bot Chat 重新接上时快照和帧的先后（`AppStore.swift`、`AppStore+Reconnect.swift` 里的几个方法） |

改了这些文件里的规则，先在这里加一项会失败的检查，再改代码。
