import Foundation

/// An assistant's "nothing to say": a reply that is only a marker such as `[SILENT]`. Hermes asks
/// for it where a turn may have nothing for you (a board notice, a focus check, a cron job) and
/// keeps it off its messaging platforms; the rules here are its own, marker for marker
/// (gateway/response_filters.py), so a chat shows what Telegram would. A reply that only mentions
/// a marker is a reply. Foundation only, so it can be checked away from a Mac.
nonisolated enum Silence {
    /// Whole-reply markers, as Hermes lists them (the Chinese forms because a model answering in
    /// Chinese translates the marker).
    static let markers: Set<String> = [
        "[SILENT]", "SILENT", "NO_REPLY", "NO REPLY",
        "[静默]", "静默", "[沉默]", "沉默",
    ]

    /// Longer than any marker could be, stray punctuation included.
    private static let cap = 64

    /// Whether the whole reply is a marker: nothing to show, and nothing to notify about.
    static func isMarker(_ reply: String) -> Bool {
        candidates(reply).contains { markers.contains($0) }
    }

    /// Whether a reply still arriving could turn out to be a marker: until it cannot, it is held
    /// back, so that a marker is never shown and then taken away.
    static func mayBecomeMarker(_ partial: String) -> Bool {
        candidates(partial).contains { candidate in
            !candidate.isEmpty && markers.contains { $0.hasPrefix(candidate) }
        }
    }

    /// A reply without the marker that closes it on a line of its own ("…the answer.\n\nNO_REPLY":
    /// the model answered, then also said it had nothing to add). A reply that is only a marker
    /// comes back as it is: that is `isMarker`'s to say.
    static func withoutClosingMarker(_ reply: String) -> String {
        let trimmed = reply.replacing(#/\s+$/#, with: "")
        guard let lineBreak = trimmed.lastIndex(of: "\n") else { return reply }
        let head = trimmed[..<lineBreak].replacing(#/\s+$/#, with: "")
        let last = String(trimmed[trimmed.index(after: lineBreak)...])
        return !head.isEmpty && isMarker(last) ? String(head) : reply
    }

    /// The reply as it is compared with the markers: upper case, runs of blank space as one, and
    /// the same again without punctuation at its ends (".NO_REPLY", "*NO_REPLY*", "静默。").
    /// Square brackets stay: they are part of a marker. Nothing for a reply too long to be one.
    private static func candidates(_ reply: String) -> [String] {
        let stripped = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, stripped.count <= cap else { return [] }
        let bare = stripped.trimmingCharacters(in: edgePunctuation).trimmingCharacters(in: .whitespacesAndNewlines)
        return (bare == stripped ? [stripped] : [stripped, bare]).map { form in
            form.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private static let edgePunctuation = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "[]"))
}
