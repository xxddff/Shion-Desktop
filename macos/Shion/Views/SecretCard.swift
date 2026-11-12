import SwiftUI

/// A password or a key an assistant asked for, in its chat and in 待你处理: who wants it, what for
/// (the tool and its command, or the skill and Hermes's prompt), the field, 提交 and 拒绝, and how
/// long Hermes still waits. Once answered, declined or expired, the field goes and the card says
/// which. What is typed is this view's state alone: it goes out once (AppStore.submitSecret) and the
/// field is cleared as it does, or when the request closes. The field has no content type, so the
/// Passwords app neither fills it nor offers to save what is typed; a saved password is pasted.
struct SecretCard: View {
    @Environment(AppStore.self) private var store
    let requestId: String
    @State private var value = ""

    var body: some View {
        if let request = store.secrets.request(requestId) {
            Box {
                VStack(alignment: .leading, spacing: 10) {
                    header(request)
                    title(request)
                    if let purpose = request.purpose {
                        Text(purpose)
                            .font(.t12)
                            .foregroundStyle(.secondary)
                    }
                    details(request)
                    if request.isOpen {
                        entry(request)
                    } else {
                        SecretOutcome(state: request.state)
                            .accessibilityIdentifier("secret-state-\(request.id)")
                    }
                }
                .padding(.vertical, 8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("secret-card-\(request.id)")
            // answered, declined or expired: the field goes, and whatever was left in it
            .onChange(of: request.isOpen) { _, open in
                if !open {
                    value = ""
                }
            }
        }
    }

    private func header(_ request: SecretRequest) -> some View {
        let bot = store.bot(request.botId)
        return HStack(spacing: 8) {
            Avatar(bot: bot, size: 22)
            Text(bot?.name ?? "").font(.t12.weight(.medium))
            Spacer()
            if request.isOpen, let deadline = request.deadline {
                SecretCountdown(deadline: deadline, now: request.demo ? store.demoClock : nil)
                    .accessibilityIdentifier("secret-left-\(request.id)")
            } else {
                Text(Fmt.hm(request.at)).font(.t12).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    /// 要 sudo 密码 / 要 NOTION_API_KEY: the variable's name as it is, so you know what you hand over.
    @ViewBuilder
    private func title(_ request: SecretRequest) -> some View {
        if request.kind == .key && !request.envVar.isEmpty {
            Text("要 \(Text(request.envVar).font(.system(size: 15, weight: .semibold, design: .monospaced)))")
                .font(.t15)
                .textSelection(.enabled)
        } else {
            Text(request.asking).font(.t15)
        }
    }

    /// The command the password is for, or Hermes's prompt for the key and where to get one.
    @ViewBuilder
    private func details(_ request: SecretRequest) -> some View {
        switch request.kind {
        case .password:
            if !request.command.isEmpty {
                Text(request.command)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .key:
            if !request.prompt.isEmpty {
                Text(request.prompt)
                    .font(.t13)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let help = request.help {
                if let url = URL(string: help), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Link(help, destination: url).font(.t12)
                } else {
                    Text(help).font(.t12).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    /// The field and the two answers, while it waits.
    @ViewBuilder
    private func entry(_ request: SecretRequest) -> some View {
        let answerable = store.canAnswer(request)
        let waiting = request.state == .waiting
        HStack(spacing: 8) {
            SecureField(placeholder(request), text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.t13)
                .disabled(!answerable || !waiting)
                .onSubmit { submit(request) }
                .accessibilityLabel(placeholder(request))
                .accessibilityIdentifier("secret-field-\(request.id)")
            Button("提交") { submit(request) }
                .buttonStyle(.borderedProminent)
                .disabled(value.isEmpty || !answerable || !waiting)
                .accessibilityIdentifier("secret-submit-\(request.id)")
            Button("拒绝") {
                value = ""
                store.declineSecret(request.id)
            }
            .disabled(!answerable || !waiting)
            .accessibilityIdentifier("secret-deny-\(request.id)")
        }
        .padding(.top, 2)
        if let problem = request.problem {
            Text("没发出去：\(problem)")
                .font(.t12)
                .foregroundStyle(Palette.alert)
                .fixedSize(horizontal: false, vertical: true)
        } else if !answerable {
            // back online, the chat not attached again yet: its resume says whether this still waits
            let phase = store.gateway.phase
            Text(phase == .online || phase == .connecting || store.reconnecting ? "连接中…" : "未连接服务器")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ request: SecretRequest) -> String {
        switch request.kind {
        case .password: return "sudo 密码"
        case .key: return request.envVar.isEmpty ? "密钥" : request.envVar
        }
    }

    /// Hands what was typed to the store and empties the field at once, whether or not it goes out.
    private func submit(_ request: SecretRequest) {
        guard !value.isEmpty, request.state == .waiting, store.canAnswer(request) else { return }
        let typed = value
        value = ""
        Task { await store.submitSecret(request.id, value: typed) }
    }
}

/// How long Hermes still waits: a minute-and-seconds count, every second (on the demo's clock in
/// screenshots, still).
struct SecretCountdown: View {
    let deadline: Date
    /// The screenshots' pinned moment; nil for the real time.
    let now: Date?

    var body: some View {
        if let now {
            label(deadline.timeIntervalSince(now))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                label(deadline.timeIntervalSince(context.date))
            }
        }
    }

    private func label(_ left: TimeInterval) -> some View {
        let total = max(0, Int(left.rounded(.up)))
        let minutes = total / 60, seconds = total % 60
        let clock = "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
        return Text("还剩 " + clock)
            .font(.t12)
            .monospacedDigit()
            .foregroundStyle(Palette.warm)
            .accessibilityLabel("还剩 \(minutes) 分 \(seconds) 秒")
    }
}

/// What was asked in a chat, where it was asked (ChatRow, the ⌥Space window): a password or a key
/// still waiting is its card; anything over, answered or not, is one line saying what became of it.
struct AskTrailCard: View {
    @Environment(AppStore.self) private var store
    let askId: String

    var body: some View {
        if let request = store.secrets.request(askId) {
            if request.isOpen {
                SecretCard(requestId: askId)
            } else {
                AskLine(id: askId, symbol: request.kind == .password ? "lock" : "key",
                        title: request.asking, outcome: SecretOutcome.words(request.state))
            }
        } else if let answered = store.trail.answer(askId) {
            AskLine(id: askId, symbol: answered.kind == .approval ? "hand.raised" : "questionmark.bubble",
                    title: answered.title, outcome: answered.outcome)
        }
    }
}

/// One line for an ask that is over: what it was, then what became of it (已允许这一次, 你回答：…,
/// 已提交). Never a value typed for a password or a key: only that it went.
struct AskLine: View {
    let id: String
    let symbol: String
    let title: String
    let outcome: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(outcome)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("ask-outcome-\(id)")
            Spacer(minLength: 0)
        }
        .font(.t12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask-line-\(id)")
    }
}

/// What became of a request once it is over.
struct SecretOutcome: View {
    let state: SecretRequest.State

    var body: some View {
        if state == .sent {
            Label(Self.words(state), systemImage: "checkmark").font(.t12).foregroundStyle(.secondary)
        } else if !Self.words(state).isEmpty {
            Text(Self.words(state)).font(.t12).foregroundStyle(.secondary)
        }
    }

    /// 已提交, 已拒绝, 已过期, 在别处回答了; nothing while it waits.
    static func words(_ state: SecretRequest.State) -> String {
        switch state {
        case .sent: return "已提交"
        case .declined: return "已拒绝"
        case .expired: return "已过期"
        case .elsewhere: return "在别处回答了"
        case .waiting, .sending: return ""
        }
    }
}

/// A request in a one-line list (今天's 「需要你」, the ⌥Space window): 填写 opens its card in the
/// chat, where the field is; 拒绝 answers no from here.
struct SecretAskRow: View {
    @Environment(AppStore.self) private var store
    let ask: Ask

    var body: some View {
        let request = store.secrets.request(ask.id)
        HStack(spacing: 10) {
            Avatar(bot: store.bot(ask.botId), size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(request?.asking ?? ask.title).font(.t13.weight(.medium)).lineLimit(1)
                Text("\(store.bot(ask.botId)?.name ?? "") · \(Fmt.hm(ask.at))")
                    .font(.t12)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("填写") { store.openSecret(ask.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("secret-open-\(ask.id)")
            Button("拒绝") { store.declineSecret(ask.id) }
                .controlSize(.small)
                .disabled(request.map { !store.canAnswer($0) || $0.state != .waiting } ?? true)
        }
        .padding(.vertical, 8)
    }
}
