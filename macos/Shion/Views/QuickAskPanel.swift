import AppKit
import SwiftUI

/// The window the global shortcut brings up: a panel floating over the app in front that takes
/// the keyboard without making Shion the active app, so Esc gives the keyboard straight back.
/// Its height follows what it holds, with the top edge kept where it is.
final class QuickAskWindow: NSPanel {
    static let width: CGFloat = 620
    /// The glass's corners (`.rect(cornerRadius:)` is continuous, like the clip below).
    static let cornerRadius: CGFloat = 24

    convenience init(store: AppStore, quick: QuickAsk) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: QuickAskWindow.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        // on the Space you are on, over a full-screen app too
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        title = "跟\(store.chiefName)说"
        identifier = NSUserInterfaceItemIdentifier("quick-ask")
        setAccessibilityIdentifier("quick-ask")
        let host = NSHostingView(rootView: QuickAskRoot(store: store, quick: quick) { [weak self] height in
            self?.fit(height)
        })
        // the window is sized by fit(_:), not by the hosting view's own constraints
        host.sizingOptions = []
        // clear outside the glass: the glass's own shadow reaches into the corners, and anything
        // drawn there makes the system outline and shadow the whole rectangle
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = QuickAskWindow.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        contentView = clip
        host.frame = clip.bounds
        host.autoresizingMask = [.width, .height]
        clip.addSubview(host)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc (when the field does not have it) and ⌘W put it away.
    override func cancelOperation(_ sender: Any?) {
        QuickAsk.shared.hide()
    }

    override func performClose(_ sender: Any?) {
        QuickAsk.shared.hide()
    }

    /// Centered on the screen with the pointer, a fifth of the way down, like Spotlight.
    func place() {
        let mouse = NSEvent.mouseLocation
        guard let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame else { return }
        let top = area.maxY - area.height * 0.2
        setFrame(NSRect(x: area.midX - frame.width / 2, y: top - frame.height, width: frame.width, height: frame.height), display: false)
    }

    /// The keyboard to the field, each time the window comes up.
    func focusField() {
        guard let field = contentView.flatMap(Self.field(in:)) else { return }
        makeFirstResponder(field)
    }

    private static func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = field(in: subview) { return field }
        }
        return nil
    }

    private func fit(_ height: CGFloat) {
        let height = height.rounded(.up)
        guard height > 0, abs(frame.height - height) > 0.5 else { return }
        var next = frame
        next.origin.y = frame.maxY - height
        next.size.height = height
        setFrame(next, display: true)
        // the shadow follows the glass's shape, which just changed: again once it has been drawn
        invalidateShadow()
        Task { [weak self] in
            self?.invalidateShadow()
        }
    }
}

/// The window's content with what it reads from the environment.
private struct QuickAskRoot: View {
    let store: AppStore
    let quick: QuickAsk
    let fit: (CGFloat) -> Void

    var body: some View {
        QuickAskView(quick: quick, fit: fit)
            .environment(store)
    }
}

/// The field, then 总秘书's answer as it comes in: the same rows as the chat (folded tool calls,
/// cards, Markdown), and what 总秘书 asks you on the way, answered here. Sentences waiting for a
/// server come first. Glass, since it floats over everything.
struct QuickAskView: View {
    @Environment(AppStore.self) private var store
    let quick: QuickAsk
    let fit: (CGFloat) -> Void
    /// Folded runs of tool calls opened by a click, as in the chat.
    @State private var openRuns: Set<String> = []
    @State private var answerHeight: CGFloat = 0

    /// Taller answers scroll, newest at the bottom.
    private static let answerMax: CGFloat = 420

    var body: some View {
        @Bindable var quick = quick
        let items = quick.exchange(in: store)
        let lines = ChatLine.lines(items, replying: store.replying.contains(store.chiefId))
        let asks = quick.asks(in: store)
        let state = status(answered: items.count > 1 || !asks.isEmpty)
        let filled = !quick.waiting.isEmpty || !lines.isEmpty || !asks.isEmpty
        VStack(spacing: 0) {
            bar($quick.draft, answering: quick.question(in: store) != nil)
            if filled {
                Divider()
                answer(lines, asks: asks)
            }
            if let state {
                HStack(spacing: 6) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.text)
                        .font(.t12)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, filled ? 2 : 0)
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quick-status")
            }
        }
        .frame(width: QuickAskWindow.width)
        .glassEffect(.regular, in: .rect(cornerRadius: QuickAskWindow.cornerRadius))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            fit(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The field; while 总秘书 waits on words from you, Return answers.
    private func bar(_ draft: Binding<String>, answering: Bool) -> some View {
        HStack(spacing: 12) {
            Mark(size: 26)
            KeyField(
                text: draft,
                placeholder: answering ? "回答\(store.chiefName)…" : "跟\(store.chiefName)说…",
                size: 15,
                identifier: "quick-field",
                onSubmit: { quick.send() },
                onCancel: { quick.hide() }
            )
            Button {
                quick.openFullChat()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .help("打开完整对话")
            .accessibilityLabel("打开完整对话")
            .accessibilityIdentifier("quick-open")
            Button {
                quick.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(answering ? "回答" : "发送")
            .accessibilityIdentifier("quick-send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 60)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-bar")
    }

    private func answer(_ lines: [ChatLine], asks: [Ask]) -> some View {
        let chief = store.chief
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(quick.waiting) { sentence in
                    WaitingSentence(text: sentence.text, written: QuickAskWaiting.written(sentence.at, now: Date()))
                }
                ForEach(lines) { line in
                    switch line {
                    case .item(let item):
                        ChatRow(item: item, bot: chief, showHead: false)
                    case .tools(let id, let tools):
                        ToolRun(tools: tools, open: openRuns.contains(id)) {
                            openRuns.formSymmetricDifference([id])
                        }
                    }
                }
                ForEach(asks) { ask in
                    QuickAskPrompt(ask: ask)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                answerHeight = height
            }
        }
        .frame(height: min(max(answerHeight, 1), Self.answerMax))
        // follows the reply as it grows
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("quick-answer")
    }

    /// Why no answer is coming, or where the connection is, while the sentence waits.
    private func status(answered: Bool) -> (text: String, color: Color)? {
        if let error = store.chatErrors[store.chiefId] {
            return (error, Palette.alert)
        }
        guard quick.asked != nil, !answered else { return nil }
        guard store.live else { return ("未连接服务器", Color.secondary) }
        switch store.gateway.phase {
        case .online: return nil
        case .connecting: return ("连接中…", Palette.warm)
        case .failed(let reason): return (reason, Palette.alert)
        case .offline: return ("未连接服务器", Color.secondary)
        }
    }
}

/// A sentence sent while no server was connected, with when it was written: it goes out by
/// itself once one is.
struct WaitingSentence: View {
    let text: String
    let written: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .font(.t13)
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Palette.accent.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Label("\(written) 写的 · 等连上服务器后发出", systemImage: "clock")
                .font(.t12)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quick-waiting")
    }
}

/// An approval or a question from 总秘书 in this exchange, with every answer it takes. A question
/// that wants words has only 跳过 here: the field answers it.
struct QuickAskPrompt: View {
    @Environment(AppStore.self) private var store
    let ask: Ask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask.title)
                .font(.t13.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let preview = ask.preview {
                Text(preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                ForEach(ask.options) { option in
                    if option.primary {
                        Button(option.label) { store.answer(ask, with: option) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button(option.label) { store.answer(ask, with: option) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-ask-\(ask.id)")
    }
}
