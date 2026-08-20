param(
    [Parameter(Mandatory = $true)][string]$Url,
    # Optional. If omitted, data lives under $HOME/yt-dlp same as before.
    # If given, ONLY the data (Archive Logs/, Youtube Videos/) moves here --
    # the pipeline install itself (scripts/, configs/) always stays at
    # $HOME/yt-dlp, since ytdl has to know where to find run_ytdlp.ps1 in
    # the first place, before any argument parsing can happen.
    [Parameter(Mandatory = $false)][string]$DataRoot = ""
)

# On PowerShell 7.3+, native-command stderr lines get wrapped as ErrorRecord
# objects when redirected (2>&1 below), which prints/logs them as noisy
# "NativeCommandError" blocks instead of yt-dlp's plain warning/error text.
# This restores plain-text passthrough. Applies the same on Linux as Windows.
$PSNativeCommandUseErrorActionPreference = $false

# --- Resolve roots ---
# $HOME is pwsh's own built-in automatic variable, cross-platform since
# PowerShell Core -- no hardcoded username anywhere, works for whatever
# account actually runs this.
$installRoot = Join-Path $HOME "yt-dlp"
$scriptsRoot = Join-Path $installRoot "scripts"
$configsRoot = Join-Path $installRoot "configs"
$confFile    = Join-Path $configsRoot "yt-dlp.conf"

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $dataRoot = $installRoot
} else {
    # Resolve to an absolute path up front. A relative path typed at the
    # shell (e.g. "downloads") would otherwise be interpreted relative to
    # pwsh's own working directory rather than anything predictable.
    $dataRoot = [System.IO.Path]::GetFullPath($DataRoot)
}

$archiveLogsRoot = Join-Path $dataRoot "Archive Logs"
$historyDir      = Join-Path $archiveLogsRoot "Archive History"
$logsDir         = Join-Path $archiveLogsRoot "Logs"
$logFile         = Join-Path $logsDir "download.log"
$archiveFile     = Join-Path $logsDir "archive.txt"
$videosRoot      = Join-Path $dataRoot "Youtube Videos"
$completeArchiveDir = Join-Path $videosRoot "Complete Archive"
$incompleteDir      = Join-Path $videosRoot "_incomplete"
$globalManifest  = Join-Path $videosRoot "global_manifest.json"

# --- Self-heal the folder structure (runs every invocation) ---
# If the whole tree (or any part of it) ever gets wiped -- a clean re-clone,
# an accidental rm -rf, starting fresh on a new disk, or just the first time
# a new -DataRoot is used -- this recreates every structural folder the
# pipeline depends on before doing anything else. Deliberately does NOT
# touch anything inside "Complete Archive" itself (each video's own folder
# is created on demand by yt-dlp's -o templates); this only guarantees the
# fixed, top-level scaffolding exists.
#
# $logsDir is created FIRST, and on its own, specifically so $logFile (which
# lives inside it) is guaranteed to already have a parent directory before
# any of the folder-recreation messages below try to log to it.
$recreatedFolders = @()
if (!(Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    $recreatedFolders += $logsDir
}
foreach ($d in @(
    $scriptsRoot,
    $configsRoot,
    $historyDir,
    $completeArchiveDir,
    $incompleteDir,
    (Join-Path $videosRoot "Pure Video"),
    (Join-Path $videosRoot "Final Video")
)) {
    if (!(Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $recreatedFolders += $d
    }
}
foreach ($d in $recreatedFolders) {
    "Recreated missing folder: $d" | Tee-Object -FilePath $logFile -Append
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

# --- Dependency updates/checks (throttled to once/day, not every run) ---
# Tied to $installRoot, not $dataRoot -- this is about the TOOLS themselves
# (yt-dlp/ffmpeg/pwsh), which are shared across every data root you might
# ever point -DataRoot at, so there's no reason to redo this check just
# because you switched download destinations.
#
# yt-dlp: safe, real, built-in self-update -- yt-dlp -U replaces its own exe
# in place and is designed for exactly this, identically on Linux. It no-ops
# harmlessly if yt-dlp was installed via a package manager that doesn't
# support self-update (e.g. apt) rather than the standalone binary.
#
# ffmpeg / pwsh: check-and-warn only, NOT auto-replace, same reasoning as the
# Windows version -- neither has a safe built-in self-update, and pwsh is the
# interpreter currently running this very script. On Ubuntu both are
# normally managed by apt, so this checks apt's own upgradable-package list
# rather than comparing against upstream release numbers, which wouldn't
# line up with Ubuntu's (older, distro-patched) package versions anyway.
# NOTE: this reads apt's existing local cache -- it does not run
# "apt update" itself, since that needs root and a background video-download
# script silently invoking sudo is not something to do unattended. Run
# "sudo apt update" yourself periodically for this check to stay accurate.
$updateThrottleMarker = Join-Path $installRoot ".last_dependency_check"
$updateThrottleHours = 24
$needsDependencyCheck = $true
# Wrapped in try/catch rather than a bare Test-Path/Get-Item pair: a real
# run hit a case where Test-Path reported the marker existed but Get-Item
# immediately after could not find it (root cause unconfirmed -- possibly
# a filesystem-level inconsistency from an earlier forced VM reboot; see
# the setup guide's note on "sudo reboot -f" -- but the fix doesn't depend
# on knowing why). Get-Item failing used to throw a non-terminating error
# that then cascaded into a SECOND error (subtracting from $null), and
# crucially, neither error was wrapped in Tee-Object -- they're both above
# where $logFile even starts being written to -- so they went straight to
# the terminal and never appeared in download.log at all. Any failure
# here now just falls back to the safe default (treat it as needing a
# fresh check) instead of crashing partway through, and gets logged
# properly instead of vanishing.
try {
    if (Test-Path $updateThrottleMarker) {
        $markerItem = Get-Item $updateThrottleMarker -ErrorAction Stop
        $age = (Get-Date) - $markerItem.LastWriteTime
        if ($age.TotalHours -lt $updateThrottleHours) { $needsDependencyCheck = $false }
    }
} catch {
    "  [dependency check] Could not read the throttle marker ($updateThrottleMarker) -- running the check anyway. Error: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
}

if ($needsDependencyCheck) {
    "-- Dependency check (throttled to once/$updateThrottleHours`h) --" | Tee-Object -FilePath $logFile -Append
    $updateOutput = & yt-dlp -U 2>&1
    $updateOutput | ForEach-Object { "  [yt-dlp -U] $_" | Tee-Object -FilePath $logFile -Append }

    $aptUpgradable = $null
    try {
        $aptUpgradable = & apt list --upgradable 2>$null
    } catch {
        "  [apt check] Could not query apt's upgradable-package list: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
    }
    if ($aptUpgradable) {
        if ($aptUpgradable -match '^powershell/') {
            "  WARNING: an apt update is available for powershell. Update at a natural stopping point with: sudo apt update && sudo apt install --only-upgrade powershell" | Tee-Object -FilePath $logFile -Append
        }
        if ($aptUpgradable -match '^ffmpeg/') {
            "  WARNING: an apt update is available for ffmpeg. Update at a natural stopping point with: sudo apt update && sudo apt install --only-upgrade ffmpeg" | Tee-Object -FilePath $logFile -Append
        }
    }

    Set-Content -Path $updateThrottleMarker -Value (Get-Date -Format "o")
}

# --- Versioned archival snapshot (#16): back up archive.txt + global manifest before this run ---
if (Test-Path $archiveFile)    { Copy-Item $archiveFile "$historyDir/archive_$timestamp.txt" }
if (Test-Path $globalManifest) { Copy-Item $globalManifest "$historyDir/global_manifest_$timestamp.json" }

$configVersion = $null
if (Test-Path $confFile) {
    $m = Select-String -Path $confFile -Pattern "CONFIG_VERSION:\s*(\S+)" | Select-Object -First 1
    if ($m) { $configVersion = $m.Matches[0].Groups[1].Value }
}
$ytDlpVersion  = (& yt-dlp --version) 2>$null
$ffmpegRaw     = (& ffmpeg -version) 2>$null
$ffmpegVersion = if ($ffmpegRaw) { ($ffmpegRaw -split "`n")[0] } else { $null }

"==== Download session started $timestamp ====" | Tee-Object -FilePath $logFile -Append
"yt-dlp: $ytDlpVersion | ffmpeg: $ffmpegVersion | config version: $configVersion" | Tee-Object -FilePath $logFile -Append
"URL: $Url" | Tee-Object -FilePath $logFile -Append
if ($DataRoot) { "Data root override: $dataRoot" | Tee-Object -FilePath $logFile -Append }

# --- Run yt-dlp, capturing stdout AND stderr (warnings/errors) into the log ---
# --ignore-config stops yt-dlp from also auto-loading any yt-dlp.conf it finds
# in the current directory, ~/.config/yt-dlp/, or next to the binary. Without
# it, a stray leftover config file anywhere on the auto-discovery path
# silently merges its own options (and any --exec lines) into every run.
#
# --download-archive, --paths, and --exec are passed here as CLI arguments
# rather than living inside yt-dlp.conf, specifically so they can vary with
# -DataRoot. yt-dlp.conf (loaded via --config-location) now only holds
# settings that never change between runs (format selection, retry/backoff
# tuning, etc) -- see the comment block at the top of that file for the
# full explanation. CLI arguments take precedence over the same setting in
# a --config-location file, so there's no conflict even though none of
# these four are present in yt-dlp.conf itself anymore.
$execCmd = "after_move:pwsh -NoProfile -File `"$scriptsRoot/postprocess.ps1`" -FilePath %(filepath)q"

# --js-runtimes also lives here rather than in yt-dlp.conf, for the same
# reason as the four above: it needs a real, resolved $HOME-based path
# (deno lives at $HOME/.local/bin/deno -- see setup.sh), and yt-dlp.conf
# is deliberately static, username-independent text with no per-user
# paths in it at all.
$denoPath = Join-Path $HOME ".local/bin/deno"

& yt-dlp `
    --ignore-config `
    --config-location $confFile `
    --download-archive $archiveFile `
    --paths "home:$completeArchiveDir" `
    --paths "temp:$incompleteDir" `
    --js-runtimes "deno:$denoPath" `
    --exec $execCmd `
    $Url 2>&1 | Tee-Object -FilePath $logFile -Append

"==== Download session finished $(Get-Date -Format o) ====" | Tee-Object -FilePath $logFile -Append
