import Foundation

/// Why Hermes ended a turn with an error, as a chat line says it: a short title by
/// `error_surface.code` and what to do, both Shion's words (their sense follows the official
/// desktop app's table, apps/desktop/src/i18n/zh_error_codes.ts), with Hermes's own text kept for
/// 详情. A code Shion has no words for shows Hermes's text as it came.
///
/// The same failure reads the same live (`message.complete`, status error) and from the transcript
/// (the assistant row Hermes closes the turn with, `display_kind` failed_turn): both carry the
/// `error_surface`. Live, the session gateway sends no `error`; its `text` is Hermes's copy of the
/// failure, with one of the notices below after a blank line (gateway/run_turn.py
/// `_hmwa_add_failed_turn_notice`). In the transcript the notice is the row's text and the raw
/// error is `display_metadata.error`.
nonisolated struct TurnFailure: Hashable, Codable, Sendable {
    var title: String
    /// What to do, a sentence or two; nil when there is nothing to add.
    var advice: String?
    /// Hermes's own words, for 详情: the live `text` (or the TUI gateway's `error`), the transcript's
    /// `display_metadata.error`. Nil when the title already is them.
    var detail: String?
    /// Hermes says trying again may help (`error_surface.retryable`).
    var retryable: Bool
    /// Hermes says some of the turn's actions may already have run (its notice).
    var actionsMayHaveRun: Bool

    /// The chat line, and what a notification says.
    var line: String { "这一轮出错了：\(title)" }

    /// Hermes's three fixed notices for a turn that ended without its reply
    /// (agent/turn_failure_copy.py): the gateway picks `partial` when the turn had tool calls.
    enum Notice: String, CaseIterable {
        case failed = "Your request was not processed. Send it again if you still want me to carry it out."
        case partial = "This turn did not complete. Some actions may already have run; verify their effects before resending."
        case automation = "An automated delivery was interrupted and was not run again. Some actions may already have run; verify their effects."

        var words: String {
            switch self {
            case .failed: "这次没有处理，还要做的话再发一次。"
            case .partial: "这一轮没做完，有些操作可能已经执行了，重发前先核实。"
            case .automation: "一次自动投递被打断了，没有再跑；有些操作可能已经执行了，先核实。"
            }
        }

        var actionsMayHaveRun: Bool { self != .failed }

        /// The notice `text` ends with, and what comes before it.
        static func split(_ text: String) -> (body: String, notice: Notice?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for notice in allCases where trimmed.hasSuffix(notice.rawValue) {
                let body = trimmed.dropLast(notice.rawValue.count)
                return (body.trimmingCharacters(in: .whitespacesAndNewlines), notice)
            }
            return (trimmed, nil)
        }
    }

    // MARK: reading Hermes

    /// A live `message.complete` with status error. `streamed` is the reply that had come, which a
    /// `text` repeating it (or `partial`) is, rather than words about the failure.
    static func live(_ payload: JSONValue, streamed: String) -> TurnFailure {
        let (body, notice) = Notice.split(payload["text"]?.string ?? "")
        let isReply = payload["partial"]?.bool == true
            || (!body.isEmpty && body == streamed.trimmingCharacters(in: .whitespacesAndNewlines))
        let raw = said(payload["error"]) ?? (isReply ? nil : said(.string(body)))
        return make(surface: payload["error_surface"], raw: raw, notice: notice, reason: said(payload["failure_reason"]))
    }

    /// The transcript's row closing a failed turn: `body` is its text (a notice).
    static func stored(_ row: JSONValue, body: String) -> TurnFailure {
        let metadata = row["display_metadata"]
        let (rest, notice) = Notice.split(body)
        let raw = said(metadata?["error"]) ?? (notice == nil ? said(.string(rest)) : nil)
        return make(surface: metadata?["error_surface"], raw: raw, notice: notice, reason: nil)
    }

    private static func make(surface: JSONValue?, raw: String?, notice: Notice?, reason: String?) -> TurnFailure {
        let retryable = surface?["retryable"]?.bool == true
        let mayHaveRun = notice?.actionsMayHaveRun ?? false
        let warning = mayHaveRun ? notice?.words : nil
        if let words = copy(surface, code: said(surface?["code"]) ?? reason) {
            let advice = [words.advice, warning].compactMap { $0 }.joined(separator: "\n")
            return TurnFailure(title: words.title, advice: advice.isEmpty ? nil : advice, detail: raw,
                               retryable: retryable, actionsMayHaveRun: mayHaveRun)
        }
        // no words for this code: Hermes's own, as they came
        if let raw {
            return TurnFailure(title: raw, advice: notice?.words, detail: nil, retryable: retryable,
                               actionsMayHaveRun: mayHaveRun)
        }
        let title = reason ?? notice.map { String($0.words.dropLast()) } ?? "没有说明"
        return TurnFailure(title: title, advice: reason == nil ? nil : notice?.words, detail: nil,
                           retryable: retryable, actionsMayHaveRun: mayHaveRun)
    }

    private static func said(_ value: JSONValue?) -> String? {
        let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: Shion's words

    /// Title and what to do for the codes Hermes stamps (agent/error_classifier.py FailoverReason,
    /// the loop's site codes, the gateway's), naming the provider and model the surface carries.
    /// Keys and accounts live on the server, so that is where the fixes point.
    static func copy(_ surface: JSONValue?, code: String?, now: Date = Date()) -> (title: String, advice: String?)? {
        guard let code else { return nil }
        let p = said(surface?["provider_label"]) ?? said(surface?["provider"]) ?? "模型服务"
        let m = said(surface?["model"]).map { model in
            model.split(separator: "/").last.map(String.init) ?? model
        } ?? "这个模型"
        guard let words = words(code, p, m, surface, now: now) else { return nil }
        // the Chinese stand-ins for a provider or model with no name sit in a sentence without spaces
        func tidy(_ text: String) -> String {
            ["模型服务", "这个模型"].reduce(text) { text, word in
                text.replacingOccurrences(of: " \(word)", with: word).replacingOccurrences(of: "\(word) ", with: word)
            }
        }
        return (tidy(words.title), words.advice.map(tidy))
    }

    private static func words(_ code: String, _ p: String, _ m: String, _ surface: JSONValue?,
                              now: Date) -> (title: String, advice: String?)? {
        let endpoint = surface?["layer"]?.string == "endpoint"
        switch code {
        case "auth", "auth_permanent":
            if surface?["auth_kind"]?.string == "oauth" {
                return ("\(p) 的登录失效了", "在服务器上重新登录 \(p)，再发一次。")
            }
            return ("\(p) 不认这个 API 密钥", "在服务器上换一个有效的密钥，再发一次。")
        case "billing", "billing_unverified":
            return ("\(p) 的额度用完了", "充值，或者换一个模型。")
        case "usage_window":
            return ("套餐里的用量用完了", said(surface?["message"]) ?? "等用量重置，或者加额度。")
        case "rate_limit":
            return ("\(p) 那边请求太多了", resetAdvice(surface, now: now) ?? "等一会儿再试。")
        case "upstream_rate_limit":
            return ("\(m) 现在太忙", "是 \(p) 的上游在限流，和你的账户无关。等一会儿再试。")
        case "overloaded":
            return ("\(p) 现在太忙", "等一会儿再试。")
        case "server_error":
            return ("\(p) 出了问题", "它那边报了错，等一会儿再试。")
        case "timeout" where endpoint, "ssl_cert_verification" where endpoint:
            return ("连不上你配的模型服务器", "确认它在运行、地址和证书没问题，再试。")
        case "timeout":
            return ("连不上 \(p)", "查一下服务器的网络，再试。")
        case "ssl_cert_verification":
            return ("\(p) 的证书验证不过", "服务器上的代理或证书有问题，修好再试。")
        case "stream_drop":
            return ("回复传到一半断了", "再试一次。")
        case "upstream_blocked":
            return ("\(p) 前面的防火墙拦下了请求", "换一个服务商，或者给它设自定义 User-Agent。")
        case "context_overflow":
            return ("这段对话太长了", "超出了 \(m) 能读的长度：先压缩对话（/compress），再继续。")
        case "payload_too_large":
            return ("这条消息太大了", "超出了 \(p) 的大小限制：压缩对话，或者去掉附件。")
        case "model_not_found":
            return ("\(m) 用不了", "\(p) 的账户上没有这个模型，换一个。")
        case "provider_policy_blocked":
            return ("\(p) 的设置挡住了 \(m)", "改一下 \(p) 上的隐私设置，或者换一个模型。")
        case "content_policy_blocked":
            return ("\(p) 拒绝了这条消息", "它的安全过滤没让过：改一改再发。")
        case "format_error":
            return ("\(p) 不接受这个请求", "换一个服务商再试。")
        case "truncated":
            return ("回复没说完就断了", "发「继续」让它接着说。")
        case "invalid_response":
            return ("回复读不出来", "\(p) 回了空的或坏的内容，等一会儿再试。")
        case "empty_response":
            return ("没有收到回复", "\(p) 这次什么也没回，等一会儿再试。")
        case "loop_error":
            return ("Hermes 没能做完这一步", "再试一次；还不行就看看服务器上的日志。")
        case "agent_init_failed":
            return ("这一轮没能开始", "Hermes 连不上 \(p)：再试；还不行就查一下服务器上这个服务商的设置。")
        case "disk_full":
            return ("服务器的磁盘满了", "Hermes 存不下这段对话：腾出空间再试。")
        case "local_runtime_unavailable":
            return ("连不上本地模型服务器", surface?["retryable"]?.bool == false
                ? "它没在运行：在服务器上启动它，或者换一个模型。"
                : "它可能还在启动：等一会儿再试，或者换一个模型。")
        case "SESSION_OWNER_BUSY", "session_busy":
            return ("这个对话正忙", "等这一轮结束再发。")
        default:
            return nil
        }
    }

    /// A rate limit whose reset the provider named (`resets_at`, epoch seconds), still ahead.
    private static func resetAdvice(_ surface: JSONValue?, now: Date) -> String? {
        guard let seconds = surface?["resets_at"]?.number else { return nil }
        let reset = Date(timeIntervalSince1970: seconds)
        guard reset > now else { return nil }
        let format = DateFormatter()
        format.dateFormat = Calendar.current.isDate(reset, inSameDayAs: now) ? "HH:mm" : "M 月 d 日 HH:mm"
        return "限额 \(format.string(from: reset)) 重置，到时再试。"
    }
}
