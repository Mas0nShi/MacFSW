import Foundation

/// A bundle's marketing version plus build number. macOS replaces an
/// activated System Extension only when the build number changes.
public struct MacFSWComponentVersion: Codable, Equatable, Sendable, CustomStringConvertible {
    public var shortVersion: String
    public var build: String

    public init(shortVersion: String, build: String) {
        self.shortVersion = shortVersion
        self.build = build
    }

    public var description: String {
        "\(shortVersion) (\(build))"
    }
}

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
        macfswComponentVersion?.shortVersion ?? "development"
    }

    var macfswComponentVersion: MacFSWComponentVersion? {
        Self.componentVersion(in: infoDictionary ?? [:])
    }

    /// The Endpoint Extension packaged inside this app bundle — what
    /// activating the extension from this app would install.
    var bundledEndpointExtensionVersion: MacFSWComponentVersion? {
        let plist = bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(MacFSWXPCDefaults.extensionBundleIdentifier).systemextension")
            .appendingPathComponent("Contents/Info.plist")
        guard let dictionary = NSDictionary(contentsOf: plist) as? [String: Any] else {
            return nil
        }
        return Self.componentVersion(in: dictionary)
    }

    private static func componentVersion(in info: [String: Any]) -> MacFSWComponentVersion? {
        func value(_ key: String) -> String? {
            (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard let short = value("CFBundleShortVersionString"), let build = value("CFBundleVersion") else {
            return nil
        }
        return MacFSWComponentVersion(shortVersion: short, build: build)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
