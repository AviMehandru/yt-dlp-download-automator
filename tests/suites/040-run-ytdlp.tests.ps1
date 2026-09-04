<#
    scripts/run_ytdlp.ps1 -- the session orchestrator.

    Run for real against a fixture data root, with yt-dlp replaced by a stub
    that records what it was asked to do. That is what turns "the code looks
    like it passes --download-archive" into "--download-archive was passed,
    and it pointed at the archive file under the data root that was actually
    used for this run".

    The dependency-check throttle test and the -BreakOnExisting truncation
    test both cover bugs that already shipped once. Neither was visible by
    reading the code:

      * The throttle marker is dot-prefixed, and PowerShell maps the Unix
        "leading dot means hidden" convention onto the Hidden attribute, so
        Get-Item WITHOUT -Force throws "Could not find item" on a path
        Test-Path just said exists. The visible symptom was only that
        `yt-dlp -U` ran on every invocation instead of once a day -- mild
        enough to go unnoticed for a long time, and invisible on Windows,
        where a leading dot means nothing.

      * `$videoIds[0..($cutIndex - 1)]` with $cutIndex = 0 evaluates 0..-1,
        which PowerShell reads as a DESCENDING range: indexes 0 and -1, the
        first element and the last one. A --sync run whose newest video was
        already archived -- the single most common --sync case -- therefore
        queued the already-archived video plus an unrelated oldest one.
#>

Describe 'run_ytdlp.ps1 session orchestration' {

    # A stub that behaves like a real single-video download session: it
    # prints the several "[youtube] <id>: Downloading ..." lines a real run
    # produces for ONE video, which is what the session summary has to
    # de-duplicate.
    $downloadBehavior = {
        if ($StubArgs -contains '--version') { Write-Output '2026.08.20'; return }
        if ($StubArgs -contains '-U')        { Write-Output 'yt-dlp is up to date'; return }
        Write-Output '[youtube] Extracting URL: https://www.youtube.com/watch?v=testVideo01'
        Write-Output '[youtube] testVideo01: Downloading webpage'
        Write-Output '[youtube] testVideo01: Downloading tv player API JSON'
        Write-Output '[youtube] testVideo01: Downloading m3u8 information'
        Write-Output '[info] testVideo01: Downloading 1 format(s): 248+251'
        Write-Output 'WARNING: Some subtitles could not be downloaded'
    }

    function New-OrchestratorRoot {
        param([string]$Label, [scriptblock]$Behavior, [switch]$SkipThrottleSeed)
        $r = New-TestRoot -Label $Label
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        Enable-Stubs -TestRoot $r
        New-StubBinary -TestRoot $r -Name 'yt-dlp' -Behavior $Behavior | Out-Null
        if (-not $SkipThrottleSeed) {
            # Seed the once-a-day marker so the dependency check is skipped.
            # Without this every test in this file would run `yt-dlp -U`, a
            # package-manager query, and (on Linux) a real HTTPS call to
            # GitHub for the latest pwsh release -- slow, and a network
            # dependency in tests that are about something else entirely.
            Set-Content -LiteralPath (Join-Path $r.InstallRoot '.last_dependency_check') `
                        -Value (Get-Date -Format 'o') -Encoding utf8
        }
        return $r
    }

    It 'recreates every structural folder in an empty data root' {
        $r = New-OrchestratorRoot -Label 'selfheal' -Behavior $downloadBehavior
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            foreach ($rel in @(
                'Archive Logs/Logs', 'Archive Logs/Archive History',
                'Youtube Videos/Complete Archive',
                'Youtube Videos/Final Video'
            )) {
                Assert-PathExists (Join-Path $r.DataRoot $rel) `
                    "the self-heal step must recreate $rel on every invocation"
            }
            # _incomplete is the one structural folder NOT asserted above:
            # self-heal creates it, and the end-of-session cleanup removes it
            # again because this run left it empty. Its recreation is
            # asserted through the log line instead, so this test still fails
            # if self-heal ever stops creating it.
            Assert-Match ([regex]::Escape("Recreated missing folder: $(Join-Path $r.DataRoot 'Youtube Videos/_incomplete')")) `
                ($run.Output -join "`n") 'self-heal must still create _incomplete before the download'
        } finally { Remove-TestRoot $r }
    }

    # The two tests below are the whole contract of the end-of-session
    # _incomplete cleanup: empty means disposable, anything at all inside
    # means a partial download that yt-dlp can still resume, and resuming
    # needs those exact fragments. Getting the second case wrong turns a
    # housekeeping convenience into silent data loss, which is why the
    # not-empty case is tested with a HIDDEN file specifically -- the
    # emptiness check reads as correct either way, and only -Force on
    # Get-ChildItem makes it actually correct.
    It 'removes the _incomplete staging folder when the session leaves it empty' {
        $r = New-OrchestratorRoot -Label 'sweepempty' -Behavior $downloadBehavior
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            Assert-PathMissing (Join-Path $r.DataRoot 'Youtube Videos/_incomplete') `
                'an empty _incomplete must not survive the end of a session'
            Assert-Match 'Removed the empty _incomplete staging folder' ($run.Output -join "`n")
        } finally { Remove-TestRoot $r }
    }

    It 'keeps _incomplete when a partial download is still staged in it' {
        $r = New-OrchestratorRoot -Label 'sweepkeep' -Behavior $downloadBehavior
        try {
            $incomplete = Join-Path $r.DataRoot 'Youtube Videos/_incomplete'
            New-Item -ItemType Directory -Path $incomplete -Force | Out-Null
            # Dot-prefixed, so PowerShell treats it as hidden on Unix and
            # Get-ChildItem WITHOUT -Force would not see it at all.
            $partial = Join-Path $incomplete '.testVideo02.f248.mp4.part'
            Set-Content -LiteralPath $partial -Value 'partial fragment' -Encoding utf8

            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            Assert-PathExists $incomplete 'a non-empty _incomplete must be left alone'
            Assert-PathExists $partial 'resumable fragments must survive the cleanup untouched'
            Assert-Match 'Kept _incomplete' ($run.Output -join "`n")
        } finally { Remove-TestRoot $r }
    }

    It 'builds the yt-dlp command line from the data root that was actually used' {
        $r = New-OrchestratorRoot -Label 'cmdline' -Behavior $downloadBehavior
        try {
            $null = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            $download = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                          Where-Object { $_.line -match '--download-archive' }) | Select-Object -First 1
            Assert-True ($null -ne $download) 'no download invocation was recorded'

            $argv = @($download.args)
            # These four are on the command line rather than in yt-dlp.conf
            # precisely so they can follow -DataRoot. Asserting the VALUE,
            # not just the flag, is the point: a flag present but pointing
            # at the default root would archive into the wrong place.
            $archiveIdx = [Array]::IndexOf($argv, '--download-archive')
            Assert-True ($archiveIdx -ge 0) '--download-archive must be passed on the command line'
            Assert-Equal (Join-Path $r.DataRoot 'Archive Logs/Logs/archive.txt') $argv[$archiveIdx + 1] `
                'the download archive must live under the data root actually in use'

            Assert-Match '--paths home:' $download.line
            Assert-Match ([regex]::Escape((Join-Path $r.DataRoot 'Youtube Videos/Complete Archive'))) $download.line
            Assert-Match '--paths temp:' $download.line
            Assert-Match ([regex]::Escape((Join-Path $r.DataRoot 'Youtube Videos/_incomplete'))) $download.line

            $execIdx = [Array]::IndexOf($argv, '--exec')
            Assert-True ($execIdx -ge 0) '--exec must be passed on the command line'
            $exec = $argv[$execIdx + 1]
            Assert-Match '^after_move:' $exec 'the hook must fire after the file is moved, not before'
            Assert-Match ([regex]::Escape((Join-Path $r.InstallRoot 'scripts/postprocess.ps1'))) $exec `
                'the hook must point at postprocess.ps1 in the INSTALL root, which does not move with -DataRoot'
            Assert-Match '%\(filepath\)q' $exec 'the hook must pass yt-dlp its own quoted filepath'
            Assert-Match '-LogFileName' $exec

            # --config-location must point at the installed configs/ (plural)
            # directory, not the repo's config/ (singular). The asymmetry is
            # real and documented; getting it wrong yields a blank config
            # version in every manifest and no error anywhere.
            $confIdx = [Array]::IndexOf($argv, '--config-location')
            Assert-True ($confIdx -ge 0) '--config-location must be passed'
            Assert-Equal (Join-Path $r.InstallRoot 'configs/yt-dlp.conf') $argv[$confIdx + 1]
        } finally { Remove-TestRoot $r }
    }

    It 'hands yt-dlp a hyphen-leading URL behind an end-of-options marker' {
        # 030-config asserts the "--" is written at every call site. This
        # asserts it SURVIVES: PowerShell gives "--" its own meaning when
        # binding cmdlet parameters, and only passes it through as a literal
        # argument because yt-dlp is a native command. Reading the source
        # cannot tell those two apart -- running it can, which is what this
        # does, by reading the arguments a stub yt-dlp was actually handed.
        $dashUrl = 'https://www.youtube.com/watch?v=-QMgcOSyf-o'
        $r = New-OrchestratorRoot -Label 'dashurl' -Behavior $downloadBehavior
        try {
            $null = Invoke-RunYtdlp -TestRoot $r -Url $dashUrl
            $download = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                          Where-Object { $_.line -match '--download-archive' }) | Select-Object -First 1
            Assert-True ($null -ne $download) 'no download invocation was recorded'

            $argv = @($download.args)
            Assert-Equal $dashUrl $argv[-1] 'the URL must be the last argument, unaltered'
            Assert-Equal '--' $argv[-2] `
                'the end-of-options marker must reach yt-dlp as a real argument, immediately before the URL'
        } finally { Remove-TestRoot $r }
    }

    It 'counts distinct video ids in the session summary, not matching lines' {
        # A real single-video run prints several "[youtube] <id>: Downloading"
        # lines -- webpage, player API JSON, m3u8 -- and a plain line count
        # reported "3 video(s) touched" for one video. How many appear
        # depends on which extraction path yt-dlp took, so it is not a fixed
        # multiplier that could be divided out either.
        $r = New-OrchestratorRoot -Label 'summary' -Behavior $downloadBehavior
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            Assert-Match '1 video\(s\) touched' $run.Output `
                'three "Downloading" lines for one id must still count as one video'
            Assert-Match '1 warning\(s\)' $run.Output
            Assert-Match '0 error\(s\)' $run.Output

            $log = Join-Path $r.DataRoot 'Archive Logs/Logs/download.log'
            Assert-FileMatches $log '==== Download session started'
            Assert-FileMatches $log '==== Download session finished'
            Assert-FileMatches $log 'config version: \d+' 'the config version must be recorded in the session header'
        } finally { Remove-TestRoot $r }
    }

    It 'snapshots archive.txt and the global manifest before the run touches them' {
        $r = New-OrchestratorRoot -Label 'snapshot' -Behavior $downloadBehavior
        try {
            $logsDir = Join-Path $r.DataRoot 'Archive Logs/Logs'
            $videosRoot = Join-Path $r.DataRoot 'Youtube Videos'
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            New-Item -ItemType Directory -Path $videosRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $logsDir 'archive.txt') -Value 'youtube previouslyArchived' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $videosRoot 'global_manifest.json') -Value '[{"video_id":"previouslyArchived"}]' -Encoding utf8

            $null = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'

            $history = Join-Path $r.DataRoot 'Archive Logs/Archive History'
            $archiveSnaps  = @(Get-ChildItem -LiteralPath $history -Filter 'archive_*.txt')
            $manifestSnaps = @(Get-ChildItem -LiteralPath $history -Filter 'global_manifest_*.json')
            Assert-True ($archiveSnaps.Count -ge 1)  'archive.txt should be snapshotted into Archive History'
            Assert-True ($manifestSnaps.Count -ge 1) 'global_manifest.json should be snapshotted into Archive History'
            Assert-FileMatches $archiveSnaps[0].FullName 'previouslyArchived' `
                'the snapshot must be the PRE-run content'
        } finally { Remove-TestRoot $r }
    }

    It 'throttles the dependency check to once a day' {
        # The dot-prefixed-marker bug. On Linux and macOS this reproduced
        # 100% of the time and made `yt-dlp -U` run on every single
        # invocation; on Windows it never happened at all.
        $r = New-OrchestratorRoot -Label 'throttle' -Behavior $downloadBehavior -SkipThrottleSeed
        try {
            $null = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            $marker = Join-Path $r.InstallRoot '.last_dependency_check'
            Assert-PathExists $marker 'the first run must write the throttle marker'
            $firstUpdates = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' | Where-Object { $_.args -contains '-U' }).Count
            Assert-True ($firstUpdates -ge 1) 'the first run should perform the dependency check'

            Clear-StubCalls -TestRoot $r
            $second = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            $secondUpdates = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' | Where-Object { $_.args -contains '-U' }).Count
            Assert-Equal 0 $secondUpdates @"
The second run within the throttle window still ran `yt-dlp -U`.
The marker is dot-prefixed, so PowerShell treats it as hidden, and
Get-Item WITHOUT -Force throws "Could not find item" on a path Test-Path
just confirmed exists. The catch then falls back to "needs a check", so
the throttle silently never engages on Linux or macOS.
"@
            Assert-NotMatch 'Could not read the throttle marker' $second.Output
        } finally { Remove-TestRoot $r }
    }

    It 'warns, rather than failing, when no deno binary can be found' {
        $r = New-OrchestratorRoot -Label 'nodeno' -Behavior $downloadBehavior
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://youtu.be/testVideo01'
            $download = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                          Where-Object { $_.line -match '--download-archive' }) | Select-Object -First 1
            if (Test-HasCommand 'deno') {
                Assert-Match '--js-runtimes' $download.line 'deno is installed here, so it should be passed'
            } else {
                Assert-Match 'no deno binary found' $run.Output
                Assert-NotMatch '--js-runtimes' $download.line `
                    'with no deno found, --js-runtimes must be omitted entirely rather than passed empty'
                # The array-unrolling guard: an empty @() splats to nothing.
                # A bare $null would too, by luck rather than construction --
                # what must never happen is a stray blank argument.
                Assert-NotMatch '\s{2,}' ($download.args -join '|') 'no empty argument should reach yt-dlp'
            }
        } finally { Remove-TestRoot $r }
    }
}

Describe 'run_ytdlp.ps1 parallel dispatch' {

    # Enumerates three ids, then behaves like a per-video download.
    $parallelBehavior = {
        if ($StubArgs -contains '--version') { Write-Output '2026.08.20'; return }
        if ($StubArgs -contains '-U')        { Write-Output 'yt-dlp is up to date'; return }
        if ($StubArgs -contains '--flat-playlist') {
            Write-Output '[youtube:tab] Extracting URL: (enumeration)'
            foreach ($id in ($env:YTDLP_TEST_IDS -split ',')) { Write-Output $id }
            return
        }
        $url = @($StubArgs)[-1]
        Write-Output "[youtube] Extracting URL: $url"
        Write-Output '[info] Downloading 1 format(s): 248+251'
    }

    function New-ParallelRoot {
        param([string]$Label)
        $r = New-TestRoot -Label $Label
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        Enable-Stubs -TestRoot $r
        New-StubBinary -TestRoot $r -Name 'yt-dlp' -Behavior $parallelBehavior | Out-Null
        Set-Content -LiteralPath (Join-Path $r.InstallRoot '.last_dependency_check') `
                    -Value (Get-Date -Format 'o') -Encoding utf8
        return $r
    }

    It 'enumerates once up front and dispatches one download per video' {
        $env:YTDLP_TEST_IDS = 'aaa111,bbb222,ccc333'
        $r = New-ParallelRoot -Label 'dispatch'
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://www.youtube.com/@chan/videos' -ExtraArgs @('-Workers', '2')
            Assert-Match '3 video\(s\) queued' $run.Output

            $enumerations = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' | Where-Object { $_.args -contains '--flat-playlist' })
            Assert-Equal 1 $enumerations.Count `
                'the listing must happen exactly once, up front -- that is what stops two workers picking the same video'
            Assert-Match '--skip-download' $enumerations[0].line 'the enumeration pass must not download anything'

            $downloads = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                           Where-Object { $_.args -contains '--download-archive' })
            Assert-Equal 3 $downloads.Count 'one download invocation per enumerated video'

            # Each worker gets its own log, because video_complete.log is
            # built by finding "the most recent session-start marker" --
            # meaningless in a shared log with interleaved concurrent writers.
            foreach ($id in @('aaa111', 'bbb222', 'ccc333')) {
                Assert-PathExists (Join-Path $r.DataRoot "Archive Logs/Logs/download.worker-$id.log")
                $matching = @($downloads | Where-Object { $_.line -match "download\.worker-$id\.log" })
                Assert-Equal 1 $matching.Count "video $id must download into its own worker log"
            }
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_IDS = $null }
    }

    It 'queues nothing when --sync finds the newest video already archived' {
        # The 0..-1 descending-range bug, and the single most common --sync
        # case: a periodic re-run against a channel with nothing new. The
        # broken version queued the already-archived video PLUS the oldest
        # one in the listing.
        $env:YTDLP_TEST_IDS = 'aaa111,bbb222,ccc333'
        $r = New-ParallelRoot -Label 'sync-none-new'
        try {
            $logsDir = Join-Path $r.DataRoot 'Archive Logs/Logs'
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $logsDir 'archive.txt') -Value 'youtube aaa111' -Encoding utf8

            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://www.youtube.com/@chan/videos' `
                                   -ExtraArgs @('-Workers', '2', '-BreakOnExisting')
            Assert-Match '0 of 3 enumerated video\(s\) are actually new' $run.Output
            $downloads = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                           Where-Object { $_.args -contains '--download-archive' })
            Assert-Equal 0 $downloads.Count @"
--sync queued videos when the newest one was already archived.
`$videoIds[0..(`$cutIndex - 1)] with `$cutIndex = 0 evaluates 0..-1, which
PowerShell reads as a DESCENDING range -- indexes 0 and -1, i.e. the first
element and the last one. The guard for `$cutIndex -eq 0 has regressed.
"@
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_IDS = $null }
    }

    It 'truncates the queue at the first already-archived video' {
        $env:YTDLP_TEST_IDS = 'aaa111,bbb222,ccc333,ddd444'
        $r = New-ParallelRoot -Label 'sync-truncate'
        try {
            $logsDir = Join-Path $r.DataRoot 'Archive Logs/Logs'
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
            # archive.txt lines are "<extractor> <id>"; only the last field
            # is the id, which is what the truncation logic must read.
            Set-Content -LiteralPath (Join-Path $logsDir 'archive.txt') -Value @('youtube ccc333') -Encoding utf8

            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://www.youtube.com/@chan/videos' `
                                   -ExtraArgs @('-Workers', '2', '-BreakOnExisting')
            Assert-Match '2 of 4 enumerated video\(s\) are actually new' $run.Output
            $downloaded = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                            Where-Object { $_.args -contains '--download-archive' } |
                            ForEach-Object { if ($_.line -match '(https://youtu\.be/(\S+))') { $Matches[2] } })
            Assert-Equal 2 $downloaded.Count
            Assert-True ($downloaded -contains 'aaa111') 'videos before the cut must still be queued'
            Assert-True ($downloaded -contains 'bbb222')
            Assert-False ($downloaded -contains 'ccc333') 'the already-archived video must not be re-downloaded'
            Assert-False ($downloaded -contains 'ddd444') 'nothing after the cut should be queued'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_IDS = $null }
    }

    It 'says so instead of silently doing nothing when enumeration returns no ids' {
        $env:YTDLP_TEST_IDS = ''
        $r = New-ParallelRoot -Label 'sync-empty'
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://www.youtube.com/@chan/videos' -ExtraArgs @('-Workers', '2')
            Assert-Match 'Enumeration returned no video IDs' $run.Output
            Assert-Match '\[enumerate\]' $run.Output 'the raw enumeration output must be logged so the real error is findable'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_IDS = $null }
    }

    It 'notes that --lazy has no effect alongside -Workers > 1' {
        $env:YTDLP_TEST_IDS = 'aaa111'
        $r = New-ParallelRoot -Label 'lazy-note'
        try {
            $run = Invoke-RunYtdlp -TestRoot $r -Url 'https://www.youtube.com/@chan/videos' `
                                   -ExtraArgs @('-Workers', '2', '-LazyPlaylist')
            Assert-Match 'LazyPlaylist has no effect' $run.Output `
                'the combination must be reported, not silently dropped'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_IDS = $null }
    }

    It 'applies --items and --after at enumeration time' {
        $env:YTDLP_TEST_IDS = 'aaa111'
        $r = New-ParallelRoot -Label 'enum-filters'
        try {
            $null = Invoke-RunYtdlp -TestRoot $r -Url 'https://www.youtube.com/@chan/videos' `
                                    -ExtraArgs @('-Workers', '2', '-PlaylistItems', '1-20', '-DateAfter', '20250101')
            $enum = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' | Where-Object { $_.args -contains '--flat-playlist' })[0]
            Assert-Match '--playlist-items 1-20' $enum.line
            Assert-Match '--dateafter 20250101' $enum.line
            # A single video URL has no "playlist items" to select, so these
            # must NOT be forwarded to the per-video downloads.
            $downloads = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' | Where-Object { $_.args -contains '--download-archive' })
            foreach ($d in $downloads) {
                Assert-NotMatch '--playlist-items' $d.line `
                    'per-video downloads use a bare video URL; forwarding --playlist-items there is meaningless'
            }
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_IDS = $null }
    }
}