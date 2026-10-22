import AppKit
import MacFSWCore
import SwiftUI

extension EventTableView.Coordinator {

        @objc func scrollViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  !isProgrammaticScroll,
                  rowCount > 0 else {
                return
            }
            let visibleBottom = clipView.bounds.maxY
            let previousVisibleBottom = lastObservedVisibleBottom
            lastObservedVisibleBottom = visibleBottom
            requestVisibleRows()
            if didScrollUp(from: previousVisibleBottom, to: visibleBottom) || isAtLiveEdge(scrollView) {
                reportLiveEdgeIfNeeded()
            }
        }

        @objc func clearProgrammaticScroll() {
            isProgrammaticScroll = false
        }

        func visibleRowRange(in tableView: NSTableView) -> Range<Int> {
            let rows = tableView.rows(in: tableView.visibleRect)
            guard rows.location != NSNotFound, rows.length > 0 else {
                let fallbackUpper = min(rowCount, 80)
                return 0..<fallbackUpper
            }
            let lower = max(0, rows.location)
            let upper = min(rowCount, rows.location + rows.length)
            return lower..<upper
        }

        func isAtLiveEdge() -> Bool {
            // Mid-animation the view is still on its way down to the edge.
            guard !isAnimatingToLive, let scrollView = tableView?.enclosingScrollView else {
                return true
            }
            return isAtLiveEdge(scrollView)
        }

        func reportLiveEdgeIfNeeded(force: Bool = false) {
            let isAtEdge = isAtLiveEdge()
            guard force || lastReportedLiveEdge != isAtEdge else {
                return
            }
            lastReportedLiveEdge = isAtEdge
            pendingLiveEdgeReport = isAtEdge
            guard !isLiveEdgeReportScheduled else {
                return
            }
            isLiveEdgeReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isLiveEdgeReportScheduled = false
                guard let pendingLiveEdgeReport = self.pendingLiveEdgeReport else {
                    return
                }
                self.pendingLiveEdgeReport = nil
                self.onLiveEdgeChanged(pendingLiveEdgeReport)
            }
        }

        func isAtLiveEdge(_ scrollView: NSScrollView) -> Bool {
            guard let tableView else {
                return true
            }
            let visibleBottom = scrollView.contentView.bounds.maxY
            let documentBottom = tableView.bounds.height
            return visibleBottom >= documentBottom - max(12, tableView.rowHeight)
        }

        func didScrollUp(from previousVisibleBottom: CGFloat?, to visibleBottom: CGFloat) -> Bool {
            guard let previousVisibleBottom else {
                return false
            }
            return visibleBottom < previousVisibleBottom - 2
        }
}
