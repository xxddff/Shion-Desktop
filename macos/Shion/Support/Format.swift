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
