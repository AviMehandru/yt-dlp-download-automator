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

    QUOTE IT. Every shell rewrites an unquoted URL before ytdl is started:
    zsh (macOS's default) fails outright on the "?" in watch?v=...; bash
    silently truncates at "&list=..." because "&" backgrounds the command;
    PowerShell rejects "&" as a syntax error. No amount of care inside this
    script can recover a command line the shell already changed, so the
    quotes are the fix, on every platform:

        ytdl "https://www.youtube.com/watch?v=-QMgcOSyf-o&list=PLabc"

    A leading hyphen in the URL or video id, on the other hand, IS handled
    here: YouTube ids are base64url and about one in thirty starts with "-"
    or "_", the first argument is taken as the URL even when it starts with
    a hyphen, and every yt-dlp invocation in the pipeline passes "--" ahead
    of the URL so yt-dlp cannot mistake it for an option either.

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
    ytdl "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

.EXAMPLE
    ytdl "https://www.youtube.com/@SomeChannel/videos" --sync --workers 3

.EXAMPLE
    ytdl "https://www.youtube.com/@SomeChannel/videos" --path "D:\Archive" --items 1-20

.EXAMPLE
    # A video id starting with a hyphen -- an ordinary base64url id, not a
    # special case you have to work around.
    ytdl "https://youtu.be/-QMgcOSyf-o"
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

$usage = "Usage: ytdl <youtube-url> [download-root-path] [--sync] [--items RANGE] [--after YYYYMMDD] [--lazy] [--workers N] [--path PATH] [--no-pot] [--skip-pot-update] [--pot-port N]"

$argList = @($args)
if ($argList.Count -eq 0 -or [string]::IsNullOrWhiteSpace($argList[0])) {
    Write-Usage $usage
    exit 1
}

# Every option spelling the switch below accepts. The switch still needs
# its own per-option cases (each one does something different), so this is
# a mirror of that list rather than its source -- but it is a mirror with
# a test behind it: 020-launcher asserts the two agree, so adding an
# option to the switch without adding it here fails the suite rather than
# quietly leaving the guard below out of date.
$knownOptions = @("--sync", "--items", "--after", "--lazy", "--workers", "--path", "--no-pot", "--skip-pot-update", "--pot-port")

# The first argument is the URL, INCLUDING when it starts with a hyphen.
#
# YouTube video ids are base64url, so roughly one in thirty starts with
# "-" or "_": "-QMgcOSyf-o" is an ordinary id, not a malformed one. A
# full URL built from such an id is harmless here (it starts with "h"),
# but a bare id typed on its own -- `ytdl -QMgcOSyf-o` -- is not, and
# neither is anything downstream that hands the value to yt-dlp as a bare
# positional argument. That downstream half is fixed by the `--`
# end-of-options marker now present at every yt-dlp call site (see the
# long note in run_ytdlp.ps1); this half is the rule that a leading hyphen
# does NOT by itself mean "option".
#
# Which leaves one case that must not be swallowed silently: an actual
# option in the URL's position, i.e. the user wrote the options first and
# forgot the URL. Before, `ytdl --sync https://...` took "--sync" as the
# URL and the real URL as the legacy positional download path, then
# started a doomed download into a directory named after a YouTube link --
# a wrong run rather than an error message. It is now a clean failure.
if ($knownOptions -contains $argList[0]) {
    Write-Usage "Error: the first argument must be the URL -- '$($argList[0])' is an option.`n$usage"
    exit 1
}

$url = $argList[0]

# A URL is only "funky" from a shell's point of view, and by the time this
# script runs the shell has already had its way with the command line.
# Three mangles this script CANNOT undo, because they happen before pwsh
# is even started:
#
#   zsh (the default shell on macOS) treats "?" as a glob character, so an
#   unquoted https://www.youtube.com/watch?v=... fails outright with
#   "zsh: no matches found" and ytdl never runs at all.
#
#   bash passes "?" through, but "&" -- as in "&list=PL..." or "&t=42" --
#   is a control operator: it backgrounds the command and silently
#   truncates the URL at that point, so the archive quietly gets the video
#   without the playlist.
#
#   PowerShell rejects an unquoted "&" as a syntax error.
#
# The cure for all three is the same and belongs to the user: quote the
# URL. What this script can do is notice when the argument it was handed
# does not look like a URL at all -- the usual sign that a glob expanded
# to filenames, or that a paste arrived in pieces -- and name quoting as
# the fix, instead of letting yt-dlp fail several layers down with an
# extractor error that reads like a YouTube problem.
#
# Deliberately a WARNING, not a rejection, and deliberately narrow: it
# stays quiet for anything containing "://" or a YouTube host or shaped
# like a bare 11-character video id, which covers every form that reaches
# yt-dlp intact today. Being wrong in the noisy direction costs a line of
# stderr; being wrong in the rejecting direction would break a command
# that used to work.
if ($url -notmatch '://' -and
    $url -notmatch '(?i)youtube\.com|youtu\.be' -and
    $url -notmatch '^[\w-]{11}$') {
    Write-Usage "Warning: '$url' does not look like a YouTube URL. If you pasted one, quote it -- an unquoted URL containing ? or & is rewritten by the shell before ytdl sees it. Continuing anyway."
}

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
$noPot           = $false
$skipPotUpdate   = $false
$potPort         = ""

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
        "--no-pot" {
            $noPot = $true
            $i++
        }
        "--skip-pot-update" {
            $skipPotUpdate = $true
            $i++
        }
        "--pot-port" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --pot-port requires a port number"; exit 1 }
            $potPort = $rest[$i + 1]
            # Same reasoning as --workers above: validated here so a typo
            # produces a clear message rather than a parameter-binding
            # error from run_ytdlp.ps1's [ValidateRange(1024,65535)].
            if ($potPort -notmatch '^\d+$' -or [int]$potPort -lt 1024 -or [int]$potPort -gt 65535) {
                Write-Usage "Error: --pot-port requires a port between 1024 and 65535 (got: '$potPort')"
                exit 1
            }
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
if ($noPot)          { $pwshArgs += "-NoPot" }
if ($skipPotUpdate)  { $pwshArgs += "-SkipPotUpdate" }
if ($potPort)        { $pwshArgs += @("-PotPort", $potPort) }

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