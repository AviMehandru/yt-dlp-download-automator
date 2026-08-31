<#
.SYNOPSIS
    Bootstrap installer for the yt-dlp archival pipeline on Windows.

.DESCRIPTION
    THIS SCRIPT IS HALF THE INSTALLER. It performs Steps 1-6 -- everything
    that has to talk to winget, plus installing pwsh itself -- and then
    hands over to scripts\setup-common.ps1 for Steps 7-12, which it shares
    byte-for-byte with the Unix bootstrap, setup.sh.

    WHY THE SPLIT LANDS THERE. It is not that these steps are the hard
    ones; it is that they have nearly nothing worth sharing. Steps 1-4 are
    winget invocations here and apt/dnf/pacman/zypper/brew invocations
    there. Step 5 (VMware shared folders) is meaningful only inside a Linux
    VM guest and is a no-op on Windows. Step 6 (desktop previews) is VLC
    via winget here, a Homebrew cask on macOS, and webp-pixbuf-loader plus
    ffmpegthumbnailer on Linux -- three implementations of one sentence
    with no shared body to factor out. Steps 7-12 are the opposite:
    fetching the project files, creating the folder tree, copying files
    into place, writing the launchers, wiring PATH and verifying are the
    same work on every platform, and used to be roughly 600 lines
    maintained twice. Now they exist once.

    STEP NUMBERING. Steps 5 and 6 here were Steps 8 and 9 before the split,
    and the old Steps 5-7 (curl_cffi, Deno, fetch) moved into the shared
    file as 7-9. The step COUNT is still 12, so a Windows setup log and a
    Linux one stay directly comparable.

    IMPORTANT: this script is written to run under Windows PowerShell 5.1
    (the version that ships with Windows) as well as PowerShell 7, because
    installing PowerShell 7 is one of the things it does. That rules out
    7-only syntax throughout: no ternary operator, no null-coalescing, no
    ForEach-Object -Parallel, and no reliance on $IsWindows. The shared
    half and the pipeline scripts it installs ARE pwsh 7 scripts and do use
    all of that -- which is exactly why they run only after Step 4.

    Deliberately does NOT use a global "stop on any error". Every external
    command that could plausibly fail on some systems (a winget package
    temporarily unavailable, a flaky network blip) is wrapped so a failure
    prints a clear WARNING and the script keeps going.

    The one thing that IS fatal is pwsh: Steps 7-12 run under it, so if
    Step 4 could not install it this script stops with an explanation
    rather than pretending. That is a change from the previous behavior,
    which went on to place files that could not be used -- run_ytdlp.ps1
    and postprocess.ps1 ARE pwsh 7 scripts, so a pwsh-less install
    downloaded nothing. Installing pwsh by hand and re-running is
    idempotent and cheap.

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

# winget is the package manager for Steps 1, 2, 4 and 6. It ships with
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
    # stored Path. This is load-bearing now rather than merely tidy: the
    # handoff at the bottom of this script LAUNCHES pwsh, so if this
    # refresh is skipped the whole shared half is unreachable on the very
    # run that just installed it.
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Write-Warn "pwsh still not found after the install attempt. Nothing in this pipeline can run without it -- install it manually from https://aka.ms/powershell and re-run this script."
    }
}

# --- Step 5: VMware shared folder support ---
Write-Step "Setting up VMware shared folder (open-vm-tools)"
# Kept as a numbered step purely so the step numbering matches setup.sh's,
# which makes a Windows setup log and a Linux setup log directly
# comparable. The step itself has no Windows meaning: it configures a Linux
# VM GUEST's access to its host's shared folders, and a Windows machine
# running this installer is the host.
Write-Host "Not applicable on Windows (this step configures a Linux VM guest's access to its host's shared folders) -- skipping."

# --- Step 6: viewing thumbnails and subtitles in the desktop ---
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

# --- Hand off to the shared installer for Steps 7-12 ---
# Everything from here -- curl_cffi, Deno, fetching the project files, the
# folder tree, placing files, the launchers, PATH wiring and verification
# -- is identical on Windows, Linux and macOS, and lives in
# scripts\setup-common.ps1 so there is exactly one copy of it.
#
# The warnings collected above are passed through rather than summarised
# here, so the final report at the end of the shared half covers the whole
# install rather than just its own steps. Same for the step counter: the
# progress bar continues from Step 6 instead of restarting, so the two
# processes read as one run.
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: pwsh (PowerShell 7) is not available, so Steps 7-12 cannot run."
    Write-Host ""
    Write-Host "Those steps place the pipeline files and create the folder tree, but"
    Write-Host "every one of those files is a pwsh 7 script -- an install without pwsh"
    Write-Host "cannot download anything, so there is nothing useful to do here without"
    Write-Host "it. See the WARNING from Step 4 above for what failed."
    Write-Host ""
    Write-Host "Install PowerShell 7 from https://aka.ms/powershell, then re-run this"
    Write-Host "script. It is safe to re-run: every step checks before it acts."
    Write-Host ""
    if ($Warnings.Count -gt 0) {
        Write-Host "Warnings so far:"
        foreach ($w in $Warnings) { Write-Host "  - $w" }
        Write-Host ""
    }
    Write-Host "Full console log saved to: $LogFile"
    if ($TranscriptRunning) { try { Stop-Transcript | Out-Null } catch {} }
    exit 1
}

# Located beside this script when running from a repo checkout, and inside
# the install root when re-running from an installed copy. The download
# fallback exists for the case that matters most: a lone setup.ps1 saved on
# a fresh machine, where neither copy is present yet.
$CommonPs1 = $null
foreach ($candidate in @(
    (Join-Path $ScriptDir "scripts\setup-common.ps1"),
    (Join-Path $ScriptDir "setup-common.ps1"),
    (Join-Path $DataRoot  "scripts\setup-common.ps1")
)) {
    if (Test-Path $candidate) { $CommonPs1 = $candidate; break }
}

if (-not $CommonPs1) {
    $commonUrl = "https://raw.githubusercontent.com/AviMehandru/yt-dlp-download-automator/main/scripts/setup-common.ps1"
    $CommonPs1 = Join-Path $env:TEMP "setup-common.ps1"
    Write-Host "Fetching the shared installer half from $commonUrl"
    try {
        Invoke-WebRequest -Uri $commonUrl -OutFile $CommonPs1 -UseBasicParsing -ErrorAction Stop
        # Downloaded .ps1 files carry the Zone.Identifier stream and are
        # refused outright by the default RemoteSigned execution policy --
        # which would fail here with a security error rather than anything
        # that points at the real cause.
        Unblock-File -Path $CommonPs1 -ErrorAction SilentlyContinue
    } catch {
        Write-Host ""
        Write-Host "ERROR: could not download setup-common.ps1 from $commonUrl"
        Write-Host "($($_.Exception.Message)). Check network/DNS, or place the file"
        Write-Host "next to this script and re-run."
        Write-Host ""
        Write-Host "Full console log saved to: $LogFile"
        if ($TranscriptRunning) { try { Stop-Transcript | Out-Null } catch {} }
        exit 1
    }
}

# Built as an argument ARRAY rather than a command string, so a path
# containing spaces (C:\Users\Some Name\...) needs no quoting logic here.
$commonArgs = @(
    "-NoProfile", "-File", $CommonPs1,
    "-DataRoot",      $DataRoot,
    "-LocalBin",      $LocalBin,
    "-SourceDir",     $ScriptDir,
    "-PlatformLabel", "windows",
    "-StartStep",     $script:CurrentStep,
    "-TotalSteps",    $TotalSteps
)
# Handed over in a temp file rather than as arguments. An array parameter
# does not survive `pwsh -File`: each argv entry binds separately, so the
# second warning would be rejected as an unexpected positional argument.
# A file also means no warning text -- which is free-form English full of
# quotes, colons and dashes -- ever has to survive command-line quoting.
# setup-common.ps1 reads it and deletes it.
if ($Warnings.Count -gt 0) {
    $warnFile = Join-Path $env:TEMP ("ytdlp-setup-warnings-{0}.txt" -f [System.Guid]::NewGuid().ToString("N"))
    Set-Content -Path $warnFile -Value $Warnings -Encoding UTF8
    $commonArgs += @("-InheritedWarningsFile", $warnFile)
}

# Piped through Write-Host rather than left to the transcript alone, for
# the same reason every winget call above is: Start-Transcript does not
# capture a child process's raw stdout reliably.
& pwsh @commonArgs 2>&1 | ForEach-Object { Write-Host $_ }
$commonExit = $LASTEXITCODE

Write-Host ""
Write-Host "Full console log saved to: $LogFile"
if ($TranscriptRunning) {
    try { Stop-Transcript | Out-Null } catch {}
}
exit $commonExit
