# Changelog

All notable changes to Watchdog are recorded here.

## [5.0] — 2026

Initial public/version-controlled release.

### Monitoring
- Monitor types: Windows Service, Process, TCP Port, HTTP(S) URL, TLS Certificate, Hyper-V VM State, Hyper-V VM Service/Process (experimental), and Backup Drive Rotation.
- Per-item check intervals, auto-restart with a max-attempt cap, and a "run as user" override for process restarts.
- Backup Drive Rotation with automatic swap detection (disconnect/reconnect **or** volume-serial change) and two-tier warning/critical overdue thresholds.

### Alerting
- HTML, colour-coded emails; `STATUS: Name` subject lines; recovery emails with downtime duration; optional daily heartbeat digest; test-email button.
- Alert batching/digest mode.
- Per-item "consecutive failures before emailing" and "re-notify while still down".

### Reliability (audit fixes rolled into 5.0)
- TLS 1.2 now set **inside** the background send runspace (runspaces don't inherit `ServicePointManager.SecurityProtocol`).
- Headless monitor loop hardened: each outbound stage wrapped in try/catch so one failure can't kill the loop silently.
- GUI scheduler tick guarded per-item and on tail calls.
- Config saves made atomic (temp file + `Move-Item`) so a headless reload never reads a half-written file.

### Platform
- Self-contained `Install-Watchdog.bat` (base64-embedded script + launcher + uninstaller).
- Headless SYSTEM scheduled-task startup, single-instance mutex lock, DPAPI-encrypted secrets, log rotation, live config reload.

---

### Unreleased / next
- Owner-draw rendering pass: fix the hover font-bleed on the item table, cache GDI brushes and badge measurements to remove per-cell allocation.
- Hoist `Ensure-ItemState` before the enabled-check to avoid a null-index on freshly-added disabled items.
