import SwiftUI

struct SkillReviewCard: View {
    @Environment(AppStore.self) private var store
    let review: SkillReview
    @State private var rejecting = false
    var body: some View {
        Box {
            VStack(alignment: .leading, spacing: 10) {
                Label("技能沉淀 · " + review.skill, systemImage: "books.vertical").font(.t15)
                Text("\(store.bot(review.profile)?.name ?? review.profile) · \(review.statusLabel)")
                    .font(.t12).foregroundStyle(.secondary)
                HStack {
                    Button("审核") { store.openReview(review) }.accessibilityIdentifier("review-open-" + review.id)
                    if review.status == "pending" {
                        Button("批准") { Task { await store.decideReview(review, decision: "approved") } }
                            .help("记录批准这次变更，不会恢复旧版本或覆盖后续修改")
                            .accessibilityIdentifier("review-approve-" + review.id)
                        Button("拒绝", role: .destructive) { rejecting = true }
                    }
                    if store.reviewBusy.contains(review.id) { ProgressView().controlSize(.small) }
                }
                .disabled(store.readOnly || store.reviewBusy.contains(review.id))
                if let error = store.reviewErrors[review.id] {
                    Text(error).font(.t12).foregroundStyle(Palette.alert).textSelection(.enabled)
                }
            }.padding(.vertical, 6)
        }
        .confirmationDialog("拒绝这次技能变更？", isPresented: $rejecting, titleVisibility: .visible) {
            Button("拒绝并撤销", role: .destructive) { Task { await store.decideReview(review, decision: "rejected") } }
        } message: {
            Text("新增技能会归档，已有技能会恢复到这次变更之前。若已经有后续修改，操作会被阻止。")
        }
    }
}

struct EventCard: View {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    var body: some View {
        Box {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: item.eventKind == "memory" ? "brain" : "bell.badge").font(.t13.weight(.medium))
                if kind == "board" {
                    ForEach(Array(AppStore.kanbanNotices(item.text).enumerated()), id: \.offset) { _, notice in
                        let reference = ChatItem(id: item.id, role: .card, at: item.at, cardId: notice.taskId, cardAssignee: notice.assignee)
                        if let found = store.chatCard(reference) {
                            CardChip(card: found.card, showsStatus: found.known)
                        }
                        Text(boardText(notice.line)).font(.t13).textSelection(.enabled)
                    }
                } else {
                    Text(item.text).font(.t13).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text(Fmt.hm(item.at)).font(.t11).foregroundStyle(.secondary)
            }.padding(.vertical, 5)
        }
    }
    private var kind: String { item.eventKind ?? (item.cardId == nil ? "review.summary" : "board") }
    private func boardText(_ line: String) -> String {
        let parts = line.components(separatedBy: " — ")
        let head = parts.first ?? ""
        let state = head.contains(" done") ? "已完成" : head.contains(" review") ? "待验收" : head.contains(" blocked") ? "任务受阻" : "任务进展"
        return parts.count > 1 ? state + "：" + parts.dropFirst().joined(separator: " — ") : state
    }
    private var title: String {
        switch kind {
        case "memory": "记忆更新 · 已生效"
        case "board": "看板进展"
        case "peer": "助手消息"
        case "process": "任务通知"
        default: "自动沉淀摘要"
        }
    }
}

struct ReviewConversationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var conversation: ReviewConversation
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("审核技能 · " + conversation.title).font(.title3)
                Spacer()
                Button("关闭") { dismiss() }.accessibilityIdentifier("review-close")
            }
            Text("独立审核会话 · 本会话关闭自动沉淀 · 不改变其他会话的设置")
                .font(.t12).foregroundStyle(.secondary)
            if let review = store.skillReviews.first(where: { $0.id == conversation.id }) {
                SkillReviewCard(review: review)
            }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(conversation.items.filter(ChatPresentation.visible)) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.role == .user ? "你" : "审核助手").font(.t12).foregroundStyle(.secondary)
                                if item.id.hasPrefix("shion-review-initial-") || (item.role == .user && item.text.hasPrefix("请审核技能「")) {
                                    DisclosureGroup("审核资料（来源上下文与技能变更）") { Text(item.text).textSelection(.enabled) }
                                } else {
                                    Text(item.text).textSelection(.enabled)
                                }
                            }.id(item.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: conversation.items.last?.text) {
                    if let id = conversation.items.last?.id { reader.scrollTo(id, anchor: .bottom) }
                }
            }
            if conversation.opening || conversation.busy { ProgressView().controlSize(.small) }
            if let error = conversation.error {
                HStack {
                    Text(error).font(.t12).foregroundStyle(Palette.alert).textSelection(.enabled)
                    Button("重新加载") { Task { await conversation.open(using: store) } }.disabled(conversation.opening)
                }
            }
            Composer(placeholder: "讨论这个技能…", text: $conversation.draft,
                canSend: !conversation.busy && !conversation.opening && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task { await conversation.send(using: store) }
            }.accessibilityIdentifier("review-composer").disabled(store.readOnly)
        }
        .onChange(of: conversation.draft) {
            store.composerDrafts[store.serverKey + "|review|" + conversation.id] = conversation.draft
        }
        .padding(24).frame(minWidth: 700, idealWidth: 820, minHeight: 600, idealHeight: 740)
        .task(id: store.gateway.connection) {
            guard !conversation.opening, store.gateway.phase == .online else { return }
            do { try await conversation.resume(using: store) }
            catch { conversation.error = error.localizedDescription }
        }
    }
}
