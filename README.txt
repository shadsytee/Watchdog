============================================================
 Watchdog - README
============================================================

Watchdog is a self-contained Windows monitoring tool. It watches
services, processes, ports, websites, TLS certificates, and (if
you're on a Hyper-V host) services/processes inside your VMs -
and emails you when something goes down, with the option to try
restarting it automatically.

Everything is configured through the GUI. You never need to edit
the script by hand.


------------------------------------------------------------
1. INSTALLING
------------------------------------------------------------

Run Install-Watchdog.bat and accept the UAC prompt. It will:

  - Create C:\Watchdog
  - Put Watchdog.ps1, Run-Watchdog.bat and Uninstall-Watchdog.bat
    inside it
  - Add a "Watchdog" shortcut to your Desktop
  - Launch Watchdog for the first time

After that, use the Desktop shortcut (or C:\Watchdog\Run-Watchdog.bat)
to open it again whenever you want.


------------------------------------------------------------
2. WHAT YOU CAN MONITOR
------------------------------------------------------------

On the "Monitored Items" tab, click Add... and choose a type:

  Windows Service       - checks if a named service is Running
  Process               - checks if a named .exe is running
  TCP Port              - checks if a host:port accepts connections
  HTTP(S) URL           - checks a URL returns the status code you expect
  TLS Certificate       - checks a site's certificate expiry date
  VM Service (Hyper-V)  - checks a service INSIDE a Hyper-V guest VM
                          (hidden by default - see EXPERIMENTAL SETTINGS below)
  VM Process (Hyper-V)  - checks a process INSIDE a Hyper-V guest VM
                          (hidden by default - see EXPERIMENTAL SETTINGS below)
  VM State (Hyper-V)    - checks whether the VM itself is powered on
                          (no guest credentials needed - this one's a
                          host-level check). Can auto-start it if off.
  Backup Drive Rotation - tracks how long since a rotating USB backup
                          drive was last swapped (see below)

TEST BEFORE YOU SAVE - the Add/Edit item dialog has a "Test this check"
button. It runs the check once against whatever you've typed, without
saving, so a mistyped service name or wrong drive letter shows up
immediately instead of at the first scheduled check.

KEYBOARD SHORTCUTS - Ctrl+N adds an item, F5 checks everything now,
Ctrl+F jumps to the filter box, Enter accepts a dialog, Esc cancels.

THE LOG TAB - entries are colour-coded (red for failures, green for
recoveries, amber for warnings). There's a filter box, a Copy button, an
Open log file button, and a "Follow new entries" toggle so it stops
scrolling you to the bottom while you're reading. The filter searches
the last 500 lines of the log file.

EXPERIMENTAL SETTINGS - on the General tab, "Experimental Settings..."
opens a small dialog with a toggle for VM Service / VM Process
monitoring. These two are hidden from the "Monitor type" list by
default because they're more complex than everything else (guest
credentials, the guest OS needing to be reachable over PowerShell
Direct, etc.) - turn the toggle on if you actually need to monitor
something inside a VM's guest OS. VM State (just checking if a VM is
powered on) is simple enough that it's always available regardless of
this setting. If you already have a VM Service/Process item saved, it
stays fully working and editable even if you later turn this off -
the toggle only affects what's offered for NEW items.

Each item has its own check interval (how often it's tested) - a
critical service can be checked every 15 seconds while a slow-moving
certificate check only needs to run once a day.

Service and Process items (including the VM versions) can also
auto-restart themselves when found down, up to a configurable
number of attempts.

BACKUP DRIVE ROTATION - if you rotate USB backup drives on a schedule
(e.g. swap to a different drive every week and take the old one
offsite), this type tracks how long it's been since a swap was last
detected, and emails you if it's overdue.

  - Point it at a drive letter (e.g. E:). For this to work well, every
    rotation drive should be set to mount at that SAME letter - do
    this once via Disk Management > right-click the drive > Change
    Drive Letter and Paths. That way "E:" always means "whichever
    backup drive is currently connected", regardless of which
    physical drive that is.
  - Set "Expected rotation every (days)" (e.g. 7 for weekly) and
    "Treat as seriously overdue after (days)" (e.g. 10) - you get an
    amber warning email at the first threshold and a red critical
    email at the second.
  - Watchdog detects a rotation automatically: either the drive going
    offline and a drive reconnecting, or - if a swap happens faster
    than the check interval - the drive's volume serial number
    changing while it stayed connected the whole time. Either way,
    the countdown resets and you don't have to tell it anything.
  - Once rotated, you get a green "ROTATED" email confirming it's
    resolved (only if it had actually been overdue - a drive rotated
    on schedule every week generates no emails at all, which is the
    point).


------------------------------------------------------------
3. HOW ALERTING WORKS
------------------------------------------------------------

For each item you set:

  - "Consecutive failures before emailing" - e.g. 3 means it won't
    email you over a single blip; it waits for 3 failed checks in
    a row first.

  - "Re-notify while still down" - how often to remind you if the
    problem hasn't been fixed. The defaults are deliberately
    different depending on type:

      * Most types default to 0 (email once, then stay quiet until
        it recovers). Re-notifying every few minutes for an outage
        that's already been reported would just be noise.

      * TLS Certificate items default to 10080 minutes (once a
        week), because a cert can sit in its "expiring soon" window
        for weeks - you want an occasional nudge, not 48 emails a day.

    You can change either default per item any time.

  - "Email me when it comes back online" - sends a separate
    recovery email (worded as UP, or RENEWED for certificates)
    the moment it's healthy again, so you know it's resolved
    without having to go check.

Email subjects are formatted as "STATUS: Name" (e.g. "DOWN: PaperCut
Print Service") so the important part is visible even when your
phone truncates the subject line. The app name and machine name
appear in the SENDER instead, so they don't eat subject space.

STARTUP GRACE PERIOD - on the General tab, "Startup grace period
(minutes)" (default 10) holds back alert emails and auto-restart
actions for that long after a genuine Windows reboot - useful if
you're monitoring things that take a minute or two to come up after
the host itself finishes booting (a Hyper-V VM, a locally-hosted app
that starts a bit after Windows does). Checks and the dashboard keep
working normally during this window; only the outbound emails/restart
attempts are paused, and the Log tab notes when something was held
back. It's measured from the actual system boot time, not from when
Watchdog itself started, so restarting Watchdog mid-day for an
unrelated reason (a config change, a crash) never suppresses
anything. Set it to 0 to turn this off entirely.


------------------------------------------------------------
4. EMAIL SETUP
------------------------------------------------------------

On the Email tab, fill in your SMTP server, port, username and
password, From/To addresses, then click Send Test Email.

If authentication fails on Outlook/Office 365/Gmail, it's almost
always because the account needs an APP PASSWORD instead of your
normal login password (this is required once two-step verification
is turned on). Check your email provider's account security settings
for "app passwords".

Your SMTP password is stored encrypted (Windows DPAPI), not in
plain text.


------------------------------------------------------------
5. RUNNING AT STARTUP (BEFORE YOU EVEN LOG IN)
------------------------------------------------------------

On the General tab, click "Install Startup Task". This:

  - Registers a Scheduled Task that runs Watchdog at every Windows
    boot, as the SYSTEM account, whether or not anyone is logged in.
  - Needs no password - SYSTEM has none, so unlike a task tied to
    your own account, this one is completely unaffected if you ever
    change your Windows password later.
  - Runs "headless" in that mode - no visible window or tray icon -
    but checks, restarts, and emails all still work normally.

Use "Remove Startup Task" to undo this without uninstalling anything
else.


------------------------------------------------------------
6. OPENING WATCHDOG WHILE THE STARTUP TASK IS RUNNING
------------------------------------------------------------

Only ONE running copy of Watchdog is ever allowed to actually check
items and send emails at a time - this stops you getting duplicate
alerts if you open the GUI while the startup task is already
monitoring in the background.

If you open Watchdog and the startup task already owns monitoring,
the window still opens normally so you can view and edit settings,
but you'll notice:

  - The status pill at the top turns grey and says
    "Config only - see running instance"
  - The "Check Now" button is greyed out
  - No checks or emails are sent from that window

Any changes you Save are picked up automatically by the running
background instance within a few seconds - you don't need to do
anything else. This is expected behaviour, not a bug.


------------------------------------------------------------
7. WHERE YOUR DATA LIVES
------------------------------------------------------------

  C:\Watchdog\                       the app itself
  C:\Watchdog\watchdog.log           activity/error log (auto-rotates
                                      past 5MB, keeps the last 3)
  %ProgramData%\Watchdog\config.json your settings (or %AppData%\Watchdog
                                      if ProgramData isn't writable)
  ...\Watchdog\backups\              automatic timestamped config
                                      backups (last 10 kept) - if you
                                      ever make a bad edit and Save,
                                      you can restore an earlier one
                                      from here

Use "Export Config" / "Import Config" on the General tab to copy
your setup to another machine (passwords are excluded from exports
for security - re-enter them after importing).


------------------------------------------------------------
8. UNINSTALLING
------------------------------------------------------------

IMPORTANT: Before running Uninstall-Watchdog.bat, move (or copy) it
OUT of C:\Watchdog into a different folder first - for example your
Desktop or Downloads folder - and run it FROM THERE.

Why: the uninstaller's job is to delete the entire C:\Watchdog
folder. Running that deletion from a script that lives inside the
very folder being deleted is asking for trouble - the safest way is
to run it from somewhere else entirely, so nothing is fighting over
the folder it's trying to remove.

Then, from its new location:

  1. Double-click Uninstall-Watchdog.bat
  2. Accept the UAC prompt
  3. Type YES when asked to confirm (it will not proceed otherwise)

It will then:

  - Stop any running Watchdog process (GUI or background)
  - Remove the Scheduled Task and the "run at login" entry
  - Remove the Desktop shortcut
  - Delete C:\Watchdog entirely
  - Delete saved settings and logs from ProgramData/AppData

Nothing of Watchdog will be left on the machine afterwards.


------------------------------------------------------------
9. TROUBLESHOOTING
------------------------------------------------------------

  - Check the Log tab inside Watchdog, or C:\Watchdog\watchdog.log,
    for the exact error behind any failure (email, restart, or
    startup task issues all log a plain-English reason there).

  - "Test Email" failing: see section 4 above (app passwords).

  - Startup task not appearing: open Task Scheduler and look for a
    task named "Watchdog" at the top level of the library (press
    F5 to refresh - it doesn't auto-update).

  - Hyper-V VM checks failing: the VM must be running, and the
    guest username/password must be a real account INSIDE that VM
    (not an account on the host).
