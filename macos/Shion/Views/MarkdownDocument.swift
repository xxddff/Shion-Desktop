import Foundation
import Markdown

/// An assistant's reply as the chat lays it out (MarkdownView.swift): GitHub-flavoured Markdown,
/// parsed by Apple's swift-markdown (cmark-gfm). Inline styles are runs of an `AttributedString`,
/// which `Text` draws; blocks are laid out by the view, since `Text` cannot show a table.
/// This file sees only Foundation and swift-markdown (whose `Text` and `Image` would clash with
/// SwiftUI's).
struct MarkdownDocument: Hashable {
    var blocks: [MarkdownBlock]
}

enum MarkdownBlock: Hashable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case code(String)
    case table(MarkdownTable)
    case rule
}

struct MarkdownList: Hashable {
    /// The first item's number, for an ordered list.
    var start: Int?
    var items: [MarkdownListItem]
}

struct MarkdownListItem: Hashable {
    /// A task list item's box, ticked or not; nil for a plain item.
    var checked: Bool?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable: Hashable {
    enum ColumnAlignment: Hashable {
        case leading, center, trailing
    }

    var alignments: [ColumnAlignment]
    var header: [AttributedString]
    /// Each as many cells as the header has.
    var rows: [[AttributedString]]
}

extension MarkdownDocument {
    /// `code` is added to inline code's runs: how the view sets them apart.
    init(parsing text: String, code: AttributeContainer = AttributeContainer()) {
        // the text as written: no curly quotes or dashes made from straight ones
        let document = Document(parsing: text, options: [.disableSmartOpts])
        blocks = MarkdownReader(code: code).blocks(in: document)
    }

    /// Where a reply still arriving can be laid out up to: just after its last blank line outside a
    /// code fence, so every block before it is whole. What follows shows as it comes.
    static func settledEnd(of text: String) -> String.Index {
        let bytes = text.utf8
        var end = bytes.startIndex
        var lineStart = bytes.startIndex
        // the open fence's character and length
        var fence: (mark: UInt8, count: Int)?
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes[index] == UInt8(ascii: "\n") else {
                index = bytes.index(after: index)
                continue
            }
            let line = bytes[lineStart..<index]
            let next = bytes.index(after: index)
            if let open = fence {
                if let close = fenceMark(line), close.mark == open.mark, close.count >= open.count, close.bare {
                    fence = nil
                }
            } else if let open = fenceMark(line) {
                fence = (open.mark, open.count)
            } else if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }) {
                end = next
            }
            lineStart = next
            index = next
        }
        return end
    }

    /// A fence line: up to three spaces, then three or more backticks or tildes. `bare` when
    /// nothing but spaces follows them, as a closing fence must be.
    private static func fenceMark(_ line: Substring.UTF8View) -> (mark: UInt8, count: Int, bare: Bool)? {
        let indent = line.prefix { $0 == UInt8(ascii: " ") }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let mark = rest.first, mark == UInt8(ascii: "`") || mark == UInt8(ascii: "~") else { return nil }
        let count = rest.prefix { $0 == mark }.count
        guard count >= 3 else { return nil }
        let after = rest.dropFirst(count)
        // a backtick fence's info string has no backticks
        if mark == UInt8(ascii: "`"), after.contains(UInt8(ascii: "`")) { return nil }
        let bare = after.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
        return (mark, count, bare)
    }
}

/// Parsed replies by message id, kept while the text stays the same: a long chat parses each
/// reply once, not every time its row is laid out or scrolls back into view.
final class MarkdownCache {
    /// Added to inline code's runs (`MarkdownDocument(parsing:code:)`).
    private let code: AttributeContainer
    private var entries: [String: (text: String, document: MarkdownDocument, used: Int)] = [:]
    private var tick = 0
    private let limit: Int

    init(code: AttributeContainer = AttributeContainer(), limit: Int = 400) {
        self.code = code
        self.limit = limit
    }

    func document(_ id: String, _ text: String) -> MarkdownDocument {
        tick += 1
        if let entry = entries[id], entry.text == text {
            entries[id]?.used = tick
            return entry.document
        }
        let document = MarkdownDocument(parsing: text, code: code)
        keep(document, of: text, as: id)
        return document
    }

    /// The whole blocks of a reply still arriving (`MarkdownDocument.settledEnd`). As the reply
    /// grows only the newly whole part is parsed, so each block costs its own length once. They
    /// can differ from the finished reply's (a loose list arrives as lists of one item), which is
    /// parsed whole once it is done.
    func settled(_ id: String, _ text: String) -> [MarkdownBlock] {
        let key = id + "|settled"
        guard let entry = entries[key], text.utf8.starts(with: entry.text.utf8) else {
            return document(key, text).blocks
        }
        tick += 1
        guard text.utf8.count > entry.text.utf8.count else {
            entries[key]?.used = tick
            return entry.document.blocks
        }
        // the old text ends just after a line break, so this is a character boundary
        let start = text.utf8.index(text.startIndex, offsetBy: entry.text.utf8.count)
        let more = MarkdownDocument(parsing: String(text[start...]), code: code)
        let document = MarkdownDocument(blocks: entry.document.blocks + more.blocks)
        keep(document, of: text, as: key)
        return document.blocks
    }

    private func keep(_ document: MarkdownDocument, of text: String, as id: String) {
        entries[id] = (text, document, tick)
        guard entries.count > limit else { return }
        // the quarter shown longest ago goes
        let stale = entries.sorted { $0.value.used < $1.value.used }.prefix(max(1, limit / 4)).map(\.key)
        for key in stale {
            entries[key] = nil
        }
    }
}

/// From swift-markdown's tree to the chat's blocks.
private struct MarkdownReader {
    let code: AttributeContainer

    func blocks(in container: Markup) -> [MarkdownBlock] {
        container.children.flatMap { block($0) }
    }

    func block(_ markup: Markup) -> [MarkdownBlock] {
        switch markup {
        case let paragraph as Paragraph:
            return [.paragraph(inline(paragraph))]
        case let heading as Heading:
            return [.heading(level: heading.level, inline(heading))]
        case let list as UnorderedList:
            return [.list(MarkdownList(start: nil, items: list.listItems.map { item($0) }))]
        case let list as OrderedList:
            return [.list(MarkdownList(start: Int(list.startIndex), items: list.listItems.map { item($0) }))]
        case let quote as BlockQuote:
            return [.quote(blocks(in: quote))]
        case let block as CodeBlock:
            let text = block.code.hasSuffix("\n") ? String(block.code.dropLast()) : block.code
            return [.code(text)]
        case let html as HTMLBlock:
            return [.paragraph(AttributedString(html.rawHTML.trimmingCharacters(in: .newlines)))]
        case is ThematicBreak:
            return [.rule]
        case let table as Table:
            return [.table(self.table(table))]
        default:
            // directives, asides and other containers: what they hold
            return blocks(in: markup)
        }
    }

    func item(_ listItem: ListItem) -> MarkdownListItem {
        let checked: Bool? = switch listItem.checkbox {
        case .checked?: true
        case .unchecked?: false
        case nil: nil
        }
        return MarkdownListItem(checked: checked, blocks: blocks(in: listItem))
    }

    func table(_ table: Table) -> MarkdownTable {
        let columns = max(table.maxColumnCount, 1)
        let alignments = (0..<columns).map { column -> MarkdownTable.ColumnAlignment in
            switch column < table.columnAlignments.count ? table.columnAlignments[column] : nil {
            case .center?: .center
            case .right?: .trailing
            default: .leading
            }
        }
        // a cell another one spans over stays, empty, so the columns keep lining up
        func row(_ cells: [Table.Cell]) -> [AttributedString] {
            let texts = cells.prefix(columns).map { $0.colspan == 0 ? AttributedString() : inline($0) }
            return texts + Array(repeating: AttributedString(), count: columns - texts.count)
        }
        return MarkdownTable(
            alignments: alignments,
            header: row(Array(table.head.cells)),
            rows: table.body.rows.map { row(Array($0.cells)) }
        )
    }

    // MARK: inline

    func inline(_ container: Markup, _ attributes: AttributeContainer = AttributeContainer()) -> AttributedString {
        var text = AttributedString()
        for child in container.children {
            text += span(child, attributes)
        }
        return text
    }

    func span(_ markup: Markup, _ attributes: AttributeContainer) -> AttributedString {
        switch markup {
        case let text as Text:
            return attributes.link == nil ? Self.linkingAddresses(text.string, attributes) : AttributedString(text.string, attributes: attributes)
        case is SoftBreak, is LineBreak:
            // a reply's line breaks are kept, as before
            return AttributedString("\n", attributes: attributes)
        case let inlineCode as InlineCode:
            return AttributedString(inlineCode.code, attributes: adding(.code, to: attributes).merging(code))
        case is Emphasis:
            return inline(markup, adding(.emphasized, to: attributes))
        case is Strong:
            return inline(markup, adding(.stronglyEmphasized, to: attributes))
        case is Strikethrough:
            return inline(markup, adding(.strikethrough, to: attributes))
        case let link as Link:
            var linked = attributes
            linked.link = link.destination.flatMap { URL(string: $0) }
            return inline(markup, linked)
        case let image as Image:
            // pictures are not shown in the chat: their words, linked to the picture
            var linked = attributes
            linked.link = image.source.flatMap { URL(string: $0) }
            let words = inline(markup, linked)
            return words.characters.isEmpty ? AttributedString(image.source ?? "", attributes: linked) : words
        case let html as InlineHTML:
            let tag = html.rawHTML.lowercased().filter { !$0.isWhitespace }
            return AttributedString(["<br>", "<br/>"].contains(tag) ? "\n" : html.rawHTML, attributes: attributes)
        case let symbol as SymbolLink:
            return AttributedString(symbol.destination ?? "", attributes: adding(.code, to: attributes).merging(code))
        default:
            return inline(markup, attributes)
        }
    }

    func adding(_ intent: InlinePresentationIntent, to attributes: AttributeContainer) -> AttributeContainer {
        var container = attributes
        container.inlinePresentationIntent = (attributes.inlinePresentationIntent ?? []).union(intent)
        return container
    }

    /// Text with its bare web addresses linked: swift-markdown leaves GitHub's autolinks out.
    static func linkingAddresses(_ string: String, _ attributes: AttributeContainer) -> AttributedString {
        var text = AttributedString()
        var rest = string.startIndex
        for range in addresses(in: string) {
            text += AttributedString(string[rest..<range.lowerBound], attributes: attributes)
            var linked = attributes
            linked.link = URL(string: String(string[range]))
            text += AttributedString(string[range], attributes: linked)
            rest = range.upperBound
        }
        text += AttributedString(string[rest...], attributes: attributes)
        return text
    }

    /// `http://` and `https://` addresses in running text, also right after Chinese or Japanese
    /// words. One ends at a space or at punctuation that cannot be in it (Chinese and Japanese
    /// marks among them); a sentence's closing punctuation and an unmatched parenthesis after it
    /// are left out.
    static func addresses(in string: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var cursor = string.startIndex
        while let scheme = string.range(of: "http", range: cursor..<string.endIndex) {
            cursor = scheme.upperBound
            let separator = string[scheme.upperBound...].hasPrefix("s://") ? "s://" : "://"
            // not the end of a longer Latin word ("xhttp://")
            let before = scheme.lowerBound == string.startIndex ? nil : string[string.index(before: scheme.lowerBound)]
            guard string[scheme.upperBound...].hasPrefix(separator),
                  !(before.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false)
            else { continue }
            let host = string.index(scheme.upperBound, offsetBy: separator.count)
            var end = host
            while end < string.endIndex, !endsAddress(string[end]) {
                end = string.index(after: end)
            }
            while end > host {
                let last = string[string.index(before: end)]
                let address = string[host..<end]
                let unmatched = last == ")" && address.filter { $0 == "(" }.count < address.filter { $0 == ")" }.count
                guard ".,;:!?'\"*_".contains(last) || unmatched else { break }
                end = string.index(before: end)
            }
            guard end > host else { continue }
            found.append(scheme.lowerBound..<end)
            cursor = end
        }
        return found
    }

    private static func endsAddress(_ character: Character) -> Bool {
        character.isWhitespace || "<>\"`{}|\\^".contains(character) || (character.isPunctuation && !character.isASCII)
    }
}
