import AppKit
import SwiftUI

/// A chat's composer with what goes with it: why the chat could not be attached again, the message
/// being answered, the pictures and files about to go (ComposerBar), and, while the assistant is in
/// a turn, how what is sent now reaches it. What is typed lives in the store
/// (AppStore+Compose.swift), so the transcript above is not drawn again for every key, and the
/// draft is there again after another page.
struct ChatComposer: View {
    @Environment(AppStore.self) private var store
    let botId: String
    /// Bumped to give the field the keys (KeyTarget).
    let keys: Int
    /// Runs a send: the chat follows what is sent down, and undoes that when it did not go.
    let sending: (() -> Bool) -> Void

    var body: some View {
        let bot = store.bot(botId)
        let running = store.turnRunning(botId) && !store.readOnly
        VStack(alignment: .leading, spacing: 8) {
            if let note = store.rejoinNote(botId) {
                RejoinNote(botId: botId, note: note)
            }
            if let target = store.replyTarget(for: botId) {
                ReplyChip(target: target, name: bot?.name ?? "") {
                    store.cancelReply(in: botId)
                }
            }
            // with what is about to go: pictures and files (AttachmentViews.swift)
            ComposerBar(botId: botId) {
                Composer(placeholder: "跟\(bot?.name ?? "")说…", text: draft,
                         canSend: store.canSend(botId, draft.wrappedValue),
                         send: { sending { store.sendDraft(to: botId) } },
                         stop: running ? { store.stopReply(botId) } : nil,
                         stopping: store.control.stopping.contains(botId),
                         busy: running ? busyMode : nil,
                         keys: keys)
            }
        }
    }

    private var draft: Binding<String> {
        Binding { store.draft(for: botId) } set: { store.setDraft($0, for: botId) }
    }

    private var busyMode: Binding<BusyMode> {
        Binding { store.busyMode } set: { store.busyMode = $0 }
    }
}

/// Over the composer of a chat this socket could not attach again (AppStore.rejoin): what failed,
/// why, and when it is tried again by itself; 再试一次 tries now. The chat above keeps what it had.
struct RejoinNote: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let note: String

    var body: some View {
        HStack(spacing: 8) {
            // two lines at most, the whole of it on hover. The chat's page is laid out no shorter
            // than it measures at no width at all, where a text as tall as its words (fixedSize)
            // stands a character to a line: with Hermes's reason that was taller than the screen,
            // and the window, which could not grow past it, showed the middle of its content, the
            // line and the composer below its bottom edge (run 220)
            Text(note)
                .font(.t12)
                .foregroundStyle(Palette.alert)
                .lineLimit(2)
                .help(note)
            Spacer(minLength: 8)
            Button("再试一次") {
                guard let sessionId = store.botChatSession(botId) else { return }
                Task { await store.rejoin(botId, sessionId) }
            }
            .controlSize(.small)
            // whole, however long the reason beside it
            .fixedSize()
            // one try at a time
            .disabled(store.unattached[botId]?.trying == true)
            .accessibilityIdentifier("rejoin-retry")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rejoin-failure")
    }
}

/// Over the composer: the message the next one answers, and the way out of answering it.
struct ReplyChip: View {
    let target: ReplyTarget
    let name: String
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.t12)
                .foregroundStyle(Palette.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.theirs ? "回复\(name)" : "回复自己说的")
                    .font(.t12.weight(.medium))
                Text(target.text)
                    .font(.t12)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("不回复这条了")
            .accessibilityLabel("取消回复")
            .accessibilityIdentifier("reply-cancel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply-target")
    }
}

/// Beside the send button while the assistant is in a turn: how what is sent now reaches it.
/// The choice is kept (Settings has it too).
struct BusyModeMenu: View {
    @Binding var mode: BusyMode

    var body: some View {
        Menu {
            Picker("助手还在忙时", selection: $mode) {
                ForEach(BusyMode.allCases) { mode in
                    Text("\(mode.label)：\(mode.explanation)").tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(mode.label)
                .font(.t12)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("助手还在忙：这句话\(mode.explanation)")
        .accessibilityIdentifier("busy-mode")
    }
}

/// Copy a message, or answer it: in its menu, and on two small buttons that show at the end of
/// its row, just above it, while the pointer is anywhere on the row, and stay for the moment the
/// pointer takes to reach them. The row is as wide as the chat, so the buttons are clear of an
/// assistant's name and time, and above the corner of a bubble of yours.
struct MessageActions: ViewModifier {
    @Environment(AppStore.self) private var store
    let item: ChatItem
    let botId: String
    @State private var onRow = false
    @State private var onButtons = false
    @State private var shown = false

    /// What is wrapped depends only on whose message it is, which never changes: were it to
    /// depend on the reply still arriving, the row would be made again as the reply ends, its
    /// tables measured and its pictures loaded a second time, and the transcript, having followed
    /// the old row down, left short of the new one's end (run 180).
    @ViewBuilder
    func body(content: Content) -> some View {
        if item.role == .user || item.role == .assistant {
            content
                .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
                .overlay(alignment: .topTrailing) {
                    if shown && offered {
                        HStack(spacing: 2) {
                            action("复制", symbol: "doc.on.doc", identifier: "message-copy", copy)
                            action("回复", symbol: "arrowshape.turn.up.left", identifier: "message-reply", reply)
                        }
                        .padding(3)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.line))
                        .onHover { inside in
                            onButtons = inside
                            settle()
                        }
                        .offset(y: -18)
                    }
                }
                .onHover { inside in
                    onRow = inside
                    settle()
                }
                .contextMenu {
                    if offered {
                        Button("复制", action: copy)
                        Button("回复", action: reply)
                    }
                }
        } else {
            content
        }
    }

    /// Once the message is whole and has words.
    private var offered: Bool {
        !item.streaming && !words.isEmpty
    }

    /// Shown at once; hidden a moment after the pointer has left both the message and the buttons.
    private func settle() {
        if onRow || onButtons {
            shown = true
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !onRow && !onButtons {
                shown = false
            }
        }
    }

    /// The message without the quote it was sent with.
    private var words: String {
        ReplyQuote.split(item.text).words
    }

    private func action(_ title: String, symbol: String, identifier: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(words, forType: .string)
    }

    private func reply() {
        store.reply(to: item, in: botId)
    }
}
