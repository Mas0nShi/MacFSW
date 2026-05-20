# MacFSW User Manual

Applies to the current MacFSW release.

## Quick Start

Use this path when you just need to capture and inspect one behavior:

1. Open MacFSW from `/Applications`.
2. Confirm the System Extension status is ready in the sidebar.
3. If the sidebar asks for approval, use Login Items & Extensions for System Extension approval or Full Disk Access for Endpoint Security authorization.
4. Keep the default Focused Mutations capture profile unless you specifically need read events.
5. Click Record.
6. Reproduce the behavior you are researching.
7. Click Stop.
8. Filter the event table with queries such as `process:installer`, `path:/Library`, or `rawtype:ES_EVENT_TYPE_NOTIFY_WRITE`.
9. Select important rows and review the inspector.
10. Save the session only if you want to keep the captured data.

Use Help > MacFSW User Manual to open the current manual on GitHub.

## Contents

- Quick Start
- 1. What MacFSW Is
- 2. Requirements
- 3. First Launch and Permissions
- 4. Main Window Overview
- 5. Recommended Workflow
- 6. Sessions
- 7. Recording
- 8. Monitor Page
- 9. Process Sidebar
- 10. Event Detail Inspector
- 11. Query Syntax Reference
- 12. Analysis Beta
- 13. System Extension Settings
- 14. Logs
- 15. Privacy Model
- 16. Troubleshooting
- 17. Keyboard Shortcuts
- 18. Glossary

## 1. What MacFSW Is

MacFSW is a macOS file-system behavior analysis tool for developers, security researchers, reverse engineers, QA engineers, and advanced users who need to understand which processes create, write, rename, delete, or modify files.

MacFSW is designed for short, explicit research sessions. It is useful when you need to answer questions such as:

- Which process touched this file?
- What did an installer write or delete?
- Did an XPC service modify LaunchAgents, preferences, caches, or temporary files?
- What file-system side effects happened during a reproduction step?
- Which events should be included in a bug report, vulnerability note, or research log?

MacFSW is not an antivirus, EDR, backup tool, file recovery tool, prevention product, or long-running audit daemon. It observes file-system events while you choose to record.

## 2. Requirements

MacFSW requires:

- macOS 14 or later
- a signed MacFSW app bundle installed in `/Applications`
- the MacFSW Endpoint Extension installed and enabled
- Endpoint Security permission for the MacFSW Endpoint Extension
- Full Disk Access for the MacFSW Endpoint Extension when macOS requires it

The command-line `swift run MacFSWApp` workflow is useful for UI development, but it does not carry the same app bundle structure and entitlements required to install or update the System Extension.

## 3. First Launch and Permissions

MacFSW uses a macOS Endpoint Security System Extension named `MacFSW Endpoint Extension`.

There are two separate permission paths:

- System Extension install or update approval
- Endpoint Security / Full Disk Access authorization

These are different concepts and appear in different locations in System Settings.

### 3.1 Enable the System Extension

When MacFSW asks macOS to install or update the System Extension, macOS may require user approval.

Open:

```text
System Settings > General > Login Items & Extensions
```

Then find the Endpoint Security Extensions section and approve or enable `MacFSW Endpoint Extension`.

In MacFSW, use:

```text
Settings > System Extension > Enable or Update
```

or the System Extension status card in the sidebar.

### 3.2 Grant Endpoint Security / Full Disk Access

After the System Extension is installed, it still needs permission to create an Endpoint Security client. MacFSW checks this by asking the System Extension to create a short-lived Endpoint Security client.

If the check fails with `ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED`, grant permission here:

```text
System Settings > Privacy & Security > Full Disk Access
```

Enable:

```text
MacFSW Endpoint Extension
```

Granting Full Disk Access to the host app is not enough for Endpoint Security capture. The permission must be granted to the System Extension.

### 3.3 Check Readiness

Use:

```text
Settings > System Extension > Check Again
```

or the sidebar status card.

The ready state means:

- the app can reach the extension
- Endpoint Security is available
- the extension can create an Endpoint Security client

## 4. Main Window Overview

MacFSW has two main pages:

- Monitor
- Analysis Beta

The left sidebar contains:

- page switcher
- process list
- operation summary
- System Extension status

The main area changes based on the selected page.

The Monitor page contains:

- query bar
- Record / Stop button
- Jump to Live button when live view is not at the newest event
- Clear button
- event table
- event detail inspector
- status bar

The Analysis page contains:

- report history
- selected process target
- Run / Cancel controls
- Markdown report output

## 5. Recommended Workflow

Use this flow for most investigations:

1. Open MacFSW.
2. Confirm the System Extension status is ready.
3. Open Settings and choose the capture profile.
4. Click Record.
5. Reproduce the behavior you want to inspect.
6. Click Stop.
7. Search or filter the event table.
8. Select high-signal events and inspect details.
9. Save the session if you want to keep the data.
10. Optionally run Analysis Beta for a selected process.

Keep capture windows focused. Short recordings are easier to review and produce less noise.

## 6. Sessions

A session contains:

- session metadata
- capture settings
- captured events
- current query state
- process summaries
- analysis results

### 6.1 New Session

Use:

```text
File > New Session
```

MacFSW asks before replacing the current session. This prevents accidental loss of unsaved captured events or analysis results.

### 6.2 Save Session

Use:

```text
File > Save Session...
```

MacFSW saves a `.macfsw-session` file. Save sessions when you need to preserve captured events or share a research artifact.

### 6.3 Open Session

Use:

```text
File > Open Session...
```

Opening a saved session does not start capture automatically.

### 6.4 Temporary Session Storage

MacFSW uses temporary SQLite-backed session storage while you work. Temporary backing directories are owned by the app and are cleaned when sessions are replaced, opened, imported, or when the app exits cleanly.

Saving a session is still explicit. Do not assume an unsaved session is a durable record.

## 7. Recording

The Record button opens a live capture stream to the System Extension. The System Extension creates an Endpoint Security client, subscribes to configured events, batches events, and streams them back to the app.

The Stop button stops capture. If the app quits or the XPC stream disconnects, the System Extension stops capture.

Recording is not a hidden background mode. Capture happens only while the stream is active.

### 7.1 Record Button States

The button may show:

- Record: the extension is ready and capture can start
- Stop: capture is active
- Enable Extension: the System Extension needs install or update approval
- Open Full Disk Access: the extension needs Endpoint Security / Full Disk Access authorization

### 7.2 Capture Settings

Open:

```text
Settings > Capture
```

Capture settings are locked while recording or connecting.

Available capture profiles:

- Focused Mutations: default profile for create, write, rename, delete, link, copy, clone, truncate, and metadata changes
- Verbose Reads: includes read-style events such as open and close
- Full System Burst: broad high-volume capture for short bursts

Use verbose profiles carefully. Read-style events can produce high event volume.

### 7.3 Duration

The Duration setting limits capture length. This is a safety control for accidental long recordings.

### 7.4 Batching

Batch Size controls how many events are delivered per batch.

Batch Interval controls how frequently queued events are flushed.

Smaller batches can feel more immediate. Larger batches can reduce overhead during high-volume captures.

### 7.5 Excluded Processes

Excluded Processes is a newline-separated list of process name fragments. Matching events are skipped.

MacFSW excludes itself by default to reduce noise.

### 7.6 Excluded Paths

Excluded Paths is a newline-separated list of path fragments or prefixes. Matching events are skipped.

Use this to remove known noisy directories from a focused investigation.

## 8. Monitor Page

The Monitor page is the primary event review surface.

### 8.1 Query Bar

The query bar filters the event table. Filtering is app-level and does not change the System Extension subscription.

Examples:

```text
process:cfprefsd path:/Library/Preferences
op:rename OR op:unlink
(op:chmod OR op:chown) path:/Library
path:/Library/LaunchAgents NOT platform:true
team:UYF* signing:com.mas0n.*
sequence>=1000 path:/Library
rawtype:ES_EVENT_TYPE_NOTIFY_WRITE
rawtype:987654
```

### 8.2 Event Table

The event table is optimized for scanning large event streams. Rows include operation, process, PID, path, signing details, and related metadata.

Select a row to open event details in the inspector.

### 8.3 Jump to Live

When capture is active and you scroll away from the newest event, MacFSW stops forcing the table to the live edge. Use Jump to Live to return to the latest events.

### 8.4 Clear

Clear removes the current view's visible event data from the active unsaved session context. Save first if you need to keep the data.

## 9. Process Sidebar

The process sidebar groups captured events by process.

Clicking a process behaves differently by page:

- On Monitor, it filters events for that process.
- On Analysis Beta, it selects the process as the analysis target.

The Include Exited toggle controls whether processes that are no longer running remain visible in the process list.

Use:

```text
Settings > General > Show exited processes by default
```

to control the default value for new sessions.

## 10. Event Detail Inspector

The inspector shows details for the selected event.

Common sections include:

- Summary
- Path
- Process
- Identity
- Raw Event

Important fields:

- Raw Type: symbolic Endpoint Security event name when available
- ES Event Raw Value: numeric Endpoint Security event raw value
- ES Version: Endpoint Security message version
- Flags: event-specific flags when available
- UID/GID: effective user and group identity
- Audit Token: process audit identity
- CDHash: code directory hash when available

Use raw values when comparing behavior across macOS SDKs, OS versions, or lower-level Endpoint Security traces.

## 11. Query Syntax Reference

MacFSW supports structured query fields, boolean operators, wildcard matching, and numeric comparisons.

### 11.1 Operators

Supported operators:

- adjacent terms mean AND
- `OR`
- `NOT`
- parentheses
- `:`
- `=`
- `!=`
- `>`
- `>=`
- `<`
- `<=`
- comma-separated value lists

String matching is case-insensitive. Use `*` and `?` as wildcards.

### 11.2 Common Fields

Operation fields:

```text
op:write
event:unlink
type:rename
class:metadata
mutation:true
```

Path fields:

```text
path:/Library
target:/Library/LaunchAgents/*
source:/tmp/*
```

Process fields:

```text
process:cfprefsd
name:xpc*
pid:3842
executable:/usr/libexec/*
platform:true
apple:false
```

Signing fields:

```text
signing:com.apple.*
team:UYF*
cdhash:abcdef*
```

Identity fields:

```text
uid:501
gid:20
uidgid:501/20
audit:*
```

Raw event fields:

```text
id:*
sequence>=1000
timestamp>0
rawtype:ES_EVENT_TYPE_NOTIFY_WRITE
rawtype:987654
version:4
flags:0x*
```

### 11.3 Practical Queries

Find LaunchAgent writes by third-party processes:

```text
path:/Library/LaunchAgents mutation:true apple:false
```

Find metadata permission changes:

```text
op:chmod OR op:chown OR op:setacl
```

Find writes by a process family:

```text
process:installer path:/Library
```

Find non-Apple activity in privileged paths:

```text
path:/Library apple:false
```

Find raw Endpoint Security write events by numeric raw value:

```text
rawtype:987654
```

## 12. Analysis Beta

Analysis is marked Beta because its output depends on the selected model, provider behavior, configured limits, and the quality of captured event data.

Analysis sends a scoped summary of selected process activity to the configured LLM provider. The payload can include:

- process identity
- operation counts
- top paths
- recent event samples
- raw event metadata when available

API keys are stored in Keychain.

### 12.1 Configure Analysis

Open:

```text
Settings > Analysis
```

Configure:

- Endpoint
- Base URL
- API Key
- Model
- Stream response
- Max Events
- Token Budget
- Timeout

Use Test Connection before running analysis.

### 12.2 Run Analysis

1. Switch to Analysis Beta.
2. Select a process in the process sidebar.
3. Click Run.
4. Review the streaming Markdown report.
5. Select completed reports from the report history.

### 12.3 Limits and Privacy

Analysis can send event summaries and path data to the configured provider. Review provider terms and local policy before sending private captures.

Use lower Max Events and Token Budget settings when working with private or very large sessions.

## 13. System Extension Settings

Open:

```text
Settings > System Extension
```

This pane shows:

- current install state
- readiness message
- Enable or Update
- Check Again
- Login Items & Extensions shortcut
- Full Disk Access shortcut

Use Enable or Update after installing a new app build that contains a newer System Extension version.

macOS may keep old System Extension versions in:

```text
terminated waiting to uninstall on reboot
```

This is expected after replacement. Reboot to let macOS finish cleanup.

## 14. Logs

Open:

```text
Settings > Logs
```

MacFSW writes local diagnostic logs to:

```text
~/Library/Logs/MacFSW/MacFSW.log
```

The Logs settings pane controls whether diagnostic logs are written, the minimum log level, and actions to open the logs folder, copy the log path, or clear the log file.

Capture, System Extension, SQLite, and analysis errors are written with full error details so status bar truncation does not hide the actionable failure.

## 15. Privacy Model

MacFSW captures private local information:

- file paths
- process names
- executable paths
- signing identifiers
- user and group IDs
- behavior timing
- potentially private filenames

MacFSW does not intentionally run hidden background capture. Recording is explicit.

Session persistence is explicit. Save a session only when you want a durable artifact.

Analysis Beta may send selected event summaries to your configured LLM provider. The app does not silently upload captures outside that user-triggered analysis flow.

## 16. Troubleshooting

### 15.1 Record Shows Enable Extension

The System Extension is missing, disabled, outdated, or not approved.

Use:

```text
Settings > System Extension > Enable or Update
```

Then approve it in:

```text
System Settings > General > Login Items & Extensions
```

### 15.2 Record Shows Open Full Disk Access

The System Extension is installed, but macOS denied Endpoint Security client creation.

Open:

```text
System Settings > Privacy & Security > Full Disk Access
```

Enable:

```text
MacFSW Endpoint Extension
```

Then return to MacFSW and click Check Again.

### 15.3 Endpoint Security Error Includes rawValue 4

`ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED` with `rawValue: 4` means the System Extension does not have the required Endpoint Security / Full Disk Access authorization.

Grant permission to `MacFSW Endpoint Extension`, not only to `MacFSW.app`.

### 15.4 Extension Is Activated but Capture Still Fails

Try these steps:

1. Quit MacFSW.
2. Reopen MacFSW from `/Applications`.
3. Open Settings > System Extension.
4. Click Check Again.
5. If needed, click Enable or Update.
6. Confirm Full Disk Access for `MacFSW Endpoint Extension`.
7. Reboot if old extension versions are waiting to uninstall.

### 15.5 No Events Appear

Check:

- capture is recording
- the target behavior actually performs file-system operations
- query text is not filtering everything out
- selected process filter is not too narrow
- excluded paths or excluded process names are not hiding the events
- the capture profile includes the event type you expect

### 15.6 Too Many Events Appear

Use:

- Focused Mutations profile
- path queries
- process filters
- excluded paths
- excluded process names
- shorter capture duration

Avoid verbose read capture unless you specifically need open and close events.

### 15.7 Analysis Fails

Check:

- API key is configured
- Base URL and Endpoint match your provider
- model name is valid
- network access is available
- timeout is high enough
- Token Budget and Max Events are within provider limits

Use Test Connection in Settings > Analysis.

## 17. Keyboard Shortcuts

Common shortcuts:

```text
Command-N            New Session
Command-O            Open Session
Command-S            Save Session
Command-Shift-/      Open MacFSW User Manual on GitHub
```

macOS may display `Command-Shift-/` as `Command-?`.

## 18. Glossary

Endpoint Security:
Apple's macOS framework for observing system events through an entitled System Extension.

System Extension:
A separately approved macOS extension bundle that runs outside the host app and owns Endpoint Security capture.

Full Disk Access:
A macOS privacy permission required for some protected system capabilities. For MacFSW capture, grant it to `MacFSW Endpoint Extension`.

Session:
The current research workspace containing capture settings, events, filters, and analysis results.

Mutation:
A file-system operation that changes state, such as create, write, rename, unlink, chmod, chown, setacl, setextattr, or truncate.

Raw Event Value:
The numeric raw value of the underlying Endpoint Security event type. This is useful for debugging SDK or OS-version differences.

Analysis Beta:
An optional LLM-assisted report feature that summarizes selected process behavior using the configured provider.
