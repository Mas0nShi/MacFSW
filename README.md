# MacFSW

<p align="center">
  <img src="https://github.com/user-attachments/assets/491e94a1-82a3-4967-a3b2-c862192fb6c4" alt="MacFSW monitor showing a focused macOS file-system capture session" width="100%">
</p>

<p align="center">
  <a href="https://swift.org"><img alt="Swift 6.0" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
  <a href="LICENSE"><img alt="License Apache 2.0" src="https://img.shields.io/badge/License-Apache--2.0-2563eb"></a>
</p>

MacFSW is a focused macOS file-system behavior analyzer for security researchers, reverse engineers, developers, and QA engineers who need to understand what changed on disk during a specific action.

It records short, explicit Endpoint Security capture sessions and turns noisy file-system activity into a searchable timeline of processes, paths, operations, signing identity, raw ES metadata, and process-scoped analysis context.

MacFSW is useful when you need to answer questions like:

- What did this installer create, modify, rename, or delete?
- Which process touched a suspicious LaunchAgent, preference file, cache, or temporary path?
- What file-system side effects happened during a reproduction step?
- Did an XPC service, helper tool, daemon, or build script mutate privileged locations?
- Which high-signal events should be saved with a bug report, vulnerability note, or research log?

MacFSW is not an antivirus, EDR, prevention product, backup tool, file recovery tool, or long-running audit daemon. It observes events only during user-controlled recording windows.

## Highlights

- Endpoint Security based capture through a minimal macOS System Extension.
- Focused Mutations profile for high-signal write, rename, delete, copy, clone, truncate, link, and metadata events.
- Optional verbose capture profiles for short high-volume read or full-system bursts.
- Live monitor with process grouping, operation summaries, row-window loading, and jump-to-live behavior.
- Structured query language with boolean logic, wildcards, numeric comparisons, raw ES event filters, and signing identity filters.
- Native `.macfsw-session` files for explicitly saved research artifacts.
- Process-scoped Analysis Beta that can stream Markdown reports from a user-configured LLM provider.
- Privacy-first session model: captured data is temporary by default and persistence happens only when the user saves.

## Quick Start

Real capture requires a signed app bundle installed from `/Applications` with the System Extension embedded and approved by macOS.

1. Build and package the development app bundle:

   ```bash
   Scripts/package-dev-app.sh
   cp -R .build/bundles/MacFSW.app /Applications/
   open /Applications/MacFSW.app
   ```

2. In MacFSW, enable or update the System Extension.
3. Approve `MacFSW Endpoint Extension` in:

   ```text
   System Settings > General > Login Items & Extensions
   ```

4. If prompted, grant Full Disk Access to `MacFSW Endpoint Extension` in:

   ```text
   System Settings > Privacy & Security > Full Disk Access
   ```

5. Click Record, reproduce the behavior, then click Stop.
6. Filter and inspect the event table, then save a `.macfsw-session` file only if you want to keep the capture.

For the full user workflow, see [docs/user-manual.md](docs/user-manual.md).

## Query Examples

```text
process:installer path:/Library
path:/Library/LaunchAgents mutation:true apple:false
op:rename OR op:unlink
(op:chmod OR op:chown) path:/Library
team:UYF* signing:com.mas0n.*
sequence>=1000 path:/Library
rawtype:ES_EVENT_TYPE_NOTIFY_WRITE
rawtype:987654
```

Supported query features include adjacent-term `AND`, `OR`, `NOT`, parentheses, `:`, `=`, `!=`, `>`, `>=`, `<`, `<=`, comma-separated values, and `*` / `?` wildcards.

## Requirements

Runtime:

- macOS 14 or later.
- A signed `MacFSW.app` bundle installed in `/Applications`.
- An enabled `MacFSW Endpoint Extension`.
- Endpoint Security authorization for the System Extension.
- Full Disk Access for the System Extension when macOS requires it.

Development:

- Swift 6 toolchain.
- Xcode command line tools.
- Apple Development signing identity for local System Extension testing.
- Apple-approved `com.apple.developer.endpoint-security.client` entitlement for real Endpoint Security capture.

The host app uses `com.apple.developer.system-extension.install`. The System Extension uses `com.apple.developer.endpoint-security.client`. Adding entitlement files locally is not enough; the App IDs and provisioning profiles must include the required capabilities.

## Development

Run tests:

```bash
swift test
```

Launch the SwiftPM executable for UI and shared-logic development:

```bash
swift run MacFSWApp
```

`swift run MacFSWApp` does not produce a signed `.app` bundle and cannot install or activate the System Extension. Use the app bundle workflow when testing real capture.

Package a local development app:

```bash
Scripts/package-dev-app.sh
cp -R .build/bundles/MacFSW.app /Applications/
open /Applications/MacFSW.app
```

Set a signing identity explicitly when needed:

```bash
CODE_SIGN_IDENTITY="<identity hash or common name>" Scripts/package-dev-app.sh
```

If you need explicit provisioning profiles:

```bash
MACFSW_HOST_PROVISIONING_PROFILE=/path/to/host.provisionprofile \
MACFSW_EXTENSION_PROVISIONING_PROFILE=/path/to/extension.provisionprofile \
Scripts/package-dev-app.sh
```

See [docs/xcode-packaging.md](docs/xcode-packaging.md) for production packaging notes.

## Architecture

MacFSW is intentionally Swift-only and keeps product state in the app, not in the System Extension.

```text
MacFSW.app
  - SwiftUI / AppKit interface
  - App Coordinator and feature stores
  - Session lifecycle
  - SQLite-backed active event store
  - Query and filter engine
  - Save / open session workflows
  - Analysis Beta

MacFSW Endpoint Extension
  - Endpoint Security client lifecycle
  - Low-level event subscription
  - Capture constraints and muting
  - Event snapshotting
  - Batched XPC event streaming
  - Drop and backpressure statistics
```

Capture is bound to the live XPC stream. When the app stops recording, crashes, or loses the connection, the System Extension tears down Endpoint Security capture.

## Repository Layout

```text
Sources/MacFSWCore              Product models, query logic, archives, event stores, XPC contracts
Sources/MacFSWApp               SwiftUI/AppKit app, Coordinator, stores, views, settings
Sources/MacFSWAnalysis          Process-scoped analysis payloads and LLM client integration
Sources/MacFSWSystemExtension   Endpoint Security capture service and XPC listener
Sources/MacFSWEndpointExtension System Extension executable entry point
Tests                           Unit tests for core, app, analysis, and XPC authorization behavior
Configuration                   Info.plist, entitlements, and signing configuration
Scripts                         Local check and app packaging scripts
docs                            User, engineering, product, and packaging documentation
```

## Security and Privacy Model

- Recording is explicit and user-controlled.
- The System Extension is a minimal capture sensor and does not own sessions, queries, saved files, or analysis.
- Active session storage is app-owned and temporary unless the user saves a `.macfsw-session` file.
- Analysis Beta runs only when the user starts it and may send scoped event summaries to the configured provider.
- API keys for analysis providers are stored in Keychain.
- The XPC listener validates client identity before accepting capture connections.

## Documentation

- [User Manual](docs/user-manual.md)
- [Engineering Notes](docs/engineering.md)
- [Product Development Whitepaper](docs/product-whitepaper.md)
- [Xcode Packaging Plan](docs/xcode-packaging.md)

## License

MacFSW is released under the [Apache License 2.0](LICENSE).
