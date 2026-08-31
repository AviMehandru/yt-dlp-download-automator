<#
.SYNOPSIS
    Steps 7-12 of the installer, shared by every platform.

.DESCRIPTION
    setup.sh (Linux and macOS) and setup.ps1 (Windows) are BOOTSTRAPS. They
    do Steps 1-6 -- everything that has to talk to a specific operating
    system's package manager, plus installing pwsh itself -- and then hand
    over to this file for the rest. Steps 7-12 are the ones where the three
    platforms were doing substantially the same work in two languages:
    fetching the project files, creating the folder tree, copying files
    into place, writing the launchers, wiring PATH, and verifying. That is
    roughly 600 lines that used to exist twice, and this is the one copy.

    WHY THE SPLIT LANDS HERE AND NOT SOMEWHERE ELSE. It is not that Steps
    1-6 are "the hard ones"; it is that they have nearly nothing in common
    to share. Step 1-4 are apt/dnf/pacman/zypper/brew/winget invocations
    with per-family quirks. Step 5 (VMware shared folders) is meaningful
    only inside a Linux VM guest. Step 6 (desktop previews) is
    webp-pixbuf-loader and ffmpegthumbnailer on Linux, a Homebrew cask on
    macOS, and VLC via winget on Windows -- three implementations of one
    sentence, with no shared body to factor out. Merging those would mean
    writing a package-manager abstraction in PowerShell that duplicates
    the one setup.sh already needs for its own Steps 1-2. Steps 7-12, by
    contrast, are the same work everywhere, with small $IsWindows branches.

    NOTE ON STEP ORDER. Steps 5 and 6 here (VMware, desktop previews) were
    Steps 8 and 9 before this split, and old Steps 5-7 (curl_cffi, Deno,
    fetch) moved down to 7-9. Nothing depends on the old relative order --
    the moved steps need only the base packages from Step 2 -- and the
    reorder is what makes the native/shared boundary a single clean cut
    rather than two separate handoffs. The step COUNT is still 12, so a log
    from any platform still reads "Step N/12" and stays comparable.

    REQUIRES pwsh 7, which Step 4 of the bootstrap installs. That is a real
    behavior change worth stating plainly: previously, if the pwsh install
    failed, the later steps still ran and still placed files. Now they
    cannot, and the bootstrap says so and stops. The files it would have
    placed were never usable without pwsh anyway -- run_ytdlp.ps1 and
    postprocess.ps1 ARE PowerShell -- so the old behavior produced a
    complete-looking install that could not download anything. Installing
    pwsh and re-running the bootstrap is idempotent and cheap.

.PARAMETER DataRoot
    The install root: where scripts/, configs/, Archive Logs/ and Youtube
    Videos/ live. Chosen by the bootstrap, which knows the platform default.

.PARAMETER LocalBin
    The user-owned directory that goes on PATH and holds the `ytdl` and
    `ytdl-view` commands.

.PARAMETER SourceDir
    Where the bootstrap itself lives. Files found here (either at their
    repo-relative path, or flat) are used as-is and never downloaded --
    load-bearing for the edit-then-reinstall loop.

.PARAMETER PlatformLabel
    A human-readable platform string for the verification output, e.g.
    "linux (Ubuntu 24.04 -- family debian, package manager apt)". Built by
    the bootstrap, which is the only thing that knows the distro details.

.PARAMETER StartStep
    The step number already reached by the bootstrap. The progress bar
    continues from here rather than restarting, so the two processes read
    as one run.

.PARAMETER InheritedWarningsFile
    Path to a temp file holding the warnings the bootstrap accumulated in
    Steps 1-6, one per line, so the final summary covers the whole install
    rather than just this half of it. Consumed and deleted here.

    A FILE rather than a [string[]] parameter, which is what this was
    first written as. Array parameters do not survive `pwsh -File`: each
    argv entry binds separately, so `-InheritedWarnings "first" "second"`
    binds only "first" and then fails with "a positional parameter cannot
    be found that accepts argument 'second'". Packing them into one
    delimited string instead would work, but only by picking a delimiter
    that can never appear in a free-text warning and then trusting it
    through two different command-line quoting rules. A file has neither
    problem. Found by an actual dry run, not by reading the code.

.PARAMETER HasDesktop
    Whether the bootstrap found a desktop environment installed. Only
    affects how the verification reports previews: a deliberate skip on a
    headless box should not read as a failure.
#>

param(
    [Parameter(Mandatory = $true)] [string]   $DataRoot,
    [Parameter(Mandatory = $true)] [string]   $LocalBin,
    [Parameter(Mandatory = $true)] [string]   $SourceDir,
    [string]   $PlatformLabel     = "unknown",
    [int]      $StartStep         = 6,
    [int]      $TotalSteps        = 12,
    [string]   $InheritedWarningsFile = "",
    [switch]   $HasDesktop
)

# Same keep-going principle as the bootstraps: every external command that
# could plausibly fail on some system is wrapped so a failure prints a
# clear WARNING and the run continues. A hard stop here would leave the
# install half-placed, which is worse than a complete install with a
# warning list at the end.
$ErrorActionPreference = "Continue"

$Warnings = New-Object System.Collections.Generic.List[string]
if ($InheritedWarningsFile -and (Test-Path $InheritedWarningsFile)) {
    foreach ($w in (Get-Content -Path $InheritedWarningsFile -ErrorAction SilentlyContinue)) {
        if ($w -and $w.Trim()) { $Warnings.Add($w) | Out-Null }
    }
    # Consumed, so the bootstrap does not have to clean up after a run it
    # no longer controls.
    Remove-Item -Path $InheritedWarningsFile -Force -ErrorAction SilentlyContinue
}

$script:CurrentStep = $StartStep

function Draw-ProgressBar {
    $width  = 30
    $pct    = [int](($script:CurrentStep * 100) / $TotalSteps)
    $filled = [int](($script:CurrentStep * $width) / $TotalSteps)
    $empty  = $width - $filled
    $bar = ""
    if ($filled -gt 0) { $bar += ("#" * $filled) }
    if ($empty  -gt 0) { $bar += ("-" * $empty) }
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

# Platform-dependent names and locations, resolved once. Everything below
# refers to these rather than re-testing $IsWindows inline, so the
# platform differences are visible in one block instead of scattered
# through six steps.
$RawBase     = "https://raw.githubusercontent.com/AviMehandru/yt-dlp-download-automator/main"
$DownloadDir = Join-Path $SourceDir "YT-DLP Installation Files"
$ScriptsDir  = Join-Path $DataRoot "scripts"
$ConfigsDir  = Join-Path $DataRoot "configs"

if ($IsWindows) {
    $YtDlpBin    = Join-Path $LocalBin "yt-dlp.exe"
    $DenoBin     = Join-Path $env:USERPROFILE ".deno\bin\deno.exe"
    $LauncherSrc = "scripts/ytdl.cmd"     # the PATH entry on Windows
    $LauncherDst = Join-Path $LocalBin "ytdl.cmd"
} else {
    $YtDlpBin    = Join-Path $LocalBin "yt-dlp"
    $DenoBin     = Join-Path $LocalBin "deno"
    $LauncherSrc = "scripts/ytdl"         # the PATH entry on Linux and macOS
    $LauncherDst = Join-Path $LocalBin "ytdl"
}

# Python is needed only by the archive viewer -- nothing in the download
# pipeline itself touches it -- so a miss here is a missing convenience,
# not a broken install.
$PythonCmd = $null
foreach ($candidate in @("python3", "python")) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $PythonCmd = $candidate; break }
}

# --- Step 7: curl_cffi (fixes the "no impersonate target" warning) ---
Write-Step "Installing curl_cffi (browser-impersonation support for yt-dlp)"
if ($PythonCmd) {
    # --break-system-packages is what lets pip write into an
    # externally-managed environment (PEP 668), which both modern Linux
    # distributions and Homebrew's python are. Windows Python installs are
    # not externally managed in that sense, so the flag is unnecessary
    # there (and older pips reject it outright). The --user retry covers an
    # older pip that does not recognize the flag at all, where --user
    # reaches the same "do not touch system site-packages" outcome by a
    # different route.
    $pipOk = $false
    if ($IsWindows) {
        & $PythonCmd -m pip install -U "curl_cffi>=0.10" 2>&1 | ForEach-Object { Write-Host "  [pip] $_" }
        $pipOk = ($LASTEXITCODE -eq 0)
    } else {
        & $PythonCmd -m pip install -U "curl_cffi>=0.10" --break-system-packages 2>&1 | ForEach-Object { Write-Host "  [pip] $_" }
        $pipOk = ($LASTEXITCODE -eq 0)
        if (-not $pipOk) {
            & $PythonCmd -m pip install -U --user "curl_cffi>=0.10" 2>&1 | ForEach-Object { Write-Host "  [pip] $_" }
            $pipOk = ($LASTEXITCODE -eq 0)
        }
    }
    if (-not $pipOk) {
        Write-Warn "curl_cffi install failed. yt-dlp will keep warning about missing impersonation targets until you retry: $PythonCmd -m pip install -U `"curl_cffi>=0.10`""
    }
} else {
    Write-Warn "No Python found, so curl_cffi was not installed. yt-dlp will warn about missing impersonation targets. Install Python and retry: python -m pip install -U `"curl_cffi>=0.10`""
}

# --- Step 8: Deno (JS runtime -- YouTube now requires solving a JS
# challenge for cipher decryption) ---
Write-Step "Installing Deno (JavaScript runtime required for current YouTube extraction)"
if (Test-Path $DenoBin) {
    Write-Host "deno already present at $DenoBin ($(& $DenoBin --version 2>$null | Select-Object -First 1)) -- skipping."
} else {
    # Deno publishes one official installer per platform family, each of
    # which picks the right build for the running architecture itself, so
    # there is no arch branch needed beyond choosing the installer.
    if ($IsWindows) {
        try {
            # $env:DENO_INSTALL_ROOT is not set, so the installer uses its
            # own default of ~\.deno -- matching $DenoBin above, and
            # exactly where run_ytdlp.ps1 looks first on Windows.
            $denoInstaller = Invoke-RestMethod -Uri "https://deno.land/install.ps1" -UseBasicParsing -ErrorAction Stop
            Invoke-Expression $denoInstaller 2>&1 | ForEach-Object { Write-Host "  [deno] $_" }
            if (Test-Path $DenoBin) {
                Write-Host "Installed deno to $DenoBin."
            } else {
                Write-Warn "Deno's installer ran but deno.exe was not found at $DenoBin. YouTube downloads may hit HTTP 403 errors or miss formats until this is resolved."
            }
        } catch {
            Write-Warn "Deno install failed: $($_.Exception.Message). YouTube downloads may hit errors or miss formats until this is resolved. Retry manually: irm https://deno.land/install.ps1 | iex"
        }
    } else {
        # Installed to $LocalBin rather than left in ~/.deno/bin, for the
        # same reason as yt-dlp: one user-owned directory on PATH, no
        # root-owned install location, no ownership mismatch later.
        # Downloaded and THEN run, rather than piped straight into sh.
        # `curl ... | sh` reports the exit status of sh, not of curl, so a
        # failed download (a 403, a captive portal, DNS interception) feeds
        # sh an empty script, sh exits 0, and the failure is misreported as
        # "the installer ran but produced no binary" -- which sends you
        # looking in the wrong place. Two steps make the two failures
        # distinguishable. The previous bash installer had this same flaw.
        $denoLog    = Join-Path ([System.IO.Path]::GetTempPath()) "deno-install.log"
        $denoScript = Join-Path ([System.IO.Path]::GetTempPath()) "deno-install.sh"
        & curl -fsSL --retry 3 --retry-delay 2 "https://deno.land/install.sh" -o $denoScript 2>&1 |
            Out-File -FilePath $denoLog -Encoding UTF8
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not download the Deno installer from https://deno.land/install.sh -- see $denoLog. Check network/DNS. YouTube downloads may hit errors or miss formats until this is resolved."
            $denoDownloadFailed = $true
        } else {
            $denoDownloadFailed = $false
            & sh $denoScript -y 2>&1 | Out-File -FilePath $denoLog -Append -Encoding UTF8
        }
        Remove-Item -Path $denoScript -Force -ErrorAction SilentlyContinue
        if (-not $denoDownloadFailed -and $LASTEXITCODE -eq 0) {
            $denoSrc = Get-ChildItem -Path (Join-Path $HOME ".deno/bin") -Filter "deno" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($denoSrc) {
                Copy-Item -Path $denoSrc.FullName -Destination $DenoBin -Force
                & chmod a+rx $DenoBin
                if ($IsMacOS) {
                    # Gatekeeper quarantines anything downloaded with a
                    # com.apple.quarantine attribute; a quarantined binary
                    # run from a terminal fails with a "developer cannot be
                    # verified" dialog rather than a normal error. Stripping
                    # it from a binary we just fetched ourselves over HTTPS
                    # from a known URL is the same trust decision as
                    # choosing to install it at all.
                    & xattr -d com.apple.quarantine $DenoBin 2>$null
                }
                Write-Host "Installed deno to $DenoBin ($(& $DenoBin --version 2>$null | Select-Object -First 1))."
            } else {
                Write-Warn "The Deno installer ran without error but no binary appeared under $HOME/.deno/bin -- see $denoLog."
            }
        } elseif (-not $denoDownloadFailed) {
            Write-Warn "The Deno installer downloaded but failed while running -- see $denoLog. YouTube downloads may hit errors or miss formats until this is resolved. Retry manually: curl -fsSL https://deno.land/install.sh | sh"
        }
    }
}
# run_ytdlp.ps1 does not require deno at one exact hardcoded path: it
# probes the locations above, then Homebrew's prefixes, then PATH, and
# logs a clear warning if none of them hit. An install somewhere else
# still works -- it just is not the tidiest outcome.

# --- Step 9: fetch the project files ---
# Convenience step: pulls the project files down automatically so Step 11
# can find them without you having to place them by hand.
#
# WHY THIS FETCHES INDIVIDUAL FILES INSTEAD OF CLONING: the honest answer
# is not disk space -- the clone was scratch, deleted a few steps later,
# costing roughly 400 KB transiently against an archive measured in
# gigabytes. The real reasons are that this is the only thing in the entire
# project that ever needed git (nothing in ytdl, run_ytdlp.ps1 or
# postprocess.ps1 touches it), that it no longer matters whether the repo
# is public, private, or reachable over SSH vs HTTPS, and that a plain
# HTTPS GET of six known filenames has far fewer ways to fail on a fresh
# machine than a clone does. git is still installed in Step 2 and still
# reported in Step 12, because you will want it on this machine to edit the
# project -- the pipeline just no longer depends on it.
#
# Each entry is a REPO-RELATIVE path, since the repo now has a scripts/ and
# config/ layout, paired with the bare filename used for the local copy.
# Keep this list in sync with the Install-ProjectFile calls in Step 11: a
# file downloaded but never copied is dead weight, and a file copied but
# never downloaded only works when it happens to sit beside the installer.
$ProjectFiles = @(
    "scripts/run_ytdlp.ps1",
    "scripts/postprocess.ps1",
    "scripts/ytdl.ps1",
    "scripts/archive-viewer.py",
    "config/yt-dlp.conf",
    $LauncherSrc
)

Write-Step "Downloading project files"
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

# Files already sitting beside the installer are used as-is and never
# downloaded over. That is deliberate and load-bearing for the
# edit-then-reinstall loop: if you cloned the repo and are running the
# installer from inside it, your local edits win and nothing is fetched
# from GitHub at all. Both spellings are accepted -- the repo-relative
# path (a real checkout) and a bare filename (files dropped flat beside
# the installer by hand).
function Get-LocalSource {
    param([string]$RepoPath)
    $bare = Split-Path -Leaf $RepoPath
    foreach ($candidate in @(
        (Join-Path $SourceDir $RepoPath),
        (Join-Path $SourceDir $bare),
        (Join-Path $DownloadDir $bare)
    )) {
        if (Test-Path -PathType Leaf $candidate) { return $candidate }
    }
    return $null
}

foreach ($repoPath in $ProjectFiles) {
    $bare = Split-Path -Leaf $repoPath
    $localCopy = @((Join-Path $SourceDir $repoPath), (Join-Path $SourceDir $bare)) |
                 Where-Object { Test-Path -PathType Leaf $_ } | Select-Object -First 1
    if ($localCopy) {
        Write-Host "Using local '$repoPath' from $SourceDir -- not downloading."
        continue
    }
    $part = Join-Path $DownloadDir ($bare + ".part")
    try {
        Invoke-WebRequest -Uri "$RawBase/$repoPath" -OutFile $part -UseBasicParsing -ErrorAction Stop
        $item = Get-Item $part -ErrorAction SilentlyContinue
        if (-not $item -or $item.Length -eq 0) {
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            Write-Warn "Downloaded '$repoPath' was empty -- treating as a failed download. Fetch it manually from $RawBase/$repoPath into $DownloadDir"
        } elseif ((Get-Content $part -TotalCount 1 -ErrorAction SilentlyContinue) -match '^\s*<(!doctype|html)') {
            # Invoke-WebRequest throws on an HTTP error status, but not on
            # a proxy or captive portal that answers 200 with its own HTML
            # page. None of these files is HTML, so a first line that looks
            # like markup means something intercepted the request and the
            # "download" is garbage.
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            Write-Warn "'$repoPath' came back as an HTML page rather than the file itself -- something (a proxy, captive portal, or DNS interception) answered instead of GitHub. Check this machine's network, then re-run."
        } else {
            Move-Item -Path $part -Destination (Join-Path $DownloadDir $bare) -Force
            Write-Host "Downloaded $repoPath"
        }
    } catch {
        Remove-Item $part -Force -ErrorAction SilentlyContinue
        Write-Warn "Could not download '$repoPath' from $RawBase/$repoPath ($($_.Exception.Message)). Check network/DNS, or place the file beside the installer ($SourceDir) and re-run."
    }
}

# --- Step 10: folder structure ---
Write-Step "Creating folder structure under $DataRoot"
foreach ($folder in @(
    $ScriptsDir,
    $ConfigsDir,
    (Join-Path $DataRoot "Archive Logs/Archive History"),
    (Join-Path $DataRoot "Archive Logs/Logs"),
    (Join-Path $DataRoot "Youtube Videos/Complete Archive"),
    (Join-Path $DataRoot "Youtube Videos/_incomplete"),
    (Join-Path $DataRoot "Youtube Videos/Final Video")
)) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}
Write-Host "Folder structure created."

# --- Step 11: place the pipeline files and the archive viewer ---
Write-Step "Installing pipeline files"
function Install-ProjectFile {
    param([string]$RepoPath, [string]$Destination, [string]$Label)
    $source = Get-LocalSource -RepoPath $RepoPath
    if ($source) {
        Copy-Item -Path $source -Destination $Destination -Force
        Write-Host "Installed $Label -> $Destination (from $source)"
        return
    }
    Write-Warn "$RepoPath not found beside the installer or in $DownloadDir -- $Label was NOT installed. Copy it to $Destination manually."
}

# Snapshot the warning count right before these copies -- compared again
# below, after they have all run, to decide whether it is safe to delete
# the downloaded files. Re-using the warning count rather than tracking
# each call's return value separately keeps one source of truth for "did
# it work", since Install-ProjectFile already reports failures via
# Write-Warn.
$WarningsBeforeInstall = $Warnings.Count

Install-ProjectFile -RepoPath "scripts/run_ytdlp.ps1"     -Destination (Join-Path $ScriptsDir "run_ytdlp.ps1")     -Label "run_ytdlp.ps1"
Install-ProjectFile -RepoPath "scripts/postprocess.ps1"   -Destination (Join-Path $ScriptsDir "postprocess.ps1")   -Label "postprocess.ps1"
# ytdl.ps1 is now installed on EVERY platform, not just Windows: it holds
# the only copy of the `ytdl` argument parser, and the POSIX `ytdl` script
# on PATH is a shim that runs it. The viewer lives with the scripts rather
# than in $LocalBin because it is a program, not a command -- ytdl-view
# below is what you type.
Install-ProjectFile -RepoPath "scripts/ytdl.ps1"          -Destination (Join-Path $ScriptsDir "ytdl.ps1")          -Label "ytdl.ps1"
Install-ProjectFile -RepoPath "scripts/archive-viewer.py" -Destination (Join-Path $ScriptsDir "archive-viewer.py") -Label "archive-viewer.py"
Install-ProjectFile -RepoPath "config/yt-dlp.conf"        -Destination (Join-Path $ConfigsDir "yt-dlp.conf")       -Label "yt-dlp.conf"
Install-ProjectFile -RepoPath $LauncherSrc                -Destination $LauncherDst                                -Label "ytdl"

$ViewerPath = Join-Path $ScriptsDir "archive-viewer.py"

if ($IsWindows) {
    # Files that arrived via Invoke-WebRequest carry the Zone.Identifier
    # stream, and a .ps1 marked as internet-downloaded is refused outright
    # by the default RemoteSigned execution policy -- which would make
    # `ytdl` fail with a security error rather than anything that points at
    # the real cause.
    Get-ChildItem -Path $ScriptsDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    Unblock-File -Path $LauncherDst -ErrorAction SilentlyContinue
    Unblock-File -Path (Join-Path $ConfigsDir "yt-dlp.conf") -ErrorAction SilentlyContinue
} else {
    if (Test-Path $LauncherDst) { & chmod +x $LauncherDst }
    if (Test-Path $ViewerPath)  { & chmod +x $ViewerPath }
}

# --- ytdl-view launcher ---
# Written here rather than shipped as a repo file. Every other installed
# file is a copy of a repo source, and this one deliberately is not: its
# entire body is a single exec line, so a repo file would exist only to be
# copied and would be one more thing to keep in sync. A custom data root is
# handled at runtime instead:  ytdl-view --root /path/to/archive
if (Test-Path $ViewerPath) {
    if ($PythonCmd) {
        if ($IsWindows) {
            $viewLauncher = Join-Path $LocalBin "ytdl-view.cmd"
            # %* passes the raw remainder of the command line through, so
            # --root "D:\Some Path" survives with its quoting intact.
            $body = @"
@echo off
REM Generated by setup-common.ps1 -- thin launcher for archive-viewer.py.
REM All arguments pass straight through: --root, --port, --host,
REM --allow-open-local, --rescan, --help, and so on.
$PythonCmd "$ViewerPath" %*
"@
            Set-Content -Path $viewLauncher -Value $body -Encoding ASCII
        } else {
            $viewLauncher = Join-Path $LocalBin "ytdl-view"
            # The backtick escapes "$@" so it is WRITTEN literally and
            # expands when the launcher runs, not now. $ViewerPath and
            # $PythonCmd are interpolated on purpose, so an install at a
            # custom data root still points at the right script.
            $body = @"
#!/usr/bin/env bash
# Generated by setup-common.ps1 -- thin launcher for archive-viewer.py.
# All arguments pass straight through: --root, --port, --host,
# --allow-open-local, --rescan, --help, and so on.
exec $PythonCmd "$ViewerPath" "`$@"
"@
            Set-Content -Path $viewLauncher -Value $body -Encoding UTF8
            & chmod +x $viewLauncher
        }
        Write-Host "Installed ytdl-view -> $viewLauncher (launches the archive viewer)"
    } else {
        Write-Warn "No Python found, so the 'ytdl-view' launcher was skipped. Install Python and re-run the installer to get it."
    }
} else {
    Write-Warn "archive-viewer.py was not installed, so the 'ytdl-view' launcher was skipped."
}

# --- PATH wiring ---
if ($IsWindows) {
    # Writes to the USER environment (not Machine), so no elevation is
    # needed -- consistent with everything else here installing into
    # user-owned locations.
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($null -eq $userPath) { $userPath = "" }
    $pathEntries = $userPath -split ';' | Where-Object { $_ -ne "" }
    if ($pathEntries -notcontains $LocalBin) {
        $newPath = if ($userPath -eq "") { $LocalBin } else { "$userPath;$LocalBin" }
        [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        # Also update THIS process so the Step 12 verification below can
        # find ytdl without the user having to open a new window first.
        $env:Path = "$env:Path;$LocalBin"
        Write-Host "Added $LocalBin to your user PATH -- open a new terminal window before using 'ytdl' from elsewhere."
    }
} else {
    # Which startup file to append to depends on the LOGIN SHELL, not on
    # the OS as such -- macOS defaults to zsh and most Linux distributions
    # to bash, but checking $SHELL gets the right answer on a machine where
    # the user changed it.
    $onPath = ($env:PATH -split [System.IO.Path]::PathSeparator) -contains $LocalBin
    if (-not $onPath) {
        $shellRc = if ($env:SHELL -match 'zsh') {
            Join-Path $HOME ".zshrc"
        } elseif ($env:SHELL -match 'bash') {
            Join-Path $HOME ".bashrc"
        } elseif ($IsMacOS) {
            Join-Path $HOME ".zshrc"
        } else {
            Join-Path $HOME ".bashrc"
        }
        Add-Content -Path $shellRc -Value "export PATH=`"$LocalBin`:`$PATH`""
        $env:PATH = "$LocalBin" + [System.IO.Path]::PathSeparator + $env:PATH
        Write-Host "Added $LocalBin to PATH in $shellRc -- run 'source $shellRc' or start a new shell before using 'ytdl'."
    }
}

# --- Clean up the downloaded installation files now that they are copied ---
# $DownloadDir is scratch: it exists only to source the files above. Once
# those are safely in their real destinations there is no reason to leave a
# second copy on disk.
#
# Only deleted if every Install-ProjectFile call above actually succeeded.
# If anything failed, the download is deliberately left in place -- it may
# be the only remaining copy of a file that never reached its destination,
# so deleting it here would destroy the one thing needed to fix the problem
# by hand. This never touches anything placed beside the installer by hand:
# $DownloadDir is a subfolder Step 9 creates, and Step 9 skips downloading
# anything already present there.
if (Test-Path $DownloadDir) {
    if ($Warnings.Count -eq $WarningsBeforeInstall) {
        Remove-Item -Path $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed downloaded installation files at '$DownloadDir' (already copied into place, no longer needed)."
    } else {
        Write-Host "Leaving '$DownloadDir' in place -- at least one file above failed to install from it (see the WARNING(s) further up). Once that is resolved and you have confirmed everything under $ScriptsDir and $ConfigsDir is correct, it is safe to delete manually."
    }
}

# --- Step 12: verify ---
# yt-dlp and deno are installed into $LocalBin rather than by a package
# manager, so both are checked via their full paths rather than as bare
# commands. A bare lookup produces a false NOT FOUND on a fresh install:
# $LocalBin was only just added to PATH a few lines up, and on POSIX that
# does not take effect for the current process's children until a new
# shell. ffmpeg/pwsh/git are unaffected, being on PATH already.
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
function Test-Command {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source } else { return "NOT FOUND (open a new shell if PATH was just updated)" }
}

Write-Host "platform: $PlatformLabel"
Write-Host "yt-dlp:  $(if (Test-Path $YtDlpBin) { Get-VersionOrMissing { & $YtDlpBin --version } } else { 'NOT FOUND' })"
Write-Host "ffmpeg:  $(Get-VersionOrMissing { & ffmpeg -version })"
Write-Host "ffprobe: $(Get-VersionOrMissing { & ffprobe -version } 'NOT FOUND (postprocess.ps1 needs this for the info.json re-embed)')"
Write-Host "pwsh:    $(Get-VersionOrMissing { & pwsh --version })"
Write-Host "deno:    $(if (Test-Path $DenoBin) { Get-VersionOrMissing { & $DenoBin --version } } else { 'NOT FOUND' })"
Write-Host "git:     $(Get-VersionOrMissing { & git --version })"
Write-Host "python:  $(if ($PythonCmd) { Get-VersionOrMissing { & $PythonCmd --version } } else { 'NOT FOUND (only the archive viewer needs it)' })"
Write-Host "ytdl:    $(if (Test-Path $LauncherDst) { $LauncherDst } else { 'NOT FOUND' })"
Write-Host "ytdl-view: $(if ($IsWindows) { $(if (Test-Path (Join-Path $LocalBin 'ytdl-view.cmd')) { Join-Path $LocalBin 'ytdl-view.cmd' } else { 'NOT FOUND' }) } else { $(if (Test-Path (Join-Path $LocalBin 'ytdl-view')) { Join-Path $LocalBin 'ytdl-view' } else { 'NOT FOUND' }) })"

# Compiles the viewer without running it -- catches a truncated or
# corrupted download that Install-ProjectFile itself has no way to notice.
# PYTHONPYCACHEPREFIX keeps the resulting .pyc out of scripts/, which
# otherwise holds exactly four known files.
if ((Test-Path $ViewerPath) -and $PythonCmd) {
    $env:PYTHONPYCACHEPREFIX = [System.IO.Path]::GetTempPath()
    & $PythonCmd -m py_compile $ViewerPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "viewer:  archive-viewer.py installed and parses cleanly"
    } else {
        Write-Warn "archive-viewer.py is installed but does not compile -- the download may be truncated. Delete $ViewerPath and re-run the installer."
    }
}

# Syntax-check the pipeline scripts without executing them. Worth having
# now that one file serves three platforms -- a syntax error introduced
# while editing would otherwise only surface at the end of a real download,
# after the video is already on disk and the after_move hook fires.
foreach ($psScript in @("run_ytdlp.ps1", "postprocess.ps1", "ytdl.ps1")) {
    $scriptPath = Join-Path $ScriptsDir $psScript
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

# Desktop preview reporting. Only meaningful if Step 6 actually ran --
# reported as "skipped (no desktop)" rather than "NOT FOUND" on a headless
# install, so a deliberate skip does not read as a failure in the summary.
if ($IsMacOS) {
    Write-Host "iina:    $(if (Test-Path '/Applications/IINA.app') { 'installed' } else { 'NOT FOUND' })"
    Write-Host "vlc:     $(if (Test-Path '/Applications/VLC.app') { 'installed' } else { 'NOT FOUND' })"
    Write-Host "previews: handled natively by Finder/Quick Look on macOS"
} elseif ($IsWindows) {
    Write-Host "vlc:     $(if ((Get-Command vlc -ErrorAction SilentlyContinue) -or (Test-Path "${env:ProgramFiles}\VideoLAN\VLC\vlc.exe")) { 'installed' } else { 'NOT FOUND' })"
    Write-Host "previews: .webp thumbnails are handled natively by Explorer on Windows 10 1809+ and Windows 11"
    # Windows-specific and worth surfacing explicitly rather than leaving
    # to be discovered as a mysterious mid-download failure on a video with
    # a long title -- see yt-dlp.conf's folder-structure notes for the
    # arithmetic.
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
} elseif ($HasDesktop) {
    Write-Host "mpv:     $(Get-VersionOrMissing { & mpv --version })"
    Write-Host "vlc:     $(Get-VersionOrMissing { & vlc --version })"
    # Checked by looking for the files these packages install rather than
    # by querying a package database. `dpkg -s` only answers on
    # Debian-family systems, and adding rpm/pacman/zypper equivalents would
    # mean three more branches to test what is ultimately one question: is
    # the loader present on disk. Both land in the same locations on every
    # distribution, so a glob is shorter AND more portable. The glob covers
    # the architecture triplet in the pixbuf directory name, which differs
    # per distro and per arch.
    $webpLoader = Get-ChildItem -Path "/usr/lib/gdk-pixbuf-2.0","/usr/lib64/gdk-pixbuf-2.0","/usr/lib/*/gdk-pixbuf-2.0" `
                                -Filter "libpixbufloader-webp.so" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host "webp:    $(if ($webpLoader) { 'webp-pixbuf-loader installed (.webp thumbnails will render)' } else { 'NOT FOUND' })"
    Write-Host "vidthumb: $(if (Test-Path '/usr/share/thumbnailers/ffmpegthumbnailer.thumbnailer') { 'ffmpegthumbnailer installed (.mkv poster frames will render)' } else { 'NOT FOUND' })"
} else {
    Write-Host "previews: skipped (no desktop environment detected)"
}

# NOTE: this final summary deliberately does NOT call Write-Step -- that is
# what advances the step counter, and all 12 real steps are done by this
# point. Calling it again would push the bar past 100%.
Write-Host ""
Draw-ProgressBar
if ($Warnings.Count -gt 0) {
    Write-Host ">>> Setup finished with $($Warnings.Count) item(s) needing attention:"
    foreach ($w in $Warnings) { Write-Host "  - $w" }
} else {
    Write-Host ">>> Setup complete, no issues detected."
}
Write-Host ""
Write-Host "Test with: ytdl `"https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID`""
Write-Host "Then browse what you archived -- video, subtitles, transcript, metadata"
Write-Host "and the full comment thread -- with: ytdl-view"
Write-Host "  (add --root /path/to/archive if you downloaded to a custom data root,"
Write-Host "   and --allow-open-local to let the page hand files to a local player)"
