import Foundation

public extension Bundle {
    /// The capture service name baked into Info.plist at packaging time,
    /// or the development default when running outside a packaged bundle.
    /// The `macfsw` tool lives in the app's `Contents/MacOS`, so it reads
    /// the app's Info.plist too.
    var macfswXPCServiceName: String {
        let configured = (object(forInfoDictionaryKey: "MacFSWXPCServiceName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.flatMap { $0.isEmpty ? nil : $0 } ?? MacFSWXPCDefaults.serviceName
    }

    var macfswVersion: String {
        let version = (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return version.flatMap { $0.isEmpty ? nil : $0 } ?? "development"
    }
}
