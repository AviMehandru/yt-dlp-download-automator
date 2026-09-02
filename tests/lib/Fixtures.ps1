<#
.SYNOPSIS
    Fixture builders: isolated roots, stub external binaries, and fabricated
    archive trees for the yt-dlp archival pipeline test suite.

.DESCRIPTION
    Three problems this file solves, in order of how much they matter.

    1. NOTHING MAY TOUCH THE REAL ARCHIVE. Every fixture lives under a fresh
       directory in the system temp path, and New-TestRoot refuses outright
       to hand back a path that sits inside the caller's install root or
       home-directory archive. A test suite that can damage the thing it is
       testing is worse than no test suite.

    2. YOUTUBE IS NOT A TEST DEPENDENCY. yt-dlp is replaced by a stub whose
       behavior each test defines for itself, so the pipeline's own logic --
       path derivation, the .mkv gate, locking, manifest merging, the
       comments-pass argument construction -- is exercised with no network
       and in milliseconds instead of hours. The stub also RECORDS every
       invocation, which is what makes "was --ignore-config actually passed"
       and "was --sleep-requests really 0.25" assertable facts rather than
       things you confirm by reading the source and hoping.

       This technique is not new here: CLAUDE.md already documents
       fabricating a video folder and omitting original_url so the comments
       pass short-circuits. The stub generalizes that -- the comments pass
       can now be RUN rather than skipped, and what it sent can be checked.

    3. STUBS MUST WORK ON ALL THREE PLATFORMS. A native command lookup finds
       an extensionless executable on Linux and macOS and a .cmd on Windows,
       so the stub ships as both, and both are two-line shims that delegate
       to one shared PowerShell body -- exactly the pattern the repo already
       uses for `ytdl` / `ytdl.cmd` / `ytdl.ps1`, for the same reason: one
       behavior, no second place to make a mistake.

    ffmpeg and ffprobe are deliberately NOT stubbed. They are real
    dependencies that are genuinely installed on every machine this pipeline
    runs on, they are fast, and stubbing them would hide exactly the kind of
    container-level failure (a remux that produces a zero-byte file) the
    pipeline has guards for. Where a test needs them and they are absent, it
    skips.
#>

Set-StrictMode -Version Latest

$script:TestRoots = [System.Collections.Generic.List[string]]::new()

# ---------------------------------------------------------------------
# Isolated roots
# ---------------------------------------------------------------------

function New-TestRoot {
    <#
        Creates <temp>/ytdlp-tests/<label>-<random>/ containing:
          install/            -> YTDLP_INSTALL_ROOT for this test (scripts/, configs/)
          data/               -> the -DataRoot for this test
          stubs/              -> prepended to PATH
        and returns an object with those paths plus a Dispose-style cleanup.
    #>
    param([string]$Label = 'test')

    $base = Join-Path ([System.IO.Path]::GetTempPath()) 'ytdlp-tests'
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '-')
    $root = Join-Path $base ("{0}-{1}" -f $safeLabel, [guid]::NewGuid().ToString('N').Substring(0, 8))

    # Guard rail, not a formality. If $TMPDIR is ever pointed somewhere odd
    # (a mounted archive volume, the install root itself), the cleanup below
    # would recursively delete real data. Refuse instead.
    $full = [System.IO.Path]::GetFullPath($root)
    foreach ($forbidden in @(
        (Join-Path $HOME 'yt-dlp'),
        'C:\yt-dlp',
        $env:YTDLP_INSTALL_ROOT
    )) {
        if ([string]::IsNullOrWhiteSpace($forbidden)) { continue }
        $forbiddenFull = try { [System.IO.Path]::GetFullPath($forbidden) } catch { continue }
        if ($full.StartsWith($forbiddenFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to build fixtures inside a real pipeline root: $full is under $forbiddenFull. Check TMPDIR/TEMP."
        }
    }

    $paths = [ordered]@{
        Root        = $full
        InstallRoot = Join-Path $full 'install'
        DataRoot    = Join-Path $full 'data'
        StubDir     = Join-Path $full 'stubs'
        CallLog     = Join-Path $full 'stub-calls.jsonl'
    }
    foreach ($p in @($paths.Root, $paths.InstallRoot, $paths.DataRoot, $paths.StubDir)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $paths.InstallRoot 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $paths.InstallRoot 'configs') -Force | Out-Null

    $script:TestRoots.Add($full) | Out-Null
    return [pscustomobject]$paths
}

function Remove-TestRoot {
    param([Parameter(Position = 0)]$TestRoot)
    if (-not $TestRoot) { return }
    $path = if ($TestRoot -is [string]) { $TestRoot } else { $TestRoot.Root }
    if ($path -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-AllTestRoots {
    foreach ($r in $script:TestRoots) { Remove-TestRoot $r }
    $script:TestRoots.Clear()
}

function Install-PipelineInto {
    <#
        Copies the repo's pipeline sources into a test install root, using
        the SAME repo-source -> runtime-location mapping the real installer
        uses (note configs/ plural on the installed side; that asymmetry is
        documented in CLAUDE.md and is load-bearing).
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    $map = @{
        'scripts/run_ytdlp.ps1'     = 'scripts/run_ytdlp.ps1'
        'scripts/postprocess.ps1'   = 'scripts/postprocess.ps1'
        'scripts/ytdl.ps1'          = 'scripts/ytdl.ps1'
        'scripts/archive-viewer.py' = 'scripts/archive-viewer.py'
        'config/yt-dlp.conf'        = 'configs/yt-dlp.conf'
    }
    foreach ($src in $map.Keys) {
        $from = Join-Path $RepoRoot $src
        $to   = Join-Path $TestRoot.InstallRoot $map[$src]
        if (-not (Test-Path -LiteralPath $from)) { throw "Repo source missing: $from" }
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
}

# ---------------------------------------------------------------------
# Stub external binaries
# ---------------------------------------------------------------------

function New-StubBinary {
    <#
        Creates a fake external command on PATH.

        -Name       the command name the pipeline calls (e.g. "yt-dlp")
        -Behavior   a scriptblock run when the stub is invoked. Inside it,
                    $StubArgs is the argument array the pipeline passed and
                    $StubName is the command name. Whatever the block
                    outputs becomes the stub's stdout; `exit N` sets the
                    exit code.

        Every invocation is appended to the call log as one JSON line
        regardless of behavior, so a test can assert on arguments even for a
        stub that does nothing.
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [scriptblock]$Behavior = $null
    )

    $stubDir  = $TestRoot.StubDir
    $bodyPath = Join-Path $stubDir "$Name.behavior.ps1"
    $runner   = Join-Path $stubDir '_stub-runner.ps1'
    $pwsh     = Get-PwshPath

    if ($Behavior) {
        Set-Content -LiteralPath $bodyPath -Value $Behavior.ToString() -Encoding utf8
    } elseif (Test-Path -LiteralPath $bodyPath) {
        Remove-Item -LiteralPath $bodyPath -Force
    }

    # One shared runner for every stub: records the call, then dispatches to
    # the per-command behavior file if one exists.
    if (-not (Test-Path -LiteralPath $runner)) {
        $runnerBody = @'
# DELIBERATELY no param() block. `pwsh -File runner.ps1 yt-dlp --version`
# with a declared parameter makes the binder try to match "-version"
# against it and fail with "A parameter cannot be found that matches
# parameter name '-version'" -- so the stub would break on exactly the
# arguments it exists to record. With no parameters declared, every
# argument lands in $args verbatim, "-U" and "--version" included.
$all       = @($args)
$StubName  = $all[0]
$StubArgs  = @(if ($all.Count -gt 1) { $all[1..($all.Count - 1)] } else { @() })
$logPath = $env:YTDLP_TEST_CALLLOG
if ($logPath) {
    $record = [ordered]@{
        name = $StubName
        args = $StubArgs
        cwd  = (Get-Location).Path
        at   = (Get-Date).ToString('o')
    }
    # A retry loop, because the concurrency tests run several stubs at once
    # and two simultaneous appends to the same file collide. A lost record
    # would make a concurrency test fail with a count mismatch that looks
    # exactly like a real lost-update bug in the pipeline -- which is the
    # worst possible way for a harness to be flaky, so on giving up it
    # leaves a marker that Get-StubCalls turns into an unambiguous message
    # about the HARNESS rather than a misleading one about the pipeline.
    $written = $false
    for ($attempt = 0; $attempt -lt 200; $attempt++) {
        try {
            $line = ($record | ConvertTo-Json -Compress -Depth 6)
            # FileShare.None, NOT FileShare.Read. On Unix .NET implements
            # FileShare with flock, and anything short of None maps to a
            # SHARED lock -- so two concurrent stubs both acquired it, both
            # seeked to the same end-of-file offset (FileMode.Append does
            # not use O_APPEND), and one record silently overwrote the
            # other. No exception, no corrupt line, just a call log one
            # entry short, which surfaced as an intermittent "expected 3
            # downloads, found 2" in the -Workers tests roughly one run in
            # five. FileShare.None is the same primitive postprocess.ps1
            # uses for its own locks, for the same reason.
            $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`n")
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            $written = $true
            break
        } catch { Start-Sleep -Milliseconds (Get-Random -Minimum 10 -Maximum 60) }
    }
    if (-not $written) {
        try { Set-Content -LiteralPath ($logPath + '.lost') -Value "$StubName $($StubArgs -join ' ')" } catch { }
    }
}
$behavior = Join-Path $PSScriptRoot "$StubName.behavior.ps1"
if (Test-Path -LiteralPath $behavior) {
    . $behavior
}
exit 0
'@
        Set-Content -LiteralPath $runner -Value $runnerBody -Encoding utf8
    }

    # Both shim spellings are always written, not just the current
    # platform's. It costs two small files, and it means a fixture built on
    # one OS is not silently wrong if the harness is ever run under an
    # emulated or cross-mounted PATH.
    $unixShim = Join-Path $stubDir $Name
    $unixBody = "#!/bin/sh`nexec `"$pwsh`" -NoProfile -File `"$runner`" $Name `"`$@`"`n"
    # -NoNewline: a stray CRLF after the shebang line makes the kernel look
    # for an interpreter named "/bin/sh\r", which fails with the famously
    # unhelpful "no such file or directory" naming a file that plainly
    # exists. Written as UTF8 without BOM for the same reason.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($unixShim, $unixBody, $utf8NoBom)
    if (-not $IsWindows) { & chmod +x $unixShim }

    $cmdShim = Join-Path $stubDir "$Name.cmd"
    $cmdBody = "@echo off`r`n`"$pwsh`" -NoProfile -File `"$runner`" $Name %*`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($cmdShim, $cmdBody, $utf8NoBom)

    return $unixShim
}

function Enable-Stubs {
    <# Prepends the stub directory to PATH and points the call log at this root. #>
    param([Parameter(Mandatory = $true)]$TestRoot)
    $sep = [System.IO.Path]::PathSeparator
    $env:PATH = $TestRoot.StubDir + $sep + $env:PATH
    $env:YTDLP_TEST_CALLLOG = $TestRoot.CallLog
    if (-not (Test-Path -LiteralPath $TestRoot.CallLog)) {
        Set-Content -LiteralPath $TestRoot.CallLog -Value '' -NoNewline
    }
}

function Get-StubCalls {
    <#
        Returns the recorded invocations, newest last. -Name filters to one
        command. Each result has .name, .args (array), .cwd, .at, plus a
        .line convenience property holding the arguments joined with spaces,
        which is what most assertions actually want to regex against.
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [string]$Name = $null
    )
    if (Test-Path -LiteralPath ($TestRoot.CallLog + '.lost')) {
        throw "HARNESS PROBLEM, not a pipeline bug: a stub could not append to the call log and gave up, so at least one invocation was not recorded. Any count assertion in this test is meaningless. Lost: $(Get-Content -LiteralPath ($TestRoot.CallLog + '.lost') -Raw)"
    }
    if (-not (Test-Path -LiteralPath $TestRoot.CallLog)) { return @() }
    $calls = @()
    foreach ($line in (Get-Content -LiteralPath $TestRoot.CallLog)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($Name -and $obj.name -ne $Name) { continue }
        $obj | Add-Member -NotePropertyName line -NotePropertyValue (@($obj.args) -join ' ') -Force
        $calls += $obj
    }
    return @($calls)
}

function Clear-StubCalls {
    param([Parameter(Mandatory = $true)]$TestRoot)
    Set-Content -LiteralPath $TestRoot.CallLog -Value '' -NoNewline
}

# ---------------------------------------------------------------------
# Fabricated archive content
# ---------------------------------------------------------------------

function New-TinyMkv {
    <#
        A real, playable one-second Matroska file, built with the real
        ffmpeg. Real rather than a touched empty file because postprocess
        actually remuxes it: `ffmpeg -attach ... -map 0 -c copy` on a
        zero-byte "video" fails, and the whole point of that test is to
        prove the swap-on-success guard works on a file that genuinely
        remuxes.

        SEVERAL CODEC COMBINATIONS ARE TRIED, in descending order of
        realism. h264 + aac is what a real archive mostly holds, so it goes
        first -- but it needs libx264, which is an EXTERNAL library that
        distributions with patent concerns leave out. Fedora's stock
        `ffmpeg-free` is exactly that build, so on Fedora the single-codec
        version of this function produced nothing and every test that needs
        a genuinely remuxable file skipped, including the info.json
        re-embed. That skip was a property of the test fixture, not of the
        pipeline: nothing in postprocess.ps1 ever ENCODES video (the
        re-embed is `-map 0 -c copy`, and yt-dlp's own merge is a stream
        copy too), so ffmpeg-free runs the real pipeline perfectly well.

        The later candidates are all encoders built into ffmpeg itself with
        no external dependency, so at least one of them exists in any build
        worth calling ffmpeg.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-HasCommand 'ffmpeg')) { return $false }
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null

    $attempts = @(
        @{ V = @('-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p'); A = @('-c:a', 'aac') }
        @{ V = @('-c:v', 'mpeg4');                                                  A = @('-c:a', 'aac') }
        @{ V = @('-c:v', 'mpeg4');                                                  A = @('-c:a', 'pcm_s16le') }
        @{ V = @('-c:v', 'ffv1');                                                   A = @('-c:a', 'pcm_s16le') }
    )

    foreach ($attempt in $attempts) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        $null = & ffmpeg -y -loglevel error `
            -f lavfi -i "testsrc=size=32x32:rate=5:duration=1" `
            -f lavfi -i "anullsrc=r=8000:cl=mono" `
            -shortest -t 1 @($attempt.V) @($attempt.A) `
            $Path 2>&1
        if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 0)) {
            return $true
        }
    }
    return $false
}

function New-InfoJson {
    <#
        A sidecar info.json shaped like the real thing, with only the fields
        the pipeline and the viewer actually read. -OmitUrls drops
        original_url/webpage_url, which is the documented way to make the
        comments pass short-circuit instead of trying to reach YouTube.
    #>
    param(
        [string]$VideoId    = 'testVideo01',
        [string]$Title      = 'A Test Video',
        [string]$Uploader   = 'Test Channel',
        [string]$UploadDate = '20250101',
        [switch]$OmitUrls,
        [switch]$OmitChannelUrl,
        [hashtable]$Extra
    )
    $info = [ordered]@{
        id                  = $VideoId
        title               = $Title
        uploader            = $Uploader
        upload_date         = $UploadDate
        duration            = 1
        ext                 = 'mkv'
        format_id           = '248+251'
        vcodec              = 'vp9'
        acodec              = 'opus'
        playlist_id         = $null
        playlist_title      = $null
        requested_formats   = @(
            [ordered]@{ format_id = '248'; ext = 'webm'; vcodec = 'vp9';  acodec = 'none' },
            [ordered]@{ format_id = '251'; ext = 'webm'; vcodec = 'none'; acodec = 'opus' }
        )
        requested_subtitles = [ordered]@{ en = [ordered]@{ ext = 'vtt'; url = 'https://example.invalid/sub' } }
        thumbnail           = 'https://example.invalid/thumb.webp'
    }
    if (-not $OmitUrls) {
        $info['original_url'] = "https://www.youtube.com/watch?v=$VideoId"
        $info['webpage_url']  = "https://www.youtube.com/watch?v=$VideoId"
    }
    if (-not $OmitChannelUrl) {
        $info['channel_url']  = 'https://www.youtube.com/@testchannel'
        $info['uploader_url'] = 'https://www.youtube.com/@testchannel'
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $info[$k] = $Extra[$k] } }
    return $info
}

function New-VideoFolder {
    <#
        Fabricates one complete per-video folder in the exact layout
        yt-dlp.conf's -o templates produce:

          <DataRoot>/Youtube Videos/Complete Archive/<Uploader>/
              <Uploader> - <date> - <id> - <title>/
                  Final files/Final Video.mkv
                  Video metadata/Info.info.json
                  Images/Thumbnail.webp
                  Subtitles/Subtitles.en.vtt

        The directory DEPTH here is the thing under test as much as the
        contents: postprocess.ps1 derives the data root by walking up from
        the file it is handed, so a fixture one level off would make every
        path assertion below meaningless. Returns the paths it built.
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [string]$Uploader   = 'Test Channel',
        [string]$VideoId    = 'testVideo01',
        [string]$Title      = 'A Test Video',
        [string]$UploadDate = '20250101',
        [switch]$OmitInfoJson,
        [switch]$OmitUrls,
        [switch]$OmitChannelUrl,
        [switch]$OmitVideoFile,
        [switch]$WithPreMergeStreams,
        [switch]$PreMergeUnrelocated,
        [switch]$PostProcessed,
        [switch]$SeedChannelInfoThrottle,
        [hashtable]$InfoExtra
    )

    $videosRoot   = Join-Path $TestRoot.DataRoot 'Youtube Videos'
    $archiveDir   = Join-Path $videosRoot 'Complete Archive'
    $channelDir   = Join-Path $archiveDir $Uploader
    $folderName   = "$Uploader - $UploadDate - $VideoId - $Title"
    $videoDir     = Join-Path $channelDir $folderName
    $finalFiles   = Join-Path $videoDir 'Final files'
    $metaDir      = Join-Path $videoDir 'Video metadata'
    $imagesDir    = Join-Path $videoDir 'Images'
    $subsDir      = Join-Path $videoDir 'Subtitles'
    $urlsDir      = Join-Path $videoDir 'URLs'

    foreach ($d in @($finalFiles, $metaDir, $imagesDir, $subsDir,
                     (Join-Path $videosRoot '_incomplete'),
                     (Join-Path $videosRoot 'Final Video'),
                     (Join-Path $TestRoot.DataRoot 'Archive Logs/Logs'),
                     (Join-Path $TestRoot.DataRoot 'Archive Logs/Archive History'))) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    $mkvPath = Join-Path $finalFiles 'Final Video.mkv'
    $hasRealMkv = $false
    if (-not $OmitVideoFile) {
        $hasRealMkv = New-TinyMkv -Path $mkvPath
        if (-not $hasRealMkv) {
            # No ffmpeg on this machine: still create the file so the path
            # logic can be tested. Tests that need a genuinely remuxable
            # file check .HasRealMkv and skip.
            Set-Content -LiteralPath $mkvPath -Value 'not a real matroska file' -Encoding utf8
        }
        Set-Content -LiteralPath (Join-Path $finalFiles 'Link.url') `
                    -Value "[InternetShortcut]`nURL=https://youtu.be/$VideoId" -Encoding utf8
    }

    if ($WithPreMergeStreams) {
        # Named exactly as --keep-video leaves them: the same "Final Video"
        # base with yt-dlp's format-id suffix before the extension.
        #
        # -PreMergeUnrelocated puts them where yt-dlp itself drops them, in
        # "Final files/", which is the state postprocess.ps1 has not yet
        # cleaned up. Otherwise they go where postprocess.ps1 moves them,
        # which is what an archive at rest actually looks like -- and the
        # state the viewer reads. Both are real; which one a test wants
        # depends on whether it is testing the relocation or something
        # downstream of it.
        $preMergeTarget = if ($PreMergeUnrelocated) { $finalFiles } else { Join-Path $videoDir 'Pre-merge streams' }
        New-Item -ItemType Directory -Path $preMergeTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $preMergeTarget 'Final Video.f248.webm') -Value 'video-only stream' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $preMergeTarget 'Final Video.f251.webm') -Value 'audio-only stream' -Encoding utf8
    }

    $infoPath = Join-Path $metaDir 'Info.info.json'
    if (-not $OmitInfoJson) {
        $info = New-InfoJson -VideoId $VideoId -Title $Title -Uploader $Uploader -UploadDate $UploadDate `
                             -OmitUrls:$OmitUrls -OmitChannelUrl:$OmitChannelUrl -Extra $InfoExtra
        $info | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $infoPath -Encoding utf8
    }

    Set-Content -LiteralPath (Join-Path $metaDir 'Description.description') -Value 'A test description.' -Encoding utf8

    # A REAL image, not a placeholder, when ffmpeg is available: the
    # thumbnail step converts whatever non-.png file it finds here into
    # Thumbnail.png, and a text file masquerading as an image would make
    # that step fail for a reason the test is not about. .jpg rather than
    # .webp because every ffmpeg build can write it, while libwebp is
    # optional. The pipeline itself only cares that the extension is not
    # .png, which is what makes .jpg a faithful stand-in.
    $rawThumb = Join-Path $imagesDir 'Thumbnail.jpg'
    if (Test-HasCommand 'ffmpeg') {
        $null = & ffmpeg -y -loglevel error -f lavfi -i "testsrc=size=64x36:rate=1:duration=1" -frames:v 1 $rawThumb 2>&1
    }
    if (-not (Test-Path -LiteralPath $rawThumb)) {
        Set-Content -LiteralPath $rawThumb -Value 'not a real image' -Encoding utf8
    }
    Set-Content -LiteralPath (Join-Path $subsDir 'Subtitles.en.vtt') `
                -Value "WEBVTT`n`n00:00:00.000 --> 00:00:01.000`nHello from the test fixture.`n" -Encoding utf8

    if ($PostProcessed) {
        # The three files postprocess.ps1 adds that the VIEWER reads back:
        # urls.json, manifest.json and checksums.sha256. Left out by
        # default, because the postprocess suite asserts these get CREATED
        # and a fixture that pre-supplies them would make those assertions
        # pass without the script having done anything.
        $urlData = [ordered]@{
            original_url   = "https://www.youtube.com/watch?v=$VideoId"
            short_url      = "https://youtu.be/$VideoId"
            embed_url      = "https://www.youtube.com/embed/$VideoId"
            channel_url    = 'https://www.youtube.com/@testchannel'
            playlist_url   = $null
            playlist_id    = $null
            playlist_title = $null
        }
        New-Item -ItemType Directory -Path $urlsDir -Force | Out-Null
        $urlData | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $urlsDir 'urls.json') -Encoding utf8

        $files = @(Get-ChildItem -LiteralPath $videoDir -Recurse -File)
        $hashes = [ordered]@{}
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($videoDir.Length + 1).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
            $hashes[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        }
        ($hashes.GetEnumerator() | ForEach-Object { "$($_.Value)  $($_.Key)" }) |
            Set-Content -LiteralPath (Join-Path $metaDir 'checksums.sha256') -Encoding utf8
        [ordered]@{
            archive_creation_time = (Get-Date).ToString('o')
            video_id              = $VideoId
            title                 = $Title
            uploader              = $Uploader
            upload_date           = $UploadDate
            config_file_version   = '24'
            every_filename        = @($hashes.Keys)
            file_hashes           = $hashes
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $metaDir 'manifest.json') -Encoding utf8
    }

    if ($SeedChannelInfoThrottle) {
        # Pre-seeding .last_refresh is how the Channel Info refresh is kept
        # from making a network call -- the documented technique from
        # CLAUDE.md, and the reason most postprocess tests need no network
        # stub for that step at all.
        $channelInfoDir = Join-Path $channelDir 'Channel Info'
        New-Item -ItemType Directory -Path $channelInfoDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $channelInfoDir '.last_refresh') `
                    -Value (Get-Date -Format 'o') -Encoding utf8
    }

    return [pscustomobject]@{
        VideosRoot  = $videosRoot
        ArchiveDir  = $archiveDir
        ChannelDir  = $channelDir
        VideoDir    = $videoDir
        FolderName  = $folderName
        FinalFiles  = $finalFiles
        MetaDir     = $metaDir
        ImagesDir   = $imagesDir
        SubsDir     = $subsDir
        MkvPath     = $mkvPath
        InfoPath    = $infoPath
        VideoId     = $VideoId
        Uploader    = $Uploader
        HasRealMkv  = $hasRealMkv
    }
}

function New-SessionLog {
    <#
        Writes a download.log (or a worker log) containing a session-start
        marker, so postprocess.ps1's video_complete.log step has something
        to slice. Without one it warns and skips, which is a legitimate
        state but not the one most tests want to exercise.
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [string]$LogFileName = 'download.log',
        [string[]]$ExtraLines = @()
    )
    $logsDir = Join-Path $TestRoot.DataRoot 'Archive Logs/Logs'
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    $path = Join-Path $logsDir $LogFileName
    $lines = @(
        '==== Download session started 2020-01-01_000000 ====',
        'a line from a PREVIOUS session that must not be copied',
        '==== Download session started 2025-01-01_120000 ====',
        'platform: Test | install root: (fixture)',
        'URL: https://www.youtube.com/watch?v=testVideo01'
    ) + $ExtraLines
    Set-Content -LiteralPath $path -Value $lines -Encoding utf8
    return $path
}

function New-YtDlpStub {
    <#
        The standard yt-dlp stand-in for postprocess.ps1 tests.

        Kept here rather than in one suite file because postprocess makes
        THREE different yt-dlp calls -- the version query, the comments
        pass, and the Channel Info refresh -- and a suite that stubbed only
        the call it cared about would let the other two fall through to
        whatever real yt-dlp is installed, which on your own machine is a
        real one pointed at YouTube. Handling all three in one place keeps
        that impossible, in every suite, without each one remembering to.

        Behaviour is steered by environment variables, because the
        scriptblock is serialised to a file and therefore cannot close over
        anything:

          YTDLP_TEST_COMMENT_REQUESTS  how many "Downloading comment API
                                       JSON" lines to print (default 5)
          YTDLP_TEST_COMMENT_THROTTLE  1 = also print a retry/incomplete-data line
          YTDLP_TEST_COMMENT_EMPTY     1 = return an info.json with no comments at all
          YTDLP_TEST_COMMENT_SET       clean (default) | dupes | orphans | twopinned
    #>
    param([Parameter(Mandatory = $true)]$TestRoot)
    New-StubBinary -TestRoot $TestRoot -Name 'yt-dlp' -Behavior {
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
                # No "comments" property AT ALL -- the shape a video with
                # comments disabled produces, and the one that must give
                # merged_count 0 rather than 1.
                Set-Content -LiteralPath (Join-Path $dir 'comments.info.json') -Value '{"id":"testVideo01"}' -Encoding utf8
                return
            }

            switch ($env:YTDLP_TEST_COMMENT_SET) {
                'dupes' {
                    $comments = @(
                        [ordered]@{ id = 'c1'; text = 'top level one'; parent = 'root'; is_pinned = $true;  author_is_uploader = $false }
                        [ordered]@{ id = 'c1'; text = 'the same id again'; parent = 'root'; is_pinned = $false; author_is_uploader = $false }
                        [ordered]@{ id = 'c2'; text = 'top level two'; parent = 'root'; is_pinned = $false; author_is_uploader = $false }
                    )
                }
                'orphans' {
                    # A reply whose parent was never captured: proof of a
                    # mid-traversal gap, and the sharpest local check there
                    # is because it costs no external call at all.
                    $comments = @(
                        [ordered]@{ id = 'c1';        text = 'top level one'; parent = 'root';     is_pinned = $true;  author_is_uploader = $false }
                        [ordered]@{ id = 'lost.r1';   text = 'reply to a comment that is not here'; parent = 'lostParent'; is_pinned = $false; author_is_uploader = $false }
                        [ordered]@{ id = 'lost.r2';   text = 'another orphan';  parent = 'lostParent'; is_pinned = $false; author_is_uploader = $false }
                    )
                }
                'twopinned' {
                    # YouTube allows at most one pinned comment per video.
                    $comments = @(
                        [ordered]@{ id = 'c1'; text = 'pinned one'; parent = 'root'; is_pinned = $true; author_is_uploader = $false }
                        [ordered]@{ id = 'c2'; text = 'pinned two'; parent = 'root'; is_pinned = $true; author_is_uploader = $false }
                    )
                }
                default {
                    $comments = @(
                        [ordered]@{ id = 'c1';    text = 'top level one'; parent = 'root'; is_pinned = $true;  author_is_uploader = $false }
                        [ordered]@{ id = 'c2';    text = 'top level two'; parent = 'root'; is_pinned = $false; author_is_uploader = $false }
                        [ordered]@{ id = 'c2.r1'; text = 'a reply';       parent = 'c2';   is_pinned = $false; author_is_uploader = $true  }
                    )
                }
            }

            $payload = [ordered]@{
                id            = 'testVideo01'
                comment_count = $comments.Count
                comments      = $comments
            }
            $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dir 'comments.info.json') -Encoding utf8
            return
        }

        Write-Output "[stub] unhandled yt-dlp invocation: $($StubArgs -join ' ')"
    }
}

function Get-ScriptRegion {
    <#
        Returns the source text of one region of a repo script, delimited by
        two comment markers.

        Used to run a single block of postprocess.ps1 -- currently the
        comment-completeness audit -- in isolation, with a shadowing
        Invoke-RestMethod, so the API branches can be exercised without a
        key, without quota and without network. This is the technique the
        audit was originally verified with, kept rather than reinvented.

        Extracting the SHIPPED text matters. A re-typed copy of the block in
        a test file drifts from the real one within a release or two, and
        then the tests pass against code that is no longer running anywhere.

        The trade is that this depends on two comment lines staying put, so
        it fails loudly and specifically when they do not, rather than
        silently testing an empty string.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker
    )
    $lines = @(Get-Content -LiteralPath $Path)
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match [regex]::Escape($StartMarker)) { $start = $i; continue }
        if ($start -ge 0 -and $lines[$i] -match [regex]::Escape($EndMarker))   { $end = $i; break }
    }
    if ($start -lt 0) {
        throw "Could not find the start marker '$StartMarker' in $Path. If that comment was reworded or the block moved, update the marker in the test that asked for it -- do not delete the test."
    }
    if ($end -lt 0) {
        throw "Found '$StartMarker' in $Path but not the end marker '$EndMarker' after it. Update the markers in the test that asked for this region."
    }
    return (($lines[$start..($end - 1)]) -join "`n")
}

function Invoke-Postprocess {
    <#
        Runs the real postprocess.ps1 in a CHILD pwsh, the same way yt-dlp's
        --exec hook does. A child process rather than dot-sourcing because
        the script sets $ErrorActionPreference = 'Stop' and calls `return`
        at script scope -- both of which behave differently in-process and
        would make the test observe something other than production.
        Returns the captured output plus the exit code.
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$LogFileName = 'download.log'
    )
    $script = Join-Path $TestRoot.InstallRoot 'scripts/postprocess.ps1'
    $previousInstallRoot = $env:YTDLP_INSTALL_ROOT
    $env:YTDLP_INSTALL_ROOT = $TestRoot.InstallRoot
    try {
        $output = & (Get-PwshPath) -NoProfile -File $script -FilePath $FilePath -LogFileName $LogFileName 2>&1 |
                  ForEach-Object { "$_" }
        return [pscustomobject]@{ Output = @($output); ExitCode = $LASTEXITCODE }
    } finally {
        $env:YTDLP_INSTALL_ROOT = $previousInstallRoot
    }
}

function Invoke-RunYtdlp {
    <# Runs the real run_ytdlp.ps1 in a child pwsh against a test root. #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        [Parameter(Mandatory = $true)][string]$Url,
        [string[]]$ExtraArgs = @()
    )
    $script = Join-Path $TestRoot.InstallRoot 'scripts/run_ytdlp.ps1'
    $previousInstallRoot = $env:YTDLP_INSTALL_ROOT
    $env:YTDLP_INSTALL_ROOT = $TestRoot.InstallRoot
    try {
        $all = @('-NoProfile', '-File', $script, '-Url', $Url, '-DataRoot', $TestRoot.DataRoot) + $ExtraArgs
        $output = & (Get-PwshPath) @all 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Output = @($output); ExitCode = $LASTEXITCODE }
    } finally {
        $env:YTDLP_INSTALL_ROOT = $previousInstallRoot
    }
}

function Invoke-YtdlLauncher {
    <#
        Runs ytdl.ps1 -- the single argument parser -- in a child pwsh. Note
        it starts run_ytdlp.ps1 as a child of ITS own, so the test install
        root must contain a run_ytdlp.ps1; the launcher suite substitutes a
        recording stand-in for it so what the parser produced can be read
        back exactly.
    #>
    param(
        [Parameter(Mandatory = $true)]$TestRoot,
        # AllowEmptyCollection, because "ytdl with no arguments at all" is
        # the single most common mistake a user makes and therefore one of
        # the cases most worth testing.
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $script = Join-Path $TestRoot.InstallRoot 'scripts/ytdl.ps1'
    $previousInstallRoot = $env:YTDLP_INSTALL_ROOT
    $env:YTDLP_INSTALL_ROOT = $TestRoot.InstallRoot
    try {
        $all = @('-NoProfile', '-File', $script) + $Arguments
        $output = & (Get-PwshPath) @all 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Output = @($output); ExitCode = $LASTEXITCODE }
    } finally {
        $env:YTDLP_INSTALL_ROOT = $previousInstallRoot
    }
}
