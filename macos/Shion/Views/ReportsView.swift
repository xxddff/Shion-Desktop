import SwiftUI

/// Daily reports written on the VPS by 「回顾」 and 「资讯」; Shion only reads them.
struct ReportsView: View {
    @Environment(AppStore.self) private var store
    @State private var kind: ReportKind = .life

    var body: some View {
        let report = store.reports.first { $0.kind == kind }
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
