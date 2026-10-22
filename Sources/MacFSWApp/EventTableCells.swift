import AppKit
import MacFSWCore

/// One table cell: an optional operation icon and a line of styled text.
/// Styling is kept as roles rather than colors so the text can switch to
/// the selection's contrasting color when the row is highlighted.
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

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var iconColor: NSColor?
    private var segments: [Segment] = []
    private var lineBreakMode: NSLineBreakMode = .byTruncatingTail
    private var labelLeadingWithIcon: NSLayoutConstraint!
    private var labelLeadingWithoutIcon: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
        let leadingWithIcon = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            leadingWithIcon,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        labelLeadingWithIcon = leadingWithIcon
        labelLeadingWithoutIcon = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
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
        self.iconColor = iconColor
        icon.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: toolTip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        }
        icon.isHidden = icon.image == nil
        labelLeadingWithIcon.isActive = !icon.isHidden
        labelLeadingWithoutIcon.isActive = icon.isHidden
        self.toolTip = toolTip
        render()
    }

    private func render() {
        let isHighlighted = backgroundStyle == .emphasized
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let text = NSMutableAttributedString()
        for segment in segments {
            text.append(NSAttributedString(string: segment.text, attributes: [
                .font: segment.font,
                .foregroundColor: isHighlighted ? NSColor.alternateSelectedControlTextColor : color(for: segment.role),
                .paragraphStyle: paragraph,
            ]))
        }
        label.attributedStringValue = text
        icon.contentTintColor = isHighlighted ? .alternateSelectedControlTextColor : iconColor
    }

    private func color(for role: Role) -> NSColor {
        switch role {
        case .primary: .labelColor
        case .secondary: .secondaryLabelColor
        case .tertiary: .tertiaryLabelColor
        case .accent(let color): color
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
