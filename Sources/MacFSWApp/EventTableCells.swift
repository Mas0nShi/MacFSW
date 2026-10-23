import AppKit
import MacFSWCore

/// One table cell: an optional operation icon and a line of styled text,
/// drawn directly. A text field per cell cost ~85% of a new row's time
/// (sizing, constraints, its own drawing); this view only draws.
///
/// What the text field provided for free is done here: accessibility
/// text, redrawing on appearance changes, and a full-text tooltip when the
/// text is truncated. Styling is kept as roles rather than colors so the
/// text can switch to the selection's contrasting color.
@MainActor
final class EventTableCellView: NSTableCellView {
    enum Role {
        case primary, secondary, tertiary, accent(NSColor)
    }

    struct Segment {
        var text: String
        var role: Role = .primary
        var font: NSFont = .systemFont(ofSize: 12)
    }

    private static let inset: CGFloat = 6
    private static let iconSize: CGFloat = 16
    private static let iconSpacing: CGFloat = 6

    private var segments: [Segment] = []
    private var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    private var icon: NSImage?
    private var iconColor: NSColor?
    private var explicitToolTip: String?
    private var plainText = ""

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(
        _ segments: [Segment],
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        symbolName: String? = nil,
        iconColor: NSColor? = nil,
        toolTip: String? = nil
    ) {
        self.segments = segments
        self.lineBreakMode = lineBreakMode
        self.icon = symbolName.map(Self.symbolImage)
        self.iconColor = iconColor
        explicitToolTip = toolTip
        plainText = segments.map(\.text).joined()
        setAccessibilityValue(plainText)
        needsDisplay = true
    }

    /// The cell's text as one string, for type-select and accessibility.
    var text: String {
        plainText
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let isHighlighted = backgroundStyle == .emphasized
        var textRect = bounds.insetBy(dx: Self.inset, dy: 0)
        if let icon {
            let iconRect = NSRect(
                x: textRect.minX,
                y: (bounds.height - Self.iconSize) / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
            drawTinted(icon, in: iconRect, color: isHighlighted ? .alternateSelectedControlTextColor : iconColor ?? .labelColor)
            textRect.origin.x = iconRect.maxX + Self.iconSpacing
            textRect.size.width = bounds.maxX - Self.inset - textRect.minX
        }
        guard !segments.isEmpty, textRect.width > 0 else {
            return
        }
        let text = attributedText(highlighted: isHighlighted)
        let lineHeight = ceil(segments.map { $0.font.ascender - $0.font.descender + $0.font.leading }.max() ?? 15)
        textRect.origin.y = floor((bounds.height - lineHeight) / 2)
        textRect.size.height = lineHeight
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func attributedText(highlighted: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let text = NSMutableAttributedString()
        for segment in segments {
            text.append(NSAttributedString(string: segment.text, attributes: [
                .font: segment.font,
                .foregroundColor: highlighted ? NSColor.alternateSelectedControlTextColor : Self.color(for: segment.role),
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    private func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func color(for role: Role) -> NSColor {
        switch role {
        case .primary: .labelColor
        case .secondary: .secondaryLabelColor
        case .tertiary: .tertiaryLabelColor
        case .accent(let color): color
        }
    }

    /// Symbol lookup and configuration cost ~120 µs; there are only a
    /// handful of operation symbols, so each is built once.
    private static var symbolImages: [String: NSImage] = [:]

    private static func symbolImage(_ name: String) -> NSImage {
        if let image = symbolImages[name] {
            return image
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) ?? NSImage()
        symbolImages[name] = image
        return image
    }

    // MARK: - Tooltip

    // Computed on hover only: measuring every cell's text up front is the
    // cost this view exists to avoid. The tooltip rect follows the frame.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }
    }
}

extension EventTableCellView: NSViewToolTipOwner {
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            if let explicitToolTip {
                return explicitToolTip
            }
            let available = bounds.width - 2 * Self.inset - (icon == nil ? 0 : Self.iconSize + Self.iconSpacing)
            return attributedText(highlighted: false).size().width > available ? plainText : ""
        }
    }
}

/// What each column shows for a row.
@MainActor
enum EventTableColumn: String, CaseIterable {
    case time, operation, process, path, change, signing

    var title: String {
        switch self {
        case .time: "Time"
        case .operation: "Operation"
        case .process: "Process"
        case .path: "Path"
        case .change: "Change"
        case .signing: "Signing"
        }
    }

    var width: CGFloat {
        switch self {
        case .time: 92
        case .operation: 96
        case .process: 140
        case .path: 420
        case .change: 180
        case .signing: 180
        }
    }

    /// Path takes whatever width is left; the other columns keep their
    /// size unless the user drags them.
    var isFlexible: Bool {
        self == .path
    }

    var isHiddenByDefault: Bool {
        self == .signing
    }

    private static let timeStyle = Date.FormatStyle.dateTime.hour().minute().second().secondFraction(.fractional(3))
    private static let monospaced = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    func configure(_ cell: EventTableCellView, with summary: MacFSWEventRowSummary?) {
        guard let summary else {
            // Rows load a page at a time; an empty row reads as "coming"
            // without the flicker of placeholder text.
            cell.configure([])
            return
        }
        switch self {
        case .time:
            let date = Date(timeIntervalSince1970: TimeInterval(summary.timestampNS) / 1_000_000_000)
            cell.configure([.init(text: date.formatted(Self.timeStyle), font: Self.monospaced)])
        case .operation:
            let color = Self.color(for: summary.eventType)
            cell.configure(
                [.init(text: summary.eventType.rawValue.uppercased(), role: .accent(color), font: .systemFont(ofSize: 11, weight: .semibold))],
                symbolName: symbol(for: summary.eventType),
                iconColor: color,
                toolTip: MacFSWOperationBucket.bucket(for: summary.eventType).title
            )
        case .process:
            cell.configure([
                .init(text: summary.processName),
                .init(text: "  \(summary.pid)", role: .tertiary, font: Self.monospaced),
            ])
        case .path:
            var segments: [EventTableCellView.Segment] = []
            if let source = summary.sourcePath, !source.isEmpty {
                segments += Self.pathSegments(source)
                segments.append(.init(text: "  →  ", role: .tertiary))
                let sameFolder = (source as NSString).deletingLastPathComponent == (summary.targetPath as NSString).deletingLastPathComponent
                segments += sameFolder
                    ? [.init(text: (summary.targetPath as NSString).lastPathComponent)]
                    : Self.pathSegments(summary.targetPath)
            } else {
                segments = Self.pathSegments(summary.targetPath)
            }
            // A move keeps its destination name in view; a plain path keeps
            // both its root and its file name.
            let lineBreakMode: NSLineBreakMode = summary.sourcePath?.isEmpty == false ? .byTruncatingHead : .byTruncatingMiddle
            cell.configure(segments, lineBreakMode: lineBreakMode, toolTip: summary.sourcePath.map { "\($0)\n→ \(summary.targetPath)" } ?? summary.targetPath)
        case .change:
            cell.configure([.init(text: summary.detailSummary)], toolTip: summary.detailSummary.isEmpty ? nil : summary.detailSummary)
        case .signing:
            cell.configure([.init(text: summary.signingSummary, role: .secondary)])
        }
    }

    /// The folder recedes so the file name stands out.
    private static func pathSegments(_ path: String) -> [EventTableCellView.Segment] {
        let name = (path as NSString).lastPathComponent
        guard name.count < path.count else {
            return [.init(text: path)]
        }
        return [
            .init(text: String(path.dropLast(name.count)), role: .secondary),
            .init(text: name),
        ]
    }

    static func color(for type: MacFSWEventType) -> NSColor {
        switch MacFSWOperationBucket.bucket(for: type) {
        case .read: .systemBlue
        case .create: .systemTeal
        case .write: .systemIndigo
        case .rename: .systemPurple
        case .delete: .systemRed
        case .metadata: .systemOrange
        case .link: .systemMint
        }
    }
}
