import AppKit
import Foundation
import Observation
import UserNotifications

/// Settings' 服务器体检: each part of the way to the server and to you, what it says, and what to
/// do when it is not right. Runs when the page opens and on 重新检查; it only reads, nothing on the
/// server changes.
@Observable
final class ServerCheck {
    enum Level {
        case checking, ok, warn, fail, skipped
    }

    struct Line: Identifiable, Hashable {
        let id: String
        let title: String
        let level: Level
        let text: String
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        var level = Level.checking
        var status = "检查中…"
        /// How to put it right, when it is not.
        var fix: String?
        var lines: [Line] = []
    }

    private(set) var items = ServerCheck.fresh
    private(set) var running = false

    /// The line over the checks: how many need putting right, once they are done.
    var summary: String {
        if running || items.contains(where: { $0.level == .checking }) { return "检查中…" }
        let fails = items.filter { $0.level == .fail }.count
        let warns = items.filter { $0.level == .warn }.count
        switch (fails, warns) {
        case (0, 0): return "都正常"
        case (_, 0): return "\(fails) 项要处理"
        case (0, _): return "\(warns) 项要留意"
        default: return "\(fails) 项要处理 · \(warns) 项要留意"
        }
    }

    static let titles: [(id: String, title: String)] = [
        ("access", "Cloudflare Access"), ("login", "登录凭证"), ("protocol", "Canonical 协议"),
        ("capabilities", "服务器能力"), ("plugin", "shion 插件"), ("timezone", "时区数据"), ("kanban", "看板插件"),
        ("limits", "看板上限"), ("notifications", "系统通知"),
    ]

    static var fresh: [Item] { titles.map { Item(id: $0.id, title: $0.title) } }

    /// The capabilities in `runtime.describe` Shion relies on, and what for.
    static let used: [(name: String, use: String)] = [
        ("session-transcript-v1", "对话一页一页地取；没打开的对话也收得到批准和提问"),
        ("plugin-rpc-v1", "shion 插件：今天、待办、日报"),
        ("session-client-v1", "新建的 Bot Chat 记着是 Shion 建的"),
    ]

    func run(_ store: AppStore) async {
        guard !running else { return }
        running = true
        defer { running = false }
        items = Self.fresh
        // screenshot runs signed in to a made-up server: nothing is dialled
        if LaunchOptions.current.demoSignIn {
            items = Self.demo
            return
        }
        let settings = store.serverSettings.trimmed
        let status = await checkAccess(settings)
        await checkLogin(settings, status: status, store: store)
        let capabilities = await checkProtocol(store)
        await checkPlugin(store, capabilities: capabilities)
        await checkKanban(settings, reachable: status != nil, store: store)
        checkLimits(store)
        await checkNotifications()
    }

    private func set(_ id: String, _ level: Level, _ status: String, fix: String? = nil, lines: [Line] = []) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].level = level
        items[index].status = status
        items[index].fix = fix
        items[index].lines = lines
    }

    // MARK: the checks

    /// `GET /api/status` with the service token: Hermes answers it without a login, so a refusal
    /// is Cloudflare Access's.
    private func checkAccess(_ settings: ServerSettings) async -> ServerStatus? {
        guard settings.isConfigured else {
            set("access", .fail, "还没填服务器地址", fix: "在「服务器」里填 Webapp 的地址，比如 https://hermes.example.dev。")
            return nil
        }
        do {
            guard let status = try await settings.status() else {
                set("access", .fail, "这个地址的 /api/status 不是 Hermes 的回复",
                    fix: "要填 hermes gateway 的 Webapp 地址。")
                return nil
            }
            set("access", .ok, settings.accessHeaders.isEmpty ? "放行了（没填 service token）" : "service token 放行了")
            return status
        } catch GatewayError.accessDenied {
            set("access", .fail, "没有放行",
                fix: "检查「服务器」里的 Access Client ID 和 Secret：要和 Cloudflare Zero Trust 里这个 service token 的一样，而且没过期。这个 Hermes 应用的 Access 策略里要有一条 Service Auth，Include 选这个 service token。")
            return nil
        } catch {
            set("access", .fail, "连不上：\(error.localizedDescription)",
                fix: "检查地址和网络；服务器上的 Cloudflare Tunnel（cloudflared）和 hermes gateway 都要在跑。")
            return nil
        }
    }

    /// The sign-in or the session token, by `GET /api/auth/me`: who it is and when it lapses.
    private func checkLogin(_ settings: ServerSettings, status: ServerStatus?, store: AppStore) async {
        guard let status else { return set("login", .skipped, "先要过得了 Access") }
        guard status.authRequired else {
            return set("login", .ok, "这个服务器不要登录（auth_required 是 false）")
        }
        switch settings.login {
        case .browser:
            guard store.account.tokens(for: settings) != nil else {
                return set("login", .fail, "还没登录", fix: "在「服务器」里点「用浏览器登录…」。")
            }
        case .sessionToken:
            guard !settings.token.isEmpty else {
                return set("login", .fail, "没填会话令牌",
                           fix: "在「服务器」里填服务器上的 HERMES_DASHBOARD_SESSION_TOKEN，或者改用浏览器登录。")
            }
            guard status.providers.contains("session-token") else {
                return set("login", .fail, "服务器没开会话令牌登录",
                           fix: GatewayError.tokenLoginOff(status.providers).localizedDescription)
            }
        }
        guard let url = settings.httpURL("/api/auth/me"), let sign = store.gateway.credential else {
            return set("login", .skipped, "这个地址拼不出 /api/auth/me")
        }
        do {
            let credential = try await sign(settings, false)
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            settings.applyAccessHeaders(to: &request)
            credential.sign(&request)
            let (data, response) = try await URLSession.shared.data(for: request)
            try ServerSettings.checkAccess(response)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let me = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
                guard code == 401 else { return set("login", .fail, "服务器返回 HTTP \(code)") }
                switch settings.login {
                case .browser:
                    return set("login", .fail, "服务器不认这个登录", fix: "在「服务器」里退出登录，再登录一次。")
                case .sessionToken:
                    return set("login", .fail, "会话令牌对不上", fix: GatewayError.badToken(settings.tokenHint).localizedDescription)
                }
            }
            var parts = ["有效"]
            if let name = me["user_id"]?.string, !name.isEmpty {
                parts.append(name)
            }
            let expires = me["expires_at"]?.number ?? 0
            if expires > 0 {
                parts.append(Self.lapse(Date(timeIntervalSince1970: expires)))
            } else if settings.login == .sessionToken {
                parts.append("会话令牌不过期")
            }
            set("login", .ok, parts.joined(separator: " · "))
        } catch {
            let fix = settings.login == .browser ? "在「服务器」里退出登录，再登录一次。" : nil
            set("login", .fail, error.localizedDescription, fix: fix)
        }
    }

    /// When a sign-in lapses; Shion renews it before then, each time it connects.
    static func lapse(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return "已经到期，连接时会自己续" }
        if minutes < 60 { return "\(minutes) 分钟后到期，到时自己续" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) 小时 \(minutes % 60) 分后到期，到时自己续" }
        return "\(hours / 24) 天后到期"
    }

    /// The socket: whether `hermes gateway` serves it (the canonical wire), and what
    /// `runtime.describe` says the server can do.
    private func checkProtocol(_ store: AppStore) async -> Set<String>? {
        let gateway = store.gateway
        guard gateway.phase == .online else {
            let reason: String
            if case .failed(let why) = gateway.phase {
                reason = why
            } else {
                reason = gateway.phase == .connecting ? "正在连" : "没连上"
            }
            set("protocol", .skipped, reason, fix: "在「服务器」里连上服务器，再检查一次。")
            set("capabilities", .skipped, "连上后检查")
            return nil
        }
        if gateway.sessionAuthority {
            set("protocol", .ok, "hermes gateway")
        } else {
            set("protocol", .fail, "服务器说的是旧协议",
                fix: "Shion 要连 hermes gateway 的 /api/ws：单独跑的 hermes serve 和 hermes dashboard 说的是旧协议。在服务器上用 hermes gateway 跑，Webapp 的 public_url 填对外的地址。")
        }
        guard let reply = try? await gateway.call("runtime.describe", [:]) else {
            set("capabilities", .fail, "runtime.describe 没有回复",
                fix: "服务器上的 Hermes 太旧，或者这不是 hermes gateway：升级（hermes update），再重启 gateway。")
            return nil
        }
        let capabilities = Set((reply["capabilities"]?.array ?? []).compactMap { $0.string })
        var lines = Self.used.map { used in
            Line(id: used.name, title: used.name, level: capabilities.contains(used.name) ? .ok : .warn, text: used.use)
        }
        let others = capabilities.subtracting(Self.used.map { $0.name }).sorted()
        if !others.isEmpty {
            lines.append(Line(id: "others", title: "其余", level: .ok, text: others.joined(separator: "、")))
        }
        let missing = Self.used.map { $0.name }.filter { !capabilities.contains($0) }
        if missing.isEmpty {
            set("capabilities", .ok, "Shion 用到的都有", lines: lines)
        } else {
            set("capabilities", .warn, "缺 \(missing.joined(separator: "、"))",
                fix: "升级服务器上的 Hermes（hermes update），再重启 gateway。缺的那几项，Shion 里对应的功能用不了。",
                lines: lines)
        }
        return capabilities
    }

    /// `plugin.shion.info` in every assistant's profile: the plugin is installed and enabled per
    /// profile, and -32601 means it is not loaded there.
    private func checkPlugin(_ store: AppStore, capabilities: Set<String>?) async {
        guard let capabilities else {
            set("timezone", .skipped, "连上后检查")
            return set("plugin", .skipped, "连上后检查")
        }
        guard capabilities.contains("plugin-rpc-v1") else {
            set("timezone", .skipped, "要先有 shion 插件")
            return set("plugin", .fail, "服务器不支持插件 RPC（没有 plugin-rpc-v1）",
                       fix: "升级服务器上的 Hermes（hermes update），再重启 gateway。")
        }
        guard store.live else {
            set("timezone", .skipped, "要先有 shion 插件")
            return set("plugin", .skipped, "还没从服务器读到助手")
        }
        var lines: [Line] = []
        var missing: [String] = []
        var first: JSONValue?
        for bot in store.bots {
            do {
                let info = try await store.gateway.call("plugin.shion.info", ["profile": .string(bot.id)])
                let version = info["plugin_version"]?.string ?? "?"
                let today = info["today"]?.string ?? ""
                lines.append(Line(id: bot.id, title: bot.name, level: .ok, text: "\(version) · 今天是 \(today)"))
                first = first ?? info
            } catch GatewayError.rpc(let code, _, let reason) where code == -32601 || reason == "unknown_method" {
                missing.append(bot.id)
                lines.append(Line(id: bot.id, title: bot.name, level: .fail, text: "没装或没启用"))
            } catch {
                missing.append(bot.id)
                lines.append(Line(id: bot.id, title: bot.name, level: .fail, text: error.localizedDescription))
            }
        }
        checkTimezone(first)
        if missing.isEmpty {
            set("plugin", .ok, "\(lines.count) 个助手都装了", lines: lines)
        } else {
            set("plugin", .fail, "\(missing.count) 个助手没有",
                fix: "在服务器上给这几个 profile 装上并启用，再重启 gateway：for p in \(missing.joined(separator: " ")); do hermes -p $p plugins install xxddff/Shion-Desktop/hermes-plugin/shion --enable; done; hermes gateway restart（详见 hermes-plugin/README.md）。",
                lines: lines)
        }
    }

    /// The plugin's `tz_database`: whether the server has the IANA time zone database. Hermes's
    /// image (Debian 13, packages without recommends) may not bring tzdata; without it the plugin
    /// still gets the zones that keep one offset all year right, and refuses the others.
    private func checkTimezone(_ info: JSONValue?) {
        guard let info else { return set("timezone", .skipped, "要先有 shion 插件") }
        let zone = info["timezone"]?.string ?? ""
        switch info["tz_database"]?.bool {
        case true?:
            set("timezone", .ok, zone.isEmpty ? "有" : "有 · 插件用 \(zone)")
        case false?:
            let note = Self.fixedZones.contains(zone)
                ? "插件现在用的 \(zone) 一年到头时差不变，不受影响；换成有夏令时的时区会被拒。"
                : "插件现在用的 \(zone) 有夏令时，算不对日期，会被拒。"
            set("timezone", Self.fixedZones.contains(zone) ? .warn : .fail, "服务器缺时区数据",
                fix: note + "修法：在容器里装 tzdata（apt-get install tzdata；重建镜像会丢，要写进自己的 Dockerfile），或者用没有夏令时的时区（Asia/Tokyo、Asia/Shanghai、UTC 等）。")
        case nil:
            set("timezone", .skipped, "插件没报（旧版本）",
                fix: "更新 shion 插件（hermes -p <profile> plugins update shion），再重启 gateway。")
        }
    }

    /// The zones the plugin gets right without the database (hermes-plugin/shion/timeutil.py).
    static let fixedZones: Set<String> = ["Asia/Tokyo", "Asia/Seoul", "Asia/Shanghai", "Asia/Hong_Kong",
                                          "Asia/Taipei", "Asia/Singapore", "UTC", "Etc/UTC"]

    /// `GET /api/plugins/kanban/boards`: the board plugin answers there, with the server's boards.
    private func checkKanban(_ settings: ServerSettings, reachable: Bool, store: AppStore) async {
        guard reachable, let sign = store.gateway.credential else { return set("kanban", .skipped, "先要过得了 Access") }
        do {
            let listing = try await KanbanClient(settings: settings, credential: sign).get("/boards")
            set("kanban", .ok, "在 · \(listing["boards"]?.array.count ?? 0) 块看板")
        } catch let error as KanbanError where error.status == 404 {
            set("kanban", .fail, "没有看板插件（/api/plugins/kanban 是 404）",
                fix: "看板是 Hermes 自带的插件（plugins/kanban）。在服务器上看 hermes plugins list 里它开着没有，config.yaml 的 dashboard.hidden_plugins 里有没有它；改完重启 gateway。")
        } catch {
            set("kanban", .fail, error.localizedDescription)
        }
    }

    /// The server's limits on cards running at once, as Settings shows them.
    private func checkLimits(_ store: AppStore) {
        guard store.live else { return set("limits", .skipped, "连上后检查") }
        guard let limits = store.boardLimits else {
            return set("limits", .fail, "读不到服务器的 /api/config",
                       fix: "重新连接一次；还不行的话，服务器上的 Hermes 可能太旧，升级（hermes update）后重启 gateway。")
        }
        let text = "整台服务器 \(SettingsView.count(limits.effectiveMax, derived: limits.derivedFromMemory)) · 每个助手 \(SettingsView.count(limits.perAssistant, derived: false))"
        if limits.perAssistant == nil {
            set("limits", .warn, text,
                fix: "每个助手只有一块云桌面和一套浏览器登录，同一个助手的两张卡同时跑会抢屏幕。在 config.yaml 里设 kanban.max_in_progress_per_profile: 1，重启 gateway。")
        } else if limits.effectiveMax == nil {
            set("limits", .warn, text,
                fix: "整台服务器不限，卡多时会同时开很多个助手。在 config.yaml 里设 kanban.max_in_progress（比如 4），重启 gateway。")
        } else {
            set("limits", .ok, text)
        }
    }

    /// Whether Shion may notify you: approvals, questions and replies reach you that way while
    /// Shion is not in front. Only read here, never asked.
    private func checkNotifications() async {
        let (status, alerts) = await Self.notificationState()
        switch status {
        case .authorized, .provisional:
            if alerts == .disabled {
                set("notifications", .warn, "允许了，但不显示横幅", fix: Self.notificationFix)
            } else {
                set("notifications", .ok, "允许")
            }
        case .denied:
            set("notifications", .fail, "关着", fix: Self.notificationFix)
        case .notDetermined:
            set("notifications", .warn, "还没问过",
                fix: "Shion 正常打开时会问一次；也可以到「系统设置 → 通知」里找到 Shion 打开。")
        @unknown default:
            set("notifications", .warn, "不知道")
        }
    }

    static let notificationFix = "到「系统设置 → 通知 → Shion」打开「允许通知」，样式选「横幅」或「提醒」。批准、提问和回复，Shion 不在前面时靠它找到你。"

    nonisolated private static func notificationState() async -> (UNAuthorizationStatus, UNNotificationSetting) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return (settings.authorizationStatus, settings.alertSetting)
    }

    /// System Settings at Notifications.
    static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        _ = NSWorkspace.shared.open(url)
    }

    // MARK: the screenshot run's

    static var demo: [Item] {
        var items = fresh
        func set(_ id: String, _ level: Level, _ status: String, fix: String? = nil, lines: [Line] = []) {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].level = level
            items[index].status = status
            items[index].fix = fix
            items[index].lines = lines
        }
        set("access", .ok, "service token 放行了")
        set("login", .ok, "有效 · kaede · 11 小时 48 分后到期，到时自己续")
        set("protocol", .ok, "hermes gateway")
        set("capabilities", .ok, "Shion 用到的都有", lines: used.map { Line(id: $0.name, title: $0.name, level: .ok, text: $0.use) })
        set("plugin", .fail, "1 个助手没有",
            fix: "在服务器上给这几个 profile 装上并启用，再重启 gateway：for p in commute; do hermes -p $p plugins install xxddff/Shion-Desktop/hermes-plugin/shion --enable; done; hermes gateway restart（详见 hermes-plugin/README.md）。",
            lines: [
                Line(id: "shion", title: "詩音", level: .ok, text: "0.3.0 · 今天是 2026-11-09"),
                Line(id: "study", title: "课程", level: .ok, text: "0.3.0 · 今天是 2026-11-09"),
                Line(id: "commute", title: "通勤", level: .fail, text: "没装或没启用"),
            ])
        set("timezone", .ok, "有 · 插件用 Asia/Tokyo")
        set("kanban", .ok, "在 · 2 块看板")
        set("limits", .warn, "整台服务器 4 件（按内存推算） · 每个助手 不限",
            fix: "每个助手只有一块云桌面和一套浏览器登录，同一个助手的两张卡同时跑会抢屏幕。在 config.yaml 里设 kanban.max_in_progress_per_profile: 1，重启 gateway。")
        set("notifications", .ok, "允许")
        return items
    }
}
