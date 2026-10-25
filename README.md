# Watchdog

A self-contained Windows infrastructure monitor for school / small-server environments — a lightweight PRTG alternative in a single PowerShell + WinForms app.

Watchdog watches Windows services, processes, TCP ports, HTTP(S) URLs, TLS certificates, Hyper-V VMs, and rotating USB backup drives. When something goes down it emails you (HTML, colour-coded), can auto-restart the thing, and can run completely headless as a SYSTEM scheduled task at boot — before anyone logs in.

Everything is configured through the GUI. You never edit the script by hand.

![Version](https://img.shields.io/badge/version-5.0-blue) ![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20PowerShell%205.1-5391FE) ![License](https://img.shields.io/badge/license-MIT-green)

---

## What it monitors

| Type | Checks |
|------|--------|
| **Windows Service** | A named service is `Running` |
| **Process** | A named `.exe` is running |
| **TCP Port** | A `host:port` accepts connections |
| **HTTP(S) URL** | A URL returns the status code you expect |
| **TLS Certificate** | A site's certificate expiry date |
| **VM State** (Hyper-V) | Whether a VM is powered on (host-level, no guest creds) — can auto-start it |
| **VM Service / Process** (Hyper-V) | A service/process *inside* a guest VM, over PowerShell Direct (experimental) |
| **Backup Drive Rotation** | Days since a rotating USB backup drive was last swapped, with warning/critical thresholds |

Each item runs on its own interval — a critical service every 15 s, a certificate once a day.

## Key features

- **Alerting** — HTML emails colour-coded by situation (DOWN/UP/EXPIRING/heartbeat/test); subject is `STATUS: Name` so it reads on a phone; recovery emails report how long something was down; optional daily heartbeat digest.
- **Auto-restart** — Service/Process/VM items can restart themselves up to N attempts, optionally under a specific Windows account (fixes profile-tied apps like Plex when Watchdog runs as SYSTEM).
- **Runs headless at boot** — a Scheduled Task as SYSTEM, no password, unaffected by account password changes.
- **Single-instance lock** — only one copy ever polls/emails, so opening the GUI while the boot task runs never produces duplicate alerts.
- **Startup grace period** — holds alerts/restarts for a window after a *real* reboot so things still starting up aren't mistaken for outages (measured from system boot time, not Watchdog's start).
- **Secrets encrypted** — SMTP, VM and run-as passwords stored with machine-scoped Windows DPAPI, never plain text.
- **Resilient** — non-blocking email on a background thread, retry-until-sent, bounded TLS timeouts, atomic config writes, auto log rotation, live config reload.

See [`FEATURES.txt`](FEATURES.txt) for the complete feature list, including the under-the-hood safety nets.

---

## Install

1. Download **`Install-Watchdog.bat`** and run it, accepting the UAC prompt.
2. It creates `C:\Watchdog`, deploys the script + launcher + uninstaller, adds a Desktop shortcut, and launches Watchdog.
3. Configure your checks and SMTP in the GUI, send a test email, then (optionally) **Install Startup Task** on the General tab to run it at every boot.

`Install-Watchdog.bat` is a single self-contained file — it carries `Watchdog.ps1`, `Run-Watchdog.bat`, and `Uninstall-Watchdog.bat` embedded as base64 and writes them out on install.

### Email note
On Outlook / Microsoft 365 / Gmail, SMTP auth almost always needs an **app password** (once two-step verification is on), not your normal login password.

## Repository layout

| File | What it is |
|------|------------|
| `Watchdog.ps1` | The application — GUI + headless monitor |
| `Install-Watchdog.bat` | Self-contained installer (generated; embeds the three files below) |
| `Run-Watchdog.bat` | Double-click launcher, self-elevates, runs hidden-console |
| `Uninstall-Watchdog.bat` | Full removal (task, shortcut, data) with typed confirmation |
| `FEATURES.txt` | Full feature list incl. hidden/under-the-hood functions |
| `README.txt` | Original plain-text user guide (long-form) |

> **Note:** `Install-Watchdog.bat` is a build artifact regenerated from the three source files. When you change `Watchdog.ps1`, rebuild the installer before committing so it carries the latest script.

## Requirements

- Windows with **Windows PowerShell 5.1** (built in; not PowerShell 7).
- Administrator rights to install (for `C:\Watchdog`, the scheduled task, and service control).
- Hyper-V role only if you use the VM check types.

## Security / data

- No secret is ever committed — `config.json`, logs, and `backups/` are git-ignored. Config lives in `%ProgramData%\Watchdog\` (or `%AppData%` fallback), **not** in the repo.
- Exported configs deliberately exclude passwords.

## License

[MIT](LICENSE)
