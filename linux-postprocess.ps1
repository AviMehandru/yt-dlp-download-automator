param(
    [Parameter(Mandatory = $true)][string]$FilePath,

    # Which file under Archive Logs/Logs/ this invocation's slice of yt-dlp
    # console output should be read from, for the video_complete.log copy
    # further down. Defaults to "download.log" -- the single shared log
    # every non-parallel run has always used -- so a manual/standalone
    # invocation of this script behaves exactly as before. When run_ytdlp.ps1
    # is dispatching multiple videos in parallel (-Workers > 1), each
    # worker downloads into its OWN log file instead of the shared one, and
    # passes that file's name here. This matters because the video_complete.log
    # logic below works by finding "the most recent session-start marker" in
    # whichever log it reads -- against a single SHARED log with several
    # downloads interleaved line-by-line from concurrent processes, that
    # search is meaningless (there's no single "most recent session," and
    # the lines from unrelated videos would end up interleaved into each
    # other's video_complete.log). A distinct log per concurrent worker
    # keeps that logic correct with no other changes needed.
    [Parameter(Mandatory = $false)][string]$LogFileName = "download.log"
)

$ErrorActionPreference = "Stop"

# --- Cross-platform advisory file locking ---
# Needed once postprocess.ps1 can run for several videos AT THE SAME TIME
# (under run_ytdlp.ps1 -Workers N): several instances of this script can
# now be doing their own read-modify-write of the SAME shared files
# (channel_manifest.json, global_manifest.json) or the same
# check-then-act sequence (the Channel Info refresh throttle) at once.
# Without serializing those specific sections, two concurrent instances
# can each read the "before" state, both compute their own "after" state,
# and whichever writes last silently wins -- the other's update is lost.
# This isn't hypothetical: it's the exact shape of bug that would corrupt
# a manifest without ever throwing an error or appearing in any log.
#
# Deliberately NOT using the Linux `flock` binary: that would work here,
# but this pipeline's Windows variant has no equivalent, and shelling out
# to flock -c "..." to wrap a block of PowerShell is awkward (it means
# writing the block out to a temp script file just to invoke it under the
# lock). Opening a file with FileShare.None instead is a plain .NET
# primitive available identically on both platforms -- a second process
# trying to open the same path the same way gets a normal IOException
# until the first one closes it, which is all a mutex needs to do here.
# This is advisory locking (it only blocks other code that also calls
# Enter-Lock/Exit-Lock around the same path) -- fine for this use, since
# every writer of these particular files is postprocess.ps1 itself.
function Enter-Lock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [int]$TimeoutSeconds = 300   # generous: this only ever guards fast, local file I/O, never a network call
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ((Get-Date) -gt $deadline) {
                throw "Timed out after ${TimeoutSeconds}s waiting for lock: $LockPath (another postprocess.ps1 instance may be stuck)"
            }
            # Small random jitter, not a fixed interval, so multiple waiters
            # queued on the same lock don't all wake up and re-collide on
            # the exact same tick.
            Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 400)
        }
    }
}
function Exit-Lock {
    param($LockHandle)
    if ($LockHandle) { $LockHandle.Close(); $LockHandle.Dispose() }
}

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

    # $dataRoot is the parent of "Youtube Videos" -- derived from $FilePath
    # itself (via $youtubeRoot above), so this correctly reflects whichever
    # data root was actually used for THIS run (the default $HOME/yt-dlp,
    # or a custom -DataRoot passed to run_ytdlp.ps1) without needing that
    # value passed in separately. $installRoot (where scripts/configs live)
    # is a different, fixed location -- always $HOME/yt-dlp regardless of
    # -DataRoot -- so it's resolved independently via $HOME below rather
    # than derived from $FilePath's ancestry.
    $dataRoot    = Split-Path $youtubeRoot -Parent
    $installRoot = Join-Path $HOME "yt-dlp"

    foreach ($d in @($logsDir, $urlsDir)) {
        if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $logFile = Join-Path $logsDir "video_postprocessing.log"
    function Log($msg) {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
        Add-Content -Path $logFile -Value $line
        Write-Output $line   # bubbles up into yt-dlp's console output / download.log via the launcher
    }

    Log "Post-processing started for: $FilePath"

    # --- Only run the full pipeline for the actual final merged file ---
    # yt-dlp's --exec "after_move:..." hook fires once for EVERY file that
    # gets moved into its final location, not just the merged video. With
    # --keep-video set (as it is here), that includes the separate,
    # pre-merge video-only and audio-only streams too -- each one gets its
    # own invocation of this entire script. Nothing below this point was
    # ever gated by file type except the info.json re-embed step further
    # down, so a run triggered by one of those intermediate streams would
    # still redo the (expensive, 30-60+ min) comments fetch, overwrite
    # manifest.json/checksums.sha256 with that stream's info instead of
    # the real video's, and -- most visibly -- copy that stream into the
    # Final Video repository, silently replacing the actual merged .mkv
    # there with a video-only or audio-only fragment, depending on which
    # invocation happened to finish last. That's almost certainly why
    # files elsewhere named after the "final" video haven't looked like
    # the real thing: whichever invocation ran last won. Only the final
    # merged .mkv should ever reach any of this, so every other file this
    # script gets invoked with is now skipped outright.
    if ($FilePath -notmatch '\.mkv$') {
        Log "Skipped: not the final merged .mkv (this is a --keep-video pre-merge stream, e.g. the video-only or audio-only file). No further processing done for this invocation."
        return
    }

    # --- Relocate --keep-video's pre-merge streams for clarity ---
    # --keep-video keeps the original, un-merged video-only and audio-only
    # streams alongside the final merged file, using the same "Final Video"
    # base name with yt-dlp's own format-id suffix inserted before the
    # extension (e.g. "Final Video.f137.mp4", "Final Video.f251.m4a").
    # Several near-identically-named files sitting in the same folder is
    # exactly what caused the "which one of these is actually final?"
    # confusion -- moving the pre-merge ones out into their own subfolder
    # leaves only the real final file ("Final Video.mkv") at the top level
    # of "Final files", with the raw streams still kept nearby, just no
    # longer easy to mistake for it.
    try {
        $preMergeFiles = Get-ChildItem -Path $finalFilesDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $FilePath -and $_.Name -match '^Final Video\.f\S+\.' }
        if ($preMergeFiles) {
            $preMergeDir = Join-Path $finalFilesDir "Pre-merge streams"
            if (!(Test-Path $preMergeDir)) { New-Item -ItemType Directory -Path $preMergeDir -Force | Out-Null }
            foreach ($f in $preMergeFiles) {
                Move-Item -Path $f.FullName -Destination (Join-Path $preMergeDir $f.Name) -Force
            }
            Log "Moved $($preMergeFiles.Count) --keep-video pre-merge stream(s) into 'Pre-merge streams/' -- Final Video.mkv is the only true final output remaining in Final files."
        }
    } catch {
        Log "WARNING: Could not relocate --keep-video pre-merge streams: $($_.Exception.Message)"
    }

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
        # manifest, and (importantly) the Final Video repository sync
        # below, just with blank URL/playlist fields. Recover what we can
        # from the folder
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
    $mainDownloadLog = Join-Path $dataRoot "Archive Logs/Logs/$LogFileName"
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

    # --- Generate the PNG thumbnail locally from the already-downloaded original ---
    # yt-dlp.conf no longer runs --convert-thumbnails, so the file already
    # sitting in Images/ IS the original, untouched, native-format thumbnail
    # exactly as it existed at extraction time (webp/jpg/etc) -- nothing
    # needs to be "preserved" via a network re-fetch anymore.
    #
    # This used to re-fetch info.thumbnail's URL here, late in the pipeline
    # (after the whole video finished downloading, which can be a long
    # time later). That URL is LIVE, not a snapshot -- if the uploader
    # changed the video's thumbnail mid-download, that re-fetch silently
    # pulled back a DIFFERENT image than the one actually embedded/used,
    # producing an "original" copy that didn't match the PNG at all. Doing
    # the PNG conversion locally, from the file yt-dlp already saved,
    # guarantees both copies are pixel-identical derivatives of the same
    # bytes captured at extraction time -- no network call, no race window.
    try {
        $imagesDir = Join-Path $videoDir "Images"
        $rawThumb = Get-ChildItem -Path $imagesDir -Filter "Thumbnail.*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ne ".png" } | Select-Object -First 1
        if ($rawThumb) {
            $pngPath = Join-Path $imagesDir "Thumbnail.png"
            if (!(Test-Path $pngPath)) {
                $ffmpegThumbOutput = & ffmpeg -y -i $rawThumb.FullName $pngPath 2>&1
                if ((Test-Path $pngPath) -and (Get-Item $pngPath).Length -gt 0) {
                    Log "Generated Thumbnail.png locally from $($rawThumb.Name) (no network re-fetch involved)."
                } else {
                    Log "WARNING: Local PNG conversion of $($rawThumb.Name) failed: $ffmpegThumbOutput"
                }
            } else {
                Log "Thumbnail.png already present -- skipped local conversion."
            }
        } else {
            Log "WARNING: No raw thumbnail file found in $imagesDir -- nothing to convert to PNG."
        }
    } catch {
        Log "WARNING: Could not generate local PNG thumbnail copy: $($_.Exception.Message)"
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

            # Piped through ForEach-Object rather than captured into a
            # variable first -- capturing the whole `& yt-dlp ... 2>&1`
            # output into $commentsOutput BEFORE logging it meant
            # PowerShell buffered the entire comments fetch silently in
            # memory and only printed anything once the process fully
            # exited. On a heavily-commented video that's exactly a 15+
            # minute silent gap with zero console/log output, looking
            # exactly like the script had hung, when it was actually
            # working the whole time. Logging each line AS it streams
            # (while still building $commentsOutput for the warning-count
            # check below) fixes that with no change in end behavior.
            $commentsOutput = & yt-dlp `
                --ignore-config `
                --skip-download `
                --write-comments `
                --write-info-json `
                --extractor-retries 100 `
                --retry-sleep "extractor:exp=1:30:2" `
                --sleep-requests 2 `
                -o (Join-Path $commentsTempDir "comments.%(ext)s") `
                $originalUrl 2>&1 | ForEach-Object {
                    Log "  [comments] $_"
                    $_
                }

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
            # Same streaming-log fix as the comments pass above, applied
            # here too for consistency -- a stream-copy remux is normally
            # fast, but on a very large file or a slow disk there's no
            # reason to let output sit buffered instead of showing up as
            # it happens.
            $ffmpegOutput = & ffmpeg -y -i $FilePath -attach $infoJsonFile.FullName -metadata:s:t:$existingAttachCount "mimetype=application/json" -map 0 -c copy $remuxTemp 2>&1 | ForEach-Object {
                Log "  [ffmpeg-reembed] $_"
                $_
            }

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
    # $installRoot (fixed at $HOME/yt-dlp), not $dataRoot -- configs/ lives
    # with the pipeline install, not with a possibly-custom data root.
    $confPath = Join-Path $installRoot "configs/yt-dlp.conf"
    $configVersion = $null
    if (Test-Path $confPath) {
        $m = Select-String -Path $confPath -Pattern "CONFIG_VERSION:\s*(\S+)" | Select-Object -First 1
        if ($m) { $configVersion = $m.Matches[0].Groups[1].Value }
    }
    $ytDlpVersion  = (& yt-dlp --version) 2>$null
    $ffmpegRaw     = (& ffmpeg -version) 2>$null
    $ffmpegVersion = if ($ffmpegRaw) { ($ffmpegRaw -split "`n")[0] } else { $null }
    # Get-CimInstance (used in the Windows version) is WMI-based and doesn't
    # exist on Linux. $PSVersionTable.OS is a built-in pwsh property that
    # returns the OS version string identically cross-platform, no branching
    # needed.
    $osCaption     = $PSVersionTable.OS

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

    # --- Global manifest (#14 / #15) ---
    # Locked separately from the channel-scoped block below, with its OWN
    # lock file at the Youtube Videos/ root rather than inside $channelDir --
    # this file is shared across EVERY channel, so two videos finishing at
    # the same time from two DIFFERENT channels still need to serialize
    # here, even though they won't contend on the per-channel lock at all.
    $globalManifestPath = Join-Path $youtubeRoot "global_manifest.json"
    $globalLockPath = Join-Path $youtubeRoot ".global_manifest.lock"
    $globalLock = Enter-Lock -LockPath $globalLockPath
    try {
        $globalManifest = if (Test-Path $globalManifestPath) {
            Get-Content $globalManifestPath -Raw | ConvertFrom-Json
        } else { @() }
        $globalManifest = @($globalManifest | Where-Object { $_.video_id -ne $videoId })
        $globalManifest += [ordered]@{ video_id = $videoId; title = $title; uploader = $uploader; upload_date = $uploadDate; url = $originalUrl; folder = $videoDir }
        $globalManifest | ConvertTo-Json -Depth 4 | Set-Content $globalManifestPath
    } finally {
        Exit-Lock -LockHandle $globalLock
    }
    Log "Updated global manifest."

    # --- Channel manifest, Channel Info refresh, and Final Video sync ---
    # All three grouped under ONE per-channel lock (lock file inside
    # $channelDir itself, so different channels never contend with each
    # other -- only videos from the SAME channel finishing around the same
    # time do). Grouped together rather than three separate locks because
    # the Final Video sync below reads $channelManifestPath and
    # $channelInfoDir right after they're written -- keeping the whole
    # sequence under one lock means Final Video always sees this video's
    # own channel-manifest update and never a half-written or
    # about-to-be-overwritten intermediate state from a concurrent sibling
    # video in the same channel. This section is pure local file I/O (no
    # network calls except the throttled Channel Info refresh, which most
    # invocations skip entirely), so serializing it costs negligible time
    # even at high worker counts -- the actual expensive, parallelizable
    # work (the comments fetch, the ffmpeg re-embed) all happens BEFORE
    # this point, unlocked.
    $channelLockPath = Join-Path $channelDir ".postprocess.lock"
    $channelLock = Enter-Lock -LockPath $channelLockPath
    try {
        # --- Channel manifest (#15) ---
        $channelManifestPath = Join-Path $channelDir "channel_manifest.json"
        $channelManifest = if (Test-Path $channelManifestPath) {
            Get-Content $channelManifestPath -Raw | ConvertFrom-Json
        } else { @() }
        $channelManifest = @($channelManifest | Where-Object { $_.video_id -ne $videoId })
        $channelManifest += [ordered]@{ video_id = $videoId; title = $title; upload_date = $uploadDate; url = $originalUrl; folder = $videoDir }
        $channelManifest | ConvertTo-Json -Depth 4 | Set-Content $channelManifestPath
        Log "Updated channel manifest."

        # --- Channel-level assets: avatar, banner, description, channel info.json ---
        # Lives outside the individual video folders, at the channel root, and is
        # refreshed (overwritten) every time a video from this channel finishes.
        try {
            $channelInfoDir = Join-Path $channelDir "Channel Info"
            if (!(Test-Path $channelInfoDir)) {
                New-Item -ItemType Directory -Path $channelInfoDir -Force | Out-Null
            }

            # Throttle: skip re-fetching if we already refreshed recently. This
            # matters most when running against a whole channel/playlist, so
            # we don't hit the channel's About page once per video in a
            # 100+ video run -- and now that this whole block is behind the
            # per-channel lock, the throttle check-then-act is also safe
            # against two workers both deciding "needs refresh" at once and
            # both clearing/repopulating Channel Info concurrently.
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
                # Join-Path (not a literal "\*" suffix, which only means anything
                # on Windows) so this works whichever OS this happens to run on.
                Remove-Item -Path (Join-Path $channelInfoDir "*") -Recurse -Force -ErrorAction SilentlyContinue

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

        # --- Sync the "Final Video" per-channel repository ---
        # A separate, flat "finished output" tree at Youtube Videos/Final Video/
        # <uploader>/, parallel to Complete Archive -- meant as the one place
        # to point a media player or another machine at, without pulling in
        # the full per-video folder tree (subtitles/description/checksums/etc)
        # that Complete Archive carries for every video. This is now the ONLY
        # "plain video" copy the pipeline maintains (the separate "Pure Video"
        # repository was removed -- it duplicated this folder's purpose almost
        # exactly, and having both was more confusing than useful). This also
        # carries a synced copy of that channel's manifest and Channel Info
        # assets, refreshed every run, plus a synced copy of the global
        # manifest at the repository root.
        try {
            $finalVideoRoot        = Join-Path $youtubeRoot "Final Video"
            $finalVideoChannelDir  = Join-Path $finalVideoRoot $uploader
            if (!(Test-Path $finalVideoChannelDir)) {
                New-Item -ItemType Directory -Path $finalVideoChannelDir -Force | Out-Null
            }

            # Full descriptive filename, built from the already-sanitized
            # folder name rather than reconstructed from raw (unsanitized)
            # info.json fields -- the folder name has already been through
            # yt-dlp's own filename sanitization, so reusing it avoids
            # re-doing (and potentially mismatching) that logic here.
            $finalVideoFileName = (Split-Path $videoDir -Leaf) + [System.IO.Path]::GetExtension($FilePath)
            Copy-Item -Path $FilePath -Destination (Join-Path $finalVideoChannelDir $finalVideoFileName) -Force

            if (Test-Path $channelManifestPath) {
                Copy-Item -Path $channelManifestPath -Destination (Join-Path $finalVideoChannelDir "channel_manifest.json") -Force
            }

            if (Test-Path $channelInfoDir) {
                $finalVideoChannelInfoDir = Join-Path $finalVideoChannelDir "Channel Info"
                if (Test-Path $finalVideoChannelInfoDir) {
                    Remove-Item -Path $finalVideoChannelInfoDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                Copy-Item -Path $channelInfoDir -Destination $finalVideoChannelInfoDir -Recurse -Force
            }

            # Read outside the global lock (which was already released
            # above) -- by this point the global manifest write for THIS
            # video is fully committed, so this is just copying a stable,
            # already-final file. A sibling video from a different channel
            # updating the global manifest at the same moment isn't a
            # correctness problem here, just eventual consistency: worst
            # case this copy is one video "behind," and the next video
            # processed anywhere in the archive corrects it.
            if (Test-Path $globalManifestPath) {
                Copy-Item -Path $globalManifestPath -Destination (Join-Path $finalVideoRoot "global_manifest.json") -Force
            }

            Log "Synced Final Video repository for $uploader."
        } catch {
            Log "WARNING: Failed to sync Final Video repository: $($_.Exception.Message)"
        }
    } finally {
        Exit-Lock -LockHandle $channelLock
    }

    # --- Trim empty leftover folders under _incomplete (#5) ---
    # yt-dlp mirrors the full per-video folder structure into the temp path
    # (same uploader/date/id/title nesting as the final destination), but it
    # has no built-in cleanup for the now-empty folders left behind once
    # files are moved to their final home. This is a known, unresolved
    # yt-dlp limitation (see yt-dlp/yt-dlp#11674), not something a config
    # flag can fix, so we sweep it ourselves after every video.
    try {
        # Sibling of "Complete Archive" under $youtubeRoot -- correctly
        # reflects this run's actual data root (default or custom).
        $incompleteRoot = Join-Path $youtubeRoot "_incomplete"
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
