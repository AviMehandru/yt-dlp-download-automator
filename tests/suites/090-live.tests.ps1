<#
    The opt-in live suite: one real video, downloaded from YouTube by the
    real yt-dlp, merged by the real ffmpeg, post-processed by the real
    postprocess.ps1, into a throwaway data root.

    Skipped unless -Live is passed. Everything else in this suite runs with
    yt-dlp stubbed, which is what makes the other 80-odd tests fast and
    offline -- but a stub can only ever prove the pipeline does what the
    stub was written to expect. This is the test that proves the pipeline
    works against the real thing: real signed format URLs, a real merge, a
    real Matroska container to attach to, real filename sanitization, real
    subtitles.

    THE COMMENTS CAP. postprocess.ps1's comments pass is the longest step in
    the pipeline by a wide margin -- it costs roughly one HTTP request per
    comment THREAD, so a popular video is hours. A test that takes hours is
    a test nobody runs. So unless -LiveFullComments is given, a pass-through
    shim sits in front of the real yt-dlp and adds
    --extractor-args "youtube:max_comments=N,all,all,0" to the comments pass
    only. Everything else reaches the real yt-dlp untouched, including every
    argument the pipeline built. The cap is the one thing this suite
    deliberately does not test at full scale, and -LiveFullComments removes
    it when you do want that.
#>

Describe 'Live end-to-end download' {

    if (-not $script:IncludeLive) {
        It 'archives one real video end to end' {
            Skip-Test 'Pass -Live to run this (it downloads a real video and needs network).'
        }
        return
    }

    It 'archives one real video end to end' {
        foreach ($tool in @('yt-dlp', 'ffmpeg', 'ffprobe')) {
            if (-not (Test-HasCommand $tool)) { Skip-Test "$tool is not installed, so a real download cannot be tested." }
        }

        # Resolved BEFORE the stub directory goes on PATH, so the shim
        # below invokes the genuine binary and not itself.
        $realYtDlp = (Get-Command yt-dlp).Source
        $r = New-TestRoot -Label 'live'
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot

        $maxComments = if ($script:LiveMaxComments) { $script:LiveMaxComments } else { 100 }
        if (-not $script:LiveFullComments) {
            Enable-Stubs -TestRoot $r
            $env:YTDLP_TEST_REAL_YTDLP = $realYtDlp
            $env:YTDLP_TEST_MAX_COMMENTS = "$maxComments"
            # A PASS-THROUGH shim, not a stub: every invocation reaches the
            # real yt-dlp with the arguments the pipeline built. The only
            # change is one extra --extractor-args on the comments pass.
            # max_replies_per_thread = 0 is applied as islice(gen, 0), so
            # the generator is never advanced and the per-thread request is
            # never made -- while replies YouTube inlines in subThreads
            # still come through free.
            New-StubBinary -TestRoot $r -Name 'yt-dlp' -Behavior {
                $passthrough = @($StubArgs)
                if ($passthrough -contains '--write-comments') {
                    $cap = $env:YTDLP_TEST_MAX_COMMENTS
                    $passthrough += @('--extractor-args', "youtube:max_comments=$cap,all,all,0")
                }
                & $env:YTDLP_TEST_REAL_YTDLP @passthrough
                exit $LASTEXITCODE
            } | Out-Null
        }

        Write-Host ''
        Write-Host "  live: archiving $($script:LiveUrl)" -ForegroundColor Yellow
        Write-Host "  live: data root  $($r.DataRoot)" -ForegroundColor Yellow
        if (-not $script:LiveFullComments) {
            Write-Host "  live: comments capped at $maxComments (pass -LiveFullComments for the real thing)" -ForegroundColor Yellow
        }

        $run = Invoke-RunYtdlp -TestRoot $r -Url $script:LiveUrl

        # --- the download itself ---
        $archiveDir = Join-Path $r.DataRoot 'Youtube Videos/Complete Archive'
        Assert-PathExists $archiveDir
        $videoDirs = @(Get-ChildItem -LiteralPath $archiveDir -Directory |
                       ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } |
                       Where-Object { $_.Name -ne 'Channel Info' })
        if ($videoDirs.Count -eq 0) {
            throw "Nothing was archived. yt-dlp output:`n$(($run.Output | Select-Object -Last 40) -join "`n")"
        }
        Assert-Equal 1 $videoDirs.Count 'exactly one video should have been archived'
        $videoDir = $videoDirs[0].FullName

        # The folder name is what postprocess.ps1 falls back to parsing and
        # what the Final Video copy is named from, so its shape matters as
        # much as its existence.
        Assert-Match '^.+ - \d{8} - [\w-]{6,} - .+$' $videoDirs[0].Name `
            'the per-video folder must keep the "<uploader> - <date> - <id> - <title>" shape'

        $mkv = Join-Path $videoDir 'Final files/Final Video.mkv'
        Assert-PathExists $mkv 'the merged .mkv must land in Final files/'
        Assert-True ((Get-Item -LiteralPath $mkv).Length -gt 10000) 'the merged video looks implausibly small'

        # Final files must hold ONLY the finished output -- the pre-merge
        # streams --keep-video leaves behind belong in their own folder.
        foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $videoDir 'Final files') -File)) {
            Assert-NotMatch '^Final Video\.f' $f.Name `
                "a --keep-video pre-merge stream was left in Final files: $($f.Name)"
        }

        # --- metadata ---
        $infoFile = @(Get-ChildItem -LiteralPath (Join-Path $videoDir 'Video metadata') -Filter '*.info.json')[0]
        Assert-True ($null -ne $infoFile) 'the sidecar info.json must be written'
        $info = Get-Content -LiteralPath $infoFile.FullName -Raw | ConvertFrom-Json
        Assert-True (-not [string]::IsNullOrWhiteSpace($info.id)) 'the info.json must carry a video id'

        $manifest = Get-Content -LiteralPath (Join-Path $videoDir 'Video metadata/manifest.json') -Raw | ConvertFrom-Json
        Assert-Equal $info.id $manifest.video_id 'the manifest must describe the video that was actually downloaded'
        Assert-True (-not [string]::IsNullOrWhiteSpace($manifest.yt_dlp_version)) 'the yt-dlp version must be recorded'
        Assert-True (-not [string]::IsNullOrWhiteSpace($manifest.ffmpeg_version)) 'the ffmpeg version must be recorded'
        Assert-True (-not [string]::IsNullOrWhiteSpace("$($manifest.config_file_version)")) `
            'a blank config version means --config-location pointed somewhere wrong'

        $urls = Get-Content -LiteralPath (Join-Path $videoDir 'URLs/urls.json') -Raw | ConvertFrom-Json
        Assert-Equal "https://youtu.be/$($info.id)" $urls.short_url

        # --- comments actually came back ---
        if (@($info.comments).Count -eq 0) {
            Write-Host '  live: no comments were returned (the video may have them disabled)' -ForegroundColor DarkYellow
        } else {
            Assert-True (@($info.comments).Count -gt 0)
            Assert-Match 'Comments pass:' $run.Output 'the comments pass should report its own request count'
        }

        # --- the integrity file must verify, in full ---
        $checksums = Join-Path $videoDir 'Video metadata/checksums.sha256'
        Assert-PathExists $checksums
        $failures = @()
        foreach ($line in (Get-Content -LiteralPath $checksums | Where-Object { $_.Trim() })) {
            $m = [regex]::Match($line, '^(?<hash>[0-9a-fA-F]{64})\s\s(?<rel>.+)$')
            if (-not $m.Success) { $failures += "MALFORMED $line"; continue }
            $full = Join-Path $videoDir $m.Groups['rel'].Value
            if (-not (Test-Path -LiteralPath $full)) { $failures += "MISSING  $($m.Groups['rel'].Value)"; continue }
            if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $m.Groups['hash'].Value.ToUpperInvariant()) {
                $failures += "MISMATCH $($m.Groups['rel'].Value)"
            }
        }
        if ($failures.Count -gt 0) {
            throw "checksums.sha256 does not verify against a real archive:`n  " + ($failures -join "`n  ")
        }

        # --- the info.json really is inside the container ---
        $mime = & ffprobe -v error -select_streams t -show_entries stream_tags=mimetype -of csv=p=0 $mkv 2>&1
        Assert-Match 'application/json' $mime `
            'the comment-complete info.json must be attached to the .mkv, tagged application/json'

        # --- session-level outputs ---
        $archiveTxt = Join-Path $r.DataRoot 'Archive Logs/Logs/archive.txt'
        Assert-FileMatches $archiveTxt ([regex]::Escape($info.id)) `
            'the video must be recorded in the download archive, or it will be re-downloaded next run'
        $globalManifest = Get-Content -LiteralPath (Join-Path $r.DataRoot 'Youtube Videos/global_manifest.json') -Raw | ConvertFrom-Json
        Assert-True (@($globalManifest | Where-Object { $_.video_id -eq $info.id }).Count -eq 1)

        $finalVideoDir = Join-Path $r.DataRoot 'Youtube Videos/Final Video'
        $copies = @(Get-ChildItem -LiteralPath $finalVideoDir -Recurse -Filter '*.mkv')
        Assert-Equal 1 $copies.Count 'exactly one copy should reach the Final Video repository'
        Assert-Equal ($videoDirs[0].Name + '.mkv') $copies[0].Name

        Assert-Match '-- Session summary: 1 video\(s\) touched' $run.Output
        Assert-PathExists (Join-Path $videoDir 'Logs/video_complete.log')

        # Deliberately NOT cleaned up: a real archive is the most useful
        # thing to look at when something about this run was surprising, and
        # it is a few megabytes in the temp directory that the OS will
        # reclaim on its own.
        Write-Host "  live: archive left at $($r.DataRoot) for inspection" -ForegroundColor Yellow
        $script:TestRoots.Remove($r.Root) | Out-Null
    }

    It 'skips a video it has already archived' {
        foreach ($tool in @('yt-dlp', 'ffmpeg')) {
            if (-not (Test-HasCommand $tool)) { Skip-Test "$tool is not installed." }
        }
        # The --download-archive contract, which is what makes a periodic
        # re-run against a channel cheap. Tested with a pre-seeded
        # archive.txt rather than by downloading twice, so this costs one
        # extraction rather than two downloads.
        $r = New-TestRoot -Label 'live-skip'
        try {
            Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
            $logsDir = Join-Path $r.DataRoot 'Archive Logs/Logs'
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

            $id = & yt-dlp --ignore-config --skip-download --print '%(id)s' $script:LiveUrl 2>$null | Select-Object -First 1
            Assert-True (-not [string]::IsNullOrWhiteSpace($id)) 'could not resolve the live URL to a video id'
            Set-Content -LiteralPath (Join-Path $logsDir 'archive.txt') -Value "youtube $id" -Encoding utf8

            $run = Invoke-RunYtdlp -TestRoot $r -Url $script:LiveUrl
            Assert-Match 'has already been recorded in the archive' $run.Output
            Assert-Match '1 already archived \(skipped\)' $run.Output
            $archived = @(Get-ChildItem -LiteralPath (Join-Path $r.DataRoot 'Youtube Videos/Complete Archive') -Directory -ErrorAction SilentlyContinue)
            Assert-Equal 0 $archived.Count 'nothing should have been downloaded'
        } finally { Remove-TestRoot $r }
    }
}
