import Foundation

extension DemoData {
    /// The failed turn's screenshot (`-ShionFailureDemo YES`): a question, a tool call, and the line
    /// a provider's rate limit leaves, read from a frame shaped as the session gateway sends it
    /// (Hermes's copy in `text`, then its notice for a turn that called tools).
    var failedTurn: [ChatItem] {
        let payload: JSONValue = [
            "text": .string("OpenRouter rate-limited every one of 3 attempts — it looks temporarily unavailable. "
                + "Wait a minute and send /retry, or switch models with /model. To avoid this in future, add a "
                + "backup provider with `hermes fallback add`.\n\nProvider said: 429 Too Many Requests: rate limit "
                + "exceeded\n\n" + TurnFailure.Notice.partial.rawValue),
            "status": "error",
            "outcome": "failed",
            "error_surface": ["layer": "provider", "code": "rate_limit", "retryable": true, "provider": "openrouter",
                              "model": "anthropic/claude-sonnet-4.5", "provider_label": "OpenRouter"],
        ]
        let failure = TurnFailure.live(payload, streamed: "")
        return [
            ChatItem(id: "f1", role: .user, at: at(0, 10, 52), text: "把这周的作业整理成卡片"),
            ChatItem(id: "f2", role: .tool, at: at(0, 10, 52), text: "web_search · 这周的作业"),
            ChatItem(id: "f3", role: .system, at: at(0, 10, 52), text: failure.line, failure: failure),
        ]
    }
}
