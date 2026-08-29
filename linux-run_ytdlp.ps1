param(
    [Parameter(Mandatory = $true)][string]$Url,
    # Optional. If omitted, data lives under $HOME/yt-dlp same as before.
    # If given, ONLY the data (Archive Logs/, Youtube Videos/) moves here --
    # the pipeline install itself (scripts/, configs/) always stays at
    # $HOME/yt-dlp, since ytdl has to know where to find run_ytdlp.ps1 in
    # the first place, before any argument parsing can happen.
    [Parameter(Mandatory = $false)][string]$DataRoot = "",

    # --- Playlist/channel options ---
    # Deliberately NOT a separate script or a URL-type detection step.
    # yt-dlp's own extractor already knows whether a URL is a single video,
    # a playlist, or a channel far more reliably than any regex this script
    # could write, and every downstream step (the -o templates, the
    # --exec after_move hook, --download-archive, postprocess.ps1's
    # channel-info throttle) already operates per-video regardless of how
    # many videos are in the session. So a single video URL and a whole
    # channel URL take the exact same code path below -- these four
    # switches just add options that only matter once a session has more
    # than one video in it, and are no-ops (or harmless) on a single video.

    # Stops the run as soon as it hits a video ID already present in
    # --download-archive. Meant for periodic "channel sync" runs: re-running
    # against a channel/playlist you've mostly already archived otherwise
    # walks its ENTIRE upload history every time just to discover nothing's
    # new. Only safe to rely on for newest-first sources (a channel's
    # default /videos listing) -- if you've reordered or filtered the
    # source, --break-on-existing can stop before reaching genuinely new
    # videos further down the list.
    [Parameter(Mandatory = $false)][switch]$BreakOnExisting,

    # Passed straight through to yt-dlp's own --playlist-items, e.g.
    # "1-20" or "5,8,10-15". Only meaningful against a playlist/channel URL.
    [Parameter(Mandatory = $false)][string]$PlaylistItems = "",

    # Passed straight through to yt-dlp's own --dateafter, e.g. "20250101".
    # Useful for picking up a channel mid-history without re-walking
    # everything before a known point.
    [Parameter(Mandatory = $false)][string]$DateAfter = "",

    # Maps to yt-dlp's own --lazy-playlist: starts downloading as videos are
    # discovered instead of enumerating the entire playlist/channel listing
    # first. Matters on very large channels (hundreds+ of videos), where
    # eager enumeration is a long delay before the first byte of video ever
    # downloads. Harmless on a single video.
    [Parameter(Mandatory = $false)][switch]$LazyPlaylist
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
    # Same streaming-log fix as in postprocess.ps1: log each line as
    # yt-dlp -U produces it (a self-update download included) rather than
    # buffering the whole thing into a variable first.
    & yt-dlp -U 2>&1 | ForEach-Object { "  [yt-dlp -U] $_" | Tee-Object -FilePath $logFile -Append }

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
if ($BreakOnExisting -or $PlaylistItems -or $DateAfter -or $LazyPlaylist) {
    $optionNotes = @()
    if ($BreakOnExisting) { $optionNotes += "break-on-existing" }
    if ($PlaylistItems)   { $optionNotes += "playlist-items=$PlaylistItems" }
    if ($DateAfter)       { $optionNotes += "dateafter=$DateAfter" }
    if ($LazyPlaylist)    { $optionNotes += "lazy-playlist" }
    "Playlist/channel options: $($optionNotes -join ', ')" | Tee-Object -FilePath $logFile -Append
}

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

# --- Playlist/channel CLI args (only added when actually requested) ---
# Built as an array, not string-interpolated into $execCmd-style text, so
# an empty/unused option never contributes a stray blank argument to the
# yt-dlp call below -- @() splats to nothing when none of the switches or
# strings were supplied, making a single-video run byte-for-byte the same
# invocation as before these params existed.
$playlistArgs = @()
if ($BreakOnExisting) { $playlistArgs += "--break-on-existing" }
if ($PlaylistItems)   { $playlistArgs += @("--playlist-items", $PlaylistItems) }
if ($DateAfter)       { $playlistArgs += @("--dateafter", $DateAfter) }
if ($LazyPlaylist)    { $playlistArgs += "--lazy-playlist" }

# Captured into $sessionOutput via a chained Tee-Object -Variable, rather
# than `$sessionOutput = ... | Tee-Object -FilePath $logFile`. Assigning a
# pipeline straight to a variable captures ALL of its output into that
# variable instead of also letting it reach the console -- which would
# silently kill live progress output for the whole session (exactly the
# "looks hung, isn't" trap postprocess.ps1's comments pass already hit and
# fixed once; same principle applies here, just for the main download
# instead of the comments sub-pass). Chaining a second Tee-Object -FilePath
# after the -Variable one keeps both: the file gets written to, the
# console still streams live, and $sessionOutput is populated for the
# summary below.
& yt-dlp `
    --ignore-config `
    --config-location $confFile `
    --download-archive $archiveFile `
    --paths "home:$completeArchiveDir" `
    --paths "temp:$incompleteDir" `
    --js-runtimes "deno:$denoPath" `
    --exec $execCmd `
    @playlistArgs `
    $Url 2>&1 | Tee-Object -Variable sessionOutput | Tee-Object -FilePath $logFile -Append

# --- Session summary ---
# Best-effort, parsed from yt-dlp's own console text rather than any
# official yt-dlp API for this -- there isn't one. Most useful for
# playlist/channel sessions (where "how many of the 80 videos in this
# channel were actually new" isn't obvious from scrolling the log); for a
# single video it'll just read "1 video touched, 0 already archived".
$videosTouched   = @($sessionOutput | Select-String -Pattern '^\[youtube\] [\w-]{6,}: Downloading').Count
$archiveSkipped  = @($sessionOutput | Select-String -Pattern 'has already been recorded in the archive').Count
$sessionErrors   = @($sessionOutput | Select-String -Pattern '^ERROR:').Count
$sessionWarnings = @($sessionOutput | Select-String -Pattern '^WARNING:').Count
"-- Session summary: $videosTouched video(s) touched, $archiveSkipped already archived (skipped), $sessionErrors error(s), $sessionWarnings warning(s) --" | Tee-Object -FilePath $logFile -Append

"==== Download session finished $(Get-Date -Format o) ====" | Tee-Object -FilePath $logFile -Append
