import AppKit
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    func captureStopped() {
        followMode = .paused
        unseenEventCount = 0
        isViewingLiveEdge = true
    }

    func handleCaptureStartFailure(_ error: Error) {
        guard !ErrorPresentation.isCancellationError(error) else {
            captureState = .idle
            return
        }
        let message = error.userFacingMessage
        logStore.record(.error, message, category: "Capture", error: error)
        errorMessage = message

        if ErrorPresentation.isXPCConnectionFailure(error) {
            systemExtensionStatusStore.applyXPCFailure(message: message)
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                message: message
            )
        }
        if ErrorPresentation.isFullDiskAccessError(message) {
            systemExtensionStatusStore.applyFullDiskAccessFailure(message: message)
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                fullDiskAccessHint: true,
                message: message
            )
        }
    }

    func reportError(
        _ error: Error,
        category: String = "Error",
        metadata: [String: String] = [:]
    ) {
        guard !ErrorPresentation.isCancellationError(error) else {
            return
        }
        let message = error.userFacingMessage
        logStore.record(.error, message, category: category, error: error, metadata: metadata)
        errorMessage = message
    }

    func openLogsFolder() {
        logStore.openLogsFolder()
    }

    func copyLogFilePath() {
        logStore.copyLogFilePath()
    }

    func clearDiagnosticLog() {
        logStore.clearLog()
    }
}
