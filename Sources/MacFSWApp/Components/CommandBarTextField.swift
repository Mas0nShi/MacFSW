import AppKit
import SwiftUI

/// Single-line AppKit text view for the monitor command bar.
///
/// An NSTextView (not NSTextField) for two reasons: SwiftUI's TextField
/// cannot intercept Tab/arrow keys while focused, and soft-capsule token
/// backgrounds need a custom NSLayoutManager (`QueryTokenLayoutManager`),
/// which only an owned TextKit stack provides. Key handling goes through
/// `textView(_:doCommandBy:)`; `isFieldEditor` keeps Tab focus traversal
/// working when the suggestion list is closed.
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
    var highlight: (String) -> [QueryHighlighter.AttributeRun]
    /// Bumped by the model when a suggestion is committed; the fill then
    /// registers one undo step from `fillCommitBasis` to `text`.
    var fillCommitSerial: Int
    var fillCommitBasis: String

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
            onDismissSuggestions: onDismissSuggestions,
            highlight: highlight,
            fillCommitSerial: fillCommitSerial
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = QueryTokenLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 4
        layoutManager.addTextContainer(textContainer)

        let textView = CommandBarTextView(frame: .zero, textContainer: textContainer)
        textView.placeholderString = placeholder
        textView.delegate = context.coordinator
        textView.font = Coordinator.font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isFieldEditor = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.height]
        textView.typingAttributes = Coordinator.defaultAttributes
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isSuggestionListVisible = isSuggestionListVisible
        context.coordinator.onEditingChanged = onEditingChanged
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onMoveHighlight = onMoveHighlight
        context.coordinator.onCycleHighlight = onCycleHighlight
        context.coordinator.onAcceptSuggestion = onAcceptSuggestion
        context.coordinator.onCancelSuggestions = onCancelSuggestions
        context.coordinator.onDismissSuggestions = onDismissSuggestions
        context.coordinator.highlight = highlight

        guard let textView = context.coordinator.textView else {
            return
        }

        let commitRequested = context.coordinator.lastFillCommitSerial != fillCommitSerial
        context.coordinator.lastFillCommitSerial = fillCommitSerial

        guard textView.string != text || commitRequested else {
            context.coordinator.applyHighlight(to: textView)
            return
        }
        context.coordinator.isApplyingProgrammaticChange = true
        defer {
            context.coordinator.isApplyingProgrammaticChange = false
        }

        if commitRequested {
            // A committed suggestion is ONE undo step from what the user
            // typed (the preview basis) to the committed text — Tab previews
            // in between never entered the undo stack, so first silently
            // restore the basis, then perform the sole undoable replacement.
            // shouldChangeText is where NSTextView registers the undo; this
            // component owns the entire delegate chain and nothing vetoes
            // edits, so a veto is a bug to surface, not a state to fall
            // back from.
            if textView.string != fillCommitBasis {
                textView.string = fillCommitBasis
            }
            let basisRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let accepted = textView.shouldChangeText(in: basisRange, replacementString: text)
            assert(accepted, "command bar text view vetoed a committed fill")
            textView.replaceCharacters(in: basisRange, with: text)
            textView.didChangeText()
        } else {
            // Preview and other programmatic updates are ephemeral: they
            // replace the text without touching the undo stack.
            textView.string = text
        }
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        context.coordinator.applyHighlight(to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        static let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]

        var text: Binding<String>
        var isSuggestionListVisible: Bool
        var onEditingChanged: () -> Void
        var onSubmit: () -> Void
        var onMoveHighlight: (Int) -> Void
        var onCycleHighlight: (Int) -> Void
        var onAcceptSuggestion: () -> Bool
        var onCancelSuggestions: () -> Void
        var onDismissSuggestions: () -> Void
        var highlight: (String) -> [QueryHighlighter.AttributeRun]
        var lastFillCommitSerial: Int
        var isApplyingProgrammaticChange = false
        weak var textView: CommandBarTextView?
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
            onDismissSuggestions: @escaping () -> Void,
            highlight: @escaping (String) -> [QueryHighlighter.AttributeRun],
            fillCommitSerial: Int
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
            self.highlight = highlight
            self.lastFillCommitSerial = fillCommitSerial
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange,
                  let textView = notification.object as? NSTextView else {
                return
            }
            cancelScheduledDismissal()
            text.wrappedValue = textView.string
            onEditingChanged()
            applyHighlight(to: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            scheduleDismissal()
        }

        /// Single-line contract: pasted newlines become spaces.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacementString,
                  replacementString.rangeOfCharacter(from: .newlines) != nil else {
                return true
            }
            let sanitized = replacementString
                .components(separatedBy: .newlines)
                .joined(separator: " ")
            if textView.shouldChangeText(in: affectedCharRange, replacementString: sanitized) {
                textView.replaceCharacters(in: affectedCharRange, with: sanitized)
                textView.didChangeText()
            }
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
                    return false // isFieldEditor turns this into focus traversal
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
                if isSuggestionListVisible {
                    onCancelSuggestions()
                }
                // Always consumed: the NSTextView default would open the
                // system completion popup.
                return true
            default:
                return false
            }
        }

        /// Re-applies syntax attributes without replacing characters, so the
        /// caret and undo stack stay intact. Skipped while an input method
        /// holds marked text.
        func applyHighlight(to textView: NSTextView) {
            guard !textView.hasMarkedText(), let textStorage = textView.textStorage else {
                return
            }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            guard textStorage.length == fullRange.length else {
                return
            }

            isApplyingProgrammaticChange = true
            defer {
                isApplyingProgrammaticChange = false
            }
            textStorage.beginEditing()
            textStorage.setAttributes(Self.defaultAttributes, range: fullRange)
            for run in highlight(text) where NSMaxRange(run.range) <= fullRange.length {
                textStorage.addAttributes(run.attributes, range: run.range)
            }
            textStorage.endEditing()
            textView.typingAttributes = Self.defaultAttributes
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

/// NSTextView with placeholder drawing; everything else is configuration.
final class CommandBarTextView: NSTextView {
    var placeholderString = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty, !hasMarkedText() else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholderString as NSString).draw(at: origin, withAttributes: attributes)
    }
}
