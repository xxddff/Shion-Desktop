import KeyboardShortcuts
import SwiftUI

/// The status item: 詩音's mark in outline (a template image, like other menu bar icons) and the
/// next thing on the calendar.
struct MenuBarLabel: View {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image)
            if let next = store.nextEvent {
                Text("\(Fmt.hm(next.start)) \(next.title.replacing(#/ 第\d+回/#, with: ""))")
            }
        }
        // the label lives as long as the app: it keeps the Dock badge (asks waiting on you) and
        // lets a clicked notification reopen a closed main window
        .onChange(of: store.confirmCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onAppear {
            Notifier.shared.openMainWindow = { openWindow(id: "main") }
        }
    }
}

enum MenuBarIcon {
    /// A template image, so the menu bar tints it.
    static let image: NSImage = render()

    /// Rendered from a view of this module: an opaque `some View` built inline here made the
    /// compiler warn that its conformance might be isolated elsewhere (#IsolatedConformances).
    private static func render() -> NSImage {
        let renderer = ImageRenderer(content: MenuBarMark())
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }
}

/// 「詩」 in a ring.
private struct MenuBarMark: View {
    var body: some View {
        Text("詩")
            .font(.system(size: 9.5, weight: .bold))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(lineWidth: 1.2))
    }
}

/// The menu bar panel: the focus check first (it is about right now), then what is next, the ride
/// home, today's most pressing todos, what waits on you, and the way to talk to 詩音.
struct MenuBarPanel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let ride = store.events(on: store.now).first { $0.kind == .commute && $0.start > store.now }
        VStack(alignment: .leading, spacing: 0) {
            focusRow
            Divider().padding(.vertical, 6)

            if let next = store.nextEvent {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下一件 · \(untilText(next.start))").font(.t12).foregroundStyle(.secondary)
                    Text(next.title).font(.t15)
                    Text("\(Fmt.hm(next.start))–\(Fmt.hm(next.end)) · \(next.place ?? "")")
                        .font(.t12)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                Divider().padding(.vertical, 6)
            }

            if let ride {
                PanelRow(systemImage: "tram", text: "回程 \(Fmt.hm(ride.start)) · \(ride.place ?? "")") {
                    Text("正常").font(.t12).foregroundStyle(Color.green)
                }
                Divider().padding(.vertical, 6)
            }

            VStack(spacing: 0) {
                ForEach(Array(store.todayTodos.prefix(3))) { todo in
                    TodoRow(todo: todo)
                }
            }
            .padding(.horizontal, 10)
            Divider().padding(.vertical, 6)

            if store.confirmCount > 0 {
                Button {
                    store.route = .confirm
                    NSApp.activate()
                } label: {
                    PanelRow(systemImage: "hand.raised", text: "\(store.confirmCount) 件事等你确认") {
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            // the same window as the global shortcut (QuickAsk.swift), whose keys it shows
            Button {
                QuickAsk.shared.show()
            } label: {
                HStack(spacing: 8) {
                    Mark(size: 18)
                    Text("跟詩音说…").foregroundStyle(.secondary)
                    Spacer()
                    if let shortcut = QuickAsk.shared.shortcut {
                        Text(shortcut.description)
                            .font(.t11)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(8)
        .frame(width: 330)
    }

    /// Two lines: the plan, then how it is going, so neither gets cut off.
    private var focusRow: some View {
        let focus = store.focus
        let minutes = max(0, Int(store.now.timeIntervalSince(focus.plannedAt) / 60))
        let plan: String = focus.onTrack ? "在做「\(focus.planTitle)」" : "「\(focus.planTitle)」原定 \(Fmt.hm(focus.plannedAt))"
        let state: String = focus.onTrack ? "对得上" : "\(minutes) 分钟没在做"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan).font(.t13)
                Text(state)
                    .font(.t12)
                    .foregroundStyle(focus.onTrack ? Color.green : Palette.warm)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func untilText(_ date: Date) -> String {
        let minutes = Int(date.timeIntervalSince(store.now) / 60)
        return minutes < 60 ? "还有 \(minutes) 分钟" : "还有 \(minutes / 60) 小时"
    }
}

struct PanelRow<Trailing: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text).font(.t13).lineLimit(1)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
