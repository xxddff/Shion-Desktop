import Charts
import SwiftUI

/// One day of app use as the server's shion plugin adds it up (`plugin.shion.usage.day`): what
/// this Mac uploaded (AppStore+Local.swift), per app and per kind of thing. The plugin decides
/// which kind an app is (its built-in table, or what 回顾 set); browsers and mail it leaves 未分类.
nonisolated struct UsageDay: Equatable, Sendable {
    nonisolated struct App: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let category: UsageCategory
        let seconds: Int
    }

    let day: String
    let totalSeconds: Int
    let byCategory: [UsageCategory: Int]
    /// Most used first.
    let apps: [App]

    init(day: String, totalSeconds: Int, byCategory: [UsageCategory: Int], apps: [App]) {
        self.day = day
        self.totalSeconds = totalSeconds
        self.byCategory = byCategory
        self.apps = apps
    }

    /// `usage.day`'s answer for the day asked for.
    init(_ reply: JSONValue, day: String) {
        self.day = day
        totalSeconds = reply["total_seconds"]?.int ?? 0
        var byCategory: [UsageCategory: Int] = [:]
        for category in UsageCategory.allCases {
            byCategory[category] = reply["by_category"]?[category.rawValue]?.int ?? 0
        }
        self.byCategory = byCategory
        apps = (reply["by_app"]?.array ?? []).compactMap { row in
            guard let id = row["bundle_id"]?.string, let seconds = row["seconds"]?.int, seconds > 0 else { return nil }
            let name = row["app_name"]?.string ?? ""
            return App(id: id, name: name.isEmpty ? id : name,
                       category: UsageCategory(rawValue: row["category"]?.string ?? "") ?? .uncategorized, seconds: seconds)
        }
        .sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }
    }

    /// The seven kinds, most time first; the ones with none keep their usual order at the end.
    var ranked: [(category: UsageCategory, seconds: Int)] {
        UsageCategory.allCases.enumerated()
            .map { (index: $0.offset, category: $0.element, seconds: byCategory[$0.element] ?? 0) }
            .sorted { ($0.seconds, -$0.index) > ($1.seconds, -$1.index) }
            .map { ($0.category, $0.seconds) }
    }

    /// 「2 小时 31 分」, 「50 分」, 「不到 1 分」, 「0 分」.
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if seconds > 0 && minutes == 0 { return "不到 1 分" }
        if minutes < 60 { return "\(minutes) 分" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

/// The plugin's six kinds of activity (ActivityKind), and 未分类 for an app it has no kind for.
nonisolated enum UsageCategory: String, CaseIterable, Sendable {
    case study, work, life, fun, social, other, uncategorized

    var label: String {
        switch self {
        case .study: "学习"
        case .work: "工作"
        case .life: "生活"
        case .fun: "娱乐"
        case .social: "社交"
        case .other: "其他"
        case .uncategorized: "未分类"
        }
    }
}

/// `usage.day`'s answers, by day, while connected to the plugin. A day already read is read again
/// when the plugin says the usage changed (the Mac uploads every few minutes, so today's grows).
@Observable
final class ScreenTime {
    static let shared = ScreenTime()

    private(set) var days: [String: UsageDay] = [:]
    /// Bumped by a change: the days on screen are read again.
    private(set) var generation = 0

    func load(_ day: String, in store: AppStore) async {
        guard let usage = await store.fetchUsage(day: day) else { return }
        days[day] = usage
    }

    /// `plugin.shion.changed` with `usage` in its topics.
    func changed() {
        generation += 1
    }

    /// Disconnected from the plugin: nothing of the server's is kept.
    func forget() {
        days = [:]
        generation += 1
    }
}

/// Under a report about your own day (学习, 工作, 生活; not 新闻): that day's screen time. The
/// server's while connected to its plugin; the demo's where the reports are the demo's too. Not
/// shown while the window shows the last data (`readOnly`): the totals are counters that keep
/// going through the day, and an old one would pass for now; the report itself is a finished text.
struct ScreenTimeSection: View {
    @Environment(AppStore.self) private var store
    let day: String

    var body: some View {
        let screen = ScreenTime.shared
        let usage: UsageDay? = store.readOnly ? nil : (store.pluginData ? screen.days[day] : UsageDay.demo(day: day))
        VStack(alignment: .leading, spacing: 0) {
            if let usage, usage.totalSeconds > 0 {
                UsageChart(usage: usage)
            }
        }
        .task(id: "\(day)|\(store.pluginData)|\(store.readOnly)|\(screen.generation)") {
            guard store.pluginData, !store.readOnly else { return }
            await screen.load(day, in: store)
        }
    }
}

/// The day's minutes by kind, then the apps used most: ranked bars in one quiet colour (purple,
/// orange and red mean something else here), each with its name above it and its time at its end,
/// no axis to read off. One series each, so no legend: the headings say what they are.
struct UsageChart: View {
    let usage: UsageDay
    /// How many apps are listed.
    static let topApps = 5
    /// The bars: grey, a step darker than the lines and fills around them.
    private static let bar = Color.secondary

    nonisolated private struct Row: Identifiable {
        let id: String
        let label: String
        let seconds: Int
    }

    var body: some View {
        let kinds = usage.ranked.map { Row(id: $0.category.rawValue, label: $0.category.label, seconds: $0.seconds) }
        let apps = usage.apps.prefix(Self.topApps).map { Row(id: $0.id, label: $0.name, seconds: $0.seconds) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("屏幕时间").font(.t15)
                Text(UsageDay.duration(usage.totalSeconds))
                    .font(.t13)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("usage-total")
            }
            bars(kinds, named: "各类时长", identifier: "usage-categories")
            if !apps.isEmpty {
                Text("用得最多的应用")
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                bars(apps, named: "用得最多的应用", identifier: "usage-apps")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-chart")
    }

    /// Each row's band: its name, a little gap, the bar in the middle, the gap to the next name.
    private static let band: CGFloat = 44

    private func bars(_ rows: [Row], named name: String, identifier: String) -> some View {
        let longest = Double(rows.map(\.seconds).max() ?? 0) / 60
        let said = rows.map { "\($0.label) \(UsageDay.duration($0.seconds))" }.joined(separator: "，")
        // the chart in a stack: what is said of it goes on the stack, as the chart keeps its own
        return VStack(spacing: 0) {
            Chart(rows) { row in
                BarMark(
                    x: .value("分钟", Double(row.seconds) / 60),
                    y: .value("名称", row.id),
                    height: .fixed(10)
                )
                .foregroundStyle(Self.bar)
                .cornerRadius(3)
                // the name over the bar's start, the time at its end
                .annotation(position: .top, alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .font(.t12)
                        .lineLimit(1)
                }
                .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                    Text(UsageDay.duration(row.seconds))
                        .font(.t12)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // room at the end of the longest bar for its time
            .chartXScale(domain: 0...max(1, longest * 1.3))
            .frame(height: CGFloat(rows.count) * Self.band)
        }
        // one element for VoiceOver (and the tests): every row and its time
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)：\(said)")
        .accessibilityValue(said)
        .accessibilityIdentifier(identifier)
    }
}

extension UsageDay {
    /// The demo's day: a student's, with the apps the demo's usage record has, and more (the
    /// demo's reports are about the day before the demo's moment, a whole one).
    nonisolated static func demo(day: String) -> UsageDay {
        let rows: [(id: String, name: String, category: UsageCategory, minutes: Int)] = [
            ("notion.id", "Notion", .study, 92),
            ("com.apple.Safari", "Safari", .uncategorized, 70),
            ("com.microsoft.VSCode", "Visual Studio Code", .work, 65),
            ("com.apple.Preview", "预览", .study, 41),
            ("jp.naver.line.mac", "LINE", .social, 38),
            ("com.spotify.client", "Spotify", .fun, 25),
            ("com.microsoft.Word", "Microsoft Word", .work, 22),
            ("com.apple.mail", "邮件", .uncategorized, 18),
            ("net.ankiweb.dtop", "Anki", .study, 18),
            ("com.hnc.Discord", "Discord", .social, 12),
            ("com.apple.iCal", "日历", .life, 8),
            ("com.apple.Maps", "地图", .life, 4),
        ]
        let apps = rows.map { App(id: $0.id, name: $0.name, category: $0.category, seconds: $0.minutes * 60) }
        var byCategory: [UsageCategory: Int] = [:]
        for app in apps {
            byCategory[app.category, default: 0] += app.seconds
        }
        return UsageDay(day: day, totalSeconds: apps.reduce(0) { $0 + $1.seconds }, byCategory: byCategory, apps: apps)
    }
}
