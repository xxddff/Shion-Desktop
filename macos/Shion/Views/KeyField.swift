import AppKit
import SwiftUI

/// The one-line field of the floating inputs (the ⌥Space window, ⌘K) and of the chat's find bar.
/// It hands Return, Esc and ↑↓ to its owner, so a list can follow the arrows. While an input
/// method is composing, those keys stay with the input method: picking a candidate neither sends
/// nor moves.
struct KeyField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 15
    let identifier: String
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMove: (Int) -> Void = { _ in }
    /// Bumped to take the keys again while it is up (⌘F with the chat's find bar showing).
    var focus = 0

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
        context.coordinator.focus = focus
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
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            // after this update: the keys moving updates the views that had them
            Task { field.window?.makeFirstResponder(field) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusField, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 240
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyField
        /// The request to take the keys last acted on (`focus`).
        var focus = 0

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

/// Behind a SwiftUI text field, gives it the keys each time `request` changes. Asked through
/// @FocusState, the chat's composer did not get them from its find field (a KeyField) as the bar
/// closed (run 159): this finds the editable field under it in the window and makes that the first
/// responder, as the ⌥Space window does with its own (QuickAskPanel.focusField).
struct KeyTarget: NSViewRepresentable {
    let request: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request)
    }

    func makeNSView(context: Context) -> Behind {
        Behind()
    }

    func updateNSView(_ view: Behind, context: Context) {
        guard context.coordinator.request != request else { return }
        context.coordinator.request = request
        // after this update, the views it changes (the find bar going) gone by then
        Task {
            guard let window = view.window, let content = window.contentView else { return }
            let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            if let field = Self.field(at: middle, in: content) {
                window.makeFirstResponder(field)
            }
        }
    }

    /// The editable text field or text view holding `point` (in the window's coordinates),
    /// outermost first; an editing field's own field editor is not one.
    private static func field(at point: NSPoint, in view: NSView) -> NSView? {
        guard !view.isHidden else { return nil }
        let editable = (view as? NSTextField)?.isEditable == true
            || (view as? NSTextView).map { $0.isEditable && !$0.isFieldEditor } == true
        if editable && view.convert(view.bounds, to: nil).contains(point) {
            return view
        }
        for subview in view.subviews {
            if let field = field(at: point, in: subview) { return field }
        }
        return nil
    }

    final class Coordinator {
        var request: Int

        init(request: Int) {
            self.request = request
        }
    }

    /// Never what a click lands on: the field in front of it is.
    final class Behind: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
