<#
    scripts/postprocess.ps1 -- the per-video pipeline, run for real against
    fabricated video folders with yt-dlp stubbed.

    This is the file where a mistake is most expensive and least visible.
    postprocess.ps1 runs inside yt-dlp's own --exec hook, once per moved
    file, in a process whose output is buried in a download log; almost
    everything it does wrong it does quietly. The bugs already found in it
    were all of that shape: a checksum manifest with one entry that could
    never verify, a Channel Info refresh that silently stopped after the
    first video in each channel, comment-warning counts that were exactly
    double reality, and pre-merge streams overwriting the real video in the
    Final Video repository depending on which invocation finished last.

    Every one of those has a test here, phrased as the thing that should be
    true rather than the mistake that was made.
#>

# ---------------------------------------------------------------------
# Stub behavior shared by most of the tests below.
#
# It is a single scriptblock rather than one per test because postprocess
# makes three DIFFERENT yt-dlp calls (version query, comments pass, Channel
# Info refresh) and a test that stubs only the one it cares about would let
# the other two fall through to whatever real yt-dlp happens to be
# installed -- which on a developer's own machine is a real one, pointed at
# YouTube. Handling all three in one place keeps that impossible.
# ---------------------------------------------------------------------
$script:PostprocessStub = {
    if ($StubArgs -contains '--version') { Write-Output '2026.08.20'; return }
    if ($StubArgs -contains '-U')        { Write-Output 'yt-dlp is up to date'; return }

    # Channel Info refresh
    if ($StubArgs -contains '--write-all-thumbnails') {
        $oi = [Array]::IndexOf($StubArgs, '-o')
        $dir = Split-Path $StubArgs[$oi + 1] -Parent
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'channel.info.json') -Value '{"channel":"Test Channel"}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $dir 'channel.description') -Value 'Channel description.' -Encoding utf8
        Write-Output '[youtube:tab] Extracting channel metadata'
        return
    }

    # Comments pass
    if ($StubArgs -contains '--write-comments') {
        $oi = [Array]::IndexOf($StubArgs, '-o')
        $dir = Split-Path $StubArgs[$oi + 1] -Parent
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $requests = 5
        if ($env:YTDLP_TEST_COMMENT_REQUESTS) { $requests = [int]$env:YTDLP_TEST_COMMENT_REQUESTS }
        for ($i = 1; $i -le $requests; $i++) {
            Write-Output "[youtube] testVideo01: Downloading comment API JSON (page $i)"
        }
        if ($env:YTDLP_TEST_COMMENT_THROTTLE -eq '1') {
            Write-Output 'WARNING: [youtube] Incomplete data received, retrying (1/3)'
        }
        if ($env:YTDLP_TEST_COMMENT_EMPTY -eq '1') {
            Set-Content -LiteralPath (Join-Path $dir 'comments.info.json') -Value '{"id":"testVideo01"}' -Encoding utf8
            return
        }
        $payload = [ordered]@{
            id            = 'testVideo01'
            comment_count = 3
            comments      = @(
                [ordered]@{ id = 'c1';    text = 'top level one'; parent = 'root'; is_pinned = $true;  author_is_uploader = $false }
                [ordered]@{ id = 'c2';    text = 'top level two'; parent = 'root'; is_pinned = $false; author_is_uploader = $false }
                [ordered]@{ id = 'c2.r1'; text = 'a reply';       parent = 'c2';   is_pinned = $false; author_is_uploader = $true  }
            )
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dir 'comments.info.json') -Encoding utf8
        return
    }

    Write-Output "[stub] unhandled yt-dlp invocation: $($StubArgs -join ' ')"
}

function New-PostprocessRoot {
    <# An install root, a stubbed yt-dlp, and a session log ready to slice. #>
    param([string]$Label, [hashtable]$VideoArgs = @{})
    $r = New-TestRoot -Label $Label
    Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
    Enable-Stubs -TestRoot $r
    New-StubBinary -TestRoot $r -Name 'yt-dlp' -Behavior $script:PostprocessStub | Out-Null
    $video = New-VideoFolder -TestRoot $r @VideoArgs
    New-SessionLog -TestRoot $r | Out-Null
    $r | Add-Member -NotePropertyName Video -NotePropertyValue $video -Force
    return $r
}

Describe 'postprocess.ps1 gating and file movement' {

    It 'skips everything for a --keep-video pre-merge stream' {
        # The hook fires once per moved file, and --keep-video means it also
        # fires for the video-only and audio-only streams. Before the gate,
        # each of those redid the whole 30-60 minute comments fetch,
        # overwrote manifest.json with that stream's info, and copied the
        # fragment into the Final Video repository over the real video --
        # whichever invocation finished last won.
        $r = New-PostprocessRoot -Label 'pp-gate' -VideoArgs @{ WithPreMergeStreams = $true; PreMergeUnrelocated = $true; SeedChannelInfoThrottle = $true }
        try {
            $stream = Join-Path $r.Video.FinalFiles 'Final Video.f248.webm'
            $result = Invoke-Postprocess -TestRoot $r -FilePath $stream
            Assert-Match 'Skipped: not the final merged \.mkv' $result.Output

            Assert-PathMissing (Join-Path $r.Video.MetaDir 'manifest.json') `
                'a pre-merge stream must not write a manifest'
            Assert-PathMissing (Join-Path $r.Video.MetaDir 'checksums.sha256')
            Assert-PathMissing (Join-Path $r.Video.VideosRoot 'Final Video/Test Channel') `
                'a pre-merge stream must never reach the Final Video repository'
            Assert-Equal 0 @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                             Where-Object { $_.args -contains '--write-comments' }).Count `
                'the expensive comments fetch must not run for a pre-merge stream'
        } finally { Remove-TestRoot $r }
    }

    It 'moves pre-merge streams out of Final files and leaves only the real video' {
        $r = New-PostprocessRoot -Label 'pp-premerge' -VideoArgs @{ WithPreMergeStreams = $true; PreMergeUnrelocated = $true; SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath

            $preMergeDir = Join-Path $r.Video.VideoDir 'Pre-merge streams'
            Assert-PathExists $preMergeDir 'Pre-merge streams/ must be a SIBLING of Final files, not nested inside it'
            Assert-PathExists (Join-Path $preMergeDir 'Final Video.f248.webm')
            Assert-PathExists (Join-Path $preMergeDir 'Final Video.f251.webm')

            $left = @(Get-ChildItem -LiteralPath $r.Video.FinalFiles -File | ForEach-Object { $_.Name })
            Assert-True ($left -contains 'Final Video.mkv') 'the merged video must stay in Final files'
            foreach ($name in $left) {
                Assert-NotMatch '^Final Video\.f' $name `
                    "Final files should hold only the final output, but still contains $name"
            }
        } finally { Remove-TestRoot $r }
    }

    It 'writes video_complete.log covering only the most recent session' {
        $r = New-PostprocessRoot -Label 'pp-log' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $complete = Join-Path $r.Video.VideoDir 'Logs/video_complete.log'
            Assert-PathExists $complete
            Assert-FileMatches $complete 'Download session started 2025-01-01_120000'
            $body = Get-Content -LiteralPath $complete -Raw
            Assert-NotMatch 'PREVIOUS session' $body `
                'the slice must start at the LAST session marker, not the first'
        } finally { Remove-TestRoot $r }
    }

    It 'recovers metadata from the folder name when the info.json is missing' {
        $r = New-PostprocessRoot -Label 'pp-noinfo' -VideoArgs @{ OmitInfoJson = $true; SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'No \.info\.json found' $result.Output
            Assert-Match 'Post-processing complete' $result.Output `
                'a missing info.json must degrade gracefully, not abort the whole pipeline'

            $manifest = Get-Content -LiteralPath (Join-Path $r.Video.MetaDir 'manifest.json') -Raw | ConvertFrom-Json
            Assert-Equal 'testVideo01'  $manifest.video_id   'the id must be parsed out of the folder name'
            Assert-Equal 'A Test Video' $manifest.title
            Assert-Equal '20250101'     $manifest.upload_date
            Assert-PathExists (Join-Path $r.Video.VideosRoot 'Final Video/Test Channel') `
                'the Final Video sync must still happen without an info.json'
        } finally { Remove-TestRoot $r }
    }
}

Describe 'postprocess.ps1 comments pass' {

    It 'passes the arguments the comments pass is supposed to pace itself with' {
        $r = New-PostprocessRoot -Label 'pp-comments-args' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $call = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                      Where-Object { $_.args -contains '--write-comments' }) | Select-Object -First 1
            Assert-True ($null -ne $call) 'the comments pass never ran'

            Assert-Match '--skip-download' $call.line 'the comments pass must not re-download the video'
            Assert-Match '--ignore-config' $call.line `
                'without this the conf file''s --sleep-requests 2 would govern the comments pass too'
            Assert-Match '--sleep-requests 0\.25' $call.line
            Assert-Match '--extractor-retries 100' $call.line
        } finally { Remove-TestRoot $r }
    }

    It 'merges the fetched comments into the sidecar info.json' {
        $r = New-PostprocessRoot -Label 'pp-comments-merge' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'Merged 3 comments into the sidecar info\.json' $result.Output

            $info = Get-Content -LiteralPath $r.Video.InfoPath -Raw | ConvertFrom-Json
            Assert-Equal 3 @($info.comments).Count
            Assert-Equal 3 $info.comment_count
            Assert-Equal 'top level one' $info.comments[0].text
            # The flags yt-dlp gets by scraping and the Data API does not
            # expose at all -- the reason the API was rejected as a
            # replacement fetcher. If a merge ever drops them, the archive
            # loses data that cannot be recovered later.
            Assert-Equal $true $info.comments[0].is_pinned
            Assert-Equal $true $info.comments[2].author_is_uploader
            # And the merge must not destroy what was already there.
            Assert-Equal 'testVideo01' $info.id
            Assert-Equal 'A Test Video' $info.title
        } finally { Remove-TestRoot $r }
    }

    It 'counts each comment API request exactly once' {
        # Log() ends in Write-Output, so inside the pass's
        # ForEach-Object { Log "..."; $_ } BOTH the timestamped copy and the
        # bare line land in $commentsOutput -- every yt-dlp line is in there
        # twice. The '\[comments\]' anchor in the three filters is what
        # picks exactly one copy per real line. Without it the request count
        # doubles and seconds-per-request comes out at half its true value,
        # which is the number you are supposed to steer --sleep-requests by.
        $env:YTDLP_TEST_COMMENT_REQUESTS = '7'
        $r = New-PostprocessRoot -Label 'pp-comments-count' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'Comments pass: 7 API request\(s\)' $result.Output @'
The comment API request count is wrong. If it reads 14, the '\[comments\]'
anchor has been removed from the $commentRequests filter in postprocess.ps1:
every yt-dlp line appears twice in $commentsOutput and an unanchored match
counts both copies.
'@
            Assert-Match 's/request, --sleep-requests 0\.25' $result.Output `
                'the pass should record its pacing alongside the request count'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_REQUESTS = $null }
    }

    It 'reports retry and throttle signals separately from ordinary warnings' {
        $env:YTDLP_TEST_COMMENT_THROTTLE = '1'
        $r = New-PostprocessRoot -Label 'pp-comments-throttle' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match '1 retry/throttle signal\(s\)' $result.Output `
                'incomplete-data and retry lines are the actual signature of YouTube pushing back, and are counted on their own'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_THROTTLE = $null }
    }

    It 'says so when the pass returns no comments rather than writing an empty list' {
        $env:YTDLP_TEST_COMMENT_EMPTY = '1'
        $r = New-PostprocessRoot -Label 'pp-comments-empty' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'returned no comments -- nothing to merge' $result.Output
            $info = Get-Content -LiteralPath $r.Video.InfoPath -Raw | ConvertFrom-Json
            Assert-Match 'testVideo01' $info.id 'the sidecar must be left intact when there is nothing to merge'
        } finally { Remove-TestRoot $r; $env:YTDLP_TEST_COMMENT_EMPTY = $null }
    }

    It 'skips the comments pass entirely when the info.json has no URL' {
        # The documented way to exercise the rest of the pipeline without a
        # reachable YouTube: with no original_url there is nothing to fetch,
        # so the pass short-circuits instead of burning --extractor-retries
        # 100 against an unreachable host.
        $r = New-PostprocessRoot -Label 'pp-comments-nourl' -VideoArgs @{ OmitUrls = $true; SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'skipped the comments pass entirely' $result.Output
            Assert-Equal 0 @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                             Where-Object { $_.args -contains '--write-comments' }).Count
            Assert-Match 'Post-processing complete' $result.Output
        } finally { Remove-TestRoot $r }
    }
}

Describe 'postprocess.ps1 outputs' {

    It 'writes urls.json with every derived URL form' {
        $r = New-PostprocessRoot -Label 'pp-urls' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $urls = Get-Content -LiteralPath (Join-Path $r.Video.VideoDir 'URLs/urls.json') -Raw | ConvertFrom-Json
            Assert-Equal 'https://www.youtube.com/watch?v=testVideo01' $urls.original_url
            Assert-Equal 'https://youtu.be/testVideo01'                $urls.short_url
            Assert-Equal 'https://www.youtube.com/embed/testVideo01'   $urls.embed_url
            Assert-Equal 'https://www.youtube.com/@testchannel'        $urls.channel_url
        } finally { Remove-TestRoot $r }
    }

    It 'generates Thumbnail.png locally from the file already on disk' {
        if (-not (Test-HasCommand 'ffmpeg')) { Skip-Test 'ffmpeg is not on PATH.' }
        $r = New-PostprocessRoot -Label 'pp-thumb' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $png = Join-Path $r.Video.ImagesDir 'Thumbnail.png'
            Assert-PathExists $png
            Assert-True ((Get-Item -LiteralPath $png).Length -gt 0) 'the PNG must not be empty'
            Assert-Match 'no network re-fetch involved' $result.Output
            # The original must survive: both copies are meant to be
            # derivatives of the same bytes captured at extraction time.
            Assert-PathExists (Join-Path $r.Video.ImagesDir 'Thumbnail.jpg')
        } finally { Remove-TestRoot $r }
    }

    It 'writes a checksums.sha256 in which every line actually verifies' {
        # The bug this replaces: video_postprocessing.log was hashed while
        # this script was still writing to it, so every video ever produced
        # had exactly one entry that could never verify. A checksum manifest
        # that always reports a failure teaches you to ignore its failures,
        # which is the one thing an integrity file must never do.
        $r = New-PostprocessRoot -Label 'pp-checksums' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $checksums = Join-Path $r.Video.MetaDir 'checksums.sha256'
            Assert-PathExists $checksums

            $lines = @(Get-Content -LiteralPath $checksums | Where-Object { $_.Trim() })
            Assert-True ($lines.Count -ge 5) "expected a line per archived file, got $($lines.Count)"

            $failures = @()
            foreach ($line in $lines) {
                $m = [regex]::Match($line, '^(?<hash>[0-9a-fA-F]{64})\s\s(?<rel>.+)$')
                Assert-True $m.Success "not in sha256sum format (two spaces between hash and path): $line"
                $rel  = $m.Groups['rel'].Value
                Assert-NotMatch '\\' $rel `
                    'checksum paths must use "/" on every platform, or a manifest written on Windows is not comparable with one written on Linux'
                $full = Join-Path $r.Video.VideoDir $rel
                if (-not (Test-Path -LiteralPath $full)) { $failures += "MISSING  $rel"; continue }
                $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
                if ($actual -ne $m.Groups['hash'].Value.ToUpperInvariant()) { $failures += "MISMATCH $rel" }
            }
            if ($failures.Count -gt 0) {
                throw "checksums.sha256 does not verify:`n  " + ($failures -join "`n  ")
            }

            Assert-NotMatch 'video_postprocessing\.log' (Get-Content -LiteralPath $checksums -Raw) @'
Logs/video_postprocessing.log is back in checksums.sha256. It is this
script's OWN live log -- hashing it captures its contents as of that
moment, and the six Log calls that follow then append to it, so the
recorded hash is stale before the script exits.
'@
            # video_complete.log is written once, in full, and never
            # appended to again -- so it SHOULD be covered.
            Assert-Match 'video_complete\.log' (Get-Content -LiteralPath $checksums -Raw) `
                'video_complete.log has a stable hash and should still be covered'
        } finally { Remove-TestRoot $r }
    }

    It 'writes manifest.json with the metadata a future reader needs' {
        $r = New-PostprocessRoot -Label 'pp-manifest' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $manifest = Get-Content -LiteralPath (Join-Path $r.Video.MetaDir 'manifest.json') -Raw | ConvertFrom-Json

            Assert-Equal 'testVideo01'  $manifest.video_id
            Assert-Equal 'A Test Video' $manifest.title
            Assert-Equal 'Test Channel' $manifest.uploader `
                'the uploader comes from the CHANNEL FOLDER name, not from info.json'
            Assert-Equal '20250101'     $manifest.upload_date
            Assert-Equal '24'           "$($manifest.config_file_version)" `
                'the config version must be read from the INSTALLED configs/yt-dlp.conf'
            Assert-True ($null -ne $manifest.operating_system) 'the OS should be recorded'

            $formatIds = @($manifest.codecs | ForEach-Object { $_.format_id })
            Assert-True ($formatIds -contains '248') 'codecs should come from requested_formats'
            Assert-True ($formatIds -contains '251')
            Assert-True (@($manifest.subtitle_languages) -contains 'en')

            $files = @($manifest.every_filename)
            Assert-True ($files -contains 'Final files/Final Video.mkv')
            foreach ($f in $files) {
                Assert-NotMatch '\\' $f 'manifest paths must use "/" on every platform'
            }
        } finally { Remove-TestRoot $r }
    }

    It 'embeds the comment-complete info.json back into the .mkv' {
        if (-not (Test-HasCommand 'ffmpeg') -or -not (Test-HasCommand 'ffprobe')) {
            Skip-Test 'ffmpeg/ffprobe are not on PATH.'
        }
        $r = New-PostprocessRoot -Label 'pp-reembed' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            if (-not $r.Video.HasRealMkv) { Skip-Test 'Could not build a real .mkv fixture with ffmpeg.' }
            $before = (Get-Item -LiteralPath $r.Video.MkvPath).Length
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'Re-embedded comment-complete info\.json' $result.Output

            Assert-PathExists $r.Video.MkvPath 'the video must still be there after the swap'
            Assert-True ((Get-Item -LiteralPath $r.Video.MkvPath).Length -gt $before) `
                'attaching the info.json should make the file bigger, not replace it with something smaller'

            $mime = & ffprobe -v error -select_streams t -show_entries stream_tags=mimetype -of csv=p=0 $r.Video.MkvPath 2>&1
            Assert-Match 'application/json' $mime 'the attachment must be tagged as JSON'

            # No temp file may survive. A leftover _remux_temp_*.mkv in
            # Final files would also be picked up as "the video" by the
            # viewer's discovery.
            $temps = @(Get-ChildItem -LiteralPath $r.Video.FinalFiles -Filter '_remux_temp_*' -ErrorAction SilentlyContinue)
            Assert-Equal 0 $temps.Count 'the remux temp file must be swapped in or removed, never left behind'
        } finally { Remove-TestRoot $r }
    }

    It 'adds the video to the global and channel manifests without duplicating on re-run' {
        $r = New-PostprocessRoot -Label 'pp-manifests' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath

            $global = @(Get-Content -LiteralPath (Join-Path $r.Video.VideosRoot 'global_manifest.json') -Raw | ConvertFrom-Json)
            Assert-Equal 1 @($global | Where-Object { $_.video_id -eq 'testVideo01' }).Count `
                're-processing the same video must REPLACE its entry, not append a second one'

            $channel = @(Get-Content -LiteralPath (Join-Path $r.Video.ChannelDir 'channel_manifest.json') -Raw | ConvertFrom-Json)
            Assert-Equal 1 @($channel | Where-Object { $_.video_id -eq 'testVideo01' }).Count
            Assert-Equal 'A Test Video' $channel[0].title
        } finally { Remove-TestRoot $r }
    }

    It 'syncs the Final Video repository with a descriptive filename' {
        $r = New-PostprocessRoot -Label 'pp-finalvideo' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            $repo = Join-Path $r.Video.VideosRoot 'Final Video/Test Channel'
            Assert-PathExists $repo
            # Named from the already-sanitized FOLDER name rather than
            # rebuilt from raw info.json fields, so yt-dlp's own filename
            # sanitization is reused instead of re-implemented.
            Assert-PathExists (Join-Path $repo ($r.Video.FolderName + '.mkv'))
            Assert-PathExists (Join-Path $repo 'channel_manifest.json')
            Assert-PathExists (Join-Path $repo 'Channel Info')
            Assert-PathExists (Join-Path $r.Video.VideosRoot 'Final Video/global_manifest.json')
        } finally { Remove-TestRoot $r }
    }

    It 'honours the six-hour Channel Info refresh throttle' {
        # The other half of the hidden-file bug. $ErrorActionPreference is
        # "Stop" in this script, so Get-Item without -Force threw on the
        # dot-prefixed marker and the throw escaped to the catch -- meaning
        # that from the moment .last_refresh first existed, the refresh was
        # never throttled AND never ran. Channel avatars, banners and
        # descriptions silently stopped updating after the first video in
        # each channel, and every later video logged "refresh failed".
        $r = New-PostprocessRoot -Label 'pp-throttle' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'Channel Info refreshed within the last 6 hours -- skipped' $result.Output
            Assert-NotMatch 'Channel Info refresh failed' $result.Output @'
The Channel Info refresh threw instead of being throttled. .last_refresh is
dot-prefixed, so PowerShell treats it as hidden and Get-Item WITHOUT -Force
throws "Could not find item" on a path Test-Path just confirmed exists.
'@
            Assert-Equal 0 @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                             Where-Object { $_.args -contains '--write-all-thumbnails' }).Count `
                'a throttled refresh must make no network call at all'
        } finally { Remove-TestRoot $r }
    }

    It 'refreshes Channel Info when the throttle marker is stale' {
        $r = New-PostprocessRoot -Label 'pp-refresh' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $marker = Join-Path $r.Video.ChannelDir 'Channel Info/.last_refresh'
            (Get-Item -LiteralPath $marker -Force).LastWriteTime = (Get-Date).AddHours(-7)

            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            Assert-Match 'Refreshed Channel Info for Test Channel' $result.Output
            Assert-Equal 1 @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                             Where-Object { $_.args -contains '--write-all-thumbnails' }).Count

            $call = @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' | Where-Object { $_.args -contains '--write-all-thumbnails' })[0]
            Assert-Match '--playlist-items 0' $call.line `
                'the channel pass must fetch channel metadata only, never the videos'
            Assert-PathExists (Join-Path $r.Video.ChannelDir 'Channel Info/channel.info.json')
            # And the marker must be rewritten, or the next video refreshes again.
            $age = (Get-Date) - (Get-Item -LiteralPath $marker -Force).LastWriteTime
            Assert-True ($age.TotalHours -lt 1) 'the throttle marker must be rewritten after a successful refresh'
        } finally { Remove-TestRoot $r }
    }

    It 'sweeps the empty folders yt-dlp leaves under _incomplete' {
        $r = New-PostprocessRoot -Label 'pp-sweep' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $incomplete = Join-Path $r.Video.VideosRoot '_incomplete'
            $emptyNest  = Join-Path $incomplete 'Test Channel/Test Channel - 20250101 - testVideo01 - A Test Video/Final files'
            $keepDir    = Join-Path $incomplete 'Other Channel/still downloading'
            New-Item -ItemType Directory -Path $emptyNest -Force | Out-Null
            New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $keepDir 'partial.mkv.part') -Value 'in progress' -Encoding utf8

            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath

            Assert-PathMissing $emptyNest 'empty leftovers under _incomplete should be swept'
            Assert-PathMissing (Join-Path $incomplete 'Test Channel') `
                'the sweep must loop until nothing more is removable, so parents of removed folders go too'
            Assert-PathExists (Join-Path $keepDir 'partial.mkv.part') `
                'a folder with a partial download in it must NOT be swept'
            Assert-PathExists $incomplete '_incomplete itself must survive -- yt-dlp writes into it every run'
        } finally { Remove-TestRoot $r }
    }

    It 'derives the data root from the file it is handed, not from the install root' {
        # postprocess.ps1 never receives -DataRoot. It walks up from
        # $FilePath, which is what makes `ytdl <url> /some/other/path` work
        # without threading a value through yt-dlp's --exec string.
        $r = New-PostprocessRoot -Label 'pp-dataroot' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath
            # Everything must land under the fixture DATA root...
            Assert-PathExists (Join-Path $r.DataRoot 'Youtube Videos/global_manifest.json')
            Assert-PathExists (Join-Path $r.DataRoot 'Youtube Videos/Final Video/Test Channel')
            # ...and nothing under the fixture INSTALL root except what the
            # installer put there.
            Assert-PathMissing (Join-Path $r.InstallRoot 'Youtube Videos') `
                'the data root must come from the file path, not from $installRoot'
        } finally { Remove-TestRoot $r }
    }
}
