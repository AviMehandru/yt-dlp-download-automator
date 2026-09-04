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

function New-PostprocessRoot {
    <# An install root, a stubbed yt-dlp, and a session log ready to slice. #>
    param([string]$Label, [hashtable]$VideoArgs = @{})
    $r = New-TestRoot -Label $Label
    Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
    Enable-Stubs -TestRoot $r
    # The canonical three-call stub lives in lib/Fixtures.ps1 so every suite
    # that runs postprocess.ps1 gets the same one -- see New-YtDlpStub for
    # why stubbing only the call a test cares about is not safe.
    New-YtDlpStub -TestRoot $r | Out-Null
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
        #
        # Under archive layout 2 the gate tests the file's ROLE (its base
        # name) rather than its extension, because the final file is no
        # longer always .mkv: --container selects it, and audio-only writes
        # "Final Audio.<ext>". A pre-merge stream is still excluded by the
        # same property it always had -- yt-dlp's format-id sits as an
        # extra dotted segment before the extension, so anything with a
        # second dot after the base name is a raw stream, whatever the
        # extension happens to be.
        $r = New-PostprocessRoot -Label 'pp-gate' -VideoArgs @{ WithPreMergeStreams = $true; PreMergeUnrelocated = $true; SeedChannelInfoThrottle = $true }
        try {
            $stream = Join-Path $r.Video.FinalFiles 'Final Video.f248.webm'
            $result = Invoke-Postprocess -TestRoot $r -FilePath $stream
            Assert-Match "is not this run's final media file" $result.Output

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

    # --- Archive layout 2: the media file is no longer always .mkv --------

    It 'accepts Final Audio as the final file in audio-only mode' {
        $r = New-PostprocessRoot -Label 'pp-audio-gate' -VideoArgs @{
            MediaBaseName = 'Final Audio'; MediaExt = '.m4a'; SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MediaPath -Mode 'audio-only'
            Assert-NotMatch 'is not this run.s final media file' $result.Output `
                'audio-only must treat Final Audio.<ext> as the file to process'
            Assert-PathExists (Join-Path $r.Video.MetaDir 'manifest.json') `
                'an audio-only run must still produce a full per-video folder'
        } finally { Remove-TestRoot $r }
    }

    It 'gates on the role of the file, not on its extension' {
        # A .mkv is not automatically the file to process, and a non-.mkv is
        # not automatically a stream to skip. Under --container mp4 the
        # final file is "Final Video.mp4", and in audio-only mode a stray
        # "Final Video.mkv" is not this run's output at all.
        $r = New-PostprocessRoot -Label 'pp-role-gate' -VideoArgs @{
            MediaBaseName = 'Final Video'; MediaExt = '.mp4'; SeedChannelInfoThrottle = $true }
        try {
            $accepted = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MediaPath
            Assert-NotMatch 'is not this run.s final media file' $accepted.Output `
                'a non-.mkv container is still the final file when its base name says so'

            # Same folder, but asked for as an audio-only run: the video
            # file is now the wrong role and must be skipped outright.
            $rejected = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MediaPath -Mode 'audio-only'
            Assert-Match 'is not this run.s final media file' $rejected.Output
        } finally { Remove-TestRoot $r }
    }

    It 'runs off the info.json when the mode downloads no media' {
        # --skip-download means the after_move hook never fires for a media
        # file, so the info.json is the trigger instead. It is written in
        # every no-media mode precisely so this hook has something to fire
        # on, and exactly once per video, which is what makes it safe as a
        # single trigger.
        $r = New-PostprocessRoot -Label 'pp-nomedia' -VideoArgs @{
            OmitVideoFile = $true; SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.InfoPath -Mode 'metadata-only'
            Assert-Match 'no media file expected' $result.Output

            Assert-PathExists (Join-Path $r.Video.MetaDir 'manifest.json') `
                'a no-media run must still write the full per-video folder'
            Assert-PathExists (Join-Path $r.Video.MetaDir 'checksums.sha256')

            # The path derivation is the subtle half: the trigger sits in
            # "Video metadata/" rather than "Final files/", and both are
            # exactly two levels below the per-video folder. A derivation
            # that took the trigger's parent as "Final files" would point
            # every later operation at the metadata folder instead.
            $manifest = Get-Content (Join-Path $r.Video.MetaDir 'manifest.json') -Raw | ConvertFrom-Json
            Assert-Equal 'metadata-only' $manifest.download_mode
            Assert-Equal $r.Video.VideoId $manifest.video_id `
                'the video folder must still be resolved correctly from a metadata trigger'
        } finally { Remove-TestRoot $r }
    }

    It 'starts exactly one pass in a no-media mode, whatever else was moved' {
        # --skip-download still moves the description and the subtitles, so
        # after_move fires for those too. Only the info.json may start a
        # pass, or a subs-only run would redo the whole folder once per
        # subtitle language.
        $r = New-PostprocessRoot -Label 'pp-nomedia-once' -VideoArgs @{
            OmitVideoFile = $true; SeedChannelInfoThrottle = $true }
        try {
            $sub = Join-Path $r.Video.SubsDir 'Subtitles.en.vtt'
            $result = Invoke-Postprocess -TestRoot $r -FilePath $sub -Mode 'subs-only'
            Assert-Match 'keyed off Info\.info\.json' $result.Output
            Assert-PathMissing (Join-Path $r.Video.MetaDir 'manifest.json') `
                'only the info.json may trigger the pass in a no-media mode'
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

    It 'skips the comments pass entirely under --no-comments' {
        # The comments pass is normally the longest stage of a download, so
        # its absence has to be recorded rather than inferred from timing.
        $r = New-PostprocessRoot -Label 'pp-nocomments' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath -NoComments
            Assert-Match 'Comments pass skipped' $result.Output

            Assert-Equal 0 @(Get-StubCalls -TestRoot $r -Name 'yt-dlp' |
                             Where-Object { $_.args -contains '--write-comments' }).Count `
                'the comments fetch must not run at all'

            # 'skipped_by_request' is what distinguishes "we did not fetch"
            # from "we fetched and found none" -- without it a --no-comments
            # run and a video with comments disabled look identical in the
            # manifest, and only one of the two is worth re-running.
            $manifest = Get-Content (Join-Path $r.Video.MetaDir 'manifest.json') -Raw | ConvertFrom-Json
            Assert-Equal 'skipped_by_request' $manifest.comment_audit.api_status
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
            # Read out of the config rather than written here as a literal.
            # This was a hardcoded '24' and had been failing since the config
            # moved to 25 -- the same stale-literal bug the installer suite
            # carried, and the same fix: assert the RELATIONSHIP (the manifest
            # records whatever the installed config says) rather than today's
            # value of it.
            $installedConf = Join-Path $r.InstallRoot 'configs/yt-dlp.conf'
            $expectedConfigVersion = [regex]::Match(
                (Get-Content -LiteralPath $installedConf -Raw),
                '(?m)^#\s*CONFIG_VERSION:\s*(\d+)').Groups[1].Value
            Assert-True ($expectedConfigVersion -ne '') `
                'could not read CONFIG_VERSION out of the installed yt-dlp.conf'
            Assert-Equal $expectedConfigVersion "$($manifest.config_file_version)" `
                'the config version must be read from the INSTALLED configs/yt-dlp.conf'
            Assert-True ($null -ne $manifest.operating_system) 'the OS should be recorded'

            # The layout contract (docs/archive-layout.md). Consumers outside
            # this repo key off this number to decide whether they can read
            # the archive at all, so it must be present and must agree with
            # the constant postprocess.ps1 declares.
            $declaredLayout = [regex]::Match(
                (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/postprocess.ps1') -Raw),
                '(?m)^\$ArchiveLayoutVersion\s*=\s*(\d+)').Groups[1].Value
            Assert-True ($declaredLayout -ne '') `
                'postprocess.ps1 must declare $ArchiveLayoutVersion'
            Assert-Equal $declaredLayout "$($manifest.archive_layout_version)" `
                'manifest.json must record the archive layout version consumers check'

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

    It 'records the archive layout version, the mode, and the media file' {
        # config_file_version alone stopped being a sufficient record of
        # what produced a video the moment a run could override the conf.
        $r = New-PostprocessRoot -Label 'pp-manifest-v2' -VideoArgs @{ SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.MkvPath -Mode 'full' `
                -RunSettings @{ mode = 'full'; quality = '1080'; codec = 'avc1' }
            $manifest = Get-Content (Join-Path $r.Video.MetaDir 'manifest.json') -Raw | ConvertFrom-Json

            $constant = [int]((Select-String -Path (Join-Path $r.InstallRoot 'scripts/postprocess.ps1') `
                        -Pattern '^\$ArchiveLayoutVersion\s*=\s*(\d+)').Matches[0].Groups[1].Value)
            Assert-Equal $constant $manifest.archive_layout_version `
                'the manifest must record the layout version the script actually declares'
            Assert-Equal 2 $constant 'the --mode work is archive layout 2'

            Assert-Equal 'full' $manifest.download_mode
            Assert-Equal 'Final files/Final Video.mkv' $manifest.media_file `
                'media_file spares every consumer from globbing for the media file'
            Assert-Equal '1080' $manifest.run_settings.quality `
                'the per-run overrides must be recorded alongside config_file_version'
        } finally { Remove-TestRoot $r }
    }

    It 'records a null media_file rather than omitting it when there is no media' {
        # A consumer must be able to tell "this mode downloaded no media"
        # from "this field is missing because the writer is older".
        $r = New-PostprocessRoot -Label 'pp-manifest-nomedia' -VideoArgs @{
            OmitVideoFile = $true; SeedChannelInfoThrottle = $true }
        try {
            $null = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.InfoPath -Mode 'comments-only'
            $manifest = Get-Content (Join-Path $r.Video.MetaDir 'manifest.json') -Raw | ConvertFrom-Json
            Assert-True ($manifest.PSObject.Properties.Name -contains 'media_file') `
                'the field must be present even when there is no media'
            Assert-True ($null -eq $manifest.media_file)
            Assert-Equal 'comments-only' $manifest.download_mode
        } finally { Remove-TestRoot $r }
    }

    It 'keeps a media-less run out of the Final Video repository' {
        # "Point a media player at this folder" is the entire contract of
        # that tree, and a zero-byte or placeholder entry would break it
        # more thoroughly than a missing one.
        $r = New-PostprocessRoot -Label 'pp-nomedia-sync' -VideoArgs @{
            OmitVideoFile = $true; SeedChannelInfoThrottle = $true }
        try {
            $result = Invoke-Postprocess -TestRoot $r -FilePath $r.Video.InfoPath -Mode 'metadata-only'
            Assert-Match 'no media file to sync' $result.Output
            $repoDir = Join-Path $r.Video.VideosRoot "Final Video/$($r.Video.Uploader)"
            if (Test-Path $repoDir) {
                $media = @(Get-ChildItem -Path $repoDir -File |
                           Where-Object { $_.Extension -notin @('.json') })
                Assert-Equal 0 $media.Count 'no media file may appear in the Final Video repository'
            }
        } finally { Remove-TestRoot $r }
    }

}
