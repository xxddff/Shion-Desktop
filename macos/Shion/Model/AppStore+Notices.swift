import AppKit

/// Daily reports as notifications: one the plugin brings that was not there when Shion connected
/// (回顾's in the evening, 资讯's in the morning) is posted, unless 日报 is in front of you. A
/// click opens that report (Landing.swift). Rewriting a report already seen is not news.
extension AppStore {
    func noticeReports(_ loaded: [Report]) {
        let seen = ReportsSeen.shared
        defer {
            seen.ids.formUnion(loaded.map(\.id))
            seen.started = true
        }
        // the first read after connecting: what is there already is not news
        guard seen.started else { return }
        for report in loaded where !seen.ids.contains(report.id) {
            guard !(NSApp.isActive && route == .reports) else { continue }
            Notifier.shared.report(report, from: bot(report.botId)?.name ?? "助手")
        }
    }

    /// Disconnected: the next connection's first read starts afresh.
    func forgetReports() {
        ReportsSeen.shared.ids = []
        ReportsSeen.shared.started = false
    }
}

/// The reports this connection has seen, by id.
final class ReportsSeen {
    static let shared = ReportsSeen()
    var ids: Set<String> = []
    var started = false
}
