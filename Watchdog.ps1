#Requires -Version 5.1
<#
.SYNOPSIS
    Watchdog - A polished tray-based watchdog for Windows services, processes,
    TCP ports, HTTP(S) endpoints and TLS certificate expiry.

.DESCRIPTION
    Everything is configured through the GUI - no script editing required.

      * Watch: Windows Services, Processes, TCP Ports, HTTP(S) URLs, TLS Certificates,
        or services/processes INSIDE Hyper-V guest VMs (via PowerShell Direct - no network).
      * Per-item check interval (each thing can be polled at its own cadence).
      * Auto-restart failed Services/Processes (with a configurable attempt cap).
      * Email after N consecutive failed checks (e.g. "email on the 3rd failure").
      * "Back online" recovery emails + tray notifications when something comes back.
      * TLS certificate monitoring: warns you a configurable number of days before a
        certificate expires (defaults to 60 days / ~2 months).
      * Re-notify cadence so you're reminded while something is still down.
      * Tray icon reflects overall health (green / amber / red) with balloon alerts.
      * Per-item uptime % and last response time, tracked over time and shown on the
        dashboard and in alert/heartbeat emails.
      * Config auto-backups (last 10 kept in a "backups" subfolder) and automatic log
        rotation (archives watchdog.log past 5MB, keeps the last 3 archives).

    SMTP password is stored encrypted with Windows DPAPI, scoped to the account the
    script runs under.

    Config + rolling log live under:
        %ProgramData%\Watchdog\   (falls back to %APPDATA% if not writable)

.NOTES
    Run:  powershell.exe -ExecutionPolicy Bypass -File .\Watchdog.ps1

    Two startup options on the General tab:
      * "Run at my Windows login" - HKCU Run key; starts with a visible tray when YOU log in.
      * "Install Startup Task" - copies the script to C:\Watchdog and registers a
        Scheduled Task (trigger: At startup) that runs it as SYSTEM - no password
        needed, and unaffected if your account password ever changes. Runs headless
        via -Headless (no visible tray) - alerting, auto-restart and cert checks all
        still run. Reconfigure from the GUI and Save; the background instance reloads
        config automatically. Must be run from a saved .ps1 file (not pasted into a
        console) since the task needs a real file path to launch.

    SMTP passwords are DPAPI-encrypted at LocalMachine scope so the same encrypted
    blob works whether the app runs as you, a service account, or SYSTEM on this box.
#>

param(
    [switch]$Headless,      # run the monitoring engine with no GUI (used by the boot task)
    [switch]$InstallTask,    # internal: elevated install routine
    [string]$TaskUser = ""   # internal: if set, register the task to run as this user instead of SYSTEM
)

# Remember where this script lives (empty if it was pasted into a console instead of run as a file)
$script:SelfPath    = $PSCommandPath
$script:InstallDir  = "C:\Watchdog"
$script:DeployedPs1 = Join-Path $script:InstallDir "Watchdog.ps1"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

if (-not $Headless) {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
}

# Prefer modern TLS everywhere (older servers default to TLS 1.0)
try {
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
} catch {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# ==================================================================
#  Theme / palette
# ==================================================================
$script:Theme = @{
    HeaderBg   = [System.Drawing.Color]::FromArgb(33, 37, 43)
    HeaderText = [System.Drawing.Color]::White
    Green      = [System.Drawing.Color]::FromArgb(46, 204, 113)
    Amber      = [System.Drawing.Color]::FromArgb(230, 160, 20)
    Red        = [System.Drawing.Color]::FromArgb(231, 76, 60)
    Gray       = [System.Drawing.Color]::FromArgb(140, 146, 155)
    Panel      = [System.Drawing.Color]::FromArgb(246, 247, 249)
    Text       = [System.Drawing.Color]::FromArgb(40, 44, 52)
    CardBorder = [System.Drawing.Color]::FromArgb(224, 227, 231)
    TextMuted  = [System.Drawing.Color]::FromArgb(140, 146, 155)
    HeaderBg2    = [System.Drawing.Color]::FromArgb(22, 26, 33)
    HeaderSubtle = [System.Drawing.Color]::FromArgb(124, 131, 141)
    TabStripBg   = [System.Drawing.Color]::FromArgb(30, 35, 43)
    FooterBg     = [System.Drawing.Color]::FromArgb(22, 26, 33)
    FooterText   = [System.Drawing.Color]::FromArgb(124, 131, 141)
    Accent       = [System.Drawing.Color]::FromArgb(55, 138, 221)
    RowHairline  = [System.Drawing.Color]::FromArgb(237, 239, 242)
}
$script:BaseFont   = New-Object System.Drawing.Font("Segoe UI", 9)
$script:BoldFont   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$script:HeaderFont = New-Object System.Drawing.Font("Segoe UI Semibold", 14, [System.Drawing.FontStyle]::Bold)
$script:MicroFont  = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
$script:MetricFont = New-Object System.Drawing.Font("Segoe UI Semibold", 15, [System.Drawing.FontStyle]::Bold)
$script:AppVersion = "5.0"

# ==================================================================
#  Paths
# ==================================================================
$script:ConfigDir = Join-Path $env:ProgramData "Watchdog"
try {
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force -ErrorAction Stop | Out-Null }
    $t = Join-Path $script:ConfigDir "_wdtest.tmp"
    Set-Content -Path $t -Value "x" -ErrorAction Stop
    Remove-Item $t -Force -ErrorAction SilentlyContinue
} catch {
    $script:ConfigDir = Join-Path $env:APPDATA "Watchdog"
    if (-not (Test-Path $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
}
$script:ConfigPath = Join-Path $script:ConfigDir "config.json"
$script:LogPath    = Join-Path $script:ConfigDir "watchdog.log"

# ==================================================================
#  Global state
# ==================================================================
$script:General = [ordered]@{
    SchedulerResolutionSec = 5
    MinimizeToTrayOnClose  = $true
    StartMinimized         = $false
    RunAtStartup           = $false
    ShowBalloonTips        = $true
    DailyHeartbeat         = $false
    HeartbeatHour          = 8
    InstanceName           = ""
    StartupGraceMinutes    = 10
    ExperimentalFeaturesEnabled = $false
    AlertBatchWindowSec = 0
    RestartNotifyMode = "Off"        # Off | UnexpectedOnly | All
    LastReportedBootTime = ""        # persisted so a given boot is only ever reported once
}
$script:Email = [ordered]@{
    SmtpServer        = ""
    SmtpPort          = 587
    UseSSL            = $true
    Username          = ""
    EncryptedPassword = ""
    From              = ""
    To                = ""
    SubjectPrefix     = ""
}
$script:Items     = New-Object System.Collections.ArrayList
$script:ItemState = @{}
$script:UI        = @{}
$script:Icons     = @{}
$script:IsPaused  = $false

# Only ONE running instance (headless boot task, or a manually-opened GUI) should ever
# actually poll items and send emails at a time - otherwise, opening the GUI while the
# boot task is already running makes every alert fire twice. A machine-wide named Mutex
# decides who "owns" monitoring; whoever loses the race still gets a usable window, just
# without its own checks/alerts, so config changes can be made safely at any time.
$script:MonitorMutexName    = "Global\WatchdogMonitorLock"
$script:MonitorMutex        = $null
$script:IsPrimaryInstance   = $true

function Test-AcquireMonitorLock {
    try {
        $createdNew = $false
        $script:MonitorMutex = [System.Threading.Mutex]::new($false, $script:MonitorMutexName, [ref]$createdNew)
        $script:IsPrimaryInstance = $createdNew
    } catch {
        # If we can't even create the lock, fail open (monitor anyway) rather than
        # silently going dark - a false "I'm secondary" would mean nothing watches at all.
        $script:IsPrimaryInstance = $true
    }
    return $script:IsPrimaryInstance
}

# ==================================================================
#  Item schema / normalization
# ==================================================================
function Get-Prop { param($Obj, [string]$Name, $Default)
    if ($null -ne $Obj -and ($Obj.PSObject.Properties.Name -contains $Name) -and $null -ne $Obj.$Name) { return $Obj.$Name }
    return $Default
}

function Normalize-Item { param($Src)
    $typeVal = Get-Prop $Src 'Type' 'Service'
    # Default re-notify: 0 (send once, don't repeat) for everything except a TLS
    # certificate warning (once a week - it has months of runway) or an overdue
    # backup drive rotation (once a day - more urgent, someone needs to act on it).
    # This only kicks in when the field is genuinely absent from the source (e.g. an
    # old config or a manually-edited import); the item editor sets an explicit value
    # for anything created through the GUI.
    $renotifyDefault = switch ($typeVal) { 'Cert' { 10080 } 'BackupDrive' { 1440 } default { 0 } }
    # Default check interval: local Service/Process/Port checks are essentially free,
    # so they default fast; a TLS check does a real handshake and cert expiry only
    # ever changes months at a time, so it defaults to once a day; Hyper-V VM checks
    # open a real PowerShell Direct session each time, so they get a longer default too;
    # a backup drive presence check is cheap but doesn't need to be constant either.
    $intervalDefault = switch ($typeVal) {
        'Service'     { 30 }
        'Process'     { 30 }
        'Port'        { 60 }
        'Cert'        { 86400 }
        'VMService'   { 120 }
        'VMProcess'   { 120 }
        'VMState'     { 30 }
        'BackupDrive' { 300 }
        default       { 60 }   # Url and anything unrecognized
    }
    # Default failures-before-emailing: a daily/periodic check like Cert or BackupDrive
    # already IS the "confirmation" - waiting for several more consecutive failures on
    # top of that would just delay reporting something that's genuinely overdue.
    $failuresDefault = if ($typeVal -eq 'Cert' -or $typeVal -eq 'BackupDrive') { 1 } else { 3 }
    [PSCustomObject]@{
        Id                  = Get-Prop $Src 'Id' ([guid]::NewGuid().ToString())
        Name                = Get-Prop $Src 'Name' 'Unnamed'
        Type                = $typeVal
        Target              = Get-Prop $Src 'Target' ''
        ExePath             = Get-Prop $Src 'ExePath' ''
        Arguments           = Get-Prop $Src 'Arguments' ''
        WorkingDirectory    = Get-Prop $Src 'WorkingDirectory' ''
        HostName            = Get-Prop $Src 'HostName' 'localhost'
        Port                = [int](Get-Prop $Src 'Port' 443)
        Url                 = Get-Prop $Src 'Url' ''
        ExpectedStatusCode  = [int](Get-Prop $Src 'ExpectedStatusCode' 200)
        TimeoutSeconds      = [int](Get-Prop $Src 'TimeoutSeconds' 10)
        CertWarnDays        = [int](Get-Prop $Src 'CertWarnDays' 60)
        CheckIntervalSec    = [int](Get-Prop $Src 'CheckIntervalSec' $intervalDefault)
        Enabled             = [bool](Get-Prop $Src 'Enabled' $true)
        AutoRestart         = [bool](Get-Prop $Src 'AutoRestart' $false)
        RestartAttempts     = [int](Get-Prop $Src 'RestartAttempts' 3)
        FailuresBeforeEmail = [int](Get-Prop $Src 'FailuresBeforeEmail' $failuresDefault)
        RenotifyMinutes     = [int](Get-Prop $Src 'RenotifyMinutes' $renotifyDefault)
        SendRecoveryEmail   = [bool](Get-Prop $Src 'SendRecoveryEmail' $true)
        VMName              = Get-Prop $Src 'VMName' ''
        VMUsername          = Get-Prop $Src 'VMUsername' ''
        EncryptedVMPassword = Get-Prop $Src 'EncryptedVMPassword' ''
        RunAsUser              = Get-Prop $Src 'RunAsUser' ''
        EncryptedRunAsPassword = Get-Prop $Src 'EncryptedRunAsPassword' ''
        WarnAfterDays          = [int](Get-Prop $Src 'WarnAfterDays' 7)
        AlertAfterDays         = [int](Get-Prop $Src 'AlertAfterDays' 10)
    }
}

function Ensure-ItemState { param($Item)
    if (-not $script:ItemState.ContainsKey($Item.Id)) {
        $script:ItemState[$Item.Id] = @{
            ConsecutiveFailures  = 0
            RestartAttemptsMade  = 0
            EmailSentForIncident = $false
            LastEmailSentTime    = $null
            LastStatus           = "Unknown"
            LastChecked          = $null
            LastMessage          = ""
            NextCheckTime        = Get-Date
            CertDaysLeft         = $null
            TotalChecks          = 0
            TotalAvailable       = 0     # checks that were Up or Warning (i.e. not Down)
            LastResponseMs       = $null
            DownSince            = $null
            LastSendAttemptTime  = $null
            LastRotationTime     = $null   # backup drive: when a swap was last detected
            DriveWasPresent      = $null   # backup drive: presence at the previous check
            LastDriveSerial      = ""      # backup drive: volume serial at the previous check
            LastRenderedStatus   = $null   # dashboard-only: used to flash a row once on status change
        }
    }
}

# "Up" and "Warning" both count as available (a cert nearing expiry isn't an outage);
# only "Down" counts against uptime.
function Get-UptimePercent { param($St)
    if (-not $St -or $St.TotalChecks -le 0) { return $null }
    return [Math]::Round((100.0 * $St.TotalAvailable / $St.TotalChecks), 1)
}

# ==================================================================
#  Config load / save
# ==================================================================
function Save-AppConfig {
    try {
        Backup-CurrentConfig
        $plainItems = @(); foreach ($i in $script:Items) { $plainItems += $i }
        $cfg = [ordered]@{ General = $script:General; Email = $script:Email; Items = $plainItems }
        $json = $cfg | ConvertTo-Json -Depth 8
        # Write to a temp file, then atomically move it over the real one. A direct
        # Set-Content truncates the file and streams the JSON in - and the headless boot
        # instance polls this same file and reloads it. If a reload lands mid-write it
        # reads half-written JSON (caught, but the reload silently fails and the headless
        # instance keeps running stale config). A move on NTFS is atomic, so a reader
        # always sees either the old complete file or the new complete file, never a
        # partial one.
        $tmp = "$($script:ConfigPath).tmp"
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
    } catch { Write-Log "Failed to save config: $($_.Exception.Message)" }
}

# Snapshot the config that's about to be overwritten, so an accidental bad edit + Save
# is always recoverable. Keeps the most recent 10 backups and prunes older ones.
function Backup-CurrentConfig {
    if (-not (Test-Path $script:ConfigPath)) { return }
    try {
        $backupDir = Join-Path $script:ConfigDir "backups"
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        Copy-Item -LiteralPath $script:ConfigPath -Destination (Join-Path $backupDir "config-$stamp.json") -Force

        $old = Get-ChildItem -Path $backupDir -Filter "config-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10
        foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    } catch { Write-Log "Config backup skipped: $($_.Exception.Message)" }
}

function Load-AppConfig {
    if (-not (Test-Path $script:ConfigPath)) { return }
    try {
        $loaded = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        if ($loaded.General) { foreach ($k in @($script:General.Keys)) { if ($null -ne $loaded.General.$k) { $script:General[$k] = $loaded.General.$k } } }
        if ($loaded.Email)   { foreach ($k in @($script:Email.Keys))   { if ($null -ne $loaded.Email.$k)   { $script:Email[$k]   = $loaded.Email.$k } } }
        if ($loaded.Items) {
            foreach ($it in $loaded.Items) {
                $norm = Normalize-Item $it
                [void]$script:Items.Add($norm)
                Ensure-ItemState -Item $norm
            }
        }
    } catch { Write-Log "Failed to load config: $($_.Exception.Message)" }
}

# Re-read config from disk, replacing current in-memory state. Used by the file
# watcher so a headless (boot/SYSTEM) instance picks up edits saved from the GUI.
# Preserves runtime failure counters for items whose Id still exists.
function Reload-AppConfig {
    if (-not (Test-Path $script:ConfigPath)) { return }
    try {
        $loaded = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        if ($loaded.General) { foreach ($k in @($script:General.Keys)) { if ($null -ne $loaded.General.$k) { $script:General[$k] = $loaded.General.$k } } }
        if ($loaded.Email)   { foreach ($k in @($script:Email.Keys))   { if ($null -ne $loaded.Email.$k)   { $script:Email[$k]   = $loaded.Email.$k } } }

        $newItems = New-Object System.Collections.ArrayList
        $seenIds  = @{}
        if ($loaded.Items) {
            foreach ($it in $loaded.Items) {
                $norm = Normalize-Item $it
                [void]$newItems.Add($norm)
                $seenIds[$norm.Id] = $true
                Ensure-ItemState -Item $norm
            }
        }
        # Drop state for items that no longer exist
        foreach ($oldId in @($script:ItemState.Keys)) { if (-not $seenIds.ContainsKey($oldId)) { $script:ItemState.Remove($oldId) } }
        $script:Items = $newItems
        Write-Log "Config reloaded from disk ($($script:Items.Count) item(s))."
    } catch { Write-Log "Config reload failed: $($_.Exception.Message)" }
}

# Export the config to a file for copying to other machines. Encrypted secrets
# (SMTP + guest passwords) are DPAPI-bound to THIS machine, so they're stripped -
# re-enter them once on each target machine.
function Export-ConfigToFile { param([string]$Path)
    try {
        $emailCopy = [ordered]@{}; foreach ($k in $script:Email.Keys) { $emailCopy[$k] = $script:Email[$k] }
        $emailCopy.EncryptedPassword = ""
        $itemsCopy = @()
        foreach ($i in $script:Items) {
            $c = $i | Select-Object *
            $c.EncryptedVMPassword = ""
            $itemsCopy += $c
        }
        $genCopy = [ordered]@{}; foreach ($k in $script:General.Keys) { $genCopy[$k] = $script:General[$k] }
        $genCopy.InstanceName = ""   # let each machine default to its own name
        $genCopy.LastReportedBootTime = ""   # machine-specific runtime state - carrying it over would suppress the target machine's first restart notice
        ([ordered]@{ General=$genCopy; Email=$emailCopy; Items=$itemsCopy } | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding UTF8
        Write-Log "Config exported to $Path (passwords stripped)."
        return $true
    } catch { Write-Log "Export failed: $($_.Exception.Message)"; return $false }
}

function Import-ConfigFromFile { param([string]$Path)
    try {
        $loaded = Get-Content $Path -Raw | ConvertFrom-Json
        if ($loaded.General) { foreach ($k in @($script:General.Keys)) { if ($k -ne 'InstanceName' -and $k -ne 'LastReportedBootTime' -and $null -ne $loaded.General.$k) { $script:General[$k] = $loaded.General.$k } } }
        if ($loaded.Email)   { foreach ($k in @($script:Email.Keys))   { if ($k -ne 'EncryptedPassword' -and $null -ne $loaded.Email.$k) { $script:Email[$k] = $loaded.Email.$k } } }
        $newItems = New-Object System.Collections.ArrayList
        if ($loaded.Items) { foreach ($it in $loaded.Items) { $n = Normalize-Item $it; [void]$newItems.Add($n); Ensure-ItemState -Item $n } }
        $script:Items = $newItems
        Write-Log "Config imported from $Path ($($script:Items.Count) item(s)). Re-enter SMTP/guest passwords, then Save."
        return $true
    } catch { Write-Log "Import failed: $($_.Exception.Message)"; return $false }
}

# ==================================================================
#  Logging
# ==================================================================
$script:LastLogRotationCheck = $null
function Invoke-LogRotationIfNeeded {
    # Only actually stat the file every few minutes - Write-Log fires constantly and
    # we don't want a disk hit on every single log line.
    $now = Get-Date
    if ($script:LastLogRotationCheck -and ($now - $script:LastLogRotationCheck).TotalMinutes -lt 5) { return }
    $script:LastLogRotationCheck = $now
    try {
        if (-not (Test-Path $script:LogPath)) { return }
        $sizeMb = (Get-Item $script:LogPath).Length / 1MB
        if ($sizeMb -lt 5) { return }
        $archive = Join-Path $script:ConfigDir ("watchdog-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        Rename-Item -LiteralPath $script:LogPath -NewName (Split-Path $archive -Leaf) -Force
        # Keep only the 3 most recent archives so old logs don't accumulate forever.
        $old = Get-ChildItem -Path $script:ConfigDir -Filter "watchdog-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3
        foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    } catch { }
}

# Classifies a log line so the Log tab can colour it. Purely presentational - the file
# on disk is unchanged plain text.
function Get-LogLineSeverity { param([string]$Message)
    if ($Message -match 'DOWN|FAILED|EXPIRED|CRITICAL|OVERDUE|error') { return 'Bad' }
    if ($Message -match 'RECOVERED|back online|sent|Rotated|installed') { return 'Good' }
    if ($Message -match 'WARNING|expiring|grace period|holding off|retry') { return 'Warn' }
    return 'Info'
}

# Repaints the whole Log tab from the file on disk, honouring the filter box. Used when
# the filter changes - simpler and safer than trying to selectively hide RichTextBox lines.
function Reload-LogView {
    $box = $script:UI.LogBox
    if (-not $box -or $box.IsDisposed) { return }
    $filter = ""
    if ($script:UI.TxtLogFilter) { $filter = $script:UI.TxtLogFilter.Text.Trim() }
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $script:LogPath -Tail 500 -ErrorAction SilentlyContinue) } catch { }
    $box.Clear()
    foreach ($l in $lines) {
        if ($filter -and ($l -notlike "*$filter*")) { continue }
        $sev = Get-LogLineSeverity -Message $l
        $colour = switch ($sev) {
            'Bad'  { $script:Theme.Red }
            'Good' { [System.Drawing.Color]::FromArgb(15,110,86) }
            'Warn' { [System.Drawing.Color]::FromArgb(133,79,11) }
            default { $script:Theme.Text }
        }
        $box.SelectionStart = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionColor = $colour
        $box.AppendText("$l`r`n")
    }
    $box.SelectionColor = $box.ForeColor
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Write-Log { param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    if ($script:UI.LogBox -and -not $script:UI.LogBox.IsDisposed) {
        $sev = Get-LogLineSeverity -Message $Message
        try {
            $script:UI.LogBox.Invoke([Action]{
                $box = $script:UI.LogBox
                $colour = switch ($sev) {
                    'Bad'  { $script:Theme.Red }
                    'Good' { [System.Drawing.Color]::FromArgb(15,110,86) }
                    'Warn' { [System.Drawing.Color]::FromArgb(133,79,11) }
                    default { $script:Theme.Text }
                }
                # Only append when the filter box is empty or the line matches it, so the
                # view stays consistent with what the filter is showing.
                $filter = ""
                if ($script:UI.TxtLogFilter) { $filter = $script:UI.TxtLogFilter.Text.Trim() }
                if ($filter -and ($line -notlike "*$filter*")) { return }
                $box.SelectionStart = $box.TextLength
                $box.SelectionLength = 0
                $box.SelectionColor = $colour
                $box.AppendText("$line`r`n")
                $box.SelectionColor = $box.ForeColor
                if (-not $script:UI.ChkLogFollow -or $script:UI.ChkLogFollow.Checked) {
                    $box.SelectionStart = $box.TextLength
                    $box.ScrollToCaret()
                }
            }) 
        } catch { }
    }
    try { Add-Content -Path $script:LogPath -Value $line -ErrorAction SilentlyContinue } catch { }
    Invoke-LogRotationIfNeeded
}

# ==================================================================
#  DPAPI password helpers
# ==================================================================
# Passwords are encrypted with DPAPI at LocalMachine scope so that whichever account
# the app runs under (your login, a service account, or SYSTEM at boot) can decrypt
# them on this machine. Blobs are prefixed "M:" (machine) so we can still read older
# user-scope blobs written by earlier versions.
function Protect-PlainPassword { param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return "" }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
        $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return "M:" + [Convert]::ToBase64String($enc)
    } catch {
        # Fallback: user-scope SecureString (still works, but only for this user)
        try { return "U:" + (ConvertFrom-SecureString -SecureString (ConvertTo-SecureString $Plain -AsPlainText -Force)) } catch { return "" }
    }
}
function Unprotect-ToPlainPassword { param([string]$Enc)
    if ([string]::IsNullOrEmpty($Enc)) { return "" }
    try {
        if ($Enc.StartsWith("M:")) {
            $bytes = [Convert]::FromBase64String($Enc.Substring(2))
            $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
            return [System.Text.Encoding]::UTF8.GetString($dec)
        }
        $blob = if ($Enc.StartsWith("U:")) { $Enc.Substring(2) } else { $Enc }
        $sec  = ConvertTo-SecureString $blob
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $p    = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        return $p
    } catch { return "" }
}

# ==================================================================
#  Email  (uses Send-MailMessage - the same method the user verified works
#          against Office 365 / Outlook)
# ==================================================================
function Get-InstanceName {
    if (-not [string]::IsNullOrWhiteSpace($script:General.InstanceName)) { return $script:General.InstanceName.Trim() }
    return $env:COMPUTERNAME
}

# Cache the actual Windows boot time once per process - it doesn't change, and querying
# WMI on every single check would be wasteful.
$script:SystemBootTime = $null
function Get-SystemBootTime {
    if (-not $script:SystemBootTime) {
        try { $script:SystemBootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
        catch { $script:SystemBootTime = Get-Date }   # fail safe: if we can't tell, assume "just booted" so nothing suppresses forever
    }
    return $script:SystemBootTime
}

# True for the configured number of minutes after the machine actually rebooted - NOT
# after Watchdog itself started, so restarting Watchdog mid-day (a config change, a
# crash) doesn't suppress alerting; only a genuine Windows boot does. Checks still run
# and the dashboard still updates during this window - only outbound alert emails and
# auto-restart actions are held back, so nothing looks like it's "down" just because
# it (or a VM it depends on) hasn't finished starting yet.
function Test-InStartupGracePeriod {
    if ([int]$script:General.StartupGraceMinutes -le 0) { return $false }
    return (Get-Date) -lt (Get-SystemBootTime).AddMinutes([int]$script:General.StartupGraceMinutes)
}

# ------------------------------------------------------------------
#  Server restart / outage detection
#  ---------------------------------------------------------------
#  Distinguishes an UNEXPECTED outage (power loss, hard lockup - Windows logs event
#  6008, "the previous system shutdown was unexpected") from a PLANNED restart (event
#  1074 records who requested it and often why). That distinction is the whole point:
#  a "server booted" email after every routine Windows Update reboot would just be
#  noise, so the default mode only reports the unexpected kind.
#  Reported at most ONCE per boot - the boot timestamp is persisted to config as soon
#  as the notice is queued, so restarting Watchdog itself can't re-trigger it.
# ------------------------------------------------------------------
function Get-LastBootClassification {
    $bootTime = Get-SystemBootTime
    $result = @{ Kind = 'Unknown'; Detail = 'Cause could not be determined'; PreviousShutdown = $null; Requestor = '' }
    try {
        # Only look at events around this boot - anything older is a previous life.
        $since = $bootTime.AddHours(-24)

        $unexpected = @(Get-WinEvent -FilterHashtable @{ LogName='System'; Id=6008; StartTime=$since } -MaxEvents 5 -ErrorAction SilentlyContinue)
        if ($unexpected.Count -gt 0) {
            $evt = $unexpected | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $result.Kind = 'Unexpected'
            $result.Detail = 'Windows reported the previous shutdown as unexpected (power loss, hard lockup, or forced power-off).'
            # 6008's message embeds the time the system actually stopped; the event's own
            # timestamp is when Windows noticed on the way back up, which is close enough
            # to boot time to be useless for measuring downtime - so prefer the recorded
            # shutdown time when we can get it, and fall back to nothing rather than lying.
            try {
                if ($evt.Properties -and $evt.Properties.Count -ge 2) {
                    $parsed = [datetime]::MinValue
                    $candidate = "$($evt.Properties[1].Value) $($evt.Properties[0].Value)"
                    if ([datetime]::TryParse($candidate, [ref]$parsed)) { $result.PreviousShutdown = $parsed }
                }
            } catch { }
            return $result
        }

        $planned = @(Get-WinEvent -FilterHashtable @{ LogName='System'; Id=1074; StartTime=$since } -MaxEvents 5 -ErrorAction SilentlyContinue)
        if ($planned.Count -gt 0) {
            $evt = $planned | Sort-Object TimeCreated -Descending | Select-Object -First 1
            $result.Kind = 'Planned'
            $result.Detail = 'A normal, requested shutdown/restart.'
            try {
                if ($evt.Properties -and $evt.Properties.Count -ge 1) { $result.Requestor = "$($evt.Properties[0].Value)" }
            } catch { }
            $result.PreviousShutdown = $evt.TimeCreated
            return $result
        }
    } catch {
        # Event log unreadable (permissions, a locked-down box, a Windows build that
        # behaves differently) - degrade to "we know it restarted, not why" rather than
        # erroring out or going silent.
        $result.Detail = "Cause could not be determined (event log unavailable: $($_.Exception.Message))"
    }
    return $result
}

# On a Hyper-V host, an outage took the guests down too - listing the VM State items
# that came back turns "the host restarted" into "here's what came back with it".
function Get-VMStateSummaryForOutage {
    $vmItems = @($script:Items | Where-Object { $_.Type -eq 'VMState' -and $_.Enabled })
    if ($vmItems.Count -eq 0) { return "" }
    $rows = ""
    foreach ($it in $vmItems) {
        Ensure-ItemState -Item $it
        $st = $script:ItemState[$it.Id]
        $status = if ($st.LastStatus) { $st.LastStatus } else { "Unknown" }
        $dot = switch ($status) { "Up"{"#2ECC71"} "Down"{"#E24B4A"} default{"#8C929B"} }
        $bg  = switch ($status) { "Up"{"#eafaf1"} "Down"{"#fdecea"} default{"#f4f4f5"} }
        $rows += "<tr style='background:$bg;'><td style='padding:6px 14px;font-size:13px;color:#222222;'><span style='display:inline-block;width:7px;height:7px;border-radius:50%;background:$dot;margin-right:6px;'></span>$($it.Name)</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$status</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$($st.LastMessage)</td></tr>"
    }
    "<div style='padding:12px 20px 4px 20px;font-size:12px;color:#888888;'>VMs on this host:</div>" +
    "<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;'>$rows</table>"
}

$script:RestartNoticeChecked = $false
function Check-RestartNotice {
    if ($script:RestartNoticeChecked) { return }
    $mode = "$($script:General.RestartNotifyMode)"
    if ($mode -ne 'UnexpectedOnly' -and $mode -ne 'All') { $script:RestartNoticeChecked = $true; return }

    # Wait out the startup grace period first - this notice shouldn't compete with the
    # boot storm it's reporting on, and the VM summary is more accurate once things settle.
    if (Test-InStartupGracePeriod) { return }

    $bootTime = Get-SystemBootTime
    $bootKey = $bootTime.ToString("o")
    if ("$($script:General.LastReportedBootTime)" -eq $bootKey) { $script:RestartNoticeChecked = $true; return }

    $class = Get-LastBootClassification
    if ($mode -eq 'UnexpectedOnly' -and $class.Kind -ne 'Unexpected') {
        # Still record it so we don't re-evaluate this boot forever.
        $script:General.LastReportedBootTime = $bootKey; Save-AppConfig
        $script:RestartNoticeChecked = $true
        Write-Log "Restart detected ($($class.Kind)) - not reported (mode is Unexpected-only)."
        return
    }

    $isUnexpected = ($class.Kind -eq 'Unexpected')
    $statusWord = if ($isUnexpected) { "OUTAGE" } else { "RESTARTED" }
    $subjectName = if ($isUnexpected) { "$(Get-InstanceName) restarted unexpectedly" } else { "$(Get-InstanceName) came back up" }

    $details = [ordered]@{
        "Machine"   = "$(Get-InstanceName) ($env:COMPUTERNAME)"
        "Booted at" = $bootTime.ToString("yyyy-MM-dd HH:mm:ss")
        "Cause"     = $class.Detail
    }
    if ($class.Requestor) { $details["Requested by"] = $class.Requestor }
    # Only report downtime if it looks sane - a clock change (or a misparsed event) can
    # otherwise produce a negative or absurd duration, which is worse than saying nothing.
    if ($class.PreviousShutdown) {
        $span = $bootTime - $class.PreviousShutdown
        if ($span.TotalSeconds -gt 0 -and $span.TotalDays -lt 30) {
            $details["Went down at"] = $class.PreviousShutdown.ToString("yyyy-MM-dd HH:mm:ss")
            $details["Down for"]     = Format-FriendlyDuration $span
        }
    }

    # Deliberately NOT routed through the alert batch - this is a one-off machine-level
    # event, and burying "the server lost power" inside a digest of item alerts would
    # badly undersell it.
    $vmSummary = Get-VMStateSummaryForOutage
    $note = if ($isUnexpected) { "Worth checking that everything came back cleanly." } else { "" }
    Send-AlertEmail -Status $statusWord -ItemName $subjectName -Details $details -Note $note -Kind 'Restart' -ExtraHtml $vmSummary

    # Persist immediately (not at the next general save) so a crash right after sending
    # can't cause a duplicate notice on the next start.
    $script:General.LastReportedBootTime = $bootKey; Save-AppConfig
    $script:RestartNoticeChecked = $true
    Write-Log "Restart notice sent ($($class.Kind))."
}

# Friendly label for a monitor type, used in email bodies (and the dashboard).
function Get-TypeLabel { param([string]$Type)
    switch ($Type) {
        "Service"     { "Service" }
        "Process"     { "Process" }
        "Port"        { "TCP Port" }
        "Url"         { "HTTP(S) URL" }
        "Cert"        { "TLS Certificate" }
        "VMService"   { "VM Service" }
        "VMProcess"   { "VM Process" }
        "VMState"     { "VM State" }
        "BackupDrive" { "Backup Drive" }
        default       { $Type }
    }
}

# If the person already put "Name <addr>" in the From field, pull out just addr -
# we're about to wrap it in our own "Watchdog (machine) <addr>" display name.
function Get-BareEmailAddress { param([string]$AddressField)
    if ($AddressField -match '<([^>]+)>') { return $Matches[1].Trim() }
    return $AddressField.Trim()
}

# ------------------------------------------------------------------
#  HTML email templating - each incident type gets its own color and
#  a clean details table instead of a wall of pre-formatted text.
# ------------------------------------------------------------------
function Get-StatusEmailColor { param([string]$Status)
    switch -Regex ($Status) {
        '^(DOWN|EXPIRED|CRITICAL|ALERT|OUTAGE)$' { '#E24B4A' }
        '^(UP|RENEWED|ROTATED)$'                 { '#2ECC71' }
        '^(EXPIRING|OVERDUE|NOTICE)$'            { '#E6A014' }
        '^(DAILY|RESTARTED)$'                    { '#3B82C4' }
        default                                  { '#8C929B' }   # TEST and anything else
    }
}

# Turns a TimeSpan into a short human string, e.g. "12 minutes", "2 hours 5 minutes".
function Format-FriendlyDuration { param([TimeSpan]$Span)
    if ($Span.TotalMinutes -lt 1) { return "under a minute" }
    if ($Span.TotalHours -lt 1) { return "{0:N0} minute{1}" -f $Span.Minutes, $(if ($Span.Minutes -ne 1) { "s" } else { "" }) }
    if ($Span.TotalDays -lt 1) {
        $h = [int]$Span.Hours; $m = [int]$Span.Minutes
        return "$h hour$(if ($h -ne 1) {'s'}) $m minute$(if ($m -ne 1) {'s'})"
    }
    $d = [int]$Span.Days; $h = [int]$Span.Hours
    return "$d day$(if ($d -ne 1) {'s'}) $h hour$(if ($h -ne 1) {'s'})"
}

# HTML email clients (Outlook especially) need table-based layout with inline styles -
# no CSS variables, no flexbox/grid, no external stylesheets. $Details is an ordered
# dictionary of Label -> Value rows. $BodyHtmlOverride, if given, replaces the details
# table entirely (used for the heartbeat's per-item table).
function Build-AlertHtml {
    param(
        [string]$Status,
        [string]$ItemName,
        $Details = [ordered]@{},
        [string]$Note = "",
        [string]$BodyHtmlOverride = "",
        [string]$ExtraHtml = ""
    )
    $color = Get-StatusEmailColor -Status $Status
    $inst = Get-InstanceName

    if ($BodyHtmlOverride) {
        $middle = $BodyHtmlOverride
    } else {
        $rows = ""
        foreach ($k in $Details.Keys) {
            $rows += "<tr><td style='padding:8px 20px;color:#888888;font-size:12px;width:38%;border-bottom:1px solid #eeeeee;vertical-align:top;'>$k</td><td style='padding:8px 20px;color:#222222;font-size:13px;border-bottom:1px solid #eeeeee;'>$($Details[$k])</td></tr>"
        }
        $middle = "<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;'>$rows</table>"
    }
    $noteHtml = if ($Note) { "<div style='padding:10px 20px;color:#444444;font-size:13px;background:#f7f7f8;'>$Note</div>" } else { "" }

    @"
<html><body style="margin:0;padding:0;background:#f2f3f5;font-family:Segoe UI,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f3f5;padding:24px 0;">
<tr><td align="center">
<table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;">
<tr><td style="background:$color;padding:16px 20px;">
<span style="color:#ffffff;font-size:19px;font-weight:bold;">$Status</span>
<div style="color:#ffffff;font-size:14px;opacity:0.9;">$ItemName</div>
</td></tr>
<tr><td>$middle</td></tr>
<tr><td>$ExtraHtml</td></tr>
<tr><td>$noteHtml</td></tr>
<tr><td style="padding:10px 20px;background:#f7f7f8;color:#999999;font-size:11px;">Watchdog ($inst)</td></tr>
</table>
</td></tr>
</table>
</body></html>
"@
}

# Color-coded per-item table for the daily heartbeat, instead of the old monospace
# text block (which often misaligns in HTML-only mail clients).
function Build-HeartbeatTableHtml {
    $rowsHtml = ""
    foreach ($it in $script:Items) {
        Ensure-ItemState -Item $it
        $st = $script:ItemState[$it.Id]
        $status = if (-not $it.Enabled) { "Disabled" } else { $st.LastStatus }
        $bg  = switch ($status) { "Up"{"#eafaf1"} "Down"{"#fdecea"} "Warning"{"#fff8e6"} default{"#f4f4f5"} }
        $dot = switch ($status) { "Up"{"#2ECC71"} "Down"{"#E24B4A"} "Warning"{"#E6A014"} default{"#8C929B"} }
        $uptime = Get-UptimePercent $st
        $uptimeStr = if ($null -ne $uptime) { "$uptime%" } else { "-" }
        $respStr = if ($null -ne $st.LastResponseMs) { "$($st.LastResponseMs) ms" } else { "-" }
        $rowsHtml += "<tr style='background:$bg;'><td style='padding:6px 14px;font-size:13px;color:#222222;'><span style='display:inline-block;width:7px;height:7px;border-radius:50%;background:$dot;margin-right:6px;'></span>$($it.Name)</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$status</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$uptimeStr</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$respStr</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$($st.LastMessage)</td></tr>"
    }
    if ([string]::IsNullOrEmpty($rowsHtml)) {
        return "<div style='padding:14px 20px;color:#888888;font-size:13px;'>No items are configured.</div>"
    }
    "<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;font-size:12px;'>" +
    "<tr style='background:#f7f7f8;'><td style='padding:6px 14px;color:#888888;'>NAME</td><td style='padding:6px 14px;color:#888888;'>STATUS</td><td style='padding:6px 14px;color:#888888;'>UPTIME</td><td style='padding:6px 14px;color:#888888;'>RESP</td><td style='padding:6px 14px;color:#888888;'>DETAIL</td></tr>" +
    "$rowsHtml</table>"
}

# ------------------------------------------------------------------
#  Alert batching (digest mode) - OFF by default (window = 0).
#  ---------------------------------------------------------------
#  If several things go Down/Warning within a short window of each other (e.g. the
#  whole host loses network and takes out several checks at once), sending one grouped
#  email reads a lot better than a flood of separate ones. This only ever affects
#  DOWN/WARNING alert emails - recovery, heartbeat, and test emails always send right
#  away, and auto-restart actions are never delayed by this, only the notification.
#  The batch queue lives in memory only: if Watchdog restarts while something is
#  sitting in an unflushed batch, that particular pending alert doesn't survive the
#  restart - consistent with how all the other in-memory incident tracking already
#  resets on restart, but worth knowing if you set a long window.
# ------------------------------------------------------------------
$script:AlertBatch = New-Object System.Collections.Generic.List[object]
$script:AlertBatchWindowStart = $null

# Called instead of sending immediately when batching is on. Dedupes by ItemId so an
# item whose own retry throttle fires again before the batch flushes doesn't end up
# queued twice.
function Add-ToAlertBatch {
    param([string]$ItemId, [string]$ItemName, [string]$TypeLabel, [string]$Target, [string]$StatusWord, [string]$Detail, [string]$Kind)
    $existing = $script:AlertBatch | Where-Object { $_.ItemId -eq $ItemId } | Select-Object -First 1
    if ($existing) {
        $existing.StatusWord = $StatusWord; $existing.Detail = $Detail; $existing.Kind = $Kind
        return
    }
    if ($script:AlertBatch.Count -eq 0) { $script:AlertBatchWindowStart = Get-Date }
    $script:AlertBatch.Add([PSCustomObject]@{
        ItemId=$ItemId; ItemName=$ItemName; TypeLabel=$TypeLabel; Target=$Target; StatusWord=$StatusWord; Detail=$Detail; Kind=$Kind
    }) | Out-Null
}

function Build-BatchTableHtml {
    param($Records)
    $rowsHtml = ""
    foreach ($rec in $Records) {
        $bg  = if ($rec.Kind -eq 'Down') { "#fdecea" } else { "#fff8e6" }
        $dot = Get-StatusEmailColor -Status $rec.StatusWord
        $rowsHtml += "<tr style='background:$bg;'><td style='padding:6px 14px;font-size:13px;color:#222222;'><span style='display:inline-block;width:7px;height:7px;border-radius:50%;background:$dot;margin-right:6px;'></span>$($rec.ItemName)</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$($rec.TypeLabel)</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$($rec.Target)</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$($rec.StatusWord)</td><td style='padding:6px 14px;font-size:12px;color:#555555;'>$($rec.Detail)</td></tr>"
    }
    "<table role='presentation' width='100%' cellpadding='0' cellspacing='0' style='border-collapse:collapse;font-size:12px;'>" +
    "<tr style='background:#f7f7f8;'><td style='padding:6px 14px;color:#888888;'>NAME</td><td style='padding:6px 14px;color:#888888;'>TYPE</td><td style='padding:6px 14px;color:#888888;'>TARGET</td><td style='padding:6px 14px;color:#888888;'>STATUS</td><td style='padding:6px 14px;color:#888888;'>DETAIL</td></tr>" +
    "$rowsHtml</table>"
}

# Called every scheduler tick. If the batch is non-empty and has been open at least as
# long as the configured window, sends it - as a normal single-item email if only one
# thing ended up in it, or as a grouped digest if there's more than one.
function Flush-AlertBatchIfDue {
    if ($script:AlertBatch.Count -eq 0) { return }
    $windowSec = [int]$script:General.AlertBatchWindowSec
    # If batching was switched off while items were still queued, don't strand them -
    # flush what's already collected right now rather than waiting on a window that no
    # longer exists. (Returning early here would leave the queue orphaned indefinitely.)
    if ($windowSec -gt 0) {
        if (-not $script:AlertBatchWindowStart) { $script:AlertBatchWindowStart = Get-Date }
        if (((Get-Date) - $script:AlertBatchWindowStart).TotalSeconds -lt $windowSec) { return }
    }

    $records = @($script:AlertBatch)
    $script:AlertBatch.Clear()
    $script:AlertBatchWindowStart = $null

    if ($records.Count -eq 1) {
        $r = $records[0]
        $details = [ordered]@{ "Type" = $r.TypeLabel; "Target" = $r.Target; "Detail" = $r.Detail }
        Send-AlertEmail -Status $r.StatusWord -ItemName $r.ItemName -Details $details -ItemId $r.ItemId -Kind $r.Kind
        return
    }

    $hasDown = @($records | Where-Object { $_.Kind -eq 'Down' }).Count -gt 0
    $batchStatus = if ($hasDown) { "ALERT" } else { "NOTICE" }
    Send-AlertEmail -Status $batchStatus -ItemName "$($records.Count) items need attention" -BodyHtmlOverride (Build-BatchTableHtml -Records $records) -Kind 'Batch' -BatchItems $records
}

# ------------------------------------------------------------------
#  Non-blocking email sending
#  ---------------------------------------------------------------
#  Send-MailMessage takes at least a second or two even on success (TLS handshake,
#  auth, transmit), and WinForms is single-threaded - if that call happened directly
#  on the UI thread, the whole window would freeze for the duration (worse if a retry
#  kicks in). So the actual network send runs in a background runspace; the UI thread
#  only ever does a cheap, instant check of whether it's finished yet (via
#  Complete-PendingSends, called every scheduler tick) - it never waits.
# ------------------------------------------------------------------
$script:PendingSends = New-Object System.Collections.Generic.List[object]

function Start-AsyncMailSend {
    param([hashtable]$MailParams, [string]$SubjectLine, [string]$ItemId = "", [string]$Kind = "", $BatchItems = $null)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($p)
        # A fresh runspace does NOT inherit the parent session's ServicePointManager
        # protocol setting, so TLS 1.2 must be forced HERE too - otherwise on an older
        # Windows build (Server 2012 R2 / early 2016) this send would fall back to a
        # protocol Office 365 / Gmail reject, and the email would silently fail.
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Send-MailMessage @p
                return @{ Ok = $true; Attempt = $attempt }
            } catch {
                $errMsg = $_.Exception.Message
                if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 5 }
                else { return @{ Ok = $false; Error = $errMsg } }
            }
        }
    }).AddArgument($MailParams)
    $handle = $ps.BeginInvoke()
    $script:PendingSends.Add(@{
        PS = $ps; Handle = $handle; SubjectLine = $SubjectLine
        ItemId = $ItemId; Kind = $Kind; BatchItems = $BatchItems; Started = Get-Date
    }) | Out-Null
}

# Drains any background sends that have finished since the last check - cheap (just
# an IsCompleted flag check) unless something actually completed. Called every
# scheduler tick, from Check Now, and from the headless loop.
function Complete-PendingSends {
    if ($script:PendingSends.Count -eq 0) { return }
    $stillPending = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $script:PendingSends) {
        if (-not $entry.Handle.IsCompleted) { $stillPending.Add($entry) | Out-Null; continue }

        $result = $null
        try { $result = $entry.PS.EndInvoke($entry.Handle) } catch { $result = @{ Ok = $false; Error = $_.Exception.Message } }
        try { $entry.PS.Dispose() } catch { }
        $ok = [bool]($result -and $result.Ok)

        if ($ok) { Write-Log "Email sent: $($entry.SubjectLine)" }
        else { Write-Log "Email FAILED ($($entry.SubjectLine)): $($result.Error)" }

        if ($entry.ItemId -and $script:ItemState.ContainsKey($entry.ItemId)) {
            $st = $script:ItemState[$entry.ItemId]
            if ($ok -and ($entry.Kind -eq 'Down' -or $entry.Kind -eq 'Warning')) {
                $st.EmailSentForIncident = $true
                $st.LastEmailSentTime = Get-Date
            }
        }
        # A batch digest covers several items at once - on success, mark each of them
        # exactly as if they'd been individually emailed, so they don't get re-queued.
        if ($ok -and $entry.BatchItems) {
            foreach ($rec in $entry.BatchItems) {
                if (($rec.Kind -eq 'Down' -or $rec.Kind -eq 'Warning') -and $script:ItemState.ContainsKey($rec.ItemId)) {
                    $bst = $script:ItemState[$rec.ItemId]
                    $bst.EmailSentForIncident = $true
                    $bst.LastEmailSentTime = Get-Date
                }
            }
        }
        if ($entry.Kind -eq 'Heartbeat' -and $ok) { $script:LastHeartbeatDate = (Get-Date).Date }
        if ($entry.Kind -eq 'Test' -and $script:UI.LblTest) {
            if ($ok) { $script:UI.LblTest.ForeColor = $script:Theme.Green; $script:UI.LblTest.Text = "Sent." }
            else { $script:UI.LblTest.ForeColor = $script:Theme.Red; $script:UI.LblTest.Text = "Failed - see Log tab." }
            if ($script:UI.BtnTest) { $script:UI.BtnTest.Enabled = $true }
        }
    }
    $script:PendingSends = $stillPending
}

# Subject is deliberately "STATUS: Name" - on a phone lock screen or a narrow inbox
# list, that's the only part guaranteed to be visible, so the two things that matter
# (what happened, to what) come first. No app-name/machine clutter in the subject -
# those live in the sender display name instead. Body is HTML, styled per status
# (see Build-AlertHtml) - pass -Details for a structured facts table, or
# -BodyHtmlOverride to replace it entirely (used by the heartbeat). Building the
# message is fast (pure string work, no I/O) so it stays synchronous; only the
# actual transmission is handed off to Start-AsyncMailSend. -ItemId/-Kind let
# Complete-PendingSends update the right item's state once the send finishes.
function Send-AlertEmail {
    param(
        [string]$Status,
        [string]$ItemName,
        $Details = [ordered]@{},
        [string]$Note = "",
        [string]$BodyHtmlOverride = "",
        [string]$ItemId = "",
        [string]$Kind = "",
        $BatchItems = $null,
        [string]$ExtraHtml = ""
    )
    if ([string]::IsNullOrWhiteSpace($script:Email.SmtpServer) -or [string]::IsNullOrWhiteSpace($script:Email.To)) {
        Write-Log "Email skipped (SMTP/recipient not configured): ${Status}: $ItemName"; return
    }

    # Office 365 / Gmail refuse anything below TLS 1.2 - force it for this send.
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }

    $subjectLine = "${Status}: $ItemName"
    # Optional short extra tag some people like (e.g. a site code); off by default.
    if (-not [string]::IsNullOrWhiteSpace($script:Email.SubjectPrefix)) {
        $subjectLine = "$($script:Email.SubjectPrefix.Trim()) $subjectLine"
    }
    $htmlBody = Build-AlertHtml -Status $Status -ItemName $ItemName -Details $Details -Note $Note -BodyHtmlOverride $BodyHtmlOverride -ExtraHtml $ExtraHtml

    $recipients = @($script:Email.To -split "[,;]" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    $params = @{
        SmtpServer  = $script:Email.SmtpServer
        Port        = [int]$script:Email.SmtpPort
        # Display name carries the app + machine, so the subject stays free for the status.
        From        = "Watchdog ($(Get-InstanceName)) <$(Get-BareEmailAddress $script:Email.From)>"
        To          = $recipients
        Subject     = $subjectLine
        Body        = $htmlBody
        BodyAsHtml  = $true
        UseSsl      = [bool]$script:Email.UseSSL
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Email.Username)) {
        $plain = Unprotect-ToPlainPassword $script:Email.EncryptedPassword
        if (-not [string]::IsNullOrEmpty($plain)) {
            $sec = ConvertTo-SecureString $plain -AsPlainText -Force
            $params.Credential = New-Object System.Management.Automation.PSCredential($script:Email.Username, $sec)
        } else {
            Write-Log "WARNING: username set but no password stored/decryptable - sending without auth."
        }
    }

    Start-AsyncMailSend -MailParams $params -SubjectLine $subjectLine -ItemId $ItemId -Kind $Kind -BatchItems $BatchItems
}

# ==================================================================
#  Check primitives  ->  @{ Status = 'Up'|'Down'|'Warning'; Detail = '...' }
# ==================================================================
function Test-ServiceUp { param([string]$Target)
    try {
        $svc = Get-Service -Name $Target -ErrorAction Stop
        if ($svc.Status -eq 'Running') { @{ Status='Up'; Detail="Running" } }
        else { @{ Status='Down'; Detail="Status: $($svc.Status)" } }
    } catch { @{ Status='Down'; Detail="Service not found" } }
}

function Test-ProcessUp { param([string]$Target)
    $name = $Target -replace '\.exe$',''
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($p) { @{ Status='Up'; Detail="$(@($p).Count) instance(s)" } } else { @{ Status='Down'; Detail="Not running" } }
}

function Test-PortUp { param([string]$HostName, [int]$Port, [int]$TimeoutMs = 4000)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
            @{ Status='Up'; Detail="Port $Port open" }
        } else { @{ Status='Down'; Detail="Port $Port not reachable" } }
    } catch { @{ Status='Down'; Detail=$_.Exception.Message } }
    finally { if ($client) { $client.Close() } }
}

function Test-UrlUp { param([string]$Url, [int]$ExpectedCode = 200, [int]$TimeoutSec = 10)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
        $code = [int]$resp.StatusCode
        if ($code -eq $ExpectedCode) { @{ Status='Up'; Detail="HTTP $code" } } else { @{ Status='Down'; Detail="HTTP $code (expected $ExpectedCode)" } }
    } catch {
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode
                  if ($code -eq $ExpectedCode) { return @{ Status='Up'; Detail="HTTP $code" } }
                  return @{ Status='Down'; Detail="HTTP $code (expected $ExpectedCode)" } } catch { }
        }
        @{ Status='Down'; Detail=$_.Exception.Message }
    }
}

function Resolve-HostPort { param([string]$InputText, [int]$DefaultPort = 443)
    $h = $InputText.Trim(); $port = $DefaultPort
    if ($h -match '^[a-zA-Z]+://') {
        try { $u = [uri]$h; $h = $u.Host; if ($u.Port -gt 0) { $port = $u.Port } } catch { }
    } elseif ($h -match '^(?<host>[^:/]+):(?<port>\d+)$') {
        $h = $Matches['host']; $port = [int]$Matches['port']
    }
    @{ HostName = $h; Port = $port }
}

function Test-CertExpiry { param([string]$Target, [int]$Port = 443, [int]$WarnDays = 60, [int]$TimeoutMs = 8000)
    $hp = Resolve-HostPort -InputText $Target -DefaultPort $Port
    $client = $null; $ssl = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hp.HostName, $hp.Port, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) {
            return @{ Status='Down'; Detail="Cannot connect to $($hp.HostName):$($hp.Port)"; DaysLeft=$null }
        }
        # Bound the TLS handshake itself - AuthenticateAsClient is a blocking call with no
        # timeout parameter of its own, so a server that accepts the TCP connection but never
        # completes (or stalls mid-) the handshake could otherwise hang this check forever.
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback]{ $true }))
        $ssl.AuthenticateAsClient($hp.HostName)
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 ($ssl.RemoteCertificate)
        $notAfter = $cert.NotAfter
        $daysLeft = [int]([Math]::Floor(($notAfter - (Get-Date)).TotalDays))
        $expStr = $notAfter.ToString("yyyy-MM-dd")
        if ($daysLeft -lt 0)            { return @{ Status='Down';    Detail="EXPIRED on $expStr"; DaysLeft=$daysLeft } }
        elseif ($daysLeft -le $WarnDays){ return @{ Status='Warning'; Detail="Expires in $daysLeft d ($expStr)"; DaysLeft=$daysLeft } }
        else                           { return @{ Status='Up';      Detail="Valid, $daysLeft d left ($expStr)"; DaysLeft=$daysLeft } }
    } catch {
        return @{ Status='Down'; Detail="TLS error: $($_.Exception.Message)"; DaysLeft=$null }
    } finally {
        if ($ssl)    { $ssl.Dispose() }
        if ($client) { $client.Close() }
    }
}

# ------------------------------------------------------------------
#  Rotating USB backup drive tracking
#  ---------------------------------------------------------------
#  Watches a drive letter (assumed reserved for whichever physical backup
#  drive is currently connected - set once via Disk Management) and tracks
#  how long it's been since a "rotation" was detected. A rotation is either:
#    (a) the drive going from disconnected to connected (a swap was observed), or
#    (b) the drive's volume serial number changing while it stayed present the
#        whole time (catches a fast swap that happened between two checks).
#  This is a stateful check - unlike the other Test-* functions it needs the
#  PREVIOUS check's results, passed in by the caller (Update-ItemCheck) from
#  item state, and returns the updated values for the caller to store back.
# ------------------------------------------------------------------
function Test-BackupDriveRotation {
    param(
        [string]$DriveLetter,
        [int]$WarnAfterDays = 7,
        [int]$AlertAfterDays = 10,
        $LastRotationTime = $null,
        $WasPresent = $null,
        [string]$LastSerial = ""
    )
    $letter = ($DriveLetter.Trim().TrimEnd('\','/',':')).ToUpper() + ":"
    $disk = $null
    try { $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter'" -ErrorAction Stop } catch { }
    $isPresent = $null -ne $disk
    $serial = if ($disk -and $disk.VolumeSerialNumber) { "$($disk.VolumeSerialNumber)" } else { "" }

    $rotationDetected = $false
    if ($null -eq $LastRotationTime) {
        # First time this item has ever been checked - start the clock now rather than
        # immediately reporting it as overdue with nothing to compare against.
        $rotationDetected = $true
    } elseif ($isPresent -and ($WasPresent -eq $false)) {
        # Was disconnected, now connected - a drive was just swapped in.
        $rotationDetected = $true
    } elseif ($isPresent -and $WasPresent -and $serial -and $LastSerial -and $serial -ne $LastSerial) {
        # Connected both times, but it's a different volume now - a swap happened
        # fast enough that the brief disconnect fell between two checks.
        $rotationDetected = $true
    }

    $newLastRotation = if ($rotationDetected) { Get-Date } else { $LastRotationTime }
    $daysSince = [Math]::Floor(((Get-Date) - $newLastRotation).TotalDays)
    $presenceNote = if ($isPresent) { "currently connected" } else { "currently disconnected" }

    $status = if ($daysSince -ge $AlertAfterDays) { 'Down' } elseif ($daysSince -ge $WarnAfterDays) { 'Warning' } else { 'Up' }
    $detail = if ($rotationDetected -and $daysSince -eq 0) { "Rotation detected today ($presenceNote)" }
              else { "Last rotated $daysSince day$(if($daysSince -ne 1){'s'}) ago ($presenceNote)" }
    if ($status -eq 'Down') { $detail = "OVERDUE - $detail" }
    elseif ($status -eq 'Warning') { $detail = "Getting overdue - $detail (expected every ~$WarnAfterDays days)" }

    @{
        Status = $status; Detail = $detail
        NewLastRotationTime = $newLastRotation; NewWasPresent = $isPresent; NewSerial = $serial
    }
}

# ------------------------------------------------------------------
#  Hyper-V guest monitoring via PowerShell Direct (VMBus - no network)
# ------------------------------------------------------------------
function Get-ItemVMCredential { param($Item)
    if ([string]::IsNullOrWhiteSpace($Item.VMUsername)) { return $null }
    $plain = Unprotect-ToPlainPassword $Item.EncryptedVMPassword
    if ([string]::IsNullOrEmpty($plain)) { return $null }
    $sec = ConvertTo-SecureString $plain -AsPlainText -Force
    return (New-Object System.Management.Automation.PSCredential($Item.VMUsername, $sec))
}

function Test-VMService { param($VMName, $Cred, $ServiceName)
    if (-not $Cred) { return @{ Status='Down'; Detail="No guest credentials set" } }
    try {
        $r = Invoke-Command -VMName $VMName -Credential $Cred -ErrorAction Stop -ArgumentList $ServiceName -ScriptBlock {
            param($svc)
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) { return @{ Found=$false } }
            @{ Found=$true; Status="$($s.Status)" }
        }
        if (-not $r.Found) { return @{ Status='Down'; Detail="Service '$ServiceName' not found in $VMName" } }
        if ($r.Status -eq 'Running') { return @{ Status='Up'; Detail="Running in $VMName" } }
        return @{ Status='Down'; Detail="$($r.Status) in $VMName" }
    } catch {
        return @{ Status='Down'; Detail="PowerShell Direct to $VMName failed: $($_.Exception.Message)" }
    }
}

function Test-VMProcess { param($VMName, $Cred, $ProcName)
    if (-not $Cred) { return @{ Status='Down'; Detail="No guest credentials set" } }
    $name = $ProcName -replace '\.exe$',''
    try {
        $r = Invoke-Command -VMName $VMName -Credential $Cred -ErrorAction Stop -ArgumentList $name -ScriptBlock {
            param($pn)
            $p = Get-Process -Name $pn -ErrorAction SilentlyContinue
            @{ Count = @($p).Count }
        }
        if ($r.Count -gt 0) { return @{ Status='Up'; Detail="$($r.Count) instance(s) in $VMName" } }
        return @{ Status='Down'; Detail="'$ProcName' not running in $VMName" }
    } catch {
        return @{ Status='Down'; Detail="PowerShell Direct to $VMName failed: $($_.Exception.Message)" }
    }
}

# Checks whether a Hyper-V VM itself is powered on - a host-level operation, so unlike
# the guest checks above this needs no credentials at all, just the VM name.
function Test-VMState { param([string]$VMName)
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ($vm.State -eq 'Running') { return @{ Status='Up'; Detail="Running" } }
        return @{ Status='Down'; Detail="State: $($vm.State)" }
    } catch {
        return @{ Status='Down'; Detail="VM '$VMName' not found or Hyper-V unavailable: $($_.Exception.Message)" }
    }
}

function Invoke-RestartAction { param($Item)
    switch ($Item.Type) {
        "Service" {
            try { Start-Service -Name $Item.Target -ErrorAction Stop; @{ Ok=$true; Detail="Start-Service issued" } }
            catch { @{ Ok=$false; Detail=$_.Exception.Message } }
        }
        "Process" {
            try {
                if ([string]::IsNullOrWhiteSpace($Item.ExePath)) { return @{ Ok=$false; Detail="No executable path set for restart" } }
                $p = @{ FilePath = $Item.ExePath }
                if ($Item.Arguments)        { $p.ArgumentList     = $Item.Arguments }
                if ($Item.WorkingDirectory) { $p.WorkingDirectory = $Item.WorkingDirectory }

                if (-not [string]::IsNullOrWhiteSpace($Item.RunAsUser)) {
                    $plainPw = Unprotect-ToPlainPassword $Item.EncryptedRunAsPassword
                    if ([string]::IsNullOrEmpty($plainPw)) { return @{ Ok=$false; Detail="Run-as-user is set but no password is stored - re-enter it on this item" } }
                    $sec = ConvertTo-SecureString $plainPw -AsPlainText -Force
                    $p.Credential = New-Object System.Management.Automation.PSCredential($Item.RunAsUser, $sec)
                    # Windows PowerShell doesn't allow -WindowStyle together with -Credential,
                    # so a run-as-user restart may briefly show a window - a known limitation,
                    # not a bug. The account's real profile (and app data/tokens) still loads.
                    Start-Process @p -ErrorAction Stop
                    @{ Ok=$true; Detail="Start-Process issued as $($Item.RunAsUser)" }
                } else {
                    $p.WindowStyle = 'Hidden'
                    Start-Process @p -ErrorAction Stop
                    @{ Ok=$true; Detail="Start-Process issued (hidden)" }
                }
            } catch { @{ Ok=$false; Detail=$_.Exception.Message } }
        }
        "VMService" {
            $cred = Get-ItemVMCredential -Item $Item
            if (-not $cred) { return @{ Ok=$false; Detail="No guest credentials" } }
            try {
                Invoke-Command -VMName $Item.VMName -Credential $cred -ErrorAction Stop -ArgumentList $Item.Target -ScriptBlock {
                    param($svc) Start-Service -Name $svc -ErrorAction Stop
                }
                @{ Ok=$true; Detail="Start-Service issued inside $($Item.VMName)" }
            } catch { @{ Ok=$false; Detail=$_.Exception.Message } }
        }
        "VMProcess" {
            $cred = Get-ItemVMCredential -Item $Item
            if (-not $cred) { return @{ Ok=$false; Detail="No guest credentials" } }
            if ([string]::IsNullOrWhiteSpace($Item.ExePath)) { return @{ Ok=$false; Detail="No guest exe path set for restart" } }
            try {
                Invoke-Command -VMName $Item.VMName -Credential $cred -ErrorAction Stop -ArgumentList $Item.ExePath, $Item.Arguments -ScriptBlock {
                    param($exe,$argstr)
                    if ($argstr) { Start-Process -FilePath $exe -ArgumentList $argstr -WindowStyle Hidden } else { Start-Process -FilePath $exe -WindowStyle Hidden }
                }
                @{ Ok=$true; Detail="Start-Process issued inside $($Item.VMName) (hidden)" }
            } catch { @{ Ok=$false; Detail=$_.Exception.Message } }
        }
        "VMState" {
            try { Start-VM -Name $Item.Target -ErrorAction Stop; @{ Ok=$true; Detail="Start-VM issued" } }
            catch { @{ Ok=$false; Detail=$_.Exception.Message } }
        }
        default { @{ Ok=$false; Detail="Auto-restart not supported for type '$($Item.Type)'" } }
    }
}

# ==================================================================
#  Icons (built once; reused to avoid GDI handle leaks over long runtime)
# ==================================================================
function Initialize-Icons {
    foreach ($c in @('Green','Amber','Red','Gray')) {
        $bmp = New-Object System.Drawing.Bitmap 32,32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $script:Theme[$c]
        $pen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(50,50,50)), 1.5
        $g.FillEllipse($brush, 3, 3, 26, 26)
        $g.DrawEllipse($pen, 3, 3, 26, 26)
        $g.Dispose()
        $script:Icons[$c] = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
}

# ==================================================================
#  Startup registration
# ==================================================================
function Set-StartupRegistration { param([bool]$Enable)
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"; $name = "Watchdog"
    try {
        if ($Enable) {
            $sp = $script:SelfPath
            if ([string]::IsNullOrWhiteSpace($sp)) { Write-Log "Cannot set login-run: script has no path (pasted?)."; return }
            Set-ItemProperty -Path $runKey -Name $name -Value "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$sp`"" -Force
        } elseif (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runKey -Name $name -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Log "Startup registration error: $($_.Exception.Message)" }
}

# ==================================================================
#  Boot startup task (runs before/without user login, as SYSTEM, headless)
# ==================================================================
$script:BootTaskName = "Watchdog"

function Test-IsElevated {
    try {
        $p = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-BootTaskState {
    # Returns 'Absent', or the task State ('Ready','Running','Disabled',...)
    try {
        $t = Get-ScheduledTask -TaskName $script:BootTaskName -ErrorAction Stop
        return "$($t.State)"
    } catch { return "Absent" }
}
function Test-BootTaskExists { return ((Get-BootTaskState) -ne "Absent") }

# Canonical Windows PowerShell path (works even if the app was started under pwsh 7)
function Get-WinPowerShellPath {
    $p = Join-Path ([System.Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path $p) { return $p }
    return (Join-Path $PSHOME 'powershell.exe')
}

# Runs a block of PowerShell as admin (UAC prompt if we're not already elevated).
# Returns $true if the elevated process exited 0.
function Invoke-Elevated { param([string]$Script)
    $psExe = Get-WinPowerShellPath
    $tmp = Join-Path $env:TEMP ("wd_" + [guid]::NewGuid().ToString('N') + ".ps1")
    Set-Content -Path $tmp -Value $Script -Encoding UTF8
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tmp`""
        if (Test-IsElevated) {
            $p = Start-Process -FilePath $psExe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
        } else {
            $p = Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -Wait -PassThru
        }
        return ($p.ExitCode -eq 0)
    } catch {
        Write-Log "Elevated command failed/cancelled: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Test-CanInstall {
    # Install needs a real script file on disk (won't work if pasted into a console).
    return (-not [string]::IsNullOrWhiteSpace($script:SelfPath)) -and (Test-Path $script:SelfPath)
}

# GUI side: launches the (elevated) install routine, then verifies the task exists.
function Install-BootTask {
    if (-not (Test-CanInstall)) { Write-Log "Install needs the script saved as a .ps1 file (it was pasted/typed, so it has no path)."; return $false }

    $resultPath = Join-Path $script:InstallDir "install-result.txt"
    try { if (Test-Path $resultPath) { Remove-Item $resultPath -Force -ErrorAction SilentlyContinue } } catch { }

    $psExe = Get-WinPowerShellPath
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SelfPath)`" -InstallTask"
    try {
        if (Test-IsElevated) { $p = Start-Process -FilePath $psExe -ArgumentList $argList -Wait -PassThru }
        else                 { $p = Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -Wait -PassThru }
    } catch {
        Write-Log "Install launch failed/cancelled: $($_.Exception.Message)"; return $false
    }
    Start-Sleep -Milliseconds 500

    $result = ""
    try { if (Test-Path $resultPath) { $result = (Get-Content $resultPath -Raw).Trim() } } catch { }

    if (Test-BootTaskExists) {
        Write-Log "Startup task installed and verified (runs as SYSTEM). Script deployed to $($script:DeployedPs1)"
        return $true
    }
    Write-Log "Startup task NOT created. Installer said: $result"
    return $false
}

# Runs elevated (via -InstallTask). Copies the script to C:\Watchdog and registers a
# task that runs as SYSTEM at every boot - no password needed and, unlike a per-user
# task, it's completely unaffected if your Windows account password ever changes.
function Invoke-TaskInstall {
    $resultPath = Join-Path $script:InstallDir "install-result.txt"
    try {
        if (-not (Test-Path $script:InstallDir)) { New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null }

        $src = $script:SelfPath
        if ($src -and (Test-Path $src) -and ($src -ne $script:DeployedPs1)) {
            Copy-Item -LiteralPath $src -Destination $script:DeployedPs1 -Force
        }
        if (-not (Test-Path $script:DeployedPs1)) { "ERROR: could not create $($script:DeployedPs1)" | Set-Content $resultPath -Encoding UTF8; return }

        $psExe = Get-WinPowerShellPath
        Import-Module ScheduledTasks -ErrorAction SilentlyContinue
        $action  = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$($script:DeployedPs1)`" -Headless"
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        try { $settings.ExecutionTimeLimit = 'PT0S' } catch { }

        Register-ScheduledTask -TaskName $script:BootTaskName -Action $action -Trigger $trigger `
            -User 'SYSTEM' -RunLevel Highest -Settings $settings -Force | Out-Null
        try { Start-ScheduledTask -TaskName $script:BootTaskName } catch { }
        "OK" | Set-Content $resultPath -Encoding UTF8
    } catch {
        try { "ERROR: $($_.Exception.Message)" | Set-Content $resultPath -Encoding UTF8 } catch { }
    }
}

function Remove-BootTask {
    $remover = @"
`$ErrorActionPreference = 'SilentlyContinue'
Stop-ScheduledTask   -TaskName '$($script:BootTaskName)'
Unregister-ScheduledTask -TaskName '$($script:BootTaskName)' -Confirm:`$false
exit 0
"@
    Invoke-Elevated -Script $remover | Out-Null
    Start-Sleep -Milliseconds 300
    if (-not (Test-BootTaskExists)) { Write-Log "Boot startup task removed."; return $true }
    Write-Log "Boot task still present after remove attempt."
    return $false
}

# ==================================================================
#  Pickers
# ==================================================================
# Rounded corners via a clipping region - standard lightweight WinForms technique.
function Set-RoundedRegion {
    param($Control, [int]$Radius)
    if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2; $w = $Control.Width; $h = $Control.Height
    if ($w -le $d -or $h -le $d) { $d = [Math]::Max(2, [Math]::Min($w,$h) - 1) }
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w-$d, 0, $d, $d, 270, 90)
    $path.AddArc($w-$d, $h-$d, $d, $d, 0, 90)
    $path.AddArc(0, $h-$d, $d, $d, 90, 90)
    $path.CloseFigure()
    $Control.Region = New-Object System.Drawing.Region($path)
}

# Flat-styled button. WinForms honours custom colours once FlatStyle is Flat, which is
# what lets the dark footer keep matching buttons instead of stock grey ones.
function Set-FlatButton {
    param($Button, [switch]$Dark, [switch]$Primary)
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.Font = $script:BaseFont
    if ($Primary) {
        $Button.BackColor = $script:Theme.Accent; $Button.ForeColor = [System.Drawing.Color]::White
        $Button.FlatAppearance.BorderSize = 0
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(72,155,236)
    } elseif ($Dark) {
        $Button.BackColor = [System.Drawing.Color]::FromArgb(45,51,61); $Button.ForeColor = [System.Drawing.Color]::FromArgb(226,229,233)
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(62,69,80)
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(58,65,77)
    } else {
        $Button.BackColor = [System.Drawing.Color]::White; $Button.ForeColor = $script:Theme.Text
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = $script:Theme.CardBorder
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(243,245,248)
    }
}

# Control.DoubleBuffered is protected, so it can only be set by reflection. Without it
# every container repaints directly to screen, which is what makes dragging the window
# edge feel laggy once the item list is owner-drawn.
function Set-DoubleBuffered { param($Control)
    try {
        $prop = [System.Windows.Forms.Control].GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        if ($prop) { $prop.SetValue($Control, $true, $null) }
    } catch { }
}

# Owner-drawing the item list means these are built for every cell on every repaint.
# At ~10 columns x N rows x each resize tick that is a lot of GDI churn, so they are
# created once here and reused (deliberately never disposed - they live for the app).
$script:Draw = @{}
function Initialize-DrawCache {
    if ($script:Draw.Ready) { return }
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $sf.FormatFlags   = [System.Drawing.StringFormatFlags]::NoWrap
    $sf.Trimming      = [System.Drawing.StringTrimming]::EllipsisCharacter
    $sfMid = New-Object System.Drawing.StringFormat
    $sfMid.Alignment     = [System.Drawing.StringAlignment]::Center
    $sfMid.LineAlignment = [System.Drawing.StringAlignment]::Center
    $script:Draw = @{
        Ready       = $true
        Fmt         = $sf
        FmtMid      = $sfMid
        TextBrush   = New-Object System.Drawing.SolidBrush($script:Theme.Text)
        MutedBrush  = New-Object System.Drawing.SolidBrush($script:Theme.TextMuted)
        PanelBrush  = New-Object System.Drawing.SolidBrush($script:Theme.Panel)
        BorderPen   = New-Object System.Drawing.Pen($script:Theme.CardBorder)
        HairlinePen = New-Object System.Drawing.Pen($script:Theme.RowHairline)
        SelBrush    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(226,238,251))
        WhiteBrush  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    }
}

# Fills a rounded rectangle - used for the status badges drawn inside the item list.
function Fill-RoundedRect {
    param($Graphics, $Rect, [int]$Radius, $Color)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius*2; $x=$Rect.X; $y=$Rect.Y; $w=$Rect.Width; $h=$Rect.Height
    if ($w -le $d -or $h -le $d) { $d = [Math]::Max(2,[Math]::Min($w,$h)-1) }
    $path.AddArc($x,$y,$d,$d,180,90); $path.AddArc($x+$w-$d,$y,$d,$d,270,90)
    $path.AddArc($x+$w-$d,$y+$h-$d,$d,$d,0,90); $path.AddArc($x,$y+$h-$d,$d,$d,90,90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $Graphics.FillPath($brush,$path); $brush.Dispose(); $path.Dispose()
}

# Badge colours, dot colour and row tint for each status.
function Get-StatusVisuals { param([string]$Status)
    switch ($Status) {
        "Up"       { @{ PillBg=[System.Drawing.Color]::FromArgb(225,245,238); PillFg=[System.Drawing.Color]::FromArgb(15,110,86);  Dot=$script:Theme.Green; RowTint=[System.Drawing.Color]::White } }
        "Down"     { @{ PillBg=[System.Drawing.Color]::FromArgb(252,235,235); PillFg=[System.Drawing.Color]::FromArgb(163,45,45);  Dot=$script:Theme.Red;   RowTint=[System.Drawing.Color]::FromArgb(255,250,250) } }
        "Warning"  { @{ PillBg=[System.Drawing.Color]::FromArgb(250,238,218); PillFg=[System.Drawing.Color]::FromArgb(133,79,11);  Dot=$script:Theme.Amber; RowTint=[System.Drawing.Color]::FromArgb(255,252,244) } }
        "Disabled" { @{ PillBg=[System.Drawing.Color]::FromArgb(241,239,232); PillFg=[System.Drawing.Color]::FromArgb(68,68,65);   Dot=[System.Drawing.Color]::FromArgb(180,178,169); RowTint=[System.Drawing.Color]::White } }
        default    { @{ PillBg=[System.Drawing.Color]::FromArgb(238,240,243); PillFg=[System.Drawing.Color]::FromArgb(90,96,104);  Dot=$script:Theme.Gray;  RowTint=[System.Drawing.Color]::White } }
    }
}

# One Up/Warning/Down/Disabled count card: white box, thin coloured left accent,
# small caption, large value. Returns the card and its value label.
function New-MetricCard {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Caption, $AccentColor)
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($X,$Y); $card.Size = New-Object System.Drawing.Size($W,$H)
    $card.BackColor = [System.Drawing.Color]::White
    $card.Add_Paint({
        param($sender,$e)
        $pen = New-Object System.Drawing.Pen($script:Theme.CardBorder)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width-1, $sender.Height-1)
        $pen.Dispose()
    })
    $strip = New-Object System.Windows.Forms.Panel; $strip.Dock="Left"; $strip.Width=3; $strip.BackColor=$AccentColor
    $cap = New-Object System.Windows.Forms.Label; $cap.Text=$Caption; $cap.ForeColor=$script:Theme.TextMuted; $cap.Font=$script:MicroFont
    $cap.Location=New-Object System.Drawing.Point(14,10); $cap.AutoSize=$true
    $val = New-Object System.Windows.Forms.Label; $val.Text="0"; $val.ForeColor=$script:Theme.Text; $val.Font=$script:MetricFont
    $val.Location=New-Object System.Drawing.Point(13,26); $val.AutoSize=$true
    $card.Controls.AddRange(@($strip,$cap,$val))
    return @{ Card=$card; ValueLabel=$val }
}

# Builds one settings section: a bold heading, a muted one-line description, and a
# bordered box to drop the controls into. Returns the box so the caller fills it.
function New-SettingsSection {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$BoxHeight, [string]$Title, [string]$Description)
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title; $lblTitle.Font = $script:BoldFont; $lblTitle.ForeColor = $script:Theme.Text
    $lblTitle.Location = New-Object System.Drawing.Point($X, $Y); $lblTitle.AutoSize = $true
    $descY = $Y + 18
    $boxY = $Y + 18
    if ($Description) {
        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Text = $Description; $lblDesc.Font = $script:BaseFont; $lblDesc.ForeColor = $script:Theme.TextMuted
        $lblDesc.Location = New-Object System.Drawing.Point($X, $descY); $lblDesc.AutoSize = $true
        $Parent.Controls.Add($lblDesc)
        $boxY = $Y + 38
    }
    $box = New-Object System.Windows.Forms.Panel
    $box.Location = New-Object System.Drawing.Point($X, $boxY)
    $box.Size = New-Object System.Drawing.Size($W, $BoxHeight)
    $box.BackColor = [System.Drawing.Color]::White
    $box.Add_Paint({
        param($sender,$e)
        $pen = New-Object System.Drawing.Pen($script:Theme.CardBorder)
        $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width-1, $sender.Height-1)
        $pen.Dispose()
    })
    $Parent.Controls.Add($lblTitle); $Parent.Controls.Add($box)
    return $box
}


function Show-ListPicker { param([string]$Title, [array]$Columns, [System.Collections.IEnumerable]$Rows)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = New-Object System.Drawing.Size(540, 480)
    $dlg.StartPosition = "CenterParent"; $dlg.Font = $script:BaseFont
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.MultiSelect = $false
    $lv.Location = New-Object System.Drawing.Point(12,12); $lv.Size = New-Object System.Drawing.Size(500,380)
    $lv.Anchor = "Top,Bottom,Left,Right"
    foreach ($c in $Columns) { [void]$lv.Columns.Add($c.Name, $c.Width) }
    foreach ($r in $Rows) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$r[0])
        for ($i=1; $i -lt $r.Count; $i++) { [void]$item.SubItems.Add([string]$r[$i]) }
        [void]$lv.Items.Add($item)
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Select"; $ok.Size = New-Object System.Drawing.Size(90,30)
    $ok.Location = New-Object System.Drawing.Point(330,402); $ok.Anchor="Bottom,Right"
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"; $cancel.Size = New-Object System.Drawing.Size(90,30)
    $cancel.Location = New-Object System.Drawing.Point(422,402); $cancel.Anchor="Bottom,Right"
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $lv.Add_DoubleClick({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close() })
    $dlg.Controls.AddRange(@($lv,$ok,$cancel)); $dlg.AcceptButton=$ok; $dlg.CancelButton=$cancel
    if (($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) -and $lv.SelectedItems.Count -gt 0) { return $lv.SelectedItems[0].Text }
    return $null
}

function Show-ServicePicker {
    $rows = @()
    try { Get-Service | Sort-Object DisplayName | ForEach-Object { $rows += ,@($_.Name, $_.DisplayName, "$($_.Status)") } } catch { }
    Show-ListPicker -Title "Select a Windows Service" -Columns @(@{Name="Name";Width=150},@{Name="Display Name";Width=230},@{Name="Status";Width=90}) -Rows $rows
}
function Show-ProcessPicker {
    $rows = @()
    try { Get-Process | Sort-Object Name | Group-Object Name | ForEach-Object { $rows += ,@($_.Name, "$($_.Count)") } } catch { }
    Show-ListPicker -Title "Select a Running Process" -Columns @(@{Name="Process Name";Width=260},@{Name="Instances";Width=100}) -Rows $rows
}

function Show-DrivePicker {
    $rows = @()
    try {
        Get-CimInstance Win32_LogicalDisk | Sort-Object DeviceID | ForEach-Object {
            $typeLabel = switch ([int]$_.DriveType) { 2{"Removable"} 3{"Fixed"} 4{"Network"} 5{"CD/DVD"} default{"Other"} }
            $label = if ($_.VolumeName) { $_.VolumeName } else { "(no label)" }
            $rows += ,@($_.DeviceID, $label, $typeLabel)
        }
    } catch { }
    Show-ListPicker -Title "Select a Drive" -Columns @(@{Name="Drive";Width=80},@{Name="Volume Label";Width=220},@{Name="Type";Width=100}) -Rows $rows
}

function Show-VMPicker {
    $rows = @()
    try {
        Get-VM -ErrorAction Stop | Sort-Object Name | ForEach-Object { $rows += ,@($_.Name, "$($_.State)") }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't list VMs. Make sure the Hyper-V role and Hyper-V PowerShell module are installed on this host, and that you're running as an administrator.`r`n`r`nYou can also just type the VM name.","Hyper-V not available","OK","Warning")|Out-Null
        return $null
    }
    if ($rows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("No VMs found on this host.","Hyper-V","OK","Information")|Out-Null; return $null }
    Show-ListPicker -Title "Select a Hyper-V VM" -Columns @(@{Name="VM Name";Width=300},@{Name="State";Width=100}) -Rows $rows
}

function Show-VMServicePicker { param([string]$VMName,$Cred)
    $rows = @()
    try {
        $svcs = Invoke-Command -VMName $VMName -Credential $Cred -ErrorAction Stop -ScriptBlock {
            Get-Service | Sort-Object DisplayName | Select-Object Name, DisplayName, Status
        }
        foreach ($s in $svcs) { $rows += ,@($s.Name, $s.DisplayName, "$($s.Status)") }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't reach $VMName over PowerShell Direct:`r`n$($_.Exception.Message)`r`n`r`nCheck the VM is running, the guest is Windows Server 2016+/Win10+, and the guest credentials are correct.","VM query failed","OK","Warning")|Out-Null
        return $null
    }
    Show-ListPicker -Title "Select a service inside $VMName" -Columns @(@{Name="Name";Width=150},@{Name="Display Name";Width=230},@{Name="Status";Width=90}) -Rows $rows
}

# ==================================================================
#  Add / Edit item dialog
# ==================================================================
function Show-ItemEditor { param($Existing)
    $isEdit = $null -ne $Existing
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($isEdit) { "Edit Monitored Item" } else { "Add Monitored Item" }
    $dlg.Size = New-Object System.Drawing.Size(580, 700)   # grows to 850 when Advanced is expanded
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.Font = $script:BaseFont

    $grpBasics = New-Object System.Windows.Forms.GroupBox
    $grpBasics.Text = "  Basics  "; $grpBasics.Location = New-Object System.Drawing.Point(15,10)
    $grpBasics.Size = New-Object System.Drawing.Size(540,150)

    $lblName = New-Object System.Windows.Forms.Label; $lblName.Text="Friendly name:"; $lblName.Location=New-Object System.Drawing.Point(15,30); $lblName.AutoSize=$true
    $txtName = New-Object System.Windows.Forms.TextBox; $txtName.Location=New-Object System.Drawing.Point(160,27); $txtName.Size=New-Object System.Drawing.Size(360,24)

    $lblType = New-Object System.Windows.Forms.Label; $lblType.Text="Monitor type:"; $lblType.Location=New-Object System.Drawing.Point(15,65); $lblType.AutoSize=$true
    $cmbType = New-Object System.Windows.Forms.ComboBox; $cmbType.DropDownStyle="DropDownList"; $cmbType.Location=New-Object System.Drawing.Point(160,62); $cmbType.Size=New-Object System.Drawing.Size(220,24)
    # VM Service/Process (PowerShell Direct into a Hyper-V guest) are gated behind the
    # "Experimental Settings" toggle on the General tab - they're more complex than the
    # other checks and not everyone needs them. If you're editing an item that already
    # uses one of these types, it stays available in the list regardless of the toggle,
    # so an existing item never becomes uneditable just because the setting changed later.
    $typeList = @("Windows Service","Process","TCP Port","HTTP(S) URL","TLS Certificate")
    $editingHiddenVMType = $isEdit -and ($Existing.Type -eq "VMService" -or $Existing.Type -eq "VMProcess")
    if ($script:General.ExperimentalFeaturesEnabled -or $editingHiddenVMType) {
        $typeList += @("VM Service (Hyper-V)","VM Process (Hyper-V)")
    }
    $typeList += @("VM State (Hyper-V)","Backup Drive Rotation")
    [void]$cmbType.Items.AddRange($typeList)

    $lblInterval = New-Object System.Windows.Forms.Label; $lblInterval.Text="Check every (seconds):"; $lblInterval.Location=New-Object System.Drawing.Point(15,102); $lblInterval.AutoSize=$true
    $numInterval = New-Object System.Windows.Forms.NumericUpDown; $numInterval.Minimum=5; $numInterval.Maximum=86400; $numInterval.Value=60; $numInterval.Location=New-Object System.Drawing.Point(160,99); $numInterval.Size=New-Object System.Drawing.Size(90,24)
    $chkEnabled = New-Object System.Windows.Forms.CheckBox; $chkEnabled.Text="Enabled"; $chkEnabled.Location=New-Object System.Drawing.Point(300,101); $chkEnabled.AutoSize=$true; $chkEnabled.Checked=$true

    $grpBasics.Controls.AddRange(@($lblName,$txtName,$lblType,$cmbType,$lblInterval,$numInterval,$chkEnabled))

    $grpTarget = New-Object System.Windows.Forms.GroupBox
    $grpTarget.Text = "  Target  "; $grpTarget.Location = New-Object System.Drawing.Point(15,170)
    $grpTarget.Size = New-Object System.Drawing.Size(540,255)

    $pnlService = New-Object System.Windows.Forms.Panel; $pnlService.Location=New-Object System.Drawing.Point(10,22); $pnlService.Size=New-Object System.Drawing.Size(520,150)
    $lblSvc = New-Object System.Windows.Forms.Label; $lblSvc.Text="Service name:"; $lblSvc.Location=New-Object System.Drawing.Point(5,8); $lblSvc.AutoSize=$true
    $txtSvc = New-Object System.Windows.Forms.TextBox; $txtSvc.Location=New-Object System.Drawing.Point(150,5); $txtSvc.Size=New-Object System.Drawing.Size(250,24)
    $btnSvc = New-Object System.Windows.Forms.Button; $btnSvc.Text="Browse..."; $btnSvc.Location=New-Object System.Drawing.Point(410,4); $btnSvc.Size=New-Object System.Drawing.Size(95,26)
    $btnSvc.Add_Click({ $s = Show-ServicePicker; if ($s) { $txtSvc.Text = $s } })
    $pnlService.Controls.AddRange(@($lblSvc,$txtSvc,$btnSvc))

    $pnlProcess = New-Object System.Windows.Forms.Panel; $pnlProcess.Location=New-Object System.Drawing.Point(10,22); $pnlProcess.Size=New-Object System.Drawing.Size(520,225)
    $lblPn = New-Object System.Windows.Forms.Label; $lblPn.Text="Process name:"; $lblPn.Location=New-Object System.Drawing.Point(5,8); $lblPn.AutoSize=$true
    $txtPn = New-Object System.Windows.Forms.TextBox; $txtPn.Location=New-Object System.Drawing.Point(150,5); $txtPn.Size=New-Object System.Drawing.Size(250,24)
    $btnPn = New-Object System.Windows.Forms.Button; $btnPn.Text="Browse..."; $btnPn.Location=New-Object System.Drawing.Point(410,4); $btnPn.Size=New-Object System.Drawing.Size(95,26)
    $btnPn.Add_Click({ $s = Show-ProcessPicker; if ($s) { $txtPn.Text = $s } })
    $lblExe = New-Object System.Windows.Forms.Label; $lblExe.Text="Exe path (restart):"; $lblExe.Location=New-Object System.Drawing.Point(5,42); $lblExe.AutoSize=$true
    $txtExe = New-Object System.Windows.Forms.TextBox; $txtExe.Location=New-Object System.Drawing.Point(150,39); $txtExe.Size=New-Object System.Drawing.Size(250,24)
    $btnExe = New-Object System.Windows.Forms.Button; $btnExe.Text="Browse..."; $btnExe.Location=New-Object System.Drawing.Point(410,38); $btnExe.Size=New-Object System.Drawing.Size(95,26)
    $btnExe.Add_Click({ $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter="Executables (*.exe)|*.exe|All files (*.*)|*.*"; if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtExe.Text = $ofd.FileName } })
    $lblArgs = New-Object System.Windows.Forms.Label; $lblArgs.Text="Arguments:"; $lblArgs.Location=New-Object System.Drawing.Point(5,76); $lblArgs.AutoSize=$true
    $txtArgs = New-Object System.Windows.Forms.TextBox; $txtArgs.Location=New-Object System.Drawing.Point(150,73); $txtArgs.Size=New-Object System.Drawing.Size(355,24)
    $lblWd = New-Object System.Windows.Forms.Label; $lblWd.Text="Working dir:"; $lblWd.Location=New-Object System.Drawing.Point(5,110); $lblWd.AutoSize=$true
    $txtWd = New-Object System.Windows.Forms.TextBox; $txtWd.Location=New-Object System.Drawing.Point(150,107); $txtWd.Size=New-Object System.Drawing.Size(355,24)
    $lblRunAsUser = New-Object System.Windows.Forms.Label; $lblRunAsUser.Text="Run as user (optional):"; $lblRunAsUser.Location=New-Object System.Drawing.Point(5,144); $lblRunAsUser.AutoSize=$true
    $txtRunAsUser = New-Object System.Windows.Forms.TextBox; $txtRunAsUser.Location=New-Object System.Drawing.Point(150,141); $txtRunAsUser.Size=New-Object System.Drawing.Size(200,24)
    $lblRunAsPass = New-Object System.Windows.Forms.Label; $lblRunAsPass.Text="Password:"; $lblRunAsPass.Location=New-Object System.Drawing.Point(360,144); $lblRunAsPass.AutoSize=$true
    $txtRunAsPass = New-Object System.Windows.Forms.TextBox; $txtRunAsPass.Location=New-Object System.Drawing.Point(425,141); $txtRunAsPass.Size=New-Object System.Drawing.Size(80,24); $txtRunAsPass.UseSystemPasswordChar=$true
    $txtRunAsPass.Add_TextChanged({ param($s,$e) $s.Tag=$null })
    $lblRunAsHint = New-Object System.Windows.Forms.Label
    $lblRunAsHint.Text = "Leave blank to run as whatever account Watchdog itself runs as (e.g. SYSTEM via the`r`nStartup Task). Set this to fix apps whose login is tied to a specific account (e.g. Plex)."
    $lblRunAsHint.ForeColor = $script:Theme.Gray; $lblRunAsHint.Location = New-Object System.Drawing.Point(5,172); $lblRunAsHint.AutoSize=$true
    $pnlProcess.Controls.AddRange(@($lblPn,$txtPn,$btnPn,$lblExe,$txtExe,$btnExe,$lblArgs,$txtArgs,$lblWd,$txtWd,$lblRunAsUser,$txtRunAsUser,$lblRunAsPass,$txtRunAsPass,$lblRunAsHint))

    $pnlPort = New-Object System.Windows.Forms.Panel; $pnlPort.Location=New-Object System.Drawing.Point(10,22); $pnlPort.Size=New-Object System.Drawing.Size(520,120)
    $lblH = New-Object System.Windows.Forms.Label; $lblH.Text="Host / IP:"; $lblH.Location=New-Object System.Drawing.Point(5,8); $lblH.AutoSize=$true
    $txtH = New-Object System.Windows.Forms.TextBox; $txtH.Location=New-Object System.Drawing.Point(150,5); $txtH.Size=New-Object System.Drawing.Size(250,24); $txtH.Text="localhost"
    $lblP = New-Object System.Windows.Forms.Label; $lblP.Text="Port:"; $lblP.Location=New-Object System.Drawing.Point(5,44); $lblP.AutoSize=$true
    $numP = New-Object System.Windows.Forms.NumericUpDown; $numP.Minimum=1; $numP.Maximum=65535; $numP.Value=443; $numP.Location=New-Object System.Drawing.Point(150,41); $numP.Size=New-Object System.Drawing.Size(90,24)
    $pnlPort.Controls.AddRange(@($lblH,$txtH,$lblP,$numP))

    $pnlUrl = New-Object System.Windows.Forms.Panel; $pnlUrl.Location=New-Object System.Drawing.Point(10,22); $pnlUrl.Size=New-Object System.Drawing.Size(520,140)
    $lblU = New-Object System.Windows.Forms.Label; $lblU.Text="URL:"; $lblU.Location=New-Object System.Drawing.Point(5,8); $lblU.AutoSize=$true
    $txtU = New-Object System.Windows.Forms.TextBox; $txtU.Location=New-Object System.Drawing.Point(150,5); $txtU.Size=New-Object System.Drawing.Size(355,24); $txtU.Text="https://"
    $lblEc = New-Object System.Windows.Forms.Label; $lblEc.Text="Expected HTTP status:"; $lblEc.Location=New-Object System.Drawing.Point(5,44); $lblEc.AutoSize=$true
    $numEc = New-Object System.Windows.Forms.NumericUpDown; $numEc.Minimum=100; $numEc.Maximum=599; $numEc.Value=200; $numEc.Location=New-Object System.Drawing.Point(180,41); $numEc.Size=New-Object System.Drawing.Size(80,24)
    $lblToL = New-Object System.Windows.Forms.Label; $lblToL.Text="Timeout (sec):"; $lblToL.Location=New-Object System.Drawing.Point(290,44); $lblToL.AutoSize=$true
    $numTo = New-Object System.Windows.Forms.NumericUpDown; $numTo.Minimum=1; $numTo.Maximum=120; $numTo.Value=10; $numTo.Location=New-Object System.Drawing.Point(400,41); $numTo.Size=New-Object System.Drawing.Size(70,24)
    $pnlUrl.Controls.AddRange(@($lblU,$txtU,$lblEc,$numEc,$lblToL,$numTo))

    $pnlCert = New-Object System.Windows.Forms.Panel; $pnlCert.Location=New-Object System.Drawing.Point(10,22); $pnlCert.Size=New-Object System.Drawing.Size(520,140)
    $lblCu = New-Object System.Windows.Forms.Label; $lblCu.Text="URL or hostname:"; $lblCu.Location=New-Object System.Drawing.Point(5,8); $lblCu.AutoSize=$true
    $txtCu = New-Object System.Windows.Forms.TextBox; $txtCu.Location=New-Object System.Drawing.Point(150,5); $txtCu.Size=New-Object System.Drawing.Size(355,24); $txtCu.Text="https://"
    $lblCp = New-Object System.Windows.Forms.Label; $lblCp.Text="Port:"; $lblCp.Location=New-Object System.Drawing.Point(5,44); $lblCp.AutoSize=$true
    $numCp = New-Object System.Windows.Forms.NumericUpDown; $numCp.Minimum=1; $numCp.Maximum=65535; $numCp.Value=443; $numCp.Location=New-Object System.Drawing.Point(150,41); $numCp.Size=New-Object System.Drawing.Size(90,24)
    $lblCw = New-Object System.Windows.Forms.Label; $lblCw.Text="Warn this many days before expiry:"; $lblCw.Location=New-Object System.Drawing.Point(5,80); $lblCw.AutoSize=$true
    $numCw = New-Object System.Windows.Forms.NumericUpDown; $numCw.Minimum=1; $numCw.Maximum=730; $numCw.Value=60; $numCw.Location=New-Object System.Drawing.Point(240,77); $numCw.Size=New-Object System.Drawing.Size(90,24)
    $pnlCert.Controls.AddRange(@($lblCu,$txtCu,$lblCp,$numCp,$lblCw,$numCw))

    $pnlBackupDrive = New-Object System.Windows.Forms.Panel; $pnlBackupDrive.Location=New-Object System.Drawing.Point(10,22); $pnlBackupDrive.Size=New-Object System.Drawing.Size(520,175)
    $lblBd = New-Object System.Windows.Forms.Label; $lblBd.Text="Drive letter:"; $lblBd.Location=New-Object System.Drawing.Point(5,8); $lblBd.AutoSize=$true
    $txtBd = New-Object System.Windows.Forms.TextBox; $txtBd.Location=New-Object System.Drawing.Point(150,5); $txtBd.Size=New-Object System.Drawing.Size(80,24); $txtBd.Text="E:"
    $btnBd = New-Object System.Windows.Forms.Button; $btnBd.Text="Browse..."; $btnBd.Location=New-Object System.Drawing.Point(240,4); $btnBd.Size=New-Object System.Drawing.Size(95,26)
    $btnBd.Add_Click({ $s = Show-DrivePicker; if ($s) { $txtBd.Text = $s } })
    $lblBdWarn = New-Object System.Windows.Forms.Label; $lblBdWarn.Text="Expected rotation every (days):"; $lblBdWarn.Location=New-Object System.Drawing.Point(5,44); $lblBdWarn.AutoSize=$true
    $numBdWarn = New-Object System.Windows.Forms.NumericUpDown; $numBdWarn.Minimum=1; $numBdWarn.Maximum=365; $numBdWarn.Value=7; $numBdWarn.Location=New-Object System.Drawing.Point(240,41); $numBdWarn.Size=New-Object System.Drawing.Size(80,24)
    $lblBdAlert = New-Object System.Windows.Forms.Label; $lblBdAlert.Text="Treat as seriously overdue after (days):"; $lblBdAlert.Location=New-Object System.Drawing.Point(5,80); $lblBdAlert.AutoSize=$true
    $numBdAlert = New-Object System.Windows.Forms.NumericUpDown; $numBdAlert.Minimum=1; $numBdAlert.Maximum=365; $numBdAlert.Value=10; $numBdAlert.Location=New-Object System.Drawing.Point(240,77); $numBdAlert.Size=New-Object System.Drawing.Size(80,24)
    $lblBdHint = New-Object System.Windows.Forms.Label
    $lblBdHint.Text = "Works best if every rotation drive is set to mount at this SAME letter (Disk`r`nManagement > change drive letter). Watchdog detects a swap whenever the drive`r`ngoes offline and a drive reconnects here - resetting the countdown automatically."
    $lblBdHint.ForeColor = $script:Theme.Gray; $lblBdHint.Location = New-Object System.Drawing.Point(5,112); $lblBdHint.AutoSize=$true
    $pnlBackupDrive.Controls.AddRange(@($lblBd,$txtBd,$btnBd,$lblBdWarn,$numBdWarn,$lblBdAlert,$numBdAlert,$lblBdHint))

    # VM (Hyper-V PowerShell Direct) panel - used for both VM Service and VM Process
    $pnlVM = New-Object System.Windows.Forms.Panel; $pnlVM.Location=New-Object System.Drawing.Point(10,22); $pnlVM.Size=New-Object System.Drawing.Size(520,225)
    $lblVMn = New-Object System.Windows.Forms.Label; $lblVMn.Text="VM name:"; $lblVMn.Location=New-Object System.Drawing.Point(5,8); $lblVMn.AutoSize=$true
    $txtVMn = New-Object System.Windows.Forms.TextBox; $txtVMn.Location=New-Object System.Drawing.Point(150,5); $txtVMn.Size=New-Object System.Drawing.Size(250,24)
    $btnVMn = New-Object System.Windows.Forms.Button; $btnVMn.Text="Browse..."; $btnVMn.Location=New-Object System.Drawing.Point(410,4); $btnVMn.Size=New-Object System.Drawing.Size(95,26)
    $btnVMn.Add_Click({ $s = Show-VMPicker; if ($s) { $txtVMn.Text = $s } })
    $lblVMu = New-Object System.Windows.Forms.Label; $lblVMu.Text="Guest username:"; $lblVMu.Location=New-Object System.Drawing.Point(5,42); $lblVMu.AutoSize=$true
    $txtVMu = New-Object System.Windows.Forms.TextBox; $txtVMu.Location=New-Object System.Drawing.Point(150,39); $txtVMu.Size=New-Object System.Drawing.Size(250,24)
    $lblVMp = New-Object System.Windows.Forms.Label; $lblVMp.Text="Guest password:"; $lblVMp.Location=New-Object System.Drawing.Point(5,76); $lblVMp.AutoSize=$true
    $txtVMp = New-Object System.Windows.Forms.TextBox; $txtVMp.Location=New-Object System.Drawing.Point(150,73); $txtVMp.Size=New-Object System.Drawing.Size(250,24); $txtVMp.UseSystemPasswordChar=$true
    $lblVMt = New-Object System.Windows.Forms.Label; $lblVMt.Text="Service/Process name:"; $lblVMt.Location=New-Object System.Drawing.Point(5,110); $lblVMt.AutoSize=$true
    $txtVMt = New-Object System.Windows.Forms.TextBox; $txtVMt.Location=New-Object System.Drawing.Point(150,107); $txtVMt.Size=New-Object System.Drawing.Size(250,24)
    $btnVMt = New-Object System.Windows.Forms.Button; $btnVMt.Text="Browse..."; $btnVMt.Location=New-Object System.Drawing.Point(410,106); $btnVMt.Size=New-Object System.Drawing.Size(95,26)
    $btnVMt.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtVMn.Text) -or [string]::IsNullOrWhiteSpace($txtVMu.Text) -or [string]::IsNullOrWhiteSpace($txtVMp.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Enter the VM name, guest username and guest password first.","Need details","OK","Information")|Out-Null; return
        }
        $sec = ConvertTo-SecureString $txtVMp.Text -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential($txtVMu.Text, $sec)
        $sel = Show-VMServicePicker -VMName $txtVMn.Text -Cred $cred
        if ($sel) { $txtVMt.Text = $sel }
    })
    $lblVMe = New-Object System.Windows.Forms.Label; $lblVMe.Text="Guest exe path (restart):"; $lblVMe.Location=New-Object System.Drawing.Point(5,144); $lblVMe.AutoSize=$true
    $txtVMe = New-Object System.Windows.Forms.TextBox; $txtVMe.Location=New-Object System.Drawing.Point(150,141); $txtVMe.Size=New-Object System.Drawing.Size(355,24)
    $lblVMa = New-Object System.Windows.Forms.Label; $lblVMa.Text="Guest arguments:"; $lblVMa.Location=New-Object System.Drawing.Point(5,178); $lblVMa.AutoSize=$true
    $txtVMa = New-Object System.Windows.Forms.TextBox; $txtVMa.Location=New-Object System.Drawing.Point(150,175); $txtVMa.Size=New-Object System.Drawing.Size(355,24)
    $lblVMhint = New-Object System.Windows.Forms.Label; $lblVMhint.Text="Uses Hyper-V PowerShell Direct (VMBus) - no network. Guest must be running."; $lblVMhint.ForeColor=$script:Theme.Gray; $lblVMhint.Location=New-Object System.Drawing.Point(5,203); $lblVMhint.AutoSize=$true
    $pnlVM.Controls.AddRange(@($lblVMn,$txtVMn,$btnVMn,$lblVMu,$txtVMu,$lblVMp,$txtVMp,$lblVMt,$txtVMt,$btnVMt,$lblVMe,$txtVMe,$lblVMa,$txtVMa,$lblVMhint))

    $pnlVMState = New-Object System.Windows.Forms.Panel; $pnlVMState.Location=New-Object System.Drawing.Point(10,22); $pnlVMState.Size=New-Object System.Drawing.Size(520,90)
    $lblVSn = New-Object System.Windows.Forms.Label; $lblVSn.Text="VM name:"; $lblVSn.Location=New-Object System.Drawing.Point(5,8); $lblVSn.AutoSize=$true
    $txtVSn = New-Object System.Windows.Forms.TextBox; $txtVSn.Location=New-Object System.Drawing.Point(150,5); $txtVSn.Size=New-Object System.Drawing.Size(250,24)
    $btnVSn = New-Object System.Windows.Forms.Button; $btnVSn.Text="Browse..."; $btnVSn.Location=New-Object System.Drawing.Point(410,4); $btnVSn.Size=New-Object System.Drawing.Size(95,26)
    $btnVSn.Add_Click({ $s = Show-VMPicker; if ($s) { $txtVSn.Text = $s } })
    $lblVShint = New-Object System.Windows.Forms.Label
    $lblVShint.Text = "Checks whether the VM itself is powered on (host-level - no guest credentials`r`nneeded). ""Auto-restart"" below starts the VM if it's found off."
    $lblVShint.ForeColor = $script:Theme.Gray; $lblVShint.Location = New-Object System.Drawing.Point(5,42); $lblVShint.AutoSize=$true
    $pnlVMState.Controls.AddRange(@($lblVSn,$txtVSn,$btnVSn,$lblVShint))

    $grpTarget.Controls.AddRange(@($pnlService,$pnlProcess,$pnlPort,$pnlUrl,$pnlCert,$pnlVM,$pnlBackupDrive,$pnlVMState))

    $grpAlert = New-Object System.Windows.Forms.GroupBox
    $grpAlert.Text = "  When it goes down  "; $grpAlert.Location = New-Object System.Drawing.Point(15,435)
    $grpAlert.Size = New-Object System.Drawing.Size(540,122)

    $lblFt = New-Object System.Windows.Forms.Label; $lblFt.Text="Email me after"; $lblFt.Location=New-Object System.Drawing.Point(15,26); $lblFt.AutoSize=$true
    $numFt = New-Object System.Windows.Forms.NumericUpDown; $numFt.Minimum=1; $numFt.Maximum=100; $numFt.Value=3; $numFt.Location=New-Object System.Drawing.Point(330,23); $numFt.Size=New-Object System.Drawing.Size(70,24)
    $lblFtU = New-Object System.Windows.Forms.Label; $lblFtU.Text="failed checks"; $lblFtU.ForeColor=$script:Theme.TextMuted; $lblFtU.Location=New-Object System.Drawing.Point(408,26); $lblFtU.AutoSize=$true

    $chkAuto = New-Object System.Windows.Forms.CheckBox; $chkAuto.Text="Try to restart it automatically"; $chkAuto.Location=New-Object System.Drawing.Point(15,58); $chkAuto.AutoSize=$true
    $chkRec = New-Object System.Windows.Forms.CheckBox; $chkRec.Text="Email me again when it recovers"; $chkRec.Location=New-Object System.Drawing.Point(15,88); $chkRec.AutoSize=$true; $chkRec.Checked=$true

    $grpAlert.Controls.AddRange(@($lblFt,$numFt,$lblFtU,$chkAuto,$chkRec))

    # ---- Collapsible advanced block -------------------------------------
    # Rarely-touched settings start hidden; the dialog grows/shrinks around them so the
    # common case (add a service, accept the defaults) stays a short form.
    $btnAdv = New-Object System.Windows.Forms.Button
    $btnAdv.Text = "  $([char]0x25B8)  Advanced - repeat interval, restart attempts, run as a different user"
    $btnAdv.Location = New-Object System.Drawing.Point(15,566); $btnAdv.Size = New-Object System.Drawing.Size(540,30)
    $btnAdv.TextAlign = "MiddleLeft"; $btnAdv.FlatStyle = "Flat"; $btnAdv.BackColor = [System.Drawing.Color]::White
    $btnAdv.FlatAppearance.BorderColor = $script:Theme.CardBorder

    $pnlAdv = New-Object System.Windows.Forms.Panel
    $pnlAdv.Location = New-Object System.Drawing.Point(15,600); $pnlAdv.Size = New-Object System.Drawing.Size(540,150)
    $pnlAdv.Visible = $false

    $lblRa = New-Object System.Windows.Forms.Label; $lblRa.Text="Max restart attempts"; $lblRa.Location=New-Object System.Drawing.Point(6,8); $lblRa.AutoSize=$true
    $numRa = New-Object System.Windows.Forms.NumericUpDown; $numRa.Minimum=0; $numRa.Maximum=50; $numRa.Value=3; $numRa.Location=New-Object System.Drawing.Point(315,5); $numRa.Size=New-Object System.Drawing.Size(70,24)

    $lblRn = New-Object System.Windows.Forms.Label; $lblRn.Text="Re-notify while still down"; $lblRn.Location=New-Object System.Drawing.Point(6,40); $lblRn.AutoSize=$true
    $numRn = New-Object System.Windows.Forms.NumericUpDown; $numRn.Minimum=0; $numRn.Maximum=10080; $numRn.Value=0; $numRn.Location=New-Object System.Drawing.Point(315,37); $numRn.Size=New-Object System.Drawing.Size(70,24)
    $lblRnU = New-Object System.Windows.Forms.Label; $lblRnU.Text="minutes  (0 = tell me once)"; $lblRnU.ForeColor=$script:Theme.TextMuted; $lblRnU.Location=New-Object System.Drawing.Point(393,40); $lblRnU.AutoSize=$true

    $lblAutoWarn = New-Object System.Windows.Forms.Label
    $lblAutoWarn.Text = "If the startup task runs as SYSTEM, an auto-restarted process runs as SYSTEM too - a`r`nseparate Windows profile. Apps whose login is tied to your own account (e.g. Plex) may`r`nshow as unauthorised. Set 'Run as user' under Target above to fix it for just this item."
    $lblAutoWarn.ForeColor = $script:Theme.TextMuted
    $lblAutoWarn.Location = New-Object System.Drawing.Point(6,76); $lblAutoWarn.AutoSize=$true

    $pnlAdv.Controls.AddRange(@($lblRa,$numRa,$lblRn,$numRn,$lblRnU,$lblAutoWarn))

    # Held in a script-scoped bag so the toggle handler never depends on locals.
    $script:ItemDlg = @{ Dlg=$dlg; PnlAdv=$pnlAdv; BtnAdv=$btnAdv; BtnOk=$null; BtnCancel=$null }
    $btnAdv.Add_Click({
        $open = -not $script:ItemDlg.PnlAdv.Visible
        $script:ItemDlg.PnlAdv.Visible = $open
        $arrow = if ($open) { [char]0x25BE } else { [char]0x25B8 }
        $script:ItemDlg.BtnAdv.Text = "  $arrow  Advanced - repeat interval, restart attempts, run as a different user"
        $btnY = if ($open) { 762 } else { 610 }
        $script:ItemDlg.BtnOk.Top = $btnY
        $script:ItemDlg.BtnCancel.Top = $btnY
        $script:ItemDlg.BtnTest.Top = $btnY
        $script:ItemDlg.Dlg.Height = if ($open) { 850 } else { 700 }
    })

    $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = if ($isEdit) { "Save Changes" } else { "Add Item" }
    $btnOk.Location=New-Object System.Drawing.Point(320,610); $btnOk.Size=New-Object System.Drawing.Size(130,34)
    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text="Cancel"; $btnCancel.Location=New-Object System.Drawing.Point(460,610); $btnCancel.Size=New-Object System.Drawing.Size(95,34)
    $btnTestCheck = New-Object System.Windows.Forms.Button; $btnTestCheck.Text="Test this check"; $btnTestCheck.Location=New-Object System.Drawing.Point(15,610); $btnTestCheck.Size=New-Object System.Drawing.Size(130,34)
    $script:ItemDlg.BtnOk = $btnOk; $script:ItemDlg.BtnCancel = $btnCancel; $script:ItemDlg.BtnTest = $btnTestCheck

    # Runs the check once against whatever is currently typed in, without saving. Catches
    # a mistyped service name or drive letter immediately instead of at the first
    # scheduled check. Uses the same Invoke-SingleCheck the monitoring loop uses.
    $btnTestCheck.Add_Click({
        $typeCode = switch ($cmbType.SelectedItem) { "Windows Service"{"Service"} "Process"{"Process"} "TCP Port"{"Port"} "HTTP(S) URL"{"Url"} "TLS Certificate"{"Cert"} "VM Service (Hyper-V)"{"VMService"} "VM Process (Hyper-V)"{"VMProcess"} "VM State (Hyper-V)"{"VMState"} "Backup Drive Rotation"{"BackupDrive"} }
        $target = switch ($typeCode) { "Service"{$txtSvc.Text.Trim()} "Process"{$txtPn.Text.Trim()} "Port"{$txtH.Text.Trim()} "Url"{$txtU.Text.Trim()} "Cert"{$txtCu.Text.Trim()} "VMService"{$txtVMt.Text.Trim()} "VMProcess"{$txtVMt.Text.Trim()} "VMState"{$txtVSn.Text.Trim()} "BackupDrive"{$txtBd.Text.Trim()} }
        if ([string]::IsNullOrWhiteSpace($target)) {
            [System.Windows.Forms.MessageBox]::Show("Fill in the target first, then test.","Nothing to test","OK","Information")|Out-Null; return
        }
        $encVMpwTest = if ($isEdit) { $Existing.EncryptedVMPassword } else { "" }
        if (($typeCode -eq "VMService" -or $typeCode -eq "VMProcess") -and $txtVMp.Tag -ne "unchanged") { $encVMpwTest = Protect-PlainPassword $txtVMp.Text }
        $tempItem = Normalize-Item ([PSCustomObject]@{
            Id=[guid]::NewGuid().ToString(); Name="test"; Type=$typeCode; Target=$target
            HostName=$txtH.Text.Trim(); Port=$(if ($typeCode -eq "Cert") { [int]$numCp.Value } else { [int]$numP.Value })
            Url=$txtU.Text.Trim(); ExpectedStatusCode=[int]$numEc.Value; TimeoutSeconds=[int]$numTo.Value
            CertWarnDays=[int]$numCw.Value
            VMName=$txtVMn.Text.Trim(); VMUsername=$txtVMu.Text.Trim(); EncryptedVMPassword=$encVMpwTest
            WarnAfterDays=[int]$numBdWarn.Value; AlertAfterDays=[int]$numBdAlert.Value
        })
        # Blank state - a one-off test has no previous check to compare against.
        $tempState = @{ LastRotationTime=$null; DriveWasPresent=$null; LastDriveSerial="" }
        $script:ItemDlg.BtnTest.Enabled = $false
        $script:ItemDlg.BtnTest.Text = "Testing..."
        try {
            $res = Invoke-SingleCheck -Item $tempItem -State $tempState
            $icon = switch ($res.Status) { "Up" { "Information" } "Warning" { "Warning" } default { "Error" } }
            $head = switch ($res.Status) { "Up" { "Looks good" } "Warning" { "Reachable, with a warning" } default { "That didn't work" } }
            [System.Windows.Forms.MessageBox]::Show("$($res.Detail)", $head, "OK", $icon) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show("$($_.Exception.Message)", "Test failed", "OK", "Error") | Out-Null
        } finally {
            $script:ItemDlg.BtnTest.Enabled = $true
            $script:ItemDlg.BtnTest.Text = "Test this check"
        }
    })
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.Controls.AddRange(@($grpBasics,$grpTarget,$grpAlert,$btnAdv,$pnlAdv,$btnTestCheck,$btnOk,$btnCancel)); $dlg.CancelButton=$btnCancel; $dlg.AcceptButton=$btnOk

    $updatePanels = {
        $pnlService.Visible=$false; $pnlProcess.Visible=$false; $pnlPort.Visible=$false; $pnlUrl.Visible=$false; $pnlCert.Visible=$false; $pnlVM.Visible=$false; $pnlBackupDrive.Visible=$false; $pnlVMState.Visible=$false
        switch ($cmbType.SelectedItem) {
            "Windows Service"       { $pnlService.Visible=$true }
            "Process"               { $pnlProcess.Visible=$true }
            "TCP Port"              { $pnlPort.Visible=$true }
            "HTTP(S) URL"           { $pnlUrl.Visible=$true }
            "TLS Certificate"       { $pnlCert.Visible=$true }
            "VM Service (Hyper-V)"  { $pnlVM.Visible=$true }
            "VM Process (Hyper-V)"  { $pnlVM.Visible=$true }
            "VM State (Hyper-V)"    { $pnlVMState.Visible=$true }
            "Backup Drive Rotation" { $pnlBackupDrive.Visible=$true }
        }
        # In the shared VM panel, guest exe/args are only relevant for VM Process restart
        $isVMProc = ($cmbType.SelectedItem -eq "VM Process (Hyper-V)")
        $lblVMe.Visible=$isVMProc; $txtVMe.Visible=$isVMProc; $lblVMa.Visible=$isVMProc; $txtVMa.Visible=$isVMProc
        if ($cmbType.SelectedItem -eq "VM Service (Hyper-V)" -or $cmbType.SelectedItem -eq "VM Process (Hyper-V)") {
            $lblVMt.Text = if ($isVMProc) { "Process name:" } else { "Service name:" }
        }
        $canRestart = ($cmbType.SelectedItem -in @("Windows Service","Process","VM Service (Hyper-V)","VM Process (Hyper-V)","VM State (Hyper-V)"))
        $chkAuto.Enabled=$canRestart; $numRa.Enabled=$canRestart
        if (-not $canRestart) { $chkAuto.Checked=$false }

        # Every monitor type defaults to "notify once" (0 = don't repeat) - re-notifying
        # every few minutes for a routine outage would be unwanted noise for most setups.
        # A cert defaults to a weekly nudge (it can sit in its warning window for weeks);
        # a backup drive rotation defaults to a daily nudge (more urgent - someone needs
        # to physically act on it). Only auto-adjust brand new items still on the
        # untouched default, so editing an existing item never silently overwrites a value
        # someone already chose.
        if ($cmbType.SelectedItem -eq "TLS Certificate") {
            $lblRn.Text = "Re-notify while still expiring soon"
            if (-not $isEdit -and ([int]$numRn.Value -eq 0 -or [int]$numRn.Value -eq 1440)) { $numRn.Value = 10080 }
        } elseif ($cmbType.SelectedItem -eq "Backup Drive Rotation") {
            $lblRn.Text = "Re-notify while still overdue"
            if (-not $isEdit -and ([int]$numRn.Value -eq 0 -or [int]$numRn.Value -eq 10080)) { $numRn.Value = 1440 }
        } else {
            $lblRn.Text = "Re-notify while still down"
            if (-not $isEdit -and ([int]$numRn.Value -eq 10080 -or [int]$numRn.Value -eq 1440)) { $numRn.Value = 0 }
        }

        # Check interval: local Service/Process/Port checks are essentially free (a
        # sub-millisecond local API call), so they default fast. A TLS check does a real
        # handshake against the target and a cert's expiry only ever changes once, months
        # away - checking that every 60 seconds is pure waste, so it defaults to once a
        # day. Hyper-V VM checks open a real PowerShell Direct session each time, so they
        # get a more conservative default too. A backup drive presence check is cheap but
        # doesn't need to be constant either. Only auto-adjust while the field still holds
        # one of these recognized defaults, and never on an existing edited item.
        $knownIntervalDefaults = @(30, 60, 86400, 120, 300)
        if (-not $isEdit -and [int]$numInterval.Value -in $knownIntervalDefaults) {
            $numInterval.Value = switch ($cmbType.SelectedItem) {
                "Windows Service"       { 30 }
                "Process"               { 30 }
                "TCP Port"              { 60 }
                "HTTP(S) URL"           { 60 }
                "TLS Certificate"       { 86400 }
                "VM Service (Hyper-V)"  { 120 }
                "VM Process (Hyper-V)"  { 120 }
                "VM State (Hyper-V)"    { 30 }
                "Backup Drive Rotation" { 300 }
                default                 { 60 }
            }
        }

        # Consecutive failures before emailing: with a daily/periodic check like Cert or
        # Backup Drive Rotation, waiting for 3 confirmations before alerting would mean
        # waiting several extra check cycles to report something already overdue/expired.
        # Both default to reporting on the first failed check instead.
        if (-not $isEdit) {
            $wantsOne = ($cmbType.SelectedItem -eq "TLS Certificate" -or $cmbType.SelectedItem -eq "Backup Drive Rotation")
            if ($wantsOne -and [int]$numFt.Value -eq 3) { $numFt.Value = 1 }
            elseif (-not $wantsOne -and [int]$numFt.Value -eq 1) { $numFt.Value = 3 }
        }
    }
    $cmbType.Add_SelectedIndexChanged($updatePanels)

    if ($isEdit) {
        $txtName.Text=$Existing.Name; $chkEnabled.Checked=[bool]$Existing.Enabled
        $numInterval.Value=[Math]::Max(5,[int]$Existing.CheckIntervalSec)
        $chkAuto.Checked=[bool]$Existing.AutoRestart; $numRa.Value=[int]$Existing.RestartAttempts
        $numFt.Value=[int]$Existing.FailuresBeforeEmail; $numRn.Value=[int]$Existing.RenotifyMinutes
        $chkRec.Checked=[bool]$Existing.SendRecoveryEmail
        switch ($Existing.Type) {
            "Service" { $cmbType.SelectedItem="Windows Service"; $txtSvc.Text=$Existing.Target }
            "Process" { $cmbType.SelectedItem="Process"; $txtPn.Text=$Existing.Target; $txtExe.Text=$Existing.ExePath; $txtArgs.Text=$Existing.Arguments; $txtWd.Text=$Existing.WorkingDirectory; $txtRunAsUser.Text=$Existing.RunAsUser; if ($Existing.EncryptedRunAsPassword) { $txtRunAsPass.Text="********"; $txtRunAsPass.Tag="unchanged" } }
            "Port"    { $cmbType.SelectedItem="TCP Port"; $txtH.Text=$Existing.HostName; $numP.Value=[int]$Existing.Port }
            "Url"     { $cmbType.SelectedItem="HTTP(S) URL"; $txtU.Text=$Existing.Url; $numEc.Value=[int]$Existing.ExpectedStatusCode; $numTo.Value=[int]$Existing.TimeoutSeconds }
            "Cert"    { $cmbType.SelectedItem="TLS Certificate"; $txtCu.Text=$Existing.Target; $numCp.Value=[int]$Existing.Port; $numCw.Value=[int]$Existing.CertWarnDays }
            "BackupDrive" { $cmbType.SelectedItem="Backup Drive Rotation"; $txtBd.Text=$Existing.Target; $numBdWarn.Value=[int]$Existing.WarnAfterDays; $numBdAlert.Value=[int]$Existing.AlertAfterDays }
            "VMService" { $cmbType.SelectedItem="VM Service (Hyper-V)"; $txtVMn.Text=$Existing.VMName; $txtVMu.Text=$Existing.VMUsername; $txtVMt.Text=$Existing.Target; if ($Existing.EncryptedVMPassword) { $txtVMp.Text="********"; $txtVMp.Tag="unchanged" } }
            "VMProcess" { $cmbType.SelectedItem="VM Process (Hyper-V)"; $txtVMn.Text=$Existing.VMName; $txtVMu.Text=$Existing.VMUsername; $txtVMt.Text=$Existing.Target; $txtVMe.Text=$Existing.ExePath; $txtVMa.Text=$Existing.Arguments; if ($Existing.EncryptedVMPassword) { $txtVMp.Text="********"; $txtVMp.Tag="unchanged" } }
            "VMState" { $cmbType.SelectedItem="VM State (Hyper-V)"; $txtVSn.Text=$Existing.Target }
        }
    } else { $cmbType.SelectedIndex = 0 }
    $txtVMp.Add_TextChanged({ param($s,$e) $s.Tag=$null })
    & $updatePanels

    $script:ItemEditorResult = $null
    $btnOk.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) { [System.Windows.Forms.MessageBox]::Show("Please enter a friendly name.","Missing info","OK","Warning")|Out-Null; return }
        $typeCode = switch ($cmbType.SelectedItem) { "Windows Service"{"Service"} "Process"{"Process"} "TCP Port"{"Port"} "HTTP(S) URL"{"Url"} "TLS Certificate"{"Cert"} "VM Service (Hyper-V)"{"VMService"} "VM Process (Hyper-V)"{"VMProcess"} "VM State (Hyper-V)"{"VMState"} "Backup Drive Rotation"{"BackupDrive"} }
        $target = switch ($typeCode) { "Service"{$txtSvc.Text.Trim()} "Process"{$txtPn.Text.Trim()} "Port"{$txtH.Text.Trim()} "Url"{$txtU.Text.Trim()} "Cert"{$txtCu.Text.Trim()} "VMService"{$txtVMt.Text.Trim()} "VMProcess"{$txtVMt.Text.Trim()} "VMState"{$txtVSn.Text.Trim()} "BackupDrive"{$txtBd.Text.Trim()} }
        if ([string]::IsNullOrWhiteSpace($target)) { [System.Windows.Forms.MessageBox]::Show("Please fill in the target.","Missing info","OK","Warning")|Out-Null; return }
        $isVM = ($typeCode -eq "VMService" -or $typeCode -eq "VMProcess")
        if ($isVM -and ([string]::IsNullOrWhiteSpace($txtVMn.Text) -or [string]::IsNullOrWhiteSpace($txtVMu.Text))) {
            [System.Windows.Forms.MessageBox]::Show("VM monitors need the VM name and a guest username.","Missing info","OK","Warning")|Out-Null; return
        }
        if ($typeCode -eq "BackupDrive" -and [int]$numBdAlert.Value -lt [int]$numBdWarn.Value) {
            [System.Windows.Forms.MessageBox]::Show("'Seriously overdue after' should be the same as or later than 'Expected rotation every'.","Check the numbers","OK","Warning")|Out-Null; return
        }
        $portVal = if ($typeCode -eq "Cert") { [int]$numCp.Value } else { [int]$numP.Value }

        # Guest password: keep existing when the field still shows the placeholder
        $encVMpw = if ($isEdit) { $Existing.EncryptedVMPassword } else { "" }
        if ($isVM -and $txtVMp.Tag -ne "unchanged") { $encVMpw = Protect-PlainPassword $txtVMp.Text }

        # Run-as-user password (Process type only): same keep-existing-if-unchanged pattern
        $encRunAsPw = if ($isEdit) { $Existing.EncryptedRunAsPassword } else { "" }
        if ($typeCode -eq "Process" -and $txtRunAsPass.Tag -ne "unchanged") { $encRunAsPw = Protect-PlainPassword $txtRunAsPass.Text }
        if ($typeCode -eq "Process" -and -not [string]::IsNullOrWhiteSpace($txtRunAsUser.Text) -and [string]::IsNullOrWhiteSpace($txtRunAsPass.Text) -and $txtRunAsPass.Tag -ne "unchanged") {
            [System.Windows.Forms.MessageBox]::Show("You entered a 'Run as user' but no password. Enter the password too, or clear the username to run as whatever account Watchdog itself uses.","Missing info","OK","Warning")|Out-Null; return
        }

        # For VM types, ExePath/Arguments come from the guest fields
        $exePathVal = if ($typeCode -eq "VMProcess") { $txtVMe.Text.Trim() } else { $txtExe.Text.Trim() }
        $argsVal    = if ($typeCode -eq "VMProcess") { $txtVMa.Text.Trim() } else { $txtArgs.Text.Trim() }

        $script:ItemEditorResult = Normalize-Item ([PSCustomObject]@{
            Id=$(if($isEdit){$Existing.Id}else{[guid]::NewGuid().ToString()})
            Name=$txtName.Text.Trim(); Type=$typeCode; Target=$target
            ExePath=$exePathVal; Arguments=$argsVal; WorkingDirectory=$txtWd.Text.Trim()
            HostName=$txtH.Text.Trim(); Port=$portVal
            Url=$txtU.Text.Trim(); ExpectedStatusCode=[int]$numEc.Value; TimeoutSeconds=[int]$numTo.Value
            CertWarnDays=[int]$numCw.Value; CheckIntervalSec=[int]$numInterval.Value
            Enabled=$chkEnabled.Checked; AutoRestart=$chkAuto.Checked; RestartAttempts=[int]$numRa.Value
            FailuresBeforeEmail=[int]$numFt.Value; RenotifyMinutes=[int]$numRn.Value; SendRecoveryEmail=$chkRec.Checked
            VMName=$txtVMn.Text.Trim(); VMUsername=$txtVMu.Text.Trim(); EncryptedVMPassword=$encVMpw
            RunAsUser=$(if($typeCode -eq "Process"){$txtRunAsUser.Text.Trim()}else{""}); EncryptedRunAsPassword=$(if($typeCode -eq "Process"){$encRunAsPw}else{""})
            WarnAfterDays=[int]$numBdWarn.Value; AlertAfterDays=[int]$numBdAlert.Value
        })
        $dlg.DialogResult=[System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    })

    $dlg.ShowDialog() | Out-Null
    return $script:ItemEditorResult
}

# ==================================================================
#  Monitoring engine
# ==================================================================
function Show-Balloon { param([string]$Title,[string]$Text,[string]$IconType="Info")
    if (-not $script:General.ShowBalloonTips) { return }
    if (-not $script:UI.Tray) { return }
    try {
        $t = switch ($IconType) { "Error"{[System.Windows.Forms.ToolTipIcon]::Error} "Warning"{[System.Windows.Forms.ToolTipIcon]::Warning} default{[System.Windows.Forms.ToolTipIcon]::Info} }
        $script:UI.Tray.ShowBalloonTip(7000, $Title, $Text, $t)
    } catch { }
}

# Runs one check for an item and returns the raw result. Shared by the monitoring loop
# and the item editor's "Test this check" button, so the two can never disagree about
# what a given item actually does. -State is only needed by BackupDrive, which compares
# against the previous check; pass a fresh blank state for a one-off test.
function Invoke-SingleCheck { param($Item, $State)
    switch ($Item.Type) {
        "Service"     { Test-ServiceUp  -Target $Item.Target }
        "Process"     { Test-ProcessUp  -Target $Item.Target }
        "Port"        { Test-PortUp     -HostName $Item.HostName -Port $Item.Port }
        "Url"         { Test-UrlUp      -Url $Item.Url -ExpectedCode $Item.ExpectedStatusCode -TimeoutSec $Item.TimeoutSeconds }
        "Cert"        { Test-CertExpiry -Target $Item.Target -Port $Item.Port -WarnDays $Item.CertWarnDays }
        "VMService"   { Test-VMService  -VMName $Item.VMName -Cred (Get-ItemVMCredential -Item $Item) -ServiceName $Item.Target }
        "VMProcess"   { Test-VMProcess  -VMName $Item.VMName -Cred (Get-ItemVMCredential -Item $Item) -ProcName $Item.Target }
        "VMState"     { Test-VMState -VMName $Item.Target }
        "BackupDrive" { Test-BackupDriveRotation -DriveLetter $Item.Target -WarnAfterDays $Item.WarnAfterDays -AlertAfterDays $Item.AlertAfterDays -LastRotationTime $State.LastRotationTime -WasPresent $State.DriveWasPresent -LastSerial $State.LastDriveSerial }
        default       { @{ Status='Down'; Detail='Unknown type' } }
    }
}

function Update-ItemCheck { param($Item)
    Ensure-ItemState -Item $Item
    $st = $script:ItemState[$Item.Id]
    $prev = $st.LastStatus

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-SingleCheck -Item $Item -State $st
    $sw.Stop()

    $st.LastChecked = Get-Date
    $st.LastMessage = $r.Detail
    $st.LastResponseMs = [int]$sw.ElapsedMilliseconds
    $st.TotalChecks++
    if ($r.Status -ne 'Down') { $st.TotalAvailable++ }
    if ($r.ContainsKey('DaysLeft')) { $st.CertDaysLeft = $r.DaysLeft }
    if ($r.ContainsKey('NewLastRotationTime')) {
        $st.LastRotationTime = $r.NewLastRotationTime
        $st.DriveWasPresent = $r.NewWasPresent
        $st.LastDriveSerial = $r.NewSerial
    }

    switch ($r.Status) {
        "Up" {
            if (($prev -eq "Down" -or $prev -eq "Warning")) {
                Write-Log "$($Item.Name): RECOVERED - $($r.Detail)"
                Show-Balloon -Title "Back online" -Text "$($Item.Name) has recovered." -IconType "Info"
                # Notify if either (a) we already sent a down/warning alert for this incident,
                # OR (b) auto-restart fired at least once - even if it healed fast enough to
                # never cross the alert threshold, you should still hear "it went down, got
                # fixed automatically, and is back" rather than silence on both ends.
                $shouldNotify = ($st.EmailSentForIncident -or $st.RestartAttemptsMade -gt 0) -and $Item.SendRecoveryEmail
                if ($shouldNotify) {
                    $recoveryWord = if ($Item.Type -eq "Cert") { "RENEWED" } elseif ($Item.Type -eq "BackupDrive") { "ROTATED" } else { "UP" }
                    $details = [ordered]@{
                        "Type"   = (Get-TypeLabel $Item.Type)
                        "Target" = $Item.Target
                    }
                    if ($st.DownSince) { $details["Was down for"] = Format-FriendlyDuration ((Get-Date) - $st.DownSince) }
                    $details["Recovered at"] = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    $details["Detail"] = $r.Detail
                    $note = if (-not $st.EmailSentForIncident -and $st.RestartAttemptsMade -gt 0) {
                        "Auto-restarted and recovered before reaching the alert threshold - you weren't separately notified it went down."
                    } else { "" }
                    Send-AlertEmail -Status $recoveryWord -ItemName $Item.Name -Details $details -Note $note -ItemId $Item.Id -Kind 'Up'
                }
            }
            $st.ConsecutiveFailures=0; $st.RestartAttemptsMade=0; $st.EmailSentForIncident=$false; $st.LastEmailSentTime=$null; $st.LastSendAttemptTime=$null; $st.DownSince=$null; $st.LastStatus="Up"
        }
        "Warning" {
            $st.LastStatus="Warning"
            if ($prev -ne "Warning") { Write-Log "$($Item.Name): WARNING - $($r.Detail)"; Show-Balloon -Title "Warning" -Text "$($Item.Name): $($r.Detail)" -IconType "Warning" }
            if (-not $st.DownSince) { $st.DownSince = Get-Date }   # so a later recovery email can report how long it needed attention

            # Keep trying every check until the FIRST notification actually gets out -
            # a failed send must never mean "silently never told anyone". Once sent,
            # only repeat per RenotifyMinutes. Throttled to at most once a minute so a
            # struggling mail server doesn't get hammered while we retry.
            $due = $false
            if (-not $st.EmailSentForIncident) {
                if (-not $st.LastSendAttemptTime -or ((Get-Date)-$st.LastSendAttemptTime).TotalSeconds -ge 60) { $due = $true }
            } elseif ($Item.RenotifyMinutes -gt 0 -and $st.LastEmailSentTime -and ((Get-Date)-$st.LastEmailSentTime).TotalMinutes -ge $Item.RenotifyMinutes) {
                $due = $true
            }
            if ($due -and (Test-InStartupGracePeriod)) {
                Write-Log "$($Item.Name): WARNING during startup grace period - holding off on the alert for now."
                $due = $false
            }
            if ($due) {
                $st.LastSendAttemptTime = Get-Date
                $statusWord = if ($Item.Type -eq "BackupDrive") { "OVERDUE" } else { "EXPIRING" }
                $noteText = if ($Item.Type -eq "BackupDrive") { "Rotate the drive as soon as convenient." } else { "Renew before it expires to avoid an outage." }
                if ([int]$script:General.AlertBatchWindowSec -gt 0) {
                    Add-ToAlertBatch -ItemId $Item.Id -ItemName $Item.Name -TypeLabel (Get-TypeLabel $Item.Type) -Target $Item.Target -StatusWord $statusWord -Detail $r.Detail -Kind 'Warning'
                } else {
                    $details = [ordered]@{ "Target" = $Item.Target; "Detail" = $r.Detail }
                    Send-AlertEmail -Status $statusWord -ItemName $Item.Name -Details $details -Note $noteText -ItemId $Item.Id -Kind 'Warning'
                }
            }
        }
        default {
            $st.ConsecutiveFailures++; $st.LastStatus="Down"
            if ($prev -ne "Down") { Show-Balloon -Title "Down" -Text "$($Item.Name): $($r.Detail)" -IconType "Error" }
            if (-not $st.DownSince) { $st.DownSince = Get-Date }
            Write-Log "$($Item.Name): DOWN (failure #$($st.ConsecutiveFailures)) - $($r.Detail)"

            # Holding off on auto-restart too during the startup grace window - something
            # that's simply still starting up alongside the rest of the machine (a VM
            # mid-boot, a service Windows hasn't gotten to yet) doesn't need "fixing".
            if ($Item.AutoRestart -and $st.RestartAttemptsMade -lt $Item.RestartAttempts -and -not (Test-InStartupGracePeriod)) {
                $st.RestartAttemptsMade++
                $rr = Invoke-RestartAction -Item $Item
                $tag = if ($rr.Ok) { "issued" } else { "FAILED" }
                Write-Log "$($Item.Name): restart attempt $($st.RestartAttemptsMade)/$($Item.RestartAttempts) $tag - $($rr.Detail)"
            }

            # Same "keep trying until it actually sends" pattern as Warning above - the
            # previous version only checked ConsecutiveFailures -eq the threshold, which
            # meant a single failed send (e.g. a transient SMTP hiccup right at that exact
            # check) would permanently skip alerting for the rest of the incident whenever
            # RenotifyMinutes was 0 (now the default for most types). That's silent alert
            # loss, which is worse than a duplicate email.
            $due = $false
            if ($st.ConsecutiveFailures -ge $Item.FailuresBeforeEmail -and -not $st.EmailSentForIncident) {
                if (-not $st.LastSendAttemptTime -or ((Get-Date)-$st.LastSendAttemptTime).TotalSeconds -ge 60) { $due = $true }
            } elseif ($st.EmailSentForIncident -and $Item.RenotifyMinutes -gt 0) {
                if (-not $st.LastEmailSentTime -or ((Get-Date)-$st.LastEmailSentTime).TotalMinutes -ge $Item.RenotifyMinutes) { $due = $true }
            }
            if ($due -and (Test-InStartupGracePeriod)) {
                Write-Log "$($Item.Name): DOWN during startup grace period - holding off on the alert for now."
                $due = $false
            }
            if ($due) {
                $st.LastSendAttemptTime = Get-Date
                # A TLS item reporting Down usually means the cert already expired (vs. an
                # unreachable host); a backup drive reporting Down means it's seriously
                # overdue - call each out with its own plain-language status word.
                $statusWord = if ($Item.Type -eq "Cert" -and $r.Detail -like "EXPIRED*") { "EXPIRED" }
                              elseif ($Item.Type -eq "BackupDrive") { "CRITICAL" }
                              else { "DOWN" }
                if ([int]$script:General.AlertBatchWindowSec -gt 0) {
                    Add-ToAlertBatch -ItemId $Item.Id -ItemName $Item.Name -TypeLabel (Get-TypeLabel $Item.Type) -Target $Item.Target -StatusWord $statusWord -Detail $r.Detail -Kind 'Down'
                } else {
                    $details = [ordered]@{
                        "Type"                = (Get-TypeLabel $Item.Type)
                        "Target"              = $Item.Target
                        "Consecutive failures" = $st.ConsecutiveFailures
                        "Detail"              = $r.Detail
                    }
                    if ($st.TotalChecks -gt 1) { $details["Historical uptime"] = "$(Get-UptimePercent $st)% over $($st.TotalChecks) checks" }
                    $note = if ($Item.AutoRestart) { "Auto-restart attempts so far: $($st.RestartAttemptsMade) of $($Item.RestartAttempts)." } else { "" }
                    Send-AlertEmail -Status $statusWord -ItemName $Item.Name -Details $details -Note $note -ItemId $Item.Id -Kind 'Down'
                }
            }
        }
    }
}

function Invoke-SchedulerTick {
    # This runs on a WinForms timer, so an uncaught exception here becomes an unhandled-
    # exception dialog that can take the whole app down. Every step is guarded, and a
    # single item's check throwing must not abort the rest of the tick (matching the
    # headless loop's per-item guard).
    if (-not $script:IsPrimaryInstance) {
        try { Complete-PendingSends } catch { }
        try { Update-Dashboard } catch { }
        return
    }
    if ($script:IsPaused) {
        try { Complete-PendingSends } catch { }
        try { Flush-AlertBatchIfDue } catch { }
        return
    }
    $now = Get-Date; $checkedAny = $false
    foreach ($it in $script:Items) {
        if (-not $it.Enabled) { $script:ItemState[$it.Id].LastStatus = "Disabled"; continue }
        Ensure-ItemState -Item $it
        if ($now -ge $script:ItemState[$it.Id].NextCheckTime) {
            try { Update-ItemCheck -Item $it } catch { Write-Log "Check error on $($it.Name): $($_.Exception.Message)" }
            $script:ItemState[$it.Id].NextCheckTime = (Get-Date).AddSeconds([Math]::Max(5,[int]$it.CheckIntervalSec))
            $checkedAny = $true
        }
    }
    try { Flush-AlertBatchIfDue } catch { Write-Log "Batch flush error: $($_.Exception.Message)" }
    try { Complete-PendingSends } catch { Write-Log "Send-completion error: $($_.Exception.Message)" }
    try { Update-Dashboard } catch { Write-Log "Dashboard error: $($_.Exception.Message)" }
    try { Check-RestartNotice } catch { Write-Log "Restart-notice error: $($_.Exception.Message)" }
    try { Check-Heartbeat } catch { Write-Log "Heartbeat error: $($_.Exception.Message)" }
    if ($checkedAny) {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $script:UI.StatusBar.Text = "Last check: $stamp"
        if ($script:UI.LblLastCheck) { $script:UI.LblLastCheck.Text = $stamp }
    }
}

function Invoke-CheckAllNow {
    foreach ($it in $script:Items) {
        if (-not $it.Enabled) { $script:ItemState[$it.Id].LastStatus = "Disabled"; continue }
        try { Update-ItemCheck -Item $it } catch { Write-Log "Check error on $($it.Name): $($_.Exception.Message)" }
        $script:ItemState[$it.Id].NextCheckTime = (Get-Date).AddSeconds([Math]::Max(5,[int]$it.CheckIntervalSec))
    }
    try { Flush-AlertBatchIfDue } catch { Write-Log "Batch flush error: $($_.Exception.Message)" }
    try { Complete-PendingSends } catch { Write-Log "Send-completion error: $($_.Exception.Message)" }
    try { Update-Dashboard } catch { Write-Log "Dashboard error: $($_.Exception.Message)" }
    if ($script:UI.StatusBar) { $script:UI.StatusBar.Text = "Checked all at $((Get-Date).ToString('HH:mm:ss'))" }
}

# ---- Daily heartbeat: one "still alive / status summary" email per day ----
$script:LastHeartbeatDate = $null
$script:LastHeartbeatAttempt = $null
function Check-Heartbeat {
    if (-not $script:General.DailyHeartbeat) { return }
    $now = Get-Date
    $today = $now.Date
    if ($now.Hour -ne [int]$script:General.HeartbeatHour -or $script:LastHeartbeatDate -eq $today) { return }

    # Don't hammer the mail server retrying every scheduler tick if it keeps failing -
    # try at most once every 5 minutes while we're still inside the target hour.
    if ($script:LastHeartbeatAttempt -and ((Get-Date) - $script:LastHeartbeatAttempt).TotalMinutes -lt 5) { return }
    $script:LastHeartbeatAttempt = Get-Date

    $down = ($script:ItemState.Values | Where-Object { $_.LastStatus -eq "Down" }).Count
    $warn = ($script:ItemState.Values | Where-Object { $_.LastStatus -eq "Warning" }).Count
    $head = if ($down -gt 0) { "$down DOWN, $warn warning" } elseif ($warn -gt 0) { "$warn warning" } else { "all healthy" }

    # Send is async now - Complete-PendingSends marks today as "done" (Kind='Heartbeat')
    # only once the send genuinely succeeds, so a failure still retries within the hour.
    Send-AlertEmail -Status "DAILY" -ItemName $head -BodyHtmlOverride (Build-HeartbeatTableHtml) -Kind 'Heartbeat'
}

# ==================================================================
#  Headless engine (no GUI) - launched by the boot Scheduled Task
# ==================================================================
function Start-HeadlessLoop {
    $script:General.ShowBalloonTips = $false   # no tray in headless
    Write-Log "Watchdog started HEADLESS (no GUI) - watching $($script:Items.Count) item(s)."
    foreach ($it in $script:Items) { Ensure-ItemState -Item $it; $script:ItemState[$it.Id].NextCheckTime = Get-Date }

    $lastCfgWrite = $null
    try { $lastCfgWrite = (Get-Item $script:ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc } catch { }

    while ($true) {
        # Hot-reload config if the GUI saved changes
        try {
            $cur = (Get-Item $script:ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
            if ($cur -and $cur -ne $lastCfgWrite) {
                Reload-AppConfig
                foreach ($it in $script:Items) { Ensure-ItemState -Item $it }
                $lastCfgWrite = $cur
            }
        } catch { }

        $now = Get-Date
        foreach ($it in $script:Items) {
            if (-not $it.Enabled) { continue }
            Ensure-ItemState -Item $it
            if ($now -ge $script:ItemState[$it.Id].NextCheckTime) {
                try { Update-ItemCheck -Item $it } catch { Write-Log "Check error on $($it.Name): $($_.Exception.Message)" }
                $script:ItemState[$it.Id].NextCheckTime = (Get-Date).AddSeconds([Math]::Max(5,[int]$it.CheckIntervalSec))
            }
        }
        # Each tail task is guarded individually: this is the always-on boot-task loop, so
        # one throwing task (e.g. a config save failing on a full disk inside the restart
        # check) must never be allowed to escape the while() and kill monitoring until the
        # next reboot - with no window open to even notice it stopped.
        try { Flush-AlertBatchIfDue } catch { Write-Log "Batch flush error: $($_.Exception.Message)" }
        try { Complete-PendingSends } catch { Write-Log "Send-completion error: $($_.Exception.Message)" }
        try { Check-RestartNotice }  catch { Write-Log "Restart-notice error: $($_.Exception.Message)" }
        try { Check-Heartbeat }      catch { Write-Log "Heartbeat error: $($_.Exception.Message)" }
        Start-Sleep -Seconds ([Math]::Max(1,[int]$script:General.SchedulerResolutionSec))
    }
}

# A real function (not a local scriptblock) so it resolves correctly no matter which
# button/menu callback invokes it later - unlike a local variable, function name lookup
# doesn't depend on which scope happened to define it.
function Set-SelectedItemsEnabled { param([bool]$NewEnabled)
    if (-not $script:UI.ItemList -or $script:UI.ItemList.SelectedItems.Count -eq 0) { return }
    $ids = @($script:UI.ItemList.SelectedItems | ForEach-Object { $_.Tag })
    $changed = 0
    for ($i=0; $i -lt $script:Items.Count; $i++) {
        if ($script:Items[$i].Id -in $ids -and $script:Items[$i].Enabled -ne $NewEnabled) {
            $script:Items[$i].Enabled = $NewEnabled; $changed++
        }
    }
    if ($changed -gt 0) {
        Write-Log "$(if ($NewEnabled) {'Enabled'} else {'Disabled'}) $changed item(s)."
        Save-AppConfig; Update-Dashboard
    }
}

function Update-Dashboard {
    $lv = $script:UI.ItemList
    if (-not $lv) { return }

    $selectedIds = @($lv.SelectedItems | ForEach-Object { $_.Tag })
    $filterText = if ($script:UI.TxtFilter) { $script:UI.TxtFilter.Text.Trim() } else { "" }

    # Build one flat record per item with everything the row needs, so filtering and
    # sorting can happen before we touch the actual ListView control.
    $rows = @()
    $up=0;$down=0;$warn=0;$dis=0
    foreach ($it in $script:Items) {
        Ensure-ItemState -Item $it
        $st = $script:ItemState[$it.Id]
        $status = if (-not $it.Enabled) { "Disabled" } else { $st.LastStatus }
        switch ($status) { "Up"{$up++} "Down"{$down++} "Warning"{$warn++} "Disabled"{$dis++} }

        # A row briefly highlights the one time its status changes, then reverts back to
        # normal on the next refresh - a quick visual cue without needing real animation.
        $changed = ($null -ne $st.LastRenderedStatus) -and ($st.LastRenderedStatus -ne $status)
        $st.LastRenderedStatus = $status

        if ($filterText -and $it.Name -notlike "*$filterText*") { continue }

        $typeLabel = switch($it.Type){"Service"{"Service"}"Process"{"Process"}"Port"{"TCP Port"}"Url"{"HTTP(S)"}"Cert"{"TLS Cert"}"VMService"{"VM Svc"}"VMProcess"{"VM Proc"}"VMState"{"VM State"}"BackupDrive"{"Backup"}default{$it.Type}}
        $targetLabel = if ($it.Type -eq "VMService" -or $it.Type -eq "VMProcess") { "$($it.Target) @ $($it.VMName)" } else { $it.Target }
        $uptimePct = Get-UptimePercent $st
        $statusRank = switch ($status) { "Down"{0} "Warning"{1} "Unknown"{2} "Up"{3} "Disabled"{4} default{5} }

        $rows += [PSCustomObject]@{
            Id=$it.Id; Name=$it.Name; TypeLabel=$typeLabel; TargetLabel=$targetLabel
            Interval=[int]$it.CheckIntervalSec; Status=$status; StatusRank=$statusRank
            UptimePct=$uptimePct
            UptimeLabel=$(if ($null -ne $uptimePct) { "$uptimePct%" } else { "-" })
            ResponseMs=$st.LastResponseMs
            ResponseLabel=$(if ($null -ne $st.LastResponseMs) { "$($st.LastResponseMs) ms" } else { "-" })
            Detail=$st.LastMessage
            LastChecked=$st.LastChecked
            LastCheckLabel=$(if ($st.LastChecked) { $st.LastChecked.ToString("HH:mm:ss") } else { "-" })
            NextCheckTime=$st.NextCheckTime
            NextCheckLabel=$(if ($it.Enabled -and $st.NextCheckTime) { $st.NextCheckTime.ToString("HH:mm:ss") } else { "-" })
            Changed=$changed
        }
    }

    $col = if ($null -ne $script:UI.SortColumn) { $script:UI.SortColumn } else { 0 }
    $asc = if ($null -ne $script:UI.SortAscending) { $script:UI.SortAscending } else { $true }
    $keyExpr = switch ($col) {
        0 { { $_.Name } }
        1 { { $_.TypeLabel } }
        2 { { $_.TargetLabel } }
        3 { { $_.Interval } }
        4 { { $_.StatusRank } }
        5 { { if ($null -ne $_.UptimePct) { $_.UptimePct } else { -1 } } }
        6 { { if ($null -ne $_.ResponseMs) { $_.ResponseMs } else { -1 } } }
        7 { { $_.Detail } }
        8 { { if ($_.LastChecked) { $_.LastChecked } else { [datetime]::MinValue } } }
        9 { { if ($_.NextCheckTime) { $_.NextCheckTime } else { [datetime]::MaxValue } } }
        default { { $_.Name } }
    }
    $sorted = @($rows | Sort-Object -Property $keyExpr)
    if (-not $asc) { [array]::Reverse($sorted) }

    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($r in $sorted) {
        $row = New-Object System.Windows.Forms.ListViewItem($r.Name)
        [void]$row.SubItems.Add($r.TypeLabel)
        [void]$row.SubItems.Add($r.TargetLabel)
        [void]$row.SubItems.Add("$($r.Interval)s")
        [void]$row.SubItems.Add($r.Status)
        [void]$row.SubItems.Add($r.UptimeLabel)
        [void]$row.SubItems.Add($r.ResponseLabel)
        [void]$row.SubItems.Add($r.Detail)
        [void]$row.SubItems.Add($r.LastCheckLabel)
        [void]$row.SubItems.Add($r.NextCheckLabel)
        if ($r.Changed) {
            $row.BackColor = switch ($r.Status) {
                "Down"{[System.Drawing.Color]::FromArgb(255,224,224)}
                "Up"{[System.Drawing.Color]::FromArgb(224,255,224)}
                "Warning"{[System.Drawing.Color]::FromArgb(255,244,205)}
                default{[System.Drawing.Color]::White}
            }
        } else {
            $row.BackColor = [System.Drawing.Color]::White
        }
        $row.Tag = $r.Id
        if ($r.Id -in $selectedIds) { $row.Selected = $true }
        [void]$lv.Items.Add($row)
    }
    $lv.EndUpdate()

    if ($script:UI.ItemListEmpty) {
        $hasAny = $script:Items.Count -gt 0
        $lv.Visible = $hasAny
        $script:UI.ItemListEmpty.Visible = -not $hasAny
    }

    $script:UI.LblUp.Text = "$up"; $script:UI.LblWarn.Text = "$warn"; $script:UI.LblDown.Text = "$down"; $script:UI.LblDis.Text = "$dis"

    if (-not $script:IsPrimaryInstance) {
        $color="Gray"; $txt="Viewing only - background service is monitoring"
    } elseif ($script:Items.Count -eq 0) { $color="Gray"; $txt="No items configured" }
    elseif ($down -gt 0)           { $color="Red";  $txt="$down down" }
    elseif ($warn -gt 0)           { $color="Amber";$txt="$warn warning" }
    else                           { $color="Green";$txt="All healthy" }
    $script:UI.Tray.Icon = $script:Icons[$color]
    $script:UI.Tray.Text = "Watchdog - $txt"
    $script:UI.Pill.Text = "  $txt  "
    $script:UI.Pill.BackColor = $script:Theme[$color]
    if ($script:IsPaused) { $script:UI.Pill.Text = "  Paused  "; $script:UI.Pill.BackColor = $script:Theme.Gray; $script:UI.Tray.Text="Watchdog - paused" }
}

function Update-BootStatus {
    if (-not $script:UI.LblBoot) { return }
    $state = Get-BootTaskState
    if ($state -eq "Absent") {
        $script:UI.LblBoot.Text = "Status: not installed"; $script:UI.LblBoot.ForeColor = $script:Theme.Gray
    } elseif ($state -eq "Running") {
        $script:UI.LblBoot.Text = "Status: installed (running)"; $script:UI.LblBoot.ForeColor = $script:Theme.Green
    } else {
        $script:UI.LblBoot.Text = "Status: installed ($state)"; $script:UI.LblBoot.ForeColor = $script:Theme.Amber
    }
}

# Builds the Help tab's content directly into the RichTextBox. Kept in one place so it's
# easy to keep in sync as features change - this is the in-app equivalent of README.txt.
function Populate-HelpText { param($Box)
    $normalFont = New-Object System.Drawing.Font($script:BaseFont.FontFamily, 9)
    $headerFont = New-Object System.Drawing.Font($script:BaseFont.FontFamily, 13, [System.Drawing.FontStyle]::Bold)
    $subFont    = New-Object System.Drawing.Font($script:BaseFont.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $darkColor  = [System.Drawing.Color]::FromArgb(33,37,43)
    $bodyColor  = [System.Drawing.Color]::FromArgb(55,55,55)

    function local:AddHeader([string]$text) {
        $Box.SelectionStart = $Box.TextLength; $Box.SelectionLength = 0
        $Box.SelectionFont = $headerFont; $Box.SelectionColor = $darkColor
        $Box.AppendText("$text`n")
    }
    function local:AddSub([string]$text) {
        $Box.SelectionStart = $Box.TextLength; $Box.SelectionLength = 0
        $Box.SelectionFont = $subFont; $Box.SelectionColor = $darkColor
        $Box.AppendText("$text`n")
    }
    function local:AddBody([string]$text) {
        $Box.SelectionStart = $Box.TextLength; $Box.SelectionLength = 0
        $Box.SelectionFont = $normalFont; $Box.SelectionColor = $bodyColor
        $Box.AppendText("$text`n")
    }
    function local:AddSpace { $Box.AppendText("`n") }

    AddHeader "Watchdog - Quick Help"
    AddBody "Watchdog monitors services, processes, ports, websites, certificates, Hyper-V VMs, and rotating backup drives, and emails you when something needs attention."
    AddSpace

    AddSub "Monitor Types"
    AddBody "- Windows Service / Process / TCP Port / HTTP(S) URL - the basics. Fast, cheap checks, every 30-60 seconds by default."
    AddBody "- TLS Certificate - watches expiry date. Warns well ahead of time (60 days by default); alerts immediately if it's actually expired."
    AddBody "- VM State (Hyper-V) - is the VM powered on? Can auto-start it if found off. No guest credentials needed."
    AddBody "- VM Service / VM Process (Hyper-V) - checks something INSIDE a guest VM over PowerShell Direct. Hidden by default - turn on under General tab > Experimental Settings."
    AddBody "- Backup Drive Rotation - tracks days since a rotating USB backup drive was last swapped. Auto-detects disconnect/reconnect (or even a same-letter drive swap missed between checks)."
    AddSpace

    AddSub "How Alerting Works"
    AddBody "Each item has its own check interval, a 'consecutive failures before emailing' threshold (so a single blip doesn't trigger an alert), and a re-notify interval (0 = notify once and stay quiet until it's fixed)."
    AddBody "Recovery emails tell you when something's back up - including how long it was actually down for. If auto-restart fixes something fast enough that it never crossed the alert threshold, you still get told (marked as an auto-heal), rather than silence."
    AddBody "Emails are colour-coded per situation (red = Down/Critical/Expired, amber = Warning/Expiring/Overdue, green = Up/Renewed/Rotated) with the item's name and status in the subject line, and the machine name in the sender - so the important part is visible even on a phone's truncated notification."
    AddBody "'Alert batching window' (General tab, off by default) groups multiple Down/Warning alerts that happen within a short window into one combined email instead of a flood of separate ones - useful if one root cause (e.g. the host losing network) takes out several things at once. It only delays the notification, never the auto-restart action itself."
    AddSpace

    AddSub "Starting Watchdog Automatically (General tab)"
    AddBody "- 'Run at my Windows login' - starts with the tray icon visible whenever you log in."
    AddBody "- 'Install Startup Task' - runs headless (no window) as SYSTEM at every Windows boot, before anyone logs in. No password needed, and unaffected if your account password ever changes."
    AddBody "- 'Startup grace period' (default 10 min) - holds off on alert emails and auto-restarts for this long after a genuine reboot, so a VM or app that's simply still starting up isn't mistaken for an outage. Checks and the dashboard still work normally during this window."
    AddSpace

    AddSub "Only One Instance Ever Sends Alerts"
    AddBody "If you open this window while the Startup Task is already running in the background, this window will say 'Config only' in the header. That's expected - you can still view and edit everything, but checks and emails come from the background instance, so you never get duplicate alerts. Any changes you Save are picked up automatically within a few seconds."
    AddSpace

    AddSub "Where Things Live"
    AddBody "Config file: $($script:ConfigDir)\config.json (auto-backed up to a 'backups' subfolder on every Save)"
    AddBody "Log file: $($script:ConfigDir)\watchdog.log (auto-rotates once it passes 5MB)"
    AddSpace

    AddSub "Troubleshooting"
    AddBody "- Test Email failing: this is almost always Outlook/Gmail requiring an 'app password' instead of your normal login password once two-step verification is on."
    AddBody "- Startup Task not showing in Task Scheduler: press F5 to refresh - it doesn't auto-update, and the task sits at the top level of the library."
    AddBody "- Hyper-V VM Service/Process checks failing: the VM must be running, and the guest username/password must be a real account INSIDE that VM, not on the host."
    AddBody "- For anything else: the Log tab records the exact reason behind a failure in plain English - that's always the first place to look."

    $Box.SelectionStart = 0
}

# Pull the Email tab fields into $script:Email. A function (not a local scriptblock)
# so it stays callable from button handlers after the window is built.
function Apply-EmailFromUI {
    $script:Email.SmtpServer=$script:UI.TxtSmtp.Text.Trim(); $script:Email.SmtpPort=[int]$script:UI.NumPort.Value
    $script:Email.UseSSL=$script:UI.ChkSsl.Checked; $script:Email.Username=$script:UI.TxtUser.Text.Trim()
    if ($script:UI.TxtPass.Tag -ne "unchanged") { $script:Email.EncryptedPassword = Protect-PlainPassword $script:UI.TxtPass.Text }
    $script:Email.From=$script:UI.TxtFrom.Text.Trim(); $script:Email.To=$script:UI.TxtTo.Text.Trim(); $script:Email.SubjectPrefix=$script:UI.TxtPrefix.Text.Trim()
}

# Push current $script:Email / $script:General into the tab controls (used after Import).
function Refresh-SettingsUI {
    if (-not $script:UI.TxtSmtp) { return }
    $script:UI.TxtSmtp.Text=$script:Email.SmtpServer; $script:UI.NumPort.Value=[Math]::Min(65535,[Math]::Max(1,[int]$script:Email.SmtpPort))
    $script:UI.ChkSsl.Checked=[bool]$script:Email.UseSSL; $script:UI.TxtUser.Text=$script:Email.Username
    $script:UI.TxtFrom.Text=$script:Email.From; $script:UI.TxtTo.Text=$script:Email.To; $script:UI.TxtPrefix.Text=$script:Email.SubjectPrefix
    if (-not [string]::IsNullOrWhiteSpace($script:Email.EncryptedPassword)) { $script:UI.TxtPass.Text="********"; $script:UI.TxtPass.Tag="unchanged" } else { $script:UI.TxtPass.Text=""; $script:UI.TxtPass.Tag=$null }
    $script:UI.NumRes.Value=[Math]::Min(60,[Math]::Max(1,[int]$script:General.SchedulerResolutionSec))
    $script:UI.ChkBalloon.Checked=[bool]$script:General.ShowBalloonTips; $script:UI.ChkMin.Checked=[bool]$script:General.MinimizeToTrayOnClose
    $script:UI.ChkStartMin.Checked=[bool]$script:General.StartMinimized; $script:UI.ChkStartup.Checked=[bool]$script:General.RunAtStartup
    $script:UI.ChkHb.Checked=[bool]$script:General.DailyHeartbeat; $script:UI.NumHb.Value=[Math]::Min(23,[Math]::Max(0,[int]$script:General.HeartbeatHour))
    if ($script:UI.TxtInstance) { $script:UI.TxtInstance.Text=$script:General.InstanceName }
    if ($script:UI.NumGrace) { $script:UI.NumGrace.Value=[Math]::Min(120,[Math]::Max(0,[int]$script:General.StartupGraceMinutes)) }
    if ($script:UI.NumBatch) { $script:UI.NumBatch.Value=[Math]::Min(600,[Math]::Max(0,[int]$script:General.AlertBatchWindowSec)) }
    if ($script:UI.ChkExperimental) { $script:UI.ChkExperimental.Checked=[bool]$script:General.ExperimentalFeaturesEnabled }
    if ($script:UI.CmbRestartNotify) { $script:UI.CmbRestartNotify.SelectedItem = switch ("$($script:General.RestartNotifyMode)") { 'UnexpectedOnly' { "Unexpected outages only" } 'All' { "All restarts" } default { "Off" } } }
}

# ==================================================================
#  Main window
# ==================================================================
function Build-MainWindow {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Watchdog"; $form.Size = New-Object System.Drawing.Size(1020, 730)
    $form.StartPosition = "CenterScreen"; $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.Font = $script:BaseFont; $form.Icon = $script:Icons['Gray']
    $script:UI.Form = $form

    $header = New-Object System.Windows.Forms.Panel; $header.Dock="Top"; $header.Height=60; $header.BackColor=$script:Theme.HeaderBg2

    # Drawn rather than a letter in a box - a letterform inside a small rounded square
    # never sits quite right optically. This is a simple concentric "watching" mark.
    $logoBox = New-Object System.Windows.Forms.Panel; $logoBox.Size=New-Object System.Drawing.Size(30,30); $logoBox.Location=New-Object System.Drawing.Point(16,15); $logoBox.BackColor=$script:Theme.HeaderBg2
    $logoBox.Add_Paint({
        param($sender,$e)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $ring = New-Object System.Drawing.Pen($script:Theme.Green, 2.2)
        $e.Graphics.DrawEllipse($ring, 2, 2, 25, 25)
        $ring.Dispose()
        $core = New-Object System.Drawing.SolidBrush($script:Theme.Green)
        $e.Graphics.FillEllipse($core, 10, 10, 9, 9)
        $core.Dispose()
    })

    # Top line reads left to right: logo, name, slogan, version. Widths are generous -
    # "Watchdog" at 14pt semibold was being clipped by a 96px label.
    $title = New-Object System.Windows.Forms.Label; $title.Text="Watchdog"; $title.ForeColor=$script:Theme.HeaderText; $title.Font=$script:HeaderFont
    $title.AutoSize=$false; $title.TextAlign="MiddleLeft"; $title.Size=New-Object System.Drawing.Size(116,24)
    $title.Location=New-Object System.Drawing.Point(54,11)
    $tagline = New-Object System.Windows.Forms.Label; $tagline.Text="Windows monitoring and alerting"; $tagline.ForeColor=$script:Theme.HeaderSubtle; $tagline.Font=$script:BaseFont
    $tagline.AutoSize=$false; $tagline.TextAlign="MiddleLeft"; $tagline.Size=New-Object System.Drawing.Size(200,24)
    $tagline.Location=New-Object System.Drawing.Point(174,18)
    $lblHdrVer = New-Object System.Windows.Forms.Label; $lblHdrVer.Text="v$($script:AppVersion)"; $lblHdrVer.ForeColor=$script:Theme.HeaderSubtle; $lblHdrVer.Font=$script:BaseFont
    $lblHdrVer.AutoSize=$false; $lblHdrVer.TextAlign="MiddleLeft"; $lblHdrVer.Size=New-Object System.Drawing.Size(60,24)
    $lblHdrVer.Location=New-Object System.Drawing.Point(382,18)
    # Machine name sits on its own line under the name.
    $subtitle = New-Object System.Windows.Forms.Label; $subtitle.Text=(Get-InstanceName); $subtitle.ForeColor=$script:Theme.HeaderSubtle; $subtitle.Font=$script:BaseFont
    $subtitle.AutoSize=$false; $subtitle.TextAlign="MiddleLeft"; $subtitle.Size=New-Object System.Drawing.Size(300,18)
    $subtitle.Location=New-Object System.Drawing.Point(55,34)

    # Right-hand side lives in a docked panel so it stays put at any window width -
    # AutoSize labels anchored Right get pushed off the edge instead of repositioning.
    $hdrRight = New-Object System.Windows.Forms.Panel
    $hdrRight.Dock = "Right"; $hdrRight.Width = 330; $hdrRight.BackColor = $script:Theme.HeaderBg2
    $lblLastLbl = New-Object System.Windows.Forms.Label; $lblLastLbl.Text="LAST CHECK"; $lblLastLbl.ForeColor=$script:Theme.HeaderSubtle; $lblLastLbl.Font=$script:MicroFont
    $lblLastLbl.AutoSize=$false; $lblLastLbl.TextAlign="MiddleRight"; $lblLastLbl.Size=New-Object System.Drawing.Size(100,14)
    $lblLastLbl.Location=New-Object System.Drawing.Point(6,16)
    $lblLastVal = New-Object System.Windows.Forms.Label; $lblLastVal.Text="-"; $lblLastVal.ForeColor=[System.Drawing.Color]::FromArgb(229,231,235); $lblLastVal.Font=$script:BaseFont
    $lblLastVal.AutoSize=$false; $lblLastVal.TextAlign="MiddleRight"; $lblLastVal.Size=New-Object System.Drawing.Size(100,18)
    $lblLastVal.Location=New-Object System.Drawing.Point(6,32)

    $pill = New-Object System.Windows.Forms.Label; $pill.Text="  starting  "; $pill.ForeColor=[System.Drawing.Color]::White; $pill.Font=$script:BoldFont
    $pill.BackColor=$script:Theme.Gray; $pill.TextAlign="MiddleCenter"; $pill.AutoSize=$false
    $pill.Size=New-Object System.Drawing.Size(190,28); $pill.Location=New-Object System.Drawing.Point(128,16)
    Set-RoundedRegion -Control $pill -Radius 14
    $hdrRight.Controls.AddRange(@($lblLastLbl,$lblLastVal,$pill))
    $header.Controls.AddRange(@($logoBox,$title,$tagline,$lblHdrVer,$subtitle))
    $header.Controls.Add($hdrRight)
    $script:UI.Pill = $pill; $script:UI.LblLastCheck = $lblLastVal

    $tabs = New-Object System.Windows.Forms.TabControl; $tabs.Dock="Fill"; $tabs.Padding=New-Object System.Drawing.Point(12,6)

    $tabItems = New-Object System.Windows.Forms.TabPage; $tabItems.Text="  Monitored Items  "; $tabItems.BackColor=[System.Drawing.Color]::White

    $summary = New-Object System.Windows.Forms.Panel; $summary.Dock="Top"; $summary.Height=78; $summary.BackColor=$script:Theme.Panel
    $mcUp   = New-MetricCard -X 14  -Y 8 -W 150 -H 60 -Caption "UP"       -AccentColor $script:Theme.Green
    $mcWarn = New-MetricCard -X 172 -Y 8 -W 150 -H 60 -Caption "WARNING"  -AccentColor $script:Theme.Amber
    $mcDown = New-MetricCard -X 330 -Y 8 -W 150 -H 60 -Caption "DOWN"     -AccentColor $script:Theme.Red
    $mcDis  = New-MetricCard -X 488 -Y 8 -W 150 -H 60 -Caption "DISABLED" -AccentColor $script:Theme.Gray
    $lblFilter = New-Object System.Windows.Forms.Label; $lblFilter.Text="Filter:"; $lblFilter.Location=New-Object System.Drawing.Point(780,24); $lblFilter.AutoSize=$true; $lblFilter.Anchor="Top,Right"
    $txtFilter = New-Object System.Windows.Forms.TextBox; $txtFilter.Location=New-Object System.Drawing.Point(825,21); $txtFilter.Size=New-Object System.Drawing.Size(160,24); $txtFilter.Anchor="Top,Right"
    $summary.Controls.AddRange(@($mcUp.Card,$mcWarn.Card,$mcDown.Card,$mcDis.Card,$lblFilter,$txtFilter))
    $script:UI.LblUp=$mcUp.ValueLabel; $script:UI.LblWarn=$mcWarn.ValueLabel; $script:UI.LblDown=$mcDown.ValueLabel; $script:UI.LblDis=$mcDis.ValueLabel; $script:UI.TxtFilter=$txtFilter

    $toolbar = New-Object System.Windows.Forms.Panel; $toolbar.Dock="Bottom"; $toolbar.Height=48
    $btnAdd    = New-Object System.Windows.Forms.Button; $btnAdd.Text="Add...";    $btnAdd.Location=New-Object System.Drawing.Point(10,8);  $btnAdd.Size=New-Object System.Drawing.Size(95,32)
    $btnEdit   = New-Object System.Windows.Forms.Button; $btnEdit.Text="Edit...";  $btnEdit.Location=New-Object System.Drawing.Point(112,8); $btnEdit.Size=New-Object System.Drawing.Size(95,32)
    $btnDup    = New-Object System.Windows.Forms.Button; $btnDup.Text="Duplicate"; $btnDup.Location=New-Object System.Drawing.Point(214,8); $btnDup.Size=New-Object System.Drawing.Size(95,32)
    $btnRemove = New-Object System.Windows.Forms.Button; $btnRemove.Text="Remove"; $btnRemove.Location=New-Object System.Drawing.Point(316,8); $btnRemove.Size=New-Object System.Drawing.Size(95,32)
    $btnCheck  = New-Object System.Windows.Forms.Button; $btnCheck.Text="Check now"; $btnCheck.Location=New-Object System.Drawing.Point(432,8); $btnCheck.Size=New-Object System.Drawing.Size(110,32)
    $btnEnableSel  = New-Object System.Windows.Forms.Button; $btnEnableSel.Text="Enable";  $btnEnableSel.Location=New-Object System.Drawing.Point(560,8); $btnEnableSel.Size=New-Object System.Drawing.Size(80,32)
    $btnDisableSel = New-Object System.Windows.Forms.Button; $btnDisableSel.Text="Disable"; $btnDisableSel.Location=New-Object System.Drawing.Point(645,8); $btnDisableSel.Size=New-Object System.Drawing.Size(80,32)
    if (-not $script:IsPrimaryInstance) {
        $btnCheck.Enabled = $false
        $script:UI.ConfigOnlyTip = New-Object System.Windows.Forms.ToolTip
        $script:UI.ConfigOnlyTip.SetToolTip($btnCheck, "The background service is already monitoring - checks and alerts run from there.")
    }
    Set-FlatButton -Button $btnAdd -Primary
    foreach ($b in @($btnEdit,$btnDup,$btnRemove,$btnCheck,$btnEnableSel,$btnDisableSel)) { Set-FlatButton -Button $b }
    $toolbar.BackColor = [System.Drawing.Color]::White
    $toolbar.Controls.AddRange(@($btnAdd,$btnEdit,$btnDup,$btnRemove,$btnCheck,$btnEnableSel,$btnDisableSel))
    $script:UI.BtnEdit = $btnEdit
    $script:UI.BtnDup = $btnDup
    $script:UI.BtnAdd = $btnAdd; $script:UI.BtnCheck = $btnCheck

    # Right-click menu mirrors the toolbar - selecting the row under the cursor first,
    # since ListView doesn't do that automatically on a right-click.
    $lvMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miEdit = $lvMenu.Items.Add("Edit...")
    $miDup = $lvMenu.Items.Add("Duplicate")
    [void]$lvMenu.Items.Add("-")
    $miEnable = $lvMenu.Items.Add("Enable")
    $miDisable = $lvMenu.Items.Add("Disable")
    [void]$lvMenu.Items.Add("-")
    $miCheckNow = $lvMenu.Items.Add("Check now")
    [void]$lvMenu.Items.Add("-")
    $miRemove = $lvMenu.Items.Add("Remove")

    $listContainer = New-Object System.Windows.Forms.Panel; $listContainer.Dock="Fill"
    $lv = New-Object System.Windows.Forms.ListView; $lv.Dock="Fill"; $lv.View="Details"; $lv.FullRowSelect=$true; $lv.GridLines=$false; $lv.MultiSelect=$true
    $lv.ContextMenuStrip = $lvMenu; $lv.BackColor=[System.Drawing.Color]::White; $lv.BorderStyle="None"
    [void]$lv.Columns.Add("NAME",150); [void]$lv.Columns.Add("TYPE",64); [void]$lv.Columns.Add("TARGET",128)
    [void]$lv.Columns.Add("INTERVAL",58); [void]$lv.Columns.Add("STATUS",76); [void]$lv.Columns.Add("UPTIME",56); [void]$lv.Columns.Add("RESPONSE",62); [void]$lv.Columns.Add("DETAIL",126); [void]$lv.Columns.Add("LAST CHECK",70); [void]$lv.Columns.Add("NEXT CHECK",70)

    # Native ListView can't draw rounded badges or per-status row tints, so cells are
    # painted by hand. Column 4 (STATUS) becomes a badge; column 0 gets a status dot.
    $lv.OwnerDraw = $true
    Set-DoubleBuffered -Control $lv
    $lv.Add_DrawColumnHeader({
        param($sender,$e)
        Initialize-DrawCache
        $e.Graphics.FillRectangle($script:Draw.PanelBrush,$e.Bounds)
        $e.Graphics.DrawLine($script:Draw.BorderPen,$e.Bounds.Left,$e.Bounds.Bottom-1,$e.Bounds.Right,$e.Bounds.Bottom-1)
        $r = New-Object System.Drawing.RectangleF([single]($e.Bounds.X+9),[single]$e.Bounds.Y,[single]($e.Bounds.Width-12),[single]$e.Bounds.Height)
        $e.Graphics.DrawString($e.Header.Text,$script:MicroFont,$script:Draw.MutedBrush,$r,$script:Draw.Fmt)
    })
    $lv.Add_DrawItem({ param($sender,$e) })
    $lv.Add_DrawSubItem({
        param($sender,$e)
        $status = ""
        if ($e.Item.SubItems.Count -gt 4) { $status = $e.Item.SubItems[4].Text }
        $vis = Get-StatusVisuals -Status $status
        $cell = $e.Bounds
        if ($e.ColumnIndex -eq 0) { $cell = New-Object System.Drawing.Rectangle($e.Bounds.X,$e.Bounds.Y,$sender.Columns[0].Width,$e.Bounds.Height) }

        Initialize-DrawCache
        if ($e.Item.Selected) {
            $e.Graphics.FillRectangle($script:Draw.SelBrush,$cell)
        } elseif ($e.Item.BackColor.A -ne 0 -and $e.Item.BackColor -ne [System.Drawing.Color]::White) {
            $bgB = New-Object System.Drawing.SolidBrush($e.Item.BackColor)
            $e.Graphics.FillRectangle($bgB,$cell); $bgB.Dispose()
        } elseif ($vis.RowTint -eq [System.Drawing.Color]::White) {
            $e.Graphics.FillRectangle($script:Draw.WhiteBrush,$cell)
        } else {
            $bgB = New-Object System.Drawing.SolidBrush($vis.RowTint)
            $e.Graphics.FillRectangle($bgB,$cell); $bgB.Dispose()
        }
        $e.Graphics.DrawLine($script:Draw.HairlinePen,$cell.Left,$cell.Bottom-1,$cell.Right,$cell.Bottom-1)
        $sf = $script:Draw.Fmt

        if ($e.ColumnIndex -eq 4) {
            $label = if ($status) { $status } else { "-" }
            $tw = $e.Graphics.MeasureString($label,$script:BaseFont)
            $pw = [int][Math]::Min(($tw.Width+18),($cell.Width-12)); $ph = 18
            $pr = New-Object System.Drawing.Rectangle(($cell.X+8),($cell.Y+[int](($cell.Height-$ph)/2)),$pw,$ph)
            $om = $e.Graphics.SmoothingMode
            $e.Graphics.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            Fill-RoundedRect -Graphics $e.Graphics -Rect $pr -Radius 9 -Color $vis.PillBg
            $e.Graphics.SmoothingMode=$om
            $pf = New-Object System.Drawing.SolidBrush($vis.PillFg)
            $prF = New-Object System.Drawing.RectangleF([single]$pr.X,[single]$pr.Y,[single]$pr.Width,[single]$pr.Height)
            $e.Graphics.DrawString($label,$script:BaseFont,$pf,$prF,$script:Draw.FmtMid)
            $pf.Dispose()
        } elseif ($e.ColumnIndex -eq 0) {
            $ds = 7; $dx = $cell.X+10; $dy = $cell.Y+[int](($cell.Height-$ds)/2)
            $om = $e.Graphics.SmoothingMode
            $e.Graphics.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $db = New-Object System.Drawing.SolidBrush($vis.Dot)
            $e.Graphics.FillEllipse($db,$dx,$dy,$ds,$ds); $db.Dispose()
            $e.Graphics.SmoothingMode=$om
            $r = New-Object System.Drawing.RectangleF([single]($dx+$ds+7),[single]$cell.Y,[single]($cell.Width-$ds-24),[single]$cell.Height)
            $e.Graphics.DrawString($e.Item.Text,$script:BaseFont,$script:Draw.TextBrush,$r,$sf)
        } else {
            $fgB = if ($e.ColumnIndex -ge 8) { $script:Draw.MutedBrush } else { $script:Draw.TextBrush }
            $r = New-Object System.Drawing.RectangleF([single]($cell.X+9),[single]$cell.Y,[single]($cell.Width-14),[single]$cell.Height)
            $e.Graphics.DrawString($e.SubItem.Text,$script:BaseFont,$fgB,$r,$sf)
        }
    })
    $script:UI.ItemList = $lv
    $script:UI.SortColumn = 0; $script:UI.SortAscending = $true

    $lblEmpty = New-Object System.Windows.Forms.Label
    $lblEmpty.Text = "No items configured yet.`r`n`r`nClick ""Add..."" below to start monitoring something."
    $lblEmpty.TextAlign = "MiddleCenter"; $lblEmpty.Dock = "Fill"; $lblEmpty.ForeColor = $script:Theme.Gray
    $lblEmpty.Font = New-Object System.Drawing.Font($script:BaseFont.FontFamily, 11)
    $lblEmpty.Visible = $false
    $script:UI.ItemListEmpty = $lblEmpty

    $listContainer.Controls.Add($lv); $listContainer.Controls.Add($lblEmpty)
    $tabItems.Controls.Add($listContainer); $tabItems.Controls.Add($toolbar); $tabItems.Controls.Add($summary)


    $tabEmail = New-Object System.Windows.Forms.TabPage; $tabEmail.Text="  Email  "; $tabEmail.BackColor=[System.Drawing.Color]::White
    # ---- Mail server -----------------------------------------------------
    $secSmtp = New-SettingsSection -Parent $tabEmail -X 22 -Y 14 -W 640 -BoxHeight 142 -Title "Mail server" -Description "Where Watchdog sends from"
    $l1=New-Object System.Windows.Forms.Label;$l1.Text="Server";$l1.Location=New-Object System.Drawing.Point(12,14);$l1.AutoSize=$true
    $txtSmtp=New-Object System.Windows.Forms.TextBox;$txtSmtp.Location=New-Object System.Drawing.Point(140,11);$txtSmtp.Size=New-Object System.Drawing.Size(300,24);$txtSmtp.Text=$script:Email.SmtpServer
    $l2=New-Object System.Windows.Forms.Label;$l2.Text="Port";$l2.Location=New-Object System.Drawing.Point(456,14);$l2.AutoSize=$true
    $numPort=New-Object System.Windows.Forms.NumericUpDown;$numPort.Minimum=1;$numPort.Maximum=65535;$numPort.Value=[int]$script:Email.SmtpPort;$numPort.Location=New-Object System.Drawing.Point(494,11);$numPort.Size=New-Object System.Drawing.Size(80,24)

    $l3=New-Object System.Windows.Forms.Label;$l3.Text="Username";$l3.Location=New-Object System.Drawing.Point(12,46);$l3.AutoSize=$true
    $txtUser=New-Object System.Windows.Forms.TextBox;$txtUser.Location=New-Object System.Drawing.Point(140,43);$txtUser.Size=New-Object System.Drawing.Size(300,24);$txtUser.Text=$script:Email.Username

    $l4=New-Object System.Windows.Forms.Label;$l4.Text="Password";$l4.Location=New-Object System.Drawing.Point(12,78);$l4.AutoSize=$true
    $txtPass=New-Object System.Windows.Forms.TextBox;$txtPass.Location=New-Object System.Drawing.Point(140,75);$txtPass.Size=New-Object System.Drawing.Size(300,24);$txtPass.UseSystemPasswordChar=$true
    if (-not [string]::IsNullOrWhiteSpace($script:Email.EncryptedPassword)) { $txtPass.Text="********"; $txtPass.Tag="unchanged" }
    $txtPass.Add_TextChanged({ param($s,$e) $s.Tag=$null })
    $chkSsl=New-Object System.Windows.Forms.CheckBox;$chkSsl.Text="Use SSL/TLS";$chkSsl.Location=New-Object System.Drawing.Point(456,77);$chkSsl.AutoSize=$true;$chkSsl.Checked=[bool]$script:Email.UseSSL
    # Surfaced up-front rather than only after a failed send - it's the single most
    # common reason a first-time setup doesn't work.
    $lblPassHint=New-Object System.Windows.Forms.Label;$lblPassHint.Text="Office 365 and Gmail need an app password here, not your normal sign-in password.";$lblPassHint.ForeColor=$script:Theme.TextMuted;$lblPassHint.Location=New-Object System.Drawing.Point(140,104);$lblPassHint.AutoSize=$true
    $secSmtp.Controls.AddRange(@($l1,$txtSmtp,$l2,$numPort,$l3,$txtUser,$l4,$txtPass,$chkSsl,$lblPassHint))

    # ---- Addresses -------------------------------------------------------
    $secAddr = New-SettingsSection -Parent $tabEmail -X 22 -Y 212 -W 640 -BoxHeight 122 -Title "Addresses" -Description ""
    $l5=New-Object System.Windows.Forms.Label;$l5.Text="Send from";$l5.Location=New-Object System.Drawing.Point(12,14);$l5.AutoSize=$true
    $txtFrom=New-Object System.Windows.Forms.TextBox;$txtFrom.Location=New-Object System.Drawing.Point(140,11);$txtFrom.Size=New-Object System.Drawing.Size(434,24);$txtFrom.Text=$script:Email.From
    $l6=New-Object System.Windows.Forms.Label;$l6.Text="Send to";$l6.Location=New-Object System.Drawing.Point(12,46);$l6.AutoSize=$true
    $txtTo=New-Object System.Windows.Forms.TextBox;$txtTo.Location=New-Object System.Drawing.Point(140,43);$txtTo.Size=New-Object System.Drawing.Size(434,24);$txtTo.Text=$script:Email.To
    $lblToHint=New-Object System.Windows.Forms.Label;$lblToHint.Text="Separate multiple recipients with a semicolon.";$lblToHint.ForeColor=$script:Theme.TextMuted;$lblToHint.Location=New-Object System.Drawing.Point(140,70);$lblToHint.AutoSize=$true
    $l7=New-Object System.Windows.Forms.Label;$l7.Text="Extra subject tag";$l7.Location=New-Object System.Drawing.Point(12,94);$l7.AutoSize=$true
    $txtPrefix=New-Object System.Windows.Forms.TextBox;$txtPrefix.Location=New-Object System.Drawing.Point(140,91);$txtPrefix.Size=New-Object System.Drawing.Size(160,24);$txtPrefix.Text=$script:Email.SubjectPrefix
    $lblPrefixHint=New-Object System.Windows.Forms.Label;$lblPrefixHint.Text="Optional - the app and machine name are already in the sender.";$lblPrefixHint.ForeColor=$script:Theme.TextMuted;$lblPrefixHint.Location=New-Object System.Drawing.Point(310,94);$lblPrefixHint.AutoSize=$true
    $secAddr.Controls.AddRange(@($l5,$txtFrom,$l6,$txtTo,$lblToHint,$l7,$txtPrefix,$lblPrefixHint))

    # ---- Check it works --------------------------------------------------
    $secTest = New-SettingsSection -Parent $tabEmail -X 22 -Y 370 -W 640 -BoxHeight 56 -Title "Check it works" -Description ""
    $btnTest=New-Object System.Windows.Forms.Button;$btnTest.Text="Send test email";$btnTest.Location=New-Object System.Drawing.Point(12,12);$btnTest.Size=New-Object System.Drawing.Size(150,30)
    $lblTest=New-Object System.Windows.Forms.Label;$lblTest.Location=New-Object System.Drawing.Point(176,19);$lblTest.AutoSize=$true
    $secTest.Controls.AddRange(@($btnTest,$lblTest))

    $script:UI.TxtSmtp=$txtSmtp;$script:UI.NumPort=$numPort;$script:UI.ChkSsl=$chkSsl;$script:UI.TxtUser=$txtUser;$script:UI.TxtPass=$txtPass
    $script:UI.TxtFrom=$txtFrom;$script:UI.TxtTo=$txtTo;$script:UI.TxtPrefix=$txtPrefix;$script:UI.LblTest=$lblTest;$script:UI.BtnTest=$btnTest

    $tabGen = New-Object System.Windows.Forms.TabPage; $tabGen.Text="  General  "; $tabGen.BackColor=[System.Drawing.Color]::White
    $tabGen.AutoScroll = $true   # grouped sections are taller than the window; let it scroll rather than cram

    # ---- Window and tray -------------------------------------------------
    $secTray = New-SettingsSection -Parent $tabGen -X 22 -Y 14 -W 640 -BoxHeight 94 -Title "Window and tray" -Description "How the app behaves on your desktop"
    $chkBalloon=New-Object System.Windows.Forms.CheckBox;$chkBalloon.Text="Show tray balloon notifications";$chkBalloon.Location=New-Object System.Drawing.Point(12,10);$chkBalloon.AutoSize=$true;$chkBalloon.Checked=[bool]$script:General.ShowBalloonTips
    $chkMin=New-Object System.Windows.Forms.CheckBox;$chkMin.Text="Minimize to tray when closing the window";$chkMin.Location=New-Object System.Drawing.Point(12,36);$chkMin.AutoSize=$true;$chkMin.Checked=[bool]$script:General.MinimizeToTrayOnClose
    $chkStartMin=New-Object System.Windows.Forms.CheckBox;$chkStartMin.Text="Start minimized";$chkStartMin.Location=New-Object System.Drawing.Point(12,62);$chkStartMin.AutoSize=$true;$chkStartMin.Checked=[bool]$script:General.StartMinimized
    $secTray.Controls.AddRange(@($chkBalloon,$chkMin,$chkStartMin))

    # ---- Alerting --------------------------------------------------------
    $secAlert = New-SettingsSection -Parent $tabGen -X 22 -Y 164 -W 640 -BoxHeight 176 -Title "Alerting" -Description "When and how often Watchdog emails you"
    $lblGrace=New-Object System.Windows.Forms.Label;$lblGrace.Text="Startup grace period after a reboot";$lblGrace.Location=New-Object System.Drawing.Point(12,13);$lblGrace.AutoSize=$true
    $numGrace=New-Object System.Windows.Forms.NumericUpDown;$numGrace.Minimum=0;$numGrace.Maximum=120;$numGrace.Value=[Math]::Min(120,[Math]::Max(0,[int]$script:General.StartupGraceMinutes));$numGrace.Location=New-Object System.Drawing.Point(400,10);$numGrace.Size=New-Object System.Drawing.Size(60,24)
    $lblGraceU=New-Object System.Windows.Forms.Label;$lblGraceU.Text="minutes";$lblGraceU.ForeColor=$script:Theme.TextMuted;$lblGraceU.Location=New-Object System.Drawing.Point(468,13);$lblGraceU.AutoSize=$true
    $lblGraceH=New-Object System.Windows.Forms.Label;$lblGraceH.Text="After a real reboot, hold off on alerts and auto-restarts while things start up. 0 turns this off.";$lblGraceH.ForeColor=$script:Theme.TextMuted;$lblGraceH.Location=New-Object System.Drawing.Point(12,34);$lblGraceH.AutoSize=$true

    $lblBatch=New-Object System.Windows.Forms.Label;$lblBatch.Text="Group alerts that happen close together";$lblBatch.Location=New-Object System.Drawing.Point(12,62);$lblBatch.AutoSize=$true
    $numBatch=New-Object System.Windows.Forms.NumericUpDown;$numBatch.Minimum=0;$numBatch.Maximum=600;$numBatch.Value=[Math]::Min(600,[Math]::Max(0,[int]$script:General.AlertBatchWindowSec));$numBatch.Location=New-Object System.Drawing.Point(400,59);$numBatch.Size=New-Object System.Drawing.Size(60,24)
    $lblBatchU=New-Object System.Windows.Forms.Label;$lblBatchU.Text="seconds";$lblBatchU.ForeColor=$script:Theme.TextMuted;$lblBatchU.Location=New-Object System.Drawing.Point(468,62);$lblBatchU.AutoSize=$true
    $lblBatchH=New-Object System.Windows.Forms.Label;$lblBatchH.Text="If several things fail at once, send one combined email instead of several. 0 sends each immediately.";$lblBatchH.ForeColor=$script:Theme.TextMuted;$lblBatchH.Location=New-Object System.Drawing.Point(12,83);$lblBatchH.AutoSize=$true

    $lblRestartNotify=New-Object System.Windows.Forms.Label;$lblRestartNotify.Text="Notify when this server restarts";$lblRestartNotify.Location=New-Object System.Drawing.Point(12,111);$lblRestartNotify.AutoSize=$true
    $cmbRestartNotify=New-Object System.Windows.Forms.ComboBox;$cmbRestartNotify.DropDownStyle="DropDownList";$cmbRestartNotify.Location=New-Object System.Drawing.Point(400,108);$cmbRestartNotify.Size=New-Object System.Drawing.Size(200,24)
    [void]$cmbRestartNotify.Items.AddRange(@("Off","Unexpected outages only","All restarts"))
    $cmbRestartNotify.SelectedItem = switch ("$($script:General.RestartNotifyMode)") { 'UnexpectedOnly' { "Unexpected outages only" } 'All' { "All restarts" } default { "Off" } }

    $chkHb=New-Object System.Windows.Forms.CheckBox;$chkHb.Text="Send a daily heartbeat email at";$chkHb.Location=New-Object System.Drawing.Point(12,144);$chkHb.AutoSize=$true;$chkHb.Checked=[bool]$script:General.DailyHeartbeat
    $numHb=New-Object System.Windows.Forms.NumericUpDown;$numHb.Minimum=0;$numHb.Maximum=23;$numHb.Value=[Math]::Min(23,[Math]::Max(0,[int]$script:General.HeartbeatHour));$numHb.Location=New-Object System.Drawing.Point(400,141);$numHb.Size=New-Object System.Drawing.Size(60,24)
    $lblHbU=New-Object System.Windows.Forms.Label;$lblHbU.Text=":00  - confirms Watchdog itself is still alive";$lblHbU.ForeColor=$script:Theme.TextMuted;$lblHbU.Location=New-Object System.Drawing.Point(468,144);$lblHbU.AutoSize=$true
    $secAlert.Controls.AddRange(@($lblGrace,$numGrace,$lblGraceU,$lblGraceH,$lblBatch,$numBatch,$lblBatchU,$lblBatchH,$lblRestartNotify,$cmbRestartNotify,$chkHb,$numHb,$lblHbU))

    # ---- Start with Windows ---------------------------------------------
    $secBoot = New-SettingsSection -Parent $tabGen -X 22 -Y 396 -W 640 -BoxHeight 92 -Title "Start with Windows" -Description "Runs as SYSTEM at boot, before anyone logs in - no password needed"
    $lblBoot=New-Object System.Windows.Forms.Label;$lblBoot.Location=New-Object System.Drawing.Point(12,12);$lblBoot.AutoSize=$true;$lblBoot.Font=$script:BoldFont
    $btnBootInstall=New-Object System.Windows.Forms.Button;$btnBootInstall.Text="Install startup task";$btnBootInstall.Location=New-Object System.Drawing.Point(12,38);$btnBootInstall.Size=New-Object System.Drawing.Size(160,32)
    $btnBootRemove=New-Object System.Windows.Forms.Button;$btnBootRemove.Text="Remove startup task";$btnBootRemove.Location=New-Object System.Drawing.Point(182,38);$btnBootRemove.Size=New-Object System.Drawing.Size(160,32)
    $chkStartup=New-Object System.Windows.Forms.CheckBox;$chkStartup.Text="Also run at my login (shows the tray icon)";$chkStartup.Location=New-Object System.Drawing.Point(360,45);$chkStartup.AutoSize=$true;$chkStartup.Checked=[bool]$script:General.RunAtStartup
    $secBoot.Controls.AddRange(@($lblBoot,$btnBootInstall,$btnBootRemove,$chkStartup))

    # ---- This machine ----------------------------------------------------
    $secMachine = New-SettingsSection -Parent $tabGen -X 22 -Y 544 -W 640 -BoxHeight 62 -Title "This machine" -Description ""
    $lblInst=New-Object System.Windows.Forms.Label;$lblInst.Text="Name shown in alert emails";$lblInst.Location=New-Object System.Drawing.Point(12,14);$lblInst.AutoSize=$true
    $txtInstance=New-Object System.Windows.Forms.TextBox;$txtInstance.Location=New-Object System.Drawing.Point(400,11);$txtInstance.Size=New-Object System.Drawing.Size(200,24);$txtInstance.Text=$script:General.InstanceName
    # Hint sits UNDERNEATH with the full box width to itself - the old right-hand position
    # had ~30px of room and clipped to just "blank". It also states the resolved value
    # rather than pointing at an empty box.
    $lblInstHint=New-Object System.Windows.Forms.Label;$lblInstHint.ForeColor=$script:Theme.TextMuted;$lblInstHint.Location=New-Object System.Drawing.Point(12,38);$lblInstHint.AutoSize=$true
    $lblInstHint.Text="Leave blank to use the computer name. Alerts will say: Watchdog ($(Get-InstanceName))"
    $txtInstance.Add_TextChanged({
        $shown = if ([string]::IsNullOrWhiteSpace($script:UI.TxtInstance.Text)) { $env:COMPUTERNAME } else { $script:UI.TxtInstance.Text.Trim() }
        $script:UI.LblInstHint.Text = "Leave blank to use the computer name. Alerts will say: Watchdog ($shown)"
    })
    $secMachine.Controls.AddRange(@($lblInst,$txtInstance,$lblInstHint))
    $script:UI.LblInstHint=$lblInstHint

    # ---- Advanced --------------------------------------------------------
    $secAdv = New-SettingsSection -Parent $tabGen -X 22 -Y 638 -W 640 -BoxHeight 148 -Title "Advanced" -Description "Leave these alone unless you need them"
    $lg=New-Object System.Windows.Forms.Label;$lg.Text="Scheduler tick interval";$lg.Location=New-Object System.Drawing.Point(12,13);$lg.AutoSize=$true
    $numRes=New-Object System.Windows.Forms.NumericUpDown;$numRes.Minimum=1;$numRes.Maximum=60;$numRes.Value=[Math]::Max(1,[int]$script:General.SchedulerResolutionSec);$numRes.Location=New-Object System.Drawing.Point(400,10);$numRes.Size=New-Object System.Drawing.Size(60,24)
    $lgHint=New-Object System.Windows.Forms.Label;$lgHint.Text="seconds  (how often it wakes to look for due checks)";$lgHint.ForeColor=$script:Theme.TextMuted;$lgHint.Location=New-Object System.Drawing.Point(468,13);$lgHint.AutoSize=$true

    $chkExperimental=New-Object System.Windows.Forms.CheckBox;$chkExperimental.Text="Show experimental monitor types";$chkExperimental.Location=New-Object System.Drawing.Point(12,46);$chkExperimental.AutoSize=$true;$chkExperimental.Checked=[bool]$script:General.ExperimentalFeaturesEnabled
    $lblExpHint=New-Object System.Windows.Forms.Label;$lblExpHint.Text="Adds VM service and VM process (Hyper-V) to the monitor type list. These need guest`r`ncredentials and are less tested than the rest.";$lblExpHint.ForeColor=$script:Theme.TextMuted;$lblExpHint.Location=New-Object System.Drawing.Point(30,68);$lblExpHint.AutoSize=$true

    $btnExport=New-Object System.Windows.Forms.Button;$btnExport.Text="Export config...";$btnExport.Location=New-Object System.Drawing.Point(12,108);$btnExport.Size=New-Object System.Drawing.Size(150,30)
    $btnImport=New-Object System.Windows.Forms.Button;$btnImport.Text="Import config...";$btnImport.Location=New-Object System.Drawing.Point(172,108);$btnImport.Size=New-Object System.Drawing.Size(150,30)
    $btnOpenCfg=New-Object System.Windows.Forms.Button;$btnOpenCfg.Text="Open config folder";$btnOpenCfg.Location=New-Object System.Drawing.Point(332,108);$btnOpenCfg.Size=New-Object System.Drawing.Size(160,30)
    $secAdv.Controls.AddRange(@($lg,$numRes,$lgHint,$chkExperimental,$lblExpHint,$btnExport,$btnImport,$btnOpenCfg))

    $lblCfg=New-Object System.Windows.Forms.Label;$lblCfg.Text="Config folder: $script:ConfigDir";$lblCfg.ForeColor=$script:Theme.TextMuted;$lblCfg.Location=New-Object System.Drawing.Point(22,796);$lblCfg.AutoSize=$true
    $tabGen.Controls.Add($lblCfg)

    $script:UI.NumRes=$numRes;$script:UI.ChkBalloon=$chkBalloon;$script:UI.ChkMin=$chkMin;$script:UI.ChkStartMin=$chkStartMin;$script:UI.ChkStartup=$chkStartup
    $script:UI.ChkHb=$chkHb;$script:UI.NumHb=$numHb;$script:UI.TxtInstance=$txtInstance;$script:UI.NumGrace=$numGrace;$script:UI.NumBatch=$numBatch;$script:UI.CmbRestartNotify=$cmbRestartNotify
    $script:UI.ChkExperimental=$chkExperimental
    $script:UI.LblBoot=$lblBoot;$script:UI.BtnBootInstall=$btnBootInstall;$script:UI.BtnBootRemove=$btnBootRemove;$script:UI.BtnExport=$btnExport;$script:UI.BtnImport=$btnImport;$script:UI.BtnOpenCfg=$btnOpenCfg

    $tabLog = New-Object System.Windows.Forms.TabPage; $tabLog.Text="  Log  "; $tabLog.BackColor=[System.Drawing.Color]::White
    $logBar = New-Object System.Windows.Forms.Panel; $logBar.Dock="Top"; $logBar.Height=44; $logBar.BackColor=[System.Drawing.Color]::White
    $txtLogFilter = New-Object System.Windows.Forms.TextBox; $txtLogFilter.Location=New-Object System.Drawing.Point(14,9); $txtLogFilter.Size=New-Object System.Drawing.Size(300,24)
    $btnLogCopy = New-Object System.Windows.Forms.Button; $btnLogCopy.Text="Copy"; $btnLogCopy.Location=New-Object System.Drawing.Point(324,8); $btnLogCopy.Size=New-Object System.Drawing.Size(80,26)
    $btnLogOpen = New-Object System.Windows.Forms.Button; $btnLogOpen.Text="Open log file"; $btnLogOpen.Location=New-Object System.Drawing.Point(412,8); $btnLogOpen.Size=New-Object System.Drawing.Size(110,26)
    $chkLogFollow = New-Object System.Windows.Forms.CheckBox; $chkLogFollow.Text="Follow new entries"; $chkLogFollow.Location=New-Object System.Drawing.Point(534,12); $chkLogFollow.AutoSize=$true; $chkLogFollow.Checked=$true
    $logBar.Controls.AddRange(@($txtLogFilter,$btnLogCopy,$btnLogOpen,$chkLogFollow))

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.ReadOnly=$true; $logBox.Dock="Fill"; $logBox.Font=New-Object System.Drawing.Font("Consolas",9)
    $logBox.BackColor=[System.Drawing.Color]::White; $logBox.BorderStyle="None"; $logBox.ForeColor=$script:Theme.Text
    $logBox.DetectUrls=$false
    $tabLog.Controls.Add($logBox); $tabLog.Controls.Add($logBar)
    $script:UI.LogBox=$logBox; $script:UI.TxtLogFilter=$txtLogFilter; $script:UI.ChkLogFollow=$chkLogFollow

    $btnLogCopy.Add_Click({
        try { if ($script:UI.LogBox.TextLength -gt 0) { [System.Windows.Forms.Clipboard]::SetText($script:UI.LogBox.Text) } } catch { }
    })
    $btnLogOpen.Add_Click({
        try { Start-Process notepad.exe -ArgumentList "`"$($script:LogPath)`"" } catch { Write-Log "Could not open the log file: $($_.Exception.Message)" }
    })
    # Filtering re-reads the file rather than trying to unpick the RichTextBox, so the
    # colours stay correct and nothing is lost when the filter is cleared.
    $txtLogFilter.Add_TextChanged({ Reload-LogView })

    $tabHelp = New-Object System.Windows.Forms.TabPage; $tabHelp.Text="  Help  "; $tabHelp.BackColor=[System.Drawing.Color]::White
    $rtbHelp = New-Object System.Windows.Forms.RichTextBox
    $rtbHelp.Dock="Fill"; $rtbHelp.ReadOnly=$true; $rtbHelp.BorderStyle="None"; $rtbHelp.BackColor=[System.Drawing.Color]::White
    $rtbHelp.Font = $script:BaseFont; $rtbHelp.DetectUrls = $false
    Populate-HelpText -Box $rtbHelp
    $helpBottom = New-Object System.Windows.Forms.Panel; $helpBottom.Dock="Bottom"; $helpBottom.Height=44; $helpBottom.BackColor=$script:Theme.Panel
    $btnOpenConfigFolder = New-Object System.Windows.Forms.Button
    $btnOpenConfigFolder.Text = "Open Config Folder"; $btnOpenConfigFolder.Location = New-Object System.Drawing.Point(14,7); $btnOpenConfigFolder.Size = New-Object System.Drawing.Size(160,30)
    $btnOpenConfigFolder.Add_Click({ try { Start-Process explorer.exe -ArgumentList "`"$($script:ConfigDir)`"" } catch { } })
    $helpBottom.Controls.Add($btnOpenConfigFolder)
    $tabHelp.Controls.Add($rtbHelp); $tabHelp.Controls.Add($helpBottom)

    $tabs.Controls.AddRange(@($tabItems,$tabEmail,$tabGen,$tabLog,$tabHelp))

    $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock="Bottom"; $bottom.Height=50; $bottom.BackColor=$script:Theme.FooterBg
    $btnSave=New-Object System.Windows.Forms.Button;$btnSave.Text="Save settings";$btnSave.Location=New-Object System.Drawing.Point(14,9);$btnSave.Size=New-Object System.Drawing.Size(140,32)
    Set-FlatButton -Button $btnSave -Primary
    $btnHide=New-Object System.Windows.Forms.Button;$btnHide.Text="Minimize to tray";$btnHide.Location=New-Object System.Drawing.Point(164,9);$btnHide.Size=New-Object System.Drawing.Size(140,32)
    Set-FlatButton -Button $btnHide -Dark
    $statusBar=New-Object System.Windows.Forms.Label;$statusBar.AutoSize=$true;$statusBar.Location=New-Object System.Drawing.Point(320,18);$statusBar.ForeColor=$script:Theme.FooterText;$statusBar.Font=$script:BaseFont
    $ftRight=New-Object System.Windows.Forms.Panel;$ftRight.Dock="Right";$ftRight.Width=90;$ftRight.BackColor=$script:Theme.FooterBg
    $lblVer=New-Object System.Windows.Forms.Label;$lblVer.Text="v$($script:AppVersion)";$lblVer.ForeColor=$script:Theme.FooterText;$lblVer.Font=$script:BaseFont
    $lblVer.AutoSize=$false;$lblVer.TextAlign="MiddleRight";$lblVer.Size=New-Object System.Drawing.Size(72,18);$lblVer.Location=New-Object System.Drawing.Point(4,18)
    $ftRight.Controls.Add($lblVer)
    $bottom.Controls.AddRange(@($btnSave,$btnHide,$statusBar)); $bottom.Controls.Add($ftRight); $script:UI.StatusBar=$statusBar

    $form.Controls.Add($tabs); $form.Controls.Add($bottom); $form.Controls.Add($header)

    # Buffer every container that repaints during a resize drag, not just the list.
    foreach ($c in @($form,$tabs,$tabItems,$tabGen,$tabEmail,$tabLog,$tabHelp,$summary,$toolbar,$header,$bottom,$listContainer)) {
        if ($c) { Set-DoubleBuffered -Control $c }
    }
    # Freeze layout while the window edge is being dragged, then do one repaint at the
    # end - otherwise every mouse-move retriggers a full owner-drawn relayout.
    $form.Add_ResizeBegin({ $script:UI.Form.SuspendLayout() })
    $form.Add_ResizeEnd({
        $script:UI.Form.ResumeLayout($true)
        if ($script:UI.ItemList) { $script:UI.ItemList.Refresh() }
    })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mOpen=$menu.Items.Add("Open Dashboard"); $mCheck=$menu.Items.Add("Check Now"); [void]$menu.Items.Add("-")
    $mPause=$menu.Items.Add("Pause Monitoring"); $mPause.CheckOnClick=$true; [void]$menu.Items.Add("-"); $mExit=$menu.Items.Add("Exit")
    if (-not $script:IsPrimaryInstance) { $mCheck.Enabled=$false; $mPause.Enabled=$false }
    $tray = New-Object System.Windows.Forms.NotifyIcon; $tray.Text="Watchdog - starting"; $tray.Icon=$script:Icons['Gray']; $tray.ContextMenuStrip=$menu; $tray.Visible=$true
    $script:UI.Tray=$tray

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval=[Math]::Max(1,[int]$script:General.SchedulerResolutionSec)*1000
    $timer.Add_Tick({ Invoke-SchedulerTick }); $script:UI.Timer=$timer

    $btnAdd.Add_Click({
        $n = Show-ItemEditor -Existing $null
        if ($n) { [void]$script:Items.Add($n); Ensure-ItemState -Item $n; $script:ItemState[$n.Id].NextCheckTime=Get-Date; Write-Log "Added: $($n.Name)"; Save-AppConfig; Invoke-SchedulerTick }
    })
    $btnEdit.Add_Click({
        if ($script:UI.ItemList.SelectedItems.Count -eq 0) { return }
        $id=$script:UI.ItemList.SelectedItems[0].Tag
        $ex=$script:Items | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $ex) { return }
        $u=Show-ItemEditor -Existing $ex
        if ($u) { for($i=0;$i -lt $script:Items.Count;$i++){ if($script:Items[$i].Id -eq $id){ $script:Items[$i]=$u; break } }; Write-Log "Edited: $($u.Name)"; Save-AppConfig; Invoke-CheckAllNow }
    })
    $script:UI.ItemList.Add_DoubleClick({ $script:UI.BtnEdit.PerformClick() })

    # Right-click selects the row under the cursor first (ListView doesn't do this on
    # its own), so the context menu always acts on the row you actually clicked.
    $script:UI.ItemList.Add_MouseUp({ param($s,$e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            $hit = $script:UI.ItemList.HitTest($e.X, $e.Y)
            if ($hit.Item -and -not $hit.Item.Selected) {
                $script:UI.ItemList.SelectedItems.Clear() | Out-Null
                $hit.Item.Selected = $true
            }
        }
    })

    $btnDup.Add_Click({
        if ($script:UI.ItemList.SelectedItems.Count -eq 0) { return }
        $ids = @($script:UI.ItemList.SelectedItems | ForEach-Object { $_.Tag })
        $copied = 0
        foreach ($id in $ids) {
            $ex = $script:Items | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if (-not $ex) { continue }
            $clone = $ex | Select-Object *
            $clone.Id = [guid]::NewGuid().ToString()
            $clone.Name = "$($ex.Name) (copy)"
            [void]$script:Items.Add($clone); Ensure-ItemState -Item $clone
            $copied++
        }
        if ($copied -gt 0) { Write-Log "Duplicated $copied item(s)."; Save-AppConfig; Update-Dashboard }
    })

    $removeSelected = {
        if ($script:UI.ItemList.SelectedItems.Count -eq 0) { return }
        $ids = @($script:UI.ItemList.SelectedItems | ForEach-Object { $_.Tag })
        $names = @($script:Items | Where-Object { $_.Id -in $ids } | ForEach-Object { $_.Name })
        $prompt = if ($ids.Count -eq 1) { "Remove '$($names[0])'?" } else { "Remove $($ids.Count) items?`r`n`r`n$($names -join "`r`n")" }
        if ([System.Windows.Forms.MessageBox]::Show($prompt,"Confirm","YesNo","Question") -eq [System.Windows.Forms.DialogResult]::Yes) {
            $keep=New-Object System.Collections.ArrayList
            foreach($x in $script:Items){ if($x.Id -notin $ids){[void]$keep.Add($x)} }
            $script:Items=$keep
            foreach ($id in $ids) { $script:ItemState.Remove($id) }
            Write-Log "Removed $($ids.Count) item(s)."; Save-AppConfig; Update-Dashboard
        }
    }
    $btnRemove.Add_Click($removeSelected)
    $miRemove.Add_Click($removeSelected)

    $btnEnableSel.Add_Click({ Set-SelectedItemsEnabled -NewEnabled $true })
    $btnDisableSel.Add_Click({ Set-SelectedItemsEnabled -NewEnabled $false })
    $miEnable.Add_Click({ Set-SelectedItemsEnabled -NewEnabled $true })
    $miDisable.Add_Click({ Set-SelectedItemsEnabled -NewEnabled $false })
    $miEdit.Add_Click({ $script:UI.BtnEdit.PerformClick() })
    $miDup.Add_Click({ $script:UI.BtnDup.PerformClick() })
    $miCheckNow.Add_Click({ Invoke-CheckAllNow })

    $txtFilter.Add_TextChanged({ Update-Dashboard })

    $script:UI.ItemList.Add_ColumnClick({ param($s,$e)
        if ($script:UI.SortColumn -eq $e.Column) { $script:UI.SortAscending = -not $script:UI.SortAscending }
        else { $script:UI.SortColumn = $e.Column; $script:UI.SortAscending = $true }
        Update-Dashboard
    })

    $btnCheck.Add_Click({ Invoke-CheckAllNow })
    $mCheck.Add_Click({ Invoke-CheckAllNow })

    $btnTest.Add_Click({
        Apply-EmailFromUI
        $script:UI.BtnTest.Enabled = $false
        $script:UI.LblTest.ForeColor=$script:Theme.Text; $script:UI.LblTest.Text="Sending..."
        $testDetails = [ordered]@{ "Sent at" = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); "Machine" = (Get-InstanceName) }
        Send-AlertEmail -Status "TEST" -ItemName "Watchdog" -Details $testDetails -Note "If you can read this, your email settings are working." -Kind 'Test'
    })

    $btnSave.Add_Click({
        $script:General.SchedulerResolutionSec=[int]$script:UI.NumRes.Value
        $script:General.ShowBalloonTips=$script:UI.ChkBalloon.Checked
        $script:General.MinimizeToTrayOnClose=$script:UI.ChkMin.Checked
        $script:General.StartMinimized=$script:UI.ChkStartMin.Checked
        $script:General.RunAtStartup=$script:UI.ChkStartup.Checked
        $script:General.DailyHeartbeat=$script:UI.ChkHb.Checked
        $script:General.HeartbeatHour=[int]$script:UI.NumHb.Value
        $script:General.InstanceName=$script:UI.TxtInstance.Text.Trim()
        $script:General.StartupGraceMinutes=[int]$script:UI.NumGrace.Value
        $script:General.AlertBatchWindowSec=[int]$script:UI.NumBatch.Value
        $script:General.RestartNotifyMode = switch ("$($script:UI.CmbRestartNotify.SelectedItem)") { "Unexpected outages only" { 'UnexpectedOnly' } "All restarts" { 'All' } default { 'Off' } }
        $script:General.ExperimentalFeaturesEnabled = [bool]$script:UI.ChkExperimental.Checked
        Apply-EmailFromUI
        Save-AppConfig; Set-StartupRegistration -Enable $script:General.RunAtStartup
        $script:UI.Timer.Stop(); $script:UI.Timer.Interval=[Math]::Max(1,[int]$script:General.SchedulerResolutionSec)*1000; $script:UI.Timer.Start()
        Write-Log "Settings saved."; $script:UI.StatusBar.Text="Settings saved at $((Get-Date).ToString('HH:mm:ss'))"
    })

    $btnHide.Add_Click({ $script:UI.Form.Hide() })
    $mOpen.Add_Click({ $script:UI.Form.Show(); $script:UI.Form.WindowState="Normal"; $script:UI.Form.Activate() })
    $tray.Add_DoubleClick({ $script:UI.Form.Show(); $script:UI.Form.WindowState="Normal"; $script:UI.Form.Activate() })
    $mPause.Add_Click({ param($s,$e)
        $script:IsPaused=$s.Checked
        if ($script:IsPaused) { Write-Log "Monitoring paused."; $script:UI.StatusBar.Text="Paused." } else { Write-Log "Monitoring resumed."; Invoke-CheckAllNow }
        Update-Dashboard
    })
    $mExit.Add_Click({ $script:UI.Timer.Stop(); $script:UI.Tray.Visible=$false; $script:UI.Tray.Dispose(); $script:UI.Form.Tag="ExitRequested"; $script:UI.Form.Close(); [System.Windows.Forms.Application]::Exit() })

    $btnOpenCfg.Add_Click({ try { Start-Process explorer.exe -ArgumentList "`"$($script:ConfigDir)`"" } catch { Write-Log "Could not open config folder: $($_.Exception.Message)" } })

    $script:UI.BtnBootInstall.Add_Click({
        if (-not (Test-CanInstall)) {
            [System.Windows.Forms.MessageBox]::Show("This script is running from a pasted/typed console session, so it has no file to install.`r`n`r`nSave it first, for example as C:\Watchdog\Watchdog.ps1, then run that file (right-click - Run with PowerShell) and click Install again.","Save the script first","OK","Warning")|Out-Null
            return
        }
        # Make sure current settings are on disk first, so the headless instance has them.
        Apply-EmailFromUI; Save-AppConfig
        if (Install-BootTask) {
            [System.Windows.Forms.MessageBox]::Show("Installed and started.`r`n`r`nThe script was copied to $($script:DeployedPs1) and a scheduled task now runs it as SYSTEM at every Windows startup - no password needed, and it keeps working even if your account password changes later.`r`n`r`nIt runs headless (no tray icon) in that mode - alerts, restarts, cert checks and the heartbeat all work. Edit settings in this GUI and Save; the background copy reloads them.`r`n`r`nTip: close this GUI when done configuring, to avoid duplicate alerts.","Startup task","OK","Information")|Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("Could not create the startup task. You must accept the UAC prompt and enter your Windows password. See the Log tab (and C:\Watchdog\install-result.txt) for the exact error.","Startup task","OK","Warning")|Out-Null
        }
        Update-BootStatus
    })
    $script:UI.BtnBootRemove.Add_Click({
        if (Remove-BootTask) { [System.Windows.Forms.MessageBox]::Show("Startup task removed.","Startup task","OK","Information")|Out-Null }
        else { [System.Windows.Forms.MessageBox]::Show("Could not remove the startup task (it may not exist, or admin rights were declined).","Startup task","OK","Warning")|Out-Null }
        Update-BootStatus
    })

    $script:UI.BtnExport.Add_Click({
        Apply-EmailFromUI
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Watchdog config (*.json)|*.json"; $sfd.FileName = "Watchdog-config.json"
        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Export-ConfigToFile -Path $sfd.FileName) {
                [System.Windows.Forms.MessageBox]::Show("Exported.`r`n`r`nCopy this file (and Watchdog.ps1) to each other machine, use Import Config there, re-enter passwords, and Save.","Export","OK","Information")|Out-Null
            } else { [System.Windows.Forms.MessageBox]::Show("Export failed - see the Log tab.","Export","OK","Warning")|Out-Null }
        }
    })
    $script:UI.BtnImport.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Watchdog config (*.json)|*.json|All files (*.*)|*.*"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if (Import-ConfigFromFile -Path $ofd.FileName) {
                Refresh-SettingsUI; Update-Dashboard
                [System.Windows.Forms.MessageBox]::Show("Imported $($script:Items.Count) item(s).`r`n`r`nNow re-enter your SMTP password (and any guest passwords in VM items), then click Save Settings.","Import","OK","Information")|Out-Null
            } else { [System.Windows.Forms.MessageBox]::Show("Import failed - see the Log tab.","Import","OK","Warning")|Out-Null }
        }
    })

    $form.Add_FormClosing({ param($eSender,$e)
        if ($script:UI.Form.Tag -ne "ExitRequested" -and $script:General.MinimizeToTrayOnClose) { $e.Cancel=$true; $script:UI.Form.Hide() }
    })
    # Watch the config file so a headless (boot/SYSTEM) instance picks up edits saved
    # by an interactive GUI instance without needing a restart.
    try {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $script:ConfigDir
        $watcher.Filter = "config.json"
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
        $onChange = {
            try {
                Start-Sleep -Milliseconds 400   # let the writer finish
                $script:UI.Form.Invoke([Action]{
                    Reload-AppConfig
                    $script:UI.Timer.Stop(); $script:UI.Timer.Interval=[Math]::Max(1,[int]$script:General.SchedulerResolutionSec)*1000; $script:UI.Timer.Start()
                    Invoke-CheckAllNow
                }) | Out-Null
            } catch { }
        }
        Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $onChange | Out-Null
        $watcher.EnableRaisingEvents = $true
        $script:UI.Watcher = $watcher
    } catch { Write-Log "Could not start config watcher: $($_.Exception.Message)" }

    # Keyboard shortcuts. KeyPreview lets the form see keys before the focused control,
    # so these work wherever you are on the Monitored items tab.
    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($sender,$e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::N) {
            $e.SuppressKeyPress = $true; $script:UI.BtnAdd.PerformClick()
        } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
            $e.SuppressKeyPress = $true
            if ($script:UI.BtnCheck -and $script:UI.BtnCheck.Enabled) { $script:UI.BtnCheck.PerformClick() }
        } elseif ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::F) {
            $e.SuppressKeyPress = $true
            if ($script:UI.TxtFilter) { $script:UI.TxtFilter.Focus() }
        }
    })

    $form.Add_Shown({
        if ($script:UI.Pill) { Set-RoundedRegion -Control $script:UI.Pill -Radius 14 }
        Update-Dashboard
        Update-BootStatus
        if ($script:General.StartMinimized) { $script:UI.Form.Hide() }
        if ($script:IsPrimaryInstance) {
            Invoke-CheckAllNow
            Write-Log "Watchdog started (watching $($script:Items.Count) item(s))."
        } else {
            Write-Log "Another Watchdog instance is already monitoring (likely the startup task) - this window is configuration-only. Checks and alerts are not run from here."
        }
        # Always start the timer, even when secondary - Complete-PendingSends still needs
        # to run periodically so a Test Email sent from a config-only window ever resolves
        # from "Sending..." to a result, even though no monitoring happens from here.
        $script:UI.Timer.Start()
    })
}

# ==================================================================
#  Main
# ==================================================================
if ($InstallTask) {
    Invoke-TaskInstall
    exit
} elseif ($Headless) {
    Load-AppConfig
    if (Test-AcquireMonitorLock) {
        Start-HeadlessLoop          # blocks forever; ended when the task is stopped
    } else {
        Write-Log "Another Watchdog instance is already monitoring - this headless launch is exiting to avoid duplicate checks/alerts."
        exit
    }
} else {
    Initialize-Icons
    Load-AppConfig
    Test-AcquireMonitorLock | Out-Null   # GUI always opens; it just won't poll/alert if it lost the race
    Build-MainWindow
    [System.Windows.Forms.Application]::Run($script:UI.Form)
}
