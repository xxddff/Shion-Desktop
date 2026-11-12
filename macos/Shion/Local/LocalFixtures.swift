import Foundation

#if DEBUG

/// This Mac's calendars, windows and app use as screenshot and test runs make them up. Screenshots
/// tell the demo's story around its pinned moment (Monday 10:52, 7 minutes after the quiz was due
/// to start, a cat video in front); the end-to-end test's follow the real clock: a focus block
/// under way since 10 minutes ago, a cat video in front for 7 of them, then the report itself.
enum LocalFixtures {
    static let lessons = "fx-lessons", personal = "fx-personal", work = "fx-work", focus = "fx-focus", holidays = "fx-holidays"

    static let calendars = [
        CalendarInfo(id: lessons, title: "课表", account: "iCloud", color: .hue(0)),
        CalendarInfo(id: personal, title: "个人", account: "iCloud", color: .hue(2)),
        CalendarInfo(id: work, title: "实习", account: "Google", color: .hue(1)),
        CalendarInfo(id: focus, title: "专注", account: "在我的 Mac 上", color: .hue(3)),
        CalendarInfo(id: holidays, title: "日本の祝日", account: "订阅的日历", color: .hue(4), preselected: false),
    ]

    /// Screenshot and test runs start with these ticked: all but the holidays.
    static var settings: LocalSettings {
        LocalSettings(
            calendars: [lessons, personal, work, focus],
            focusCheck: true,
            usageLog: true,
            excluded: [ExcludedApp(bundleId: "com.1password.1password", name: "1Password")]
        )
    }

    // MARK: screenshots

    /// The demo's week, as the calendars on this Mac would have it (DemoData's events, but the
    /// commutes, which are 通勤's).
    static func demoItems(around now: Date) -> [CalendarItem] {
        let at = clock(now)
        return [
            CalendarItem(id: "e2", calendarId: lessons, title: "数据结构与算法 第7回", start: at(0, 9, 0), end: at(0, 10, 30), place: "3号馆 201"),
            CalendarItem(id: "e3", calendarId: lessons, title: "机器学习基础 第7回", start: at(0, 13, 0), end: at(0, 14, 30), place: "5号馆 102"),
            CalendarItem(id: "e4", calendarId: focus, title: "写实验报告 第3章", start: at(0, 15, 0), end: at(0, 16, 30), place: "图书馆"),
            CalendarItem(id: "e5", calendarId: work, title: "实习周会", start: at(0, 17, 0), end: at(0, 17, 45), place: "Zoom"),
            CalendarItem(id: "e7", calendarId: lessons, title: "线性代数 第7回", start: at(1, 10, 40), end: at(1, 12, 10), place: "3号馆 105"),
            CalendarItem(id: "e8", calendarId: work, title: "实习", start: at(1, 14, 0), end: at(1, 18, 0), place: "渋谷 办公室"),
            CalendarItem(id: "e9", calendarId: lessons, title: "数据结构演习", start: at(2, 9, 0), end: at(2, 10, 30), place: "计算机室 B"),
            CalendarItem(id: "e10", calendarId: lessons, title: "英语 Reading", start: at(2, 13, 0), end: at(2, 14, 30), place: "2号馆 303"),
            CalendarItem(id: "e11", calendarId: focus, title: "数据结构 作业4", start: at(2, 19, 0), end: at(2, 21, 0)),
            CalendarItem(id: "p1", calendarId: personal, title: "妈妈生日", start: at(2, 0, 0), end: at(3, 0, 0), allDay: true),
            CalendarItem(id: "e13", calendarId: work, title: "实习 HR 面谈", start: at(3, 15, 0), end: at(3, 15, 30), place: "Zoom"),
            CalendarItem(id: "p2", calendarId: personal, title: "社团聚餐", start: at(3, 19, 0), end: at(3, 21, 0), place: "吉祥寺"),
            CalendarItem(id: "e14", calendarId: lessons, title: "机器学习基础 第8回", start: at(4, 9, 0), end: at(4, 10, 30), place: "5号馆 102"),
            CalendarItem(id: "e15", calendarId: lessons, title: "研讨课", start: at(4, 14, 40), end: at(4, 16, 10), place: "研究室"),
            CalendarItem(id: "h1", calendarId: holidays, title: "勤労感謝の日", start: at(14, 0, 0), end: at(15, 0, 0), allDay: true),
        ]
    }

    /// What was in front since class ended: notes, a chat, then a cat video that was still on
    /// when the quiz (DemoData's td2, 10:45) came due.
    static func demoTimeline(around now: Date) -> FocusEngine {
        let at = clock(now)
        let notes = FrontWindow(bundleId: "notion.id", app: "Notion", title: "数据结构与算法 第7回 · 课堂笔记")
        let chat = FrontWindow(bundleId: "jp.naver.line.mac", app: "LINE", title: "研究室")
        let cats = FrontWindow(bundleId: "com.apple.Safari", app: "Safari", title: "猫のおもしろ動画まとめ 2026 - YouTube")
        let quiz = "机器学习 课前小测"
        return FocusEngine(samples: [
            FocusSample(at: at(0, 10, 30), front: notes, planId: nil),
            FocusSample(at: at(0, 10, 34), front: chat, planId: nil),
            FocusSample(at: at(0, 10, 41), front: cats, planId: nil),
            FocusSample(at: at(0, 10, 45), front: cats, planId: "todo:td2",
                        judgement: FixtureJudge.rule(plan: quiz, app: cats.app, title: cats.title)),
        ])
    }

    /// Today's apps so far, for Settings.
    static func demoUsage(around now: Date) -> UsageLog {
        let at = clock(now)
        return UsageLog(segments: [
            UsageSegment(bundleId: "com.microsoft.VSCode", app: "Visual Studio Code", start: at(0, 8, 50), end: at(0, 9, 0)),
            UsageSegment(bundleId: "notion.id", app: "Notion", start: at(0, 9, 0), end: at(0, 10, 30)),
            UsageSegment(bundleId: "com.apple.Safari", app: "Safari", start: at(0, 10, 30), end: at(0, 10, 34)),
            UsageSegment(bundleId: "jp.naver.line.mac", app: "LINE", start: at(0, 10, 34), end: at(0, 10, 41)),
            UsageSegment(bundleId: "com.apple.Safari", app: "Safari", start: at(0, 10, 41), end: at(0, 10, 52)),
        ])
    }

    // MARK: the end-to-end test

    static let scriptPlan = "CI：实验报告 第3章"

    /// Around the real `now`: the focus block under way, a class and a meeting later, and an event
    /// in the unticked holidays calendar that must not show.
    static func scriptItems(around now: Date) -> [CalendarItem] {
        let base = minute(now)
        func plus(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        return [
            CalendarItem(id: "ci-focus", calendarId: focus, title: scriptPlan, start: plus(-10), end: plus(80), place: "图书馆"),
            CalendarItem(id: "ci-lesson", calendarId: lessons, title: "CI：线性代数", start: plus(90), end: plus(180), place: "3号馆 105"),
            CalendarItem(id: "ci-work", calendarId: work, title: "CI：实习周会", start: plus(200), end: plus(245), place: "Zoom"),
            CalendarItem(id: "ci-hidden", calendarId: holidays, title: "CI：不该出现的日程", start: plus(20), end: plus(50)),
        ]
    }

    /// A cat video in front for the last 7 minutes of the focus block, then the report.
    static func scriptWindows() -> [FrontWindow?] {
        [
            FrontWindow(bundleId: "com.apple.Safari", app: "Safari", title: "猫のおもしろ動画まとめ - YouTube"),
            FrontWindow(bundleId: "com.apple.iWork.Pages", app: "Pages", title: "实验报告 第3章.pages"),
        ]
    }

    /// The cat video came to the front 7 minutes before the app started.
    static func scriptTimeline(around now: Date) -> FocusEngine {
        FocusEngine(samples: [
            FocusSample(at: now.addingTimeInterval(-7 * 60), front: scriptWindows()[0], planId: "event:ci-focus"),
        ])
    }

    /// Earlier today: Xcode 40 minutes, Safari 20, LINE 5, and 10 minutes in 1Password, which is
    /// left out of the record and must not reach the server.
    static func scriptUsage(around now: Date) -> UsageLog {
        let base = minute(now)
        func plus(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        return UsageLog(segments: [
            UsageSegment(bundleId: "com.apple.dt.Xcode", app: "Xcode", start: plus(-180), end: plus(-140)),
            UsageSegment(bundleId: "com.apple.Safari", app: "Safari", start: plus(-140), end: plus(-120)),
            UsageSegment(bundleId: "jp.naver.line.mac", app: "LINE", start: plus(-120), end: plus(-115)),
            UsageSegment(bundleId: "com.1password.1password", app: "1Password", start: plus(-115), end: plus(-105)),
        ])
    }

    // MARK: -

    /// A wall-clock time on `now`'s day plus `day` days.
    private static func clock(_ now: Date) -> (Int, Int, Int) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        return { day, hour, minute in
            let date = calendar.date(byAdding: .day, value: day, to: start) ?? start
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
    }

    private static func minute(_ now: Date) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}
#endif
