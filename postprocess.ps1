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

    $logFile = Join-Path $logsDir "video.log"
    function Log($msg) {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
        Add-Content -Path $logFile -Value $line
        Write-Output $line   # bubbles up into yt-dlp's console output / download.log via the launcher
    }

    Log "Post-processing started for: $FilePath"

    # --- Locate the matching info.json ---
    $infoJsonFile = Get-ChildItem -Path $videoMetaDir -Filter "*.info.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $infoJsonFile) { throw "Could not find matching .info.json in $videoMetaDir" }
    $info = Get-Content $infoJsonFile.FullName -Raw | ConvertFrom-Json

    $videoId      = $info.id
    $title        = $info.title
    $uploadDate   = $info.upload_date
    $originalUrl  = if ($info.original_url) { $info.original_url } else { $info.webpage_url }
    $channelUrl   = if ($info.channel_url) { $info.channel_url } else { $info.uploader_url }
    $shortUrl     = "https://youtu.be/$videoId"
    $embedUrl     = "https://www.youtube.com/embed/$videoId"
    $playlistUrl  = if ($info.playlist_id) { "https://www.youtube.com/playlist?list=$($info.playlist_id)" } else { $null }

    # --- URL metadata file (#12) ---
    $urlData = [ordered]@{
        original_url   = $originalUrl
        short_url       = $shortUrl
        embed_url       = $embedUrl
        channel_url     = $channelUrl
        playlist_url    = $playlistUrl
        playlist_id     = $info.playlist_id
        playlist_title  = $info.playlist_title
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
    $confPath = "C:/yt-dlp/yt-dlp.conf"
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

    Log "Post-processing complete."
}
catch {
    $errMsg = "ERROR during post-processing: $($_.Exception.Message)"
    Write-Output $errMsg
    try { Add-Content -Path $logFile -Value $errMsg } catch {}
    throw
}
