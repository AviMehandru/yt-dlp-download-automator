# archive-viewer.py — reading the archive, comments included

`ytdl` saves everything worth keeping. Nothing on disk shows you all of it at once,
and no media player will ever render a comment thread. This does.

It is a single Python 3 file with **no dependencies at all** — no pip, no venv, no
packaging step, matching the rest of this project. It starts a small web server on
your own machine and serves the archive as a browsable library.

`setup.sh` installs it to `~/yt-dlp/scripts/archive-viewer.py` and generates a
`ytdl-view` launcher on your `PATH`, so on a machine set up by the installer:

```bash
ytdl-view
```

Anywhere else — including the Windows/macOS host reading the archive over a shared
folder — run the file directly; nothing needs installing beyond `python3` itself:

```bash
python3 archive-viewer.py
```

Either way that auto-detects `~/yt-dlp`, prints a URL, and opens it. Everything else
is optional, and every flag below works identically through `ytdl-view`.

## What each video page gives you

- **The video**, with the archived subtitle tracks attached as selectable captions.
- **The full comment thread** — threaded, with replies collapsed under each parent;
  sortable by top / newest / oldest; searchable across every comment *and* reply,
  keeping threads intact; pinned, creator, verified and creator-hearted comments
  badged. Timestamps inside comment text ("the bit at 2:15") are clickable and seek
  the player.
- **A clickable transcript** built from the `.vtt` files, with the current line
  highlighted as the video plays, a search box, and a copy-everything button.
  YouTube's auto-caption format is a rolling two-line display where nearly every cue
  repeats the previous one; that duplication and the per-word `<c>` timing tags are
  stripped, so the result reads as prose rather than as subtitle soup.
- **The description**, with URLs linkified and timestamps turned into seek links.
- **Chapters**, from `info.json`, as a clickable list.
- **Metadata** — key facts, the actual streams inside the `.mkv` per ffprobe, tags,
  every thumbnail, the full `info.json`, plus `manifest.json` and `urls.json` as
  written by `postprocess.ps1`.
- **Files** — every file in the video's folder with its size, a download link, and an
  inline viewer for the text ones (including `video_postprocessing.log`, which is
  where you look when a video's comments are missing).

The library page has search across titles/channels/descriptions, a channel filter,
and sorting including **by comment count**.

## Playback, and why there is sometimes a "prepare" step

The pipeline merges to `.mkv`, and no browser plays the Matroska container. Two cases:

- **VP9 or AV1 video with Opus audio** — that combination inside Matroska is
  byte-identical to WebM, so the file streams straight out of the archive with a WebM
  content type. No copy, no wait, no disk used. This is the common case for
  `-f bv*+ba/b` on YouTube.
- **Anything else (typically H.264 + AAC)** — the page offers a one-click *container
  swap*: ffmpeg copies the existing video and audio streams into an MP4 with
  `-c copy`. Nothing is re-encoded, no quality is lost, and it usually takes seconds.
  The result goes in the viewer's cache, never in the archive.

Only if the codecs cannot go into an MP4 at all does it offer a real re-encode, and
it says so plainly first. `--no-transcode` removes that option entirely.

If your browser still cannot decode something, the page says so instead of showing a
black rectangle, and points you at the two lossless options: **Open in local player**
(needs `--allow-open-local`; prefers mpv, then VLC, then the system opener) or
**Download original**.

## The archive is never written to

Nothing is created, moved, or modified inside `Youtube Videos/`. Everything derived —
the metadata index, the split-out comment files, remuxed playback copies — lives in a
separate cache:

| OS | Cache location |
|---|---|
| Linux | `~/.cache/ytdlp-archive-viewer/` (or `$XDG_CACHE_HOME`) |
| macOS | `~/Library/Caches/ytdlp-archive-viewer/` |
| Windows | `%LOCALAPPDATA%\ytdlp-archive-viewer\` |

This matters specifically because `postprocess.ps1` writes a `checksums.sha256`
covering every file in a video folder. Dropping derived files in there would make
those checksums stop verifying for no reason. The cache is disposable — delete it any
time; the next run rebuilds it.

The cache also makes startup cheap. A first run parses every `info.json` once
(an 8 MB one with 20,000 comments takes about half a second) and splits the comments
into their own file; later runs read a small index instead. **Rescan** re-reads the
archive after new downloads; shift-clicking it ignores the cache entirely.

## Options

| Flag | What it does |
|---|---|
| `--root PATH` | Archive location. Accepts a data root (the folder holding `Youtube Videos`), the `Youtube Videos` folder, or `Complete Archive` itself. Use this for `ytdl --path` archives and mounted shares. |
| `--port N` | Default 8777. |
| `--host ADDR` | Default `127.0.0.1` — this machine only. See the LAN note below. |
| `--allow-open-local` | Let the page hand a file to mpv/VLC on this machine. Only honoured for requests from localhost. |
| `--no-transcode` | Never offer re-encoding; lossless container copies only. |
| `--cache-dir PATH` | Move the cache. |
| `--rescan` | Ignore the cached index and re-read every `info.json`. |
| `--ffmpeg` / `--ffprobe` | Explicit paths if they are not on `PATH`. |
| `--no-browser`, `--verbose`, `--version` | As they sound. |

## Running it on the Mac against the VM's archive

The viewer only needs to *read* the folder, so either machine works:

```bash
# on the Mac, against a shared/mounted archive
python3 archive-viewer.py --root "/Volumes/Media/yt-dlp" --allow-open-local
```

Copy the single `.py` file over and that is the whole install — there is deliberately
nothing else to set up on the host side.

ffmpeg is only needed for the container-swap path and for reading stream details. On a
Mac with no ffmpeg installed, everything else — library, comments, transcript,
metadata, downloads — still works; the viewer says as much on startup instead of
failing.

## `--host 0.0.0.0`

That serves to every device on your network **with no authentication of any kind**, and
it exposes every file in the archive to anyone who can reach the port. It is genuinely
useful for watching on a phone or TV on a home LAN, and genuinely a bad idea anywhere
else. It is not the default for that reason.

## Installation

The installer handles this on every platform, and from Step 7 onward it is the
same shared code doing it: Step 9 downloads `archive-viewer.py` alongside the
pipeline files, Step 11 copies it into the install root's `scripts/` folder and
writes the `ytdl-view` launcher, and Step 12 compiles it with `py_compile` as a
check that the download was not truncated. By hand it is two commands — see
[Step 11 of the setup guide](setup-guide.md#step-11-place-the-project-files).

The viewer is installed to `scripts/` rather than onto your `PATH` because it is a
program, not a command; `ytdl-view` is the command. It is one file shared by every
platform, like the rest of the pipeline — there is nothing OS-specific in it.

## Verification status

Unlike the rest of this project, this file *has* been run end to end. It was exercised
against a synthetic archive built to match the real layout — including a VP9/Opus mkv,
an H.264/AAC mkv, decoy pre-merge streams, rolling auto-captions, a corrupt
`info.json`, a folder with no video at all, and a 20,000-comment `info.json` — with
100 automated checks covering both the HTTP API (range requests, remux correctness
verified with ffprobe, path-traversal refusal) and the real UI driven in Chromium.

What that testing did *not* cover, and you should treat as unverified until you run it:
your actual archive's contents, and playback of an H.264/AAC file in a real browser
(the headless Chromium used for testing ships without the proprietary decoders that
Chrome, Safari and Firefox all have, so that path was verified at the HTTP and
file-format level rather than by an actual decode).
