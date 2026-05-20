import Foundation
import MacFSWCore

enum ErrorPresentation {
    static func userFacingMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    static func isFullDiskAccessError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Full Disk Access")
            || message.localizedCaseInsensitiveContains("ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED")
    }

    static func isXPCConnectionFailure(_ error: Error) -> Bool {
        if let clientError = error as? MacFSWClientError {
            if case .xpcUnavailable = clientError {
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSXPCConnectionInvalid {
            return true
        }

        return nsError.localizedDescription.localizedCaseInsensitiveContains("XPC")
            || nsError.localizedDescription.localizedCaseInsensitiveContains("connection to service")
    }
}
