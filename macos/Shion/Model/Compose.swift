import Foundation

/// How a message sent while the assistant is in the middle of a turn reaches it: the three ways
/// Hermes's own clients have (`display.busy_input_mode`), by the same calls
/// (ui-tui/src/app/useSubmission.ts). Foundation only, so it can be checked away from a Mac.
nonisolated enum BusyMode: String, CaseIterable, Identifiable, Sendable {
    /// It waits: a turn of its own once this one ends (`prompt.submit`, which Hermes queues
    /// behind the running turn and never lets cut it short).
    case queue
    /// It is put before the assistant in this turn, at its next step; nothing stops
    /// (`session.steer`).
    case steer
    /// The turn turns to it now, keeping what it had worked out (`session.redirect`).
    case interrupt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .queue: return "排队"
        case .steer: return "引导"
        case .interrupt: return "打断"
        }
    }

    /// What becomes of the message, after 「这句话」.
    var explanation: String {
        switch self {
        case .queue: return "等这一轮做完再处理"
        case .steer: return "不打断，在这一轮的下一步带上"
        case .interrupt: return "让这一轮马上转过来处理"
        }
    }

    /// The call that puts a message into the running turn; none for a message that waits.
    var correction: String? {
        switch self {
        case .queue: return nil
        case .steer: return "session.steer"
        case .interrupt: return "session.redirect"
        }
    }

    private static let key = "ShionBusyMode"

    /// The way chosen last, on this Mac. Screenshot and test runs start from 排队 and keep nothing.
    @MainActor static var saved: BusyMode {
        guard !LaunchOptions.current.snapshot else { return .queue }
        return UserDefaults.standard.string(forKey: key).flatMap(BusyMode.init(rawValue:)) ?? .queue
    }

    @MainActor func save() {
        guard !LaunchOptions.current.snapshot else { return }
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}

/// A message put into a running turn that did not get there for sure.
nonisolated enum CorrectionError: Error {
    /// The connection went before Hermes answered: it may have reached the assistant, and there is
    /// no receipt to ask for afterwards (a correction is not a submission).
    case unconfirmed
    /// Hermes answered that the assistant did not take it, without saying it never saw it.
    case refused
}

/// The message a reply answers: over the composer until the reply goes, or the mark is taken off.
nonisolated struct ReplyTarget: Hashable, Sendable {
    let id: String
    let text: String
    /// The assistant's message, not one of your own.
    let theirs: Bool
}

/// A reply to one message, worded as Hermes words every reply on its messaging platforms
/// (gateway/run_inbound.py: `[Replying to: "…"]`, a blank line, then the message), so the
/// assistant reads it as it reads a reply on Telegram, and Hermes's own summarizer knows the
/// marker. Read back from a message's words, it shows as a quote over them.
nonisolated enum ReplyQuote {
    private static let toTheirs = "[Replying to your previous message: \""
    private static let toYours = "[Replying to: \""
    private static let close = "\"]\n\n"
    /// Hermes quotes a message whole (a preview loses the list or the code that was meant); this
    /// only keeps one enormous message from being sent twice over.
    static let limit = 8000

    static func wrap(_ words: String, replyingTo target: ReplyTarget) -> String {
        var quoted = target.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if quoted.count > limit {
            quoted = String(quoted.prefix(limit)) + "…"
        }
        return (target.theirs ? toTheirs : toYours) + quoted + close + words
    }

    /// The quote and the words of a message sent as a reply; any other message is all words.
    static func split(_ text: String) -> (quote: String?, theirs: Bool, words: String) {
        for (open, theirs) in [(toTheirs, true), (toYours, false)] where text.hasPrefix(open) {
            let rest = text.dropFirst(open.count)
            guard let end = rest.range(of: close) else { break }
            return (String(rest[..<end.lowerBound]), theirs, String(rest[end.upperBound...]))
        }
        return (nil, false, text)
    }
}
