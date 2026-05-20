# MacFSW Product Development Whitepaper

## 1. Product Definition

MacFSW is a macOS file-system behavior analysis tool for developers and security researchers.

The product helps users observe, capture, search, and analyze file-system operations performed by a target process, XPC service, system component, installer, script, or application. It is designed for short, focused research sessions rather than long-running endpoint monitoring.

MacFSW answers questions such as:

- Which process touched this file?
- What did a target XPC service write, delete, rename, or chmod?
- Did a process modify sensitive locations such as LaunchAgents, preferences, caches, temporary directories, or application support folders?
- What file-system side effects happened during a specific reproduction step?
- Which events provide useful supporting detail for vulnerability analysis or a bug report?

MacFSW is not an EDR platform, antivirus product, prevention tool, backup tool, or long-term audit daemon.

## 2. Target Users

Primary users:

- macOS security researchers
- vulnerability researchers
- reverse engineers
- developers investigating application side effects
- engineers debugging installers, build tools, helper tools, daemons, and XPC services

Secondary users:

- advanced macOS users who need to understand file modifications
- QA engineers reproducing file-system side effects
- incident responders doing local triage

## 3. Product Principles

MacFSW follows these principles:

1. Capture is explicit and user-controlled.
2. System Extension work is minimized.
3. The App owns product-level Session state.
4. Data is in memory by default.
5. Persistence happens only when the user saves or exports.
6. The UI is optimized for reading, filtering, and analyzing large event streams.
7. Security-relevant signals are prioritized over raw completeness.
8. The product favors short, focused, high-fidelity capture windows.

## 4. Core Workflow

The main workflow is:

```text
Open MacFSW
  -> Create or select a Session
  -> Configure target and capture scope
  -> Record
  -> Trigger the behavior being researched
  -> Stop
  -> Search, filter, inspect, tag, and annotate events
  -> Save Session
```

Recording is not a background monitoring mode. Recording opens a live capture stream to the System Extension. Stopping or losing the connection stops Endpoint Security capture.

## 5. Architecture Overview

MacFSW uses a Swift-only architecture.

```text
MacFSW.app
  - UI
  - Session Manager
  - Capture Controller
  - In-memory Event Store
  - Query and Filter Engine
  - Import / Export

MacFSWSystemExtension
  - XPC CaptureStream endpoint
  - Endpoint Security lifecycle
  - Low-level event subscription
  - ES muting / low-level capture constraints
  - Event snapshotting
  - Batched event streaming
  - Drop / backpressure statistics
```

The System Extension does not manage product Sessions, save files, query history, or store events on disk.

## 6. System Extension Responsibility

The System Extension is a minimal capture sensor.

It is responsible for:

- accepting a capture stream connection from the App
- creating and destroying the Endpoint Security client
- subscribing only to requested ES event types
- applying low-level muting where appropriate
- copying minimal event data from ES callbacks
- batching events and sending them to the App
- tracking dropped events and backpressure
- stopping capture when the XPC stream disconnects

It is not responsible for:

- Session names
- saved views
- user annotations
- markers
- import / export
- SQLite or other persistent storage
- product-level query syntax
- long-term monitoring

## 7. Capture Lifecycle

Capture is bound to the XPC stream lifetime.

```text
Idle
  -> App opens CaptureStream
Capturing
  -> ES client created
  -> events subscribed
  -> events streamed to App
Stopping
  -> stream closed, interrupted, invalidated, or explicitly stopped
  -> unsubscribe / delete ES client
  -> flush queued batches
Idle
```

If the App crashes or the XPC connection is interrupted, the System Extension must stop ES capture automatically.

For v1, heartbeat or lease renewal is not required if capture is strictly tied to the live XPC stream. A hard maximum capture duration can still be used as a safety guard.

## 8. Capture Scope

The default capture profile should avoid high-noise read-style events.

Default v1 event categories:

- create
- write
- rename
- unlink
- link
- clone
- copyfile
- truncate
- exchangedata
- chmod / chown
- setacl
- setxattr / deletexattr
- utimes

Verbose read capture, such as open and close, should be opt-in and clearly labeled as high-volume.

Endpoint Security provides low-level controls such as event subscription, process muting, path muting, target-path muting, and mute inversion on supported macOS versions. These should be treated as capture constraints, not as the App's full query/filter system.

## 9. App Responsibility

The App is the product core.

It is responsible for:

- creating and managing Sessions
- connecting to the System Extension
- starting and stopping capture streams
- receiving event batches
- storing current Session data in memory
- rendering the live console
- searching and filtering events
- showing event detail
- adding markers, tags, and notes
- saving and opening native Session files

The App should support multiple Sessions, but v1 should allow only one active CaptureStream at a time.

## 10. Session Model

A Session represents a research task.

Session data includes:

- name
- creation time
- capture configuration
- target description
- event list
- markers
- notes
- tags
- saved views
- source metadata
- saved / unsaved state

Session examples:

- `Analyze com.apple.example.xpc writes`
- `Installer file-system side effects`
- `TCC database mutation test`
- `LaunchAgent persistence triage`

Sessions belong entirely to the App.

## 11. Data Model

Each event should contain:

- timestamp
- event type
- operation class
- target path
- source path, when applicable
- process name
- PID
- executable path
- audit token or stable process identity
- UID / GID
- signing ID
- team ID
- cdhash
- platform binary flag
- raw ES event type and version
- file ID / flags when available

Future extensions:

- parent process
- process tree
- launchd label
- XPC service identity
- sandbox/container identity
- TCC context
- event-specific metadata, such as xattr name or mode changes

## 12. In-Memory Event Store

By default, events are not persisted.

The App maintains an in-memory event store optimized for append, search, and UI virtualization.

Required capabilities:

- append batched events
- keep capture order and timestamp order
- support large event counts
- support memory limits
- track dropped / omitted events
- support fast filtering by time, process, PID, event type, path, signing identity, and risk hints

If event volume exceeds memory limits, the App may offer an explicit temporary spill mode. This is still App-owned and should not turn the System Extension into a storage service.

## 13. Query and Search

MacFSW needs two query layers.

Basic filters:

- event operation: `op:rename`, `event:unlink`, `type:write`
- operation class: `class:metadata`
- target path: `target:/Library/*`
- source path: `source:/tmp/*`
- combined path: `path:/Library`
- process name: `process:cfprefsd`, `name:xpc*`
- PID: `pid:3842`
- executable path: `executable:/usr/libexec/*`
- signing ID: `signing:com.apple.*`
- team ID: `team:UYF*`
- platform binary: `platform:true`
- risk: `risk:high`, `risk>=medium`
- risk reasons: `reason:sensitive*`
- UID/GID: `uid:501`, `gid:20`, `uidgid:501/20`
- raw event fields: `id:*`, `sequence>=1000`, `timestamp>0`, `rawtype:ES_EVENT_TYPE_NOTIFY_*`, `version:4`, `flags:0x*`
- derived research shortcuts: `mutation:true`, `sensitive:true`, `apple:false`

All string fields support case-insensitive wildcard matching with `*` and `?`. Adjacent terms are `AND`; `OR`, `NOT`, parentheses, comma-separated value lists, equality, inequality, and numeric comparisons are supported in the App query layer.

Advanced query syntax:

```text
process:cfprefsd op:write path:/Library/Preferences
pid:3842 op:rename
signing:com.apple.* path:/private/var
(op:chmod OR op:chown) path:/Library
path:/Library/LaunchAgents NOT platform:true
team:UYF* signing:com.mas0n.*
sequence>=1000 risk>=medium
```

Advanced queries are App-level analysis features. They should not be pushed into the System Extension.

## 14. UI / UX Direction

The UI should feel like a security research console, not a consumer file monitor.

Primary layout:

```text
Toolbar
  Record / Stop
  Freeze View
  Clear View
  Mark Time
  Save
  Export

Sidebar
  Sessions
  Saved Views
  Targets

Main Pane
  Query bar
  Event table
  Status bar

Inspector
  Event summary
  Process identity
  Path details
  Security context
  Raw event metadata
  Notes / tags
```

The event table is the primary surface. It must be dense, virtualized, keyboard-friendly, and optimized for scanning.

Default table columns:

- time
- risk
- operation
- process
- PID
- target path
- source path
- UID
- signing / team ID

The UI should distinguish:

- `Record`: starts ES capture
- `Stop`: stops ES capture
- `Freeze View`: stops live scrolling/rendering, but does not stop capture
- `Clear View`: clears visible/current unsaved events after confirmation
- `Mark Time`: inserts a timeline marker

## 15. Risk and Signal Design

Risk should be presented as a research hint, not as an automated vulnerability verdict.

High-signal examples:

- writes to LaunchAgents or LaunchDaemons
- chmod / chown / setacl
- delete or rename of sensitive files
- writes to preferences or TCC-related paths
- unsigned or third-party process touching privileged locations
- unexpected writes by an XPC service
- file replacement patterns involving rename or exchangedata

Risk labels should remain explainable. The UI should show why an event was highlighted.

## 16. Save and Open Sessions

- `Save Session`
- `Open Session`

Recommended session file:

```text
.macfsw-session
```

Session files are the only persisted project artifact in v1. Opening a saved Session must not start capture automatically.

## 17. Privacy and Security

MacFSW captures sensitive data:

- file paths
- process identities
- user names in paths
- system behavior
- potential secrets in filenames

Privacy rules:

- no default persistence
- no cloud upload
- explicit save only
- clear unsaved-session warnings
- System Extension should have the smallest practical responsibility

Security rules:

- no AUTH blocking in v1
- System Extension install/update approval is handled through Login Items & Extensions
- Endpoint Security permission is validated by the System Extension with `es_new_client`
- `ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED` should direct users to grant Full Disk Access to MacFSW Endpoint Extension in System Settings > Privacy & Security > Full Disk Access
- notify-only capture
- no automatic remediation
- no hidden background capture
- capture stops on XPC disconnect
- default profile avoids high-noise read events

## 18. Performance Requirements

Performance goals:

- ES callback does minimal work
- event batching is mandatory
- App table rendering is virtualized
- filtering does not block the main thread
- high-volume modes are opt-in
- backpressure and dropped event counts are visible
- System Extension avoids persistence and complex analysis

Backpressure policy should be explicit:

- drop low-priority events first where possible
- surface dropped event count in UI
- warn when UI cannot keep up
- optionally auto-stop on severe overload

## 19. v1 Scope

v1 should include:

- Swift-only architecture
- System Extension CaptureStream
- explicit Record / Stop
- mutation-focused default capture
- App-owned Session Manager
- in-memory Event Store
- live event table
- event Inspector
- basic filters
- advanced query MVP
- Mark Time
- Save / Open Session
- dropped event and capture health UI

v1 should not include:

- default persistence
- long-term background monitoring
- EDR-style policy management
- cloud sync
- AUTH event blocking
- automatic vulnerability detection
- multi-active capture streams

## 20. Development Phases

Phase 1: Product Skeleton

- Session model
- App shell
- test-only synthetic event fixtures
- virtualized event table prototype
- Inspector prototype

Phase 2: Capture Stream

- XPC stream between App and System Extension
- start/stop bound to connection lifetime
- ES notify subscription
- batched event delivery
- dropped event stats

Phase 3: Analysis Workspace

- in-memory event store
- basic filters
- query bar
- saved views
- markers and notes

Phase 4: File Workflows

- Save / Open Session
- schema versioning
- offline saved Session mode

Phase 5: Security Research Depth

- better process identity
- signing metadata
- launchd / XPC attribution where practical
- risk hints
- related event grouping
- comparison between Sessions

## 21. Open Questions

Open product questions:

- What should the default memory limit be?
- Should verbose read capture be hidden behind an advanced toggle?
- Should saved Sessions use SQLite, JSONL, or a package format combining both?
- How much risk classification should v1 include?
- What is the minimum viable advanced query grammar?
- How should MacFSW identify XPC service ownership reliably?
- Should imports be editable, read-only, or editable with local annotations?

## 22. Final Direction

MacFSW should be built as a session-driven macOS file-system behavior analyzer.

The System Extension should be minimal: it captures and streams events only while the App holds a live capture connection.

The App should be the full research workspace: Sessions, search, filtering, analysis, annotation, save/open, and UI.

This architecture minimizes system overhead, keeps privileged code small, avoids default persistence of sensitive data, and matches the workflow of developers and security researchers investigating focused file-system behavior.
