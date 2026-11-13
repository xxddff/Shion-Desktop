import Foundation

/// A whole day, a date with no time of day, in the words it has outside the app: `2026-11-13`, as
/// the shion plugin writes a todo's day and takes one, and as the last data keeps one. The year,
/// month and day are the Gregorian calendar's, whichever calendar this Mac counts in: the plugin
/// reads them so, and the same day's year is 8 in the Japanese calendar, 115 in the Republic of
/// China's, 2569 in the Buddhist one. Inside the app a whole day is the moment it starts on this
/// Mac, so each conversion says in which time zone. What a row shows (今天, 11月13日) is not from
/// here: that follows the Mac's own calendar (Format.swift).
/// Foundation only, so it can be checked away from a Mac.
nonisolated enum WholeDay {
    /// The Gregorian calendar in `zone`.
    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Where the day `text` names starts in `zone`. Nil for what is not a day so written (a
    /// moment, with its time and offset, is longer).
    static func start(_ text: String, in zone: TimeZone) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3 else { return nil }
        return calendar(in: zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The day `date` is in, in `zone`.
    static func text(_ date: Date, in zone: TimeZone) -> String {
        let day = calendar(in: zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 1, day.day ?? 1)
    }

    // MARK: in the last data

    /// What the last data keeps beside a whole day's moment: the day itself, in words. The moment
    /// is only where the day started in the time zone the Mac was in then. Nil for a date with a
    /// time of day, which is the same moment everywhere.
    static func kept(_ date: Date?, allDay: Bool, in zone: TimeZone) -> String? {
        guard allDay, let date else { return nil }
        return text(date, in: zone)
    }

    /// A date read back from the last data, in the time zone the Mac is in now. A whole day is
    /// where its day starts here, wherever it was written: kept in Tokyo and read in Taipei, the
    /// 13th is still the 13th, not an hour before it. A date with a time is the moment it was; so
    /// is a whole day from a file written before days were kept (`day` nil), as it was read then.
    static func restored(_ date: Date?, day: String?, allDay: Bool, in zone: TimeZone) -> Date? {
        guard allDay, date != nil, let day, let start = start(day, in: zone) else { return date }
        return start
    }
}
