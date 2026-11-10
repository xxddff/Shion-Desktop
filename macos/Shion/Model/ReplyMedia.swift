import Foundation
import Markdown

/// What an assistant's reply hands over, read as Hermes's gateway reads a reply it delivers
/// (`gateway/platforms/base.py`): `MEDIA:<path>` tags outside code, quotes and JSON strings; server
/// paths written in the words; and Markdown pictures. The reply shows without its tags and its
/// pictures, which the chat lays out under it. This file sees only Foundation and swift-markdown,
/// whose `Image` would clash with SwiftUI's.
enum ReplyMedia {
    struct Parsed: Hashable {
        var text: String
        var media: [ChatMedia]
    }

    static func parse(_ reply: String) -> Parsed {
        guard reply.contains("MEDIA:") || reply.contains("![") || reply.contains("/") || reply.contains("[[") else {
            return Parsed(text: reply, media: [])
        }
        var media: [ChatMedia] = []
        func add(_ item: ChatMedia) {
            if !media.contains(where: { $0.id == item.id }) {
                media.append(item)
            }
        }
        var text = reply.replacingOccurrences(of: "[[audio_as_voice]]", with: "")
            .replacingOccurrences(of: "[[as_document]]", with: "")
        if text.contains("MEDIA:") || text.contains("media:") {
            let tags = mediaTags(text)
            tags.delivered.forEach { add(ChatMedia(serverPath: $0)) }
            tags.unconfirmed.forEach { add(ChatMedia(serverPath: $0, unconfirmed: true)) }
            if !tags.spans.isEmpty {
                text = deleting(tags.spans, from: text)
                text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if text.contains("![") {
            let found = pictures(text)
            found.forEach { add($0.media) }
            if !found.isEmpty {
                text = deleting(found.map { $0.span }, from: text)
            }
        }
        for path in writtenPaths(text) {
            add(ChatMedia(serverPath: path, unconfirmed: true))
        }
        return Parsed(text: text, media: media)
    }

    /// A reply still arriving, without the tags that are whole already.
    static func streamingText(_ reply: String) -> String {
        guard reply.contains("MEDIA:") || reply.contains("[[") else { return reply }
        let text = reply.replacingOccurrences(of: "[[audio_as_voice]]", with: "")
            .replacingOccurrences(of: "[[as_document]]", with: "")
        let spans = mediaTags(text).spans
        return spans.isEmpty ? text : deleting(spans, from: text)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    // MARK: MEDIA: tags

    /// Longest first, so a short extension never matches the start of a longer one.
    private static let extensions = MediaKinds.deliveryExtensions.sorted { $0.count > $1.count }.joined(separator: "|")
    /// Chinese full-width punctuation ends a path too (`MEDIA:/x/早报.pdf（782.6 KB）`).
    private static let cjkStops = "（）〈〉《》：，。；！？、\u{201C}\u{201D}\u{2018}\u{2019}【】"

    /// Hermes's `MEDIA_TAG_CLEANUP_RE`: a tag whose path ends in an extension it delivers, quoted or
    /// bare, up to three quote or emphasis marks around it; a bare path may have spaces in it.
    private static let deliveredTag = try! NSRegularExpression(
        pattern: #"[`"'*_]{0,3}MEDIA:\s*(`[^`\n]+?`|"[^"\n]+?"|'[^'\n]+?'|(?:~/|/)\S+?(?:[^\S\n]+\S+?)*?\.(?:"#
            + extensions + #"))(?=[\s`"'*_,;:)\]}\["# + cjkStops + #"]|MEDIA:|\.(?:\s|$)|$)[`"'*_]{0,3}\.?"#,
        options: .caseInsensitive)

    /// `MEDIA_EXTENSIONLESS_TAG_RE`: any other path, up to the first space. Hermes sends those only
    /// once it finds the file, so they stay in the words and show once the server has them.
    private static let otherTag = try! NSRegularExpression(
        pattern: #"[`"'*_]{0,3}MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|(?:~/|/)[^\s`"']+?)(?=[`"'\s,;:)\]}"#
            + cjkStops + #"]|MEDIA:|$)[`"'*_]{0,3}\s*"#,
        options: .caseInsensitive)

    private static let fence = try! NSRegularExpression(pattern: "```[^\\n]*\\n.*?```", options: .dotMatchesLineSeparators)
    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let quoteLine = try! NSRegularExpression(pattern: "^>.*$", options: .anchorsMatchLines)
    private static let jsonValue = try! NSRegularExpression(pattern: #"(?<=[:,{\[])\s*"((?:[^"\\\n]|\\.)*)""#)
    private static let jsonTag = try! NSRegularExpression(pattern: #"MEDIA:\s*(?:~/|/)"#)

    /// The tags' paths, and where the delivered ones are (UTF-16 ranges of `text`). A whole tag in
    /// inline code (`` `MEDIA:/x.csv` ``) is real when the file is there, which only the server knows.
    static func mediaTags(_ text: String) -> (delivered: [String], unconfirmed: [String], spans: [NSRange]) {
        let (masked, quoted) = masking(text)
        let whole = NSRange(location: 0, length: (masked as NSString).length)
        var delivered: [String] = []
        var spans: [NSRange] = []
        for match in deliveredTag.matches(in: masked, range: whole) {
            let path = normalized((masked as NSString).substring(with: match.range(at: 1)))
            // a quoted value after "media:" in a sentence is not a file on the server
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { continue }
            spans.append(match.range)
            if !delivered.contains(path) {
                delivered.append(path)
            }
        }
        var unconfirmed = quoted
        for match in otherTag.matches(in: masked, range: whole)
        where !spans.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let path = normalized((masked as NSString).substring(with: match.range(at: 1)))
            guard path.hasPrefix("/") || path.hasPrefix("~/"),
                  !MediaKinds.deliveryExtensions.contains(MediaKinds.fileExtension(MediaKinds.fileName(path))),
                  !delivered.contains(path), !unconfirmed.contains(path)
            else { continue }
            unconfirmed.append(path)
        }
        return (delivered, unconfirmed, spans)
    }

    /// `text` with code, quotes and JSON strings blanked, the same length in UTF-16 so ranges found
    /// in it hold in `text`; and the paths of whole tags in inline code.
    private static func masking(_ text: String) -> (String, [String]) {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        var spans = fence.matches(in: text, range: whole).map(\.range)
        var quoted: [String] = []
        for match in inlineCode.matches(in: text, range: whole) {
            let start = match.range.location
            let before = string.substring(with: NSRange(location: max(0, start - 20), length: min(20, start)))
            // the backticks quote a tag's path: `MEDIA:` comes just before them
            if before.range(of: #"MEDIA:\s*$"#, options: .regularExpression) != nil {
                continue
            }
            let inner = string.substring(with: NSRange(location: start + 1, length: match.range.length - 2))
                .trimmingCharacters(in: .whitespaces)
            if inner.uppercased().hasPrefix("MEDIA:") {
                let path = normalized(String(inner.dropFirst(6)))
                if path.hasPrefix("/") || path.hasPrefix("~/"), !quoted.contains(path) {
                    quoted.append(path)
                }
            }
            spans.append(match.range)
        }
        spans += quoteLine.matches(in: text, range: whole).map(\.range)
        for match in jsonValue.matches(in: text, range: whole) {
            let value = match.range(at: 1)
            if jsonTag.firstMatch(in: text, range: value) != nil {
                spans.append(value)
            }
        }
        return (blanking(spans, in: text), quoted)
    }

    /// Hermes's `_normalize_media_tag_path`: without its quotes, and without the punctuation a
    /// sentence puts after it.
    static func normalized(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let head = path.first, head == path.last, "`\"'".contains(head) {
            path = String(path.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let first = path.first, "`\"'".contains(first) {
            path.removeFirst()
        }
        while let last = path.last, "`\"',.;:)}]".contains(last) {
            path.removeLast()
        }
        return path
    }

    // MARK: paths written in the words

    /// Hermes's `extract_local_files`: an absolute or home path ending in an extension it delivers,
    /// not inside a web address or a relative path, not in code. Hermes sends one only if the file
    /// is there.
    private static let writtenPath = try! NSRegularExpression(
        pattern: #"(?<![/:\w.])(?:~/|/)(?:[\w.\-]+/)*[\w.\-]+\.(?:"# + extensions + #")\b"#, options: .caseInsensitive)

    static func writtenPaths(_ text: String) -> [String] {
        guard text.contains("/") else { return [] }
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        let code = fence.matches(in: text, range: whole).map(\.range) + inlineCode.matches(in: text, range: whole).map(\.range)
        var paths: [String] = []
        for match in writtenPath.matches(in: text, range: whole)
        where !code.contains(where: { NSLocationInRange(match.range.location, $0) }) {
            let path = string.substring(with: match.range)
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    // MARK: Markdown pictures

    /// Each Markdown picture outside code: where it is (UTF-16 range of `text`) and what to show.
    /// A web picture waits for a click; a `data:` one is shown as it is; a path is the server's.
    /// Relative sources are left alone.
    static func pictures(_ text: String) -> [(span: NSRange, media: ChatMedia)] {
        var walker = PictureWalker()
        walker.visit(Document(parsing: text, options: [.disableSmartOpts]))
        let lines = lineStarts(text)
        return walker.found.compactMap { picture -> (NSRange, ChatMedia)? in
            guard let range = picture.range, let span = utf16Range(range, lines: lines, in: text) else { return nil }
            let source = picture.source.trimmingCharacters(in: .whitespaces)
            let caption = picture.alt.isEmpty ? nil : picture.alt
            if source.hasPrefix("http://") || source.hasPrefix("https://") || source.lowercased().hasPrefix("data:image/") {
                guard let url = URL(string: source) else { return nil }
                let name = url.scheme == "data" ? "图片" : MediaKinds.fileName(url.path)
                return (span, ChatMedia(kind: .image, name: name.isEmpty ? "图片" : name, url: url, caption: caption))
            }
            let path = source.hasPrefix("file://") ? (URL(string: source)?.path ?? "") : source
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
            var media = ChatMedia(serverPath: path)
            media.kind = .image
            media.caption = caption
            return (span, media)
        }
    }

    private struct PictureWalker: MarkupWalker {
        var found: [(source: String, alt: String, range: SourceRange?)] = []

        mutating func visitImage(_ image: Image) {
            found.append((image.source ?? "", image.plainText, image.range))
        }
    }

    /// UTF-8 offsets of each line's first byte; swift-markdown counts lines from 1 and columns in
    /// UTF-8 bytes from 1.
    private static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") {
            starts.append(offset + 1)
        }
        return starts
    }

    private static func utf16Range(_ range: SourceRange, lines: [Int], in text: String) -> NSRange? {
        func index(_ location: SourceLocation) -> String.Index? {
            guard location.line >= 1, location.line <= lines.count else { return nil }
            let offset = lines[location.line - 1] + location.column - 1
            guard offset >= 0, offset <= text.utf8.count else { return nil }
            return text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        }
        guard let start = index(range.lowerBound), let end = index(range.upperBound), start <= end else { return nil }
        return NSRange(start..<end, in: text)
    }

    // MARK: ranges

    private static func blanking(_ spans: [NSRange], in text: String) -> String {
        var units = Array(text.utf16)
        for span in spans {
            for index in span.location..<min(units.count, span.location + span.length) where units[index] != 0x0A {
                units[index] = 0x20
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// `text` without `spans`, overlapping ones merged first.
    private static func deleting(_ spans: [NSRange], from text: String) -> String {
        var merged: [NSRange] = []
        for span in spans.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, span.location <= last.location + last.length {
                merged[merged.count - 1].length = max(last.length, span.location + span.length - last.location)
            } else {
                merged.append(span)
            }
        }
        let result = NSMutableString(string: text)
        for span in merged.reversed() where span.location + span.length <= result.length {
            result.deleteCharacters(in: span)
        }
        return result as String
    }
}

/// Replies' pictures and files, worked out once per text: a long chat parses each reply once, not
/// every time its row is laid out.
final class ReplyMediaCache {
    static let shared = ReplyMediaCache()

    private var entries: [String: (text: String, parsed: ReplyMedia.Parsed)] = [:]

    func parsed(_ id: String, _ text: String) -> ReplyMedia.Parsed {
        if let entry = entries[id], entry.text == text {
            return entry.parsed
        }
        let parsed = ReplyMedia.parse(text)
        if entries.count >= 400 {
            entries.removeAll(keepingCapacity: true)
        }
        entries[id] = (text, parsed)
        return parsed
    }
}
