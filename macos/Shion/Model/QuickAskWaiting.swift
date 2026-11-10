import Foundation

/// A sentence for 总秘书 from the ⌥Space window that has not gone out yet (no server was
/// connected), and how waiting sentences read once they do. Foundation only, so the wording can
/// be checked away from a Mac.
nonisolated struct QuickAskWaiting: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    /// When it was written.
    let at: Date

    /// Written longer ago than this, a sentence goes out with the time it was written:
    /// 「提醒我 5 分钟后出门」 two hours late is not what was meant.
    static let lateAfter: TimeInterval = 5 * 60

    /// The sentence as it goes out at `now`: as written, or, when late, after the time it was
    /// written (「（10:32 写的）…」).
    @MainActor
    func line(sentAt now: Date) -> String {
        guard now.timeIntervalSince(at) > Self.lateAfter else { return text }
        return "（\(Self.written(at, now: now)) 写的）\(text)"
    }

    /// The waiting sentences as the one message they go out in, a line each.
    @MainActor
    static func message(_ sentences: [QuickAskWaiting], sentAt now: Date) -> String {
        sentences.map { $0.line(sentAt: now) }.joined(separator: "\n")
    }

    /// When a sentence was written, as the window and the message say it: the time, after the
    /// day when that was not today (「昨天 23:50」, 「11月7日 09:05」).
    @MainActor
    static func written(_ at: Date, now: Date) -> String {
        Fmt.dayDiff(at, now) == 0 ? Fmt.hm(at) : "\(Fmt.dayLabel(at, now: now)) \(Fmt.hm(at))"
    }
}
