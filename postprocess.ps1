param(
    [Parameter(Mandatory = $true)][string]$FilePath
)

$ErrorActionPreference = "Stop"

try {
    # FilePath = .../<Uploader> - <Date> - <Id> - <Title>/Final files/<name>.mkv
    $finalFilesDir = Split-Path $FilePath -Parent
    $videoDir      = Split-Path $finalFilesDir -Parent
    $channelDir    = Split-Path $videoDir -Parent
    $archiveDir    = Split-Path $channelDir -Parent          # .../Complete Archive
    $youtubeRoot   = Split-Path $archiveDir -Parent          # .../Youtube Videos
    $uploader      = Split-Path $channelDir -Leaf

    $videoMetaDir  = Join-Path $videoDir "Video metadata"
    $logsDir       = Join-Path $videoDir "Logs"
    $urlsDir       = Join-Path $videoDir "URLs"
    $pureVideoDir  = Join-Path (Join-Path $youtubeRoot "Pure Video") $uploader

    foreach ($d in @($logsDir, $urlsDir, $pureVideoDir)) {
        if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $logFile = Join-Path $logsDir "video_postprocessing.log"
    function Log($msg) {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
        Add-Content -Path $logFile -Value $line
        Write-Output $line   # bubbles up into yt-dlp's console output / download.log via the launcher
    }

    Log "Post-processing started for: $FilePath"

    # --- Locate the matching info.json (retry briefly for FS/AV-scan lag) ---
    $infoJsonFile = $null
    for ($i = 0; $i -lt 5; $i++) {
        $infoJsonFile = Get-ChildItem -Path $videoMetaDir -Filter "*.info.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($infoJsonFile) { break }
        Start-Sleep -Seconds 2
    }

    if ($infoJsonFile) {
        $info = Get-Content $infoJsonFile.FullName -Raw | ConvertFrom-Json
        $videoId      = $info.id
        $title        = $info.title
        $uploadDate   = $info.upload_date
        $originalUrl  = if ($info.original_url) { $info.original_url } else { $info.webpage_url }
        $channelUrl   = if ($info.channel_url) { $info.channel_url } else { $info.uploader_url }
        $shortUrl     = "https://youtu.be/$videoId"
        $embedUrl     = "https://www.youtube.com/embed/$videoId"
        $playlistUrl  = if ($info.playlist_id) { "https://www.youtube.com/playlist?list=$($info.playlist_id)" } else { $null }
    } else {
        # Degrade gracefully rather than aborting: still do checksums, the
        # manifest, and (importantly) the Pure Video copy below, just with
        # blank URL/playlist fields. Recover what we can from the folder
        # name itself, which encodes uploader/date/id/title.
        Log "WARNING: No .info.json found in $videoMetaDir after retrying. Continuing with filename-derived metadata only."
        $info = $null
        $folderName = Split-Path $videoDir -Leaf
        if ($folderName -match '^(?<uploader>.+?) - (?<date>\d{8}) - (?<id>[\w-]{6,})\s*-\s*(?<title>.+)$') {
            $videoId    = $Matches.id
            $title      = $Matches.title
            $uploadDate = $Matches.date
        } else {
            $videoId = $null; $title = $null; $uploadDate = $null
        }
        $originalUrl = $null
        $channelUrl  = $null
        $shortUrl    = if ($videoId) { "https://youtu.be/$videoId" } else { $null }
        $embedUrl    = $null
        $playlistUrl = $null
    }

    # --- Per-video copy of the full yt-dlp console output (#9) ---
    # download.log is shared/cumulative across every video and every run, so
    # this pulls out just the lines that mention this video's ID -- which in
    # practice is nearly every line for this video, since our output template
    # embeds the ID in every filename yt-dlp logs. This is a best-effort
    # filter by content match, not a true session-boundary extract, so an
    # unrelated line that happens to contain the same text is theoretically
    # possible but very unlikely given YouTube's ID format.
    $mainDownloadLog = "C:/yt-dlp/download.log"
    $completeLogFile = Join-Path $logsDir "video_complete.log"
    if ($videoId -and (Test-Path $mainDownloadLog)) {
        $matchedLines = Select-String -Path $mainDownloadLog -Pattern ([regex]::Escape($videoId)) -SimpleMatch | ForEach-Object { $_.Line }
        $matchedLines | Set-Content -Path $completeLogFile
        Log "Wrote video_complete.log."

        # Surface comment-fetch problems specifically, since they can fail
        # quietly enough to be easy to miss in the full console output.
        $commentIssues = $matchedLines | Where-Object { $_ -match '(?i)comment' -and $_ -match '(?i)(warn|error|unable|fail)' }
        if ($commentIssues) {
            Log "WARNING: $($commentIssues.Count) comment-related warning/error line(s) for this video (full text in video_complete.log):"
            foreach ($line in $commentIssues) { Log "  $line" }
        }
    } else {
        Log "WARNING: Could not build video_complete.log (no video id, or download.log not found)."
    }

    # --- URL metadata file (#12) ---
    $urlData = [ordered]@{
        original_url   = $originalUrl
        short_url       = $shortUrl
        embed_url       = $embedUrl
        channel_url     = $channelUrl
        playlist_url    = $playlistUrl
        playlist_id     = if ($info) { $info.playlist_id } else { $null }
        playlist_title  = if ($info) { $info.playlist_title } else { $null }
    }
    $urlData | ConvertTo-Json | Set-Content (Join-Path $urlsDir "urls.json")
    Log "Wrote URL metadata file."

    # --- Codecs actually used ---
    $codecs = @()
    if ($info.requested_formats) {
        foreach ($f in $info.requested_formats) {
            $codecs += [ordered]@{ format_id = $f.format_id; ext = $f.ext; vcodec = $f.vcodec; acodec = $f.acodec }
        }
    } elseif ($info.vcodec -or $info.acodec) {
        $codecs += [ordered]@{ format_id = $info.format_id; ext = $info.ext; vcodec = $info.vcodec; acodec = $info.acodec }
    }

    # --- Subtitle languages actually downloaded ---
    $subLangs = @()
    if ($info.requested_subtitles) {
        $subLangs = $info.requested_subtitles.PSObject.Properties.Name
    }

    # --- Every file + hash under the video folder ---
    $allFiles = Get-ChildItem -Path $videoDir -Recurse -File
    $fileHashes = [ordered]@{}
    $fileList = @()
    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($videoDir.Length + 1)
        $fileList += $rel
        $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
        $fileHashes[$rel] = $hash
    }

    # --- Checksums file (#10) ---
    $checksumLines = $fileHashes.GetEnumerator() | ForEach-Object { "$($_.Value)  $($_.Key)" }
    $checksumLines | Set-Content (Join-Path $videoMetaDir "checksums.sha256")
    Log "Wrote checksums for $($fileList.Count) files."

    # --- Config version, tool versions ---
    $confPath = "C:/yt-dlp/configs/yt-dlp.conf"
    $configVersion = $null
    if (Test-Path $confPath) {
        $m = Select-String -Path $confPath -Pattern "CONFIG_VERSION:\s*(\S+)" | Select-Object -First 1
        if ($m) { $configVersion = $m.Matches[0].Groups[1].Value }
    }
    $ytDlpVersion  = (& yt-dlp --version) 2>$null
    $ffmpegRaw     = (& ffmpeg -version) 2>$null
    $ffmpegVersion = if ($ffmpegRaw) { ($ffmpegRaw -split "`n")[0] } else { $null }
    $osCaption     = (Get-CimInstance Win32_OperatingSystem).Caption

    # --- manifest.json (#8) ---
    $manifest = [ordered]@{
        archive_creation_time = (Get-Date).ToString("o")
        yt_dlp_version         = $ytDlpVersion
        ffmpeg_version          = $ffmpegVersion
        operating_system        = $osCaption
        config_file_version     = $configVersion
        video_id                = $videoId
        title                   = $title
        uploader                = $uploader
        upload_date             = $uploadDate
        original_url            = $originalUrl
        channel_url             = $channelUrl
        playlist_id             = $info.playlist_id
        playlist_title          = $info.playlist_title
        codecs                  = $codecs
        subtitle_languages      = $subLangs
        every_filename          = $fileList
        file_hashes             = $fileHashes
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $videoMetaDir "manifest.json")
    Log "Wrote manifest.json."

    # --- Copy final file to Pure Video (replaces old copy_to_pure.bat) ---
    $destFile = Join-Path $pureVideoDir (Split-Path $FilePath -Leaf)
    Copy-Item -Path $FilePath -Destination $destFile -Force
    Log "Copied final file to Pure Video: $destFile"

    # --- Channel manifest (#15) ---
    $channelManifestPath = Join-Path $channelDir "channel_manifest.json"
    $channelManifest = if (Test-Path $channelManifestPath) {
        Get-Content $channelManifestPath -Raw | ConvertFrom-Json
    } else { @() }
    $channelManifest = @($channelManifest | Where-Object { $_.video_id -ne $videoId })
    $channelManifest += [ordered]@{ video_id = $videoId; title = $title; upload_date = $uploadDate; url = $originalUrl; folder = $videoDir }
    $channelManifest | ConvertTo-Json -Depth 4 | Set-Content $channelManifestPath

    # --- Global manifest (#14 / #15) ---
    $globalManifestPath = Join-Path $youtubeRoot "global_manifest.json"
    $globalManifest = if (Test-Path $globalManifestPath) {
        Get-Content $globalManifestPath -Raw | ConvertFrom-Json
    } else { @() }
    $globalManifest = @($globalManifest | Where-Object { $_.video_id -ne $videoId })
    $globalManifest += [ordered]@{ video_id = $videoId; title = $title; uploader = $uploader; upload_date = $uploadDate; url = $originalUrl; folder = $videoDir }
    $globalManifest | ConvertTo-Json -Depth 4 | Set-Content $globalManifestPath

    Log "Updated channel and global manifests."

    # --- Channel-level assets: avatar, banner, description, channel info.json ---
    # Lives outside the individual video folders, at the channel root, and is
    # refreshed (overwritten) every time a video from this channel finishes.
    try {
        $channelInfoDir = Join-Path $channelDir "Channel Info"
        if (!(Test-Path $channelInfoDir)) {
            New-Item -ItemType Directory -Path $channelInfoDir -Force | Out-Null
        }

        # Throttle: skip re-fetching if we already refreshed recently. This matters
        # most when running against a whole channel/playlist in one go, so we don't
        # hit the channel's About page once per video in a 100+ video run.
        $throttleMarker = Join-Path $channelInfoDir ".last_refresh"
        $throttleHours = 6
        $needsRefresh = $true
        if (Test-Path $throttleMarker) {
            $age = (Get-Date) - (Get-Item $throttleMarker).LastWriteTime
            if ($age.TotalHours -lt $throttleHours) { $needsRefresh = $false }
        }

        if (-not $channelUrl) {
            Log "No channel_url found in info.json — skipped Channel Info refresh."
        } elseif (-not $needsRefresh) {
            Log "Channel Info refreshed within the last $throttleHours hours — skipped."
        } else {
            # Only clear the folder once we're actually about to repopulate it.
            Remove-Item -Path "$channelInfoDir\*" -Recurse -Force -ErrorAction SilentlyContinue

            & yt-dlp `
                --ignore-config `
                --skip-download `
                --flat-playlist `
                --playlist-items 0 `
                --write-info-json `
                --write-all-thumbnails `
                --write-description `
                -o (Join-Path $channelInfoDir "channel.%(ext)s") `
                $channelUrl 2>&1 | ForEach-Object { Log "  [channel-info] $_" }

            Set-Content -Path $throttleMarker -Value (Get-Date -Format "o")
            Log "Refreshed Channel Info for $uploader."
        }
    }
    catch {
        Log "WARNING: Channel Info refresh failed: $($_.Exception.Message)"
    }

    # --- Trim empty leftover folders under _incomplete (#5) ---
    # yt-dlp mirrors the full per-video folder structure into the temp path
    # (same uploader/date/id/title nesting as the final destination), but it
    # has no built-in cleanup for the now-empty folders left behind once
    # files are moved to their final home. This is a known, unresolved
    # yt-dlp limitation (see yt-dlp/yt-dlp#11674), not something a config
    # flag can fix, so we sweep it ourselves after every video.
    try {
        $incompleteRoot = "C:/yt-dlp/Youtube Videos/_incomplete"
        if (Test-Path $incompleteRoot) {
            do {
                $removed = 0
                Get-ChildItem -Path $incompleteRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { -not (Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1) } |
                    ForEach-Object {
                        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                        $removed++
                    }
            } while ($removed -gt 0)
            Log "Swept empty folders under _incomplete."
        }
    } catch {
        Log "WARNING: Empty-folder sweep under _incomplete failed: $($_.Exception.Message)"
    }

    Log "Post-processing complete."
}
catch {
    $errMsg = "ERROR during post-processing: $($_.Exception.Message)"
    Write-Output $errMsg
    try { Add-Content -Path $logFile -Value $errMsg } catch {}
    throw
}
