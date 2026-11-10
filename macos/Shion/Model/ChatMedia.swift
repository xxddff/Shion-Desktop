import Foundation

/// A picture or a file in a chat: one you sent, one a tool made or looked at, or one an assistant
/// handed over (`MEDIA:`, a path in its reply, a Markdown picture). It can be read from the Mac's
/// cache (`sha256`), from the server (`path`, in the chat's profile and session) or, for a web
/// picture, from `url`, once you ask for it.
nonisolated struct ChatMedia: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case image, file, folder
    }

    var kind: Kind
    var name: String
    /// On the server: absolute, or relative to the session's directory (an `@file:` inside it).
    var path: String?
    /// A web picture (`![](https://…)`), or one written out as a `data:` URL.
    var url: URL?
    /// The bytes' SHA-256 in the Mac's cache, when Shion has them.
    var sha256: String?
    var size: Int?
    /// A Markdown picture's alt text.
    var caption: String?
    /// Named in passing (a path written in a reply, a `MEDIA:` file of a kind Hermes only sends
    /// once it finds it): shown once the server says the file is there.
    var unconfirmed = false

    var id: String { path ?? url?.absoluteString ?? sha256 ?? name }

    init(kind: Kind, name: String, path: String? = nil, url: URL? = nil, sha256: String? = nil, size: Int? = nil,
         caption: String? = nil, unconfirmed: Bool = false) {
        self.kind = kind
        self.name = name
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.caption = caption
        self.unconfirmed = unconfirmed
    }

    /// A file on the server, a picture when its name says so.
    init(serverPath: String, unconfirmed: Bool = false) {
        let name = MediaKinds.fileName(serverPath)
        self.init(kind: MediaKinds.isImage(name) ? .image : .file, name: name, path: serverPath,
                  sha256: MediaKinds.contentHash(in: serverPath), unconfirmed: unconfirmed)
    }
}

/// File names and what they hold.
nonisolated enum MediaKinds {
    /// What ImageIO opens and the chat shows as a picture; SVG is not among them (it can hold
    /// scripts and outside links).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif"]

    /// What Hermes delivers from a `MEDIA:` tag or a bare path in a reply without checking first
    /// (`MEDIA_DELIVERY_EXTS`, gateway/platforms/base.py).
    static let deliveryExtensions = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg",
        "mp4", "mov", "avi", "mkv", "webm", "3gp",
        "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac",
        "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub",
        "xlsx", "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml",
        "kmz", "kml", "geojson", "gpx",
        "pptx", "ppt", "odp", "key",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa",
        "html", "htm",
    ]

    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static func isImage(_ name: String) -> Bool {
        imageExtensions.contains(fileExtension(name))
    }

    /// The last part of a path, without the slash a folder ends with.
    static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// The SHA-256 in a picture's path once Hermes took it in: it keeps each one at
    /// `cache/documents/native-inputs/<sha256>/<name>` (gateway/session_ingress_media.py).
    static func contentHash(in path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "native-inputs"), index + 1 < parts.count else { return nil }
        let hash = parts[index + 1]
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash.lowercased()
    }
}

/// A user row of the transcript, as Hermes stored it after its pictures and files: the words you
/// typed, and what came with them. The forms (Hermes `agent/image_routing.py`'s `split_image_notes`,
/// the official desktop's `chat-messages/hydration.ts` and `reference-kinds.ts`):
/// - pictures sent natively: the caption (Hermes's own when you typed nothing), a blank line, one
///   `[Image attached at: <path>]` per picture, then a `[screenshot]` (or `[image]`) placeholder each;
/// - pictures described for a model that cannot see: `[The user sent an image … image_url: <path>]`
///   notes before the words;
/// - files: one `@file:<path>` line each, before the words; older servers also kept the files'
///   contents after a `--- Attached Context ---` line.
enum SentNotes {
    /// What Hermes asks when pictures come without words.
    static let defaultCaption = "What do you see in this image?"

    static func parse(_ text: String) -> (text: String, media: [ChatMedia]) {
        guard text.contains("[") || text.contains("@") || text.contains("---") else { return (text, []) }
        var rest = text
        var pictures: [ChatMedia] = []
        if let (caption, hints) = trailingHints(rest) {
            rest = caption
            pictures = hints
        }
        rest = withoutAttachedContext(rest)
        var notes: [ChatMedia] = []
        while let match = noteRegex.firstMatch(in: rest, options: .anchored, range: NSRange(rest.startIndex..., in: rest)),
              let whole = Range(match.range, in: rest), let path = Range(match.range(at: 1), in: rest) {
            notes.append(picture(String(rest[path]).trimmingCharacters(in: .whitespaces)))
            rest = String(rest[whole.upperBound...])
        }
        let (refs, words) = leadingRefs(rest)
        var media: [ChatMedia] = []
        for item in refs + notes + pictures where !media.contains(where: { $0.id == item.id }) {
            media.append(item)
        }
        let shown = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !media.isEmpty else { return (words == text ? text : shown, []) }
        let captionOnly = shown == defaultCaption && media.contains(where: { $0.kind == .image })
        return (captionOnly ? "" : shown, media)
    }

    /// A picture named in a note: a server path, or a web address (`[Image attached: <url>]`).
    private static func picture(_ value: String) -> ChatMedia {
        if value.contains("://"), let url = URL(string: value), url.scheme != "file" {
            return ChatMedia(kind: .image, name: MediaKinds.fileName(url.path), url: url)
        }
        let path = value.hasPrefix("file://") ? (URL(string: value)?.path ?? value) : value
        var media = ChatMedia(serverPath: path)
        media.kind = .image
        return media
    }

    // MARK: the pictures' notes at the end

    private static let hintsRegex = try! NSRegularExpression(
        pattern: #"(?:^|\n\n)((?:\[Image attached(?: at)?: [^\n]+\]\n?)+)((?:\[(?:screenshot|image)(?: detail=[a-z]+)?\](?:\n|$))*)\s*$"#)
    private static let hintRegex = try! NSRegularExpression(pattern: #"\[Image attached(?: at)?: ([^\n]+)\]"#)

    private static func trailingHints(_ text: String) -> (String, [ChatMedia])? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = hintsRegex.firstMatch(in: text, range: whole),
              let hints = Range(match.range(at: 1), in: text), let start = Range(match.range, in: text)
        else { return nil }
        let block = String(text[hints])
        let pictures = hintRegex.matches(in: block, range: NSRange(block.startIndex..., in: block)).compactMap { hint in
            Range(hint.range(at: 1), in: block).map { picture(String(block[$0]).trimmingCharacters(in: .whitespaces)) }
        }
        guard !pictures.isEmpty else { return nil }
        return (String(text[..<start.lowerBound]), pictures)
    }

    // MARK: notes and references at the start

    private static let noteRegex = try! NSRegularExpression(
        pattern: #"\[The user (?:sent|attached) an image[\s\S]*?image_url: ([^\n]+?)(?: ~)?\](?:\n\n|$)"#)

    /// One reference alone on its line: `@file:`, `@folder:` or `@image:`, its value quoted when it
    /// has spaces or brackets in it.
    private static let refLineRegex = try! NSRegularExpression(
        pattern: #"^@(file|folder|image):(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)$"#)

    private static func leadingRefs(_ text: String) -> ([ChatMedia], String) {
        var lines = text.components(separatedBy: "\n")
        var refs: [ChatMedia] = []
        while let first = lines.first {
            let line = first.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            guard let match = refLineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let kind = Range(match.range(at: 1), in: line), let value = Range(match.range(at: 2), in: line)
            else { break }
            let path = unwrap(String(line[value]))
            guard !path.isEmpty else { break }
            var media = ChatMedia(serverPath: path)
            switch line[kind] {
            case "folder": media.kind = .folder
            case "image": media.kind = .image
            default: break
            }
            refs.append(media)
            lines.removeFirst()
        }
        guard !refs.isEmpty else { return ([], text) }
        return (refs, lines.joined(separator: "\n"))
    }

    /// A reference's value without its quotes; a bare one also loses the punctuation that ends a
    /// sentence after it, as the desktop reads it.
    static func unwrap(_ raw: String) -> String {
        if raw.count >= 2, let head = raw.first, head == raw.last, "`\"'".contains(head) {
            return String(raw.dropFirst().dropLast())
        }
        var value = raw
        while let last = value.last, ",.;!?".contains(last) {
            value.removeLast()
        }
        return value
    }

    // MARK: what an older server kept after the words

    private static let attachedMarker = try! NSRegularExpression(pattern: #"(?:^|\n)--- Attached Context ---\s*\n"#)
    private static let warningsMarker = try! NSRegularExpression(pattern: #"(?:^|\n)--- Context Warnings ---[\s\S]*$"#)
    private static let contextRef = try! NSRegularExpression(
        pattern: #"@(?:file|folder|url|image|tool|terminal):(?:"[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)"#)

    /// The words before the files' contents, with the references they lack put back on top.
    private static func withoutAttachedContext(_ text: String) -> String {
        guard let marker = attachedMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let cut = Range(marker.range, in: text)
        else { return text.contains("--- Context Warnings ---") ? withoutWarnings(text) : text }
        let visible = withoutWarnings(String(text[..<cut.lowerBound]))
        let attached = String(text[cut.upperBound...])
        var missing: [String] = []
        for match in contextRef.matches(in: attached, range: NSRange(attached.startIndex..., in: attached)) {
            guard let range = Range(match.range, in: attached) else { continue }
            let ref = String(attached[range])
            if ref.hasPrefix("@file:") || ref.hasPrefix("@folder:") || ref.hasPrefix("@image:"),
               !visible.contains(ref), !missing.contains(ref) {
                missing.append(ref)
            }
        }
        return [missing.joined(separator: "\n"), visible].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func withoutWarnings(_ text: String) -> String {
        warningsMarker.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The picture a finished tool call made or looked at, from its `tool.complete` event: Hermes's
/// `image_path` (`tui_gateway/contracts/events.py`), else the fields it reads that from
/// (`agent/terminal_image.py`): the result's `image_path` or `screenshot_path`, `image_generate`'s
/// `image`, `vision_analyze`'s `image_url`. Only local pictures on the server count.
enum ToolPicture {
    static func path(in payload: JSONValue) -> String? {
        if let path = local(payload["image_path"]) {
            return path
        }
        var result = payload["result"]
        if let text = result?.string ?? payload["result_text"]?.string, let parsed = try? JSONValue.parse(text) {
            result = parsed
        }
        let name = payload["name"]?.string ?? ""
        var candidates = [result?["image_path"], result?["screenshot_path"],
                          result?["meta"]?["image_path"], result?["meta"]?["screenshot_path"]]
        if name == "image_generate" {
            candidates.insert(result?["image"], at: 0)
        }
        if name == "vision_analyze" {
            candidates.insert(payload["args"]?["image_url"], at: 0)
        }
        return candidates.lazy.compactMap { local($0) }.first
    }

    private static func local(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains("://"), !text.hasPrefix("data:"),
              text.hasPrefix("/") || text.hasPrefix("~/"), MediaKinds.isImage(text)
        else { return nil }
        return text
    }
}
