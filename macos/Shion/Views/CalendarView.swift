import SwiftUI

/// The week, Monday to Sunday, on an hour grid.
struct CalendarView: View {
    @Environment(AppStore.self) private var store
    private let startHour = 8
    private let endHour = 22
    private let hourHeight: CGFloat = 46
    private let gutter: CGFloat = 52

    var body: some View {
        let days = weekDays
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
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(startHour..<endHour, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour))
                                .font(.t11)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 8)
                                .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                        }
                    }
                    ForEach(days, id: \.self) { day in
                        dayColumn(day)
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, 12)
            }
            .defaultScrollAnchor(.top)
        }
        .navigationTitle("日程")
        .navigationSubtitle("\(Fmt.monthDay(days.first ?? store.now)) – \(Fmt.monthDay(days.last ?? store.now))")
    }

    private var weekDays: [Date] {
        let calendar = Fmt.calendar
        let today = calendar.startOfDay(for: store.now)
        let weekday = calendar.component(.weekday, from: today)  // 1 is Sunday
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private func dayColumn(_ day: Date) -> some View {
        let events = store.events(on: day)
        let isToday = Fmt.dayDiff(day, store.now) == 0
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(startHour..<endHour, id: \.self) { _ in
                    VStack(spacing: 0) {
                        Palette.line.frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                    .frame(height: hourHeight)
                }
            }
            ForEach(events) { event in
                EventBlock(event: event, past: event.end < store.now)
                    .frame(height: max(22, height(of: event)))
                    .padding(.horizontal, 3)
                    .offset(y: offset(of: event.start))
            }
            if isToday {
                Palette.alert
                    .frame(height: 1.5)
                    .offset(y: offset(of: store.now))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CGFloat(endHour - startHour) * hourHeight, alignment: .top)
        .background(isToday ? Palette.accent.opacity(0.04) : Color.clear)
        .overlay(alignment: .leading) {
            Palette.line.frame(width: 0.5)
        }
    }

    private func offset(of date: Date) -> CGFloat {
        let hour = Fmt.calendar.component(.hour, from: date)
        let minute = Fmt.calendar.component(.minute, from: date)
        return CGFloat((hour - startHour) * 60 + minute) * hourHeight / 60
    }

    private func height(of event: CalEvent) -> CGFloat {
        CGFloat(event.end.timeIntervalSince(event.start) / 60) * hourHeight / 60
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
        .background(event.area.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            event.area.color
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .opacity(past ? 0.55 : 1)
    }
}
