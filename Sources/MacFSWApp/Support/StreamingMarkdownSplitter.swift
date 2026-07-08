import Foundation

/// Splits streaming markdown into a stable prefix of COMPLETED top-level
/// blocks and the still-growing tail.
///
/// Why: MarkdownView re-parses, re-highlights (JavaScriptCore), and re-lays
/// out its entire input on every change — and a code block that is still
/// growing changes its cache key on every token, so its syntax highlighting
/// re-runs from scratch each tick. Feeding MarkdownView only the completed
/// blocks means it updates once per finished block instead of once per
/// token, and finished code blocks get permanent highlight-cache hits; the
/// tail renders as plain Text until its block completes.
///
/// The boundary is the last blank line OUTSIDE a code fence (a blank line
/// inside ``` / ~~~ would split the fence and turn the rest of the document
/// into code). A mis-split only affects the transient tail rendering and
/// self-heals when the block completes.
enum StreamingMarkdownSplitter {
    static func split(_ markdown: String) -> (stablePrefix: String, tail: String) {
        var inFence = false
        var lastBoundary: String.Index?
        var lineStart = markdown.startIndex
        var index = markdown.startIndex

        while index < markdown.endIndex {
            guard markdown[index] == "\n" else {
                index = markdown.index(after: index)
                continue
            }
            let line = markdown[lineStart..<index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if trimmed.isEmpty, !inFence {
                lastBoundary = markdown.index(after: index)
            }
            index = markdown.index(after: index)
            lineStart = index
        }
        // The trailing partial line is never a boundary.

        guard let boundary = lastBoundary else {
            return ("", markdown)
        }
        return (String(markdown[..<boundary]), String(markdown[boundary...]))
    }
}
