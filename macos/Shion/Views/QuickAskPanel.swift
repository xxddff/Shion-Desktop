import AppKit
import SwiftUI

/// The window the global shortcut brings up: a panel floating over the app in front that takes
/// the keyboard without making Shion the active app, so Esc gives the keyboard straight back.
/// Its height follows what it holds, with the top edge kept where it is.
final class QuickAskWindow: NSPanel {
    static let width: CGFloat = 620

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
        title = "跟詩音说"
        identifier = NSUserInterfaceItemIdentifier("quick-ask")
        setAccessibilityIdentifier("quick-ask")
        let host = NSHostingView(rootView: QuickAskRoot(store: store, quick: quick) { [weak self] height in
            self?.fit(height)
        })
        // the window is sized by fit(_:), not by the hosting view's own constraints
        host.sizingOptions = []
        contentView = host
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
        // the shadow follows the glass's shape, which just changed
        invalidateShadow()
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

/// The field, then 詩音's answer as it comes in: the same rows as her chat (folded tool calls,
/// cards, Markdown), and what she asks you on the way. Glass, since it floats over everything.
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
        let chiefId = store.chiefId
        let items = quick.exchange(in: store)
        let lines = ChatLine.lines(items, replying: store.replying.contains(chiefId))
        let since = quick.asked?.at ?? .distantFuture
        let asks = store.asks.filter { $0.botId == chiefId && $0.at >= since }
        let state = status(answered: items.count > 1 || !asks.isEmpty)
        VStack(spacing: 0) {
            bar($quick.draft)
            if !lines.isEmpty || !asks.isEmpty {
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
                .padding(.top, lines.isEmpty && asks.isEmpty ? 0 : 2)
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quick-status")
            }
        }
        .frame(width: QuickAskWindow.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            fit(height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func bar(_ draft: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Mark(size: 26)
            KeyField(
                text: draft,
                placeholder: "跟\(store.bot(store.chiefId)?.name ?? "詩音")说…",
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
            .accessibilityLabel("发送")
            .accessibilityIdentifier("quick-send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 60)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-bar")
        // how the window came up, for the end-to-end test; nothing on screen
        .accessibilityValue(quick.openedBy)
    }

    private func answer(_ lines: [ChatLine], asks: [Ask]) -> some View {
        let chief = store.bot(store.chiefId)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                    AskRow(ask: ask)
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
