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

    The options above only ever matter once a session covers more than one
    video; they are harmless no-ops against a single video URL.

    WHAT gets downloaded (all of these DO matter on a single video):

      --mode MODE       One of: full (default), video-only, audio-only,
                        metadata-only, comments-only, subs-only.
                        full        video+audio merged, everything else.
                        video-only  no audio stream at all.
                        audio-only  no video stream; the media file is
                                    named "Final Audio.<ext>" instead of
                                    "Final Video.<ext>" (archive layout 2).
                        metadata-only / comments-only / subs-only
                                    download no media at all. The per-video
                                    folder is still created in full, with a
                                    manifest and checksums -- just with no
                                    media file in it, so the media can be
                                    filled in by a later run.
      --quality N       Cap the video height, e.g. --quality 1080. Also
                        accepts "best" (the default, no cap).
      --codec NAME      Preferred video codec: any (default), avc1, vp9,
                        av01. A PREFERENCE, not a filter -- if the codec
                        isn't offered, the best available is still taken.
                        avc1 is the compatibility choice (plays anywhere);
                        av01 is the smallest for the same quality.
      --audio-codec N   Preferred audio codec for --mode audio-only: any
                        (default, keeps the original stream untouched),
                        opus, aac, mp3, flac. Anything but "any" re-encodes
                        via yt-dlp's audio extraction.
      --container EXT   Merge container for video: mkv (default), mp4,
                        webm. mkv is the archival choice; mp4 is the
                        compatible one. Ignored when no merge happens.

    Leaving a COMPONENT out (each is independent of --mode):

      --no-comments     Skip the (slow) comments pass entirely.
      --no-subs         Download no subtitles.
      --no-thumbnail    Download and embed no thumbnail.
      --no-metadata     Write no description/info.json sidecars. The
                        manifest then falls back to folder-name-derived
                        metadata, which the pipeline already handles.
      --no-audio        Alias for --mode video-only.
      --no-video        Alias for --mode audio-only.

    The escape hatch:

      --ytdlp-arg ARG   Pass ARG straight to yt-dlp, after the config file
                        so it wins. Repeatable:
                            --ytdlp-arg --sponsorblock-mark --ytdlp-arg all
                        Options that would break the archive layout (-o,
                        --paths, --exec, --config-location, --ignore-config,
                        --download-archive) are refused here rather than
                        silently producing an archive nothing can read --
                        see run_ytdlp.ps1's $BlockedPassthroughArgs.

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

$usage = @"
Usage: ytdl <youtube-url> [download-root-path] [options]

  Session:   [--sync] [--items RANGE] [--after YYYYMMDD] [--lazy]
             [--workers N] [--path PATH]
  PO token:  [--no-pot] [--skip-pot-update] [--pot-port N]
  Content:   [--mode full|video-only|audio-only|metadata-only|comments-only|subs-only]
             [--quality N|best] [--codec any|avc1|vp9|av01]
             [--audio-codec any|opus|aac|mp3|flac] [--container mkv|mp4|webm]
  Skips:     [--no-comments] [--no-subs] [--no-thumbnail] [--no-metadata]
             [--no-audio] [--no-video]
  Escape:    [--ytdlp-arg ARG]   (repeatable)
"@

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
$knownOptions = @("--sync", "--items", "--after", "--lazy", "--workers", "--path", "--no-pot", "--skip-pot-update", "--pot-port",
                  "--mode", "--quality", "--codec", "--audio-codec", "--container",
                  "--no-comments", "--no-subs", "--no-thumbnail", "--no-metadata", "--no-audio", "--no-video",
                  "--ytdlp-arg")

# The accepted values for the four enumerated content options. Validated
# HERE, at the point the user typed them, rather than left to
# run_ytdlp.ps1's [ValidateSet] several layers down -- same reasoning as
# --workers and --pot-port below: "invalid value 'audio only' for --mode"
# beats a PowerShell parameter-binding error record naming a script the
# user did not invoke. 030-config asserts these agree with the
# [ValidateSet]s in run_ytdlp.ps1, so the two lists cannot drift.
$validModes        = @("full", "video-only", "audio-only", "metadata-only", "comments-only", "subs-only")
$validCodecs       = @("any", "avc1", "vp9", "av01")
$validAudioCodecs  = @("any", "opus", "aac", "mp3", "flac")
$validContainers   = @("mkv", "mp4", "webm")

# The modes that download no media at all. Kept as a named list rather
# than an inline three-way -or because run_ytdlp.ps1 and postprocess.ps1
# both need the same predicate, and a fourth such mode should only have to
# be added in one place per script.
$noMediaModes = @("metadata-only", "comments-only", "subs-only")

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

$mode            = ""
$quality         = ""
$codec           = ""
$audioCodec      = ""
$container       = ""
$noComments      = $false
$noSubs          = $false
$noThumbnail     = $false
$noMetadata      = $false
# --no-audio/--no-video are recorded separately from $mode rather than
# writing straight into it, so "--no-audio --mode audio-only" is caught as
# the contradiction it is instead of being resolved by whichever happened
# to be typed last.
$noAudio         = $false
$noVideo         = $false
$ytdlpArgs       = @()

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
        # --- What gets downloaded ---
        # Each of the four enumerated options below follows the same shape:
        # require a value, check it against the list declared near
        # $knownOptions, and name the valid values in the error rather than
        # just rejecting. A typo in "--codec av1" (the real codec name in
        # yt-dlp's format fields is "av01", with a zero) is the single most
        # likely mistake here, and an error listing the four accepted
        # spellings fixes it immediately.
        "--mode" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --mode requires a value ($($validModes -join ', '))"; exit 1 }
            $mode = $rest[$i + 1]
            if ($validModes -notcontains $mode) {
                Write-Usage "Error: --mode must be one of: $($validModes -join ', ') (got: '$mode')"
                exit 1
            }
            $i += 2
        }
        "--quality" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --quality requires a height in pixels, or 'best' (e.g. --quality 1080)"; exit 1 }
            $quality = $rest[$i + 1]
            # "best" is spelled out rather than left as "omit the flag" so a
            # GUI or a saved preset always has a value to send for this
            # field, including when the user has chosen no cap.
            if ($quality -ne "best" -and ($quality -notmatch '^\d+$' -or [int]$quality -lt 1)) {
                Write-Usage "Error: --quality requires a positive height in pixels, or 'best' (got: '$quality')"
                exit 1
            }
            $i += 2
        }
        "--codec" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --codec requires a value ($($validCodecs -join ', '))"; exit 1 }
            $codec = $rest[$i + 1]
            if ($validCodecs -notcontains $codec) {
                Write-Usage "Error: --codec must be one of: $($validCodecs -join ', ') (got: '$codec'). Note av01 is spelled with a zero."
                exit 1
            }
            $i += 2
        }
        "--audio-codec" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --audio-codec requires a value ($($validAudioCodecs -join ', '))"; exit 1 }
            $audioCodec = $rest[$i + 1]
            if ($validAudioCodecs -notcontains $audioCodec) {
                Write-Usage "Error: --audio-codec must be one of: $($validAudioCodecs -join ', ') (got: '$audioCodec')"
                exit 1
            }
            $i += 2
        }
        "--container" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --container requires a value ($($validContainers -join ', '))"; exit 1 }
            $container = $rest[$i + 1]
            if ($validContainers -notcontains $container) {
                Write-Usage "Error: --container must be one of: $($validContainers -join ', ') (got: '$container')"
                exit 1
            }
            $i += 2
        }

        # --- Component skips ---
        "--no-comments"  { $noComments  = $true; $i++ }
        "--no-subs"      { $noSubs      = $true; $i++ }
        "--no-thumbnail" { $noThumbnail = $true; $i++ }
        "--no-metadata"  { $noMetadata  = $true; $i++ }
        "--no-audio"     { $noAudio     = $true; $i++ }
        "--no-video"     { $noVideo     = $true; $i++ }

        # --- Passthrough ---
        # Accumulated in order and handed to run_ytdlp.ps1 as a single
        # array parameter. NOT validated for meaning here: the whole point
        # is that yt-dlp options this pipeline has never heard of still
        # work. What IS checked -- in run_ytdlp.ps1, where the list of
        # layout-critical options already lives next to the code that
        # passes them -- is that the argument is not one of the handful
        # that would redirect the output somewhere no reader can find it.
        "--ytdlp-arg" {
            if ($i + 1 -ge $rest.Count) { Write-Usage "Error: --ytdlp-arg requires a value (e.g. --ytdlp-arg --sponsorblock-mark --ytdlp-arg all)"; exit 1 }
            $ytdlpArgs += $rest[$i + 1]
            $i += 2
        }

        default {
            Write-Usage "Unknown option: $($rest[$i])`n$usage"
            exit 1
        }
    }
}

# --- Resolve the aliases, and reject the contradictions ---
# Done after the whole command line is parsed rather than inside the
# switch, so the error does not depend on the order the options were
# typed in. Every one of these is a case where continuing would produce a
# download that is quietly not what was asked for, which is the failure
# mode this pipeline works hardest to avoid.
if ($noAudio -and $noVideo) {
    Write-Usage "Error: --no-audio and --no-video together leave no media to download. Use --mode metadata-only (or comments-only / subs-only) if that is what you meant."
    exit 1
}
if ($noAudio) {
    if ($mode -and $mode -ne "video-only") {
        Write-Usage "Error: --no-audio is an alias for --mode video-only and cannot be combined with --mode $mode."
        exit 1
    }
    $mode = "video-only"
}
if ($noVideo) {
    if ($mode -and $mode -ne "audio-only") {
        Write-Usage "Error: --no-video is an alias for --mode audio-only and cannot be combined with --mode $mode."
        exit 1
    }
    $mode = "audio-only"
}

# A no-media mode plus an option that only describes media is a
# contradiction worth naming, not silently ignoring: someone who typed
# "--mode comments-only --quality 1080" has misunderstood what the mode
# does, and finding out now costs them a re-typed command instead of a
# finished run with no video in it.
if ($noMediaModes -contains $mode) {
    $mediaOnlyOpts = @()
    if ($quality -and $quality -ne "best") { $mediaOnlyOpts += "--quality" }
    if ($codec -and $codec -ne "any")      { $mediaOnlyOpts += "--codec" }
    if ($audioCodec -and $audioCodec -ne "any") { $mediaOnlyOpts += "--audio-codec" }
    if ($container)                        { $mediaOnlyOpts += "--container" }
    if ($mediaOnlyOpts.Count -gt 0) {
        Write-Usage "Error: --mode $mode downloads no media, so $($mediaOnlyOpts -join ' and ') cannot apply. Drop the option, or pick a mode that downloads media."
        exit 1
    }
}

# --mode comments-only with the comments pass switched off is the one
# combination that would run to completion and produce exactly nothing.
if ($mode -eq "comments-only" -and $noComments) {
    Write-Usage "Error: --mode comments-only with --no-comments would fetch nothing at all."
    exit 1
}
if ($mode -eq "subs-only" -and $noSubs) {
    Write-Usage "Error: --mode subs-only with --no-subs would fetch nothing at all."
    exit 1
}

# --audio-codec only reaches yt-dlp in audio-only mode (it drives the
# audio-extraction postprocessor, which only runs there). Warned about
# rather than rejected: it is a no-op, not a wrong result.
if ($audioCodec -and $audioCodec -ne "any" -and $mode -ne "audio-only") {
    Write-Usage "Warning: --audio-codec only applies to --mode audio-only; ignoring it for this run."
    $audioCodec = ""
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

if ($mode)           { $pwshArgs += @("-Mode", $mode) }
if ($quality)        { $pwshArgs += @("-Quality", $quality) }
if ($codec)          { $pwshArgs += @("-Codec", $codec) }
if ($audioCodec)     { $pwshArgs += @("-AudioCodec", $audioCodec) }
if ($container)      { $pwshArgs += @("-Container", $container) }
if ($noComments)     { $pwshArgs += "-NoComments" }
if ($noSubs)         { $pwshArgs += "-NoSubs" }
if ($noThumbnail)    { $pwshArgs += "-NoThumbnail" }
if ($noMetadata)     { $pwshArgs += "-NoMetadata" }

# --- Passing an ARRAY across `pwsh -File`, which cannot be done directly ---
# This is the same boundary problem setup-common.ps1 documents for
# -InheritedWarnings, and BOTH of the obvious spellings were tried here
# and observed to fail, rather than reasoned about:
#
#   -YtdlpArg a -YtdlpArg b   -> "Cannot bind parameter because parameter
#                                'YtdlpArg' is specified more than once."
#                                Repeating the name does not accumulate.
#   -YtdlpArg a,b             -> binds ONE element, the literal string
#                                "a,b". `-File` hands every argv entry to
#                                the parameter binder as a raw string, so
#                                PowerShell's array syntax is never
#                                evaluated -- the comma stays data.
#
# A delimiter-joined string is not the fix either, because there is no
# delimiter a yt-dlp argument cannot legitimately contain: --match-filter
# expressions carry commas, spaces, "&" and comparison operators as a
# matter of course.
#
# So the array crosses as base64-encoded JSON in a single scalar
# parameter: no quoting rules to survive, no temp file to create and clean
# up (setup-common.ps1's answer, appropriate there because those are
# free-text warnings, overkill for a handful of short arguments), and it
# round-trips a --match-filter string containing all four of the above
# intact. run_ytdlp.ps1 decodes it back into an array; 020-launcher
# asserts the round trip.
if ($ytdlpArgs.Count -gt 0) {
    $ytdlpArgsJson = ConvertTo-Json -Compress -InputObject @($ytdlpArgs)
    $ytdlpArgsB64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ytdlpArgsJson))
    $pwshArgs += @("-YtdlpArgsB64", $ytdlpArgsB64)
}

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