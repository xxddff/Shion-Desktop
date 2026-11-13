import SwiftUI

/// A skill an assistant wrote or changed by itself, in its chat and in 待你处理: whose, what was
/// done, and where it stands. 审核 opens a session to talk it over; 批准 writes the decision
/// down; 拒绝 takes the change back, after saying what that does.
struct SkillReviewCard: View {
    @Environment(AppStore.self) private var store
    let review: SkillReview
    /// Not inside the talk itself.
    var talks = true
    @State private var working = false
    @State private var failure: String?
    @State private var rejecting = false

    var body: some View {
        let bot = store.bot(review.profile)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "graduationcap").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.skill).font(.t13.weight(.medium)).lineLimit(1)
                    Text("\(bot?.name ?? review.profile)\(review.change)").font(.t12).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(review.state)
                    .font(.t12.weight(review.status == .pending ? .medium : .regular))
                    .foregroundStyle(review.status == .pending ? Palette.warm : Color.secondary)
                    .accessibilityIdentifier("skill-review-state-\(review.id)")
            }
            HStack(spacing: 8) {
                if talks {
                    Button("审核") { store.openReview(review) }
                        .accessibilityIdentifier("skill-review-open-\(review.id)")
                }
                if review.status == .pending {
                    Button("批准") { decide(.approved) }
                        .help("记下你认可这次变更；技能不动")
                        .accessibilityIdentifier("skill-review-approve-\(review.id)")
                    Button("拒绝") { rejecting = true }
                        .accessibilityIdentifier("skill-review-reject-\(review.id)")
                }
                if working {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
            // the last data, or the connection down: a decision waits for the server
            .disabled(store.readOnly || working)
            if let failure {
                Text(failure)
                    .font(.t12)
                    .foregroundStyle(Palette.alert)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("skill-review-failure")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .confirmationDialog("拒绝「\(review.skill)」的这次变更？", isPresented: $rejecting, titleVisibility: .visible) {
            Button("拒绝并撤销", role: .destructive) { decide(.rejected) }
                .accessibilityIdentifier("skill-review-reject-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text(review.undoing + "技能在那之后又被改过的话，不会动它。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-review-\(review.id)")
    }

    private func decide(_ decision: SkillReview.Status) {
        working = true
        failure = nil
        Task {
            failure = await store.decide(review, decision)
            working = false
        }
    }
}

/// The talk about one skill: its card, what was said, and a composer. The first message is what
/// the assistant was given to review with, folded away. A message of yours stays where you said
/// it: one Hermes did not take says so under it, with 重发 (SkillReviewTalk.resend); a turn that
/// failed, or a session that would not open, says so over the composer, with 再试一次
/// (SkillReviewTalk.retry).
struct SkillReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var talk: SkillReviewTalk

    var body: some View {
        let bot = store.bot(talk.review.profile)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("审核技能").font(.t15.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("skill-review-close")
            }
            SkillReviewCard(review: store.skillReview(talk.review.id) ?? talk.review, talks: false)
            Text("这是单独的一个会话，不在\(bot?.name ?? "助手")的对话里；它在这里没有工具，改不了技能和记忆。")
                .font(.t12)
                .foregroundStyle(.secondary)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(talk.items) { item in
                            row(item, bot: bot).id(item.id)
                        }
                        if talk.opening || talk.retrying || (talk.busy && talk.items.last?.streaming != true) {
                            BusyDots().id("busy")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .onChange(of: talk.items.last?.text) {
                    if let last = talk.items.last {
                        reader.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // what a message says under it (没发出去, 重发) is part of its row: in view too
                .onChange(of: talk.sent) {
                    if let last = talk.items.last {
                        reader.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let failure = talk.failure {
                HStack(spacing: 8) {
                    Text(failure)
                        .font(.t12)
                        .foregroundStyle(Palette.alert)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    // what went wrong stays said until the new try has begun (SkillReviewTalk.retry)
                    Button("再试一次") {
                        Task { await talk.retry(in: store) }
                    }
                    .controlSize(.small)
                    .disabled(talk.opening || talk.retrying || talk.busy || store.readOnly)
                    .accessibilityIdentifier("skill-review-talk-retry")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("skill-review-talk-failure")
            }
            Composer(placeholder: "和\(bot?.name ?? "助手")讨论这个技能…", text: $talk.draft,
                     // not before the session is there: what is typed stays typed (SkillReviewTalk.send)
                     canSend: talk.ready && !talk.busy && !talk.opening && !talk.retrying
                        && !talk.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                     send: { Task { await talk.send(in: store) } })
                .disabled(store.readOnly)
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 680)
        // the connection came back: the session's rows again, and its events on the new socket
        .task(id: store.gateway.phase == .online) {
            guard store.gateway.phase == .online, !talk.opening else { return }
            try? await talk.read(in: store)
        }
        // a container of its own: without it the name lands on everything inside, over their own
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-review-sheet")
    }

    @ViewBuilder
    private func row(_ item: ChatItem, bot: Bot?) -> some View {
        if talk.isMaterial(item) {
            VStack(alignment: .leading, spacing: 4) {
                DisclosureGroup("给\(bot?.name ?? "助手")的审核资料：写入前的对话、这次变更、技能现在的内容") {
                    Text(item.text)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.t12)
                .accessibilityIdentifier("skill-review-material")
                delivery(of: item)
            }
        } else if item.role == .user {
            let waits = talk.sent[item.id].map { $0 != .sending } ?? false
            VStack(alignment: .trailing, spacing: 4) {
                UserMessage(item: item)
                    .opacity(waits ? 0.55 : 1)
                delivery(of: item)
            }
        } else if item.streaming {
            Text(item.text).font(.t13).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(bot?.name ?? "").font(.t12.weight(.semibold))
                MarkdownView(blocks: MarkdownCache.shared.document(item.id, item.text).blocks)
                    .textSelection(.enabled)
            }
        }
    }

    /// Under a message of yours Hermes has not said it has, as a Bot Chat says it (DeliveryMark):
    /// not known yet (no answer came: the session is asked, at once or when the connection is
    /// back), or 没发出去 with 重发, which sends the same message again under its id. Nothing
    /// under one on its way or there.
    @ViewBuilder
    private func delivery(of item: ChatItem) -> some View {
        switch talk.sent[item.id] {
        case .unsent(let reason)?:
            HStack(spacing: 10) {
                Label {
                    Text(reason.map { "没发出去：\($0)" } ?? "没发出去")
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Palette.alert)
                }
                .accessibilityIdentifier("review-unsent")
                Button {
                    Task { await talk.resend(item.id, in: store) }
                } label: {
                    Label("重发", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.readOnly || talk.busy || talk.opening || talk.retrying)
                .accessibilityIdentifier("review-resend")
            }
            .font(.t12)
            .foregroundStyle(.secondary)
        case .unsure?, .unconfirmed?:
            Label(store.gateway.phase == .online ? "正在向服务器确认有没有送到" : "等连上后确认", systemImage: "clock")
                .font(.t12)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review-unsure")
        default:
            EmptyView()
        }
    }
}
