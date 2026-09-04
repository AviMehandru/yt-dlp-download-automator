# The archive layout contract

`postprocess.ps1` writes a per-video folder tree. Other programs read it.
This file is the agreement between them.

It exists because not every reader lives in this repository any more.
`archive-viewer.py` ships alongside the pipeline and is covered by its test
suite; a separate desktop application is maintained in its own repository and
is not. For an in-repo reader, "don't break the layout" is enforced by
`050-postprocess` and `080-viewer` failing together. For an out-of-repo
reader, nothing enforces it at all — this repo's tests pass, that repo's tests
pass, and the first symptom is somebody's library coming up empty.

A version number does not prevent that. It converts it from silence into a
clear message.

## The current version

**`ARCHIVE_LAYOUT_VERSION = 1`**, defined as `$ArchiveLayoutVersion` at the
top of `scripts/postprocess.ps1` and written as `archive_layout_version`, the
first field of every `Video metadata/manifest.json`.

## What the contract covers

### The directory shape

```
<dataRoot>/
  Youtube Videos/
    Complete Archive/
      <Uploader>/
        Channel Info/                     channel-level assets, not a video
        channel_manifest.json
        <Uploader> - <YYYYMMDD> - <id> - <title>/
          Final files/                    Final Video.mkv, Link.*
          Pre-merge streams/              --keep-video's raw f<id> streams
          Subtitles/                      Subtitles.<lang>.vtt
          Images/                         thumbnail images
          URLs/                           urls.json
          Logs/                           video_complete.log, video_postprocessing.log
          Video metadata/                 Info.info.json, manifest.json, checksums.sha256
    Final Video/<Uploader>/               flat "point a player here" copies
    global_manifest.json
  Archive Logs/
    Logs/                                 download.log, archive.txt
    Archive History/                      timestamped snapshots
```

**The depth is load-bearing.** `postprocess.ps1` re-derives the data root by
walking up from the file it was handed, so every level above `Final files/`
is fixed. Consumers discover videos by walking
`Complete Archive/<Uploader>/<video folder>/` and reading the subfolders by
name.

### The video folder name

`<uploader> - <YYYYMMDD> - <id> - <title>`, separated by space-hyphen-space.

This is part of the contract, not an incidental. It is the documented
fallback for a video whose `info.json` is missing or unparseable — a real
state that real runs produce — so a consumer is entitled to parse it.

### manifest.json

Guaranteed present, with at least these fields:

| Field | Meaning |
|---|---|
| `archive_layout_version` | this contract's version |
| `archive_creation_time` | ISO 8601, when post-processing finished |
| `yt_dlp_version`, `ffmpeg_version` | tool versions used |
| `config_file_version` | `CONFIG_VERSION` from `yt-dlp.conf` |
| `video_id`, `title`, `uploader`, `upload_date` | identity |
| `original_url`, `channel_url` | provenance |
| `codecs`, `subtitle_languages` | what was captured |
| `every_filename`, `file_hashes` | inventory, paths `/`-separated |
| `comment_audit` | completeness of the comments pass |

### Things a consumer must tolerate

These are not edge cases; they occur in normal operation:

- **A missing or unparseable `info.json`.** Fall back to the folder name.
- **A folder with no video file at all.** An interrupted run leaves one.
- **`Pre-merge streams/`.** `--keep-video` leaves video-only and audio-only
  files there. A consumer choosing "the" video **must** skip that folder, or
  it will pick a silent video or a black audio track.
- **Path separators.** `every_filename` and `checksums.sha256` always use
  `/`, on every platform, deliberately, so a manifest written on Windows is
  readable on Linux.
- **`checksums.sha256` excludes `Logs/video_postprocessing.log`**, which is
  still being appended to when the hashes are computed. A consumer verifying
  the manifest must not treat its absence as a failure.

## What bumping means

Bump `$ArchiveLayoutVersion` when a change would make an existing reader
**wrong**:

- renaming or re-nesting any per-video subfolder
- changing the folder-name form
- removing a `manifest.json` field, or changing what an existing one means
- changing the path-separator or hashing conventions

Do **not** bump for changes that leave existing readers correct:

- adding a new `manifest.json` field
- adding a new file inside an existing subfolder
- anything under `Archive Logs/`, which no consumer contract covers

## The rule a consumer applies

Read `archive_layout_version` from a video's `manifest.json` and compare it
with the highest version that consumer understands.

- **Equal, or the manifest has no version field** — proceed. An absent field
  means the video predates versioning, which is layout 1 by definition.
- **Lower than the consumer's maximum** — proceed. Older layouts stay
  readable; that is the point of versioning rather than just documenting.
- **Higher** — do not guess. Show the user a clear message naming both
  numbers and telling them to update the consumer. An empty library with no
  explanation is the outcome this whole file exists to prevent.

A consumer should apply this per video, not per archive: an archive written
across an upgrade legitimately contains both versions.

## Where this is enforced

- `050-postprocess` asserts `manifest.json` carries `archive_layout_version`
  and that it matches the constant in `postprocess.ps1`.
- `080-viewer` asserts `archive-viewer.py` still discovers a fabricated tree.
- Out-of-repo consumers are expected to keep their own conformance test that
  builds a fixture tree in this shape and asserts their reader finds it. That
  test is what turns a bump into a build failure on their side rather than a
  bug report from a user.
