import Foundation

// Where local data comes from, as LocalData sees it, and the made-up sources screenshots and
// tests use: a CI runner cannot grant calendar or Accessibility access, and has no Apple
// Intelligence. The real ones are in MacSources.swift and ModelJudge.swift.

/// Whether Shion may read the calendars on this Mac.
enum CalendarAccess: Equatable {
    case notDetermined, denied, granted
}

/// The calendars on this Mac.
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    /// Asks once (the system's prompt); afterwards only System Settings can change it.
    func requestAccess() async
    func calendars() -> [CalendarInfo]
    func items(from start: Date, to end: Date, in calendars: Set<String>) -> [CalendarItem]
    /// The calendars changed: an event was added or moved here, or synced from an account.
    var onChange: (() -> Void)? { get set }
}

/// What is in front of you: the app, its window's title when Shion may read it, how long since
/// the last keyboard or mouse input, and whether the screen is locked or asleep.
protocol FrontSource: AnyObject {
    /// The app and window in front; nil while the screen is locked or asleep.
    func look(titles: Bool) async -> FrontWindow?
    /// Seconds since the last keyboard or mouse input.
    var idleSeconds: TimeInterval { get }
    /// Whether Shion may read other apps' window titles (Privacy & Security → Accessibility).
    var titlesAllowed: Bool { get }
    /// Asks for that permission: the system's prompt the first time, then its pane in System Settings.
    func askForTitles()
    /// Another app came to the front, or the screen locked, unlocked, slept or woke.
    var onChange: (() -> Void)? { get set }
}

enum JudgeStatus: Equatable {
    case ready
    case unavailable(String)
}

/// Judges the window in front against the plan, on this Mac.
protocol FocusJudge: AnyObject {
    var status: JudgeStatus { get }
    /// Nil when it cannot say (the model is not available, or this window failed).
    func judge(plan: String, app: String, title: String) async -> Judgement?
}

// MARK: - made up, for screenshots and tests

final class FixtureCalendars: CalendarSource {
    let access: CalendarAccess
    private let all: [CalendarInfo]
    private let events: [CalendarItem]
    var onChange: (() -> Void)?

    init(access: CalendarAccess, calendars: [CalendarInfo], items: [CalendarItem]) {
        self.access = access
        self.all = calendars
        self.events = items
    }

    /// Screenshot runs never ask for anything.
    func requestAccess() async {}

    func calendars() -> [CalendarInfo] {
        access == .granted ? all : []
    }

    func items(from start: Date, to end: Date, in ids: Set<String>) -> [CalendarItem] {
        guard access == .granted else { return [] }
        return events.filter { ids.contains($0.calendarId) && $0.start < end && $0.end > start }
    }
}

/// Windows in front one after the other, as a test scripts them; `advance` brings the next.
final class ScriptedFront: FrontSource {
    private let windows: [FrontWindow?]
    private var index = 0
    var onChange: (() -> Void)?

    init(_ windows: [FrontWindow?]) {
        self.windows = windows
    }

    func look(titles: Bool) async -> FrontWindow? {
        windows.isEmpty ? nil : windows[index]
    }

    var idleSeconds: TimeInterval { 0 }
    var titlesAllowed: Bool { true }
    func askForTitles() {}

    func advance() {
        guard index + 1 < windows.count else { return }
        index += 1
        onChange?()
    }
}

/// What the on-device model would say about the demo's and the tests' windows, without one.
final class FixtureJudge: FocusJudge {
    var status: JudgeStatus { .ready }

    func judge(plan: String, app: String, title: String) async -> Judgement? {
        Self.rule(plan: plan, app: app, title: title)
    }

    static func rule(plan: String, app: String, title: String) -> Judgement {
        let window = app + " " + title
        // the plan's own words in the title: this is it
        let words = plan.replacingOccurrences(of: "CI：", with: "")
            .split(whereSeparator: { " ：:·（）()".contains($0) })
            .map(String.init)
            .filter { $0.count >= 2 }
        if words.contains(where: { title.contains($0) }) || title.contains("課前小テスト") {
            return Judgement(fit: .same, kind: .study)
        }
        if window.contains("講義") || window.contains("解説") || window.contains("Notion") {
            return Judgement(fit: .related, kind: .study)
        }
        if app == "LINE" || app == "Slack" || window.contains("X（") {
            return Judgement(fit: .unrelated, kind: .social)
        }
        if window.contains("YouTube") || window.contains("猫") || window.contains("Steam") {
            return Judgement(fit: .unrelated, kind: .fun)
        }
        return Judgement(fit: .unrelated, kind: .other)
    }
}
