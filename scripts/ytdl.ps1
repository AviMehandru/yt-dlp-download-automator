<#
.SYNOPSIS
    The launcher for the yt-dlp archival pipeline. One file, all platforms.

.DESCRIPTION
    This is the ONLY place the `ytdl` command line is parsed. It used to be
    the Windows half of a matched pair, with an equivalent bash parser in
    the POSIX `ytdl` script; both accepted the same seven options and both
    had to be edited, in two languages, to add or change any one of them.
    That pair is gone. `ytdl` (bash) and `ytdl.cmd` are now both thin
    shims that locate this file, hand it the command line untouched, and
    propagate its exit code -- so a command that works on one platform
    works verbatim on all three because there is literally one parser, not
    because two parsers were kept in agreement by hand.

    Everything platform-specific that remains is the install-root default
    below, and it is three lines.

.PARAMETER Url
    The YouTube URL, given as the first argument. Works identically whether
    it is a single video, a playlist, or a whole channel -- yt-dlp's own
    extractor tells them apart, not this script, so nothing here (or in
    run_ytdlp.ps1) branches on URL type.

.NOTES
    Options (any order, after the URL and optional path):

      --sync            Stop as soon as an already-archived video is hit.
                        For periodic re-runs against a channel or playlist
                        you have mostly already archived.
      --items RANGE     yt-dlp's own --playlist-items syntax, e.g.
                        --items 1-20  or  --items 5,8,10-15
      --after YYYYMMDD  yt-dlp's own --dateafter, e.g. --after 20250101
      --lazy            Start downloading as videos are discovered instead
                        of enumerating the whole listing first. Mainly
                        useful on very large channels. No effect combined
                        with --workers > 1.
      --workers N       Download N videos AT THE SAME TIME instead of one
                        after another. Default 1 (unchanged behavior). See
                        run_ytdlp.ps1's own comments on -Workers for what
                        this actually does and why it is NOT the same as
                        running ytdl several times yourself in different
                        terminals -- short version: it enumerates every
                        video up front so no two workers can be assigned
                        the same one, and postprocess.ps1 has matching
                        file-locking so concurrent workers cannot corrupt
                        shared manifests. Start low (2-4) and watch
                        download.log for rate-limit warnings.
      --path PATH       Same as the legacy positional path below, as an
                        explicit flag -- use this if you also need one of
                        the options above in the same command.

    The options only ever matter once a session covers more than one
    video; they are harmless no-ops against a single video URL.

    The second positional argument (a bare path, not starting with "--")
    is still accepted for backward compatibility: `ytdl <url> /some/path`.
    If given, it REPLACES the default data root (Archive Logs/, Youtube
    Videos/) for this run only -- the pipeline install itself (scripts/,
    configs/) always stays at the install root regardless, since the shims
    need a fixed, known location to find this file in the first place. A
    relative path is resolved to an absolute one by run_ytdlp.ps1.

.EXAMPLE
    ytdl https://www.youtube.com/watch?v=dQw4w9WgXcQ

.EXAMPLE
    ytdl https://www.youtube.com/@SomeChannel/videos --sync --workers 3

.EXAMPLE
    ytdl https://www.youtube.com/@SomeChannel/videos --path "D:\Archive" --items 1-20
#>

# Deliberately NOT declared with a param() block of named parameters.
# The whole point of this launcher is to accept double-dashed option
# spellings (--sync, --items, --workers), and PowerShell's own parameter
# binder would try to interpret those as its own parameters, or reject
# them outright. Taking the raw argument list and parsing it by hand is
# what lets the shims pass a command line straight through.
$ErrorActionPreference = "Stop"

# Usage and validation messages go to stderr through [Console]::Error
# rather than Write-Error. Write-Error emits a PowerShell ERROR RECORD,
# which the host renders as a multi-line block with the script name, line
# number, a caret diagram and the offending source line -- appropriate for
# an unexpected fault, absurd for "you forgot the URL". The bash launcher
# this replaces printed one clean line to stderr, and dropping to that
# noise level would have been a visible regression on every platform for
# the most common mistake a user can make. Exit codes are unchanged.
function Write-Usage {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

# Install root. Must agree with the platform block at the top of
# run_ytdlp.ps1, which reads the same environment variable and falls back
# to the same defaults, and with the two shims, which need it to find this
# file. $IsWindows and friends are pwsh 7 automatic variables and are safe
# here: this script only ever runs under pwsh 7, because that is the only
# thing either shim will start it with.
#
# Windows keeps C:\yt-dlp rather than living under the user profile
# because of MAX_PATH -- the per-video paths this pipeline builds are long
# enough that ten characters of prefix genuinely matter. See run_ytdlp.ps1.
if (-not [string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $installRoot = $env:YTDLP_INSTALL_ROOT
} elseif ($IsWindows) {
    $installRoot = "C:/yt-dlp"
} else {
    $installRoot = Join-Path $HOME "yt-dlp"
}

$usage = "Usage: ytdl <youtube-url> [download-root-path] [--sync] [--items RANGE] [--after YYYYMMDD] [--lazy] [--workers N] [--path PATH]"

$argList = @($args)
if ($argList.Count -eq 0 -or [string]::IsNullOrWhiteSpace($argList[0])) {
    Write-Usage $usage
    exit 1
}

$url = $argList[0]
# The OUTER @() here is load-bearing, not decorative. PowerShell unrolls
# the result of an if-expression through the pipeline, so a branch that
# returns a ONE-element array yields that element as a bare scalar rather
# than an array -- which makes $rest a [string], $rest[0] its first
# CHARACTER, and $rest[0].StartsWith(...) a runtime error, since
# [System.Char] has no such method. That is exactly the single-extra-
# argument case: `ytdl <url> D:\Archive`, the legacy positional path form
# this block exists to support. (An empty branch unrolls to $null for the
# same reason.) Wrapping the whole if-expression in @() forces an array in
# every branch. Caught by an actual test run, not by reading the code.
$rest = @(if ($argList.Count -gt 1) { $argList[1..($argList.Count - 1)] } else { @() })

$customPath      = ""
$breakOnExisting = $false
$playlistItems   = ""
$dateAfter       = ""
$lazyPlaylist    = $false
$workers         = ""

# Backward compatibility with the old positional form: if the first
# remaining argument does not start with "--", treat it as the legacy
# positional custom download-root path rather than requiring everyone to
# switch to --path immediately.
$i = 0
if ($rest.Count -gt 0 -and -not $rest[0].StartsWith("--")) {
    $customPath = $rest[0]
    $i = 1
}

while ($i -lt $rest.Count) {
    switch ($rest[$i]) {
        "--sync" {
            $breakOnExisting = $true
            $i++
        }
        "--items" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --items requires a value (e.g. --items 1-20)"; exit 1 }
            $playlistItems = $rest[$i + 1]
            $i += 2
        }
        "--after" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --after requires a value (e.g. --after 20250101)"; exit 1 }
            $dateAfter = $rest[$i + 1]
            $i += 2
        }
        "--lazy" {
            $lazyPlaylist = $true
            $i++
        }
        "--workers" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --workers requires a positive integer"; exit 1 }
            $workers = $rest[$i + 1]
            # Validated here rather than left to run_ytdlp.ps1's own
            # [ValidateRange(1,64)], so a typo produces a clear, immediate
            # message instead of a PowerShell parameter-binding error
            # several layers down.
            if ($workers -notmatch '^\d+$' -or [int]$workers -lt 1) {
                Write-Usage "Error: --workers requires a positive integer (got: '$workers')"
                exit 1
            }
            $i += 2
        }
        "--path" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --path requires a value"; exit 1 }
            $customPath = $rest[$i + 1]
            $i += 2
        }
        default {
            Write-Usage "Unknown option: $($rest[$i])`n$usage"
            exit 1
        }
    }
}

# Assembled as an argument ARRAY rather than a command string, so a path or
# URL containing spaces never needs quoting logic here at all -- pwsh
# passes each element through as a single argument regardless of content.
$pwshArgs = @("-NoProfile", "-File", (Join-Path $installRoot "scripts/run_ytdlp.ps1"), "-Url", $url)
if ($customPath)     { $pwshArgs += @("-DataRoot", $customPath) }
if ($breakOnExisting){ $pwshArgs += "-BreakOnExisting" }
if ($playlistItems)  { $pwshArgs += @("-PlaylistItems", $playlistItems) }
if ($dateAfter)      { $pwshArgs += @("-DateAfter", $dateAfter) }
if ($lazyPlaylist)   { $pwshArgs += "-LazyPlaylist" }
if ($workers)        { $pwshArgs += @("-Workers", $workers) }

# Started as a CHILD pwsh process rather than dot-sourced or invoked with
# & in this one, even though this script is already running under pwsh and
# a child process is strictly more expensive. Two reasons, both about not
# changing behavior that already works: run_ytdlp.ps1's own `exit N` calls
# terminate the process they run in, so invoking it in-process would make
# this launcher's exit path depend on subtleties of how `exit` behaves
# inside `&`; and a separate process keeps run_ytdlp.ps1's $PSScriptRoot,
# preference variables and error state entirely its own. The cost is one
# process launch against a job that then spends minutes downloading video.
& pwsh @pwshArgs
exit $LASTEXITCODE
