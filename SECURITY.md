# Security Policy

## Scope & Threat Model

BarLens runs as a local, single-user macOS menu bar utility and helper process (`BarLens` + `BarLensAgent`):

- **No Network Access**: BarLens makes zero network requests and includes no telemetry or analytics.
- **Local IPC Hardening**:
  - Communication between the UI process and `BarLensAgent` takes place inside `~/Library/Application Support/BarLens/` with directory permissions restricted to `0700` and state/log files restricted to `0600`.
  - Both processes validate file ownership (`lstat` `st_uid == getuid()` and regular-file mode `S_IFREG`) before reading IPC state, and automatically purge stale `.sb-*` atomic-write temporary files on startup.
- **Fail-Open Visibility Restriction**:
  - The menu bar visibility assertion is bound to the helper's XPC connection lifecycle and guarded by a `10s` heartbeat timeout. If either process exits or crashes, all hidden menu bar items are automatically restored by `MenuBarAgent`.

## Reporting a Vulnerability

If you discover a security issue (for example, local privilege escalation, IPC symlink/TOCTOU issues, or unsafe private framework invocation), please report it privately via **GitHub Security Advisories** on the repository rather than opening a public issue.
