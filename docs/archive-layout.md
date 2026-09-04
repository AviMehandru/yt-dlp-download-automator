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

**`ARCHIVE_LAYOUT_VERSION = 2`**, defined as `$ArchiveLayoutVersion` at the
top of `scripts/postprocess.ps1` and written as `archive_layout_version`, the
first field of every `Video metadata/manifest.json`.

### What changed in 2

Version 2 exists because `--mode` made the media file's name variable, where
version 1 could assume it was always `Final Video.mkv`.

- **Audio-only runs write `Final Audio.<ext>`**, not `Final Video.<ext>`.
- **The extension varies** even for video: `--container` selects `.mkv`,
  `.mp4` or `.webm`, and audio-only produces whatever the source stream is
  (`.m4a`, `.opus`, `.webm`) or whatever `--audio-codec` re-encoded it to.
- **A per-video folder may legitimately contain no media file at all.**
  `--mode metadata-only`, `comments-only` and `subs-only` write the complete
  folder — manifest, checksums, subfolders, comments — with no media in it.

The rename is what forces the bump. A version-1 reader globs for
`Final Video.*`, finds nothing in an audio-only folder, and renders an empty
entry with no error — precisely the silent failure this number converts into
a message.

**A version-2 reader must find the media file by base name, never by
extension**, and must treat its absence as a valid state rather than a
corrupt or interrupted folder. `manifest.json`'s `media_file` field gives the
answer directly and should be preferred over globbing at all.

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
          Final files/                    Final Video.<ext> OR Final Audio.<ext>
                                          (or neither), Link.*
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
| `config_file_version` | `CONFIG_VERSION` from `yt-dlp.conf` — the static baseline only |
| `download_mode` | *(2)* which `--mode` wrote this folder |
| `media_file` | *(2)* the media file's folder-relative path, or `null` |
| `run_settings` | *(2)* the per-run overrides; see below |
| `video_id`, `title`, `uploader`, `upload_date` | identity |
| `original_url`, `channel_url` | provenance |
| `codecs`, `subtitle_languages` | what was captured |
| `every_filename`, `file_hashes` | inventory, paths `/`-separated |
| `comment_audit` | completeness of the comments pass |

#### `run_settings`, and why `config_file_version` is no longer enough

`config_file_version` records which generation of the **static** baseline in
`config/yt-dlp.conf` was installed. Until `--mode`, that was a complete
description of how a video was produced, because nothing could vary between
runs.

Content options are now appended to the yt-dlp command line *after*
`--config-location`, where the later option wins. The conf is still never
rewritten — but its version number no longer implies the settings that were
actually in force. `run_settings` carries the difference:

| Key | Meaning |
|---|---|
| `mode` | the `--mode` value |
| `quality`, `codec`, `audio_codec`, `container` | the content options as resolved |
| `no_comments`, `no_subs`, `no_thumbnail`, `no_metadata` | component skips |
| `passthrough` | raw `--ytdlp-arg` values, in order |
| `effective_args` | the complete argument list appended after the conf |

Read `config_file_version` **and** `run_settings` together. Either alone is a
partial answer. `run_settings` may be `null` for a video written by a
standalone `postprocess.ps1` invocation, which is a valid state.

The full text of the conf at a given version is not duplicated into every
manifest — that would be tens of lines repeated per video forever. A
timestamped copy is written once per session into `Archive Logs/Archive
History/` instead, which is outside this contract and free to change.

### Things a consumer must tolerate

These are not edge cases; they occur in normal operation:

- **A missing or unparseable `info.json`.** Fall back to the folder name.
- **A folder with no media file at all.** Two different causes now, and a
  consumer should not try to tell them apart by guessing: an interrupted run
  leaves one, and so does any of the three no-media modes, on purpose.
  `download_mode` says which. Neither is corrupt.
- **A media file that is not `Final Video.mkv`.** *(2)* It may be
  `Final Video.mp4`, `Final Video.webm`, or `Final Audio.<anything>`. Match
  on the base name, or just read `media_file` from the manifest. Matching on
  `.mkv` was correct under layout 1 and is a bug under layout 2.
- **A video folder with no subtitles, no thumbnail, or no description.**
  The `--no-subs`, `--no-thumbnail` and `--no-metadata` skips each leave a
  folder that is complete and correct without them.
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
across an upgrade legitimately contains both versions — and after the 1→2
upgrade, most real archives do.

### Upgrading a reader from 1 to 2

Three changes, in the order they bite:

1. **Stop matching on `.mkv` or on `Final Video`.** Prefer `media_file` from
   the manifest; fall back to globbing `Final Video.*` and `Final Audio.*`,
   still excluding anything with a format-id segment (`Final Video.f137.mp4`)
   and still skipping `Pre-merge streams/`.
2. **Treat a missing media file as ordinary.** Render the entry from its
   metadata rather than hiding it or reporting corruption.
3. **Raise the maximum understood version to 2**, and keep reading layout-1
   videos exactly as before — where `media_file` is absent, `Final Video.mkv`
   is the correct assumption, because under layout 1 it always was.

## Where this is enforced

- `050-postprocess` asserts `manifest.json` carries `archive_layout_version`
  and that it matches the constant in `postprocess.ps1`.
- `080-viewer` asserts `archive-viewer.py` still discovers a fabricated tree.
- Out-of-repo consumers are expected to keep their own conformance test that
  builds a fixture tree in this shape and asserts their reader finds it. That
  test is what turns a bump into a build failure on their side rather than a
  bug report from a user.
