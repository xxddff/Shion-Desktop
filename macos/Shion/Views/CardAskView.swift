import SwiftUI

/// A board card on 「等你确认」: stopped on something only you can give it — an answer, a code, an
/// account. What you write goes on the card as a comment under your name; 「让它继续」 sends it
/// back to the queue, and its worker reads the comments first when it runs again.
struct CardAskView: View {
    @Environment(AppStore.self) private var store
    let ask: BoardAsk
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        let bot = ask.assignee.flatMap { store.bot($0) }
        Box {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Avatar(bot: bot, size: 22)
                    Text(bot?.name ?? ask.assignee ?? "").font(.t12.weight(.medium))
                    if let board = boardName {
                        Text(board).font(.t12).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let at = ask.ask.at {
                        Text(Fmt.hm(at)).font(.t12).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(ask.title).font(.t15)
                Text(reason)
                    .font(.t13)
                    .foregroundStyle(Palette.warm)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !ask.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ask.comments) { comment in
                            Text("\(store.boardAuthor(comment.author))：\(comment.body)")
                                .font(.t12)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("补充它需要的信息", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send(resume: true) }
                        .accessibilityIdentifier("card-ask-reply-\(ask.cardId)")
                    Button("回复") { send(resume: false) }
                        .disabled(trimmed.isEmpty || sending)
                        .accessibilityIdentifier("card-ask-send-\(ask.cardId)")
                    Button("让它继续") { send(resume: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending)
                        .accessibilityIdentifier("card-ask-resume-\(ask.cardId)")
                }
                // the last data, or the connection down: an answer waits for the server
                .disabled(store.readOnly)
                .padding(.top, 2)
                HStack(spacing: 8) {
                    Button("打开卡片") { store.openCard(ask.cardId, board: ask.board) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("card-ask-open-\(ask.cardId)")
                    if let failure {
                        Text(failure)
                            .font(.t12)
                            .foregroundStyle(Palette.alert)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-ask-\(ask.cardId)")
    }

    private var reason: String { ask.ask.words }

    /// The card's board, when the server has more than one.
    private var boardName: String? {
        guard store.board.active, store.board.boards.count > 1 else { return nil }
        return store.board.boardInfo(ask.board)?.name
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(resume: Bool) {
        let text = trimmed
        guard resume || !text.isEmpty, !sending else { return }
        sending = true
        failure = nil
        Task {
            if let refused = await store.answerCard(ask, text: text, resume: resume) {
                failure = refused
            } else {
                draft = ""
            }
            sending = false
        }
    }
}

/// A card waiting on your answer in 今天's 「需要你」: one line, and the way to 等你确认, where the
/// answer is written.
struct CardAskRow: View {
    @Environment(AppStore.self) private var store
    let ask: BoardAsk

    var body: some View {
        let bot = ask.assignee.flatMap { store.bot($0) }
        HStack(spacing: 10) {
            Avatar(bot: bot, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(ask.title).font(.t13.weight(.medium)).lineLimit(1)
                Text("\(bot?.name ?? ask.assignee ?? "") · \(ask.ask.words)")
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("去回复") { store.route = .confirm }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
    }
}
