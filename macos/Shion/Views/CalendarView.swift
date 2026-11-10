import SwiftUI

/// The week, Monday to Sunday, on an hour grid: this Mac's ticked calendars, or the demo's week
/// until Shion may read them. All-day events sit in a row above the grid; events at the same
/// time share their day's width.
struct CalendarView: View {
    @Environment(AppStore.self) private var store
    private let hourHeight: CGFloat = 46
    private let gutter: CGFloat = 52

    /// One day of the week and its events.
    struct Day: Identifiable {
        let day: Date
        let events: [CalEvent]

        var id: Date { day }
    }

    var body: some View {
        let days = weekDays
        let week = days.map { Day(day: $0, events: store.events(on: $0)) }
        let hours = hourRange(week)
        let allDay = week.map { $0.events.filter(\.allDay) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter, height: 1)
                ForEach(days, id: \.self) { day in
                    let isToday = Fmt.dayDiff(day, store.now) == 0
                    VStack(spacing: 2) {
                        Text(Fmt.weekday(day)).font(.t12).foregroundStyle(.secondary)
                        Text("\(Fmt.calendar.component(.day, from: day))")
                            .font(.t20)
                            .monospacedDigit()
                            .foregroundStyle(isToday ? Palette.alert : Color.primary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 10)
            if allDay.contains(where: { !$0.isEmpty }) {
                allDayRow(allDay)
            }
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(hours, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .font(.t11)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 8)
                                .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                        }
                    }
                    ForEach(week) { entry in
                        dayColumn(entry.day, events: entry.events.filter { !$0.allDay }, hours: hours)
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 12)
            }
            .defaultScrollAnchor(.top)
        }
        .navigationTitle("日程")
        .navigationSubtitle("\(Fmt.monthDay(days.first ?? store.now)) – \(Fmt.monthDay(days.last ?? store.now))")
        .toolbar {
            // the demo's week until Shion may read this Mac's calendars: the way to let it
            if store.local.access != .granted {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task { await store.local.requestCalendarAccess() }
                    } label: {
                        Label("读取这台 Mac 的日历", systemImage: "calendar.badge.plus")
                    }
                    .help("读取这台 Mac 的日历")
                    .accessibilityIdentifier("calendar-allow")
                }
            }
        }
    }

    private var weekDays: [Date] {
        let calendar = Fmt.calendar
        let today = calendar.startOfDay(for: store.now)
        let weekday = calendar.component(.weekday, from: today)  // 1 is Sunday
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    /// 8:00 to 22:00, wider when the week has events earlier or later (each day's part of them).
    private func hourRange(_ week: [Day]) -> [Int] {
        var first = 8
        var last = 22
        for entry in week {
            let dayStart = Fmt.calendar.startOfDay(for: entry.day)
            for event in entry.events where !event.allDay {
                let start = max(0, event.start.timeIntervalSince(dayStart) / 3600)
                let end = min(24, max(start + 0.5, event.end.timeIntervalSince(dayStart) / 3600))
                first = min(first, Int(start.rounded(.down)))
                last = max(last, Int(end.rounded(.up)))
            }
        }
        return Array(max(0, first)..<min(24, max(last, first + 1)))
    }

    private func allDayRow(_ days: [[CalEvent]]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天")
                .font(.t11)
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)
                .frame(width: gutter, alignment: .trailing)
            ForEach(Array(days.enumerated()), id: \.offset) { _, events in
                VStack(spacing: 2) {
                    ForEach(events) { event in
                        Text(event.title)
                            .font(.t11.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(event.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 6)
    }

    private func dayColumn(_ day: Date, events: [CalEvent], hours: [Int]) -> some View {
        let isToday = Fmt.dayDiff(day, store.now) == 0
        let dayStart = Fmt.calendar.startOfDay(for: day)
        let dayEnd = Fmt.calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let first = hours.first ?? 0
        let lanes = Self.lanes(events, dayStart: dayStart, dayEnd: dayEnd)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { _ in
                        VStack(spacing: 0) {
                            Palette.line.frame(height: 0.5)
                            Spacer(minLength: 0)
                        }
                        .frame(height: hourHeight)
                    }
                }
                ForEach(lanes, id: \.event.id) { placed in
                    let width = (proxy.size.width - 6) / CGFloat(placed.lanes)
                    EventBlock(event: placed.event, past: placed.event.end < store.now)
                        .frame(width: max(0, width - 2), height: max(22, height(from: placed.start, to: placed.end)))
                        .offset(x: 3 + width * CGFloat(placed.lane), y: offset(of: placed.start, from: first))
                }
                if isToday {
                    Palette.alert
                        .frame(height: 1.5)
                        .offset(y: offset(of: store.now, from: first))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CGFloat(hours.count) * hourHeight, alignment: .top)
        .background(isToday ? Palette.accent.opacity(0.04) : Color.clear)
        .overlay(alignment: .leading) {
            Palette.line.frame(width: 0.5)
        }
        .clipped()
    }

    private func offset(of date: Date, from firstHour: Int) -> CGFloat {
        let hour = Fmt.calendar.component(.hour, from: date)
        let minute = Fmt.calendar.component(.minute, from: date)
        return CGFloat((hour - firstHour) * 60 + minute) * hourHeight / 60
    }

    private func height(from start: Date, to end: Date) -> CGFloat {
        CGFloat(end.timeIntervalSince(start) / 60) * hourHeight / 60
    }

    /// An event as its day shows it: cut to the day, in a lane of the group it overlaps with.
    struct Placed {
        let event: CalEvent
        let start: Date
        let end: Date
        var lane = 0
        var lanes = 1
    }

    /// Side by side where events overlap: each takes the first free lane, and a group of
    /// overlapping events shares the day's width between its lanes.
    static func lanes(_ events: [CalEvent], dayStart: Date, dayEnd: Date) -> [Placed] {
        let placed = events
            .map { Placed(event: $0, start: max($0.start, dayStart), end: min(max($0.end, $0.start), dayEnd)) }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
        var out: [Placed] = []
        var group: [Placed] = []
        var groupEnd = Date.distantPast
        func flush() {
            let count = (group.map(\.lane).max() ?? 0) + 1
            out += group.map { item in
                var item = item
                item.lanes = count
                return item
            }
            group = []
        }
        for var item in placed {
            // a short event still takes the 22 points it is drawn with
            let drawnEnd = max(item.end, item.start.addingTimeInterval(30 * 60))
            if item.start >= groupEnd {
                flush()
                groupEnd = .distantPast
            }
            var laneEnds: [Int: Date] = [:]
            for other in group {
                laneEnds[other.lane] = max(laneEnds[other.lane] ?? .distantPast, max(other.end, other.start.addingTimeInterval(30 * 60)))
            }
            var lane = 0
            while let busy = laneEnds[lane], busy > item.start {
                lane += 1
            }
            item.lane = lane
            group.append(item)
            groupEnd = max(groupEnd, drawnEnd)
        }
        flush()
        return out
    }
}

struct EventBlock: View {
    let event: CalEvent
    let past: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title).font(.t12.weight(.medium)).lineLimit(2)
            if let place = event.place {
                Text(place).font(.t11).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(event.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            event.color
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .opacity(past ? 0.55 : 1)
    }
}
