param(
    [Parameter(Mandatory = $true)][string]$Url,
    # Optional. If omitted, data lives under the platform's default install
    # root (see the platform-resolution block below) same as before.
    # If given, ONLY the data (Archive Logs/, Youtube Videos/) moves here --
    # the pipeline install itself (scripts/, configs/) always stays at the
    # install root, since ytdl has to know where to find run_ytdlp.ps1 in
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
    # downloads. Harmless on a single video. IGNORED when -Workers > 1 (see
    # the -Workers comment below for why) -- a warning is logged if both
    # are given together, rather than silently dropping it.
    [Parameter(Mandatory = $false)][switch]$LazyPlaylist,

    # How many videos to download AT THE SAME TIME. Default 1 -- the
    # original, single-stream behavior, completely unchanged below.
    #
    # This is NOT the same as just running `ytdl` several times by hand in
    # different terminals. Doing that against the same channel/data root
    # races on several shared files this pipeline maintains
    # (channel_manifest.json, global_manifest.json, the Channel Info
    # refresh throttle, download.log itself) with no coordination between
    # the independent invocations -- postprocess.ps1 didn't used to be
    # written expecting more than one instance of itself to ever run
    # concurrently. -Workers > 1 is the supported way to get real
    # parallelism instead: it enumerates the full set of videos ONCE up
    # front (so no two workers can ever be assigned the same video --
    # there's no scheduling decision made independently by each worker
    # that could collide), then dispatches across a fixed-size pool using
    # PowerShell 7's native ForEach-Object -Parallel, one whole
    # download+postprocess pipeline per video. postprocess.ps1 itself has
    # matching changes (file locking around the shared manifest/Channel Info
    # writes, and a per-video log file instead of one shared download.log)
    # so those concurrent pipelines don't corrupt each other's output --
    # see postprocess.ps1's own comments for the locking details.
    #
    # Real, useful parallelism here is bounded by more than just CPU/disk:
    # every worker is also hitting YouTube's own infrastructure at the same
    # time, and this pipeline's pacing settings (--sleep-requests etc) were
    # tuned assuming ONE stream. A higher worker count multiplies your
    # aggregate request rate by that count, which raises real risk of
    # rate-limiting or a temporary block -- there's no universally "safe"
    # number this script can pick for you. Start low (2-4) against a
    # channel you don't mind re-running if something goes wrong, watch
    # download.log for warnings/403s, and only raise it if that stays clean.
    [Parameter(Mandatory = $false)][ValidateRange(1, 64)][int]$Workers = 1
)

# On PowerShell 7.3+, native-command stderr lines get wrapped as ErrorRecord
# objects when redirected (2>&1 below), which prints/logs them as noisy
# "NativeCommandError" blocks instead of yt-dlp's plain warning/error text.
# This restores plain-text passthrough. Applies identically on all three
# platforms.
$PSNativeCommandUseErrorActionPreference = $false

# =====================================================================
# PLATFORM RESOLUTION
# =====================================================================
# This is the ONLY place in this script that knows which OS it's on.
# Everything below this block is platform-agnostic and reads the variables
# set here. This file used to exist as two separate copies (a Windows one
# and a Linux one) that drifted badly apart -- the Windows copy sat ~29
# commits behind for a month, missing -DataRoot, the playlist switches,
# -Workers, deno support and the locking rework, because every feature had
# to be written twice and the second write kept not happening. One file
# with one small branch at the top is what stops that recurring.
#
# $IsWindows / $IsMacOS / $IsLinux are pwsh's own built-in automatic
# variables (PowerShell 6+), not something this script has to detect.
#
# Everything below is a DEFAULT: $env:YTDLP_INSTALL_ROOT overrides the
# install root on any platform, for anyone who wants the pipeline
# somewhere else entirely.
if ($IsWindows) {
    $platformName = "Windows"
    # Kept at the drive root rather than moved under $HOME (which pwsh does
    # resolve correctly on Windows) for two reasons. First, it's where the
    # existing Windows install already lives, so nothing has to move.
    # Second and more importantly, MAX_PATH: Windows still caps most paths
    # at 260 characters unless long-path support is explicitly enabled, and
    # this pipeline's per-video paths are genuinely long -- a 40-char
    # uploader folder, then a second folder repeating uploader + date + id
    # + a 60-char title, then "Pre-merge streams/Final Video.f137.mp4".
    # That lands near 240 characters before the data root is even prefixed.
    # "C:/yt-dlp" costs 9 of the budget; "C:/Users/<name>/yt-dlp" can
    # easily cost twice that and pushes real videos over the limit.
    $defaultInstallRoot = "C:/yt-dlp"
    # yt-dlp's Windows build appends .exe; deno's own installer puts it
    # under $HOME\.deno\bin rather than the ~/.local/bin convention used
    # on the Unix side.
    $denoCandidates = @(
        (Join-Path $HOME ".deno/bin/deno.exe"),
        (Join-Path $HOME ".local/bin/deno.exe")
    )
} elseif ($IsMacOS) {
    $platformName = "macOS"
    $defaultInstallRoot = Join-Path $HOME "yt-dlp"
    $denoCandidates = @(
        (Join-Path $HOME ".local/bin/deno"),
        (Join-Path $HOME ".deno/bin/deno"),
        "/opt/homebrew/bin/deno",
        "/usr/local/bin/deno"
    )
} else {
    $platformName = "Linux"
    $defaultInstallRoot = Join-Path $HOME "yt-dlp"
    $denoCandidates = @(
        (Join-Path $HOME ".local/bin/deno"),
        (Join-Path $HOME ".deno/bin/deno")
    )
}

$installRoot = if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $defaultInstallRoot
} else {
    $env:YTDLP_INSTALL_ROOT
}

$scriptsRoot = Join-Path $installRoot "scripts"
$configsRoot = Join-Path $installRoot "configs"
$confFile    = Join-Path $configsRoot "yt-dlp.conf"

# --js-runtimes lives here rather than in yt-dlp.conf, since it needs a
# real, resolved path (deno's install location differs per platform), and
# yt-dlp.conf is deliberately static, username- and path-independent text
# with no per-user paths in it at all.
#
# Resolved by probing the known install locations and then falling back to
# whatever is on PATH, rather than the old hardcoded single path. The
# hardcode was fine while this only ran on one platform with one installer,
# but it silently passed a non-existent path (and produced a confusing
# yt-dlp error rather than a clear one) any time deno had been installed
# somewhere else. If nothing is found, --js-runtimes is omitted entirely
# and a warning is logged -- yt-dlp still runs, just with the less reliable
# extraction fallback described in yt-dlp.conf.
$denoPath = $denoCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $denoPath) {
    $denoCommand = Get-Command deno -ErrorAction SilentlyContinue
    if ($denoCommand) { $denoPath = $denoCommand.Source }
}
# Wrapped in an outer @() so this is always a real array. PowerShell
# unrolls an if-expression's result through the pipeline, which turns an
# empty branch into $null and a one-element branch into a bare scalar.
# Splatting $null happens to behave the same as splatting an empty array,
# so this particular case worked by luck rather than by construction --
# but the same pattern bit the Windows launcher for real (see ytdl.ps1's
# $rest), so it is pinned down here too rather than left to chance.
$jsRuntimeArgs = @(if ($denoPath) { @("--js-runtimes", "deno:$denoPath") } else { @() })

# =====================================================================
# END PLATFORM RESOLUTION
# =====================================================================

# --- Resolve roots ---
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
# an accidental delete, starting fresh on a new disk, or just the first time
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
# yt-dlp: safe, real, built-in self-update -- yt-dlp -U replaces its own
# binary in place and is designed for exactly this, identically on all
# three platforms. It no-ops harmlessly if yt-dlp was installed via a
# package manager that doesn't support self-update (apt, Homebrew, winget)
# rather than the standalone binary.
#
# ffmpeg / pwsh: check-and-warn only, NOT auto-replace. Neither has a safe
# built-in self-update, and pwsh is the interpreter currently running this
# very script -- attempting to overwrite its own binary mid-session risks a
# locked-file failure or a broken install. What "check" means is
# necessarily platform-specific, since it's really a question about the
# package manager that owns those two binaries, so it's the one part of
# this script (besides the platform block itself) that has to branch.
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
    "-- Dependency check on $platformName (throttled to once/$updateThrottleHours`h) --" | Tee-Object -FilePath $logFile -Append
    # Same streaming-log fix as in postprocess.ps1: log each line as
    # yt-dlp -U produces it (a self-update download included) rather than
    # buffering the whole thing into a variable first.
    & yt-dlp -U 2>&1 | ForEach-Object { "  [yt-dlp -U] $_" | Tee-Object -FilePath $logFile -Append }

    if ($IsWindows) {
        # winget's own upgrade listing, filtered to the two packages this
        # pipeline actually cares about. Replaces the older approach of
        # querying the GitHub releases API for pwsh and gyan.dev's
        # release-version endpoint for ffmpeg: those compared against
        # UPSTREAM version numbers, which don't necessarily match what the
        # local package manager installed or can install, and they broke
        # whenever either site changed shape. winget already knows both
        # what's installed and what it can upgrade to.
        try {
            $wingetUpgradable = & winget upgrade --disable-interactivity 2>$null
            if ($wingetUpgradable) {
                if ($wingetUpgradable -match 'Microsoft\.PowerShell') {
                    "  WARNING: a winget update is available for PowerShell. Update at a natural stopping point with: winget upgrade --id Microsoft.PowerShell" | Tee-Object -FilePath $logFile -Append
                }
                if ($wingetUpgradable -match '(?i)ffmpeg') {
                    "  WARNING: a winget update is available for ffmpeg. Update at a natural stopping point with: winget upgrade --id Gyan.FFmpeg" | Tee-Object -FilePath $logFile -Append
                }
            }
        } catch {
            "  [winget check] Could not query winget's upgrade list: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
        }
    } elseif ($IsMacOS) {
        # Homebrew's own outdated list. Like apt below, this reads what brew
        # already knows rather than running "brew update" itself -- a
        # background download script silently refreshing package indexes
        # (and potentially triggering a long network stall mid-run) is not
        # something to do unattended. Run "brew update" yourself
        # periodically for this check to stay accurate.
        try {
            $brewOutdated = & brew outdated --quiet 2>$null
            if ($brewOutdated) {
                if ($brewOutdated -match '(?im)^powershell$') {
                    "  WARNING: a Homebrew update is available for powershell. Update at a natural stopping point with: brew update && brew upgrade --cask powershell" | Tee-Object -FilePath $logFile -Append
                }
                if ($brewOutdated -match '(?im)^ffmpeg$') {
                    "  WARNING: a Homebrew update is available for ffmpeg. Update at a natural stopping point with: brew update && brew upgrade ffmpeg" | Tee-Object -FilePath $logFile -Append
                }
            }
        } catch {
            "  [brew check] Could not query Homebrew's outdated list: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
        }
    } else {
        # On Ubuntu both are normally managed by apt, so this checks apt's
        # own upgradable-package list rather than comparing against upstream
        # release numbers, which wouldn't line up with Ubuntu's (older,
        # distro-patched) package versions anyway.
        # NOTE: this reads apt's existing local cache -- it does not run
        # "apt update" itself, since that needs root and a background
        # video-download script silently invoking sudo is not something to
        # do unattended. Run "sudo apt update" yourself periodically for
        # this check to stay accurate.
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
    }

    Set-Content -Path $updateThrottleMarker -Value (Get-Date -Format "o")
}

# --- Versioned archival snapshot (#16): back up archive.txt + global manifest before this run ---
if (Test-Path $archiveFile)    { Copy-Item $archiveFile (Join-Path $historyDir "archive_$timestamp.txt") }
if (Test-Path $globalManifest) { Copy-Item $globalManifest (Join-Path $historyDir "global_manifest_$timestamp.json") }

$configVersion = $null
if (Test-Path $confFile) {
    $m = Select-String -Path $confFile -Pattern "CONFIG_VERSION:\s*(\S+)" | Select-Object -First 1
    if ($m) { $configVersion = $m.Matches[0].Groups[1].Value }
}
$ytDlpVersion  = (& yt-dlp --version) 2>$null
$ffmpegRaw     = (& ffmpeg -version) 2>$null
$ffmpegVersion = if ($ffmpegRaw) { ($ffmpegRaw -split "`n")[0] } else { $null }

"==== Download session started $timestamp ====" | Tee-Object -FilePath $logFile -Append
"platform: $platformName | install root: $installRoot" | Tee-Object -FilePath $logFile -Append
"yt-dlp: $ytDlpVersion | ffmpeg: $ffmpegVersion | config version: $configVersion" | Tee-Object -FilePath $logFile -Append
"URL: $Url" | Tee-Object -FilePath $logFile -Append
if ($DataRoot) { "Data root override: $dataRoot" | Tee-Object -FilePath $logFile -Append }
if (-not $denoPath) {
    "WARNING: no deno binary found (looked in $($denoCandidates -join ', ') and on PATH). YouTube's JS challenge can't be solved without a JS runtime, which commonly shows up as mid-download HTTP 403 errors rather than an obvious 'no runtime' message. Install it and re-run setup, or see yt-dlp/yt-dlp#14404." | Tee-Object -FilePath $logFile -Append
}
if ($BreakOnExisting -or $PlaylistItems -or $DateAfter -or $LazyPlaylist -or ($Workers -gt 1)) {
    $optionNotes = @()
    if ($BreakOnExisting) { $optionNotes += "break-on-existing" }
    if ($PlaylistItems)   { $optionNotes += "playlist-items=$PlaylistItems" }
    if ($DateAfter)       { $optionNotes += "dateafter=$DateAfter" }
    if ($LazyPlaylist)    { $optionNotes += "lazy-playlist" }
    if ($Workers -gt 1)   { $optionNotes += "workers=$Workers" }
    "Playlist/channel options: $($optionNotes -join ', ')" | Tee-Object -FilePath $logFile -Append
}
if ($LazyPlaylist -and ($Workers -gt 1)) {
    "  NOTE: -LazyPlaylist has no effect combined with -Workers > 1 -- parallel dispatch already requires a full up-front listing (to build the worker queue), so there's no 'lazy' phase for it to skip." | Tee-Object -FilePath $logFile -Append
}

# --ignore-config (used in every yt-dlp invocation below, single-stream or
# parallel) stops yt-dlp from also auto-loading any yt-dlp.conf it finds in
# the current directory, the per-user config dir (~/.config/yt-dlp/ on
# Linux/macOS, %APPDATA%\yt-dlp\ on Windows), or next to the binary.
# Without it, a stray leftover config file anywhere on the auto-discovery
# path silently merges its own options (and any --exec lines) into every run.

if ($Workers -le 1) {
    # ============================================================
    # Single-stream path -- UNCHANGED from before -Workers existed.
    # ============================================================
    # --download-archive, --paths, and --exec are passed here as CLI
    # arguments rather than living inside yt-dlp.conf, specifically so they
    # can vary with -DataRoot. CLI arguments take precedence over the same
    # setting in a --config-location file, so there's no conflict even
    # though none of these are present in yt-dlp.conf itself anymore.
    #
    # The pwsh invocation inside --exec uses the bare command name "pwsh"
    # rather than a resolved absolute path: it's on PATH on all three
    # platforms by the time anything can call this script (the launcher
    # that got here was itself started by pwsh), and hardcoding a full path
    # would mean a fourth platform-specific value to keep correct.
    $execCmd = "after_move:pwsh -NoProfile -File `"$(Join-Path $scriptsRoot 'postprocess.ps1')`" -FilePath %(filepath)q -LogFileName `"download.log`""

    # Built as an array, not string-interpolated into $execCmd-style text,
    # so an empty/unused option never contributes a stray blank argument to
    # the yt-dlp call below -- @() splats to nothing when none of the
    # switches or strings were supplied, making a plain single-video run
    # byte-for-byte the same invocation as before these params existed.
    $playlistArgs = @()
    if ($BreakOnExisting) { $playlistArgs += "--break-on-existing" }
    if ($PlaylistItems)   { $playlistArgs += @("--playlist-items", $PlaylistItems) }
    if ($DateAfter)       { $playlistArgs += @("--dateafter", $DateAfter) }
    if ($LazyPlaylist)    { $playlistArgs += "--lazy-playlist" }

    # Captured into $sessionOutput via a chained Tee-Object -Variable,
    # rather than `$sessionOutput = ... | Tee-Object -FilePath $logFile`.
    # Assigning a pipeline straight to a variable captures ALL of its
    # output into that variable instead of also letting it reach the
    # console -- which would silently kill live progress output for the
    # whole session (exactly the "looks hung, isn't" trap postprocess.ps1's
    # comments pass already hit and fixed once; same principle applies
    # here, just for the main download instead of the comments sub-pass).
    # Chaining a second Tee-Object -FilePath after the -Variable one keeps
    # both: the file gets written to, the console still streams live, and
    # $sessionOutput is populated for the summary below.
    & yt-dlp `
        --ignore-config `
        --config-location $confFile `
        --download-archive $archiveFile `
        --paths "home:$completeArchiveDir" `
        --paths "temp:$incompleteDir" `
        @jsRuntimeArgs `
        --exec $execCmd `
        @playlistArgs `
        $Url 2>&1 | Tee-Object -Variable sessionOutput | Tee-Object -FilePath $logFile -Append

    # --- Session summary ---
    # Best-effort, parsed from yt-dlp's own console text rather than any
    # official yt-dlp API for this -- there isn't one. Most useful for
    # playlist/channel sessions (where "how many of the 80 videos in this
    # channel were actually new" isn't obvious from scrolling the log); for
    # a single video it'll just read "1 video touched, 0 already archived".
    # Counted by DISTINCT video id, NOT by counting matching lines.
    # yt-dlp prints SEVERAL "[youtube] <id>: Downloading ..." lines for a
    # single video -- webpage, player API JSON, m3u8 information, and so
    # on -- so a plain line count reported "3 video(s) touched" for a
    # one-video run (confirmed in a real download.log: three such lines,
    # all for the same id). It isn't a fixed multiplier that could just be
    # divided out, either: how many of those lines appear depends on which
    # client/extraction path yt-dlp happens to take that run. The id is
    # captured from each match and de-duplicated instead, which is exactly
    # one entry per video no matter how chatty extraction was.
    $videosTouched   = @($sessionOutput |
        Select-String -Pattern '^\[youtube\] ([\w-]{6,}): Downloading' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Sort-Object -Unique).Count
    $archiveSkipped  = @($sessionOutput | Select-String -Pattern 'has already been recorded in the archive').Count
    $sessionErrors   = @($sessionOutput | Select-String -Pattern '^ERROR:').Count
    $sessionWarnings = @($sessionOutput | Select-String -Pattern '^WARNING:').Count
    "-- Session summary: $videosTouched video(s) touched, $archiveSkipped already archived (skipped), $sessionErrors error(s), $sessionWarnings warning(s) --" | Tee-Object -FilePath $logFile -Append

} else {
    # ============================================================
    # Parallel path (-Workers > 1)
    # ============================================================
    # Step 1: enumerate the FULL set of videos ONE time, up front, into a
    # static, ordered list. This is what actually prevents two workers ever
    # downloading the same video: they're never each independently deciding
    # what to work on next (which is where a race would come from) -- they
    # only ever pull their next item from a list that was already fully
    # built before any worker started. --flat-playlist keeps this fast (it's
    # a metadata-only listing pass, no downloading), and works identically
    # whether $Url is a single video (returns exactly one id), a playlist,
    # or a channel. -PlaylistItems/-DateAfter are applied HERE, at listing
    # time, rather than passed to each per-video download below (a single
    # video URL has no "playlist items" to select) -- functionally
    # equivalent to how they'd filter a single-stream run, just applied at
    # a different point in the pipeline.
    "-- Enumerating videos for parallel dispatch ($Workers workers) --" | Tee-Object -FilePath $logFile -Append
    $enumArgs = @()
    if ($PlaylistItems) { $enumArgs += @("--playlist-items", $PlaylistItems) }
    if ($DateAfter)      { $enumArgs += @("--dateafter", $DateAfter) }
    $enumOutput = & yt-dlp --ignore-config --flat-playlist --skip-download --print "%(id)s" @enumArgs $Url 2>&1
    $enumOutput | ForEach-Object { "  [enumerate] $_" | Tee-Object -FilePath $logFile -Append }
    # yt-dlp's --print output is one id per line; anything else mixed into
    # 2>&1 (warnings, progress) won't match this shape, so a simple filter
    # is enough to separate real ids from everything else.
    $videoIds = @($enumOutput | Where-Object { $_ -match '^[\w-]{6,}$' })

    if ($videoIds.Count -eq 0) {
        "ERROR: Enumeration returned no video IDs -- nothing to dispatch. Check the [enumerate] lines above for the actual yt-dlp error." | Tee-Object -FilePath $logFile -Append
    } else {
        # -BreakOnExisting has no built-in equivalent for a --flat-playlist
        # listing pass (it only has meaning during an actual sequential
        # download walk, which this parallel path deliberately isn't
        # doing). Reproduced manually instead: read the existing archive
        # file, then truncate the enumerated list at the first id already
        # in it. Same newest-first assumption and same caveat as the
        # single-stream -BreakOnExisting: only correct if $videoIds is
        # already in newest-first order (true for a channel's default
        # /videos listing) -- reordered/filtered sources can stop before
        # reaching genuinely new videos further down.
        if ($BreakOnExisting -and (Test-Path $archiveFile)) {
            # archive.txt lines look like "<extractor> <id>" -- only the
            # last whitespace-separated field is the id itself.
            $archivedIds = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($line in (Get-Content $archiveFile)) {
                $parts = $line -split '\s+'
                if ($parts.Count -ge 2) { [void]$archivedIds.Add($parts[-1]) }
            }
            $cutIndex = -1
            for ($i = 0; $i -lt $videoIds.Count; $i++) {
                if ($archivedIds.Contains($videoIds[$i])) { $cutIndex = $i; break }
            }
            if ($cutIndex -ge 0) {
                $originalCount = $videoIds.Count
                # $cutIndex of 0 means the very first enumerated video is
                # already archived, i.e. nothing is new.
                #
                # This is a REAL BUG FIX, not a cross-platform adjustment.
                # The previous code was an unguarded
                # $videoIds[0..($cutIndex - 1)], which at $cutIndex = 0
                # evaluates the range 0..-1 -- and PowerShell reads a
                # descending range as "count DOWN", so 0..-1 is the two
                # indexes 0 and -1, i.e. the FIRST element and (because -1
                # means "from the end") the LAST one. Verified directly:
                # against ids (aaa,bbb,ccc) with $cutIndex = 0 it returned
                # (aaa,ccc) instead of nothing. So a --sync run whose newest
                # video was already archived -- the single most common case
                # for --sync, the "nothing new since last time" run -- did
                # not stop as intended. It queued the already-archived video
                # plus the OLDEST video in the listing, an unrelated video
                # picked purely by an off-by-one wrapping around the end of
                # the array. Only reachable with -Workers > 1, since the
                # single-stream path hands --break-on-existing to yt-dlp
                # itself rather than reimplementing it here.
                #
                # The outer @() is the same array-unrolling guard described
                # at $jsRuntimeArgs above: it keeps $videoIds an array in
                # both branches, instead of $null when empty and a bare
                # string when exactly one video is new.
                $videoIds = @(if ($cutIndex -eq 0) { @() } else { $videoIds[0..($cutIndex - 1)] })
                "  -BreakOnExisting: stopping at the first already-archived video -- $($videoIds.Count) of $originalCount enumerated video(s) are actually new." | Tee-Object -FilePath $logFile -Append
            }
        }

        "  $($videoIds.Count) video(s) queued, dispatching across $Workers worker(s)." | Tee-Object -FilePath $logFile -Append

        # Step 2: dispatch. ForEach-Object -Parallel is PowerShell 7's own
        # native parallel construct -- -ThrottleLimit is the actual "N at a
        # time" control. Each iteration runs in its own isolated runspace,
        # so anything from the outer scope it needs (paths, the archive
        # file, etc) has to be passed in explicitly via $using: -- plain
        # variable references from outside the block aren't visible inside
        # it the way they are in a normal (non-parallel) ForEach-Object.
        #
        # Each iteration gets its OWN log file, named after that specific
        # video's id -- trivially unique with no coordination needed
        # between workers (no shared counter, no PID juggling), and it
        # doubles as a readable label if you ever need to go find one
        # video's raw session output by hand. These per-video top-level log
        # files are NOT cleaned up automatically after postprocess.ps1
        # copies their content into that video's own video_complete.log --
        # deleting them automatically would work against this project's
        # own established preference for keeping real logs around as the
        # basis for diagnosis. On a very large channel they will
        # accumulate under Archive Logs/Logs/ (download.worker-<id>.log,
        # one per video) -- safe to delete by hand later, since everything
        # in them is duplicated into each video's own video_complete.log
        # once that video finishes successfully.
        $results = $videoIds | ForEach-Object -ThrottleLimit $Workers -Parallel {
            # Each -Parallel iteration runs in its own isolated runspace,
            # which does NOT inherit script-scope settings like this one
            # from the outer script (only $using: values cross that
            # boundary, and only for reading) -- without re-setting it
            # here, the noisy NativeCommandError stderr-wrapping this line
            # exists to suppress (see the top of this script) would come
            # back specifically inside parallel workers.
            $PSNativeCommandUseErrorActionPreference = $false

            $id            = $_
            $confFile      = $using:confFile
            $archiveFile   = $using:archiveFile
            $completeArchiveDir = $using:completeArchiveDir
            $incompleteDir = $using:incompleteDir
            $scriptsRoot   = $using:scriptsRoot
            $logsDir       = $using:logsDir
            $jsRuntimeArgs = $using:jsRuntimeArgs

            $workerLogName = "download.worker-$id.log"
            $workerLogFile = Join-Path $logsDir $workerLogName
            $workerExecCmd = "after_move:pwsh -NoProfile -File `"$(Join-Path $scriptsRoot 'postprocess.ps1')`" -FilePath %(filepath)q -LogFileName `"$workerLogName`""
            $videoUrl = "https://youtu.be/$id"

            "==== Download session started (worker, video $id) $(Get-Date -Format o) ====" | Set-Content -Path $workerLogFile

            & yt-dlp `
                --ignore-config `
                --config-location $confFile `
                --download-archive $archiveFile `
                --paths "home:$completeArchiveDir" `
                --paths "temp:$incompleteDir" `
                @jsRuntimeArgs `
                --exec $workerExecCmd `
                $videoUrl 2>&1 | Tee-Object -Variable workerOutput | Add-Content -Path $workerLogFile

            "==== Download session finished (worker, video $id) $(Get-Date -Format o) ====" | Add-Content -Path $workerLogFile

            [pscustomobject]@{
                VideoId       = $id
                ArchiveSkipped = @($workerOutput | Select-String -Pattern 'has already been recorded in the archive').Count -gt 0
                Errors        = @($workerOutput | Select-String -Pattern '^ERROR:').Count
                Warnings      = @($workerOutput | Select-String -Pattern '^WARNING:').Count
            }
        }

        # --- Aggregate session summary ---
        # Same shape as the single-stream summary, just built from each
        # worker's own returned result object instead of one shared
        # $sessionOutput (there isn't one in parallel mode -- see above).
        $videosTouched   = $results.Count
        $archiveSkipped  = @($results | Where-Object { $_.ArchiveSkipped }).Count
        $sessionErrors   = ($results | Measure-Object -Property Errors -Sum).Sum
        $sessionWarnings = ($results | Measure-Object -Property Warnings -Sum).Sum
        "-- Session summary: $videosTouched video(s) touched, $archiveSkipped already archived (skipped), $sessionErrors error(s), $sessionWarnings warning(s) --" | Tee-Object -FilePath $logFile -Append
    }
}

"==== Download session finished $(Get-Date -Format o) ====" | Tee-Object -FilePath $logFile -Append
