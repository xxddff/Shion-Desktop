import Foundation

// What this Mac knows that the server cannot, in plain values: the calendars, what you planned to
// be doing, what was in front and which apps were used. Nothing here touches AppKit, EventKit or
// the model, so it builds and is tested on Linux too (see README, 原生 App 的界面检查).

// MARK: - calendars

/// What a calendar holds, as the focus check sees it: classes and focus blocks are plans to check
/// the window in front against; the rest only shows on the calendar.
nonisolated enum CalendarRole: String, CaseIterable, Codable, Sendable {
    case lesson, focus, other

    var label: String {
        switch self {
        case .lesson: return "课"
        case .focus: return "专注时段"
        case .other: return "日程"
        }
    }

    /// A first guess from the calendar's name, until you pick one in Settings.
    static func guess(_ name: String) -> CalendarRole {
        let name = name.lowercased()
        let lessons = ["课", "課", "授業", "講義", "時間割", "时间表", "class", "course", "lecture", "timetable"]
        let focus = ["专注", "集中", "focus"]
        if lessons.contains(where: { name.contains($0) }) { return .lesson }
        if focus.contains(where: { name.contains($0) }) { return .focus }
        return .other
    }
}

/// A calendar's color: one of the palette's hues (the demo's calendars), or its own.
nonisolated enum CalendarColor: Hashable, Sendable {
    case hue(Int)
    case rgb(red: Double, green: Double, blue: Double)
}

/// A calendar on this Mac, as Settings lists it.
nonisolated struct CalendarInfo: Identifiable, Hashable, Sendable {
    /// EventKit's `calendarIdentifier`: the calendars you tick are kept by it.
    let id: String
    let title: String
    /// The account it is under: iCloud, Google, 在我的 Mac 上…
    let account: String
    let color: CalendarColor
    /// Ticked when the calendars are first listed: not birthdays or subscriptions (holidays).
    var preselected = true
}

/// One event as its calendar has it.
nonisolated struct CalendarItem: Identifiable, Hashable, Sendable {
    /// One per occurrence: a repeating event's occurrences share EventKit's identifier.
    let id: String
    let calendarId: String
    let title: String
    let start: Date
    let end: Date
    var allDay = false
    var place: String?
}

// MARK: - the plan

/// What you planned to be doing at a moment: a class or a focus block, or a todo whose time came.
nonisolated struct FocusPlan: Hashable, Sendable {
    nonisolated enum Source: Hashable, Sendable {
        case lesson, focus, todo
    }

    /// The event's or the todo's id: another id is another plan.
    let id: String
    let title: String
    let start: Date
    let source: Source
}

/// A todo, as far as plans go.
nonisolated struct PlanTodo: Hashable, Sendable {
    let id: String
    let title: String
    let doAt: Date?
    var done = false
    /// Its date is an assistant's suggestion you have not confirmed: not a plan yet.
    var proposed = false
}

nonisolated enum PlanPicker {
    /// The plan at `now`: the class or focus block under way (of several, the one that began
    /// last); else today's todo whose time came last, not done and not waiting on you to confirm
    /// its date. Nil when there is no plan: then nothing is checked.
    static func plan(at now: Date, items: [CalendarItem], roles: [String: CalendarRole], todos: [PlanTodo],
                     calendar: Calendar = .current) -> FocusPlan? {
        let blocks = items.filter { item in
            guard !item.allDay, item.start <= now, now < item.end else { return false }
            return (roles[item.calendarId] ?? .other) != .other
        }
        if let block = blocks.max(by: { $0.start < $1.start }) {
            let source: FocusPlan.Source = roles[block.calendarId] == .lesson ? .lesson : .focus
            return FocusPlan(id: "event:" + block.id, title: named(block.title), start: block.start, source: source)
        }
        let due = todos.filter { todo in
            guard let doAt = todo.doAt, !todo.done, !todo.proposed else { return false }
            return doAt <= now && calendar.isDate(doAt, inSameDayAs: now)
        }
        guard let todo = due.max(by: { ($0.doAt ?? .distantPast) < ($1.doAt ?? .distantPast) }),
              let doAt = todo.doAt
        else { return nil }
        return FocusPlan(id: "todo:" + todo.id, title: named(todo.title), start: doAt, source: .todo)
    }

    /// The plugin takes a plan name of 1–200 characters.
    static func named(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "没有标题的日程" : String(trimmed.prefix(200))
    }
}

// MARK: - the window in front

/// The app and window in front, as one look saw them. The title is empty when it could not be
/// read (no Accessibility permission, or a window without one).
nonisolated struct FrontWindow: Hashable, Codable, Sendable {
    var bundleId: String
    var app: String
    var title = ""
}

/// The plugin's six kinds of activity (`activity` of `focus.report`).
nonisolated enum ActivityKind: String, CaseIterable, Codable, Sendable {
    case study, work, life, fun, social, other

    /// As the plugin words them for 詩音.
    var label: String {
        switch self {
        case .study: return "学习"
        case .work: return "工作"
        case .life: return "生活"
        case .fun: return "娱乐"
        case .social: return "社交"
        case .other: return "别的事"
        }
    }
}

/// How the window in front stands to the plan: the plan itself, something to do with it, or not.
nonisolated enum Fit: String, Codable, Sendable {
    case same, related, unrelated
}

/// The on-device model's word on one window against one plan.
nonisolated struct Judgement: Hashable, Codable, Sendable {
    let fit: Fit
    let kind: ActivityKind
}

/// One stretch of the same window in front (or of being away), as the focus check saw it, with
/// the plan it was judged against. Kept on this Mac only, for 7 days.
nonisolated struct FocusSample: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let at: Date
    /// Nil while you were away: the screen locked or asleep, or no input for 5 minutes.
    let front: FrontWindow?
    /// The plan in force when it began; nil when there was none.
    let planId: String?
    var judgement: Judgement?

    var away: Bool { front == nil }
}

/// Where the focus check stands, against the plan of the moment.
nonisolated enum FocusState: Equatable, Sendable {
    /// No plan now: nothing to check.
    case free
    /// A plan, and the window in front is not judged yet.
    case watching(FocusPlan)
    case away(FocusPlan)
    case on(FocusPlan, Judgement)
    case off(FocusPlan, since: Date, kind: ActivityKind)
}

/// What 詩音 is told: `plugin.shion.focus.report`'s four values, and which stretch it is about.
nonisolated struct FocusReport: Hashable, Sendable {
    let plan: String
    let offMinutes: Int
    let activity: ActivityKind
    let onTrack: Bool
    let planId: String
    let since: Date
}

/// The focus check's memory: the windows seen and what 詩音 was last told. Off the plan for 5
/// minutes, she hears it once; back on it, she hears that too. Being away is not being off.
nonisolated struct FocusEngine: Codable, Sendable {
    /// Minutes off the plan before 詩音 hears of it.
    static let reportAfter: TimeInterval = 5 * 60
    /// No keyboard or mouse input for this long: you are not at the Mac.
    static let awayAfter: TimeInterval = 5 * 60
    /// How long the timeline is kept, and at most how many windows of it.
    static let keep: TimeInterval = 7 * 24 * 3600
    static let most = 5000

    nonisolated struct Told: Codable, Hashable, Sendable {
        let planId: String
        let since: Date
    }

    private(set) var samples: [FocusSample] = []
    /// The stretch off the plan 詩音 was told about, until she hears you are back on it.
    private(set) var told: Told?

    init(samples: [FocusSample] = []) {
        self.samples = samples
    }

    /// One look at what is in front at `now` (nil: away). A new sample when the window, being
    /// away or the plan changed, so the window in front is judged again when a plan begins.
    @discardableResult
    mutating func observe(_ front: FrontWindow?, plan: FocusPlan?, at now: Date) -> Bool {
        if let told, told.planId != plan?.id {
            self.told = nil  // that plan is over: nothing to come back to
        }
        if let last = samples.last, last.front == front, last.planId == plan?.id {
            return false
        }
        samples.append(FocusSample(at: now, front: front, planId: plan?.id))
        if samples.count > Self.most {
            samples.removeFirst(samples.count - Self.most)
        }
        return true
    }

    /// Samples of `plan` the model has not judged yet, newest last.
    func unjudged(for plan: FocusPlan) -> [FocusSample] {
        samples.filter { $0.planId == plan.id && !$0.away && $0.judgement == nil }
    }

    mutating func judge(_ id: UUID, _ judgement: Judgement) {
        guard let index = samples.lastIndex(where: { $0.id == id }) else { return }
        samples[index].judgement = judgement
    }

    /// While the window just come to the front is being judged, the last word stands.
    func state(plan: FocusPlan?) -> FocusState {
        guard let plan else { return .free }
        guard let last = samples.last, last.planId == plan.id else { return .watching(plan) }
        if last.away { return .away(plan) }
        guard let judgement = latestJudgement(for: plan) else { return .watching(plan) }
        if judgement.fit != .unrelated { return .on(plan, judgement) }
        // off since the first of the windows just before that were off it too (or not judged
        // yet), under this plan; being away ends a stretch
        var first = samples.count - 1
        while first > 0 {
            let previous = samples[first - 1]
            guard previous.planId == plan.id, !previous.away, (previous.judgement?.fit ?? .unrelated) == .unrelated
            else { break }
            first -= 1
        }
        return .off(plan, since: max(plan.start, samples[first].at), kind: judgement.kind)
    }

    /// The newest judgement under `plan`, across windows not judged yet but not across being away.
    private func latestJudgement(for plan: FocusPlan) -> Judgement? {
        for sample in samples.reversed() {
            guard sample.planId == plan.id, !sample.away else { return nil }
            if let judgement = sample.judgement { return judgement }
        }
        return nil
    }

    /// What to tell 詩音 at `now`, if anything: 5 minutes off the plan and not told yet; or back
    /// on it after she was told. Not while the window in front is still being judged.
    func due(plan: FocusPlan?, at now: Date) -> FocusReport? {
        guard samples.last?.judgement != nil else { return nil }
        switch state(plan: plan) {
        case .off(let plan, let since, let kind):
            guard now.timeIntervalSince(since) >= Self.reportAfter, told != Told(planId: plan.id, since: since) else { return nil }
            return FocusReport(plan: plan.title, offMinutes: Self.minutes(from: since, to: now), activity: kind,
                               onTrack: false, planId: plan.id, since: since)
        case .on(let plan, let judgement):
            guard let told, told.planId == plan.id else { return nil }
            // how long it was: from the stretch's start to the window that came back to the plan
            let back = samples.last?.at ?? now
            return FocusReport(plan: plan.title, offMinutes: Self.minutes(from: told.since, to: back),
                               activity: judgement.kind, onTrack: true, planId: plan.id, since: told.since)
        default:
            return nil
        }
    }

    /// 詩音 has been told.
    mutating func sent(_ report: FocusReport) {
        told = report.onTrack ? nil : Told(planId: report.planId, since: report.since)
    }

    /// Forgets what is older than `cutoff`, but not the window in front now.
    mutating func prune(before cutoff: Date) {
        guard samples.count > 1 else { return }
        let last = samples.removeLast()
        samples.removeAll { $0.at < cutoff }
        samples.append(last)
    }

    mutating func clear() {
        samples = []
        told = nil
    }

    /// Whole minutes, as the plugin takes them (0–1440).
    static func minutes(from start: Date, to end: Date) -> Int {
        min(1440, max(0, Int(end.timeIntervalSince(start) / 60)))
    }
}

// MARK: - app usage

/// A stretch of one app in front, as the plugin's `usage.upload` takes it: which app, from when
/// to when. No window titles: they never leave this Mac.
nonisolated struct UsageSegment: Codable, Hashable, Sendable {
    var bundleId: String
    var app: String
    var start: Date
    var end: Date
    /// The end the server has for it; nil until it was sent. A segment is known by its app and
    /// start, so sending it again with a later end updates it there.
    var sentEnd: Date?

    var seconds: TimeInterval { end.timeIntervalSince(start) }
}

/// Which app was in front when, compacted from the looks the Mac takes every few seconds into
/// one segment per stay in an app. What `usage.upload` sends: the app and its times, nothing else.
nonisolated struct UsageLog: Codable, Sendable {
    /// Shorter stays (passing through an app while switching) are not kept.
    static let shortest: TimeInterval = 5
    /// No look for this long (the Mac slept): the open stay ended at its last look.
    static let gap: TimeInterval = 90
    /// One segment at most this long; the plugin takes up to 24 hours.
    static let longest: TimeInterval = 12 * 3600
    /// How long segments are kept on this Mac (the server keeps them 30 days).
    static let keep: TimeInterval = 7 * 24 * 3600

    /// Closed stays, oldest first.
    private(set) var segments: [UsageSegment] = []
    /// The stay in progress.
    private(set) var current: UsageSegment?

    init(segments: [UsageSegment] = []) {
        self.segments = segments
    }

    /// One look at what is in front at `now`. `front` is nil while the screen is locked or
    /// asleep; `idle` is how long since the last keyboard or mouse input. Excluded apps, and
    /// time away (no input for 5 minutes), are not recorded.
    mutating func observe(_ front: FrontWindow?, idle: TimeInterval, at now: Date, excluded: Set<String>) {
        var here = front
        if let app = front, app.bundleId.isEmpty || excluded.contains(app.bundleId) || idle >= FocusEngine.awayAfter {
            here = nil
        }
        if var open = current {
            if now.timeIntervalSince(open.end) > Self.gap {
                close()  // the Mac slept: it ended at its last look
            } else if here?.bundleId != open.bundleId || now.timeIntervalSince(open.start) >= Self.longest {
                if front == nil || idle >= FocusEngine.awayAfter {
                    // away: it ended at the last input
                    open.end = max(open.start, min(now, now.addingTimeInterval(-idle)))
                } else {
                    open.end = now
                }
                current = open
                close()
            } else {
                open.end = now
                if let name = here?.app, !name.isEmpty { open.app = name }
                current = open
            }
        }
        if current == nil, let here {
            let start = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            current = UsageSegment(bundleId: here.bundleId, app: here.app.isEmpty ? here.bundleId : here.app,
                                   start: start, end: start)
        }
    }

    /// Ends the stay in progress (recording stopped).
    mutating func close() {
        guard var open = current else { return }
        current = nil
        if open.sentEnd != nil {
            // the server has it: keep it, so the shorter end it ended with goes out too
            if open.end <= open.start { open.end = open.start.addingTimeInterval(1) }
            segments.append(open)
        } else if open.seconds >= Self.shortest {
            segments.append(open)
        }
    }

    /// What the server does not have yet: segments never sent, or whose end moved since; the
    /// stay in progress too, once it is long enough to keep.
    func unsent(excluding excluded: Set<String> = []) -> [UsageSegment] {
        var out = segments.filter { $0.sentEnd != $0.end && !excluded.contains($0.bundleId) }
        if let open = current, open.seconds >= Self.shortest, open.sentEnd != open.end, !excluded.contains(open.bundleId) {
            out.append(open)
        }
        return out
    }

    /// The server took these.
    mutating func markSent(_ sent: [UsageSegment]) {
        for item in sent {
            if let index = segments.firstIndex(where: { $0.bundleId == item.bundleId && $0.start == item.start }) {
                segments[index].sentEnd = item.end
            }
            if let open = current, open.bundleId == item.bundleId, open.start == item.start {
                current?.sentEnd = item.end
            }
        }
    }

    /// An app you no longer want recorded: its segments go from this Mac (not from the server).
    mutating func forget(_ bundleId: String) {
        segments.removeAll { $0.bundleId == bundleId }
        if current?.bundleId == bundleId { current = nil }
    }

    mutating func prune(before cutoff: Date) {
        segments.removeAll { $0.end < cutoff }
    }

    mutating func clear() {
        segments = []
        current = nil
    }

    /// All the stays, closed and in progress, oldest first.
    var all: [UsageSegment] { segments + (current.map { [$0] } ?? []) }

    /// Seconds in front between `start` and `end`.
    func seconds(from start: Date, to end: Date) -> TimeInterval {
        all.reduce(0) { total, segment in
            total + max(0, min(segment.end, end).timeIntervalSince(max(segment.start, start)))
        }
    }

    /// Apps by time in front since `start`, the most used first: (bundle id, name, seconds).
    func apps(since start: Date) -> [(bundleId: String, app: String, seconds: TimeInterval)] {
        var seconds: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        for segment in all where segment.end > start {
            seconds[segment.bundleId, default: 0] += segment.end.timeIntervalSince(max(segment.start, start))
            names[segment.bundleId] = segment.app
        }
        return seconds.map { (bundleId: $0.key, app: names[$0.key] ?? $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.app < $1.app }
    }
}

// MARK: - on the wire

nonisolated enum WireTime {
    /// ISO 8601 with this Mac's offset, to the second (`2026-11-09T10:52:00+09:00`), as the
    /// plugin asks the Mac to send its times.
    static func string(_ date: Date, in zone: TimeZone = .current) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: zone))
    }
}
