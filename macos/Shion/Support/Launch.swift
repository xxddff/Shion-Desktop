import SwiftUI

/// The pages of the main window, in sidebar order.
enum Route: Hashable {
    case today, confirm, todos, calendar, reports, board, desktop
    case chat(String)
    /// An assistant's own settings page.
    case botSettings(String)

    /// Parses the launch argument form used by the screenshot test: `today`, `chat-shion`,
    /// `assistant-shion`, ...
    init?(token: String) {
        switch token {
        case "today": self = .today
        case "confirm": self = .confirm
        case "todos": self = .todos
        case "calendar": self = .calendar
        case "reports": self = .reports
        case "board": self = .board
        case "desktop": self = .desktop
        default:
            if token.hasPrefix("assistant-") {
                self = .botSettings(String(token.dropFirst(10)))
                return
            }
            guard token.hasPrefix("chat-") else { return nil }
            self = .chat(String(token.dropFirst(5)))
        }
    }
}

/// Options the screenshot test passes on launch:
/// `-ShionSnapshot YES -ShionRoute today -ShionAppearance dark`, and `-ShionDemoSignIn YES` to
/// show Settings signed in to a made-up server.
struct LaunchOptions {
    var snapshot = false
    var route: Route = .today
    var colorScheme: ColorScheme?
    var demoSignIn = false

    static let current: LaunchOptions = {
        let defaults = UserDefaults.standard
        var options = LaunchOptions()
        options.snapshot = defaults.bool(forKey: "ShionSnapshot")
        options.demoSignIn = options.snapshot && defaults.bool(forKey: "ShionDemoSignIn")
        if let token = defaults.string(forKey: "ShionRoute"), let route = Route(token: token) {
            options.route = route
        }
        switch defaults.string(forKey: "ShionAppearance") {
        case "dark": options.colorScheme = ColorScheme.dark
        case "light": options.colorScheme = ColorScheme.light
        default: break
        }
        return options
    }()
}

enum Clock {
    /// The demo day: 10:52 on a weekday, just after the first class. Screenshots pin the date
    /// (Monday, 9 November 2026) so every run renders the same week.
    static let demoNow: Date = {
        let calendar = Calendar.current
        if LaunchOptions.current.snapshot {
            let parts = DateComponents(year: 2026, month: 11, day: 9, hour: 10, minute: 52)
            return calendar.date(from: parts) ?? Date()
        }
        return calendar.date(bySettingHour: 10, minute: 52, second: 0, of: Date()) ?? Date()
    }()
}
