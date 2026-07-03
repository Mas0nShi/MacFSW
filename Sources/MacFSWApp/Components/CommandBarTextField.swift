import AppKit
import SwiftUI

/// Borderless AppKit text field for the monitor command bar. SwiftUI's
/// TextField cannot intercept Tab/arrow keys while focused (the field editor
/// consumes them), so suggestion navigation needs
/// `control(_:textView:doCommandBy:)`.
struct CommandBarTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isSuggestionListVisible: Bool
    var onEditingChanged: () -> Void
    var onSubmit: () -> Void
    var onMoveHighlight: (Int) -> Void
    var onCycleHighlight: (Int) -> Void
    var onAcceptSuggestion: () -> Bool
    var onCancelSuggestions: () -> Void
    var onDismissSuggestions: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isSuggestionListVisible: isSuggestionListVisible,
            onEditingChanged: onEditingChanged,
            onSubmit: onSubmit,
            onMoveHighlight: onMoveHighlight,
            onCycleHighlight: onCycleHighlight,
            onAcceptSuggestion: onAcceptSuggestion,
            onCancelSuggestions: onCancelSuggestions,
            onDismissSuggestions: onDismissSuggestions
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isSuggestionListVisible = isSuggestionListVisible
        context.coordinator.onEditingChanged = onEditingChanged
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onMoveHighlight = onMoveHighlight
        context.coordinator.onCycleHighlight = onCycleHighlight
        context.coordinator.onAcceptSuggestion = onAcceptSuggestion
        context.coordinator.onCancelSuggestions = onCancelSuggestions
        context.coordinator.onDismissSuggestions = onDismissSuggestions

        guard field.stringValue != text else {
            return
        }
        context.coordinator.isApplyingProgrammaticChange = true
        defer {
            context.coordinator.isApplyingProgrammaticChange = false
        }
        field.stringValue = text
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isSuggestionListVisible: Bool
        var onEditingChanged: () -> Void
        var onSubmit: () -> Void
        var onMoveHighlight: (Int) -> Void
        var onCycleHighlight: (Int) -> Void
        var onAcceptSuggestion: () -> Bool
        var onCancelSuggestions: () -> Void
        var onDismissSuggestions: () -> Void
        var isApplyingProgrammaticChange = false
        private var dismissalGeneration = 0

        init(
            text: Binding<String>,
            isSuggestionListVisible: Bool,
            onEditingChanged: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onMoveHighlight: @escaping (Int) -> Void,
            onCycleHighlight: @escaping (Int) -> Void,
            onAcceptSuggestion: @escaping () -> Bool,
            onCancelSuggestions: @escaping () -> Void,
            onDismissSuggestions: @escaping () -> Void
        ) {
            self.text = text
            self.isSuggestionListVisible = isSuggestionListVisible
            self.onEditingChanged = onEditingChanged
            self.onSubmit = onSubmit
            self.onMoveHighlight = onMoveHighlight
            self.onCycleHighlight = onCycleHighlight
            self.onAcceptSuggestion = onAcceptSuggestion
            self.onCancelSuggestions = onCancelSuggestions
            self.onDismissSuggestions = onDismissSuggestions
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange,
                  let field = notification.object as? NSTextField else {
                return
            }
            cancelScheduledDismissal()
            text.wrappedValue = field.stringValue
            onEditingChanged()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            scheduleDismissal()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                guard isSuggestionListVisible else {
                    return false
                }
                onMoveHighlight(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                // Also fires while the list is hidden so ↓ can reopen it.
                onMoveHighlight(1)
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard isSuggestionListVisible else {
                    return false
                }
                onCycleHighlight(1)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard isSuggestionListVisible else {
                    return false
                }
                onCycleHighlight(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if isSuggestionListVisible, onAcceptSuggestion() {
                    return true
                }
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard isSuggestionListVisible else {
                    return false
                }
                onCancelSuggestions()
                return true
            default:
                return false
            }
        }

        /// Focus loss dismisses the list after a short grace period so a
        /// click on a suggestion row can land first; edits and acceptance
        /// cancel the pending dismissal.
        private func scheduleDismissal() {
            dismissalGeneration += 1
            let generation = dismissalGeneration
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, self.dismissalGeneration == generation else {
                    return
                }
                self.onDismissSuggestions()
            }
        }

        func cancelScheduledDismissal() {
            dismissalGeneration += 1
        }
    }
}
