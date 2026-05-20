# MacFSW

MacFSW is a macOS file-system behavior analyzer for developers and security researchers.

The product is designed around focused, user-controlled capture sessions:

- The macOS App owns sessions, UI state, search, analysis, save, and open workflows.
- The System Extension is a minimal Endpoint Security capture sensor.
- Capture is bound to a live XPC stream. When the stream disconnects, ES capture stops.
- Events are held in memory by default. Users explicitly save sessions when they want persistence.

## Current Architecture

```text
MacFSW.app
  - SwiftUI / AppKit UI
  - Session manager
  - In-memory event store
  - Query and filter engine
  - Save / open session

MacFSWSystemExtension
  - Endpoint Security lifecycle
  - Low-level capture constraints
  - Event snapshotting
  - Batched XPC event streaming
```

See [docs/product-whitepaper.md](docs/product-whitepaper.md) for the product and architecture baseline.

## Development

```bash
swift test
swift run MacFSWApp
```

`swift run MacFSWApp` launches a raw executable and is not entitled to install System Extensions. Use the app bundle workflow when testing extension activation:

```bash
Scripts/package-dev-app.sh
cp -R .build/bundles/MacFSW.app /Applications/
open /Applications/MacFSW.app
```

The packaging script builds a real `MacFSW.app` bundle, embeds `com.mas0n.MacFSW.EndpointExtension.systemextension`, and signs both bundles with the configured entitlements when a valid Apple Development identity is available.

`Enable System Extension` is guarded at runtime. If MacFSW is launched from `swift run`, launched outside `/Applications`, or if the signed app is missing `com.apple.developer.system-extension.install`, the app will refuse to submit the activation request and show a packaging error.

The app connects to the Endpoint Security extension through `UYF535Y9QZ.com.mas0n.MacFSW.EndpointExtension.xpc`, the Mach service declared in the extension `Info.plist`.

Production distribution should use an Xcode project/archive with a host app target and an Endpoint Security System Extension target using the configuration files in `Configuration/`.

## Signing Configuration

The baseline local signing values are:

```text
DEVELOPMENT_TEAM = UYF535Y9QZ
MACFSW_HOST_BUNDLE_ID = com.mas0n.MacFSW
MACFSW_EXTENSION_BUNDLE_ID = com.mas0n.MacFSW.EndpointExtension
```

Real Endpoint Security capture requires Apple approval for:

```text
com.apple.developer.endpoint-security.client
```
