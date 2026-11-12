import AppKit
import SwiftUI

/// AppKit owns selection, IME composition and newline insertion at the caret.
struct ComposerText: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    var send: () -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let field = Input(frame: NSRect(x: 0, y: 0, width: 400, height: 70))
        field.minSize = NSSize(width: 0, height: 70)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        field.isRichText = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = true
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainerInset = NSSize(width: 0, height: 7)
        field.setAccessibilityIdentifier("composer")
        field.delegate = context.coordinator
        field.submit = send
        configure(field)
        scroll.documentView = field
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let field = view.documentView as? Input else { return }
        if field.string != text && !field.hasMarkedText() { field.string = text }
        field.submit = send
        configure(field)
    }
    private func configure(_ field: Input) {
        // SwiftUI's disabled environment does not set NSTextView's editability or AX state.
        field.isEditable = isEnabled
        field.setAccessibilityEnabled(isEnabled)
        field.textColor = isEnabled ? .labelColor : .disabledControlTextColor
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerText
        init(_ parent: ComposerText) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextView, !field.hasMarkedText() { parent.text = field.string }
        }
    }
    final class Input: NSTextView {
        var submit: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            guard isEditable else { return }
            if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
                if event.modifierFlags.contains(.shift) { insertNewline(nil) }
                else { submit?() }
                return
            }
            super.keyDown(with: event)
        }
    }
}
