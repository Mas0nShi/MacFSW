import AppKit
import MacFSWCore
import QuartzCore

/// Following the newest row.
///
/// At readable rates a display link glides the view toward the bottom,
/// at most a couple of rows per frame, so new rows enter a few at a time.
/// When events outrun that (the backlog exceeds a screen), gliding would
/// rebuild a screenful of cells every frame for text nobody can read, so
/// the view instead jumps to the newest row a few times per second.
///
/// The user is always in charge: scrolling up stops following, scrolling
/// back to the bottom (with nothing selected) resumes it.
extension EventTableView.Coordinator {
    /// Seconds for a glide to close ~63% of the distance to the newest row.
    private static let followTimeConstant: CFTimeInterval = 0.1
    /// Fastest glide, in rows per frame.
    private static let maxGlideRows: CGFloat = 2
    /// Minimum time between jumps when events outrun the glide.
    private static let jumpInterval: CFTimeInterval = 0.25

    @objc func scrollViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else {
            return
        }
        let bounds = clipView.bounds
        let previous = lastClipBounds
        lastClipBounds = bounds
        requestVisibleRows()
        guard !isProgrammaticScroll, rowCount > 0, let previous else {
            return
        }
        guard bounds.size == previous.size else {
            // A resize, not a scroll: stay on the newest row if following.
            if isFollowing {
                startFollowing()
            }
            return
        }
        if isFollowing, bounds.origin.y < previous.origin.y - 1 {
            setFollowing(false, notify: true)
        } else if !isFollowing, bounds.origin.y > previous.origin.y, isAtLiveEdge(),
                  tableView?.selectedRow ?? -1 < 0 {
            // Arrow keys moving a selection down to the last row should not
            // resume following, so only an unselected table resumes.
            setFollowing(true, notify: true)
        }
    }

    func setFollowing(_ following: Bool, notify: Bool) {
        guard isFollowing != following else {
            return
        }
        isFollowing = following
        if following {
            startFollowing()
        } else {
            followLink?.isPaused = true
        }
        if notify {
            // Reported after the current AppKit pass; it updates SwiftUI state.
            // Until then the store's follow mode is stale and must not win.
            hasUnreportedFollowChange = true
            DispatchQueue.main.async { [weak self] in
                self?.hasUnreportedFollowChange = false
                self?.onFollowChanged(following)
            }
        }
    }

    /// Adopts the store's follow mode unless the user just changed it here.
    func syncFollowing(with followMode: MacFSWFollowMode) {
        guard !hasUnreportedFollowChange else {
            return
        }
        setFollowing(followMode == .live, notify: false)
    }

    /// Resumes the display link when there is distance left to cover.
    func startFollowing() {
        guard isFollowing, let scrollView = tableView?.enclosingScrollView else {
            return
        }
        if followLink == nil {
            let link = scrollView.displayLink(target: self, selector: #selector(followFrame(_:)))
            link.add(to: .main, forMode: .common)
            followLink = link
        }
        if followLink?.isPaused != false {
            lastFollowFrame = nil
            followLink?.isPaused = false
        }
    }

    /// Puts the newest row in view at once, keeping at most the last screen
    /// to glide through. Used for explicit jumps and fresh results.
    func jumpToLiveEdge(gliding: Bool) {
        guard let clipView = tableView?.enclosingScrollView?.contentView, rowCount > 0 else {
            return
        }
        let target = liveEdgeOriginY(in: clipView)
        let start = gliding ? max(clipView.bounds.origin.y, target - clipView.bounds.height) : target
        setScrollOriginY(start, in: clipView)
        startFollowing()
    }

    @objc func followFrame(_ link: CADisplayLink) {
        guard isFollowing, rowCount > 0, let clipView = tableView?.enclosingScrollView?.contentView else {
            link.isPaused = true
            return
        }
        let current = clipView.bounds.origin.y
        let target = liveEdgeOriginY(in: clipView)
        let gap = target - current
        guard gap > 0.5 else {
            if gap != 0 {
                setScrollOriginY(target, in: clipView)
            }
            link.isPaused = true
            return
        }
        let elapsed = lastFollowFrame.map { link.timestamp - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastFollowFrame = link.timestamp

        if gap > clipView.bounds.height {
            if link.timestamp - lastFollowJump >= Self.jumpInterval {
                lastFollowJump = link.timestamp
                setScrollOriginY(target, in: clipView)
            }
            return
        }
        let rowHeight = tableView?.rowHeight ?? 26
        let eased = gap * (1 - exp(-elapsed / Self.followTimeConstant))
        let step = min(max(1, eased), rowHeight * Self.maxGlideRows)
        setScrollOriginY(min(target, current + step), in: clipView)
    }

    func stopFollowLink() {
        followLink?.invalidate()
        followLink = nil
    }

    private func liveEdgeOriginY(in clipView: NSClipView) -> CGFloat {
        guard let tableView else {
            return clipView.bounds.origin.y
        }
        let bottom = tableView.rect(ofRow: rowCount - 1).maxY
        return clipView.constrainBoundsRect(NSRect(
            origin: NSPoint(x: clipView.bounds.origin.x, y: bottom - clipView.bounds.height),
            size: clipView.bounds.size
        )).origin.y
    }

    private func setScrollOriginY(_ y: CGFloat, in clipView: NSClipView) {
        isProgrammaticScroll = true
        defer { isProgrammaticScroll = false }
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
        clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    func visibleRowRange(in tableView: NSTableView) -> Range<Int> {
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.location != NSNotFound, rows.length > 0 else {
            return 0..<min(rowCount, 80)
        }
        let lower = max(0, rows.location)
        let upper = min(rowCount, rows.location + rows.length)
        return lower..<upper
    }

    func isAtLiveEdge() -> Bool {
        guard let tableView, let clipView = tableView.enclosingScrollView?.contentView else {
            return true
        }
        return clipView.bounds.maxY >= tableView.bounds.height - max(12, tableView.rowHeight)
    }
}
