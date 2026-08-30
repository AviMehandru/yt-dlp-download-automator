<#
.SYNOPSIS
    Windows launcher for the yt-dlp archival pipeline.

.DESCRIPTION
    The Windows counterpart to the POSIX `ytdl` bash script used on Linux
    and macOS. It accepts the exact same double-dashed options, in the same
    order-independent way, and builds the exact same run_ytdlp.ps1
    invocation -- so a command that works on one platform works verbatim on
    all three.

    This is a PowerShell script rather than a .bat file on purpose. The
    older Windows launcher was a batch file that accepted only a URL, and
    extending cmd.exe's argument handling to cover six optional flags
    (two of which take values) is genuinely painful -- cmd treats "=" as an
    argument delimiter, has no arrays, and needs delayed expansion for any
    loop that assigns variables. Since pwsh is already a hard requirement
    for the pipeline itself, the launcher may as well be written in it.
    ytdl.cmd sits next to this file as a one-line shim so that plain
    `ytdl <url>` still works from cmd.exe and from the Run box.

.PARAMETER Url
    The YouTube URL. Works identically whether it's a single video, a
    playlist, or a whole channel -- yt-dlp's own extractor tells them apart,
    not this script.

.EXAMPLE
    ytdl https://www.youtube.com/watch?v=dQw4w9WgXcQ

.EXAMPLE
    ytdl https://www.youtube.com/@SomeChannel/videos --sync --workers 3

.EXAMPLE
    ytdl https://www.youtube.com/@SomeChannel/videos --path "D:\Archive" --items 1-20
#>

# Deliberately NOT declared with a param() block of named parameters.
# The whole point of this launcher is to accept the SAME double-dashed
# option spellings the bash launcher uses (--sync, --items, --workers),
# and PowerShell's own parameter binder would try to interpret those as
# its own parameters (or reject them outright). Taking the raw argument
# list and parsing it by hand is what keeps the two launchers' command
# lines identical.
$ErrorActionPreference = "Stop"

# Install root. Must agree with the platform block at the top of
# run_ytdlp.ps1, which reads the same environment variable and falls back
# to the same default. See that block for why Windows keeps C:\yt-dlp
# rather than living under the user profile (short version: MAX_PATH).
$installRoot = if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    "C:/yt-dlp"
} else {
    $env:YTDLP_INSTALL_ROOT
}

$usage = "Usage: ytdl <youtube-url> [download-root-path] [--sync] [--items RANGE] [--after YYYYMMDD] [--lazy] [--workers N] [--path PATH]"

$argList = @($args)
if ($argList.Count -eq 0 -or [string]::IsNullOrWhiteSpace($argList[0])) {
    Write-Error $usage
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
# remaining argument doesn't start with "--", treat it as the legacy
# positional custom download-root path rather than requiring everyone to
# switch to --path immediately. Same rule as the bash launcher.
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
            if ($i + 1 -ge $rest.Count) { Write-Error "Error: --items requires a value (e.g. --items 1-20)"; exit 1 }
            $playlistItems = $rest[$i + 1]
            $i += 2
        }
        "--after" {
            if ($i + 1 -ge $rest.Count) { Write-Error "Error: --after requires a value (e.g. --after 20250101)"; exit 1 }
            $dateAfter = $rest[$i + 1]
            $i += 2
        }
        "--lazy" {
            $lazyPlaylist = $true
            $i++
        }
        "--workers" {
            if ($i + 1 -ge $rest.Count) { Write-Error "Error: --workers requires a positive integer"; exit 1 }
            $workers = $rest[$i + 1]
            # Validated here rather than left to run_ytdlp.ps1's own
            # [ValidateRange(1,64)], so a typo produces the same clear,
            # immediate message the bash launcher gives instead of a
            # PowerShell parameter-binding error several layers down.
            if ($workers -notmatch '^\d+$' -or [int]$workers -lt 1) {
                Write-Error "Error: --workers requires a positive integer (got: '$workers')"
                exit 1
            }
            $i += 2
        }
        "--path" {
            if ($i + 1 -ge $rest.Count) { Write-Error "Error: --path requires a value"; exit 1 }
            $customPath = $rest[$i + 1]
            $i += 2
        }
        default {
            Write-Error "Unknown option: $($rest[$i])`n$usage"
            exit 1
        }
    }
}

# Splatted as a hashtable rather than assembled as a string, so a path or
# URL containing spaces never needs quoting logic here at all -- pwsh
# passes each value through as a single argument regardless of content.
$pwshArgs = @("-NoProfile", "-File", (Join-Path $installRoot "scripts/run_ytdlp.ps1"), "-Url", $url)
if ($customPath)     { $pwshArgs += @("-DataRoot", $customPath) }
if ($breakOnExisting){ $pwshArgs += "-BreakOnExisting" }
if ($playlistItems)  { $pwshArgs += @("-PlaylistItems", $playlistItems) }
if ($dateAfter)      { $pwshArgs += @("-DateAfter", $dateAfter) }
if ($lazyPlaylist)   { $pwshArgs += "-LazyPlaylist" }
if ($workers)        { $pwshArgs += @("-Workers", $workers) }

& pwsh @pwshArgs
exit $LASTEXITCODE
