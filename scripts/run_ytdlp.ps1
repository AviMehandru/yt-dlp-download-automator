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
    [Parameter(Mandatory = $false)][ValidateRange(1, 64)][int]$Workers = 1,

    # --- PO (proof-of-origin) token options ---
    # See scripts/pot-provider.ps1 for what a PO token is and why this
    # pipeline needs one. Short version: without a token, the only YouTube
    # client this pipeline can actually download from is android_vr, which
    # is the one with the open upstream 403 bug (yt-dlp/yt-dlp#17456). With
    # a token, tv_simply and web_safari become usable and android_vr
    # becomes a genuine last-resort fallback instead of the only option.

    # Port the local provider server listens on. 4416 is upstream's
    # default and what the yt-dlp plugin assumes when nothing overrides it;
    # change it only if something else on this machine already holds 4416.
    [Parameter(Mandatory = $false)][ValidateRange(1024, 65535)][int]$PotPort = 4416,

    # Skips the update-and-verify cycle when the provider is unhealthy.
    # The provider is still USED if it already works -- this only
    # suppresses the "try to fix it" half. Useful on a metered or offline
    # connection, and for reproducing a specific failure without the
    # pipeline repairing it out from under you mid-investigation.
    [Parameter(Mandatory = $false)][switch]$SkipPotUpdate,

    # Skips PO tokens entirely and runs on yt-dlp's own default clients --
    # exactly the behavior this pipeline had before pot-provider.ps1
    # existed. NOTE that this still triggers degraded-mode archive handling
    # below (downloads withheld from archive.txt), because what that
    # handling protects against is "this run may not be full quality",
    # which is equally true whether the provider is broken or skipped.
    [Parameter(Mandatory = $false)][switch]$NoPot,

    # --- What to download ---
    # These are the only parameters here that change what ends up in the
    # archive rather than how the session is scheduled, and every one of
    # them becomes a yt-dlp argument appended AFTER --config-location.
    # That ordering is the whole mechanism: yt-dlp resolves options
    # left-to-right and the later one wins, which is why these can
    # override config/yt-dlp.conf without that file being rewritten,
    # regenerated, or touched at any point. It is the same mechanism
    # --download-archive, --paths, --exec and --js-runtimes already use.
    #
    # The [ValidateSet]s below are a second line of defence, not the first:
    # ytdl.ps1 checks the same four lists at the point the user typed them
    # so the error names the option they wrote. 030-config asserts the two
    # copies agree.

    # full         video+audio merged (the pre-existing behaviour, exactly).
    # video-only   -f bv*   -- no audio stream.
    # audio-only   -f ba/b  -- no video stream. The media file is named
    #              "Final Audio.<ext>"; see $mediaBaseName below and
    #              docs/archive-layout.md for why that rename is an archive
    #              layout bump.
    # metadata-only / comments-only / subs-only
    #              --skip-download: no media at all. postprocess.ps1 still
    #              runs and still writes the full per-video folder, keyed
    #              off the info.json instead of the media file.
    [Parameter(Mandatory = $false)]
    [ValidateSet("full", "video-only", "audio-only", "metadata-only", "comments-only", "subs-only")]
    [string]$Mode = "full",

    # Height cap in pixels, or "best" for none. Applied as a format
    # FILTER ([height<=N]) with an unfiltered fallback after it, so a video
    # whose only rendition is taller than the cap still downloads rather
    # than failing the run -- an archive that skips a video is worse than
    # one that stores it larger than asked.
    [Parameter(Mandatory = $false)][string]$Quality = "best",

    # Video codec PREFERENCE, expressed through --format-sort, not through
    # a format filter. A filter ("only avc1") makes a video that offers no
    # avc1 rendition fail; a sort preference reorders the candidates and
    # still takes the best available when the preferred codec is absent.
    [Parameter(Mandatory = $false)][ValidateSet("any", "avc1", "vp9", "av01")][string]$Codec = "any",

    # Audio codec for -Mode audio-only. "any" keeps yt-dlp's chosen stream
    # byte-for-byte; anything else runs yt-dlp's audio-extraction
    # postprocessor, which RE-ENCODES (flac excepted, where the source is
    # already lossy so the conversion is lossless-of-a-lossy-original and
    # simply larger). Left at "any" the archive keeps the original bytes,
    # which is what the rest of this pipeline optimises for.
    [Parameter(Mandatory = $false)][ValidateSet("any", "opus", "aac", "mp3", "flac")][string]$AudioCodec = "any",

    # Merge container. Only has an effect when a merge actually happens
    # (video + audio); a single-stream download keeps its native extension
    # regardless. See docs/archive-layout.md: consumers must find the media
    # file by base NAME, never by extension, precisely because of this.
    [Parameter(Mandatory = $false)][ValidateSet("mkv", "mp4", "webm")][string]$Container = "",

    # --- Component skips ---
    # Each of these turns OFF something config/yt-dlp.conf turns on. Note
    # that "off" here means passing yt-dlp's explicit negating flag
    # (--no-write-subs, not the absence of --write-subs): the conf has
    # already said yes by the time these are appended, and only the
    # negation can override it. Omitting the flag would leave the conf's
    # setting in force, which is the single easiest mistake to make in this
    # whole file.
    [Parameter(Mandatory = $false)][switch]$NoComments,
    [Parameter(Mandatory = $false)][switch]$NoSubs,
    [Parameter(Mandatory = $false)][switch]$NoThumbnail,
    [Parameter(Mandatory = $false)][switch]$NoMetadata,

    # Base64-encoded JSON array of raw yt-dlp arguments, decoded below.
    # Encoded rather than passed as a [string[]] because `pwsh -File`
    # cannot bind an array at all -- see the long note at the bottom of
    # ytdl.ps1, where both failing spellings are recorded.
    [Parameter(Mandatory = $false)][string]$YtdlpArgsB64 = ""
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
# ROOT CAUSE FOUND -- and it was not what the previous comment here
# guessed. This block used to say the "Test-Path says it exists but
# Get-Item cannot find it" behaviour was unexplained, and speculated about
# filesystem inconsistency after a forced VM reboot. It is nothing so
# exotic: PowerShell maps the Unix "leading dot means hidden" convention
# onto the Hidden file attribute, and Get-Item WITHOUT -Force refuses to
# return a hidden item, throwing "Could not find item" while Test-Path on
# the very same path returns true. ".last_dependency_check" is dot-
# prefixed, so this reproduced 100% of the time on Linux and macOS, not
# intermittently. It never happened on Windows, where a leading dot is
# just an ordinary character -- which is why a Windows-first codebase
# never saw it.
#
# The visible symptom was mild enough to be easy to miss: the catch below
# falls back to "needs a check", so the throttle simply never engaged and
# `yt-dlp -U` ran on EVERY invocation instead of once a day. The same root
# cause was doing real damage in postprocess.ps1's Channel Info throttle,
# where the throw escaped to a catch that skipped the refresh entirely --
# see that file for the details.
#
# The try/catch is kept even though -Force fixes the known cause: falling
# back to "run the check" is still the right behaviour for any other
# unreadable-marker case, and this code runs before $logFile is being
# written to, where an unhandled error would go to the terminal and never
# reach download.log at all.
try {
    if (Test-Path $updateThrottleMarker) {
        $markerItem = Get-Item $updateThrottleMarker -Force -ErrorAction Stop
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
        # --- Linux: ask whichever package manager this distribution uses ---
        # This used to assume apt outright. It degraded safely elsewhere (a
        # missing `apt` throws CommandNotFoundException, the catch logs it and
        # the block below is skipped), but it meant a Fedora or Arch user
        # simply never got told an ffmpeg update was waiting.
        #
        # The family is read from /etc/os-release the same way setup.sh reads
        # it, including the ID_LIKE fallback that makes derivatives -- Mint,
        # Pop!_OS, Manjaro, Rocky -- resolve to their parent family without
        # being named.
        #
        # In every case this reads the package manager's EXISTING local cache
        # and never refreshes it: refreshing needs root, and a background
        # video-download script silently invoking sudo is not something to do
        # unattended. Refresh it yourself periodically for this to stay
        # accurate.
        $distroFamily = "unknown"
        try {
            if (Test-Path "/etc/os-release") {
                $osRelease = Get-Content "/etc/os-release" -Raw
                $distroId     = if ($osRelease -match '(?m)^ID=("?)(.*?)\1\s*$')      { $Matches[2] } else { "" }
                $distroIdLike = if ($osRelease -match '(?m)^ID_LIKE=("?)(.*?)\1\s*$') { $Matches[2] } else { "" }
                # Padded with spaces so the -like patterns below test whole
                # words against the space-separated ID_LIKE list, exactly as
                # setup.sh's case patterns do.
                $idHaystack = " $distroId $distroIdLike "
                if     ($idHaystack -like "* debian *" -or $idHaystack -like "* ubuntu *") { $distroFamily = "debian" }
                elseif ($idHaystack -like "* fedora *" -or $idHaystack -like "* rhel *" -or $idHaystack -like "* centos *") { $distroFamily = "fedora" }
                elseif ($idHaystack -like "* arch *")   { $distroFamily = "arch" }
                elseif ($idHaystack -like "* suse *" -or $idHaystack -like "* opensuse *" -or $distroId -like "opensuse*") { $distroFamily = "suse" }
            }
        } catch {
            "  [distro check] Could not read /etc/os-release: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
        }

        # pwsh is installed from Microsoft's tarball into $HOME/.local by
        # setup.sh, NOT from any distro package (see that script's Step 4 for
        # why). No package manager knows about it, so asking one whether an
        # update is available would always answer no. Compared against the
        # newest published release instead -- via GitHub's /releases/latest
        # redirect rather than its API, which is rate-limited per IP for
        # unauthenticated callers and fails unpredictably on shared networks.
        try {
            $latestUrl = (Invoke-WebRequest -Uri "https://github.com/PowerShell/PowerShell/releases/latest" -MaximumRedirection 5 -ErrorAction Stop).BaseResponse.RequestMessage.RequestUri.AbsoluteUri
            if ($latestUrl -match '/tag/v(.+)$') {
                $latestPwsh = $Matches[1]
                $currentPwsh = $PSVersionTable.PSVersion.ToString()
                if ($latestPwsh -and ($currentPwsh -ne $latestPwsh)) {
                    "  WARNING: pwsh $currentPwsh is running; $latestPwsh is the latest release. It was installed from a tarball rather than a package, so nothing updates it for you -- re-run setup.sh at a natural stopping point to pick up the new version." | Tee-Object -FilePath $logFile -Append
                }
            }
        } catch {
            "  [pwsh check] Could not reach GitHub to check the latest PowerShell release: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
        }

        # ffmpeg IS a distro package on every supported family, so this asks
        # the local package manager about it.
        $ffmpegUpdateHint = $null
        try {
            switch ($distroFamily) {
                "debian" {
                    $upgradable = & apt list --upgradable 2>$null
                    if ($upgradable -match '^ffmpeg/') { $ffmpegUpdateHint = "sudo apt update && sudo apt install --only-upgrade ffmpeg" }
                }
                "fedora" {
                    # dnf exits 100 when updates ARE available, which is
                    # documented behaviour rather than a failure -- so the
                    # exit code is deliberately not inspected here, only the
                    # output.
                    $upgradable = & dnf check-update ffmpeg 2>$null
                    if ($upgradable -match '(?m)^ffmpeg\s') { $ffmpegUpdateHint = "sudo dnf upgrade ffmpeg" }
                }
                "arch" {
                    # -Qu lists installed packages with a newer version in the
                    # local sync database. Queries only; touches nothing.
                    $upgradable = & pacman -Qu 2>$null
                    if ($upgradable -match '(?m)^ffmpeg\s') { $ffmpegUpdateHint = "sudo pacman -Syu" }
                }
                "suse" {
                    $upgradable = & zypper --non-interactive list-updates 2>$null
                    if ($upgradable -match '(?m)\|\s*ffmpeg') { $ffmpegUpdateHint = "sudo zypper update ffmpeg" }
                }
            }
        } catch {
            "  [$distroFamily check] Could not query the package manager for updates: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
        }
        if ($ffmpegUpdateHint) {
            "  WARNING: a package update is available for ffmpeg. Update at a natural stopping point with: $ffmpegUpdateHint" | Tee-Object -FilePath $logFile -Append
        }
    }

    Set-Content -Path $updateThrottleMarker -Value (Get-Date -Format "o")
}

# --- Versioned archival snapshot (#16): back up archive.txt + global manifest before this run ---
if (Test-Path $archiveFile)    { Copy-Item $archiveFile (Join-Path $historyDir "archive_$timestamp.txt") }
if (Test-Path $globalManifest) { Copy-Item $globalManifest (Join-Path $historyDir "global_manifest_$timestamp.json") }

# The conf itself, snapshotted once per session alongside them.
#
# Every manifest.json records config_file_version, but a version number is
# only a useful record while the file it names is still recoverable. This
# keeps the actual text: "CONFIG_VERSION 25 plus these three overrides"
# stays readable years later without needing this repository, and without
# duplicating eighty lines of conf into every video folder forever. Once
# per session, not once per video, is the whole point of putting it here.
#
# Archive Logs/ is deliberately outside the consumer contract (see
# docs/archive-layout.md), so adding a file here needs no layout bump and
# no reader has to learn about it.
if (Test-Path $confFile) { Copy-Item $confFile (Join-Path $historyDir "yt-dlp_conf_$timestamp.conf") }

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

# =====================================================================
# PO TOKEN PREFLIGHT
# =====================================================================
# Runs BEFORE any download so the client list and the archive policy for
# this entire session are decided once, up front, rather than per video.
#
# Two things come out of this block:
#   $potArgs      -- the --extractor-args to splat onto every yt-dlp call
#                    below (empty when degraded, which reproduces exactly
#                    the client behaviour this pipeline had before PO
#                    tokens existed).
#   $potDegraded  -- whether this session must withhold its downloads from
#                    the download archive. See the long note further down
#                    at "DEGRADED-MODE ARCHIVE HANDLING" for why that
#                    matters more than it sounds like it should.
#
# Failure here is never fatal. A machine with no node, no network, or a
# provider upstream has not fixed yet still downloads videos; it just
# downloads them the way it did last month.
$potArgs     = @()
$potDegraded = $true
$potReason   = "not attempted"
$potModule   = Join-Path $scriptsRoot "pot-provider.ps1"

if ($NoPot) {
    $potReason = "-NoPot was passed"
    "PO tokens: disabled by -NoPot. Running on yt-dlp's default clients." | Tee-Object -FilePath $logFile -Append
} elseif (-not (Test-Path $potModule)) {
    # An older install that predates pot-provider.ps1, or a partial file
    # placement. Worth saying out loud, because the symptom otherwise is
    # just "downloads are flakier than the docs imply".
    $potReason = "pot-provider.ps1 not found at $potModule"
    "PO tokens: pot-provider.ps1 is missing from $scriptsRoot -- re-run setup to install it. Running on yt-dlp's default clients meanwhile." | Tee-Object -FilePath $logFile -Append
} else {
    try {
        . $potModule
        # The logger is threaded in as a scriptblock rather than having the
        # module know about $logFile: the module has to stay usable
        # standalone (pot-provider.ps1 -SelfTest), where there is no
        # session log to write to.
        $potResult = Initialize-PotProvider -ProviderPort $PotPort -SkipUpdate:$SkipPotUpdate -Log {
            param($m) $m | Tee-Object -FilePath $logFile -Append | Out-Null; Write-Host "  [pot] $m"
        }
        # Wrapped in @() for the same reason $jsRuntimeArgs is, and this
        # one is not hypothetical: reading an empty array off a
        # pscustomobject property hands back $null, and a one-element
        # result would arrive as a bare scalar. Splatting $null happens to
        # behave like splatting @(), so the degraded case would work by
        # luck -- but the healthy case builds a 2- or 4-element array whose
        # count depends on whether -PotPort was overridden, and relying on
        # luck for one shape and not the other is how the launcher's $rest
        # bug happened.
        $potArgs     = @($potResult.ExtractorArgs)
        $potDegraded = -not $potResult.Healthy
        $potReason   = $potResult.Reason
        "PO tokens: $(if ($potResult.Healthy) { 'active' } else { 'UNAVAILABLE' }) | clients: $($potResult.PlayerClients) | $($potResult.Reason)" |
            Tee-Object -FilePath $logFile -Append
    } catch {
        # A broken provider module must not take the download with it.
        $potReason = "pot-provider.ps1 threw: $($_.Exception.Message)"
        "PO tokens: provider setup failed ($($_.Exception.Message)). Running on yt-dlp's default clients." | Tee-Object -FilePath $logFile -Append
    }
}

# --- DEGRADED-MODE ARCHIVE HANDLING ---
# This is the subtle part, and it is worth spelling out because getting it
# wrong is silent and permanent.
#
# --download-archive is append-only and yt-dlp writes to it as each video
# completes. In a degraded session the videos that complete are real
# downloads, but they came from yt-dlp's fallback clients, which may mean
# a lower maximum quality, missing formats, or a "made for kids" video
# skipped outright. If those ids land in archive.txt, every future run --
# including runs where the provider is perfectly healthy -- will skip them
# as already archived. The archive would quietly and permanently contain
# the worse copy, with nothing in it to say which entries were degraded.
#
# The fix is to let yt-dlp READ the real archive (so already-done videos
# are still correctly skipped, and a degraded run does not re-download the
# entire back catalogue) while WRITING to a throwaway copy. Diffing the
# copy against the original afterwards yields exactly the set of ids this
# session downloaded, which goes to needs-refetch.txt instead of to the
# archive. yt-dlp has no read-only archive mode, so a scratch copy is the
# mechanism; the semantics are what matter.
#
# Cost: a degraded video downloads again later, so it is paid for twice in
# bandwidth. That is the deliberate trade -- duplicate work is recoverable,
# a silently-degraded archive entry is not.
$refetchFile   = Join-Path $logsDir "needs-refetch.txt"
$archiveForRun = $archiveFile
$archiveScratch = $null
if ($potDegraded) {
    $archiveScratch = Join-Path $logsDir ".archive-degraded-$timestamp.txt"
    if (Test-Path $archiveFile) {
        Copy-Item -Path $archiveFile -Destination $archiveScratch -Force
    } else {
        New-Item -ItemType File -Path $archiveScratch -Force | Out-Null
    }
    $archiveForRun = $archiveScratch
    "  Degraded session: downloads will NOT be recorded in archive.txt. Any video completed now is listed in $refetchFile for re-fetching at full quality later." |
        Tee-Object -FilePath $logFile -Append
}

# =====================================================================
# CONTENT SELECTION -- what this session downloads
# =====================================================================
# Everything in this block becomes yt-dlp arguments appended AFTER
# --config-location in both invocations below. yt-dlp resolves options
# left to right and the later occurrence wins, so these override
# config/yt-dlp.conf without that file being read differently, rewritten,
# or regenerated -- the conf stays exactly as static as it has always
# been. That is the entire mechanism, and it is the same one
# --download-archive/--paths/--exec have used since CONFIG_VERSION 21.
#
# $contentArgs is built once here and splatted into BOTH the single-stream
# call and the parallel worker call. Getting that wrong in one direction
# is the specific bug this layout is arranged to prevent: $playlistArgs
# below is deliberately single-stream-only (its options are applied at
# ENUMERATION time in the parallel path instead), and an earlier draft of
# this change followed that shape by accident, which would have made every
# content option silently do nothing whenever --workers was above 1.
# 040-run-ytdlp asserts both call sites carry $contentArgs.

# --- The passthrough denylist ---
# These are the yt-dlp options that decide WHERE output lands and WHAT
# runs afterwards. Every one of them is already set by this script from
# resolved runtime paths, and overriding any of them from the command line
# does not produce a differently-configured archive -- it produces files
# that no consumer of this archive can find, with no error at any layer,
# which is exactly the failure docs/archive-layout.md exists to prevent.
# Refused loudly here instead.
$BlockedPassthroughArgs = @(
    "-o", "--output", "-P", "--paths", "--exec", "--config-location",
    "--ignore-config", "--download-archive", "--paths-temp"
)

$passthroughArgs = @()
if ($YtdlpArgsB64) {
    try {
        $decodedJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($YtdlpArgsB64))
        # @() around the ConvertFrom-Json result is load-bearing for the
        # same reason it is around the if-expression in ytdl.ps1: a
        # single-element JSON array deserializes to a bare scalar, which
        # would make .Count 1 by accident of string length rather than by
        # element count, and the foreach below iterate characters.
        $passthroughArgs = @($decodedJson | ConvertFrom-Json)
    } catch {
        "ERROR: Could not decode -YtdlpArgsB64: $($_.Exception.Message)" | Tee-Object -FilePath $logFile -Append
        exit 1
    }
    foreach ($pa in $passthroughArgs) {
        # Compared against the bare option name only, so "--output=X" (the
        # equals spelling optparse also accepts) is caught as well as
        # "--output X".
        $bare = ($pa -split '=', 2)[0]
        if ($BlockedPassthroughArgs -contains $bare) {
            "ERROR: --ytdlp-arg $bare is refused: it decides where files are written or what runs afterwards, and overriding it produces an archive no reader can find. See docs/archive-layout.md." |
                Tee-Object -FilePath $logFile -Append
            exit 1
        }
    }
    if ($passthroughArgs.Count -gt 0) {
        "  Passthrough yt-dlp arguments for this run: $($passthroughArgs -join ' ')" | Tee-Object -FilePath $logFile -Append
    }
}

$noMediaModes = @("metadata-only", "comments-only", "subs-only")
$isNoMedia    = $noMediaModes -contains $Mode

# --- The media file's base name ---
# "Final Video" for everything that has a video stream, "Final Audio" for
# audio-only. This rename is why the archive layout version went to 2: a
# layout-1 reader looks for "Final Video.*" and would find nothing in an
# audio-only folder, showing an empty entry rather than an error.
$mediaBaseName = if ($Mode -eq "audio-only") { "Final Audio" } else { "Final Video" }

# --- Format selection ---
# Built as a yt-dlp format expression rather than as separate flags. The
# "/" alternatives are yt-dlp's own fallback operator: each is tried in
# turn and the first that matches wins, which is what keeps a height cap
# from turning "this video only exists in 1440p" into a failed download.
$formatArgs = @()
$heightFilter = if ($Quality -and $Quality -ne "best") { "[height<=$Quality]" } else { "" }
switch ($Mode) {
    "video-only" {
        # bv* rather than bv: the * form allows a video-only rendition OR
        # the video half of a combined stream, so a source that publishes
        # no separate video-only track still works.
        $formatArgs = @("-f", "bv*$heightFilter/bv*/b$heightFilter/b")
    }
    "audio-only" {
        # No height filter: a height predicate against an audio-only
        # format matches nothing, which would empty the candidate list.
        $formatArgs = @("-f", "ba/b")
    }
    default {
        if ($heightFilter) {
            $formatArgs = @("-f", "bv*$heightFilter+ba/b$heightFilter/bv*+ba/b")
        }
        # No -f at all when the mode is "full" and no cap was asked for:
        # the conf's own "-f bv*+ba/b" is already exactly right, and
        # re-passing it would make a default run's command line differ
        # from the pre-change one for no reason.
    }
}

# --- Codec preference ---
# --format-sort, not a format filter. See the -Codec parameter comment.
# Passed with +vcodec: so it is prepended to yt-dlp's own default sort
# order rather than replacing it -- everything else about how yt-dlp picks
# a format stays as it was.
$sortArgs = @()
if ($Codec -ne "any") {
    $sortArgs = @("-S", "vcodec:$Codec")
}

# --- Audio extraction ---
$audioArgs = @()
if ($Mode -eq "audio-only" -and $AudioCodec -ne "any") {
    $audioArgs = @("-x", "--audio-format", $AudioCodec)
}

# --- Container ---
$containerArgs = @()
if ($Container) { $containerArgs = @("--merge-output-format", $Container) }

# --- Component skips ---
# Every entry here is an explicit NEGATING flag, never an omission. The
# conf has already switched each of these on by the time these arguments
# are appended, so "leave the flag out" leaves the conf's value in force
# and the skip silently does nothing. This is the single most likely way
# to get this file wrong; 040-run-ytdlp asserts the negations by name.
$skipArgs = @()
if ($NoSubs) {
    # Both, because the conf sets both --write-subs and --write-auto-subs
    # and each has its own negation. --embed-subs is left alone: with
    # nothing written there is nothing to embed, and passing --no-embed-subs
    # as well would be a no-op that only makes the command line longer.
    $skipArgs += @("--no-write-subs", "--no-write-auto-subs")
}
if ($NoThumbnail) {
    $skipArgs += @("--no-write-thumbnail", "--no-embed-thumbnail")
}
if ($NoMetadata) {
    # --no-write-info-json also removes what postprocess.ps1 reads for
    # title/id/date/urls. That is a supported state, not a broken one: it
    # falls back to parsing the folder name, which is a path 050-postprocess
    # already covers and archive-viewer.py already handles.
    $skipArgs += @("--no-write-description", "--no-write-info-json")
}

# --- No-media modes ---
# --skip-download leaves nothing to merge and nothing to move into
# "Final files", so the after_move hook never fires for a media file.
# postprocess.ps1 is keyed off the info.json in those modes instead (see
# -Mode there), which means the info.json must be written even when
# --no-metadata asked for no sidecars -- otherwise the hook has no trigger
# at all and the per-video folder is never assembled. Forced back on here,
# with a warning, rather than silently producing nothing.
$skipDownloadArgs = @()
if ($isNoMedia) {
    $skipDownloadArgs = @("--skip-download")
    if ($NoMetadata) {
        "  NOTE: --mode $Mode needs the info.json as its post-processing trigger, so --no-metadata's --no-write-info-json is not applied this run (the description sidecar is still skipped)." |
            Tee-Object -FilePath $logFile -Append
        $skipArgs = @($skipArgs | Where-Object { $_ -ne "--no-write-info-json" })
    }
    if ($Mode -eq "subs-only") {
        # Re-assert the conf's subtitle settings positively: subs-only is
        # the one mode where a subtitle download is the entire point, so
        # it should not depend on the conf still happening to enable them.
        $skipDownloadArgs += @("--write-subs", "--write-auto-subs")
    }
}

# --- The output template for audio-only ---
# Read out of the conf and rewritten, rather than duplicated here. The
# per-video folder shape (uploader/date/id/title, and which subfolder each
# file type lands in) has exactly one definition in this project and it is
# in config/yt-dlp.conf; a second copy in this file would be a second
# thing to keep correct, and the first symptom of them disagreeing would
# be an audio-only download landing outside the archive entirely.
#
# Only the DEFAULT (unprefixed) -o line is touched -- the subtitle:,
# thumbnail:, description:, infojson: and link: templates are keyed by
# type and already correct for audio.
$outputArgs = @()
if ($Mode -eq "audio-only") {
    $defaultTemplate = $null
    foreach ($line in (Get-Content $confFile)) {
        if ($line -match '^\s*-o\s+"([^"]+)"\s*$') {
            $candidate = $Matches[1]
            # A prefixed template starts with "<type>:"; the default one
            # starts with the uploader field. Anchored on the "%(" that
            # every template field opens with so a future type prefix
            # containing a digit or dash is still recognised as prefixed.
            if ($candidate -notmatch '^[A-Za-z0-9_]+:') {
                $defaultTemplate = $candidate
                break
            }
        }
    }
    if ($defaultTemplate -and $defaultTemplate -match 'Final Video\.%\(ext\)s') {
        $audioTemplate = $defaultTemplate -replace 'Final Video\.%\(ext\)s', 'Final Audio.%(ext)s'
        $outputArgs = @("-o", $audioTemplate)
        "  Audio-only: media file will be named 'Final Audio.<ext>' (archive layout 2)." | Tee-Object -FilePath $logFile -Append
    } else {
        # Refused rather than guessed. Falling back to a hardcoded
        # template here would write the audio file into a folder shape
        # that no longer matches the one every other file in this run is
        # using, which is worse than not running.
        "ERROR: could not read the default -o template out of $confFile, so --mode audio-only cannot rename the media file safely. Has the template been changed? See docs/archive-layout.md." |
            Tee-Object -FilePath $logFile -Append
        exit 1
    }
}

# Assembled in a fixed order -- format, sort, audio, container, skips,
# skip-download, output template, then the user's own passthrough LAST so
# that --ytdlp-arg genuinely wins over everything this script decided.
$contentArgs = @()
$contentArgs += $formatArgs
$contentArgs += $sortArgs
$contentArgs += $audioArgs
$contentArgs += $containerArgs
$contentArgs += $skipArgs
$contentArgs += $skipDownloadArgs
$contentArgs += $outputArgs
$contentArgs += $passthroughArgs

if ($contentArgs.Count -gt 0) {
    "-- Content options for this session (mode: $Mode): $($contentArgs -join ' ') --" | Tee-Object -FilePath $logFile -Append
}

# Recorded into every manifest.json this session writes, so a video can be
# traced back to the settings that produced it. config_file_version alone
# stopped being sufficient the moment a run could override the conf --
# see docs/archive-layout.md. Passed to postprocess.ps1 the same way
# -LogFileName already is, base64-encoded for the array-crossing reason
# documented in ytdl.ps1.
$runSettings = [ordered]@{
    mode          = $Mode
    quality       = $Quality
    codec         = $Codec
    audio_codec   = $AudioCodec
    container     = if ($Container) { $Container } else { "mkv" }
    no_comments   = [bool]$NoComments
    no_subs       = [bool]$NoSubs
    no_thumbnail  = [bool]$NoThumbnail
    no_metadata   = [bool]$NoMetadata
    passthrough   = @($passthroughArgs)
    effective_args = @($contentArgs)
}
$runSettingsB64 = [System.Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 6 -InputObject $runSettings)))

# The extra arguments every postprocess.ps1 invocation in this session
# carries, beyond -FilePath and -LogFileName. Built once so the two
# --exec strings below cannot drift apart.
$ppExtraArgs = "-Mode `"$Mode`" -RunSettingsB64 `"$runSettingsB64`""
if ($NoComments) { $ppExtraArgs += " -NoComments" }

# =====================================================================
# END CONTENT SELECTION
# =====================================================================

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
    $execCmd = "after_move:pwsh -NoProfile -File `"$(Join-Path $scriptsRoot 'postprocess.ps1')`" -FilePath %(filepath)q -LogFileName `"download.log`" $ppExtraArgs"

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
    #
    # The bare `--` on the second-to-last line is the end-of-options marker,
    # and it is the reason a URL whose video id starts with a hyphen works
    # here. YouTube ids are base64url, so "-QMgcOSyf-o" and "_x1-abcdefg"
    # are perfectly ordinary ids, and yt-dlp parses its command line with
    # optparse: without `--`, an argument beginning with "-" is read as an
    # option no matter where it sits, and the run dies with a bare "Usage:
    # yt-dlp [OPTIONS] URL [URL...]" that says nothing about which argument
    # was at fault. `--` says "everything after this is a positional
    # argument", which is exactly what a URL is. It costs nothing on a
    # normal URL (verified: yt-dlp extracts identically with and without
    # it), so every yt-dlp invocation in this pipeline that takes a URL now
    # has one -- see the enumeration and worker calls below, and the
    # comments and Channel Info passes in postprocess.ps1.
    #
    # PowerShell passes a bare `--` through to a NATIVE command as a plain
    # literal argument (its own end-of-parameters meaning applies to
    # cmdlets, not to native command lines), including across the backtick
    # continuations used here -- also verified rather than assumed.
    #
    # What this does NOT fix, because it happens before this script exists:
    # the shell eating the URL first. An unquoted "watch?v=..." is a glob in
    # zsh (macOS's default shell), which fails the command outright with
    # "no matches found"; an unquoted "&list=..." backgrounds the command in
    # bash and truncates the URL; and "&" is a syntax error in PowerShell.
    # Quoting the URL is the only cure for those, so ytdl.ps1 detects what
    # it can of the aftermath and says so plainly, and docs/ytdl-usage.md
    # spells out the rule.
    # $archiveForRun is the real archive.txt in a healthy session and a
    # throwaway copy in a degraded one -- see DEGRADED-MODE ARCHIVE
    # HANDLING above. @potArgs is empty in a degraded session, which makes
    # this invocation identical to the pre-PO-token one.
    & yt-dlp `
        --ignore-config `
        --config-location $confFile `
        --download-archive $archiveForRun `
        --paths "home:$completeArchiveDir" `
        --paths "temp:$incompleteDir" `
        @jsRuntimeArgs `
        @potArgs `
        --exec $execCmd `
        @contentArgs `
        @playlistArgs `
        -- `
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
    # `--` before $Url for the same reason as the single-stream call above:
    # a channel or playlist URL is a positional argument, and one whose id
    # begins with a hyphen must not be read as an option.
    $enumOutput = & yt-dlp --ignore-config --flat-playlist --skip-download --print "%(id)s" @enumArgs -- $Url 2>&1
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
            # The PO token decision was made ONCE in the parent, before
            # any worker started, and only its RESULT crosses the runspace
            # boundary. Workers must never run the preflight themselves:
            # they would race to start, health-check and possibly rebuild
            # the same single provider server on the same single port.
            # The server is shared infrastructure; the args are just data.
            $archiveForRun = $using:archiveForRun
            $potArgs       = $using:potArgs
            $completeArchiveDir = $using:completeArchiveDir
            $incompleteDir = $using:incompleteDir
            $scriptsRoot   = $using:scriptsRoot
            $logsDir       = $using:logsDir
            $jsRuntimeArgs = $using:jsRuntimeArgs
            # The content options are decided ONCE in the parent, before
            # any worker starts, and only the finished argument array
            # crosses the runspace boundary -- the same rule as $potArgs
            # above, for the same reason: a worker must never re-derive a
            # session-wide decision for itself. In particular the
            # audio-only -o template is read out of the conf file exactly
            # once, not once per video.
            $contentArgs   = $using:contentArgs
            $ppExtraArgs   = $using:ppExtraArgs

            $workerLogName = "download.worker-$id.log"
            $workerLogFile = Join-Path $logsDir $workerLogName
            $workerExecCmd = "after_move:pwsh -NoProfile -File `"$(Join-Path $scriptsRoot 'postprocess.ps1')`" -FilePath %(filepath)q -LogFileName `"$workerLogName`" $ppExtraArgs"
            # A worker's URL is BUILT here from an enumerated id rather than
            # typed by anyone, which makes the hyphen case more likely, not
            # less: enumeration hands back whatever ids the channel has, and
            # roughly one YouTube id in thirty starts with "-" or "_". The
            # https:// prefix means this particular string can never look
            # like an option, but the `--` below is kept for the same reason
            # as everywhere else -- one rule, applied at every call site,
            # rather than a per-call judgement about whether this one is
            # safe.
            $videoUrl = "https://youtu.be/$id"

            "==== Download session started (worker, video $id) $(Get-Date -Format o) ====" | Set-Content -Path $workerLogFile

            & yt-dlp `
                --ignore-config `
                --config-location $confFile `
                --download-archive $archiveForRun `
                --paths "home:$completeArchiveDir" `
                --paths "temp:$incompleteDir" `
                @jsRuntimeArgs `
                @potArgs `
                --exec $workerExecCmd `
                @contentArgs `
                -- `
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

# --- Degraded-session reconciliation: capture what must be re-fetched ---
# Runs for BOTH the single-stream and worker paths (they share one scratch
# archive, exactly as they already share one real archive.txt).
#
# The diff is done by video id against the ORIGINAL archive rather than by
# counting lines, because a degraded session can interleave with anything
# else that touched archive.txt between the copy and now -- and because an
# id is the only part of an archive line this pipeline ever needs to act
# on later.
#
# Note what is deliberately NOT done here: the downloaded files are left
# exactly where they are. A degraded copy of a video is still a copy of
# that video, and deleting it to force a clean re-fetch would mean an
# outage produces nothing at all, which is the outcome this whole design
# exists to avoid. needs-refetch.txt records the debt; paying it is a
# separate, explicit act (see docs/setup-guide.md).
if ($potDegraded -and $archiveScratch -and (Test-Path $archiveScratch)) {
    try {
        $before = @{}
        if (Test-Path $archiveFile) {
            foreach ($line in (Get-Content -Path $archiveFile -ErrorAction SilentlyContinue)) {
                if ($line -and $line.Trim()) { $before[$line.Trim()] = $true }
            }
        }
        $newEntries = @(
            Get-Content -Path $archiveScratch -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() -and -not $before.ContainsKey($_.Trim()) } |
                ForEach-Object { $_.Trim() }
        )
        if ($newEntries.Count -gt 0) {
            # One line per entry, prefixed with when and why, so the file
            # stays useful months later when "why is this video in here"
            # is not obvious. Appended, never overwritten: successive
            # degraded sessions accumulate rather than clobber.
            $stamp = Get-Date -Format "o"
            $newEntries |
                ForEach-Object { "$stamp`t$_`tdegraded: $potReason" } |
                Add-Content -Path $refetchFile -Encoding UTF8
            "-- $($newEntries.Count) video(s) downloaded WITHOUT PO tokens and withheld from archive.txt. Listed in $refetchFile; re-run those URLs once 'pwsh -File $potModule -Status' reports a healthy provider, to replace them at full quality. --" |
                Tee-Object -FilePath $logFile -Append
        }
    } catch {
        # If reconciliation fails, the scratch archive is still on disk and
        # is named for the session timestamp, so nothing is lost -- say
        # where it is rather than silently dropping the record.
        "WARNING: could not reconcile the degraded-session archive ($($_.Exception.Message)). The raw scratch archive is kept at $archiveScratch -- diff it against archive.txt by hand to find what needs re-fetching." |
            Tee-Object -FilePath $logFile -Append
        $archiveScratch = $null
    }
    if ($archiveScratch) { Remove-Item -Path $archiveScratch -Force -ErrorAction SilentlyContinue }
}

# --- Retire the staging folder itself if the session left it empty (#5) ---
# postprocess.ps1 already sweeps the empty per-video subfolders yt-dlp
# leaves behind INSIDE _incomplete after each video (yt-dlp/yt-dlp#11674),
# but it deliberately stops short of _incomplete itself: it runs per video,
# from --exec after_move, while later videos in the same session -- and, in
# parallel mode, other workers at that very moment -- are still staging
# files through that exact folder. Removing it from there would be pulling
# the floor out from under an in-flight download.
#
# Here is the one point in the pipeline where it is safe: every yt-dlp
# invocation this session made (the single stream, or all N workers, which
# ForEach-Object -Parallel has already joined by now) has returned, so
# nothing is writing under _incomplete any more. Nothing is lost by
# removing it: the self-heal block at the top of this script recreates it
# on the next invocation, and yt-dlp's --paths temp: would create it on
# demand regardless.
#
# The check is strict on purpose -- ANY entry, including hidden ones, and
# the folder is left completely alone. A non-empty _incomplete is not
# clutter; it is the .part/.ytdl fragments of a download that failed or was
# interrupted, and those files are exactly what yt-dlp needs to resume
# rather than restart it. -Force is what makes that true: without it
# Get-ChildItem skips hidden entries, and the folder would look empty while
# still holding resumable state (the same hidden-file trap the dependency
# throttle marker hit once already, higher up in this script).
try {
    if (Test-Path $incompleteDir) {
        $stagedLeftovers = @(Get-ChildItem -Path $incompleteDir -Force -ErrorAction Stop)
        if ($stagedLeftovers.Count -eq 0) {
            Remove-Item -Path $incompleteDir -Force -ErrorAction Stop
            "-- Removed the empty _incomplete staging folder. --" | Tee-Object -FilePath $logFile -Append
        } else {
            "-- Kept _incomplete: $($stagedLeftovers.Count) item(s) still staged there (resumable partial download). --" | Tee-Object -FilePath $logFile -Append
        }
    }
} catch {
    # Non-fatal by design: a leftover staging folder costs nothing, and a
    # session that downloaded everything correctly should not report failure
    # because a housekeeping delete lost a race with an antivirus scanner or
    # an open Explorer window.
    "-- WARNING: Could not remove _incomplete: $($_.Exception.Message) --" | Tee-Object -FilePath $logFile -Append
}

"==== Download session finished $(Get-Date -Format o) ====" | Tee-Object -FilePath $logFile -Append