import SwiftUI

/// The focus check at the top of the menu bar panel, since it is about right now: the plan and
/// how it is going, in two lines so neither gets cut off. Click it for the last few windows and
/// the pause. Nothing shows while the check is turned off.
struct FocusPanelRow: View {
    @Environment(AppStore.self) private var store
    @State private var open = false

    var body: some View {
        let view = store.local.focusView(at: store.now)
        if view != .off {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    open.toggle()
                } label: {
                    summary(view)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("focus-row")
                if open {
                    detail(view)
                }
            }
            Divider().padding(.vertical, 6)
        }
    }

    private func summary(_ view: LocalData.FocusView) -> some View {
        let line = Self.lines(view, now: store.now)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.plan).font(.t13).lineLimit(1)
                if let state = line.state {
                    Text(state)
                        .font(.t12)
                        .foregroundStyle(line.tone)
                        .accessibilityIdentifier("focus-state")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.t11)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// The windows seen lately (on this Mac only) and what each was against the plan, then the pause.
    private func detail(_ view: LocalData.FocusView) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(recent) { row in
                HStack(spacing: 6) {
                    Text(Fmt.hm(row.at))
                        .font(.t11)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(row.window)
                        .font(.t12)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(row.fit)
                        .font(.t11)
                        .foregroundStyle(row.tone)
                }
            }
            HStack {
                Spacer()
                if case .paused = view {
                    Button("恢复") { store.local.resume() }
                        .controlSize(.small)
                        .accessibilityIdentifier("focus-resume")
                } else {
                    Button("暂停 1 小时") { store.local.pause(minutes: 60) }
                        .controlSize(.small)
                        .accessibilityIdentifier("focus-pause")
                }
            }
            .padding(.top, 2)
        }
        .padding(.leading, 34)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }

    private struct WindowRow: Identifiable {
        let id: UUID
        let at: Date
        let window: String
        let fit: String
        let tone: Color
    }

    /// The last four windows; a window still in front when a plan began counts once.
    private var recent: [WindowRow] {
        var rows: [(sample: FocusSample, judgement: Judgement?)] = []
        for sample in store.local.engine.samples.suffix(16) {
            if let last = rows.last, last.sample.front == sample.front {
                rows[rows.count - 1].judgement = sample.judgement ?? last.judgement
            } else {
                rows.append((sample, sample.judgement))
            }
        }
        return rows.suffix(4).map { row in
            let label = Self.fit(row.judgement, away: row.sample.away)
            return WindowRow(
                id: row.sample.id,
                at: row.sample.at,
                window: row.sample.front.map { [$0.app, $0.title].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "不在 Mac 前",
                fit: label.text,
                tone: label.tone
            )
        }
    }

    private static func fit(_ judgement: Judgement?, away: Bool) -> (text: String, tone: Color) {
        if away { return ("离开", Color.secondary) }
        guard let judgement else { return ("", Color.secondary) }
        switch judgement.fit {
        case .same: return ("就是这件事", Color.green)
        case .related: return ("相关 · \(judgement.kind.label)", Color.green)
        case .unrelated: return (judgement.kind.label, Palette.warm)
        }
    }

    /// The plan, then how it is going.
    static func lines(_ view: LocalData.FocusView, now: Date) -> (plan: String, state: String?, tone: Color) {
        switch view {
        case .off:
            return ("", nil, Color.secondary)
        case .paused(let until):
            return ("专注检查暂停到 \(Fmt.hm(until))", nil, Color.secondary)
        case .needsTitles:
            return ("专注检查", "没有辅助功能权限", Palette.warm)
        case .noModel(let why):
            return ("专注检查", why, Color.secondary)
        case .checking(let state):
            switch state {
            case .free:
                return ("现在没有安排", nil, Color.secondary)
            case .watching(let plan):
                return ("「\(plan.title)」", "在看前台窗口", Color.secondary)
            case .away(let plan):
                return ("「\(plan.title)」", "你不在 Mac 前", Color.secondary)
            case .on(let plan, _):
                return ("在做「\(plan.title)」", "对得上", Color.green)
            case .off(let plan, let since, _):
                let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
                return ("「\(plan.title)」原定 \(Fmt.hm(plan.start))", "\(minutes) 分钟没在做", Palette.warm)
            }
        }
    }
}
