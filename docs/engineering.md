# Engineering Notes

## Architecture

MacFSW is intentionally Swift-only:

- `MacFSWCore` contains product models, query logic, the SQLite event store, archive support, XPC payloads, the capture client, and `MacFSWCaptureSession`, the UI-independent session engine.
- `MacFSWApp` owns Session UX, event analysis, save/open workflows, and all App-layer orchestration.
- `MacFSWCommands` implements each agent- and script-facing operation once (`Workspace`, `SessionQueries`).
- `MacFSWCLI` builds the `macfsw` tool: ArgumentParser subcommands and a stdio MCP server (`macfsw mcp`), both thin front ends over `MacFSWCommands`.
- `MacFSWSystemExtension` owns Endpoint Security capture and XPC event streaming only.

The System Extension must remain a minimal sensor. It should not persist data, manage Sessions, or implement product search.

### Session engine

`MacFSWCaptureSession` (Core) is one session's event store plus the capture stream feeding it. The app and the CLI both drive recording through it:

- `start(config:)` returns once the extension accepted the stream and throws if it could not be opened. A `stop()` that arrives while the stream is still opening closes it as soon as it opens.
- XPC delivers batches and the finish signal on one serial queue; the engine funnels both into a single stream and appends to the store from one consumer, so batch order is preserved and the finish never overtakes the last batch.
- Recording stops on its own after `maxCaptureDurationSeconds`.
- Observers call `updates()` for appended events and state changes; each call gets an independent stream.

Session metadata (`MacFSWResearchSession`) stays with the caller. The app and the CLI never share a live session; recordings move between them as `.macfsw-session` files.

Saved sessions open read-only (`MacFSWSQLiteEventStore.openReadOnly`): no migrations run, files without the current schema are rejected, and the engine refuses to record into or clear them. Saving a read-only session copies the file and writes the metadata into the copy.

Temporary stores live in `macfsw-<uuid>` directories under the temporary directory. The owning process holds an exclusive `flock` on a marker file for the store's lifetime, and `cleanupStaleTemporaryStores()` deletes only directories whose lock it can take, so an app launch never deletes a running CLI's session.

### Query subsystem layering

The query language lives in `Sources/MacFSWCore/Query/` as a layered front-end
over a frozen semantic core:

- `QueryLexer` is the single positioned tokenizer; `QueryFieldTerm` is the
  single field/operator splitter. The parser, the completion cursor context
  (`QueryCursorContext`), and any future tooling (syntax highlighting,
  mid-cursor completion) consume these — never a second implementation.
- `QueryParser.parseDetailed` returns the query plus healing diagnostics;
  `parse` is a thin wrapper with identical output. Diagnostics name every
  lenient-heal path and never change interpretation.
- `QueryModel` holds the semantic AST (`MacFSWQueryExpression`) and the
  per-event matcher. The AST's Codable encoding is a **frozen wire format**
  (session archives persist saved queries as JSON): no case renames, no
  associated-value label changes, no new cases; new front-end types are
  deliberately not Codable. A fixture test guards the encoding.
- `QueryPrinter` renders canonical text; the round-trip property
  `parse ∘ print == identity` plus a golden corpus are the executable
  grammar specification. See [Query Syntax](query-syntax.md).

## App Target Structure

`MacFSWApp` is organized as a staged MVVM/Coordinator app:

```text
Sources/MacFSWApp/
  App/          App entry, AppDelegate, dependency environment, Coordinator
  Stores/       Feature state, task ownership, persistence adapters
  Views/        SwiftUI view surfaces grouped by feature
  Components/   Reusable view components
  Models/       App presentation models
  Support/      Pure helpers and reducers
```

`MacFSWApp.swift` is intentionally small. It wires the scenes, commands, Settings, and external Help links only.

`MacFSWAppCoordinator` is the root model views receive from the environment. It owns the feature stores and handles cross-feature actions, such as replacing a session, routing a process selection to Monitor or Analysis, and syncing capture failures with System Extension status. Views read stores through it (`model.monitor.queryText`) and bind with `@Bindable`; Observation tracks each property read, so a view re-renders only for state it uses.

Stores are `@Observable` and own both the state and the logic for their domain. Properties views never read (task handles, caches, generations) are `@ObservationIgnored`.

- `AppPreferencesStore`: default page, default process visibility, LLM settings persistence
- `SessionStore`: current research session metadata, the `MacFSWCaptureSession` behind it, capture state, health, and stats
- `SystemExtensionStatusStore`: activation state, Login Items and Full Disk Access shortcuts
- `MonitorStore`: query parsing and suggestions, result snapshots, selection, follow mode, the paged row cache, and live-tail rendering
- `ProcessSidebarStore`: process summary index, filtering, grouping, include-exited state
- `AnalysisStore`: selected analysis target, LLM stream task, connection test, report history
- `AppLogStore`: local diagnostic log settings and serialized writes to `~/Library/Logs/MacFSW/MacFSW.log`

Views should render state and forward user intent. They should not directly start XPC streams, open SQLite stores, touch Keychain, call LLM providers, or open System Settings. Those side effects belong in stores or the Coordinator.

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

Version metadata has a single source of truth in `Configuration/Signing.xcconfig`:

```text
MARKETING_VERSION = 0.1.8
CURRENT_PROJECT_VERSION = 16
```

Those are the standard Xcode build setting names for `CFBundleShortVersionString` and `CFBundleVersion`. App code must read the installed bundle metadata through `Bundle.main` when it needs the product version, for example when creating session metadata. Core libraries must not hardcode the App version.

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

## Event Store Performance

The App uses SQLite as the active session event store. Monitor filtering must avoid work proportional to every matching row whenever possible:

- Result snapshots are lightweight in-memory query descriptors, not materialized `result_rows` tables.
- The event table loads only the requested row windows from SQLite.
- FTS-backed text fields use FTS directly for normal text queries; wildcard and non-FTS fields fall back to `LIKE`.
- Operation summaries are refreshed after the table's initial rows are committed so large `GROUP BY` work does not block first paint.

This keeps broad filters usable on sessions with hundreds of thousands of events. Deep random scrolling can still hit SQLite `OFFSET` costs; keyset/cursor pagination is the next optimization if that becomes the dominant bottleneck.

## XPC Trust Boundary

The System Extension must not accept arbitrary XPC clients. `XPCClientPolicy` builds a code-signing requirement that the listener enforces through `setConnectionCodeSigningRequirement`; the system checks it against each peer's audit token, so it cannot be fooled by PID reuse.

Two client identities are admitted, both signed by Team ID `UYF535Y9QZ`:

```text
identifier "com.mas0n.MacFSW"      + entitlement "com.apple.developer.system-extension.install"   (the app)
identifier "com.mas0n.MacFSW.cli"                                                              (the macfsw tool)
```

`Scripts/package-dev-app.sh` signs `Contents/MacOS/macfsw` with the CLI identifier and verifies it. Each accepted connection gets its own capture service and Endpoint Security client, so the app and the CLI can record at the same time.

Health checks carry the running extension's `CFBundleVersion`, so the app and `macfsw status` can tell an outdated extension from a healthy one. When an older extension refuses the CLI's connection outright, the CLI reads the activated version from `systemextensionsctl list` instead. `macfsw setup` launches the app with `--setup-extension` (or posts `com.mas0n.MacFSW.setupExtension` to a running app) because only the app bundle may submit activation requests, then polls until the extension is ready.

Any change to the extension binary — like this policy — must ship with a new build number. macOS replaces an activated System Extension only when its `CFBundleVersion` changes, so bump `CURRENT_PROJECT_VERSION` in `Configuration/Signing.xcconfig`, repackage, and enable the System Extension again from the app. With an unchanged build number the previously activated binary keeps running.

## Agent Interface (MCP)

`macfsw mcp` serves the Model Context Protocol over stdio using the official `modelcontextprotocol/swift-sdk`. Each tool is one call into `MacFSWCommands`:

| Tool | Operation |
|---|---|
| `get_status` | `Workspace.status()` |
| `start_capture` / `stop_capture` | `Workspace.startCapture(_:)` / `stopCapture()` |
| `open_session` / `save_session` / `close_session` | `Workspace.open(_:)` / `save(to:overwrite:)` / `close()` |
| `summarize_events`, `list_processes`, `query_events`, `get_event` | `SessionQueries` |

Rules the tools keep:

- One active session per server process. Starting a capture after opening a file starts a new temporary session; files an agent opened are never written to, and saving refuses to overwrite unless asked.
- Results are compact JSON with ISO 8601 dates, returned as text content and as structured content.
- The `query_events` description lists query fields generated from `MacFSWQueryFieldCatalog`, so it cannot drift from the parser; a test checks every catalog field appears.
- Event fields are produced by observed programs. The server instructions and query tool descriptions tell the model to treat them as data, not instructions — a mitigation for prompt injection through crafted file or process names, not a guarantee.
