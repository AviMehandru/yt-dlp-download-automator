<#
.SYNOPSIS
    Automated setup for the yt-dlp archival pipeline on Windows.

.DESCRIPTION
    The Windows counterpart to setup.sh, which covers Linux and macOS.
    Performs the same twelve steps in the same order, with winget in place
    of apt/Homebrew, and installs the exact same cross-platform
    run_ytdlp.ps1 / postprocess.ps1 / yt-dlp.conf that the Unix installer
    does -- there are no Windows-specific copies of those files anymore.

    IMPORTANT: this script is written to run under Windows PowerShell 5.1
    (the version that ships with Windows) as well as PowerShell 7, because
    installing PowerShell 7 is one of the things it does. That rules out
    7-only syntax throughout: no ternary operator, no null-coalescing, no
    ForEach-Object -Parallel, and no reliance on $IsWindows. The pipeline
    scripts it installs are pwsh 7 scripts and do use all of that -- but
    they are never executed by this installer, only copied.

    Deliberately does NOT use a global "stop on any error". Every external
    command that could plausibly fail on some systems (a winget package
    temporarily unavailable, a flaky network blip) is wrapped so a failure
    prints a clear WARNING and the script keeps going, rather than dying
    silently partway through. This matters most for the folder-structure
    and file-placement steps -- those should basically ALWAYS run, since
    nothing about them depends on earlier steps having succeeded.

    Safe to re-run -- every step checks before it acts.

.EXAMPLE
    # From an ordinary (non-admin) PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>

$ErrorActionPreference = "Continue"

# See run_ytdlp.ps1's platform block for why the Windows install root is
# C:\yt-dlp rather than something under the user profile: MAX_PATH. The
# per-video paths this pipeline builds are long enough that ten characters
# of prefix genuinely matter.
if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $DataRoot = "C:\yt-dlp"
} else {
    $DataRoot = $env:YTDLP_INSTALL_ROOT
}
# Mirrors the Unix installer's $HOME/.local/bin. Chosen over
# C:\Program Files\... for the same reason as on Unix: it is a directory
# the user already owns outright, so yt-dlp's self-updater (which writes a
# temp file into the CONTAINING directory and renames over the old binary)
# never hits a permissions problem, and no step here needs elevation.
$LocalBin   = Join-Path $env:USERPROFILE ".local\bin"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RawBase    = "https://raw.githubusercontent.com/AviMehandru/yt-dlp-download-automator/main"
$DownloadDir = Join-Path $ScriptDir "YT-DLP Installation Files"

# Keep this list in sync with the Copy-ProjectFile calls in Step 11.
# ytdl.ps1 and ytdl.cmd are the Windows launcher pair (the .cmd is a
# one-line shim so `ytdl <url>` works from cmd.exe, which cannot execute a
# .ps1 directly); the Unix installer fetches the single `ytdl` bash script
# in their place. Everything else in this list is identical on all three
# platforms.
$ProjectFiles = @(
    "run_ytdlp.ps1",
    "postprocess.ps1",
    "yt-dlp.conf",
    "ytdl.ps1",
    "ytdl.cmd",
    "archive-viewer.py"
)

$Warnings = New-Object System.Collections.Generic.List[string]

# --- Console log capture ---
# Start-Transcript is the native equivalent of the Unix installer's
# `exec > >(tee -a ...)`: everything printed from here on goes to both the
# console and the file. It does NOT capture the raw stdout of external
# .exe calls as reliably as tee does, so every winget/curl call below is
# additionally piped through Write-Log rather than left to the transcript
# alone. Uses the same "Archive Logs\Logs" directory the rest of the
# pipeline logs into, for one consistent place to look.
$LogDir = Join-Path $DataRoot "Archive Logs\Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("setup_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
try {
    Start-Transcript -Path $LogFile -Append | Out-Null
    $TranscriptRunning = $true
} catch {
    $TranscriptRunning = $false
    Write-Host "NOTE: could not start a transcript ($($_.Exception.Message)); console output will not be saved to a file."
}
Write-Host "Logging full console output to: $LogFile"
Write-Host "Detected platform: windows"

# --- Overall progress bar ---
# Step-counter bar, not a byte/percent-of-work bar: it advances once per
# top-level step (12 total), regardless of how long that step's actual work
# takes. winget prints its own real progress for its own downloads, so this
# only needs to answer "how far through the whole script am I".
# $TotalSteps must match the number of Write-Step calls below.
$TotalSteps = 12
$script:CurrentStep = 0

function Draw-ProgressBar {
    $width = 30
    $pct = [int](($script:CurrentStep * 100) / $TotalSteps)
    $filled = [int](($script:CurrentStep * $width) / $TotalSteps)
    $empty = $width - $filled
    $bar = ""
    if ($filled -gt 0) { $bar += ("#" * $filled) }
    if ($empty -gt 0)  { $bar += ("-" * $empty) }
    Write-Host ("Overall progress: [{0}] {1,3}%  (step {2}/{3})" -f $bar, $pct, $script:CurrentStep, $TotalSteps)
}

# Write-Step does double duty: per-step header AND step counter, so the
# bar's count and the "Step N/12" numbering cannot drift apart -- there is
# only one place that increments anything.
function Write-Step {
    param([string]$Message)
    $script:CurrentStep++
    Write-Host ""
    Draw-ProgressBar
    Write-Host ">>> Step $($script:CurrentStep)/$($TotalSteps): $Message"
}
function Write-Warn {
    param([string]$Message)
    Write-Host "WARNING: $Message"
    $Warnings.Add($Message) | Out-Null
}

New-Item -ItemType Directory -Path $LocalBin -Force | Out-Null

# winget is the package manager for Steps 1, 2, 4 and 9. It ships with
# Windows 10 1809+ and Windows 11 as the "App Installer" package, but can
# be missing on a stripped image or an account that has never opened the
# Store. Checked once here so each step can degrade with a useful message
# instead of four identical "not recognized" errors.
$HasWinget = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
if (-not $HasWinget) {
    Write-Warn "winget was not found. ffmpeg, git, PowerShell 7 and the video player cannot be installed automatically. Install 'App Installer' from the Microsoft Store (or from https://aka.ms/getwinget), then re-run this script. The folder-structure and file-placement steps further down will still run without it."
}

function Invoke-Winget {
    param([string]$Id, [string]$Label)
    if (-not $HasWinget) {
        Write-Warn "Skipped installing $Label -- winget is not available."
        return
    }
    # --accept-*-agreements are required for an unattended run; without
    # them winget stops and waits for a keypress that will never come in a
    # scripted context. --disable-interactivity covers the same class of
    # prompt for newer winget versions.
    & winget install --id $Id --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 |
        ForEach-Object { Write-Host "  [winget] $_" }
    # winget exits non-zero for "already installed" as well as for real
    # failures, so the exit code alone can't distinguish them. The caller
    # verifies by checking for the actual command afterwards instead.
}

# --- Step 1: update the package source ---
Write-Step "Updating the winget package source"
# Deliberately only refreshes winget's SOURCE INDEX rather than running
# `winget upgrade --all`. The Unix installer's Step 1 does a full system
# upgrade because on a purpose-built Ubuntu VM that is expected and safe;
# a Windows machine running this is far more likely to be the user's
# actual daily-driver PC, where silently upgrading every installed
# application as a side effect of setting up a video archiver is not a
# reasonable thing for this script to decide on its own.
if ($HasWinget) {
    & winget source update 2>&1 | ForEach-Object { Write-Host "  [winget] $_" }
} else {
    Write-Host "Skipped -- winget is not available."
}

# --- Step 2: base dependencies ---
Write-Step "Installing ffmpeg, git, and Python"
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Write-Host "ffmpeg already present ($((& ffmpeg -version 2>$null | Select-Object -First 1))) -- skipping."
} else {
    # Gyan.FFmpeg is the same build the old Windows script's update check
    # pointed at (gyan.dev), now installed and version-tracked through
    # winget instead of downloaded by hand.
    Invoke-Winget -Id "Gyan.FFmpeg" -Label "ffmpeg"
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Invoke-Winget -Id "Git.Git" -Label "git"
}
if (-not (Get-Command python3 -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
    # Only the archive viewer needs Python -- nothing in the download
    # pipeline itself touches it -- so this is a convenience install, not a
    # requirement.
    Invoke-Winget -Id "Python.Python.3.12" -Label "Python 3"
}

# --- Step 3: yt-dlp (standalone binary, so -U self-update actually works) ---
Write-Step "Installing yt-dlp"
$YtDlpExe = Join-Path $LocalBin "yt-dlp.exe"
if (Test-Path $YtDlpExe) {
    Write-Host "yt-dlp already present at $YtDlpExe ($(& $YtDlpExe --version 2>$null)) -- skipping install, run 'yt-dlp -U' to update."
} else {
    try {
        # yt-dlp.exe is the Windows release asset (the plain "yt-dlp" asset
        # is the Linux binary and "yt-dlp_macos" the Mac one -- see
        # setup.sh's Step 3 for the other two).
        #
        # -UseBasicParsing is harmless on pwsh 7 and required on Windows
        # PowerShell 5.1, where Invoke-WebRequest otherwise tries to use
        # the Internet Explorer engine to parse the response -- which fails
        # outright on a machine where IE has never been configured.
        Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile $YtDlpExe -UseBasicParsing -ErrorAction Stop
        Write-Host "Installed yt-dlp to $YtDlpExe."
        # Windows marks files downloaded from the internet with a
        # Zone.Identifier alternate data stream. For a plain .exe run from
        # a terminal this is usually only a SmartScreen prompt rather than
        # a hard block, but clearing it avoids the prompt entirely -- the
        # same trust decision as macOS's xattr -d com.apple.quarantine in
        # setup.sh.
        Unblock-File -Path $YtDlpExe -ErrorAction SilentlyContinue
    } catch {
        Write-Warn "yt-dlp download failed: $($_.Exception.Message). Retry manually by saving https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe to $YtDlpExe"
    }
}

# --- Step 4: PowerShell 7 ---
Write-Step "Installing PowerShell 7 (pwsh)"
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    Write-Host "pwsh already present ($(& pwsh --version)) -- skipping."
} else {
    Invoke-Winget -Id "Microsoft.PowerShell" -Label "PowerShell 7"
    # winget installs pwsh onto the machine PATH, but the CURRENT process
    # inherited its environment before that happened -- so Get-Command
    # would still miss it for the rest of this run without re-reading the
    # stored Path. This matters because Step 12 verifies pwsh, and the
    # syntax check there shells out to it.
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Write-Warn "pwsh still not found after the install attempt. Nothing in this pipeline can run without it -- install it manually from https://aka.ms/powershell and re-run this script."
    }
}

# --- Step 5: curl_cffi (fixes the "no impersonate target" warning) ---
Write-Step "Installing curl_cffi (browser-impersonation support for yt-dlp)"
$PythonCmd = $null
foreach ($candidate in @("python3", "python")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $PythonCmd = $candidate; break }
}
if ($PythonCmd) {
    # No --break-system-packages here, unlike the Unix installer: Windows
    # Python installs are not "externally managed" in the PEP 668 sense, so
    # the flag is unnecessary (and older pips reject it outright).
    & $PythonCmd -m pip install -U "curl_cffi>=0.10" 2>&1 | ForEach-Object { Write-Host "  [pip] $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "curl_cffi install failed. yt-dlp will keep warning about missing impersonation targets until you retry: $PythonCmd -m pip install -U `"curl_cffi>=0.10`""
    }
} else {
    Write-Warn "No Python found, so curl_cffi was not installed. yt-dlp will warn about missing impersonation targets. Install Python and retry: python -m pip install -U `"curl_cffi>=0.10`""
}

# --- Step 6: Deno (JS runtime -- YouTube now requires solving a JS
# challenge for cipher decryption) ---
Write-Step "Installing Deno (JavaScript runtime required for current YouTube extraction)"
$DenoExe = Join-Path $env:USERPROFILE ".deno\bin\deno.exe"
if (Test-Path $DenoExe) {
    Write-Host "deno already present at $DenoExe ($(& $DenoExe --version 2>$null | Select-Object -First 1)) -- skipping."
} else {
    try {
        # Deno's own official Windows installer, the direct counterpart to
        # the install.sh the Unix installer pipes to sh. It installs to
        # $env:USERPROFILE\.deno\bin, which is exactly where
        # run_ytdlp.ps1's platform block looks first on Windows.
        $denoInstaller = Invoke-RestMethod -Uri "https://deno.land/install.ps1" -UseBasicParsing -ErrorAction Stop
        # $env:DENO_INSTALL_ROOT is not set, so the installer uses its own
        # default of ~\.deno -- matching $DenoExe above.
        Invoke-Expression $denoInstaller 2>&1 | ForEach-Object { Write-Host "  [deno] $_" }
        if (Test-Path $DenoExe) {
            Write-Host "Installed deno to $DenoExe."
        } else {
            Write-Warn "Deno's installer ran but deno.exe was not found at $DenoExe. YouTube downloads may hit HTTP 403 errors or miss formats until this is resolved."
        }
    } catch {
        Write-Warn "Deno install failed: $($_.Exception.Message). YouTube downloads may hit errors or miss formats until this is resolved. Retry manually: irm https://deno.land/install.ps1 | iex"
    }
}
# run_ytdlp.ps1 does not require deno at one exact hardcoded path: on
# Windows it probes ~\.deno\bin\deno.exe, then ~\.local\bin\deno.exe, then
# PATH, and logs a clear warning if none of them hit.

# --- Step 7: fetch the project files ---
# Same rationale as setup.sh's Step 7: individual HTTPS GETs of known
# filenames rather than a git clone. Nothing else in this project needs
# git, a plain GET has far fewer ways to fail on a fresh machine, and it
# does not matter whether the repo is public, private or reachable over
# SSH. Files already sitting next to setup.ps1 are used as-is and never
# downloaded over -- load-bearing for the edit-then-reinstall loop.
Write-Step "Downloading project files"
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
$WarningsBeforeDownload = $Warnings.Count
foreach ($projectFile in $ProjectFiles) {
    $localCopy = Join-Path $ScriptDir $projectFile
    if (Test-Path $localCopy) {
        Write-Host "Using local '$projectFile' from $ScriptDir -- not downloading."
        continue
    }
    $part = Join-Path $DownloadDir ($projectFile + ".part")
    try {
        Invoke-WebRequest -Uri "$RawBase/$projectFile" -OutFile $part -UseBasicParsing -ErrorAction Stop
        $item = Get-Item $part -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -eq 0) {
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            Write-Warn "Downloaded '$projectFile' was empty -- treating as a failed download. Fetch it manually from $RawBase/$projectFile into $DownloadDir"
        } elseif ((Get-Content $part -TotalCount 1 -ErrorAction SilentlyContinue) -match '^\s*<(!doctype|html)') {
            # Invoke-WebRequest throws on an HTTP error status, but not on a
            # proxy or captive portal that answers 200 with its own HTML
            # page. None of these files is HTML, so a first line that looks
            # like markup means something intercepted the request.
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            Write-Warn "'$projectFile' came back as an HTML page rather than the file itself -- something (a proxy, captive portal, or DNS interception) answered instead of GitHub. Check this machine's network, then re-run."
        } else {
            Move-Item -Path $part -Destination (Join-Path $DownloadDir $projectFile) -Force
            Write-Host "Downloaded $projectFile"
        }
    } catch {
        Remove-Item $part -Force -ErrorAction SilentlyContinue
        Write-Warn "Could not download '$projectFile' from $RawBase/$projectFile ($($_.Exception.Message)). Check network/DNS, or place the file next to setup.ps1 ($ScriptDir) and re-run."
    }
}

# --- Step 8: VMware shared folder support ---
Write-Step "Setting up VMware shared folder (open-vm-tools)"
# Kept as a numbered step purely so the step numbering matches setup.sh's,
# which makes a Windows setup log and a Linux setup log directly
# comparable. The step itself has no Windows meaning: it configures a Linux
# VM GUEST's access to its host's shared folders, and a Windows machine
# running this installer is the host.
Write-Host "Not applicable on Windows (this step configures a Linux VM guest's access to its host's shared folders) -- skipping."

# --- Step 9: viewing thumbnails and subtitles in the desktop ---
Write-Step "Installing desktop preview support (thumbnails and subtitles)"
# Far less to do here than on Linux. Windows 10 1809+ and Windows 11
# already render .webp in Explorer and the Photos app natively, so there is
# no equivalent of webp-pixbuf-loader to install, and no thumbnail size cap
# to raise. What Windows genuinely lacks is any built-in way to play .mkv
# with selectable subtitle tracks -- the Media Player app's Matroska
# support is inconsistent and it will not auto-load the sidecar .vtt files
# this pipeline writes -- so VLC is the one thing worth installing.
if (Get-Command vlc -ErrorAction SilentlyContinue) {
    Write-Host "VLC already present -- skipping."
} elseif (Test-Path "${env:ProgramFiles}\VideoLAN\VLC\vlc.exe") {
    Write-Host "VLC already present at ${env:ProgramFiles}\VideoLAN\VLC\vlc.exe -- skipping."
} else {
    Invoke-Winget -Id "VideoLAN.VLC" -Label "VLC"
}
Write-Host "Explorer previews .webp thumbnails natively on Windows 10 1809+ and Windows 11 -- no thumbnailer packages needed."
Write-Host "NOTE: Explorer does NOT generate poster-frame thumbnails for .mkv out of the box. If you want those, install a shell thumbnail extension such as Icaros -- nothing in the pipeline depends on it."

# --- Step 10: folder structure ---
Write-Step "Creating folder structure under $DataRoot"
foreach ($folder in @(
    (Join-Path $DataRoot "scripts"),
    (Join-Path $DataRoot "configs"),
    (Join-Path $DataRoot "Archive Logs\Archive History"),
    (Join-Path $DataRoot "Archive Logs\Logs"),
    (Join-Path $DataRoot "Youtube Videos\Complete Archive"),
    (Join-Path $DataRoot "Youtube Videos\_incomplete"),
    (Join-Path $DataRoot "Youtube Videos\Final Video")
)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}
Write-Host "Folder structure created."

# --- Step 11: place the pipeline files and the archive viewer ---
Write-Step "Installing pipeline files"
function Copy-ProjectFile {
    param([string]$Source, [string]$Destination, [string]$Label)
    $candidates = @(
        (Join-Path $ScriptDir $Source),
        (Join-Path $DownloadDir $Source)
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            Copy-Item -Path $candidate -Destination $Destination -Force
            Write-Host "Installed $Label -> $Destination (from $candidate)"
            return
        }
    }
    Write-Warn "$Source not found in any of: $($candidates -join ', ') -- $Label was NOT installed. Copy it to $Destination manually."
}
# Snapshot the warning count right before these copies -- compared again
# below to decide whether it's safe to delete the downloaded files.
$WarningsBeforeInstall = $Warnings.Count
# These file names have no platform prefix: run_ytdlp.ps1, postprocess.ps1
# and yt-dlp.conf are now one cross-platform set shared with Linux and
# macOS rather than a separate windows-* copy that has to be kept in sync.
Copy-ProjectFile -Source "run_ytdlp.ps1"     -Destination (Join-Path $DataRoot "scripts\run_ytdlp.ps1")     -Label "run_ytdlp.ps1"
Copy-ProjectFile -Source "postprocess.ps1"   -Destination (Join-Path $DataRoot "scripts\postprocess.ps1")   -Label "postprocess.ps1"
Copy-ProjectFile -Source "yt-dlp.conf"       -Destination (Join-Path $DataRoot "configs\yt-dlp.conf")       -Label "yt-dlp.conf"
# The launcher pair. ytdl.ps1 does the real argument parsing and lives with
# the other scripts; ytdl.cmd is the shim that goes on PATH, so that typing
# `ytdl` works from cmd.exe, PowerShell and the Run box alike.
Copy-ProjectFile -Source "ytdl.ps1"          -Destination (Join-Path $DataRoot "scripts\ytdl.ps1")          -Label "ytdl.ps1"
Copy-ProjectFile -Source "ytdl.cmd"          -Destination (Join-Path $LocalBin "ytdl.cmd")                  -Label "ytdl"
Copy-ProjectFile -Source "archive-viewer.py" -Destination (Join-Path $DataRoot "scripts\archive-viewer.py") -Label "archive-viewer.py"

# Unblock everything just copied. Files that arrived via Invoke-WebRequest
# carry the Zone.Identifier stream, and a .ps1 marked as
# internet-downloaded is refused outright by the default RemoteSigned
# execution policy -- which would make `ytdl` fail with a security error
# rather than anything that points at the real cause.
Get-ChildItem -Path (Join-Path $DataRoot "scripts") -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
Unblock-File -Path (Join-Path $LocalBin "ytdl.cmd") -ErrorAction SilentlyContinue
Unblock-File -Path (Join-Path $DataRoot "configs\yt-dlp.conf") -ErrorAction SilentlyContinue

# --- ytdl-view launcher ---
# Written here rather than shipped as a repo file, same as in setup.sh:
# its entire content is a single line, so a repo file would exist only to
# be copied and would be one more thing to keep in sync.
$viewerPath = Join-Path $DataRoot "scripts\archive-viewer.py"
if (Test-Path $viewerPath) {
    if ($PythonCmd) {
        $viewLauncher = Join-Path $LocalBin "ytdl-view.cmd"
        # %* passes the raw remainder of the command line through, so
        # --root "D:\Some Path" survives with its quoting intact.
        $viewLauncherBody = @"
@echo off
REM Generated by setup.ps1 -- thin launcher for archive-viewer.py.
REM All arguments pass straight through: --root, --port, --host,
REM --allow-open-local, --rescan, --help, and so on.
$PythonCmd "$viewerPath" %*
"@
        Set-Content -Path $viewLauncher -Value $viewLauncherBody -Encoding ASCII
        Write-Host "Installed ytdl-view -> $viewLauncher (launches the archive viewer)"
    } else {
        Write-Warn "No Python found, so the 'ytdl-view' launcher was skipped. Install Python and re-run this script to get it."
    }
} else {
    Write-Warn "archive-viewer.py was not installed, so the 'ytdl-view' launcher was skipped."
}

# PATH wiring. Writes to the USER environment (not Machine), so no
# elevation is needed -- consistent with everything else here installing
# into user-owned locations.
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }
$pathEntries = $userPath -split ';' | Where-Object { $_ -ne "" }
if ($pathEntries -notcontains $LocalBin) {
    $newPath = if ($userPath -eq "") { $LocalBin } else { "$userPath;$LocalBin" }
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    # Also update THIS process so the Step 12 verification below can find
    # ytdl without the user having to open a new window first.
    $env:Path = "$env:Path;$LocalBin"
    Write-Host "Added $LocalBin to your user PATH -- open a new terminal window before using 'ytdl' from elsewhere."
}

# --- Clean up the downloaded installation files now that they're copied ---
# Only deleted if every Copy-ProjectFile call above actually succeeded. If
# anything failed to install, the download is deliberately left in place --
# it may be the only remaining copy of a file that never made it to its
# destination, so deleting it here would destroy the one thing needed to
# fix the problem by hand. Never touches anything placed next to setup.ps1
# by hand: $DownloadDir is a subfolder Step 7 creates, and Step 7 skips
# downloading anything already present beside the installer.
if (Test-Path $DownloadDir) {
    if ($Warnings.Count -eq $WarningsBeforeInstall) {
        Remove-Item -Path $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed downloaded installation files at '$DownloadDir' (already copied into place, no longer needed)."
    } else {
        Write-Host "Leaving '$DownloadDir' in place -- at least one file above failed to install from it (see the WARNING(s) further up). Once that's resolved and you've confirmed everything under $DataRoot\scripts and $DataRoot\configs is correct, it's safe to delete manually."
    }
}

# --- Step 12: verify ---
Write-Step "Verifying installation"
function Get-VersionOrMissing {
    param([scriptblock]$Probe, [string]$Missing = "NOT FOUND")
    try {
        $result = & $Probe 2>$null
        if ($result) { return ($result | Select-Object -First 1) }
        return $Missing
    } catch {
        return $Missing
    }
}
Write-Host "platform: windows"
# yt-dlp is checked via its full path rather than the bare command, for the
# same reason setup.sh does: $LocalBin was only just added to PATH, and a
# bare lookup would report a false NOT FOUND immediately after a successful
# install.
Write-Host "yt-dlp:  $(if (Test-Path $YtDlpExe) { Get-VersionOrMissing { & $YtDlpExe --version } } else { 'NOT FOUND' })"
Write-Host "ffmpeg:  $(Get-VersionOrMissing { & ffmpeg -version })"
Write-Host "ffprobe: $(Get-VersionOrMissing { & ffprobe -version } 'NOT FOUND (postprocess.ps1 needs this for the info.json re-embed)')"
Write-Host "pwsh:    $(Get-VersionOrMissing { & pwsh --version })"
Write-Host "deno:    $(if (Test-Path $DenoExe) { Get-VersionOrMissing { & $DenoExe --version } } else { 'NOT FOUND' })"
Write-Host "git:     $(Get-VersionOrMissing { & git --version })"
Write-Host "python:  $(if ($PythonCmd) { Get-VersionOrMissing { & $PythonCmd --version } } else { 'NOT FOUND (only the archive viewer needs it)' })"
Write-Host "ytdl:    $(if (Test-Path (Join-Path $LocalBin 'ytdl.cmd')) { Join-Path $LocalBin 'ytdl.cmd' } else { 'NOT FOUND' })"
Write-Host "ytdl-view: $(if (Test-Path (Join-Path $LocalBin 'ytdl-view.cmd')) { Join-Path $LocalBin 'ytdl-view.cmd' } else { 'NOT FOUND' })"

# Compiles the viewer without running it -- catches a truncated or
# corrupted download that Copy-ProjectFile itself has no way to notice.
if ((Test-Path $viewerPath) -and $PythonCmd) {
    $env:PYTHONPYCACHEPREFIX = $env:TEMP
    & $PythonCmd -m py_compile $viewerPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "viewer:  archive-viewer.py installed and parses cleanly"
    } else {
        Write-Warn "archive-viewer.py is installed but does not compile -- the download may be truncated. Delete $viewerPath and re-run this script."
    }
}

# Syntax-check the two pipeline scripts without executing them. Worth
# having now that one file serves three platforms -- a syntax error
# introduced while editing would otherwise only surface at the end of a
# real download, after the video is already on disk and the after_move
# hook fires. Uses the PowerShell parser directly, so it validates the
# pwsh 7 syntax in those files even though this installer itself may be
# running under Windows PowerShell 5.1.
foreach ($psScript in @("run_ytdlp.ps1", "postprocess.ps1", "ytdl.ps1")) {
    $scriptPath = Join-Path $DataRoot "scripts\$psScript"
    if (Test-Path $scriptPath) {
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors) | Out-Null
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            Write-Warn "$psScript has $($parseErrors.Count) PowerShell syntax error(s) -- it will fail at runtime. First: $($parseErrors[0].Message)"
        } else {
            Write-Host "syntax:  $psScript parses cleanly"
        }
    }
}

# Long-path check. This is Windows-specific and worth surfacing explicitly
# rather than leaving to be discovered as a mysterious mid-download failure
# on a video with a long title -- see yt-dlp.conf's folder-structure notes
# for the arithmetic.
try {
    $longPaths = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -ErrorAction Stop
    if ($longPaths -eq 1) {
        Write-Host "longpath: enabled (paths over 260 characters are allowed)"
    } else {
        Write-Host "longpath: DISABLED -- paths are capped at 260 characters. Most videos are fine, but a long channel name plus a long title can exceed it. To enable: run as Administrator 'New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force' and reboot."
    }
} catch {
    Write-Host "longpath: could not read the LongPathsEnabled setting -- assuming the 260-character default applies."
}

# NOTE: this final summary deliberately does NOT call Write-Step -- that is
# what advances the step counter, and all 12 real steps are already done by
# this point. Calling it again would push the bar past 100%.
Write-Host ""
Draw-ProgressBar
if ($Warnings.Count -gt 0) {
    Write-Host ">>> Setup finished with $($Warnings.Count) item(s) needing attention:"
    foreach ($w in $Warnings) { Write-Host "  - $w" }
} else {
    Write-Host ">>> Setup complete, no issues detected."
}
Write-Host ""
Write-Host "Full console log saved to: $LogFile"
Write-Host ""
Write-Host "Test with: ytdl `"https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID`""
Write-Host "Then browse what you archived -- video, subtitles, transcript, metadata"
Write-Host "and the full comment thread -- with: ytdl-view"
Write-Host "  (add --root D:\path\to\archive if you downloaded to a custom data root,"
Write-Host "   and --allow-open-local to let the page hand files to VLC)"

if ($TranscriptRunning) {
    try { Stop-Transcript | Out-Null } catch {}
}
