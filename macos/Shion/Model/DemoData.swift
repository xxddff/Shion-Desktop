import SwiftUI

/// The prototype's demo day: Monday 10:52, just after the first class. Everything is laid out
/// relative to `now` so the app opens on the same story every time.
struct DemoData {
    let now: Date
    private let calendar = Calendar.current

    init(now: Date) {
        self.now = now
    }

    /// A wall-clock time on the demo day plus `day` days.
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .day, value: day, to: start) ?? start
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    var bots: [Bot] {
        [
            Bot(id: "shion", name: "詩音", title: "总秘书", chief: true, hue: Palette.accent, status: .working, statusNote: "在跟进 4 件事"),
            Bot(id: "study", name: "课程", title: "课程助理", chief: false, hue: Palette.hues[0], status: .working, statusNote: "在整理第7回录音"),
            Bot(id: "commute", name: "通勤", title: "通勤", chief: false, hue: Palette.hues[2], status: .idle, statusNote: "回程 18:10 · 中央線快速 正常"),
            Bot(id: "mail", name: "邮件", title: "邮件", chief: false, hue: Palette.hues[1], status: .waiting, statusNote: "等你确认：发给中村老师的回复"),
            Bot(id: "news", name: "资讯", title: "资讯与核查", chief: false, hue: Palette.hues[3], status: .working, statusNote: "在核实电费传言"),
            Bot(id: "journal", name: "回顾", title: "回顾", chief: false, hue: Palette.hues[4], status: .idle, statusNote: "今晚 22:30 写日报"),
        ]
    }

    var todos: [Todo] {
        [
            Todo(id: "td1", title: "回复中村老师：中期报告的提交格式", area: .study, source: "来自 中村老师 的邮件", doAt: at(-1, 20), dueAt: at(-1, 23, 59), nudges: 2),
            Todo(id: "td2", title: "机器学习 课前小测", area: .study, source: "机器学习基础", doAt: at(0, 10, 45), dueAt: at(0, 12, 50), nudges: 1),
            Todo(id: "td3", title: "写实验报告 第3章", area: .study, source: "你跟詩音说的", doAt: at(0, 15), dueAt: at(2, 17)),
            Todo(id: "td4", title: "交房租", area: .life, source: "每月 10 日", doAt: at(0, 20), dueAt: at(1, 23, 59), nudges: 1),
            Todo(id: "td5", title: "买牛奶、鸡蛋、洗衣液", area: .life, source: "你跟詩音说的", doAt: at(0, 19, 10)),
            Todo(id: "td6", title: "写实习周报", area: .work, source: "每周提醒", doAt: at(1, 10), dueAt: at(1, 18)),
            Todo(id: "td7", title: "数据结构 作业4：实现二叉堆", area: .study, source: "数据结构与算法 第7回", doAt: at(2, 19), dueAt: at(4, 23, 59), proposed: true),
            Todo(id: "td8", title: "复习第7回：堆与优先队列", area: .study, source: "数据结构与算法 第7回", doAt: at(1, 20), proposed: true),
            Todo(id: "td9", title: "预约牙医", area: .life, source: "你自己加的", doAt: at(3, 12)),
            Todo(id: "td10", title: "读论文：Attention Is All You Need（研讨课）", area: .study, source: "你跟詩音说的", doAt: at(3, 20), dueAt: at(4, 14, 40)),
            Todo(id: "td12", title: "回复实习 HR：面谈时间", area: .work, source: "来自 实习 HR 的邮件", done: true),
        ]
    }

    var events: [CalEvent] {
        [
            CalEvent(id: "e1", title: "上学", kind: .commute, area: .life, start: at(0, 8), end: at(0, 8, 47), place: "吉祥寺 → 新宿"),
            CalEvent(id: "e2", title: "数据结构与算法 第7回", kind: .lesson, area: .study, start: at(0, 9), end: at(0, 10, 30), place: "3号馆 201"),
            CalEvent(id: "e3", title: "机器学习基础 第7回", kind: .lesson, area: .study, start: at(0, 13), end: at(0, 14, 30), place: "5号馆 102"),
            CalEvent(id: "e4", title: "写实验报告 第3章", kind: .focus, area: .study, start: at(0, 15), end: at(0, 16, 30), place: "图书馆"),
            CalEvent(id: "e5", title: "实习周会", kind: .event, area: .work, start: at(0, 17), end: at(0, 17, 45), place: "Zoom"),
            CalEvent(id: "e6", title: "回家", kind: .commute, area: .life, start: at(0, 18, 10), end: at(0, 18, 42), place: "新宿 → 吉祥寺"),
            CalEvent(id: "e7", title: "线性代数 第7回", kind: .lesson, area: .study, start: at(1, 10, 40), end: at(1, 12, 10), place: "3号馆 105"),
            CalEvent(id: "e8", title: "实习", kind: .event, area: .work, start: at(1, 14), end: at(1, 18), place: "渋谷 办公室"),
            CalEvent(id: "e9", title: "数据结构演习", kind: .lesson, area: .study, start: at(2, 9), end: at(2, 10, 30), place: "计算机室 B"),
            CalEvent(id: "e10", title: "英语 Reading", kind: .lesson, area: .study, start: at(2, 13), end: at(2, 14, 30), place: "2号馆 303"),
            CalEvent(id: "e11", title: "数据结构 作业4", kind: .focus, area: .study, start: at(2, 19), end: at(2, 21)),
            CalEvent(id: "e13", title: "实习 HR 面谈", kind: .event, area: .work, start: at(3, 15), end: at(3, 15, 30), place: "Zoom"),
            CalEvent(id: "e14", title: "机器学习基础 第8回", kind: .lesson, area: .study, start: at(4, 9), end: at(4, 10, 30), place: "5号馆 102"),
            CalEvent(id: "e15", title: "研讨课", kind: .lesson, area: .study, start: at(4, 14, 40), end: at(4, 16, 10), place: "研究室"),
        ]
    }

    var cards: [Card] {
        [
            Card(id: "c7a1", title: "整理「数据结构与算法 第7回」录音，列出要做的事", assignee: "study", status: .running, line: "读完录音，正在列待办 · 2 分钟前", updatedAt: at(0, 10, 50)),
            Card(id: "f1e0", title: "核实「东京今冬电费上涨 30%」", assignee: "news", status: .running, line: "找到公告，正在比对数字 · 12 分钟前", updatedAt: at(0, 10, 40)),
            Card(id: "m2b1", title: "回复中村老师：中期报告的提交格式", assignee: "mail", status: .waiting, line: "回复起草好了，等你确认后发出", updatedAt: at(0, 8, 44)),
            Card(id: "g5d2", title: "下载上学期成绩单", assignee: "study", status: .waiting, line: "学校门户要两步验证码，发到你手机上了。告诉我验证码，我接着下载。", updatedAt: at(0, 10, 20)),
            Card(id: "c7b2", title: "下载第7回课件，存进 Notion", assignee: "study", status: .queued, line: "课程手上还有一件，做完就开始", updatedAt: at(0, 10, 32)),
            Card(id: "c7c3", title: "做第7回复习卡片", assignee: "study", status: .queued, line: "等「下载第7回课件」做完", updatedAt: at(0, 10, 31)),
            Card(id: "d6c3", title: "做第6回复习卡片", assignee: "study", status: .done, line: "12 张，放在 Notion「数据结构与算法」第6回下面", updatedAt: at(-1, 21, 6)),
            Card(id: "h6a4", title: "把第6回作业的批改意见整理进 Notion", assignee: "study", status: .done, line: "批改意见 5 条，放在 Notion「数据结构与算法」第6回下面", updatedAt: at(0, 9, 24)),
        ]
    }

    var asks: [Ask] {
        [
            Ask(
                id: "ask-mail", kind: .approval, botId: "mail", at: at(0, 8, 44),
                title: "把这封回复发给中村老师？",
                preview: "中村老师：\n\n您好，感谢提醒。中期报告我会按要求整理成 PDF，在 11 月 15 日前上传到课程网站。\n\n如格式上还有其他要求，请告诉我。\n\n谢谢！",
                options: [
                    AskOption(value: "send", label: "发送", primary: true),
                    AskOption(value: "edit", label: "改一下"),
                    AskOption(value: "hold", label: "先不发"),
                ]
            ),
            Ask(
                id: "ask-hw4", kind: .clarify, botId: "shion", at: at(0, 10, 51),
                title: "作业4 排在周三 19:00 做，周五 23:59 截止，可以吗？",
                detail: "来自第7回录音的整理。",
                options: [
                    AskOption(value: "ok", label: "可以", primary: true),
                    AskOption(value: "later", label: "往后挪一天"),
                    AskOption(value: "self", label: "我自己安排"),
                ]
            ),
        ]
    }

    var chats: [String: [ChatItem]] {
        [
            "shion": [
                ChatItem(id: "s1", role: .user, at: at(-1, 21, 5), text: "第6回的复习卡片做好了吗"),
                ChatItem(id: "s2", role: .assistant, at: at(-1, 21, 6), text: "做好了，12 张，放在 Notion「数据结构与算法」第6回页面下面。"),
                ChatItem(id: "s3", role: .user, at: at(0, 8, 41), text: "帮我核实一下，网上说东京今年冬天电费要涨 30%，是真的吗"),
                ChatItem(id: "s4", role: .assistant, at: at(0, 8, 41), text: "交给「资讯」去查了，有结论我回来告诉你。"),
                ChatItem(id: "s5", role: .card, at: at(0, 8, 41), cardId: "f1e0"),
                ChatItem(id: "s6", role: .user, at: at(0, 10, 31), text: "下课了，第7回的录音整理一下吧，作业别漏了"),
                ChatItem(id: "s7", role: .assistant, at: at(0, 10, 32), text: "交给「课程」了：先整理录音、列出要做的事，再去课程平台下载课件。整理出的待办，日期会先问你。"),
                ChatItem(id: "s8", role: .card, at: at(0, 10, 32), cardId: "c7a1"),
                ChatItem(id: "s9", role: .card, at: at(0, 10, 32), cardId: "c7b2"),
                ChatItem(id: "s10", role: .assistant, at: at(0, 10, 50), text: "小测原定 10:45 开始，已经过了 5 分钟。15 分钟就能做完，现在开始吧？", todoIds: ["td2"]),
                // a finished turn: its tool calls fold into one line above the reply
                ChatItem(id: "s11", role: .user, at: at(0, 10, 51), text: "这周还有哪些作业？列个表"),
                ChatItem(id: "s12", role: .tool, at: at(0, 10, 51), text: "calendar_events · 本周的截止日期"),
                ChatItem(id: "s13", role: .tool, at: at(0, 10, 51), text: "notion_search · 作业"),
                ChatItem(id: "s14", role: .tool, at: at(0, 10, 51), text: "web_extract · moodle.example/course/ds"),
                ChatItem(id: "s15", role: .assistant, at: at(0, 10, 52), text: """
                    这周要交的有 3 项，按截止时间排：

                    | 作业 | 截止 | 进度 |
                    | :-- | :-: | --: |
                    | 机器学习 课前小测 | 今天 12:50 | 0% |
                    | 实验报告 第3章 | 周三 17:00 | 60% |
                    | 数据结构 作业4 | 周五 23:59 | 0% |

                    作业4 要做两件事：
                    1. 实现 `push` 和 `pop`
                    2. 写测试，至少覆盖：
                       - 空堆
                       - 重复的元素

                    ```python
                    heap = BinaryHeap(key=lambda todo: (todo.due, -todo.priority))  # 先比截止时间，同一时间再比优先级，都一样时按加进来的先后
                    heap.push(3)
                    assert heap.pop() == 3
                    ```
                    """),
            ],
            // 资讯's sources side by side: a table wider than the reply, which scrolls on its own
            "news": [
                ChatItem(id: "n1", role: .user, at: at(0, 10, 38), text: "电费涨 30% 那个说法，查得怎么样了？"),
                ChatItem(id: "n2", role: .tool, at: at(0, 10, 38), text: "web_search · 东京电力 12月 电费 上涨"),
                ChatItem(id: "n3", role: .tool, at: at(0, 10, 39), text: "web_extract · tepco.example/press/2026"),
                ChatItem(id: "n4", role: .tool, at: at(0, 10, 39), text: "web_extract · meti.example/energy/winter"),
                ChatItem(id: "n5", role: .assistant, at: at(0, 10, 40), text: """
                    找到三处说法，先列在这里，数字还在比对：

                    | 来源 | 发布 | 原话 | 涨幅 | 说的是哪种合同 | 和传言的出入 |
                    | --- | :-: | --- | --: | --- | --- |
                    | 东京电力 官方公告 | 11 月 1 日 | 「12 月起，标准家庭的月电费比 11 月增加约 312 日元」 | 约 3.6% | 从量电灯 B，30A，每月用电 260 kWh | 只有传言的八分之一左右 |
                    | 经济产业省 说明资料 | 10 月 28 日 | 「冬季补贴结束后，电价恢复到补贴前的水平」 | 没写 | 所有低压合同 | 没有提到 30% |
                    | 社交网络上的帖子 | 11 月 7 日 | 「东京今冬电费上涨 30%」 | 30% | 没说 | 像是把燃料调整费的涨幅当成了电费总额的涨幅 |

                    30% 这个数字目前只在帖子里出现，两份官方资料都对不上，确认完再告诉你结论。
                    """),
            ],
            // 课程's notes on the lecture: headings, lists in lists, a quote, task boxes, a rule
            "study": [
                ChatItem(id: "k1", role: .user, at: at(0, 10, 47), text: "第7回讲了什么？先给我个提纲"),
                ChatItem(id: "k2", role: .tool, at: at(0, 10, 47), text: "read_file · 第7回录音转写.txt"),
                ChatItem(id: "k3", role: .tool, at: at(0, 10, 48), text: "notion_search · 数据结构与算法 第6回"),
                ChatItem(id: "k4", role: .assistant, at: at(0, 10, 49), text: """
                    ## 第7回：堆与优先队列

                    **堆**是一棵完全二叉树，每个父节点都不大于它的子节点（*最小堆*）。

                    ### 要点
                    1. 插入：放到最后一个位置，再**上浮**
                    2. 删除最小值：
                       - 把最后一个元素换到根
                       - 再**下沉**，和较小的子节点交换
                    3. 建堆是 O(n)，不是 ~~O(n log n)~~

                    > 老师说期末一定会考建堆的复杂度。

                    ### 我在做的
                    - [x] 读完录音
                    - [ ] 列出要做的事
                    - [ ] 下载课件，存进 Notion

                    ---

                    第6回的笔记在 [Notion](https://www.notion.so) 里，可以先对照着看。
                    """),
            ],
            "commute": [
                ChatItem(id: "m1", role: .system, at: at(0, 7, 50), text: "出门提醒 · 07:50"),
                ChatItem(id: "m2", role: .assistant, at: at(0, 7, 50), text: "中央線快速 因车辆检查延误约 8 分钟。改走 井の頭線 → 明大前 → 京王線，08:47 到新宿，比等中央線早 6 分钟。要改吗？"),
                ChatItem(id: "m3", role: .user, at: at(0, 7, 53), text: "好，走京王"),
                ChatItem(id: "m4", role: .assistant, at: at(0, 7, 53), text: "已把出门提醒改到 08:00。回程我会在 17:55 再查一次。"),
            ],
            "mail": [
                ChatItem(id: "x1", role: .system, at: at(0, 8), text: "收件箱整理 · 08:00"),
                ChatItem(id: "x2", role: .assistant, at: at(0, 8, 1), text: "新邮件 9 封，需要你处理的有 2 封：中村老师问中期报告的提交格式（昨天就该回了），实习 HR 的面谈时间确认（我已经帮你接受了周四 15:00）。"),
                ChatItem(id: "x3", role: .user, at: at(0, 8, 43), text: "老师那封你帮我回一下，说用 PDF 按时交"),
                ChatItem(id: "x4", role: .assistant, at: at(0, 8, 44), text: "起草好了，在「等你确认」里，你点发送我再发。"),
                // pictures and files in a chat (ChatMediaViews.swift): one you sent, the inbox the
                // assistant looked at, a file it hands over, a web picture that waits for a click
                ChatItem(id: "x5", role: .user, at: at(0, 9, 2), text: "老师发的讲义也拍了，要交的格式是不是这样？",
                         media: [ChatMedia(kind: .image, name: "讲义.jpg", path: "/opt/data/profiles/mail/cache/images/讲义.jpg")]),
                ChatItem(id: "x6", role: .tool, at: at(0, 9, 3), text: "browser_navigate · webmail.example/inbox"),
                ChatItem(id: "x7", role: .assistant, at: at(0, 9, 4), text: """
                    是的，和讲义上写的一样：PDF，A4，学号写在页眉。中村老师的邮件里附了模板，我存下来了：

                    MEDIA:/opt/data/profiles/mail/attachments/中期报告模板.docx

                    课程网站上的提交页面是这样的：

                    ![课程网站的提交页面](https://moodle.example/pluginfile.php/submission.png)
                    """),
            ],
        ]
    }

    var reports: [Report] {
        [
            Report(
                id: "r-life", kind: .life, botId: "journal", date: at(-1, 22, 30),
                headline: "昨天比前天早睡半小时，屏幕时间少了 40 分钟",
                blocks: [
                    ReportBlock(heading: "做完的事", items: ["交了线性代数 作业3（21:12）", "第6回复习卡片 12 张", "买了这周的早餐"]),
                    ReportBlock(heading: "今天留意", items: ["交房租，明晚截止", "牙医还没预约"]),
                ]
            ),
            Report(
                id: "r-study", kind: .study, botId: "journal", date: at(-1, 22, 30),
                headline: "数据结构跟得上，机器学习小测今天 12:50 截止",
                blocks: [
                    ReportBlock(heading: "学了什么", items: ["数据结构 第6回：二叉搜索树，复习卡片已做", "线性代数 作业3 已交"]),
                    ReportBlock(heading: "接下来", items: ["机器学习 课前小测，今天 12:50", "实验报告 第3章，周三 17:00"]),
                ]
            ),
            Report(
                id: "r-work", kind: .work, botId: "journal", date: at(-1, 22, 30),
                headline: "实习周报明天 18:00 截止，周四 15:00 和 HR 面谈",
                blocks: [
                    ReportBlock(heading: "这周", items: ["周报：明天 18:00 前", "HR 面谈：周四 15:00，Zoom"]),
                ]
            ),
            Report(
                id: "r-news", kind: .news, botId: "news", date: at(0, 7),
                headline: "央行维持利率不变；「电费上涨 30%」的说法在核实中",
                blocks: [
                    ReportBlock(heading: "今天的新闻", items: [
                        "央行维持政策利率不变，暗示 12 月可能加息（两家来源一致）",
                        "环状线新型车辆明年春季投入运营（官方发布）",
                        "日元兑美元跌至 158，创三个月新低（行情数据一致）",
                        "「东京今冬电费上涨 30%」在社交网络流传（「资讯」正在核实）",
                    ]),
                ]
            ),
        ]
    }

    var screens: [BotScreen] {
        [
            BotScreen(botId: "commute", running: true, activity: "07:50 查过运行信息，空闲中", url: "transit-info.example/status"),
            BotScreen(botId: "news", running: true, activity: "在读电费相关的报道", url: "news.example/energy"),
            BotScreen(botId: "study", running: false, activity: "未启动"),
            BotScreen(botId: "mail", running: false, activity: "未启动"),
            BotScreen(botId: "shion", running: false, activity: "未启动"),
            BotScreen(botId: "journal", running: false, activity: "未启动"),
        ]
    }
}
