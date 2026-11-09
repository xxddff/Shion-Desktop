import AppKit
import SwiftUI

/// The one-line field of the floating inputs (the ⌥Space window, ⌘K). It hands Return, Esc and
/// ↑↓ to its owner, so a list can follow the arrows. While an input method is composing, those
/// keys stay with the input method: picking a candidate neither sends nor moves.
struct KeyField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 15
    let identifier: String
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMove: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FocusField {
        let field = FocusField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.stringValue = text
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(identifier)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        // only when the owner changed it (sent, cleared): typing already matches, and writing
        // over a word being composed would cut the input method off
        if field.stringValue != text && !Coordinator.composing(field) {
            field.stringValue = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusField, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyField

        init(_ parent: KeyField) {
            self.parent = parent
            super.init()
        }

        /// An input method is holding marked (not yet chosen) text.
        static func composing(_ field: NSTextField) -> Bool {
            (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, !Self.composing(field) else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            default:
                return false
            }
            return true
        }
    }
}

/// Takes the keyboard as soon as it is in a window: the inputs it is used for open to be typed in.
final class FocusField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
