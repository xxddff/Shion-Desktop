import Foundation
import Observation

/// Where this run's local data comes from.
enum LocalMode: Equatable {
    /// This Mac: EventKit, NSWorkspace, Accessibility and the on-device model; files in Application Support.
    case real
    /// Screenshot runs: made-up calendars and windows, standing still. Nothing is asked for, sent or saved.
    case snapshot
    /// End-to-end tests: made-up calendars and windows that follow the clock, reported to the stand-in server.
    case script
}

/// What LocalData needs from the app: todos as plans, and the server's shion plugin.
protocol LocalHost: AnyObject {
    /// Todos as plans: the plugin's (the demo's in screenshot and test runs); none without the plugin.
    var planTodos: [PlanTodo] { get }
    /// Whether the plugin can take a report or an upload now.
    var pluginReady: Bool { get }
    /// `plugin.shion.focus.report`.
    func sendFocus(_ report: FocusReport) async throws -> FocusOutcome
    /// `plugin.shion.usage.upload`.
    func sendUsage(_ segments: [UsageSegment]) async throws
    /// The calendars or their events changed.
    func calendarChanged()
    /// 总秘书 as chosen on this Mac, while connected; nil when no choice was made here (the
    /// server's setting stands) or the chosen profile is gone.
    var chosenChief: ChiefChoice? { get }
    /// The plugin's `chief_profile` setting, asked in that profile. Throws `PluginCallError`.
    func pluginChief(in profile: String) async throws -> String?
    /// Sets the plugin's `chief_profile` to that profile, in that profile. Throws `PluginCallError`.
    func setPluginChief(_ profile: String) async throws
}

/// The plugin's answer to a focus report: whether it woke 总秘书, and why not.
nonisolated struct FocusOutcome: Hashable, Sendable {
    var woke: Bool
    var reason: String?
    /// 总秘书's name when the report went out.
    var chief = ""
}

/// A 总秘书 chosen on this Mac: the profile, and the name Shion shows for it.
nonisolated struct ChiefChoice: Hashable, Sendable {
    let id: String
    let name: String
}

/// Why a call to the plugin did not go through.
nonisolated enum PluginCallError: Error, Hashable, Sendable {
    /// That profile has no shion plugin: Hermes knows no such method there (-32601).
    case notInstalled
    /// Anything else, in words for Settings.
    case failed(String)
}

/// Whether the plugin wakes the 总秘书 chosen on this Mac. The plugin wakes whoever its
/// `chief_profile` setting names, one setting for every profile.
nonisolated enum ChiefSync: Hashable, Sendable {
    /// Nothing to do: not connected, or no choice made on this Mac.
    case idle
    /// The plugin wakes this one.
    case synced(ChiefChoice)
    /// That profile has no shion plugin, so the focus check cannot reach it.
    case noPlugin(ChiefChoice)
    /// The setting could not be changed; the next connection tries again.
    case failed(ChiefChoice, String)
}

/// The last thing 总秘书 was told.
nonisolated struct SentFocus: Hashable, Sendable {
    let at: Date
    let report: FocusReport
    let outcome: FocusOutcome
}

nonisolated struct ExcludedApp: Codable, Hashable, Sendable, Identifiable {
    let bundleId: String
    let name: String

    var id: String { bundleId }
}

/// Your choices, kept in the app's preferences (in memory only in screenshot and test runs).
nonisolated struct LocalSettings: Codable, Hashable, Sendable {
    /// Ticked calendars, by EventKit identifier; nil until the calendars were first listed.
    var calendars: [String]?
    /// What each calendar holds, where you picked it; else a guess from its name.
    var roles: [String: CalendarRole] = [:]
    var focusCheck = false
    var usageLog = true
    var excluded: [ExcludedApp] = []
}

/// Files under Application Support/Shion: the focus check's timeline and the usage record.
nonisolated struct LocalFiles: Sendable {
    let folder: URL

    static var standard: LocalFiles? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { LocalFiles(folder: $0.appendingPathComponent("Shion", isDirectory: true)) }
    }

    func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            // window titles are in there: for this user only
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name), options: [.atomic])
        } catch {
            // the next save tries again
        }
    }
}

/// What this Mac knows that the server cannot: its calendars, the window in front (for the
/// focus check) and which app was in front when. Window titles and the timeline stay here; 总秘书
/// only hears the focus check's verdict, 回顾 only gets which app was in front when.
@Observable
final class LocalData {
    let mode: LocalMode
    /// The time, a tick every 30 seconds: pages that follow the real clock redraw with it.
    private(set) var clock: Date
    private(set) var settings: LocalSettings

    // calendars
    private(set) var access: CalendarAccess = .notDetermined
    private(set) var calendars: [CalendarInfo] = []
    /// Events of the ticked calendars, from a week back to two weeks on.
    private(set) var items: [CalendarItem] = []

    // the focus check
    private(set) var engine = FocusEngine()
    private(set) var titlesAllowed = false
    private(set) var judgeStatus: JudgeStatus = .ready
    private(set) var pausedUntil: Date?
    private(set) var lastSent: SentFocus?
    /// Whether the plugin wakes the 总秘书 chosen on this Mac.
    private(set) var chiefSync: ChiefSync = .idle

    // app usage
    @ObservationIgnored private(set) var usage = UsageLog()
    private(set) var usageToday: TimeInterval = 0
    private(set) var lastUpload: Date?
    private(set) var uploadFailed = false

    @ObservationIgnored weak var host: LocalHost?
    /// The time now; a test can set its own.
    @ObservationIgnored var timeSource: () -> Date = { Date() }
    /// Screenshot runs: the demo's moment, which their calendars and today's usage are laid out around.
    private let pinned: Date?
    private let calendarSource: CalendarSource
    private let front: FrontSource
    private let judge: FocusJudge
    private let files: LocalFiles?
    private let defaults: UserDefaults?
    /// The model's word per plan and window: a title is judged once.
    @ObservationIgnored private var verdicts: [String: Judgement] = [:]
    @ObservationIgnored private var failed: [String: Date] = [:]
    @ObservationIgnored private var looking = false
    @ObservationIgnored private var lookAgain = false
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var retryAt = Date.distantPast
    @ObservationIgnored private var uploading = false
    @ObservationIgnored private var nextUpload = Date.distantPast
    @ObservationIgnored private var pluginWasReady = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pruned = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var calendarRefresh: Task<Void, Never>?

    static let settingsKey = "ShionLocal"

    init(mode: LocalMode, calendars: CalendarSource, front: FrontSource, judge: FocusJudge, settings: LocalSettings,
         files: LocalFiles? = nil, defaults: UserDefaults? = nil, engine: FocusEngine? = nil, usage: UsageLog? = nil,
         pinned: Date? = nil) {
        self.mode = mode
        self.calendarSource = calendars
        self.front = front
        self.judge = judge
        self.settings = settings
        self.files = files
        self.defaults = defaults
        self.pinned = pinned
        self.clock = Date()
        let savedTimeline: FocusEngine? = files?.load("focus.json")
        let savedUsage: UsageLog? = files?.load("usage.json")
        self.engine = engine ?? savedTimeline ?? FocusEngine()
        self.usage = usage ?? savedUsage ?? UsageLog()
    }

    /// The settings saved in `defaults`, or the defaults.
    static func savedSettings(_ defaults: UserDefaults) -> LocalSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let saved = try? JSONDecoder().decode(LocalSettings.self, from: data)
        else { return LocalSettings() }
        return saved
    }

    /// Reads the calendars and, except in screenshot runs, starts looking at the window in front
    /// every few seconds and sending what is due.
    func start(_ host: LocalHost) {
        guard !started else { return }
        started = true
        self.host = host
        calendarSource.onChange = { [weak self] in self?.calendarsChanged() }
        front.onChange = { [weak self] in self?.lookSoon() }
        titlesAllowed = front.titlesAllowed
        judgeStatus = judge.status
        refreshCalendars()
        updateUsageToday()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.tick()
            }
        })
        guard mode != .snapshot else { return }
        let fast = mode == .script
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.look()
                try? await Task.sleep(for: .seconds(fast ? 2 : 5))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(fast ? 2 : 15))
                await self?.uploadIfDue()
            }
        })
        guard mode == .real else { return }
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.saveIfDirty()
            }
        })
        MacLocal.onQuit { [weak self] in
            self?.saveNow()
        }
    }

    /// Every 30 seconds: the clock, a new day's calendar, permissions coming and going.
    func tick() {
        let now = timeSource()
        let newDay = !Calendar.current.isDate(now, inSameDayAs: clock)
        clock = now
        // a new day's events, or access given (or taken) in System Settings meanwhile
        if newDay || calendarSource.access != access { refreshCalendars() }
        let allowed = front.titlesAllowed
        if allowed != titlesAllowed { titlesAllowed = allowed }
        updateJudgeStatus()
        updateUsageToday()
        if now.timeIntervalSince(pruned) > 3600 {
            pruned = now
            var timeline = engine
            timeline.prune(before: now.addingTimeInterval(-FocusEngine.keep))
            if timeline.samples.count != engine.samples.count { engine = timeline }
            usage.prune(before: now.addingTimeInterval(-UsageLog.keep))
            if verdicts.count > 2000 { verdicts = [:] }
        }
    }

    /// Whether the pages follow the real clock: they show this Mac's calendars (or a test's).
    var realTime: Bool {
        switch mode {
        case .real: return access == .granted
        case .snapshot: return false
        case .script: return true
        }
    }

    // MARK: - calendars

    /// What a calendar holds: as you picked it, else as its name suggests.
    func role(of calendarId: String) -> CalendarRole {
        if let role = settings.roles[calendarId] { return role }
        return CalendarRole.guess(calendars.first { $0.id == calendarId }?.title ?? "")
    }

    func isTicked(_ calendarId: String) -> Bool {
        settings.calendars?.contains(calendarId) ?? false
    }

    func setTicked(_ calendarId: String, _ on: Bool) {
        var ticked = settings.calendars ?? []
        ticked.removeAll { $0 == calendarId }
        if on { ticked.append(calendarId) }
        change { $0.calendars = ticked }
        refreshCalendars()
    }

    func setRole(_ role: CalendarRole, of calendarId: String) {
        change { $0.roles[calendarId] = role }
        host?.calendarChanged()
    }

    /// Asks for calendar access the first time; after a refusal, opens System Settings.
    func requestCalendarAccess() async {
        switch calendarSource.access {
        case .notDetermined:
            await calendarSource.requestAccess()
            refreshCalendars()
        case .denied:
            if mode == .real { MacLocal.openPrivacy("Privacy_Calendars") }
        case .granted:
            refreshCalendars()
        }
    }

    func refreshCalendars() {
        let now = timeSource()
        access = calendarSource.access
        guard access == .granted else {
            if !calendars.isEmpty { calendars = [] }
            if !items.isEmpty { items = [] }
            host?.calendarChanged()
            return
        }
        calendars = calendarSource.calendars()
        if settings.calendars == nil, !calendars.isEmpty {
            // the first time they are listed: the usual ones ticked; Settings has the rest
            let first = calendars.filter(\.preselected).map(\.id)
            change { $0.calendars = first }
        }
        let today = Calendar.current.startOfDay(for: pinned ?? now)
        let start = Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today
        let end = Calendar.current.date(byAdding: .day, value: 15, to: today) ?? today
        items = calendarSource.items(from: start, to: end, in: Set(settings.calendars ?? []))
        host?.calendarChanged()
    }

    private func calendarsChanged() {
        // EventKit sends a burst while an account syncs: read once it settles
        calendarRefresh?.cancel()
        calendarRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshCalendars()
        }
    }

    // MARK: - the focus check

    /// What the menu bar shows of the focus check.
    enum FocusView: Equatable {
        /// Turned off in Settings: nothing shows.
        case off
        case paused(until: Date)
        /// No Accessibility permission: window titles cannot be read.
        case needsTitles
        case noModel(String)
        case checking(FocusCheckState)
    }

    /// The plan at `now`: the class or focus block under way in a ticked calendar, else today's
    /// todo whose time came.
    func plan(at now: Date) -> FocusPlan? {
        let roles = Dictionary(calendars.map { ($0.id, role(of: $0.id)) }, uniquingKeysWith: { first, _ in first })
        return PlanPicker.plan(at: now, items: access == .granted ? items : [], roles: roles, todos: host?.planTodos ?? [])
    }

    func focusView(at now: Date) -> FocusView {
        guard settings.focusCheck else { return .off }
        if let pausedUntil, pausedUntil > now { return .paused(until: pausedUntil) }
        if !titlesAllowed { return .needsTitles }
        if case .unavailable(let why) = judgeStatus { return .noModel(why) }
        return .checking(engine.state(plan: plan(at: now)))
    }

    /// The focus check is on, may read titles, has a model and is not paused.
    private var checking: Bool {
        settings.focusCheck && titlesAllowed && judgeStatus == .ready && !(pausedUntil.map { $0 > timeSource() } ?? false)
    }

    func setFocusCheck(_ on: Bool) {
        change { $0.focusCheck = on }
        if on {
            // the first time it is turned on, the system asks for Accessibility
            if !front.titlesAllowed { front.askForTitles() }
            pausedUntil = nil
            lookSoon()
        }
    }

    func askForTitles() {
        front.askForTitles()
    }

    func pause(minutes: Int) {
        pausedUntil = timeSource().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func resume() {
        pausedUntil = nil
        lookSoon()
    }

    /// Forgets the windows seen (Settings' 清空).
    func clearFocusLog() {
        engine.clear()
        verdicts = [:]
        failed = [:]
        lastSent = nil
        dirty = true
        saveNow()
    }

    private func updateJudgeStatus() {
        let status = judge.status
        if status != judgeStatus { judgeStatus = status }
    }

    // MARK: - looking at the window in front

    private func lookSoon() {
        guard mode != .snapshot else { return }
        Task { [weak self] in await self?.look() }
    }

    /// One look at what is in front, for the usage record and the focus check; then whatever is
    /// due to 总秘书. Looks never overlap: one asked for meanwhile runs right after.
    func look() async {
        guard !looking else {
            lookAgain = true
            return
        }
        looking = true
        repeat {
            lookAgain = false
            await lookOnce()
        } while lookAgain
        looking = false
    }

    private func lookOnce() async {
        let allowed = front.titlesAllowed
        if allowed != titlesAllowed { titlesAllowed = allowed }
        let focus = checking
        let recording = settings.usageLog
        guard focus || recording else { return }
        let seen = await front.look(titles: focus)
        let now = timeSource()
        let idle = front.idleSeconds
        if recording {
            usage.observe(seen, idle: idle, at: now, excluded: excludedIds)
            dirty = true
        }
        guard focus, checking else { return }
        let plan = plan(at: now)
        var timeline = engine
        if timeline.observe(idle >= FocusEngine.awayAfter ? nil : seen, plan: plan, at: now) {
            engine = timeline
            dirty = true
        }
        if let plan {
            await judgeWindows(of: plan)
        }
        await reportIfDue(plan: plan, at: now)
    }

    private func judgeWindows(of plan: FocusPlan) async {
        for sample in engine.unjudged(for: plan) {
            guard let window = sample.front else { continue }
            let key = [plan.title, window.bundleId, window.title].joined(separator: "\u{1F}")
            var verdict = verdicts[key]
            if verdict == nil {
                if let at = failed[key], timeSource().timeIntervalSince(at) < 600 { continue }
                verdict = await judge.judge(plan: plan.title, app: window.app, title: window.title)
                if let verdict {
                    verdicts[key] = verdict
                } else {
                    failed[key] = timeSource()
                }
                updateJudgeStatus()
            }
            guard let verdict else { continue }
            engine.judge(sample.id, verdict)
            dirty = true
        }
    }

    private func reportIfDue(plan: FocusPlan?, at now: Date) async {
        guard mode != .snapshot, !sending, now >= retryAt, let host, host.pluginReady,
              let report = engine.due(plan: plan, at: now)
        else { return }
        sending = true
        do {
            var outcome = try await host.sendFocus(report)
            if outcome.reason == "wrong_profile", host.chosenChief != nil {
                // the plugin's 总秘书 is not this Mac's (a report that went out before the setting
                // was changed on connecting): change it, and say it again where it is heard
                await syncChief()
                if case .synced = chiefSync {
                    outcome = try await host.sendFocus(report)
                }
            }
            engine.sent(report)
            lastSent = SentFocus(at: now, report: report, outcome: outcome)
            dirty = true
            if mode == .script, !report.onTrack { scriptNext() }
        } catch {
            // offline or refused: the stretch is still off, so it goes out again in a minute
            retryAt = now.addingTimeInterval(60)
        }
        sending = false
    }

    /// Tests: once 总秘书 has heard you drifted off, the next window comes to the front.
    private func scriptNext() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let script = self?.front as? ScriptedFront else { return }
            script.advance()
        }
    }

    /// The plugin wakes whoever its `chief_profile` setting names, so the focus check follows the
    /// 总秘书 chosen on this Mac: after a choice, on connecting and after a reconnect, the setting is
    /// changed where it differs. Without a choice made here the server's setting stands. A failure
    /// stops nothing; the next connection tries again.
    func syncChief() async {
        guard let host, let choice = host.chosenChief else {
            chiefSync = .idle
            return
        }
        let result: ChiefSync
        do {
            if try await host.pluginChief(in: choice.id) != choice.id {
                try await host.setPluginChief(choice.id)
            }
            result = .synced(choice)
        } catch PluginCallError.notInstalled {
            result = .noPlugin(choice)
        } catch PluginCallError.failed(let why) {
            result = .failed(choice, why)
        } catch {
            result = .failed(choice, error.localizedDescription)
        }
        // chosen again meanwhile: that choice's own sync says how it went
        guard host.chosenChief == choice else { return }
        chiefSync = result
    }

    // MARK: - app usage

    private var excludedIds: Set<String> { Set(settings.excluded.map(\.bundleId)) }

    func setUsageLog(_ on: Bool) {
        change { $0.usageLog = on }
        if !on {
            usage.close()
            dirty = true
        }
        updateUsageToday()
    }

    /// Leaves an app out of the record; what this Mac kept of it goes too (not what was sent).
    func exclude(_ app: ExcludedApp) {
        guard !excludedIds.contains(app.bundleId) else { return }
        change { $0.excluded.append(app) }
        usage.forget(app.bundleId)
        dirty = true
        updateUsageToday()
    }

    func include(_ bundleId: String) {
        change { $0.excluded.removeAll { $0.bundleId == bundleId } }
    }

    /// Apps used this week that are not left out, the most used first: for the exclude menu.
    func recentApps() -> [ExcludedApp] {
        usage.apps(since: timeSource().addingTimeInterval(-UsageLog.keep))
            .filter { !excludedIds.contains($0.bundleId) }
            .prefix(15)
            .map { ExcludedApp(bundleId: $0.bundleId, name: $0.app) }
    }

    private func updateUsageToday() {
        let now = pinned ?? timeSource()
        let seconds = usage.seconds(from: Calendar.current.startOfDay(for: now), to: now)
        if abs(seconds - usageToday) >= 1 { usageToday = seconds }
    }

    /// Right after the plugin comes up, then every 10 minutes: what the server does not have yet.
    private func uploadIfDue() async {
        guard let host else { return }
        let ready = host.pluginReady
        let fresh = ready && !pluginWasReady
        pluginWasReady = ready
        guard ready, settings.usageLog, fresh || timeSource() >= nextUpload else { return }
        await upload()
    }

    func upload() async {
        guard !uploading, let host else { return }
        let now = timeSource()
        nextUpload = now.addingTimeInterval(600)
        let batch = Array(usage.unsent(excluding: excludedIds).prefix(1000))
        guard !batch.isEmpty else { return }
        uploading = true
        do {
            try await host.sendUsage(batch)
            usage.markSent(batch)
            lastUpload = now
            if uploadFailed { uploadFailed = false }
            dirty = true
            if batch.count == 1000 { nextUpload = now }  // more after these
        } catch {
            uploadFailed = true
        }
        uploading = false
    }

    // MARK: - keeping it

    private func change(_ edit: (inout LocalSettings) -> Void) {
        var next = settings
        edit(&next)
        guard next != settings else { return }
        settings = next
        if mode == .real, let defaults, let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveIfDirty() {
        guard dirty, let files else { return }
        dirty = false
        let timeline = engine
        let record = usage
        Task.detached(priority: .utility) {
            files.save(timeline, "focus.json")
            files.save(record, "usage.json")
        }
    }

    /// As the app quits, or after 清空: written before returning.
    func saveNow() {
        guard let files else { return }
        dirty = false
        files.save(engine, "focus.json")
        files.save(usage, "usage.json")
    }
}
