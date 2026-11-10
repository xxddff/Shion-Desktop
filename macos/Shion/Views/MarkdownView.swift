import SwiftUI

/// A reply's Markdown (MarkdownDocument.swift), block under block. Text selection set on a
/// container reaches every text in it, so a finished reply selects block by block.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], depth: 0)
            }
        }
    }
}

struct MarkdownBlockView: View {
    /// What the chat's find bar looks for, marked (ChatControls.swift).
    @Environment(\.findMarks) private var marks
    let block: MarkdownBlock
    /// How deep in lists the block is: the bullet changes with it.
    let depth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(marks.mark(text))
                .font(.t13)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(marks.mark(text))
                .font(level <= 2 ? Font.t15 : Font.t13.weight(.semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .list(let list):
            MarkdownListView(list: list, depth: depth)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Palette.line)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks.indices, id: \.self) { index in
                        MarkdownBlockView(block: blocks[index], depth: depth)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            MarkdownCode(code: code)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider()
                .padding(.vertical, 4)
        }
    }
}

/// A list's items, each after its number, bullet or task box.
struct MarkdownListView: View {
    let list: MarkdownList
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list.items.indices, id: \.self) { index in
                let item = list.items[index]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item, index)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.blocks.indices, id: \.self) { block in
                            MarkdownBlockView(block: item.blocks[block], depth: depth + 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownListItem, _ index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.t13)
                .foregroundStyle(checked ? Palette.accent : Color.secondary)
                .accessibilityLabel(checked ? "已完成" : "未完成")
        } else if let start = list.start {
            Text(verbatim: "\(start + index).")
                .font(.t13)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text(verbatim: ["•", "◦", "▪"][min(depth, 2)])
                .font(.t13)
                .foregroundStyle(.secondary)
        }
    }
}

/// A code block: monospaced, long lines scroll sideways instead of wrapping.
struct MarkdownCode: View {
    @Environment(\.findMarks) private var marks
    let code: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(marks.mark(code))
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        // a block starts at its first column, whatever a scroll view around it anchors (the
        // ⌥Space window's answer anchors its bottom)
        .defaultScrollAnchor(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("markdown-code")
    }
}

/// A GitHub table: the header over a line, a fainter line between rows, each column aligned as
/// the table says. One that fits the reply is laid out as it is; wider, its cells wrap, though
/// none narrower than `cellLimit` needs to be; still too wide, the table scrolls sideways in its
/// own box and the rest of the reply stays put.
struct MarkdownTableView: View {
    @Environment(\.findMarks) private var marks
    let table: MarkdownTable
    /// About 18 Chinese characters at 13 points.
    static let cellLimit: CGFloat = 240

    var body: some View {
        // a table fits when its cells, each wrapped at no more than the limit, fit side by side
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) {
                grid
            }
            // a table starts at its first column, whatever a scroll view around it anchors (the
            // ⌥Space window's answer anchors its bottom)
            .defaultScrollAnchor(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("markdown-table-scroll")
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column, font: Font.t13.weight(.semibold))
                        .gridColumnAlignment(horizontal(column))
                }
            }
            // a divider would widen the grid to the whole reply
            Divider()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        cell(table.rows[row][column], column, font: .t13)
                    }
                }
                if row < table.rows.count - 1 {
                    Divider()
                        .opacity(0.5)
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-table")
    }

    private func cell(_ text: AttributedString, _ column: Int, font: Font) -> some View {
        WrappingWidth(limit: Self.cellLimit) {
            Text(marks.mark(text))
                .font(font)
                .multilineTextAlignment(textAlignment(column))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func horizontal(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func alignment(_ column: Int) -> MarkdownTable.ColumnAlignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }
}

/// Lays a cell's text out at the width it is offered, up to its own; offered none (measured for
/// its ideal size, or in a sideways scroll view, where a frame would let it run on in one line),
/// it wraps at `limit`.
struct WrappingWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        return text.sizeThatFits(ProposedViewSize(width: width(text, proposal), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let text = subviews.first else { return }
        text.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width(text, proposal), height: nil))
    }

    private func width(_ text: LayoutSubview, _ proposal: ProposedViewSize) -> CGFloat {
        min(text.sizeThatFits(.unspecified).width, proposal.width ?? limit)
    }
}

/// A reply still arriving: the blocks already whole, laid out, then the rest as it comes, behind
/// the cursor. Not selectable yet: a selectable text keeps the accessibility value it was made
/// with, so the reply becomes selectable once it is whole.
struct StreamingReply: View {
    let id: String
    let text: String

    var body: some View {
        let parts = MarkdownDocument.streaming(text)
        VStack(alignment: .leading, spacing: 8) {
            if parts.end > text.startIndex {
                MarkdownView(blocks: MarkdownCache.shared.settled(id, String(text[..<parts.end]), definitions: parts.definitions))
            }
            Text(verbatim: String(text[parts.end...].drop { $0.isNewline }) + " ▍")
                .font(.t13)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension MarkdownCache {
    /// The chat's: inline code on the faint fill code blocks have.
    static let shared: MarkdownCache = {
        var code = AttributeContainer()
        code.backgroundColor = Palette.fill
        return MarkdownCache(code: code)
    }()
}
