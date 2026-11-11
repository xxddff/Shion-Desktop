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


extension Fmt {
    static func day(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    static func isoDay(_ value: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }
}

extension Todo {
    var plannedDate: Date? { Fmt.day(doDay) ?? doAt }
    var deadlineDate: Date? { Fmt.day(dueDay) ?? dueAt }
    func overdue(at now: Date) -> Bool {
        if let day = Fmt.day(dueDay) { return Fmt.dayDiff(day, now) < 0 }
        return (dueAt ?? .distantFuture) < now
    }
    func planLabel(now: Date) -> String {
        if let day = Fmt.day(doDay) { return Fmt.dayLabel(day, now: now) }
        return doAt.map { Fmt.when($0, now: now) } ?? "未安排"
    }
    func deadlineLabel(now: Date) -> String {
        if let day = Fmt.day(dueDay) { return Fmt.dayLabel(day, now: now) + " 截止" }
        return dueAt.map { Fmt.when($0, now: now) } ?? "无截止日期"
    }
}
