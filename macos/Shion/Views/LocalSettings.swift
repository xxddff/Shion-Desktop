import SwiftUI

// Settings → 这台 Mac: its calendars, the focus check and the app usage record. What each sends
// and what it does not is said here, under its switch, and nowhere else.

/// The 这台 Mac tab.
struct LocalSettingsView: View {
    var body: some View {
        Form {
            CalendarSettings()
            FocusSettings()
            UsageSettings()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }
}

/// The calendars on this Mac, by account: which ones Shion reads, and what each holds.
struct CalendarSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let local = store.local
        Section {
            if local.access == .granted {
                ForEach(accounts, id: \.self) { account in
                    Text(account.isEmpty ? "其他" : account)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                    ForEach(local.calendars.filter { $0.account == account }) { calendar in
                        CalendarRow(calendar: calendar)
                    }
                }
            } else {
                LabeledContent("这台 Mac 的日历") {
                    Button(local.access == .denied ? "到系统设置里允许…" : "允许读取日历…") {
                        Task { await local.requestCalendarAccess() }
                    }
                    .accessibilityIdentifier("calendar-access")
                }
            }
        } header: {
            Text("日历")
        } footer: {
            Text("读的是这台 Mac 上「日历」App 里的日历（iCloud、Google 等账户都在那里），只读勾上的那些，用在今天、日程和菜单栏的「下一件」，连没连服务器都一样，日程不经过服务器。算作「课」和「专注时段」的日历里，此刻正在进行的那一项就是专注检查的计划。没允许读取时，这些地方是示例数据。")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
    }

    /// Accounts in the order their first calendar comes.
    private var accounts: [String] {
        var seen: [String] = []
        for calendar in store.local.calendars where !seen.contains(calendar.account) {
            seen.append(calendar.account)
        }
        return seen
    }
}

/// One calendar: its color and name, ticked or not, and what it holds.
struct CalendarRow: View {
    @Environment(AppStore.self) private var store
    let calendar: CalendarInfo

    var body: some View {
        let local = store.local
        let ticked = local.isTicked(calendar.id)
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { ticked }, set: { local.setTicked(calendar.id, $0) })) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(AppStore.tint(calendar.color))
                        .frame(width: 9, height: 9)
                    Text(calendar.title)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("calendar-\(calendar.id)")
            Spacer(minLength: 8)
            Picker("算作", selection: Binding(get: { local.role(of: calendar.id) }, set: { local.setRole($0, of: calendar.id) })) {
                ForEach(CalendarRole.allCases, id: \.self) { role in
                    Text(role.label).tag(role)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!ticked)
        }
    }
}

/// The focus check: on or off, what it needs, who hears it, and what was said last.
struct FocusSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let local = store.local
        Section {
            Toggle(isOn: Binding(get: { local.settings.focusCheck }, set: { local.setFocusCheck($0) })) {
                Text("专注检查")
                Text("发给\(store.chiefName)：此刻的计划、偏离了几分钟、在做哪类事。不发：窗口标题、应用名、本机的窗口记录。")
            }
            .accessibilityIdentifier("focus-check")
            LabeledContent("读窗口标题（辅助功能）") {
                if local.titlesAllowed {
                    Text("已允许").foregroundStyle(.secondary)
                } else {
                    Button("去允许…") { local.askForTitles() }
                }
            }
            LabeledContent("本机模型") {
                Text(model).foregroundStyle(.secondary)
            }
            if store.live, let chief = Self.chief(local.chiefSync) {
                LabeledContent("插件叫醒") {
                    Text(chief.text)
                        .foregroundStyle(chief.problem ? Palette.alert : Color.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("focus-chief")
                }
            }
            if let sent = local.lastSent {
                LabeledContent("最近告诉\(Self.recipient(sent) ?? store.chiefName)") {
                    Text(Self.describe(sent))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("focus-last-sent")
                }
            }
            LabeledContent("这台 Mac 上的窗口记录") {
                Button("清空") { local.clearFocusLog() }
                    .disabled(local.engine.samples.isEmpty)
                    .accessibilityIdentifier("focus-clear")
            }
        } header: {
            Text("专注检查")
        } footer: {
            Text("到了计划的时间，看这台 Mac 前台的窗口和计划对不对得上。计划是勾上的日历里算作「课」或「专注时段」、此刻正在进行的那一项；没有的话，是服务器上今天执行时间已到、还没做完的待办。窗口标题用辅助功能读（第一次打开时系统会问；每装一个新版本，要在「隐私与安全性 → 辅助功能」里重新打开），由这台 Mac 上的 Apple 智能判断，同一个标题只判断一次。偏离满 5 分钟告诉总秘书一次，回到计划上再告诉一次；锁屏、睡眠或键鼠 5 分钟没动算不在 Mac 前，不算偏离。插件只叫醒它设置里的总秘书（chief_profile）：在「助手」里选了总秘书，Shion 选的时候和每次连上服务器时把这一项改成同一个，那个助手的 profile 要装着 shion 插件，也要在它的 config.yaml 里打开 allow_gateway_injection，允许插件叫醒它（插件说明里安装的第 3 步）。窗口标题和这段记录只存在这台 Mac 上，保留 7 天。菜单栏里可以暂停 1 小时。")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
    }

    private var model: String {
        switch store.local.judgeStatus {
        case .ready: return "可以用"
        case .unavailable(let why): return why
        }
    }

    /// Who the plugin wakes, when a choice made on this Mac is in play; nil otherwise.
    static func chief(_ sync: ChiefSync) -> (text: String, problem: Bool)? {
        switch sync {
        case .idle: return nil
        case .synced(let chief): return (chief.name, false)
        case .noPlugin(let chief): return ("叫不醒\(chief.name)：那个 profile 里没有 shion 插件", true)
        case .failed(let chief, let why): return ("还没改成\(chief.name)（\(why)），下次连上再试", true)
        }
    }

    /// 总秘书 as it was when the report went out.
    static func recipient(_ sent: SentFocus) -> String? {
        sent.outcome.chief.isEmpty ? nil : sent.outcome.chief
    }

    static func describe(_ sent: SentFocus) -> String {
        let report = sent.report
        let name = recipient(sent) ?? "总秘书"
        let what = report.onTrack
            ? "回到「\(report.plan)」上了"
            : "「\(report.plan)」偏离 \(report.offMinutes) 分钟，在做\(report.activity.label)"
        let heard: String
        switch sent.outcome.reason {
        case .none: heard = sent.outcome.woke ? "" : "（没叫醒\(name)）"
        case .some("no_session_key"): heard = "（没叫醒：\(name)的 Bot Chat 还没回过话）"
        case .some("inject_refused"): heard = "（没叫醒：服务器没让插件进\(name)的对话，要在那个 profile 里打开 allow_gateway_injection）"
        case .some("wrong_profile"): heard = "（没叫醒：插件设置里的总秘书不是\(name)）"
        case .some(let reason): heard = "（没叫醒\(name)：\(reason)）"
        }
        return "\(Fmt.hm(sent.at)) \(what)\(heard)"
    }
}

/// The app usage record: on or off, today's total, the last upload, the apps left out.
struct UsageSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let local = store.local
        Section {
            Toggle(isOn: Binding(get: { local.settings.usageLog }, set: { local.setUsageLog($0) })) {
                Text("记录应用使用情况")
                Text("发给「回顾」：哪个应用、从几点用到几点。不发：窗口标题、窗口里的内容。")
            }
            .accessibilityIdentifier("usage-log")
            LabeledContent("今天", value: Self.duration(local.usageToday))
            LabeledContent("上次发给回顾") {
                Text(sent)
                    .foregroundStyle(local.uploadFailed ? Palette.alert : Color.secondary)
                    .accessibilityIdentifier("usage-last-upload")
            }
            ForEach(local.settings.excluded) { app in
                LabeledContent {
                    Button("不再排除") { local.include(app.bundleId) }
                } label: {
                    HStack(spacing: 6) {
                        AppIcon(bundleId: app.bundleId)
                        Text(app.name)
                    }
                }
            }
            Menu("排除一个应用") {
                ForEach(local.recentApps()) { app in
                    Button(app.name) { local.exclude(app) }
                }
                Divider()
                Button("选择应用…") {
                    if let app = MacLocal.chooseApp() { local.exclude(app) }
                }
            }
            .fixedSize()
            .accessibilityIdentifier("usage-exclude")
        } header: {
            Text("应用使用记录")
        } footer: {
            Text("记下哪个应用在前台、从几点到几点（不用任何权限），连上装了 shion 插件的服务器时每 10 分钟发一次，「回顾」用它写日报里的屏幕时间。在一个应用里不到 5 秒的、锁屏和键鼠 5 分钟没动的时间不算。这台 Mac 上保留 7 天，服务器上默认保留 30 天。排除的应用不记录，这台 Mac 上已有的那部分也删掉；已经发出去的留在服务器上。")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
    }

    /// The last upload; while the window shows the last data (not connected), uploads wait.
    private var sent: String {
        let local = store.local
        if local.uploadFailed { return "没发出去，稍后再试" }
        guard let at = local.lastUpload else { return store.pluginData && !store.readOnly ? "还没发过" : "连上服务器后发" }
        return store.readOnly ? "\(Fmt.hm(at))，连上服务器后接着发" : Fmt.hm(at)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

/// An app's icon from this Mac, or a plain one in screenshot runs and for apps not installed.
struct AppIcon: View {
    let bundleId: String

    var body: some View {
        if !LaunchOptions.current.snapshot, let icon = MacLocal.icon(bundleId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }
}
