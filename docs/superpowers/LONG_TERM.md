# Long-Term Plan: Local Detach/Attach (tmux-style session persistence)

## Goal

Close the cmux GUI and reopen it later with all terminal processes still alive, scrollback history visible, and multiple clients able to attach the same session simultaneously.

Target: Tier 3 — process persistence + scrollback history + multi-attach + disconnect resume.

## Current State

- `TerminalSurface` (Ghostty C API) directly fork/execs shells and owns PTY master fd
- Closing GUI → surface destroyed → shell process terminated
- `SessionPersistence` restores window layout + scrollback text (via temp file + `cat`), but NOT processes
- `cmuxd-remote` (Go) exists for remote SSH workspaces with multi-attach + smallest-wins resize
- Ghostty C API has no public entry point for external PTY or external output injection
- Ghostty internal `Manual` backend exists but is not wired to surface/C API

## Recommended Architecture: daemon + attach relay client

### Why not direct WebSocket → Ghostty surface

`ghostty_surface_new(...)` only accepts exec-style parameters (`command`, `working_directory`, `env_vars`). There is no public API for injecting external byte streams into a surface. Patching Ghostty's `Manual` backend through to the C API is possible but has high fork maintenance cost.

### The "two-stage" design

```
cmuxd-local (daemon, Zig or Rust)
  ├── Holds real PTY master + shell child processes
  ├── Append-only VT byte log per session (memory ring buffer + disk)
  ├── Fan-out output to all attached clients
  ├── Per-client ack offset for disconnect resume
  ├── Manages session lifecycle (create, attach, detach, kill)
  ├── Resize coordination: "smallest wins" across attachments
  └── Unix socket API (or local WebSocket)

cmux-attach-local (relay client, very thin CLI)
  ├── Launched by Ghostty surface as its "command" (instead of shell)
  ├── stdin → forward user input to daemon
  ├── daemon output → stdout (Ghostty renders normally)
  ├── SIGWINCH → report terminal size to daemon
  └── On daemon disconnect: retry loop or exit (surface respawns)

cmux GUI (unchanged Ghostty surface mechanics)
  ├── Creates session → tells daemon to spawn PTY
  ├── Surface exec's `cmux-attach-local --session <id>` instead of shell
  ├── Detach = close GUI (relay client exits, daemon keeps PTY alive)
  └── Attach = reopen GUI, session restore maps session IDs → daemon sessions
```

### Key advantage

Completely bypasses "Ghostty doesn't support external data injection". Ghostty thinks it's talking to a normal child process. All existing surface architecture, rendering, focus management, AppKit portal layer, search/select/copy — untouched.

## Attach Semantics

### Hot reconnect (relay client network hiccup or surface recreation)

- Client sends `last_acked_seq` on connect
- Daemon resumes from that offset in VT log
- Gap-free continuation

### Cold attach (GUI was closed, new surface attaching to existing session)

- Daemon sends full VT byte log (or recent tail) to hydrate terminal state
- Then switches to live tail
- Known limitation: very long sessions may have slow cold attach
- Long-term: daemon-side terminal state checkpoint (snapshot current screen + scrollback) for instant cold attach

### Multi-attach

- Multiple relay clients can connect to same session
- Output fan-out via broadcast channel
- Resize: "smallest wins" (same model as cmuxd-remote)
- Input: all clients can send input (last writer wins, same as tmux)

## Session Restore Changes

Current: snapshot saves layout + scrollback text → restore creates fresh shells + replays text via `cat`.

New: snapshot saves layout + `local_session_id` per panel → restore checks daemon for alive sessions → attach if alive, fall back to fresh shell if not.

## Metadata Re-wiring

These features currently depend on "GUI owns the real PTY/shell process" and need to query daemon instead:

- `ttyName` (used for process observation)
- SSH detection / port scanning
- Foreground process tracking (for tab titles, AI tool detection)
- Working directory tracking

Daemon exposes these via its API; GUI queries daemon instead of local process table.

## Daemon Lifecycle

- Managed via `launchd` user agent (not app-forked background process)
- Single-instance via PID file + socket lock
- Graceful shutdown: flush VT logs, send SIGHUP to child processes
- Auto-start on first cmux launch, persist across GUI restarts
- Health check endpoint for GUI to verify daemon is alive

## Technical Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Cold attach for TUI/alternate screen apps | High | Store raw VT bytes; long-term add terminal state checkpointing |
| Relay client latency overhead | Low | Relay is pass-through, no terminal parsing; overhead is ~1 syscall per direction |
| VT log disk growth | Medium | Ring buffer with configurable max size; old data truncated |
| Ghostty fork changes breaking surface assumptions | Medium | Relay approach has zero Ghostty coupling |
| `ttyName`/process-observation re-wiring | Medium | Incremental; can stub with daemon API queries |

## Implementation Phases

### Phase 0: POC (1-2 weeks)

Prove three things:
1. GUI closes → shell in daemon stays alive
2. Two surfaces attach same session simultaneously
3. Relay disconnect + reconnect resumes at correct offset

Scope: single session, hardcoded paths, no persistence, no launchd.

### Phase 1: Usable V1 (4-6 weeks)

- Multi-session support
- Disk-backed VT log with configurable retention
- Hot reconnect with offset resume
- Basic cold attach (tail of VT log)
- Session restore integration (attach alive sessions on app reopen)
- Socket auth + lifecycle (launchd user agent)
- Daemon API for session metadata (cwd, foreground process, title)

### Phase 2: Production hardening (4-8 weeks)

- TUI/alternate-screen correctness for cold attach
- Terminal state checkpointing for instant cold attach
- VT log compaction / garbage collection
- Crash recovery (daemon restart → detect orphaned PTYs)
- Comprehensive test matrix
- Migration path from current session restore format
- Documentation

## Reference Implementations

- `tether_ghostty` (`../tether_ghostty`): Rust daemon + Flutter GUI, full detach/attach with WebSocket protocol, scrollback persistence, multi-attach. Uses similar two-stage model but with direct Ghostty rendering integration (Flutter-specific).
- `cmuxd-remote` (`daemon/remote/`): Go daemon for remote SSH workspaces, multi-attach with smallest-wins resize. Shares many design patterns applicable to local daemon.
- tmux: Classic reference for session persistence, multi-attach, and resize coordination.

## Open Questions

- Language for cmuxd-local: Zig (consistency with cmuxd builds) vs Rust (portable-pty ecosystem, tether reference)?
- Should cmuxd-local and cmuxd-remote eventually merge into a single daemon?
- VT log format: raw bytes vs structured events?
- Cold attach strategy: full VT replay vs terminal state snapshot vs hybrid?
