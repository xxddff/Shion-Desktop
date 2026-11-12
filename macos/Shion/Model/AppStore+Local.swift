import SwiftUI

/// This Mac's own data in the window: its calendars on 今天, 日程 and in the menu bar (with or
/// without a server), and what goes to the server's shion plugin: the focus check's verdict
/// (`focus.report`) and which app was in front when (`usage.upload`). LocalData has the rest.
extension AppStore: LocalHost {
    func startLocal() {
        local.start(self)
    }

    // MARK: the calendar

    /// 今天, 日程 and the menu bar's 下一件: the ticked calendars once Shion may read them, whether a
    /// server is connected or not; the demo's week until then.
    func applyCalendar() {
        guard local.access == .granted else {
            events = LaunchOptions.current.snapshot ? DemoData(now: demoClock).events : []
            return
        }
        let calendars = Dictionary(local.calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var shown = local.items.map { event(from: $0, in: calendars[$0.calendarId]) }
        if local.mode == .snapshot {
            // screenshots keep the demo's rides to school and home: they are 通勤's, not a calendar's
            shown += DemoData(now: demoClock).events.filter { $0.kind == .commute }
        }
        events = shown
    }

    func calendarChanged() {
        applyCalendar()
    }

    private func event(from item: CalendarItem, in calendar: CalendarInfo?) -> CalEvent {
        let role = local.role(of: item.calendarId)
        return CalEvent(
            id: item.id,
            title: item.title.isEmpty ? "没有标题" : item.title,
            kind: role == .lesson ? .lesson : (role == .focus ? .focus : .event),
            area: role == .other ? .life : .study,
            start: item.start,
            end: item.end,
            place: item.place,
            tint: calendar.map { Self.tint($0.color) },
            allDay: item.allDay
        )
    }

    /// A calendar's color on screen: a palette hue for the demo's, the calendar's own for this Mac's.
    static func tint(_ color: CalendarColor) -> Color {
        switch color {
        case .hue(let index): return Palette.hues[index % Palette.hues.count]
        case .rgb(let red, let green, let blue): return Color(.sRGB, red: red, green: green, blue: blue)
        }
    }

    // MARK: what goes to the plugin

    /// The plugin's todos are plans once their time comes: the server's, or the last of them while
    /// not connected (never the demo's, which stand in when the server had no plugin). Screenshot
    /// and test runs: the demo's.
    var planTodos: [PlanTodo] {
        let real = pluginData || (lastData.shown && lastData.file?.todos != nil)
        guard real || local.mode != .real else { return [] }
        return todos.map { PlanTodo(id: $0.id, title: $0.title, doAt: $0.doAt, done: $0.done, proposed: $0.proposed) }
    }

    /// Reports and uploads go out only while connected to the plugin and showing the server's own
    /// data, not the last of it (`readOnly`); meanwhile they wait, and go out once it is live.
    var pluginReady: Bool {
        pluginData && gateway.phase == .online && !readOnly
    }

    /// `plugin.shion.focus.report` in 总秘书's profile (the plugin's `chief_profile`), with that
    /// Bot Chat's session id when it is attached: the plugin wakes 总秘书 there. Only the plan, the
    /// minutes and the kind of thing: never a window title or an app.
    func sendFocus(_ report: FocusReport) async throws -> FocusOutcome {
        var params: [String: JSONValue] = [
            "profile": .string(chiefId),
            "plan": .string(report.plan),
            "off_minutes": .number(Double(report.offMinutes)),
            "activity": .string(report.activity.rawValue),
            "on_track": .bool(report.onTrack),
        ]
        if let session = botChatSession(chiefId) {
            params["session_id"] = .string(session)
        }
        let name = chiefName
        let reply = try await gateway.call("plugin.shion.focus.report", .object(params))
        return FocusOutcome(woke: reply["woke"]?.bool ?? false, reason: reply["reason"]?.string, chief: name)
    }

    // MARK: who the plugin wakes

    var chosenChief: ChiefChoice? {
        guard live, gateway.phase == .online, let chosen = roster.prefs.chief, chosen == chiefId else { return nil }
        return ChiefChoice(id: chosen, name: chiefName)
    }

    func pluginChief(in profile: String) async throws -> String? {
        let reply = try await pluginRPC("settings.get", in: profile)
        return reply["settings"]?["chief_profile"]?.string
    }

    func setPluginChief(_ profile: String) async throws {
        _ = try await pluginRPC("settings.update", in: profile, ["chief_profile": .string(profile)])
    }

    /// A shion plugin call in that profile. Hermes answers -32601 where no plugin of that name is
    /// loaded: not installed or not enabled there.
    private func pluginRPC(_ method: String, in profile: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard serverCapabilities.contains("plugin-rpc-v1") else {
            throw PluginCallError.failed("服务器不支持插件 RPC")
        }
        var fields = params
        fields["profile"] = .string(profile)
        do {
            return try await gateway.call("plugin.shion." + method, .object(fields))
        } catch GatewayError.rpc(let code, _, _) where code == -32601 {
            throw PluginCallError.notInstalled
        } catch {
            throw PluginCallError.failed(error.localizedDescription)
        }
    }

    /// `plugin.shion.usage.upload`: each segment is the app and its times, the four keys the plugin
    /// takes. The server knows a segment by its app and start, so sending one again updates it.
    func sendUsage(_ segments: [UsageSegment]) async throws {
        let rows: [JSONValue] = segments.map { segment in
            [
                "bundle_id": .string(String(segment.bundleId.prefix(255))),
                "app_name": .string(String(segment.app.prefix(255))),
                "start": .string(WireTime.string(segment.start)),
                "end": .string(WireTime.string(segment.end)),
            ]
        }
        try await gateway.call("plugin.shion.usage.upload", [
            "profile": .string(chiefId), "segments": .array(rows), "device": "mac",
        ])
    }
}

extension LocalData {
    /// This run's sources: this Mac's; in screenshot runs (`-ShionSnapshot YES`) made-up ones that
    /// never ask for a permission, read real data or send anything. `-ShionLocalScript YES` makes
    /// them follow the clock and report to the server, for LocalDataTests; `-ShionCalendarAccess
    /// none` shows calendars Shion may not read yet.
    static func forLaunch() -> LocalData {
        let defaults = UserDefaults.standard
        guard LaunchOptions.current.snapshot else {
            return LocalData(mode: .real, calendars: EventKitCalendars(), front: WorkspaceFront(), judge: SystemModelJudge(),
                             settings: savedSettings(defaults), files: LocalFiles.standard, defaults: defaults)
        }
        let access: CalendarAccess = defaults.string(forKey: "ShionCalendarAccess") == "none" ? .notDetermined : .granted
        if defaults.bool(forKey: "ShionLocalScript") {
            let now = Date()
            return LocalData(
                mode: .script,
                calendars: FixtureCalendars(access: access, calendars: LocalFixtures.calendars, items: LocalFixtures.scriptItems(around: now)),
                front: ScriptedFront(LocalFixtures.scriptWindows()), judge: FixtureJudge(), settings: LocalFixtures.settings,
                engine: LocalFixtures.scriptTimeline(around: now), usage: LocalFixtures.scriptUsage(around: now)
            )
        }
        let demo = Clock.demoNow
        return LocalData(
            mode: .snapshot,
            calendars: FixtureCalendars(access: access, calendars: LocalFixtures.calendars, items: LocalFixtures.demoItems(around: demo)),
            front: ScriptedFront([]), judge: FixtureJudge(), settings: LocalFixtures.settings,
            engine: LocalFixtures.demoTimeline(around: demo), usage: LocalFixtures.demoUsage(around: demo), pinned: demo
        )
    }
}

extension CalEvent {
    /// Its calendar's color; the area's for the demo's events.
    var color: Color { tint ?? area.color }
}
