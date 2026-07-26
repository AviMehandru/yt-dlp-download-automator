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
    # download.log is shared/cumulative across every run. postprocess.ps1
    # runs mid-session (via the after_move hook, before yt-dlp itself
    # finishes and writes the "session finished" marker), so everything
    # from the most recent "session started" marker up to this exact
    # moment is an exact, unedited copy of this run's console output.
    # NOTE: this captures the whole session, not just one video -- for a
    # playlist/channel URL covering several videos in one run, each
    # video's video_complete.log would contain everything processed so
    # far in that session, not just its own portion. Exact per-video
    # boundaries aren't available for multi-video sessions since yt-dlp
    # doesn't mark them. This matches how you actually run it (one URL
    # per invocation), where it's a perfect 1:1 copy.
    $mainDownloadLog = "C:/yt-dlp/Archive Logs/Logs/download.log"
    $completeLogFile = Join-Path $logsDir "video_complete.log"
    $sessionLines = $null
    if (Test-Path $mainDownloadLog) {
        $allLines = Get-Content -Path $mainDownloadLog
        $startMatch = $allLines | Select-String -Pattern '^==== Download session started' | Select-Object -Last 1
        if ($startMatch) {
            $sessionLines = $allLines[($startMatch.LineNumber - 1)..($allLines.Count - 1)]
            $sessionLines | Set-Content -Path $completeLogFile
            Log "Wrote video_complete.log (exact copy of this session from download.log)."
        } else {
            Log "WARNING: No session-start marker found in download.log; video_complete.log not written."
        }
    } else {
        Log "WARNING: download.log not found at $mainDownloadLog; video_complete.log not written."
    }

    # Comments are now fetched by a separate pass below, after the video/
    # audio/subtitles are already safely downloaded -- see that section for
    # why, and for where comment-fetch issues get logged instead.

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

    # --- Preserve the original-format thumbnail alongside the converted PNG ---
    # yt-dlp's --convert-thumbnails replaces the on-disk file rather than
    # keeping both, so this re-fetches the original straight from its
    # source URL (already known from info.json) and saves it next to the
    # PNG with the same base filename, distinguished only by extension.
    # Downloads straight to disk with -OutFile rather than reading .Content
    # into memory -- -OutFile writes binary responses correctly without
    # depending on how Invoke-WebRequest happens to type .Content, and
    # -PassThru still gets us the response object (for Content-Type) in
    # the same call. No -UseBasicParsing needed under pwsh: that switch
    # only ever existed to avoid Windows PowerShell's IE-engine HTML
    # parsing, which pwsh's Invoke-WebRequest never uses in the first place.
    try {
        $imagesDir = Join-Path $videoDir "Images"
        $pngThumb = Get-ChildItem -Path $imagesDir -Filter "*.png" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pngThumb -and $info -and $info.thumbnail) {
            $rawThumbTemp = Join-Path $imagesDir ("_thumb_temp_{0}" -f ([guid]::NewGuid().ToString("N")))
            $resp = Invoke-WebRequest -Uri $info.thumbnail -Method Get -OutFile $rawThumbTemp -PassThru -ErrorAction Stop
            $ext = "jpg"
            $ct = $resp.Headers["Content-Type"]
            if ($ct -match "webp") { $ext = "webp" }
            elseif ($ct -match "png") { $ext = "png" }
            elseif ($ct -match "jpeg") { $ext = "jpg" }
            if ($ext -ne "png") {
                $origThumbPath = Join-Path $imagesDir "$($pngThumb.BaseName).$ext"
                Move-Item -Path $rawThumbTemp -Destination $origThumbPath -Force
                Log "Preserved original-format thumbnail: $origThumbPath"
            } else {
                Remove-Item -Path $rawThumbTemp -Force -ErrorAction SilentlyContinue
                Log "Thumbnail source was already PNG -- no separate original-format copy needed."
            }
        } elseif (-not $pngThumb) {
            Log "WARNING: No PNG thumbnail found in $imagesDir -- skipped preserving original-format copy."
        }
    } catch {
        Log "WARNING: Could not preserve original-format thumbnail: $($_.Exception.Message)"
    }

    # --- Comments: separate pass, run last on purpose ---
    # See the config comment near --continue for why this isn't part of the
    # main download. This re-extracts the video (unavoidable -- yt-dlp has
    # no "comments only" mode that skips extraction) purely to fetch
    # comments, then merges them into the sidecar info.json already saved
    # from the main download. Note this does NOT reach the copy of
    # info.json already embedded inside the .mkv via --embed-info-json --
    # that embed happened during the main pass, before comments existed.
    # Only the sidecar info.json file on disk gets the comments added.
    # This can also take 30-60+ minutes on a heavily-commented video; it
    # doesn't make the video finish any faster overall, it just makes sure
    # everything expiry-sensitive is safe before comments are attempted.
    try {
        if ($originalUrl -and $infoJsonFile) {
            $commentsTempDir = Join-Path $videoMetaDir "_comments_temp"
            if (!(Test-Path $commentsTempDir)) { New-Item -ItemType Directory -Path $commentsTempDir -Force | Out-Null }

            $commentsOutput = & yt-dlp `
                --ignore-config `
                --skip-download `
                --write-comments `
                --write-info-json `
                --extractor-retries 100 `
                --retry-sleep "extractor:exp=1:30:2" `
                --sleep-requests 2 `
                -o (Join-Path $commentsTempDir "comments.%(ext)s") `
                $originalUrl 2>&1
            $commentsOutput | ForEach-Object { Log "  [comments] $_" }

            $commentIssues = $commentsOutput | Where-Object { $_ -match '(?i)(warn|error|unable|fail)' }
            if ($commentIssues) {
                Log "WARNING: $($commentIssues.Count) issue(s) during the comments pass (see [comments] lines above)."
            }

            $commentsInfoFile = Get-ChildItem -Path $commentsTempDir -Filter "*.info.json" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($commentsInfoFile) {
                $commentsInfo = Get-Content $commentsInfoFile.FullName -Raw | ConvertFrom-Json
                if ($commentsInfo.comments) {
                    $mainInfoRaw = Get-Content $infoJsonFile.FullName -Raw | ConvertFrom-Json
                    $mainInfoRaw | Add-Member -NotePropertyName comments -NotePropertyValue $commentsInfo.comments -Force
                    $mainInfoRaw | Add-Member -NotePropertyName comment_count -NotePropertyValue $commentsInfo.comment_count -Force
                    $mainInfoRaw | ConvertTo-Json -Depth 20 | Set-Content $infoJsonFile.FullName
                    Log "Merged $($commentsInfo.comments.Count) comments into the sidecar info.json."
                } else {
                    Log "WARNING: Comments pass completed but returned no comments -- nothing to merge."
                }
            } else {
                Log "WARNING: Comments pass produced no usable info.json -- comments not merged."
            }

            Remove-Item -Path $commentsTempDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Log "WARNING: No original_url or main info.json available -- skipped the comments pass entirely."
        }
    } catch {
        Log "WARNING: Comments pass failed: $($_.Exception.Message)"
    }

    # --- Re-embed the (now comment-complete) info.json into the .mkv ---
    # This is what --embed-info-json would normally do, done manually and
    # deferred until after the comments merge above. ffmpeg attaches the
    # updated info.json to the existing file -- -map 0 -c copy means this
    # is a container-level change only, no video/audio re-encoding, and it
    # preserves whatever's already attached (e.g. the embedded thumbnail).
    # Writes to a temp file first and only swaps it in on success, so a
    # failed remux can never leave you with a damaged or missing video.
    try {
        if ($FilePath -match '\.mkv$' -and $infoJsonFile) {
            # Count existing attachment-type streams so the mimetype tag
            # below targets ONLY the new one we're adding. Without an
            # explicit index, ffmpeg's "s:t" specifier matches every
            # attachment stream, which would mislabel the already-embedded
            # thumbnail as application/json too.
            $existingAttachCount = 0
            $probeOutput = & ffprobe -v error -select_streams t -show_entries stream=index -of csv=p=0 $FilePath 2>&1
            if ($LASTEXITCODE -eq 0) {
                $existingAttachCount = @($probeOutput | Where-Object { $_ -match '^\d+$' }).Count
            } else {
                Log "WARNING: ffprobe attachment count failed, assuming 0 existing attachments: $probeOutput"
            }

            $remuxTemp = Join-Path $finalFilesDir ("_remux_temp_{0}.mkv" -f ([guid]::NewGuid().ToString("N")))
            $ffmpegOutput = & ffmpeg -y -i $FilePath -attach $infoJsonFile.FullName -metadata:s:t:$existingAttachCount "mimetype=application/json" -map 0 -c copy $remuxTemp 2>&1
            $ffmpegOutput | ForEach-Object { Log "  [ffmpeg-reembed] $_" }

            if ((Test-Path $remuxTemp) -and (Get-Item $remuxTemp).Length -gt 0) {
                Remove-Item -Path $FilePath -Force
                Move-Item -Path $remuxTemp -Destination $FilePath -Force
                Log "Re-embedded comment-complete info.json into $FilePath."
            } else {
                Log "WARNING: Re-embed produced no output file -- original left untouched. Comments are still in the sidecar info.json, just not embedded in the .mkv."
                Remove-Item -Path $remuxTemp -Force -ErrorAction SilentlyContinue
            }
        } elseif ($FilePath -notmatch '\.mkv$') {
            Log "Skipped info.json re-embed: output file isn't .mkv ($FilePath)."
        }
    } catch {
        Log "WARNING: Re-embed of info.json failed: $($_.Exception.Message). Original file left untouched; comments are still in the sidecar info.json."
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
