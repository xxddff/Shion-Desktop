import Foundation

/// Dates the way the app says them: 10:52, 今天, 11月9日, 周一.
enum Fmt {
    static let calendar = Calendar.current

    private static let hmFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func hm(_ date: Date) -> String {
        hmFormatter.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    static func monthDay(_ date: Date) -> String {
        "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
    }

    /// Whole calendar days from `b` to `a`.
    static func dayDiff(_ a: Date, _ b: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: b), to: calendar.startOfDay(for: a)).day ?? 0
    }

    static func dayLabel(_ date: Date, now: Date) -> String {
        switch dayDiff(date, now) {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        default: return monthDay(date)
        }
    }

    /// "明天 20:00", or only the day when the time is the end of the day.
    static func when(_ date: Date, now: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        if hour == 23 && minute == 59 { return dayLabel(date, now: now) }
        return "\(dayLabel(date, now: now)) \(hm(date))"
    }
}

// MARK: - whole days

extension Fmt {
    /// A whole day as the plugin writes it (`2026-11-10`): where that day starts on this Mac.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The day `date` is in on this Mac, as the plugin takes a whole day.
    static func isoDay(_ date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 1, day.day ?? 1)
    }
}

extension Todo {
    /// When to do it, as a row says it: the time, with the day where the row is not under its day
    /// already. A whole day has no time: only its day, and nothing where the day is plain.
    func doLabel(now: Date, showDay: Bool) -> String? {
        guard let doAt else { return nil }
        if doAllDay {
            return showDay ? Fmt.dayLabel(doAt, now: now) : nil
        }
        return showDay ? Fmt.when(doAt, now: now) : Fmt.hm(doAt)
    }

    /// The moment from which it is overdue: a deadline that is a whole day ends with that day.
    var deadline: Date? {
        guard let dueAt else { return nil }
        return dueAllDay ? Fmt.calendar.date(byAdding: .day, value: 1, to: dueAt) : dueAt
    }

    func overdue(at now: Date) -> Bool {
        deadline.map { $0 < now } ?? false
    }

    /// When it is due, in words: 「20:00 截止」, 「明天截止」.
    func dueWords(now: Date) -> String? {
        guard let dueAt else { return nil }
        if dueAllDay || Fmt.dayDiff(dueAt, now) != 0 {
            return "\(Fmt.dayLabel(dueAt, now: now))截止"
        }
        return "\(Fmt.hm(dueAt)) \(dueAt < now ? "已截止" : "截止")"
    }
}
