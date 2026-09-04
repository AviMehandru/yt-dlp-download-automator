<#
    scripts/ytdl.ps1 -- the single argument parser for every platform.

    Tested by substituting a recording stand-in for run_ytdlp.ps1 whose
    param() block is a byte-for-byte copy of the real one, then reading back
    exactly which parameters the launcher produced. That mirroring is not
    incidental: it means these tests also fail if ytdl.ps1 ever emits an
    argument run_ytdlp.ps1 could not bind, which is the actual failure the
    user would see and which no amount of reading either file in isolation
    would reveal.

    The single-extra-argument case has its own test because it is a
    regression, not a hypothetical: `ytdl <url> /some/path` used to crash
    with "[System.Char] has no method StartsWith", because a one-element
    branch of an if-expression unrolls to a bare string and $rest[0] then
    indexes a CHARACTER. It was found by running the thing, not by reading
    it, which is precisely the argument for having this file.
#>

Describe 'ytdl.ps1 argument parsing' {

    $root = New-TestRoot -Label 'launcher'
    Install-PipelineInto -TestRoot $root -RepoRoot $script:RepoRoot

    $capturePath = Join-Path $root.Root 'launcher-capture.json'
    $env:YTDL_TEST_CAPTURE = $capturePath

    # The stand-in. Its param() block deliberately duplicates run_ytdlp.ps1's
    # own, including [ValidateRange(1,64)] on -Workers, so a launcher that
    # emitted an out-of-range or misspelled parameter fails here the same way
    # it would in production.
    $standIn = @'
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $false)][string]$DataRoot = "",
    [Parameter(Mandatory = $false)][switch]$BreakOnExisting,
    [Parameter(Mandatory = $false)][string]$PlaylistItems = "",
    [Parameter(Mandatory = $false)][string]$DateAfter = "",
    [Parameter(Mandatory = $false)][switch]$LazyPlaylist,
    [Parameter(Mandatory = $false)][ValidateRange(1, 64)][int]$Workers = 1,
    [Parameter(Mandatory = $false)][ValidateRange(1024, 65535)][int]$PotPort = 4416,
    [Parameter(Mandatory = $false)][switch]$SkipPotUpdate,
    [Parameter(Mandatory = $false)][switch]$NoPot,
    [Parameter(Mandatory = $false)]
    [ValidateSet("full", "video-only", "audio-only", "metadata-only", "comments-only", "subs-only")]
    [string]$Mode = "full",
    [Parameter(Mandatory = $false)][string]$Quality = "best",
    [Parameter(Mandatory = $false)][ValidateSet("any", "avc1", "vp9", "av01")][string]$Codec = "any",
    [Parameter(Mandatory = $false)][ValidateSet("any", "opus", "aac", "mp3", "flac")][string]$AudioCodec = "any",
    [Parameter(Mandatory = $false)][ValidateSet("mkv", "mp4", "webm")][string]$Container = "",
    [Parameter(Mandatory = $false)][switch]$NoComments,
    [Parameter(Mandatory = $false)][switch]$NoSubs,
    [Parameter(Mandatory = $false)][switch]$NoThumbnail,
    [Parameter(Mandatory = $false)][switch]$NoMetadata,
    [Parameter(Mandatory = $false)][string]$YtdlpArgsB64 = ""
)
# The passthrough array is decoded here rather than captured raw, so the
# assertion in the test reads the arguments the way run_ytdlp.ps1 will
# actually see them -- which is the half of the base64 transport that can
# realistically break.
$decodedPassthrough = @()
if ($YtdlpArgsB64) {
    $decodedPassthrough = @([System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($YtdlpArgsB64)) | ConvertFrom-Json)
}
[ordered]@{
    Url             = $Url
    DataRoot        = $DataRoot
    BreakOnExisting = [bool]$BreakOnExisting
    PlaylistItems   = $PlaylistItems
    DateAfter       = $DateAfter
    LazyPlaylist    = [bool]$LazyPlaylist
    Workers         = $Workers
    PotPort         = $PotPort
    SkipPotUpdate   = [bool]$SkipPotUpdate
    NoPot           = [bool]$NoPot
    Mode            = $Mode
    Quality         = $Quality
    Codec           = $Codec
    AudioCodec      = $AudioCodec
    Container       = $Container
    NoComments      = [bool]$NoComments
    NoSubs          = [bool]$NoSubs
    NoThumbnail     = [bool]$NoThumbnail
    NoMetadata      = [bool]$NoMetadata
    Passthrough     = $decodedPassthrough
} | ConvertTo-Json | Set-Content -LiteralPath $env:YTDL_TEST_CAPTURE
'@
    Set-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1') -Value $standIn -Encoding utf8

    function Invoke-Launcher {
        param([AllowEmptyCollection()][string[]]$Arguments = @())
        if (Test-Path -LiteralPath $capturePath) { Remove-Item -LiteralPath $capturePath -Force }
        $result = Invoke-YtdlLauncher -TestRoot $root -Arguments $Arguments
        $captured = if (Test-Path -LiteralPath $capturePath) {
            Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
        } else { $null }
        $result | Add-Member -NotePropertyName Params -NotePropertyValue $captured -Force
        return $result
    }

    $url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'

    It 'prints usage and exits 1 with no arguments' {
        $r = Invoke-Launcher -Arguments @()
        Assert-Equal 1 $r.ExitCode 'no URL is a usage error, not a crash'
        Assert-Match 'Usage: ytdl' $r.Output
        # Write-Error would render a multi-line ERROR RECORD with a caret
        # diagram for "you forgot the URL". [Console]::Error keeps it to one
        # line, and that difference is the whole reason Write-Usage exists.
        Assert-NotMatch 'CategoryInfo|FullyQualifiedErrorId' $r.Output `
            'usage text must not come out as a PowerShell error record'
    }

    It 'passes a bare URL through untouched' {
        $r = Invoke-Launcher -Arguments @($url)
        Assert-Equal 0 $r.ExitCode
        Assert-True ($null -ne $r.Params) 'run_ytdlp.ps1 was never reached'
        Assert-Equal $url $r.Params.Url 'the "=" in a watch URL must survive the shims'
        Assert-Equal '' $r.Params.DataRoot
        Assert-Equal 1 $r.Params.Workers
        Assert-False $r.Params.BreakOnExisting
    }

    # --- Hyphen-leading URLs and ids ---------------------------------------
    #
    # YouTube ids are base64url, so "-QMgcOSyf-o" is an ordinary id and about
    # one in thirty starts with "-" or "_". Everything in the argument path
    # that could mistake such an id for an option is covered here; the other
    # half of the fix -- the "--" end-of-options marker on every yt-dlp
    # invocation -- is asserted in 030-config and 040-run-ytdlp, because that
    # is where the yt-dlp command line is actually built.
    $dashUrl = 'https://www.youtube.com/watch?v=-QMgcOSyf-o'

    It 'passes a URL whose video id starts with a hyphen through untouched' {
        $r = Invoke-Launcher -Arguments @($dashUrl)
        Assert-Equal 0 $r.ExitCode
        Assert-Equal $dashUrl $r.Params.Url 'a hyphen inside the URL must not turn it into an option'
    }

    It 'treats a bare hyphen-leading video id as the URL, not as an option' {
        # `ytdl -QMgcOSyf-o`. The launcher must not reject this, and -- the
        # part that is easy to get wrong -- pwsh's own -File binder must
        # still hand it to run_ytdlp.ps1 as the VALUE of -Url rather than
        # reading it as a second parameter name.
        $r = Invoke-Launcher -Arguments @('-QMgcOSyf-o')
        Assert-Equal 0 $r.ExitCode 'a leading hyphen alone must not be a usage error'
        Assert-Equal '-QMgcOSyf-o' $r.Params.Url
    }

    It 'still accepts a hyphen-leading URL alongside a path and options' {
        $r = Invoke-Launcher -Arguments @($dashUrl, '/tmp/dash root', '--sync', '--workers', '4')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal $dashUrl $r.Params.Url
        Assert-Equal '/tmp/dash root' $r.Params.DataRoot
        Assert-True $r.Params.BreakOnExisting
        Assert-Equal 4 $r.Params.Workers
    }

    It 'rejects an option in the URL position instead of downloading nothing' {
        # `ytdl --sync <url>` used to take "--sync" as the URL and the real
        # URL as the legacy positional download root: a doomed run into a
        # directory named after a YouTube link, with no error. Now that a
        # leading hyphen no longer implies "option", this has to be caught
        # explicitly.
        $r = Invoke-Launcher -Arguments @('--sync', $url)
        Assert-Equal 1 $r.ExitCode 'a missing URL must fail, not start a wrong run'
        Assert-Match 'first argument must be the URL' $r.Output
        Assert-True ($null -eq $r.Params) 'run_ytdlp.ps1 must not be started at all'
    }

    It 'keeps the missing-URL guard in step with the options the parser accepts' {
        # $knownOptions in ytdl.ps1 mirrors the switch cases rather than
        # driving them, so this asserts the mirror. Without it, adding an
        # option to the switch and forgetting the list would silently
        # restore the wrong-run behaviour above for that one option.
        $src = Get-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/ytdl.ps1') -Raw

        # (?s) so the capture can span lines: $knownOptions outgrew a single
        # line when the content options were added, and without it this
        # match failed outright rather than matching a shorter list.
        #
        # The character class is [a-z-] rather than [a-z] for a subtler
        # reason. With [a-z], every option carrying an internal hyphen was
        # invisible to BOTH halves of this comparison -- --no-pot,
        # --skip-pot-update and --pot-port before, and all ten content
        # options now. The test compared the six easy ones, found them
        # equal, and reported success while never having looked at two
        # thirds of the list it exists to guard. Same class of quiet
        # staleness as 070-installer's hardcoded step count: passing for a
        # reason unrelated to the thing being asserted.
        $listed = @()
        if ($src -match '(?sm)^\$knownOptions\s*=\s*@\((.*?)\)\s*$') {
            $listed = @([regex]::Matches($matches[1], '"(--[a-z-]+)"') |
                        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        }
        Assert-True ($listed.Count -gt 0) '$knownOptions could not be read out of ytdl.ps1'

        # The switch cases, read the same way: every quoted "--option" that
        # appears as a case label in the parsing loop.
        $cases = @([regex]::Matches($src, '(?m)^\s{8}"(--[a-z-]+)"\s*\{') |
                   ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        Assert-True ($cases.Count -gt 0) 'no switch cases could be read out of ytdl.ps1'

        Assert-Equal ($cases -join ',') ($listed -join ',') `
            '$knownOptions and the parser switch have drifted apart'
    }

    It 'warns, but still runs, when the first argument does not look like a URL' {
        # The one thing this script can say about shell-mangled URLs. zsh
        # kills an unquoted "watch?v=..." before ytdl is ever started and
        # bash truncates at "&", so neither is detectable here -- but an
        # argument that reaches us looking nothing like a URL is the visible
        # residue of a paste that went wrong, and naming quoting at that
        # moment beats an extractor error several layers down. A warning
        # rather than a rejection on purpose: guessing wrong must not break
        # a command that used to work.
        $r = Invoke-Launcher -Arguments @('watch-v-abc.html')
        Assert-Equal 0 $r.ExitCode 'the warning must not block the run'
        Assert-Match 'does not look like a YouTube URL' $r.Output
        Assert-Match 'quote it' $r.Output
        Assert-Equal 'watch-v-abc.html' $r.Params.Url 'the argument must still be passed through unchanged'
    }

    It 'stays silent for every URL shape that already worked' {
        foreach ($good in @(
            $url, $dashUrl, '-QMgcOSyf-o',
            'https://youtu.be/-QMgcOSyf-o',
            'youtu.be/-QMgcOSyf-o',
            'https://www.youtube.com/@SomeChannel/videos',
            'https://music.youtube.com/watch?v=dQw4w9WgXcQ'
        )) {
            $r = Invoke-Launcher -Arguments @($good)
            Assert-NotMatch 'does not look like a YouTube URL' $r.Output `
                "the shape warning must not fire on '$good'"
        }
    }

    It 'accepts the legacy positional path as the only extra argument' {
        # The regression case. Exactly ONE argument after the URL is what
        # collapsed $rest from an array into a bare string.
        $r = Invoke-Launcher -Arguments @($url, '/tmp/some archive path')
        Assert-Equal 0 $r.ExitCode 'a single positional path must not crash the parser'
        Assert-NotMatch 'StartsWith|System\.Char' $r.Output `
            'the array-unrolling guard on $rest has regressed'
        Assert-Equal '/tmp/some archive path' $r.Params.DataRoot 'a path with spaces must survive as one argument'
    }

    It 'accepts --path as the explicit form' {
        $r = Invoke-Launcher -Arguments @($url, '--path', '/tmp/explicit root')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '/tmp/explicit root' $r.Params.DataRoot
    }

    It 'translates --sync to -BreakOnExisting' {
        $r = Invoke-Launcher -Arguments @($url, '--sync')
        Assert-Equal 0 $r.ExitCode
        Assert-True $r.Params.BreakOnExisting
    }

    It 'translates --items to -PlaylistItems' {
        $r = Invoke-Launcher -Arguments @($url, '--items', '5,8,10-15')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '5,8,10-15' $r.Params.PlaylistItems
    }

    It 'translates --after to -DateAfter' {
        $r = Invoke-Launcher -Arguments @($url, '--after', '20250101')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '20250101' $r.Params.DateAfter
    }

    It 'translates --lazy to -LazyPlaylist' {
        $r = Invoke-Launcher -Arguments @($url, '--lazy')
        Assert-Equal 0 $r.ExitCode
        Assert-True $r.Params.LazyPlaylist
    }

    It 'translates --workers to -Workers' {
        $r = Invoke-Launcher -Arguments @($url, '--workers', '4')
        Assert-Equal 0 $r.ExitCode
        Assert-Equal 4 $r.Params.Workers
    }

    It 'accepts every option at once, in any order, after a positional path' {
        $r = Invoke-Launcher -Arguments @(
            $url, '/tmp/mixed root', '--workers', '3', '--sync',
            '--after', '20240301', '--items', '1-20', '--lazy'
        )
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '/tmp/mixed root' $r.Params.DataRoot
        Assert-Equal 3      $r.Params.Workers
        Assert-Equal '1-20' $r.Params.PlaylistItems
        Assert-Equal '20240301' $r.Params.DateAfter
        Assert-True $r.Params.BreakOnExisting
        Assert-True $r.Params.LazyPlaylist
    }

    It 'rejects --workers 0 and non-numeric worker counts before starting anything' {
        foreach ($bad in @('0', 'abc', '-1', '2.5')) {
            $r = Invoke-Launcher -Arguments @($url, '--workers', $bad)
            Assert-Equal 1 $r.ExitCode "--workers $bad should be rejected"
            Assert-Match 'requires a positive integer' $r.Output
            Assert-True ($null -eq $r.Params) `
                "--workers $bad reached run_ytdlp.ps1 -- validation must happen in the launcher so the message is readable"
        }
    }

    It 'rejects an option given without its value' {
        foreach ($opt in @('--items', '--after', '--workers', '--path')) {
            $r = Invoke-Launcher -Arguments @($url, $opt)
            Assert-Equal 1 $r.ExitCode "$opt with no value should be a usage error"
            Assert-Match 'requires' $r.Output
        }
    }

    It 'rejects an unknown option instead of forwarding it' {
        $r = Invoke-Launcher -Arguments @($url, '--turbo')
        Assert-Equal 1 $r.ExitCode
        Assert-Match 'Unknown option: --turbo' $r.Output
        Assert-Match 'Usage: ytdl' $r.Output 'an unknown option should also show usage'
    }

    It 'propagates run_ytdlp.ps1 exit codes rather than always reporting success' {
        Set-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1') `
                    -Value "param([string]`$Url)`nexit 42" -Encoding utf8
        try {
            $r = Invoke-YtdlLauncher -TestRoot $root -Arguments @($url)
            Assert-Equal 42 $r.ExitCode 'the launcher must pass the child exit code through'
        } finally {
            Set-Content -LiteralPath (Join-Path $root.InstallRoot 'scripts/run_ytdlp.ps1') -Value $standIn -Encoding utf8
        }
    }
    # -----------------------------------------------------------------
    # Content options (archive layout 2)
    # -----------------------------------------------------------------
    # These decide WHAT gets downloaded rather than how the session is
    # scheduled, so unlike the playlist options above they matter on a
    # single video URL too. The parser is still the only place the command
    # line is read, so this is still the only place their spellings are
    # checked.

    It 'translates every content option to its run_ytdlp.ps1 parameter' {
        $r = Invoke-Launcher -Arguments @($url,
            '--mode', 'audio-only', '--quality', '1080',
            '--codec', 'av01', '--audio-codec', 'opus', '--container', 'webm')
        Assert-Equal 0 $r.ExitCode 'a fully-specified content run must start'
        Assert-Equal 'audio-only' $r.Params.Mode
        Assert-Equal '1080'       $r.Params.Quality
        Assert-Equal 'av01'       $r.Params.Codec
        Assert-Equal 'opus'       $r.Params.AudioCodec
        Assert-Equal 'webm'       $r.Params.Container
    }

    It 'translates every component skip to its switch' {
        $r = Invoke-Launcher -Arguments @($url,
            '--no-comments', '--no-subs', '--no-thumbnail', '--no-metadata')
        Assert-Equal 0 $r.ExitCode
        Assert-True $r.Params.NoComments  '--no-comments must reach run_ytdlp.ps1'
        Assert-True $r.Params.NoSubs      '--no-subs must reach run_ytdlp.ps1'
        Assert-True $r.Params.NoThumbnail '--no-thumbnail must reach run_ytdlp.ps1'
        Assert-True $r.Params.NoMetadata  '--no-metadata must reach run_ytdlp.ps1'
    }

    It 'resolves --no-audio and --no-video to the equivalent mode' {
        $a = Invoke-Launcher -Arguments @($url, '--no-audio')
        Assert-Equal 'video-only' $a.Params.Mode '--no-audio is an alias for --mode video-only'

        $v = Invoke-Launcher -Arguments @($url, '--no-video')
        Assert-Equal 'audio-only' $v.Params.Mode '--no-video is an alias for --mode audio-only'
    }

    It 'rejects an invalid value for an enumerated option, naming the valid ones' {
        # Checked in the launcher rather than left to run_ytdlp.ps1's
        # [ValidateSet] so the message names the option the user typed
        # instead of a parameter on a script they never invoked. "av1" for
        # "av01" is the likeliest of these by a wide margin -- the codec's
        # marketing name has no zero in it and its format-field name does.
        $r = Invoke-Launcher -Arguments @($url, '--codec', 'av1')
        Assert-Equal 1 $r.ExitCode
        Assert-Match 'av01 is spelled with a zero' $r.Output
        Assert-True ($null -eq $r.Params) 'run_ytdlp.ps1 must not be started at all'

        $m = Invoke-Launcher -Arguments @($url, '--mode', 'audio only')
        Assert-Equal 1 $m.ExitCode
        Assert-Match '--mode must be one of' $m.Output
    }

    It 'rejects the combinations that would silently download nothing' {
        # Every one of these runs to completion and produces an empty or
        # wrong result rather than an error, which is exactly the class of
        # outcome this pipeline treats as worse than a loud failure.
        $both = Invoke-Launcher -Arguments @($url, '--no-audio', '--no-video')
        Assert-Equal 1 $both.ExitCode
        Assert-Match 'leave no media to download' $both.Output

        $clash = Invoke-Launcher -Arguments @($url, '--no-audio', '--mode', 'audio-only')
        Assert-Equal 1 $clash.ExitCode
        Assert-Match 'cannot be combined with --mode' $clash.Output

        $nothing = Invoke-Launcher -Arguments @($url, '--mode', 'comments-only', '--no-comments')
        Assert-Equal 1 $nothing.ExitCode
        Assert-Match 'would fetch nothing at all' $nothing.Output
    }

    It 'rejects a media option against a mode that downloads no media' {
        # "--mode comments-only --quality 1080" is a misunderstanding of
        # what the mode does, and saying so now costs a retyped command
        # instead of a finished run with no video in it.
        $r = Invoke-Launcher -Arguments @($url, '--mode', 'metadata-only', '--quality', '1080')
        Assert-Equal 1 $r.ExitCode
        Assert-Match 'downloads no media' $r.Output
    }

    It 'round-trips --ytdlp-arg values that no delimiter could survive' {
        # The reason the passthrough array crosses as base64 JSON rather
        # than as a joined string: a real --match-filter expression
        # contains commas, spaces, "&" and comparison operators, and
        # `pwsh -File` can bind neither a repeated parameter nor comma
        # array syntax. The stand-in decodes it the same way run_ytdlp.ps1
        # does, so this asserts the transport end to end.
        $filter = 'duration > 60 & title *= a,b'
        $r = Invoke-Launcher -Arguments @($url,
            '--ytdlp-arg', '--match-filter', '--ytdlp-arg', $filter,
            '--ytdlp-arg', '--sponsorblock-mark', '--ytdlp-arg', 'all')
        Assert-Equal 0 $r.ExitCode
        $pt = @($r.Params.Passthrough)
        Assert-Equal 4 $pt.Count 'every --ytdlp-arg value must arrive, in order'
        Assert-Equal '--match-filter'     $pt[0]
        Assert-Equal $filter              $pt[1] 'the filter expression must survive intact'
        Assert-Equal '--sponsorblock-mark' $pt[2]
        Assert-Equal 'all'                $pt[3]
    }

    It 'leaves the content parameters at their defaults when none are given' {
        # A plain run must produce the same invocation it always did --
        # the content options are additive, and a default run's command
        # line should not have changed at all.
        $r = Invoke-Launcher -Arguments @($url)
        Assert-Equal 'full' $r.Params.Mode
        Assert-Equal 'best' $r.Params.Quality
        Assert-Equal 'any'  $r.Params.Codec
        Assert-Equal ''     $r.Params.Container
        Assert-Equal 0 @($r.Params.Passthrough).Count
    }
}

Describe 'POSIX ytdl shim' {

    It 'reports a clear error when the launcher is missing' {
        if ($IsWindows) { Skip-Test 'scripts/ytdl is the Linux/macOS shim; ytdl.cmd is the Windows one.' }
        if (-not (Test-HasCommand 'bash')) { Skip-Test 'bash is not on PATH.' }
        $empty = New-TestRoot -Label 'shim-empty'
        $shim = Join-Path $script:RepoRoot 'scripts/ytdl'
        $out = & bash -c "YTDLP_INSTALL_ROOT='$($empty.InstallRoot)' '$shim' https://example.invalid 2>&1"
        Assert-Equal 1 $LASTEXITCODE
        Assert-Match 'launcher not found' $out
        Assert-Match 'YTDLP_INSTALL_ROOT' $out 'the error should say how to point at a non-default install'
        Remove-TestRoot $empty
    }

    It 'honours YTDLP_INSTALL_ROOT when locating ytdl.ps1' {
        if ($IsWindows) { Skip-Test 'POSIX shim only.' }
        if (-not (Test-HasCommand 'bash')) { Skip-Test 'bash is not on PATH.' }
        $r = New-TestRoot -Label 'shim-root'
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        # A run_ytdlp.ps1 that just announces itself, so reaching it proves
        # the whole shim -> ytdl.ps1 -> run_ytdlp.ps1 chain resolved.
        Set-Content -LiteralPath (Join-Path $r.InstallRoot 'scripts/run_ytdlp.ps1') `
                    -Value "param([string]`$Url)`nWrite-Output `"REACHED:`$Url`"" -Encoding utf8
        $shim = Join-Path $script:RepoRoot 'scripts/ytdl'
        $out = & bash -c "YTDLP_INSTALL_ROOT='$($r.InstallRoot)' '$shim' https://youtu.be/abc123 2>&1"
        Assert-Match 'REACHED:https://youtu.be/abc123' $out
        Remove-TestRoot $r
    }

}
