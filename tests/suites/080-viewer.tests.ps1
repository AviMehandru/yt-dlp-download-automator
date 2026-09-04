<#
    scripts/archive-viewer.py -- started for real against a fabricated
    archive and driven over HTTP.

    Started as a real server rather than imported and unit-tested because
    the three invariants worth protecting are all properties of the running
    thing, not of any one function:

      * THE ARCHIVE IS READ-ONLY. Not fastidiousness: postprocess.ps1 writes
        a checksums.sha256 covering every file in a video folder, so a
        derived file dropped in there makes that manifest stop verifying --
        and a checksum file that reports a failure every time is one you
        learn to ignore. The test takes a full before/after inventory of the
        archive, browses everything the UI would touch, and diffs it.

      * THE CLIENT NEVER SENDS A FILESYSTEM PATH. Traversal is off the table
        because there is no route that accepts a path at all, rather than
        because a filter has to be right. That is a property you can test
        directly: throw paths at it and check that nothing outside the
        archive comes back.

      * PRE-MERGE STREAMS ARE NOT THE VIDEO. --keep-video leaves video-only
        and audio-only files behind, and picking one of those as "the video"
        is exactly the confusion the Pre-merge streams/ folder exists to end.
#>

Describe 'archive-viewer.py' {

    $python = @('python3', 'python') | Where-Object { Test-HasCommand $_ } | Select-Object -First 1

    function Start-Viewer {
        <#
            Starts the viewer on a free port and waits for /api/status. All
            derived state is forced into a cache directory OUTSIDE the
            archive, which is also the thing the read-only test then
            verifies actually happened.
        #>
        param($TestRoot, [string[]]$ExtraArgs = @())

        # A port picked by asking the OS for a free one, then released --
        # a fixed port would collide with whatever the developer already
        # has running, and with a second copy of this suite.
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()

        $cacheDir = Join-Path $TestRoot.Root 'viewer-cache'
        $viewer   = Join-Path $TestRoot.InstallRoot 'scripts/archive-viewer.py'
        $stdout   = Join-Path $TestRoot.Root 'viewer-stdout.log'
        $stderr   = Join-Path $TestRoot.Root 'viewer-stderr.log'

        $argList = @($viewer, '--root', $TestRoot.DataRoot, '--port', "$port",
                     '--host', '127.0.0.1', '--cache-dir', $cacheDir, '--no-browser') + $ExtraArgs
        $proc = Start-Process -FilePath $script:ViewerPython -ArgumentList $argList `
                              -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
                              -PassThru -NoNewWindow

        $base = "http://127.0.0.1:$port"
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) {
                throw "the viewer exited immediately (code $($proc.ExitCode)):`n$(Get-Content -LiteralPath $stderr -Raw)"
            }
            try {
                $null = Invoke-WebRequest -Uri "$base/api/status" -UseBasicParsing -TimeoutSec 3
                break
            } catch { Start-Sleep -Milliseconds 250 }
        }

        return [pscustomobject]@{
            Process = $proc; Base = $base; Port = $port
            CacheDir = $cacheDir; Stdout = $stdout; Stderr = $stderr
        }
    }

    function Stop-Viewer {
        param($Viewer)
        if ($Viewer -and $Viewer.Process -and -not $Viewer.Process.HasExited) {
            $Viewer.Process.Kill()
            $null = $Viewer.Process.WaitForExit(10000)
        }
    }

    function Get-Json {
        param($Viewer, [string]$Path)
        $response = Invoke-WebRequest -Uri ($Viewer.Base + $Path) -UseBasicParsing -TimeoutSec 20
        return ($response.Content | ConvertFrom-Json)
    }

    function Wait-ForScan {
        param($Viewer, [int]$Expected = 1)
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            $status = Get-Json -Viewer $Viewer -Path '/api/status'
            if (-not $status.scanning -and $status.count -ge $Expected) { return $status }
            Start-Sleep -Milliseconds 300
        }
        throw "the viewer never finished indexing $Expected video(s)"
    }

    function Get-ArchiveInventory {
        <# Path + size + last-write for everything under the archive. #>
        param([string]$Path)
        $inventory = [ordered]@{}
        foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $inventory[$f.FullName] = "$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
        }
        return $inventory
    }

    function New-ViewerRoot {
        param([string]$Label)
        $r = New-TestRoot -Label $Label
        Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
        $v1 = New-VideoFolder -TestRoot $r -Uploader 'Test Channel' -VideoId 'testVideo01' `
                              -Title 'A Test Video' -WithPreMergeStreams -PostProcessed -SeedChannelInfoThrottle
        $v2 = New-VideoFolder -TestRoot $r -Uploader 'Other Channel' -VideoId 'otherVid02' `
                              -Title 'Another Video' -UploadDate '20240615' -PostProcessed
        $r | Add-Member -NotePropertyName V1 -NotePropertyValue $v1 -Force
        $r | Add-Member -NotePropertyName V2 -NotePropertyValue $v2 -Force
        return $r
    }

    if (-not $python) {
        It 'runs the viewer suite' { Skip-Test 'No python3/python on PATH; the viewer is an optional component.' }
        return
    }
    $script:ViewerPython = (Get-Command $python).Source

    It 'serves the page, its assets and a status endpoint' {
        $r = New-ViewerRoot -Label 'viewer-serve'
        $v = $null
        try {
            $v = Start-Viewer -TestRoot $r
            foreach ($route in @('/', '/index.html', '/app.css', '/app.js', '/favicon.ico')) {
                $resp = Invoke-WebRequest -Uri ($v.Base + $route) -UseBasicParsing -TimeoutSec 15
                Assert-Equal 200 $resp.StatusCode "$route should be served"
            }
            $status = Wait-ForScan -Viewer $v -Expected 2
            Assert-Equal 2 $status.count 'both fabricated videos should be indexed'
            Assert-Equal 2 $status.channels 'each uploader folder is its own channel'
            # The cache must resolve outside the archive even when --root
            # points at a custom data root -- the whole read-only invariant
            # rests on this one path decision.
            Assert-NotMatch ([regex]::Escape((Join-Path $r.DataRoot 'Youtube Videos'))) "$($status.cache)" `
                'the cache directory must never resolve inside the archive'
            $unknown = 0
            try { $null = Invoke-WebRequest -Uri "$($v.Base)/no/such/route" -UseBasicParsing -TimeoutSec 10 }
            catch { if ($_.Exception.Response) { $unknown = [int]$_.Exception.Response.StatusCode } }
            Assert-Equal 404 $unknown 'an unknown route should 404 rather than 500'
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'never writes anything into the archive' {
        $r = New-ViewerRoot -Label 'viewer-readonly'
        $v = $null
        try {
            $archivePath = Join-Path $r.DataRoot 'Youtube Videos'
            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 2 | Out-Null

            $before = Get-ArchiveInventory -Path $archivePath

            # Everything the UI touches for one video: metadata, comments,
            # transcript, the raw thumbnail, a text file, and the playback
            # plan (which is what may produce a remux).
            $library = Get-Json -Viewer $v -Path '/api/library'
            foreach ($video in $library.videos) {
                $null = Get-Json -Viewer $v -Path "/api/video/$($video.key)"
                $null = Get-Json -Viewer $v -Path "/api/comments/$($video.key)"
                $null = Get-Json -Viewer $v -Path "/api/transcript/$($video.key)"
                if ($video.has_thumb) {
                    $null = Invoke-WebRequest -Uri "$($v.Base)/media/$($video.key)/file?idx=$($video.thumb_idx)" `
                                              -UseBasicParsing -TimeoutSec 20
                }
            }
            $null = Get-Json -Viewer $v -Path '/api/rescan?force=1'
            Start-Sleep -Seconds 2
            Wait-ForScan -Viewer $v -Expected 2 | Out-Null

            $after = Get-ArchiveInventory -Path $archivePath
            $added    = @($after.Keys  | Where-Object { -not $before.Contains($_) })
            $removed  = @($before.Keys | Where-Object { -not $after.Contains($_) })
            $modified = @($before.Keys | Where-Object { $after.Contains($_) -and $after[$_] -ne $before[$_] })

            if ($added.Count -or $removed.Count -or $modified.Count) {
                throw @"
The viewer modified the archive. It must never create, move or change
anything under 'Youtube Videos/' -- checksums.sha256 covers every file in a
video folder, so a derived file dropped there makes that manifest stop
verifying, and an integrity file that always reports a failure is one you
learn to ignore.
  added:    $($added -join ', ')
  removed:  $($removed -join ', ')
  modified: $($modified -join ', ')
"@
            }

            # ...and the derived state must have gone somewhere: a cache dir
            # that stayed empty would pass the diff above for the wrong
            # reason.
            Assert-PathExists $v.CacheDir 'derived state must be written OUTSIDE the archive, not simply not written'
            $cached = @(Get-ChildItem -LiteralPath $v.CacheDir -Recurse -File)
            Assert-True ($cached.Count -gt 0) 'the cache directory should hold the index and split-out comments'
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'reads the metadata the pipeline wrote' {
        $r = New-ViewerRoot -Label 'viewer-meta'
        $v = $null
        try {
            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 2 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            $entry = $library.videos | Where-Object { $_.id -eq 'testVideo01' } | Select-Object -First 1
            Assert-True ($null -ne $entry) 'testVideo01 should appear in the library'
            Assert-Equal 'A Test Video' $entry.title
            Assert-Equal 'Test Channel' $entry.channel_folder
            Assert-True $entry.has_video
            Assert-True ($entry.sub_count -ge 1) 'the fabricated subtitle should be found'

            $detail = Get-Json -Viewer $v -Path "/api/video/$($entry.key)"
            Assert-Equal 'Final Video.mkv' $detail.video_name `
                'the merged video must be chosen, never a --keep-video pre-merge stream'
            Assert-True ($null -ne $detail.urls) 'urls.json should be surfaced'
            Assert-Equal 'https://youtu.be/testVideo01' $detail.urls.short_url

            $transcript = Get-Json -Viewer $v -Path "/api/transcript/$($entry.key)"
            Assert-True (@($transcript.cues).Count -ge 1) 'the .vtt should parse into at least one cue'
            Assert-Match 'Hello from the test fixture' ($transcript.cues[0].text)
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'falls back to the folder name when a video has no info.json' {
        $r = New-TestRoot -Label 'viewer-fallback'
        $v = $null
        try {
            Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
            $null = New-VideoFolder -TestRoot $r -Uploader 'Bare Channel' -VideoId 'bareVideo1' `
                                    -Title 'No Metadata Here' -UploadDate '20230704' -OmitInfoJson
            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 1 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            $entry = $library.videos[0]
            Assert-Equal 'bareVideo1' $entry.id `
                'the id must be recovered from the "<uploader> - <date> - <id> - <title>" folder name'
            Assert-Equal 'No Metadata Here' $entry.title
            Assert-Equal '20230704' $entry.upload_date
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'tolerates a video folder with no video file in it' {
        $r = New-TestRoot -Label 'viewer-novideo'
        $v = $null
        try {
            Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
            $null = New-VideoFolder -TestRoot $r -Uploader 'Empty Channel' -VideoId 'noVideo001' `
                                    -Title 'Metadata Only' -OmitVideoFile
            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 1 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            Assert-False $library.videos[0].has_video
            $detail = Get-Json -Viewer $v -Path "/api/video/$($library.videos[0].key)"
            Assert-Equal 'none' $detail.playback.mode `
                'a folder with no video must report "no video" rather than erroring'
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'exposes no route that accepts a filesystem path' {
        # The design claim, tested directly: content is addressed by an
        # opaque key plus an index into a server-side file list, so there is
        # nothing to traverse. Every probe below should come back 404 or
        # 403 -- never 200, and never the contents of a file outside the
        # archive.
        $r = New-ViewerRoot -Label 'viewer-traversal'
        $v = $null
        try {
            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 2 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            $key = $library.videos[0].key

            $probes = @(
                '/media/../../../../etc/passwd',
                '/media/file?path=/etc/passwd',
                "/media/$key/file?idx=../../../../etc/passwd",
                "/media/$key/file?path=/etc/passwd",
                "/api/file-text/$key`?idx=../../../../../etc/hosts",
                "/api/video/$key/../../../etc/passwd",
                '/etc/passwd',
                '/../../../../etc/passwd',
                '/api/../../etc/passwd'
            )
            foreach ($probe in $probes) {
                $status = 0
                $body = ''
                try {
                    $resp = Invoke-WebRequest -Uri ($v.Base + $probe) -UseBasicParsing -TimeoutSec 15
                    $status = [int]$resp.StatusCode
                    $body = "$($resp.Content)"
                } catch {
                    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { $status = -1 }
                }
                Assert-NotMatch 'root:x:0:0' $body "$probe returned the contents of /etc/passwd"
                if ($status -eq 200 -and $body -notmatch '<!doctype|<html|"error"') {
                    throw "$probe returned 200 with a non-page body -- a route that resolves a client-supplied path has been added. Content addressing must stay: opaque key + index into a server-side list."
                }
            }
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'refuses to launch a local player unless explicitly enabled' {
        $r = New-ViewerRoot -Label 'viewer-openlocal'
        $v = $null
        try {
            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 2 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            $status = 0
            try {
                $null = Invoke-WebRequest -Uri "$($v.Base)/api/open/$($library.videos[0].key)" -UseBasicParsing -TimeoutSec 15
                $status = 200
            } catch {
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            }
            Assert-Equal 403 $status `
                'launching a local player must be opt-in via --allow-open-local, even from localhost'
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'splits comments out of the info.json and serves them threaded' {
        $r = New-TestRoot -Label 'viewer-comments'
        $v = $null
        try {
            Install-PipelineInto -TestRoot $r -RepoRoot $script:RepoRoot
            $video = New-VideoFolder -TestRoot $r -Uploader 'Chatty Channel' -VideoId 'chatVideo1' -Title 'Has Comments'
            # A post-comments-merge info.json: what postprocess.ps1 leaves
            # behind once its comments pass has run.
            $info = Get-Content -LiteralPath $video.InfoPath -Raw | ConvertFrom-Json
            $info | Add-Member -NotePropertyName comment_count -NotePropertyValue 3 -Force
            $info | Add-Member -NotePropertyName comments -NotePropertyValue @(
                [pscustomobject]@{ id = 'c1';    parent = 'root'; text = 'first comment';  author = 'Alice'; is_pinned = $true;  author_is_uploader = $false; like_count = 12 },
                [pscustomobject]@{ id = 'c2';    parent = 'root'; text = 'second comment'; author = 'Bob';   is_pinned = $false; author_is_uploader = $false; like_count = 3 },
                [pscustomobject]@{ id = 'c2.r1'; parent = 'c2';   text = 'a reply';        author = 'Cara';  is_pinned = $false; author_is_uploader = $true }
            ) -Force
            $info | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $video.InfoPath -Encoding utf8

            $v = Start-Viewer -TestRoot $r
            Wait-ForScan -Viewer $v -Expected 1 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            $key = $library.videos[0].key

            $comments = Get-Json -Viewer $v -Path "/api/comments/$key"
            Assert-Equal 3 $comments.count
            $pinned = @($comments.comments | Where-Object { $_.is_pinned })
            Assert-Equal 1 $pinned.Count 'the pinned flag must survive into the viewer -- the Data API has no such field at all'
            $reply = @($comments.comments | Where-Object { $_.parent -eq 'c2' })
            Assert-Equal 1 $reply.Count 'replies must keep their parent id so the thread can be rebuilt'
            Assert-Equal $true $reply[0].author_is_uploader

            # The comments must be split into their own cache file, so a
            # huge info.json is read once rather than on every page view.
            $commentCaches = @(Get-ChildItem -LiteralPath $v.CacheDir -Recurse -Filter 'comments.json')
            Assert-True ($commentCaches.Count -ge 1) 'comments should be split out into the cache'
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'picks a transcode encoder this ffmpeg build actually has' {
        # libx264 is an EXTERNAL library, not part of ffmpeg itself, and
        # distributions with patent concerns leave it out -- Fedora's stock
        # ffmpeg-free is exactly that build. A hardcoded encoder meant the
        # transcode button failed there with "Unknown encoder 'libx264'".
        # The viewer now reads `ffmpeg -encoders` and picks the first profile
        # it can actually run, so this asserts the choice is real ON THIS
        # MACHINE rather than assuming any particular build.
        if (-not (Test-HasCommand 'ffmpeg')) { Skip-Test 'ffmpeg is not on PATH.' }
        $r = New-ViewerRoot -Label 'viewer-encoder'
        $v = $null
        try {
            $v = Start-Viewer -TestRoot $r
            $status = Wait-ForScan -Viewer $v -Expected 2
            Assert-True ($null -ne $status.transcode_profile) `
                'ffmpeg is installed, so some transcode profile should have resolved'

            # The profile names carry their encoder in brackets; whichever was
            # chosen must appear in this build's encoder list.
            $encoders = (& ffmpeg -hide_banner -encoders 2>&1) -join "`n"
            $encoder = [regex]::Match("$($status.transcode_profile)", '\(([^)]+)\)').Groups[1].Value
            if (-not $encoder) {
                # A WebM profile names its codecs rather than a library.
                $encoder = if ("$($status.transcode_profile)" -match 'VP9') { 'libvpx-vp9' } else { 'libvpx' }
            }
            Assert-Match ([regex]::Escape($encoder)) $encoders @"
The viewer chose the transcode profile '$($status.transcode_profile)', but
'$encoder' is not in this ffmpeg build's encoder list. A re-encode would fail
with "Unknown encoder". The profile list in archive-viewer.py must only ever
resolve to something `ffmpeg -encoders` reports.
"@
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'reports no profile, rather than a broken one, when nothing can encode' {
        # The Fedora case taken to its limit: an ffmpeg that can encode
        # nothing this viewer knows how to drive. It must say so up front so
        # the UI can decline, instead of offering a button that fails on
        # click.
        $r = New-ViewerRoot -Label 'viewer-noencoder'
        $v = $null
        try {
            # A stand-in ffmpeg whose -encoders listing is empty.
            $fake = Join-Path $r.Root 'ffmpeg-no-encoders'
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($fake, "#!/bin/sh`nexit 0`n", $utf8NoBom)
            if ($IsWindows) { Skip-Test 'Needs a POSIX shell for the stand-in ffmpeg.' }
            & chmod +x $fake

            $v = Start-Viewer -TestRoot $r -ExtraArgs @('--ffmpeg', $fake)
            $status = Wait-ForScan -Viewer $v -Expected 2
            Assert-True ($null -eq $status.transcode_profile) `
                'an ffmpeg that lists no encoders must resolve to no profile at all'
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }

    It 'never offers a re-encode when started with --no-transcode' {
        $r = New-ViewerRoot -Label 'viewer-notranscode'
        $v = $null
        try {
            $v = Start-Viewer -TestRoot $r -ExtraArgs @('--no-transcode')
            Wait-ForScan -Viewer $v -Expected 2 | Out-Null
            $library = Get-Json -Viewer $v -Path '/api/library'
            foreach ($video in $library.videos) {
                $detail = Get-Json -Viewer $v -Path "/api/video/$($video.key)"
                Assert-NotEqual 'transcode' $detail.playback.mode `
                    '--no-transcode must remove the re-encode option entirely, not just hide it'
            }
        } finally { Stop-Viewer $v; Remove-TestRoot $r }
    }
}
