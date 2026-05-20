# App Bundle Packaging Plan

SwiftPM is the development and verification surface for this repository. A raw SwiftPM executable is not enough for System Extension activation because it has no `.app` bundle, no embedded `.systemextension`, no `Info.plist`, and no host app entitlements.

For local development, use:

```bash
Scripts/package-dev-app.sh
cp -R .build/bundles/MacFSW.app /Applications/
open /Applications/MacFSW.app
```

The script builds this structure:

```text
MacFSW.app
  Contents/
    Info.plist
    MacOS/MacFSWApp
    Library/
      SystemExtensions/
        com.mas0n.MacFSW.EndpointExtension.systemextension/
          Contents/
            Info.plist
            MacOS/MacFSWEndpointExtension
```

Set `CODE_SIGN_IDENTITY` if automatic identity discovery does not find the correct Apple Development certificate.

```bash
CODE_SIGN_IDENTITY="<identity hash or common name>" Scripts/package-dev-app.sh
```

If you need to embed explicit provisioning profiles:

```bash
MACFSW_HOST_PROVISIONING_PROFILE=/path/to/host.provisionprofile \
MACFSW_EXTENSION_PROVISIONING_PROFILE=/path/to/extension.provisionprofile \
Scripts/package-dev-app.sh
```

Use `CODE_SIGN=0 Scripts/package-dev-app.sh` only to inspect bundle structure. Unsigned bundles cannot activate the System Extension.

By default the script searches Xcode's local provisioning profile directory and embeds matching profiles for both bundles. The host profile must include `com.apple.developer.system-extension.install`; the extension profile must include `com.apple.developer.endpoint-security.client`.

After signing, the packaging script verifies that:

- the host app contains `com.apple.developer.system-extension.install`
- the System Extension contains `com.apple.developer.endpoint-security.client`
- the host app `Info.plist` contains `NSSystemExtensionUsageDescription`
- the host app and System Extension agree on the XPC service name

If either entitlement is missing, the script fails before you launch the app.

For production distribution, create an Xcode project/archive because Endpoint Security requires a signed System Extension bundle and valid provisioning profiles.

For the GitHub Actions path that signs, notarizes, staples, and uploads the current SwiftPM-packaged artifact, see `docs/github-actions-signing.md`.

Release DMGs are assembled with `Scripts/create-release-dmg.sh`, which adds an `Applications` shortcut and Finder background guidance. This is intentional: MacFSW must be copied to `/Applications` before launch so macOS can activate the bundled System Extension normally.

## Required Targets

Create an Xcode project with these targets:

- `MacFSW`: macOS host application
- `MacFSWEndpointExtension`: Endpoint Security System Extension
- `MacFSWCoreTests`: unit tests for shared product logic

The host app target should include:

- `Sources/MacFSWApp`
- `Sources/MacFSWCore`
- `Configuration/MacFSWApp-Info.plist`
- `Configuration/MacFSWApp.entitlements`

The System Extension target should include:

- `Sources/MacFSWSystemExtension`
- `Sources/MacFSWCore`
- `Configuration/MacFSWSystemExtension-Info.plist`
- `Configuration/MacFSWSystemExtension.entitlements`

## Build Settings

Use `Configuration/Signing.xcconfig` as the shared base config.

Baseline values:

```text
DEVELOPMENT_TEAM = UYF535Y9QZ
MARKETING_VERSION = 0.1.6
CURRENT_PROJECT_VERSION = 9
MACFSW_HOST_BUNDLE_ID = com.mas0n.MacFSW
MACFSW_EXTENSION_BUNDLE_ID = com.mas0n.MacFSW.EndpointExtension
MACFSW_XPC_SERVICE_NAME = UYF535Y9QZ.com.mas0n.MacFSW.EndpointExtension.xpc
```

`MARKETING_VERSION` is the user-facing release version and maps to `CFBundleShortVersionString`. `CURRENT_PROJECT_VERSION` is the monotonically increasing build number and maps to `CFBundleVersion`. Do not add a second Swift constant for the product version; runtime code should read the bundled Info.plist through `Bundle.main`.

Host app:

```text
PRODUCT_BUNDLE_IDENTIFIER = $(MACFSW_HOST_BUNDLE_ID)
CODE_SIGN_ENTITLEMENTS = Configuration/MacFSWApp.entitlements
```

System Extension:

```text
PRODUCT_BUNDLE_IDENTIFIER = $(MACFSW_EXTENSION_BUNDLE_ID)
CODE_SIGN_ENTITLEMENTS = Configuration/MacFSWSystemExtension.entitlements
```

The Endpoint Security extension `Info.plist` must include:

```text
NSEndpointSecurityMachServiceName = $(MACFSW_XPC_SERVICE_NAME)
```

The host app reads `MacFSWXPCServiceName` from its own `Info.plist` and connects to the same Mach service.

## Entitlement Requirements

The host app needs:

```text
com.apple.developer.system-extension.install
```

The System Extension needs Apple approval for:

```text
com.apple.developer.endpoint-security.client
```

The entitlement must exist on the System Extension App ID and provisioning profile. Adding the entitlement file to the repository is not enough.

## User Activation Flow

The host app uses `OSSystemExtensionRequest.activationRequest` to ask macOS to activate the bundled System Extension. If macOS requires user approval, the App surfaces an onboarding card and opens System Settings > General > Login Items & Extensions.

After activation, the System Extension must still pass Endpoint Security authorization. The supported runtime check is creating an ES client with `es_new_client`; `ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED` means the MacFSW Endpoint Extension needs Full Disk Access / Endpoint Security permission in System Settings > Privacy & Security > Full Disk Access.

The app bundle must be launched from `/Applications` for normal activation. During low-level extension development, macOS developer mode can relax the location check, but production behavior should be validated from `/Applications`.

Record should remain gated until the XPC capture service is reachable.

## Development Backend

The app always uses the XPC capture backend. SwiftPM builds can validate shared logic and UI compilation, but real capture requires a signed host app bundle with the System Extension installed and approved.
