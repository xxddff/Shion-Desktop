import SwiftUI

/// Daily reports written on the VPS by 「回顾」 and 「资讯」; Shion only reads them. A notification's
/// report opens on its kind; one that is no longer the newest of its kind is read for it.
struct ReportsView: View {
    @Environment(AppStore.self) private var store
    @State private var kind: ReportKind = .life
    /// A notification's report that is not the newest of its kind, while that kind is picked.
    @State private var opened: Report?

    var body: some View {
        let report = opened.flatMap { $0.kind == kind ? $0 : nil } ?? store.reports.first { $0.kind == kind }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let report {
                    header(report)
                    ForEach(report.blocks, id: \.heading) { block in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(block.heading).font(.t15)
                            ForEach(block.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(item)
                                        .font(.t13)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("还没有这类日报", systemImage: "doc.text")
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("日报")
        // a notification's report (Landing.swift), once the plugin's reports are here
        .task(id: "\(String(describing: Landings.shared.pending(on: .reports)))|\(store.pluginData)") {
            guard case .report(let id, let day, let kind)? = Landings.shared.pending(on: .reports), store.pluginData else { return }
            self.kind = kind
            let report = store.reports.contains { $0.id == id } ? nil : await store.fetchReport(day: day, kind: kind)
            guard !Task.isCancelled else { return }
            opened = report
            // last: clearing it starts this task anew
            Landings.shared.pending = nil
        }
        .onChange(of: kind) {
            if opened?.kind != kind {
                opened = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("日报", selection: $kind) {
                    ForEach(ReportKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private func header(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(report.kind.label)日报 · \(Fmt.dayLabel(report.date, now: store.now)) \(Fmt.monthDay(report.date)) \(Fmt.weekday(report.date))")
                .font(.t12)
                .foregroundStyle(.secondary)
            Text(report.headline)
                .font(.t20)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Avatar(bot: store.bot(report.botId), size: 16)
                Text("\(store.bot(report.botId)?.name ?? "") \(Fmt.hm(report.date)) 写")
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
