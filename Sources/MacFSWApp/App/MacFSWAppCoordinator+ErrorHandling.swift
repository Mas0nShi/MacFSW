import AppKit
import Combine
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
        guard !isCancellationError(error) else {
            captureState = .idle
            return
        }
        let message = userFacingMessage(error)
        logStore.record(.error, message, category: "Capture", error: error)
        errorMessage = message

        if isXPCConnectionFailure(error) {
            systemExtensionStatusStore.applyXPCFailure(message: message)
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                message: message
            )
        }
        if isFullDiskAccessError(message) {
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

    func isFullDiskAccessError(_ message: String) -> Bool {
        ErrorPresentation.isFullDiskAccessError(message)
    }

    func isXPCConnectionFailure(_ error: Error) -> Bool {
        ErrorPresentation.isXPCConnectionFailure(error)
    }

    func reportError(
        _ error: Error,
        category: String = "Error",
        metadata: [String: String] = [:]
    ) {
        guard !isCancellationError(error) else {
            return
        }
        let message = userFacingMessage(error)
        logStore.record(.error, message, category: category, error: error, metadata: metadata)
        errorMessage = message
    }

    func isCancellationError(_ error: Error) -> Bool {
        ErrorPresentation.isCancellationError(error)
    }

    func userFacingMessage(_ error: Error) -> String {
        ErrorPresentation.userFacingMessage(error)
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
