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
    [Parameter(Mandatory = $false)][string]$LogFileName = "download.log",

    # Which content mode produced this run. Defaults to "full", so a
    # standalone invocation of this script against an existing
    # "Final files/Final Video.mkv" behaves exactly as it always has --
    # the documented manual-repair path in CLAUDE.md keeps working
    # unchanged, with no new argument to remember.
    #
    # What this actually selects is WHICH FILE is the trigger for the run
    # (see the gate below): the merged video, the audio file, or -- when
    # no media is downloaded at all -- the info.json.
    [Parameter(Mandatory = $false)]
    [ValidateSet("full", "video-only", "audio-only", "metadata-only", "comments-only", "subs-only")]
    [string]$Mode = "full",

    # Skips the comments pass and its audit. Separate from -Mode because
    # it is orthogonal to it: "download everything but do not spend an
    # hour on comments" is a full-mode run.
    [Parameter(Mandatory = $false)][switch]$NoComments,

    # Base64-encoded JSON of the settings run_ytdlp.ps1 resolved for this
    # session, recorded verbatim into manifest.json. See the
    # run_settings field in docs/archive-layout.md for why the config
    # file's version number stopped being a sufficient record of what
    # produced a video.
    [Parameter(Mandatory = $false)][string]$RunSettingsB64 = ""
)

$ErrorActionPreference = "Stop"

# =====================================================================
# PLATFORM RESOLUTION
# =====================================================================
# Must match run_ytdlp.ps1's own platform block exactly -- this is the
# same install root, resolved the same way, and the two scripts disagreeing
# about where configs/ lives would silently produce a blank config version
# in every manifest. See run_ytdlp.ps1 for why Windows keeps C:/yt-dlp
# (MAX_PATH) rather than moving under $HOME like the Unix platforms.
#
# NOTE: only the INSTALL root is resolved here. The DATA root -- which may
# have been overridden with run_ytdlp.ps1's -DataRoot -- is derived from
# $FilePath's own ancestry further down instead, so it always reflects
# whichever data root this particular video actually landed in without
# needing that value passed in separately.
if ($IsWindows) {
    $defaultInstallRoot = "C:/yt-dlp"
} else {
    # Linux and macOS are identical here: $HOME/yt-dlp.
    $defaultInstallRoot = Join-Path $HOME "yt-dlp"
}
$installRoot = if ([string]::IsNullOrWhiteSpace($env:YTDLP_INSTALL_ROOT)) {
    $defaultInstallRoot
} else {
    $env:YTDLP_INSTALL_ROOT
}
# =====================================================================
# END PLATFORM RESOLUTION
# =====================================================================

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
# Deliberately NOT using the Unix `flock` binary: that would work on Linux
# and macOS, but Windows has no equivalent, and shelling out to
# flock -c "..." to wrap a block of PowerShell is awkward anyway (it means
# writing the block out to a temp script file just to invoke it under the
# lock). Opening a file with FileShare.None instead is a plain .NET
# primitive available identically on all three platforms -- a second
# process trying to open the same path the same way gets a normal
# IOException until the first one closes it, which is all a mutex needs to
# do here. This is advisory locking (it only blocks other code that also
# calls Enter-Lock/Exit-Lock around the same path) -- fine for this use,
# since every writer of these particular files is postprocess.ps1 itself.
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

# --- The archive layout contract ---
#
# The SHAPE of what this script writes -- the per-video folder tree, the
# names of the subfolders inside it, and the fields in manifest.json -- is
# consumed by readers that do not all live in this repository.
# archive-viewer.py is one and ships alongside; a separate desktop
# application is another and does not. Every one of them rediscovers videos
# by walking
#
#   Complete Archive/<Uploader>/<Uploader> - <date> - <id> - <title>/
#
# and reading Video metadata/, Final files/, Subtitles/ and Images/ by name.
#
# Until now that was an invariant held together by comments and by the fact
# that every reader lived in this repo and its test suite. A reader outside
# it has no such protection: change an -o template in yt-dlp.conf and that
# reader finds nothing, with no error anywhere -- its tests still pass, this
# repo's tests still pass, and the first sign of trouble is an empty library
# in somebody's window.
#
# So the layout now carries a version, recorded in every manifest.json.
# BUMP THIS whenever a change would make an existing reader wrong:
#   - renaming or re-nesting any per-video subfolder
#   - changing the "<uploader> - <date> - <id> - <title>" folder-name form
#   - removing a manifest.json field, or changing what an existing one means
# Adding a NEW manifest field is backward-compatible and needs no bump.
# See docs/archive-layout.md for the full contract and for the rule a
# consumer is expected to apply to this number.
#
# VERSION 2 (--mode): the media file is no longer always "Final Video.mkv".
#   - audio-only runs write "Final Audio.<ext>" instead of "Final Video.<ext>"
#   - a video's container is selectable, so the extension varies (.mkv,
#     .mp4, .webm) even when the base name does not
#   - metadata-only / comments-only / subs-only runs write a complete
#     per-video folder with NO media file in it at all
#
# The rename is what forces the bump: a layout-1 reader looks for
# "Final Video.*", finds nothing in an audio-only folder, and shows an
# empty entry rather than an error -- exactly the silent failure this
# number exists to convert into a loud one. The rule for a version-2
# reader is: find the media file by BASE NAME ("Final Video" or
# "Final Audio"), never by extension, and treat its absence as a valid
# state rather than a corrupt folder. manifest.json's media_file field
# gives it to you directly and should be preferred over globbing.
$ArchiveLayoutVersion = 2

$noMediaModes = @("metadata-only", "comments-only", "subs-only")
$isNoMedia    = $noMediaModes -contains $Mode
# "Final Video" for anything carrying a video stream, "Final Audio" for
# audio-only. Must agree with $mediaBaseName in run_ytdlp.ps1, which is
# what actually names the file via the -o template; 050-postprocess
# asserts the two agree.
$mediaBaseName = if ($Mode -eq "audio-only") { "Final Audio" } else { "Final Video" }

try {
    # The trigger file differs by mode, but its DEPTH does not, which is
    # what lets one derivation serve both:
    #
    #   media run:    .../<Uploader> - <Date> - <Id> - <Title>/Final files/Final Video.mkv
    #   no-media run: .../<Uploader> - <Date> - <Id> - <Title>/Video metadata/Info.info.json
    #
    # Both sit exactly two levels below the per-video folder, so $videoDir
    # is the trigger's grandparent either way. $finalFilesDir is then
    # composed from $videoDir rather than taken from the trigger's parent
    # -- in a no-media run the trigger's parent is "Video metadata", and
    # deriving it the old way would have pointed every later "Final files"
    # operation at the metadata folder instead.
    $triggerDir    = Split-Path $FilePath -Parent
    $videoDir      = Split-Path $triggerDir -Parent
    $finalFilesDir = Join-Path $videoDir "Final files"
    $channelDir    = Split-Path $videoDir -Parent
    $archiveDir    = Split-Path $channelDir -Parent          # .../Complete Archive
    $youtubeRoot   = Split-Path $archiveDir -Parent          # .../Youtube Videos
    $uploader      = Split-Path $channelDir -Leaf

    $videoMetaDir  = Join-Path $videoDir "Video metadata"
    $logsDir       = Join-Path $videoDir "Logs"
    $urlsDir       = Join-Path $videoDir "URLs"

    # $dataRoot is the parent of "Youtube Videos" -- derived from $FilePath
    # itself (via $youtubeRoot above), so this correctly reflects whichever
    # data root was actually used for THIS run (the platform default, or a
    # custom -DataRoot passed to run_ytdlp.ps1) without needing that value
    # passed in separately. $installRoot (where scripts/configs live) is a
    # different, fixed location regardless of -DataRoot -- resolved in the
    # platform block at the top rather than derived from $FilePath.
    $dataRoot = Split-Path $youtubeRoot -Parent

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
    # The gate is on the file's ROLE -- its base name -- not on its
    # extension. Extension was a sufficient test only while every run
    # produced exactly one kind of output; with a selectable container the
    # final file can legitimately be .mkv, .mp4 or .webm, with audio-only
    # it can be .m4a/.opus/.webm/.mp3/.flac, and with a no-media mode
    # there is no media file to key on at all. Testing "is this the file
    # this mode calls final" instead holds across all of those.
    #
    # The "[^.]+$" tail is what still excludes --keep-video's pre-merge
    # streams: those carry yt-dlp's format-id as an extra dotted segment
    # ("Final Video.f137.mp4"), so anything with a second dot after the
    # base name is a raw stream, not the final file.
    $triggerName = Split-Path $FilePath -Leaf
    if ($isNoMedia) {
        # No media is downloaded, so after_move never fires for a media
        # file. The info.json is the trigger instead -- it is written in
        # every no-media mode (run_ytdlp.ps1 forces it back on even under
        # --no-metadata precisely so this hook has something to fire on),
        # and it is written exactly once per video, which is what makes it
        # a safe single trigger. Subtitles and the description also get
        # moved in these modes and must NOT each start a second pass.
        if ($triggerName -notmatch '^Info\.info\.json$') {
            Log "Skipped: --mode $Mode is keyed off Info.info.json, and this invocation was for '$triggerName'. No further processing done for this invocation."
            return
        }
        Log "Mode '$Mode': no media file expected. Assembling the per-video folder from the metadata alone."
    } else {
        $mediaPattern = "^{0}\.[^.]+$" -f [regex]::Escape($mediaBaseName)
        if ($triggerName -notmatch $mediaPattern) {
            Log "Skipped: '$triggerName' is not this run's final media file ('$mediaBaseName.<ext>'). This is a --keep-video pre-merge stream or a sidecar. No further processing done for this invocation."
            return
        }
    }

    # --- Relocate --keep-video's pre-merge streams for clarity ---
    # --keep-video keeps the original, un-merged video-only and audio-only
    # streams alongside the final merged file, using the same "Final Video"
    # base name with yt-dlp's own format-id suffix inserted before the
    # extension (e.g. "Final Video.f137.mp4", "Final Video.f251.m4a").
    # Several near-identically-named files sitting in the same folder is
    # exactly what caused the "which one of these is actually final?"
    # confusion -- moving the pre-merge ones out leaves only the real final
    # file ("Final Video.mkv") at the top level of "Final files", with the
    # raw streams still kept nearby, just no longer easy to mistake for it.
    # This now lands as "Pre-merge streams/", a sibling of "Final files"
    # directly under the per-video folder (alongside Subtitles/, Images/,
    # Video metadata/), rather than a subfolder nested inside "Final files"
    # itself -- keeping "Final files" as a true single-purpose folder that
    # only ever holds the actual final output (Final Video.mkv, Link.*),
    # with the raw pre-merge streams treated as their own category
    # entirely, the same way subtitles or thumbnails are.
    # $mediaFilePath is the one variable the rest of this script should use
    # to mean "the finished media file", and it is deliberately NOT the
    # same thing as $FilePath any more: in a no-media mode $FilePath is the
    # info.json that triggered this run, and there is no media file at all.
    # Every step below that touches media is guarded on this being non-null
    # rather than on $FilePath's extension.
    $mediaFilePath = if ($isNoMedia) { $null } else { $FilePath }

    try {
        $preMergePattern = "^{0}\.f\S+\." -f [regex]::Escape($mediaBaseName)
        $preMergeFiles = if ($isNoMedia) { @() } else {
            Get-ChildItem -Path $finalFilesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -ne $mediaFilePath -and $_.Name -match $preMergePattern }
        }
        if ($preMergeFiles) {
            $preMergeDir = Join-Path $videoDir "Pre-merge streams"
            if (!(Test-Path $preMergeDir)) { New-Item -ItemType Directory -Path $preMergeDir -Force | Out-Null }
            foreach ($f in $preMergeFiles) {
                Move-Item -Path $f.FullName -Destination (Join-Path $preMergeDir $f.Name) -Force
            }
            Log "Moved $($preMergeFiles.Count) --keep-video pre-merge stream(s) into 'Pre-merge streams/' (sibling of 'Final files/') -- $(Split-Path $mediaFilePath -Leaf) is the only file remaining in Final files."
        }
    } catch {
        Log "WARNING: Could not relocate --keep-video pre-merge streams: $($_.Exception.Message)"
    }

    # --- Locate the matching info.json (retry briefly for FS/AV-scan lag) ---
    # The retry loop matters more on Windows than on the Unix platforms:
    # real-time antivirus scanning routinely holds a just-written file open
    # for a moment, so a file that definitely exists can still be briefly
    # unreadable. Harmless everywhere else -- the first iteration finds it.
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
        # from the folder name itself, which encodes uploader/date/id/title.
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
    # per invocation), where it's a perfect 1:1 copy. Under -Workers > 1
    # each worker has its own log (see $LogFileName above), which restores
    # the 1:1 property for parallel runs too.
    $mainDownloadLog = Join-Path (Join-Path (Join-Path $dataRoot "Archive Logs") "Logs") $LogFileName
    $completeLogFile = Join-Path $logsDir "video_complete.log"
    $sessionLines = $null
    if (Test-Path $mainDownloadLog) {
        $allLines = Get-Content -Path $mainDownloadLog
        $startMatch = $allLines | Select-String -Pattern '^==== Download session started' | Select-Object -Last 1
        if ($startMatch) {
            $sessionLines = $allLines[($startMatch.LineNumber - 1)..($allLines.Count - 1)]
            $sessionLines | Set-Content -Path $completeLogFile
            Log "Wrote video_complete.log (exact copy of this session from $LogFileName)."
        } else {
            Log "WARNING: No session-start marker found in $LogFileName; video_complete.log not written."
        }
    } else {
        Log "WARNING: $LogFileName not found at $mainDownloadLog; video_complete.log not written."
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
        if ($NoComments) {
            # Logged rather than silently skipped: the comments pass is
            # normally the longest single stage of a download, so its
            # absence is the most conspicuous difference in a run's timing
            # and the log should say why rather than leave it to be
            # inferred. comment_audit below records the same fact in the
            # manifest, so a consumer can tell "no comments were fetched"
            # apart from "this video has no comments".
            Log "Comments pass skipped: --no-comments was given for this run."
        } elseif ($originalUrl -and $infoJsonFile) {
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
            # --- Why --sleep-requests is 0.25 here and not 2 ---
            # This single number used to dominate the entire runtime of a
            # download. yt-dlp's comment extractor (_comment_entries in
            # yt_dlp/extractor/youtube/_video.py) does NOT fetch comments in
            # bulk: top-level comments arrive ~20 per continuation request,
            # but EVERY thread with paginated replies costs its own separate
            # HTTP request, because the extractor recurses into
            # _comment_entries(..., parent=comment_id) once per thread. So on
            # a reply-heavy video the request count tracks the number of
            # THREADS, not comments/20 -- a 2,000-comment video with ~1,200
            # reply-bearing threads is ~1,260 requests, not ~100.
            #
            # --sleep-requests then fires before EVERY ONE of those, inside
            # InfoExtractor._request_webpage (yt_dlp/extractor/common.py). At
            # the old value of 2 that was ~1,260 x (2s sleep + ~0.5s real
            # latency) = ~52 minutes, of which roughly 80% was this process
            # sleeping on purpose. A 35,000-comment video worked out to
            # ~22,000 requests and 15+ hours, which matched a real overnight
            # run that was still going after 14.
            #
            # 2 was never a YouTube requirement -- yt-dlp's own default is 0.
            # The comment endpoint is an unauthenticated InnerTube `next`
            # POST, considerably cheaper to serve than the player endpoint the
            # main download pass hits, so it tolerates far more than this.
            # 0.25 keeps a real (if small) gap between requests and still cuts
            # the comments pass by roughly 4-5x.
            #
            # NOTE: the --sleep-requests 2 in config/yt-dlp.conf is deliberately
            # left ALONE. That one governs the MAIN download pass, which makes
            # only a handful of extraction requests (player, formats, subs) and
            # whose reliability is worth far more than the couple of seconds
            # lowering it would save. This pass sets --ignore-config, so the two
            # values are genuinely independent -- do not "fix" the mismatch.
            #
            # If this ever needs raising again, the tell is the throttle check
            # below, not a hunch: watch for retry/incomplete-data lines, and for
            # the seconds-per-request figure logged at the end of this pass
            # drifting well above the sleep value.
            # The `--` before $originalUrl is the end-of-options marker; see
            # the long note at the single-stream call in run_ytdlp.ps1 for
            # why every yt-dlp invocation in this pipeline that takes a URL
            # carries one. It matters here even though $originalUrl comes
            # out of the info.json rather than off a command line: this pass
            # re-extracts the video, so an id beginning with a hyphen would
            # cost the comments of a video that had otherwise downloaded
            # perfectly -- a partial archive rather than a loud failure,
            # which is the worse of the two outcomes.
            $commentsSw = [System.Diagnostics.Stopwatch]::StartNew()
            $commentsOutput = & yt-dlp `
                --ignore-config `
                --skip-download `
                --write-comments `
                --write-info-json `
                --extractor-retries 100 `
                --retry-sleep "extractor:exp=1:30:2" `
                --sleep-requests 0.25 `
                -o (Join-Path $commentsTempDir "comments.%(ext)s") `
                -- `
                $originalUrl 2>&1 | ForEach-Object {
                    Log "  [comments] $_"
                    $_
                }
            $commentsSw.Stop()

            # --- Throttle / pacing telemetry ---
            # Counts the extractor's own per-request progress lines, so the
            # cost of this pass is recorded in real numbers rather than
            # guessed at afterwards. Seconds-per-request is the useful one: it
            # should sit a little above --sleep-requests above. If it climbs
            # well beyond that, YouTube is making requests wait (or the retry
            # backoff is firing), which means the sleep value is no longer what
            # sets the pace -- and raising it further would not help.
            # NOTE the '\[comments\]' anchor in all three filters below, and do
            # not remove it. Log() ends in Write-Output (so its lines bubble up
            # to the console and download.log via the launcher), which means
            # that inside the ForEach-Object above, BOTH the timestamped
            # "  [comments] <line>" copy AND the bare $_ get collected into
            # $commentsOutput. Every yt-dlp line is therefore in there exactly
            # twice, and an unanchored -match counts all of them twice: request
            # counts double, and seconds-per-request comes out at half its true
            # value. Anchoring on the prefix that only Log() adds picks exactly
            # one copy per real line. (This also guarantees a string to match
            # against -- 2>&1 puts ErrorRecord objects, not strings, into the
            # bare copies.) $commentIssues below had this bug too: its counts
            # were 2x reality for as long as the streaming-log change has been in.
            $commentRequests = @($commentsOutput | Where-Object { $_ -match '\[comments\].*Downloading comment.*API JSON' }).Count
            $commentsElapsed = $commentsSw.Elapsed.TotalSeconds
            if ($commentRequests -gt 0) {
                $secsPerReq = [math]::Round($commentsElapsed / $commentRequests, 2)
                Log ("Comments pass: {0} API request(s) in {1:N0}s ({2}s/request, --sleep-requests 0.25)." -f $commentRequests, $commentsElapsed, $secsPerReq)
            } else {
                Log ("Comments pass finished in {0:N0}s (no comment API requests detected)." -f $commentsElapsed)
            }

            # Retries and incomplete-data warnings are the actual signature of
            # YouTube pushing back; plain "warning" lines are not (a subtitle
            # 404 and similar land in the same bucket as a throttle otherwise).
            # Called out separately so real pushback is not lost in the noise.
            $throttleSignals = @($commentsOutput | Where-Object { $_ -match '(?i)\[comments\].*(incomplete data|retrying|too many requests|429|rate.?limit)' })
            if ($throttleSignals.Count -gt 0) {
                Log "WARNING: $($throttleSignals.Count) retry/throttle signal(s) during the comments pass -- if this recurs, raise --sleep-requests in postprocess.ps1 back toward 1."
            }

            $commentIssues = $commentsOutput | Where-Object { $_ -match '(?i)\[comments\].*(warn|error|unable|fail)' }
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

    # --- Comment completeness audit ---
    # yt-dlp cannot tell you whether it got all the comments. It has no
    # ground-truth count to check itself against, so a partial extraction
    # looks exactly like a complete one: no error, no warning, just fewer
    # comments in the file. That is not hypothetical -- yt-dlp/yt-dlp#15303
    # was precisely this, where YouTube's A/B-tested threaded comments view
    # caused silent extraction of 367 comments out of 684. Fixed upstream in
    # #15419 (and the fix is in the version this pipeline pins), but the
    # failure MODE is permanent: comment extraction is scraping, scraping
    # breaks quietly when YouTube changes its response shape, and an archive
    # that cannot detect the breakage inherits it forever.
    #
    # So: audit, do not re-fetch. This deliberately does NOT use the YouTube
    # Data API to download comments -- that path would cost real quota and
    # would lose is_pinned, is_favorited and author_is_verified, none of
    # which the API exposes at all. yt-dlp remains the only fetcher. All
    # this does is ask, for 1 quota unit, how many comments YouTube thinks
    # exist, and compare.
    #
    # The local invariants below cost nothing and run unconditionally, even
    # with no API key. The orphan-reply check is the sharpest of them: a
    # reply whose parent was never captured is proof of a mid-traversal gap,
    # detectable with no external call whatsoever.
    $commentAudit = [ordered]@{
        merged_count      = $null
        yt_dlp_reported   = $null
        api_comment_count = $null
        # 'skipped_by_request' distinguishes "we did not fetch comments"
        # from "we fetched and found none" -- without it, a --no-comments
        # run and a video with the comments disabled are indistinguishable
        # in the manifest, and only one of the two is worth re-running.
        api_status        = if ($NoComments) { 'skipped_by_request' } else { 'not_attempted' }
        shortfall_ratio   = $null
        tolerance         = $null
        duplicate_ids     = $null
        orphan_replies    = $null
        pinned_count      = $null
        audited_at        = (Get-Date).ToString('o')
    }
    try {
        # statistics.commentCount is an APPROXIMATION on YouTube's side -- it
        # is cached, it drifts, and it is not guaranteed to equal parents plus
        # replies exactly. Hence a percentage tolerance rather than an equality
        # check. 5% is loose enough to absorb that drift and still catch the
        # #15303-class failure by a wide margin (that one was 46% short). Both
        # raw numbers are recorded in manifest.json on every run, so the real
        # ratio can be calibrated from actual archive data instead of guessed.
        $auditTolerance = 0.05
        if ($env:YTDLP_COMMENT_AUDIT_TOLERANCE) {
            $parsedTol = 0.0
            if ([double]::TryParse($env:YTDLP_COMMENT_AUDIT_TOLERANCE, [ref]$parsedTol) -and $parsedTol -ge 0 -and $parsedTol -le 1) {
                $auditTolerance = $parsedTol
            } else {
                Log "WARNING: comment audit -- YTDLP_COMMENT_AUDIT_TOLERANCE is not a number between 0 and 1; using the 0.05 default."
            }
        }
        $commentAudit.tolerance = $auditTolerance

        $auditComments = @()
        if ($infoJsonFile -and (Test-Path $infoJsonFile.FullName)) {
            $auditInfo = Get-Content $infoJsonFile.FullName -Raw | ConvertFrom-Json
            # NOT @($auditInfo.comments) directly: if the property is absent
            # that yields a one-element array containing $null, and the count
            # comes out as 1 for a video with no comments at all.
            if ($auditInfo.comments) { $auditComments = @($auditInfo.comments) }
            $commentAudit.yt_dlp_reported = $auditInfo.comment_count
        }
        $commentAudit.merged_count = $auditComments.Count

        # --- Local invariants: zero quota, no network, always run ---
        if ($auditComments.Count -gt 0) {
            $auditIds = New-Object 'System.Collections.Generic.HashSet[string]'
            $auditDupes = 0
            foreach ($c in $auditComments) {
                if ($c.id -and -not $auditIds.Add([string]$c.id)) { $auditDupes++ }
            }
            $auditOrphans = 0
            foreach ($c in $auditComments) {
                $cParent = [string]$c.parent
                if ($cParent -and $cParent -ne 'root' -and -not $auditIds.Contains($cParent)) { $auditOrphans++ }
            }
            $auditPinned = @($auditComments | Where-Object { $_.is_pinned }).Count

            $commentAudit.duplicate_ids  = $auditDupes
            $commentAudit.orphan_replies = $auditOrphans
            $commentAudit.pinned_count   = $auditPinned

            if ($auditDupes -gt 0) {
                Log "WARNING: comment audit -- $auditDupes duplicate comment id(s) in the merged set."
            }
            if ($auditOrphans -gt 0) {
                Log "WARNING: comment audit -- $auditOrphans repl(ies) whose parent comment was never captured. That is an extraction gap, not a display quirk."
            }
            if ($auditPinned -gt 1) {
                Log "WARNING: comment audit -- $auditPinned comments flagged is_pinned, but YouTube allows at most one per video."
            }
        }

        # --- API cross-check: exactly 1 quota unit per video ---
        # Not attempted at all under --no-comments. The cross-check exists
        # to answer "did the fetch miss any comments"; with no fetch there
        # is nothing to compare, and spending a quota unit to discover
        # that the archive holds 0 of N comments would be a warning about
        # a deliberate choice. The local invariants above still ran, and
        # correctly report 0 merged with no orphans.
        $apiKey = $env:YTDLP_YOUTUBE_API_KEY
        if ($NoComments) {
            Log "Comment audit: API cross-check skipped -- no comments were fetched this run (--no-comments)."
        } elseif ([string]::IsNullOrWhiteSpace($apiKey)) {
            $commentAudit.api_status = 'no_key'
            Log "Comment audit: local checks only (set YTDLP_YOUTUBE_API_KEY to enable the API cross-check)."
        } elseif (-not $videoId) {
            $commentAudit.api_status = 'no_video_id'
            Log "WARNING: comment audit -- no video id resolved; API cross-check skipped."
        } else {
            try {
                # The key travels in the query string, which is the form the
                # Data API documents. That means it can appear inside whatever
                # exception message PowerShell builds from the request URI, so
                # every message logged from the catch below is passed through
                # an explicit redaction first. Never log $auditUri itself.
                $auditUri = "https://www.googleapis.com/youtube/v3/videos?part=statistics&id=$videoId&key=$apiKey"
                $auditResp = Invoke-RestMethod -Uri $auditUri -Method Get -TimeoutSec 30 -ErrorAction Stop
                $auditItem = @($auditResp.items) | Select-Object -First 1
                if (-not $auditItem) {
                    $commentAudit.api_status = 'video_not_found'
                    Log "WARNING: comment audit -- the API returned no such video (deleted, private, or region-blocked). Cross-check skipped."
                } elseif ($null -eq $auditItem.statistics.commentCount) {
                    $commentAudit.api_status = 'comment_count_unavailable'
                    Log "Comment audit: the API reports no comment count for this video (comments disabled or hidden)."
                } else {
                    $apiCount = [long]$auditItem.statistics.commentCount
                    $commentAudit.api_comment_count = $apiCount
                    $commentAudit.api_status = 'ok'
                    if ($apiCount -gt 0) {
                        $auditRatio = [math]::Round(1 - ($commentAudit.merged_count / $apiCount), 4)
                        # Clamp: archiving MORE than the reported count is normal
                        # (the statistic lags, and yt-dlp sees replies the count
                        # may not include). A negative shortfall is not a finding.
                        if ($auditRatio -lt 0) { $auditRatio = 0 }
                        $commentAudit.shortfall_ratio = $auditRatio
                        if ($auditRatio -gt $auditTolerance) {
                            Log ("WARNING: comment audit -- archived {0} of ~{1} comments the API reports ({2}% short, tolerance {3}%). Worth re-running the comments pass for this video." -f $commentAudit.merged_count, $apiCount, [math]::Round($auditRatio * 100, 1), [math]::Round($auditTolerance * 100, 1))
                        } else {
                            Log ("Comment audit: archived {0} vs ~{1} reported by the API -- within tolerance." -f $commentAudit.merged_count, $apiCount)
                        }
                    }
                }
            } catch {
                $auditMsg = $_.Exception.Message
                if ($apiKey) { $auditMsg = $auditMsg -replace [regex]::Escape($apiKey), '<redacted>' }
                $auditCode = $null
                try { $auditCode = [int]$_.Exception.Response.StatusCode } catch { }
                if ($auditCode -eq 403) {
                    $commentAudit.api_status = 'forbidden_or_quota'
                    Log "WARNING: comment audit -- API returned 403: daily quota exhausted, key restricted, or YouTube Data API v3 not enabled on the project. Audit skipped; the download itself is unaffected."
                } elseif ($auditCode -eq 400) {
                    $commentAudit.api_status = 'bad_request'
                    Log "WARNING: comment audit -- API returned 400, which almost always means YTDLP_YOUTUBE_API_KEY is malformed. Audit skipped; the download itself is unaffected."
                } else {
                    $commentAudit.api_status = 'error'
                    Log "WARNING: comment audit -- API call failed: $auditMsg"
                }
            }
        }
    } catch {
        $commentAudit.api_status = 'audit_failed'
        Log "WARNING: comment audit failed entirely: $($_.Exception.Message)"
    }

    # --- Re-embed the (now comment-complete) info.json into the .mkv ---
    # This is what --embed-info-json would normally do, done manually and
    # deferred until after the comments merge above. ffmpeg attaches the
    # updated info.json to the existing file -- -map 0 -c copy means this
    # is a container-level change only, no video/audio re-encoding, and it
    # preserves whatever's already attached (e.g. the embedded thumbnail).
    # Writes to a temp file first and only swaps it in on success, so a
    # failed remux can never leave you with a damaged or missing video.
    # Still .mkv-only, and deliberately so: Matroska is the only container
    # in the selectable set that carries arbitrary file attachments.
    # MP4 has no general attachment concept ffmpeg can write this way, and
    # WebM's spec omits the attachment elements Matroska defines. So
    # --container mp4/webm and every audio-only format keep the comments
    # in the sidecar info.json only, which is where the comment-complete
    # copy lives in every case anyway -- the embed is a convenience, not
    # the system of record. Logged explicitly below so the difference
    # between containers is visible in the log rather than surprising.
    try {
        if ($mediaFilePath -and $mediaFilePath -match '\.mkv$' -and $infoJsonFile) {
            # Count existing attachment-type streams so the mimetype tag
            # below targets ONLY the new one we're adding. Without an
            # explicit index, ffmpeg's "s:t" specifier matches every
            # attachment stream, which would mislabel the already-embedded
            # thumbnail as application/json too.
            $existingAttachCount = 0
            $probeOutput = & ffprobe -v error -select_streams t -show_entries stream=index -of csv=p=0 $mediaFilePath 2>&1
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
            $ffmpegOutput = & ffmpeg -y -i $mediaFilePath -attach $infoJsonFile.FullName -metadata:s:t:$existingAttachCount "mimetype=application/json" -map 0 -c copy $remuxTemp 2>&1 | ForEach-Object {
                Log "  [ffmpeg-reembed] $_"
                $_
            }

            if ((Test-Path $remuxTemp) -and (Get-Item $remuxTemp).Length -gt 0) {
                Remove-Item -Path $mediaFilePath -Force
                Move-Item -Path $remuxTemp -Destination $mediaFilePath -Force
                Log "Re-embedded comment-complete info.json into $mediaFilePath."
            } else {
                Log "WARNING: Re-embed produced no output file -- original left untouched. Comments are still in the sidecar info.json, just not embedded in the .mkv."
                Remove-Item -Path $remuxTemp -Force -ErrorAction SilentlyContinue
            }
        } elseif (-not $mediaFilePath) {
            Log "Skipped info.json re-embed: --mode $Mode downloaded no media file to embed into. The comment-complete info.json is in Video metadata/ as usual."
        } elseif ($mediaFilePath -notmatch '\.mkv$') {
            Log "Skipped info.json re-embed: only Matroska carries file attachments, and this run produced $(Split-Path $mediaFilePath -Leaf). The comment-complete info.json is in Video metadata/ as usual."
        }
    } catch {
        Log "WARNING: Re-embed of info.json failed: $($_.Exception.Message). Original file left untouched; comments are still in the sidecar info.json."
    }

    # --- Every file + hash under the video folder ---
    # video_postprocessing.log is deliberately EXCLUDED, and this fixes a
    # real defect rather than being a stylistic choice. That file is this
    # script's own live log: hashing it here captures its contents as of
    # this moment, and then the Log calls for the remaining six steps
    # (checksums written, manifest written, manifests updated, Channel Info,
    # Final Video sync, "Post-processing complete") append to it. Its
    # recorded hash was therefore guaranteed stale before the script even
    # exited -- every video ever produced had exactly one entry in
    # checksums.sha256 that could never verify. Confirmed with
    # `sha256sum -c`: 9 of 10 OK, video_postprocessing.log FAILED.
    #
    # That matters more than one wrong line. A checksum manifest that always
    # reports a failure teaches you to ignore its failures, which is the one
    # thing an integrity file must never do -- and it would mask a genuine
    # bit-rot or truncation finding among the noise. archive-viewer.py's own
    # default_cache_dir() takes pains to stay outside the archive for exactly
    # this reason, so the intent that these checksums actually verify is
    # already established elsewhere in the project.
    #
    # video_complete.log is NOT excluded: it is written once, in full,
    # earlier in this script and never appended to again, so its hash is
    # stable. The exclusion is specifically the file still being written.
    $selfLogRelPath = "Logs/video_postprocessing.log"
    $allFiles = Get-ChildItem -Path $videoDir -Recurse -File
    $fileHashes = [ordered]@{}
    $fileList = @()
    foreach ($f in $allFiles) {
        # Relative path, with the separator normalized to "/" regardless of
        # platform. Without this, the same video archived on Windows and on
        # Linux/macOS produces manifests and checksum files whose every key
        # differs only by "\" vs "/" -- which makes them non-comparable
        # across machines and breaks any consumer (archive-viewer.py
        # included) that looks a path up by name. "/" is the portable
        # choice: Windows accepts it everywhere as a path separator, so a
        # value read back from the manifest still resolves natively there.
        $rel = $f.FullName.Substring($videoDir.Length + 1).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
        if ($rel -eq $selfLogRelPath) { continue }
        $fileList += $rel
        $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash
        $fileHashes[$rel] = $hash
    }

    # --- Checksums file (#10) ---
    # Two-space separator between hash and path is the standard sha256sum
    # format, so this file can be verified directly with the system tool:
    #   sha256sum -c checksums.sha256    (Linux)
    #   shasum -a 256 -c checksums.sha256 (macOS)
    $checksumLines = $fileHashes.GetEnumerator() | ForEach-Object { "$($_.Value)  $($_.Key)" }
    $checksumLines | Set-Content (Join-Path $videoMetaDir "checksums.sha256")
    Log "Wrote checksums for $($fileList.Count) files."

    # --- Config version, tool versions ---
    # $installRoot (resolved in the platform block at the top), not
    # $dataRoot -- configs/ lives with the pipeline install, not with a
    # possibly-custom data root.
    $confPath = Join-Path (Join-Path $installRoot "configs") "yt-dlp.conf"
    $configVersion = $null
    if (Test-Path $confPath) {
        $m = Select-String -Path $confPath -Pattern "CONFIG_VERSION:\s*(\S+)" | Select-Object -First 1
        if ($m) { $configVersion = $m.Matches[0].Groups[1].Value }
    }
    $ytDlpVersion  = (& yt-dlp --version) 2>$null
    $ffmpegRaw     = (& ffmpeg -version) 2>$null
    $ffmpegVersion = if ($ffmpegRaw) { ($ffmpegRaw -split "`n")[0] } else { $null }
    # Get-CimInstance (which the old Windows-only copy of this script used)
    # is WMI-based and doesn't exist off Windows. $PSVersionTable.OS is a
    # built-in pwsh property that returns a descriptive OS version string
    # identically on all three platforms, so no branching is needed here at
    # all -- one of the several places where "cross-platform" cost nothing
    # more than picking the portable API in the first place.
    $osCaption     = $PSVersionTable.OS

    # --- The settings this run actually used ---
    # config_file_version alone stopped being a sufficient record of what
    # produced a video the moment a run could override the conf from the
    # command line. It is still recorded (and still means what it always
    # did -- which generation of the static baseline was installed), but a
    # consumer now needs the overrides on top of it to know what it is
    # looking at. Decoded defensively: a manifest missing this field is a
    # far better outcome than a video that fails to get a manifest at all.
    $runSettings = $null
    if ($RunSettingsB64) {
        try {
            $runSettings = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($RunSettingsB64)) | ConvertFrom-Json
        } catch {
            Log "WARNING: could not decode -RunSettingsB64; manifest run_settings will be null: $($_.Exception.Message)"
        }
    }

    # The media file's archive-relative path, or $null when the mode
    # downloaded none. Handed to consumers directly so they never have to
    # guess at the base name or glob for an extension -- which is the
    # whole reason the layout version went to 2. Computed from $videoDir
    # so it is in the same "/"-separated form as every_filename.
    $mediaFileRel = if ($mediaFilePath -and (Test-Path $mediaFilePath)) {
        $mediaFilePath.Substring($videoDir.Length + 1).Replace([System.IO.Path]::DirectorySeparatorChar, '/')
    } else { $null }

    # --- manifest.json (#8) ---
    $manifest = [ordered]@{
        # First field on purpose: a consumer that cannot understand this
        # layout should be able to find that out from the head of the file
        # rather than after parsing all of it.
        archive_layout_version = $ArchiveLayoutVersion
        archive_creation_time = (Get-Date).ToString("o")
        yt_dlp_version         = $ytDlpVersion
        ffmpeg_version          = $ffmpegVersion
        operating_system        = $osCaption
        config_file_version     = $configVersion
        # New in layout 2. download_mode says which of the six modes wrote
        # this folder; media_file names the media file (or is null, which
        # is a VALID state under layout 2, not a corrupt folder);
        # run_settings carries the per-run overrides that config_file_version
        # can no longer imply on its own.
        download_mode           = $Mode
        media_file              = $mediaFileRel
        run_settings            = $runSettings
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
        comment_audit           = $commentAudit
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
            # -Force is REQUIRED here, and its absence was a real bug.
            # PowerShell maps the Unix "leading dot means hidden" convention
            # onto the Hidden file attribute, and Get-Item without -Force
            # refuses to return a hidden item -- it throws "Could not find
            # item", even though Test-Path on the same path just returned
            # true. Every marker file in this pipeline is dot-prefixed, so
            # this hits all of them on Linux and macOS. It does NOT hit
            # Windows, where a leading dot carries no meaning, which is why
            # it survived unnoticed in a Windows-first codebase.
            #
            # The consequence here was worse than a missed optimization.
            # $ErrorActionPreference is "Stop" for this script, so the throw
            # escaped to this block's catch, meaning that from the moment
            # .last_refresh first existed, the Channel Info refresh was
            # never throttled AND never ran -- every subsequent video logged
            # "Channel Info refresh failed" and the marker was never
            # rewritten. Channel avatars, banners and descriptions silently
            # stopped being updated after the first video in each channel.
            # Only the read side is affected: Set-Content writes to a hidden
            # file (and creates one) perfectly well, which is why the marker
            # still appeared to be maintained.
            if (Test-Path $throttleMarker) {
                $age = (Get-Date) - (Get-Item $throttleMarker -Force).LastWriteTime
                if ($age.TotalHours -lt $throttleHours) { $needsRefresh = $false }
            }

            if (-not $channelUrl) {
                Log "No channel_url found in info.json -- skipped Channel Info refresh."
            } elseif (-not $needsRefresh) {
                Log "Channel Info refreshed within the last $throttleHours hours -- skipped."
            } else {
                # Only clear the folder once we're actually about to repopulate it.
                # Join-Path (not a literal "\*" suffix, which only means anything
                # on Windows) so this works whichever OS this happens to run on.
                Remove-Item -Path (Join-Path $channelInfoDir "*") -Recurse -Force -ErrorAction SilentlyContinue

                # `--` again, same rule as the comments pass above. A channel
                # URL built from a custom handle (/@-SomeChannel) is the case
                # this one guards.
                & yt-dlp `
                    --ignore-config `
                    --skip-download `
                    --flat-playlist `
                    --playlist-items 0 `
                    --write-info-json `
                    --write-all-thumbnails `
                    --write-description `
                    -o (Join-Path $channelInfoDir "channel.%(ext)s") `
                    -- `
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

            # The media copy is skipped, not faked, when the mode produced
            # no media. The manifest and Channel Info syncs below still run:
            # this repository is also where a media player finds the
            # channel's assets, and a metadata-only run legitimately
            # updates those. What must NOT happen is an empty or
            # placeholder file appearing here -- "point a media player at
            # this folder" is the entire contract of this tree, and a
            # zero-byte entry would break it more thoroughly than a missing
            # one.
            if ($mediaFilePath -and (Test-Path $mediaFilePath)) {
                # Full descriptive filename, built from the already-sanitized
                # folder name rather than reconstructed from raw (unsanitized)
                # info.json fields -- the folder name has already been through
                # yt-dlp's own filename sanitization, so reusing it avoids
                # re-doing (and potentially mismatching) that logic here.
                # The extension comes off the actual media file, so a
                # --container mp4 run or an audio-only .opus lands here with
                # the right one rather than an assumed .mkv.
                $finalVideoFileName = (Split-Path $videoDir -Leaf) + [System.IO.Path]::GetExtension($mediaFilePath)
                Copy-Item -Path $mediaFilePath -Destination (Join-Path $finalVideoChannelDir $finalVideoFileName) -Force
            } else {
                Log "Final Video repository: no media file to sync for --mode $Mode; channel manifest and Channel Info still refreshed."
            }

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