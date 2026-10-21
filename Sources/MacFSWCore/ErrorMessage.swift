import Foundation

public extension Error {
    /// The `LocalizedError` description when there is one, otherwise the
    /// error's own description — never Foundation's generic
    /// "The operation couldn't be completed" text.
    var userFacingMessage: String {
        (self as? LocalizedError)?.errorDescription ?? String(describing: self)
    }
}
