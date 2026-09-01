<#
    Concurrency. The reason -Workers N is safe, and the only part of this
    pipeline whose failure mode is silent data loss rather than an error.

    Two instances of postprocess.ps1 doing their own read-modify-write of
    global_manifest.json each read the "before" state, each compute their
    own "after", and whichever writes last wins -- the other's update is
    simply gone. Nothing throws. Nothing appears in any log. The only way to
    find out is to count entries afterwards, which is exactly what these
    tests do.

    Run at real concurrency rather than simulated: N genuine child processes
    started at once, the same shape as -Workers N. A lock bug that only
    appears under contention cannot be found any other way, and CLAUDE.md's
    existing verification note ("six concurrent instances across two
    channels") was a one-off manual exercise that nothing repeated.
#>

Describe 'Concurrent postprocess instances' {

    $lockStub = {
        if ($StubArgs -contains '--version') { Write-Output '2026.08.20'; return }
        if ($StubArgs -contains '-U')        { Write-Output 'yt-dlp is up to date'; return }
        # No comments and no channel refresh: this suite is about the
        # locked sections, and a real fetch would dominate the runtime
        # without exercising them any harder.
        Write-Output '[stub] no-op'
    }

    function New-ContentionFixture {
        <#
            One install root, several videos, optionally spread across two
            channels. Returns the root plus the list of .mkv paths to hand
            to concurrent instances.
        #>
        param([string]$Label, [string[]]$Channels, [int]$PerChannel)
        $r = New-TestRoot -Label $Label
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        Enable-Stubs -TestRoot $r
        New-StubBinary -TestRoot $r -Name 'yt-dlp' -Behavior $lockStub | Out-Null

        $videos = @()
        foreach ($channel in $Channels) {
            for ($i = 1; $i -le $PerChannel; $i++) {
                $id = ('{0}{1:d2}' -f ($channel -replace '[^A-Za-z]', ''), $i)
                $v = New-VideoFolder -TestRoot $r -Uploader $channel -VideoId $id `
                                     -Title "Video $i" -SeedChannelInfoThrottle -OmitUrls
                # Each concurrent instance needs its OWN log, because
                # video_complete.log is built by finding "the most recent
                # session-start marker" -- meaningless in a shared log with
                # interleaved writers. This is the same reason run_ytdlp.ps1
                # gives every parallel worker a download.worker-<id>.log.
                New-SessionLog -TestRoot $r -LogFileName "download.worker-$id.log" | Out-Null
                $videos += [pscustomobject]@{ Mkv = $v.MkvPath; Id = $id; Channel = $channel; Dir = $v.ChannelDir }
            }
        }
        # Pre-seed the global manifest with a realistic number of existing
        # entries. This is not padding: the read-modify-write is
        # ConvertFrom-Json, a filter, and ConvertTo-Json over the WHOLE
        # file, so against an empty manifest it finishes in microseconds and
        # two unsynchronized instances can miss each other by luck. A
        # verified-by-mutation detail -- removing the lock from
        # postprocess.ps1 did NOT reliably lose updates against an empty
        # manifest, and did against this one. A real archive has hundreds of
        # entries here, so this is also the more faithful fixture.
        $videosRoot = Join-Path $r.DataRoot 'Youtube Videos'
        New-Item -ItemType Directory -Path $videosRoot -Force | Out-Null
        $seed = @(1..300 | ForEach-Object {
            [ordered]@{
                video_id    = ('seed{0:d4}' -f $_)
                title       = "Previously archived video $_"
                uploader    = 'Seed Channel'
                upload_date = '20240101'
                url         = "https://www.youtube.com/watch?v=seed$_"
                folder      = (Join-Path $videosRoot "Complete Archive/Seed Channel/entry-$_")
            }
        })
        $seed | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $videosRoot 'global_manifest.json') -Encoding utf8
        $r | Add-Member -NotePropertyName SeedCount -NotePropertyValue $seed.Count -Force

        $r | Add-Member -NotePropertyName Videos -NotePropertyValue $videos -Force
        return $r
    }

    function Invoke-Concurrently {
        param($TestRoot, [int]$Throttle = 6)
        $pwshExe    = Get-PwshPath
        $scriptPath = Join-Path $TestRoot.InstallRoot 'scripts/postprocess.ps1'
        $installRoot = $TestRoot.InstallRoot
        return @($TestRoot.Videos | ForEach-Object -ThrottleLimit $Throttle -Parallel {
            # Every outer variable must be passed with $using: -- a
            # -Parallel iteration runs in its own runspace and does not
            # inherit script scope. (Environment variables DO cross, since
            # they belong to the process, which is why PATH still finds the
            # stub in here.)
            $env:YTDLP_INSTALL_ROOT = $using:installRoot
            $video = $_
            $out = & $using:pwshExe -NoProfile -File $using:scriptPath `
                       -FilePath $video.Mkv -LogFileName "download.worker-$($video.Id).log" 2>&1 |
                   ForEach-Object { "$_" }
            [pscustomobject]@{ Id = $video.Id; Output = @($out) }
        })
    }

    It 'loses no global manifest updates with six instances across two channels' {
        $r = New-ContentionFixture -Label 'lock-global' -Channels @('Alpha Channel', 'Beta Channel') -PerChannel 3
        try {
            $runs = Invoke-Concurrently -TestRoot $r -Throttle 6
            Assert-Equal 6 $runs.Count

            foreach ($run in $runs) {
                Assert-NotMatch 'Timed out .* waiting for lock' $run.Output `
                    "instance $($run.Id) timed out waiting for a lock -- a holder is not releasing"
                Assert-Match 'Post-processing complete' $run.Output "instance $($run.Id) did not finish"
            }

            $globalPath = Join-Path $r.DataRoot 'Youtube Videos/global_manifest.json'
            Assert-PathExists $globalPath
            $global = @(Get-Content -LiteralPath $globalPath -Raw | ConvertFrom-Json)
            $ids = @($global | ForEach-Object { $_.video_id } | Sort-Object -Unique)
            $expected = @($r.Videos | ForEach-Object { $_.Id } | Sort-Object -Unique)

            # The pre-existing entries must survive too. A lock bug that
            # replaced the file rather than merging into it would otherwise
            # pass every check below.
            $survivingSeed = @($ids | Where-Object { $_ -like 'seed*' }).Count
            Assert-Equal $r.SeedCount $survivingSeed `
                'the already-archived entries in global_manifest.json were dropped -- each instance must merge into the existing file, not replace it'

            $ids = @($ids | Where-Object { $_ -notlike 'seed*' })
            if ($ids.Count -ne $expected.Count) {
                $lost = @($expected | Where-Object { $ids -notcontains $_ })
                throw @"
Lost updates in global_manifest.json: expected $($expected.Count) entries, found $($ids.Count).
Missing: $($lost -join ', ')
Two instances read the same "before" state and the later write silently
overwrote the earlier one. The global manifest is shared across EVERY
channel, so it needs its own lock at the Youtube Videos/ root -- the
per-channel lock does not serialize videos from different channels.
"@
            }
        } finally { Remove-TestRoot $r }
    }

    It 'loses no channel manifest updates when four instances share one channel' {
        $r = New-ContentionFixture -Label 'lock-channel' -Channels @('Contended Channel') -PerChannel 4
        try {
            $null = Invoke-Concurrently -TestRoot $r -Throttle 4
            $channelPath = Join-Path $r.Videos[0].Dir 'channel_manifest.json'
            Assert-PathExists $channelPath
            $channel = @(Get-Content -LiteralPath $channelPath -Raw | ConvertFrom-Json)
            $ids = @($channel | ForEach-Object { $_.video_id } | Sort-Object -Unique)
            Assert-Equal 4 $ids.Count `
                "channel_manifest.json should hold all four videos, found: $($ids -join ', ')"
        } finally { Remove-TestRoot $r }
    }

    It 'keeps the Final Video repository consistent with the manifests it copies' {
        # The channel manifest, the Channel Info refresh and the Final Video
        # sync are one critical section on purpose: the sync READS the first
        # two immediately after they are written, so splitting them would
        # let a concurrent sibling video interleave a half-written state
        # into the copy.
        $r = New-ContentionFixture -Label 'lock-finalvideo' -Channels @('Sync Channel') -PerChannel 4
        try {
            $null = Invoke-Concurrently -TestRoot $r -Throttle 4
            $repo = Join-Path $r.DataRoot 'Youtube Videos/Final Video/Sync Channel'
            Assert-PathExists $repo

            $copied = @(Get-ChildItem -LiteralPath $repo -Filter '*.mkv')
            Assert-Equal 4 $copied.Count 'every video should reach the Final Video repository exactly once'

            # The synced manifest must be valid JSON, not a torn write.
            $syncedManifest = Join-Path $repo 'channel_manifest.json'
            Assert-PathExists $syncedManifest
            $parsed = $null
            try { $parsed = @(Get-Content -LiteralPath $syncedManifest -Raw | ConvertFrom-Json) }
            catch { throw "the synced channel_manifest.json is not parseable JSON -- a concurrent write was copied mid-flight: $($_.Exception.Message)" }
            Assert-True ($parsed.Count -ge 1) 'the synced manifest should not be empty'
        } finally { Remove-TestRoot $r }
    }

    It 'creates its lock files at the documented paths' {
        $r = New-ContentionFixture -Label 'lock-paths' -Channels @('Lock Channel') -PerChannel 1
        try {
            $null = Invoke-Concurrently -TestRoot $r -Throttle 1
            Assert-PathExists (Join-Path $r.DataRoot 'Youtube Videos/.global_manifest.lock') `
                'the global manifest lock belongs at the Youtube Videos root, above every channel'
            Assert-PathExists (Join-Path $r.Videos[0].Dir '.postprocess.lock') `
                'the per-channel lock belongs inside the channel folder, so different channels never contend'
        } finally { Remove-TestRoot $r }
    }

    It 'uses a lock primitive that is genuinely exclusive on this platform' {
        # The mechanism itself, isolated: FileShare.None was chosen over the
        # Unix flock binary specifically because Windows has no equivalent.
        # If the .NET primitive were not exclusive here, every test above
        # would pass by luck of timing rather than by locking.
        $r = New-TestRoot -Label 'lock-primitive'
        try {
            $lockPath = Join-Path $r.Root 'exclusive.lock'
            $first = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
                                            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                Assert-Throws {
                    [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
                                           [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                } '.' 'a second FileShare.None open of a held lock must fail'
            } finally { $first.Close(); $first.Dispose() }

            # And it must be re-acquirable once released, or the first
            # video in a session would wedge every one after it.
            $second = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
                                             [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $second.Close(); $second.Dispose()
        } finally { Remove-TestRoot $r }
    }
}
