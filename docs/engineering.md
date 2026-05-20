# Engineering Notes

## Architecture

MacFSW is intentionally Swift-only:

- `MacFSWCore` contains product models, query logic, in-memory storage, archive support, XPC payloads, and capture client abstractions.
- `MacFSWApp` owns Session UX, event analysis, and save/open workflows.
- `MacFSWSystemExtension` owns Endpoint Security capture and XPC event streaming only.

The System Extension must remain a minimal sensor. It should not persist data, manage Sessions, or implement product search.

## Development Backend

The product app always uses the XPC capture client. There is no alternate production or development capture backend in the app target.

Running `swift run MacFSWApp` without a signed and installed System Extension is still useful for UI shell work, but Record will report XPC unavailability rather than generating synthetic events.

Synthetic events may be constructed inside tests only.

## Production Packaging

SwiftPM is used for modular development and tests. Raw `swift run` executables do not carry bundle metadata or entitlements, so they cannot install System Extensions.

For local bundle testing:

```bash
Scripts/package-dev-app.sh
cp -R .build/bundles/MacFSW.app /Applications/
open /Applications/MacFSW.app
```

The script creates:

```text
MacFSW.app
  Contents/
    Info.plist
    MacOS/MacFSWApp
    Library/SystemExtensions/com.mas0n.MacFSW.EndpointExtension.systemextension
```

It embeds matching Xcode provisioning profiles when available, signs the embedded System Extension with `Configuration/MacFSWSystemExtension.entitlements`, and signs the host app with `Configuration/MacFSWApp.entitlements` when a valid Apple Development signing identity is available.

The host app and extension communicate over the Endpoint Security Mach service declared by `NSEndpointSecurityMachServiceName`. The configured local service name is:

```text
UYF535Y9QZ.com.mas0n.MacFSW.EndpointExtension.xpc
```

The app also checks its launch location and its own runtime entitlement before submitting a System Extension activation request. If the app is not launched from `/Applications`, or if the current process lacks `com.apple.developer.system-extension.install`, activation is blocked with an actionable packaging error. This prevents raw SwiftPM executables or incorrectly signed bundles from reaching `OSSystemExtensionManager`.

A production app bundle should still be archived from an Xcode project with:

- host app target
- Endpoint Security System Extension target
- `Configuration/Signing.xcconfig`
- host app entitlements
- system extension entitlements
- provisioning profiles that include the required restricted ES entitlement

## System Extension Onboarding

The app does not assume the System Extension is installed. On launch it checks XPC health. If the capture service is not reachable, the sidebar shows a System Extension onboarding card and the toolbar action changes from `Record` to `Enable Extension`.

Activation flow:

```text
Enable Extension
  -> OSSystemExtensionRequest.activationRequest
  -> macOS installs or updates the bundled System Extension
  -> user approval may be required in System Settings > General > Login Items & Extensions
  -> App checks XPC health again
  -> System Extension probes Endpoint Security permission by creating a short-lived ES client
  -> user grants Full Disk Access to MacFSW Endpoint Extension in Privacy & Security if required
  -> Record becomes available after the capture service is reachable and authorized
```

System Extension installation and update approval belongs in Login Items & Extensions. Endpoint Security authorization belongs to the MacFSW Endpoint Extension itself and is validated through `es_new_client`; failures with `ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED` should guide the user to System Settings > Privacy & Security > Full Disk Access.

The App can only request activation and guide the user. macOS owns approval, replacement, and failure decisions.

## Capture Contract

Capture is bound to XPC stream lifetime:

- App opens a capture stream.
- System Extension creates an ES client and subscribes to configured event types.
- System Extension batches events to the App.
- XPC interruption, invalidation, or explicit stop ends ES capture.

No heartbeat is required in v1 if this lifetime contract is kept strict.

## XPC Trust Boundary

The System Extension must not accept arbitrary XPC clients. The listener validates each incoming connection before calling `resume()`.

Required client identity:

```text
identifier "com.mas0n.MacFSW"
certificate leaf Team ID "UYF535Y9QZ"
entitlement "com.apple.developer.system-extension.install"
```

Connections that do not satisfy this code-signing requirement are invalidated and rejected. The XPC service must never return `true` unconditionally from `listener(_:shouldAcceptNewConnection:)`.
