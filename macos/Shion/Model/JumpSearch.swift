import Foundation

/// One thing ⌘K can go to, and the words it is found by. Foundation only, so the matching can be
/// checked away from a Mac.
struct JumpCandidate: Identifiable, Equatable {
    /// In the order the palette lists them; `ask` is the line that hands the words to 总秘书.
    enum Group: Int, CaseIterable {
        case page, assistant, todo, ask
    }

    let id: String
    let group: Group
    let title: String
    /// Other words it answers to: a page's route name, an assistant's profile and title.
    var keywords: [String] = []
}

enum JumpSearch {
    /// A search lists at most this many todos.
    static let todoLimit = 6

    /// With nothing typed: the pages and the assistants. Otherwise what matches, a group at a time
    /// in palette order, best first: a title that starts with the words, then a title that has
    /// them, then one found by its other words; ties keep the order they came in.
    static func results(_ candidates: [JumpCandidate], query: String) -> [JumpCandidate] {
        let words = normalized(query)
        guard !words.isEmpty else {
            return candidates.filter { $0.group == .page || $0.group == .assistant }
        }
        var found: [JumpCandidate] = []
        for group in JumpCandidate.Group.allCases {
            let ranked = candidates.enumerated()
                .compactMap { index, candidate -> (rank: Int, index: Int, candidate: JumpCandidate)? in
                    guard candidate.group == group, let rank = rank(candidate, words) else { return nil }
                    return (rank, index, candidate)
                }
                .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
                .map(\.candidate)
            found += group == .todo ? Array(ranked.prefix(todoLimit)) : ranked
        }
        return found
    }

    /// 0: the title starts with the words; 1: the title has them; 2: another of its words has
    /// them; nil: no match. `words` is already normalized.
    static func rank(_ candidate: JumpCandidate, _ words: String) -> Int? {
        let title = normalized(candidate.title)
        if title.hasPrefix(words) { return 0 }
        if title.contains(words) { return 1 }
        if candidate.keywords.contains(where: { normalized($0).contains(words) }) { return 2 }
        return nil
    }

    /// Case, width (full-width letters from an input method) and accents do not count, and
    /// neither do spaces at either end.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }
}
