# SSH Auto Remote Sessions Design

Date: 2026-04-28

## Summary

cmux should make SSH feel like a natural capability of any terminal surface instead of a separate "remote workspace" mode. A workspace can contain local terminals, normal SSH terminals detected after the fact, daemon-managed remote terminals, and browser panes at the same time. The user should not need to decide whether a workspace is local or remote.

The approved approach has two layers:

1. Passive SSH enhancement is enabled by default. When a cmux terminal is running a foreground interactive `ssh host`, cmux detects the SSH destination, deploys or starts remote support for that host in the background, and associates the terminal surface with that remote transport. The existing OpenSSH shell keeps running unchanged and is not recoverable through the remote daemon.
2. Recoverable SSH auto-upgrade is optional and off by default. When enabled, cmux shell integration intercepts conservative interactive `ssh host` commands before OpenSSH starts, and upgrades them into daemon-managed remote terminal sessions. These upgraded sessions are recoverable from the remote daemon when the remote daemon and session artifacts are available.

## Goals

- Let users type `ssh host` in a normal cmux terminal and get useful remote-aware behavior without needing to remember `cmux ssh host`.
- Preserve ordinary SSH behavior by default.
- Make recoverability a surface/session property, not a workspace identity.
- Reuse the current remote daemon bootstrap, proxy, relay, reconnect, and resize behavior where possible.
- Keep existing `cmux ssh ...` and `workspace.remote.*` APIs compatible during migration.

## Non-Goals

- Do not claim that an already-running OpenSSH shell can be migrated into a daemon-managed PTY. It cannot.
- Do not intercept scripted SSH usage by default.
- Do not rewrite `scp`, `sftp`, `rsync`, Git SSH transports, or non-interactive SSH commands.
- Do not require users to create separate remote workspaces to use remote browser routing.

## Current State

`cmux ssh ...` creates a workspace, sends `workspace.remote.configure`, and starts a `WorkspaceRemoteSessionController`. The controller probes the host, uploads or verifies `cmuxd-remote`, starts the daemon transport, publishes a proxy endpoint, and starts relay support.

Plain `ssh host` inside a cmux terminal is currently only detected for file and image drop routing. `TerminalSSHSessionDetector` can infer destination, port, identity, jump host, control path, and selected options from the foreground `ssh` process on a terminal TTY. That detector should become a general surface lifecycle input, not just a drop-time helper.

Recent local daemon work has also strengthened local terminal recovery. That supports the broader product direction: terminal durability should be described per surface, whether backed by the local daemon, by a remote daemon, or only by scrollback replay.

## UX Model

Every terminal surface has a durability and remote-support status.

- Local daemon-backed terminal: recoverable while local daemon session artifacts are available.
- Plain local terminal without daemon backing: not recoverable beyond scrollback replay.
- Detected SSH terminal: remote enhanced, not recoverable.
- Managed remote terminal: remote recoverable.

Passive enhancement behavior:

- The user types `ssh host`.
- cmux detects the foreground SSH process once it is running.
- cmux associates that surface with a detected remote host.
- cmux starts remote support in the background.
- Browser panes opened from that source surface route through the remote host once the daemon proxy is ready.
- If remote support fails, the SSH shell continues normally and the UI reports that remote support is unavailable.

Auto-upgrade behavior:

- The user enables a setting named "Upgrade interactive ssh commands to recoverable remote sessions".
- The user types a plain interactive `ssh host`.
- cmux shell integration intercepts the command before OpenSSH starts.
- cmux creates or attaches a daemon-managed remote terminal session in the current surface context.
- If upgrade cannot complete, cmux falls back to executing the original SSH command and records a status entry explaining the fallback.

## Data Model

Add a surface-level remote attachment concept. The exact type names can be adjusted to fit the existing Swift model, but the state should be equivalent to:

```swift
enum TerminalRemoteAttachment {
    case none
    case detectedSSH(DetectedSSHAttachment)
    case managedRemote(ManagedRemoteAttachment)
}
```

`DetectedSSHAttachment` stores normalized SSH destination metadata:

- destination
- display target
- port
- identity file presence/path as needed for background SSH operations
- selected SSH options after filtering unsafe process-specific options
- transport key
- daemon/proxy state
- recoverable: false

`ManagedRemoteAttachment` stores daemon-managed session metadata:

- destination
- display target
- transport key
- remote daemon path and version when ready
- remote session ID or attachment ID
- relay port and relay credentials where applicable
- proxy endpoint state
- recoverable: true

Existing `WorkspaceRemoteConfiguration` should remain for compatibility, but new behavior should resolve terminal and browser behavior through surface attachments. `cmux ssh ...` can continue to call the old APIs initially, then gradually become a wrapper that creates a managed remote surface in a normal workspace.

## Components

### SSH Surface Detector

Extend use of `TerminalSSHSessionDetector` from drop-time detection to surface lifecycle detection. The detector should run for active terminal surfaces with known TTY names and publish attachment updates when the foreground process changes into or out of a supported `ssh` process.

Detection should be debounced so it does not run expensive process inspection on every keystroke or layout change. It should react to terminal runtime metadata refreshes, foreground process changes, TTY updates, and periodic low-frequency refresh while a terminal is active.

### Transport-Scoped Remote Daemon Manager

Introduce a manager keyed by normalized SSH transport:

- destination
- port
- identity
- jump host
- config file where needed
- relevant SSH options

This manager owns the reusable host transport state:

- remote platform probe
- remote daemon upload and verification
- daemon hello and capability state
- SOCKS/CONNECT proxy endpoint
- CLI relay metadata
- reconnect/backoff
- status reporting

This is the durable part currently concentrated in `WorkspaceRemoteSessionController`. The new manager should be usable by both detected SSH attachments and managed remote sessions.

### Surface Attachment Coordinator

Add a workspace or app-level coordinator that binds terminal surfaces to remote attachments. It should:

- create a detected attachment when the SSH detector recognizes a supported foreground SSH process
- clear or mark stale a detected attachment when the process exits
- create a managed attachment for `cmux ssh ...` and auto-upgraded commands
- expose attachment status to sidebar rows, browser creation, file drop, and socket payloads

### Browser Proxy Resolution

Browser proxy routing should resolve from the source surface or focused surface instead of workspace global state.

Rules:

- Browser opened from a remote-attached terminal uses that attachment's proxy endpoint when ready.
- Browser opened from a local-only surface stays local.
- If a workspace contains mixed surfaces, browser routing follows the surface that created or owns the browser pane.
- Existing remote workspace browser behavior remains compatible by mapping old workspace remote config to a managed remote attachment.

### Auto-Upgrade Shell Hook

Add a shell integration hook for interactive command submission. The hook should be gated by a user setting and should only intercept conservative SSH commands.

Supported first version:

- `ssh host`
- `ssh user@host`
- `ssh -p 2222 host`
- `ssh -i ~/.ssh/id_ed25519 host`
- equivalent `-o` options that can be safely forwarded

Explicitly fall through unchanged:

- commands with a remote command, such as `ssh host uname -a`
- commands with pipes or redirections
- commands that use `-W`, `-N`, `-L`, `-R`, `-D`, or stdio forwarding semantics
- commands with custom `RemoteCommand`
- non-interactive shells
- scripts
- command substitutions
- any command line the parser cannot confidently classify

The hook should call a cmux CLI helper such as:

```bash
cmux ssh-upgrade --destination host --surface "$CMUX_SURFACE_ID" --original-command "$BUFFER"
```

The exact helper shape can change during implementation, but it must preserve fallback: if cmux cannot upgrade, the original command executes.

## Error Handling

Passive detection must never break the user's SSH shell. If daemon deploy, proxy startup, or relay setup fails, the active OpenSSH process remains untouched. The UI should show a non-blocking status entry such as "Remote support unavailable" with retry details.

Auto-upgrade failures should fall back to the original SSH command. The user should not be left at a prompt with no connection unless the original SSH command also fails.

Remote daemon bootstrap errors should keep the existing detailed behavior: retry count, delay, actionable failure text, and notification/status updates. The status target changes from workspace-level remote state to surface-level attachment state.

## Compatibility

`cmux ssh ...` remains supported. In the migration phase it may continue to create a workspace and configure workspace remote state, but the intended model is:

- create a normal workspace or use the current workspace depending on command semantics
- create a managed remote terminal surface
- attach browser and relay behavior to that surface's remote attachment
- preserve `workspace.remote.status`, `workspace.remote.reconnect`, and related APIs by adapting them to the managed attachment where possible

Existing remote Docker/e2e coverage should continue to pass during migration.

## Settings And Localization

Add settings for:

- passive SSH enhancement: default enabled
- interactive SSH auto-upgrade: default disabled

All visible labels, status text, menu items, tooltips, and errors must use localized strings in `Resources/Localizable.xcstrings` with English and Japanese values.

The upgrade setting should appear in Settings and be supported in `~/.config/cmux/settings.json`. If a keyboard shortcut or command palette action is added for retrying or upgrading a detected SSH surface, it must follow the existing shortcut policy.

## Testing

Tests should verify behavior through executable paths, not source text.

Passive detection:

- Unit-test `TerminalSSHSessionDetector` with aliases, ports, identities, jump hosts, config files, control paths, and supported `-o` options.
- Verify unsupported or process-specific SSH options are filtered.
- Verify a terminal surface with foreground `ssh host` becomes `detectedSSH`.
- Verify daemon bootstrap failure does not kill or mutate the active SSH shell.

Proxy routing:

- Browser opened from a detected SSH surface uses that surface's remote proxy when the daemon is ready.
- Browser opened from a local-only surface stays local.
- Mixed local/remote surfaces in one workspace route browser traffic by source/focused surface, not workspace-wide state.

Auto-upgrade:

- Hook intercepts simple interactive `ssh host` only when enabled.
- Hook does not intercept remote commands, forwarding modes, pipes, redirects, scripts, disabled setting, or unknown parse cases.
- Upgrade failure executes the original SSH command and records fallback status.

Compatibility:

- Existing `cmux ssh ...` metadata, relay, browser proxy, reconnect, and daemon resize tests keep passing.
- Existing file/image drop behavior works for detected SSH and managed remote surfaces.

Local execution policy:

- Follow the repository policy for validation. Do not run e2e, UI, or socket tests locally. Prefer CI/VM for full validation.
- Unit tests that do not launch the app can be used where allowed by repository policy, but CI remains the preferred validation path.

## Rollout

Phase 1: add the surface attachment model and passive detector, leaving `cmux ssh ...` behavior intact.

Phase 2: route browser proxy and file drop through surface attachments, with compatibility adapters for existing workspace-level remote configuration.

Phase 3: add the transport-scoped daemon manager and gradually move daemon/proxy/relay ownership out of workspace-only state.

Phase 4: add the default-off auto-upgrade shell hook and settings UI.

Phase 5: migrate `cmux ssh ...` to create managed remote surfaces through the same attachment path while keeping public API compatibility.

Each phase should leave cmux usable and should preserve ordinary `ssh` semantics unless the user explicitly enables auto-upgrade.
