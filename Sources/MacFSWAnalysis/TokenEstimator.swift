import Foundation

/// Rough token estimate for display purposes only (~4 characters per token).
/// The app talks to arbitrary OpenAI-compatible endpoints whose tokenizers
/// are unknown, so budgets are enforced in characters; this exists solely to
/// caption those budgets in familiar units.
public enum MacFSWTokenEstimator {
    public static func estimatedTokens(forCharacters count: Int) -> Int {
        max(0, count) / 4
    }
}
