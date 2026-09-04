#!/usr/bin/env python3
# VIEWER_VERSION: 1
"""
archive-viewer.py -- a local, dependency-free viewer for the archive produced
by the yt-dlp-download-automator pipeline.

The pipeline already saves everything worth keeping (video, subtitles,
thumbnail, description, chapters, the full info.json *including the merged
comments*, manifests, checksums, logs) -- but nothing on disk can show you all
of it at once, and no normal media player will ever render a comment thread.
This does. Point it at the archive root, open the URL it prints, and every
video gets a page with the player, a clickable transcript, the description,
chapters, the complete threaded comment section, and the raw metadata.

Design notes / constraints this file deliberately honours:

  * Python 3.8+ standard library ONLY. No pip, no venv, no packaging step --
    the rest of this project has none either, and adding one for a viewer
    would be a poor trade.
  * ffmpeg/ffprobe are used when present but are NOT required to browse
    metadata or read comments. They already exist on any machine running the
    pipeline; on a Mac that is only *reading* a mounted archive, everything
    except in-browser playback of a non-WebM-safe .mkv still works without
    them.
  * The archive is treated as READ-ONLY. Nothing is ever written inside it.
    All derived state (the metadata index, split-out comment files, remuxed
    playback copies) lives in a separate cache directory, so the archive stays
    exactly as postprocess.ps1 left it and its checksums.sha256 keeps
    verifying.
  * The client never sends a filesystem path. Every request addresses content
    by an opaque key plus an index into a server-side file list, so there is
    no path-traversal surface to get wrong.

Why an on-demand remux exists at all: the pipeline merges to .mkv, and no
browser plays the Matroska container. When the streams inside are VP9/AV1 +
Opus the file is byte-for-byte WebM-compatible and is served directly with a
WebM content type (a real trick, not a hack -- WebM is a subset of Matroska).
Otherwise ffmpeg makes a stream-COPY .mp4 in the cache. Nothing is ever
re-encoded unless you explicitly ask for it, so no quality is lost and the
copy takes seconds rather than hours.

Usage:
    python3 archive-viewer.py                      # auto-detect ~/yt-dlp
    python3 archive-viewer.py --root /mnt/archive  # or point it anywhere
    python3 archive-viewer.py --host 0.0.0.0 --port 8777   # LAN (see --help)
"""

import argparse
import html
import http.server
import json
import mimetypes
import os
import platform
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from hashlib import sha1
from pathlib import Path

VIEWER_VERSION = "1.0"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

VIDEO_EXTS = (".mkv", ".mp4", ".webm", ".m4v", ".mov", ".avi", ".flv", ".ts")
# Archive layout 2: an audio-only run writes "Final Audio.<ext>" and there is
# no video file in the folder at all. ".webm" is deliberately absent here --
# it is already in VIDEO_EXTS, and a WebM holding only an Opus stream is
# found by the video pass and handled correctly downstream by plan(), which
# probes the actual streams rather than trusting the extension.
AUDIO_EXTS = (".m4a", ".opus", ".mp3", ".flac", ".ogg", ".oga", ".wav", ".aac")
IMAGE_EXTS = (".png", ".webp", ".jpg", ".jpeg", ".gif", ".avif")
SUB_EXTS = (".vtt", ".srt", ".ass", ".ssa", ".lrc", ".json3", ".srv1", ".srv2", ".srv3", ".ttml")


def find_media(entry):
    """The one place that decides which file to play for a video folder.

    Returns (index, file) like Entry.find, or (None, None) when the folder
    holds no playable media -- which under archive layout 2 is an ordinary
    state, not a broken folder: --mode metadata-only/comments-only/subs-only
    all write a complete folder with no media in it.

    Was five copies of the same lambda testing `f["ext"] in VIDEO_EXTS`.
    That was right while every run produced one merged video; layout 2 also
    writes "Final Audio.<ext>", and five copies is five chances to update
    only four of them.

    Two passes rather than one predicate, so the video preference is real
    rather than an accident of directory order -- Entry.find returns the
    first match in file order, so a single combined predicate would pick
    whichever of the two the filesystem happened to list first.

    `Pre-merge streams/` stays excluded for the reason it always was:
    --keep-video leaves the raw video-only and audio-only halves there, and
    picking one yields a silent video or a black screen, which reads as a
    corrupt archive rather than a wrong file choice.
    """
    def usable(f, exts):
        return f["ext"] in exts and "pre-merge" not in f["folder"].lower()

    idx, f = entry.find(lambda f: usable(f, VIDEO_EXTS))
    if idx is not None:
        return idx, f
    return entry.find(lambda f: usable(f, AUDIO_EXTS))

# info.json keys that are enormous and useless in a metadata panel. They are
# dropped from the cached copy; the UI says so rather than pretending the
# field never existed.
HEAVY_INFO_KEYS = ("comments", "formats", "automatic_captions", "heatmap",
                   "thumbnails", "subtitles")


def log(msg):
    print("[viewer] %s" % msg, flush=True)


def key_for(rel_path):
    """Stable, opaque, URL-safe id for a video folder.

    Derived from the archive-relative path rather than the video id, because
    the video id is not guaranteed to be parseable from the folder name for
    every extractor, and two folders could in principle carry the same id
    (a re-download into a different data root, for instance)."""
    return sha1(str(rel_path).encode("utf-8", "replace")).hexdigest()[:16]


def safe_json_load(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return json.load(fh)
    except Exception:
        # PowerShell's Set-Content writes a UTF-8 BOM on some hosts; json
        # chokes on it. utf-8-sig is a cheap second attempt before giving up.
        try:
            with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
                return json.load(fh)
        except Exception as exc:
            log("could not parse %s (%s)" % (path, exc))
            return None


def read_text(path, limit=None):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read() if limit is None else fh.read(limit)
    except Exception:
        return ""


def which(name, override=None):
    if override:
        p = Path(override).expanduser()
        return str(p) if p.exists() else None
    return shutil.which(name)


def dir_signature(paths):
    """Cheap change-detector for a video folder: size+mtime of the files the
    cache is derived from. Avoids re-parsing a 40 MB info.json on every start
    while still noticing a re-download that replaced it."""
    parts = []
    for p in paths:
        try:
            st = os.stat(p)
            parts.append("%s:%d:%d" % (os.path.basename(p), st.st_size, int(st.st_mtime)))
        except OSError:
            continue
    return sha1("|".join(parts).encode("utf-8")).hexdigest()[:20]


# ---------------------------------------------------------------------------
# Locating the archive
# ---------------------------------------------------------------------------

def looks_like_channel_dir(path):
    """A channel folder holds per-video folders named '<up> - <date> - <id> - <title>'
    and/or a 'Channel Info' folder."""
    try:
        entries = list(path.iterdir())
    except OSError:
        return False
    for e in entries[:60]:
        if not e.is_dir():
            continue
        if e.name == "Channel Info":
            return True
        if (e / "Final files").is_dir() or (e / "Video metadata").is_dir():
            return True
    return False


def resolve_archive_root(candidate):
    """Accept anything reasonable the user might point at and find the real
    'Complete Archive' directory underneath (or above) it."""
    if candidate is None:
        return None
    p = Path(candidate).expanduser()
    if not p.exists():
        return None
    p = p.resolve()

    tries = [
        p / "Youtube Videos" / "Complete Archive",   # a data root
        p / "Complete Archive",                      # the 'Youtube Videos' dir
        p,                                           # already Complete Archive
    ]
    for t in tries:
        if t.is_dir() and t.name == "Complete Archive":
            return t
    # Pointed straight at a channel folder, or at some other reorganisation of
    # the tree: walk up looking for a Complete Archive ancestor.
    for parent in [p] + list(p.parents):
        if parent.name == "Complete Archive" and parent.is_dir():
            return parent
    # Last resort: a directory whose children look like channel folders is
    # good enough to index, whatever it happens to be called.
    if p.is_dir():
        for child in list(p.iterdir())[:60]:
            if child.is_dir() and looks_like_channel_dir(child):
                return p
        if looks_like_channel_dir(p):
            return p.parent if p.parent.name == "Complete Archive" else p
    return None


def autodetect_root():
    home = Path.home()
    for c in (home / "yt-dlp", home / "Documents" / "yt-dlp", home, Path.cwd()):
        r = resolve_archive_root(c)
        if r:
            return r
    return None


# ---------------------------------------------------------------------------
# Subtitle parsing (WebVTT / SRT -> cue list, and SRT -> VTT)
# ---------------------------------------------------------------------------

TS_RE = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")
INLINE_TAG_RE = re.compile(r"</?[cvbiu][^>]*>|<\d{2}:\d{2}:\d{2}\.\d{3}>")


def parse_ts(text):
    m = TS_RE.match(text.strip())
    if not m:
        return None
    hours, mins, secs, ms = m.groups()
    return (int(hours or 0) * 3600 + int(mins) * 60 + int(secs)
            + int(ms.ljust(3, "0")) / 1000.0)


def parse_subtitle_cues(path):
    """Return [{'start': float, 'end': float, 'text': str}].

    YouTube's auto-generated VTT is a rolling two-line display: nearly every
    cue repeats the previous cue's last line, and words carry inline
    <00:00:01.234> karaoke timestamps. Read as-is it is unusable as a
    transcript, so tags are stripped and repeated lines are collapsed."""
    raw = read_text(path)
    if not raw:
        return []
    cues = []
    blocks = re.split(r"\n\s*\n", raw.replace("\r\n", "\n").replace("\r", "\n"))
    for block in blocks:
        lines = [ln for ln in block.split("\n") if ln.strip()]
        if not lines:
            continue
        time_idx = None
        for i, ln in enumerate(lines):
            if "-->" in ln:
                time_idx = i
                break
        if time_idx is None:
            continue
        left, _, right = lines[time_idx].partition("-->")
        start = parse_ts(left)
        end = parse_ts(right.strip().split(" ")[0]) if right.strip() else None
        if start is None:
            continue
        body = " ".join(lines[time_idx + 1:])
        body = INLINE_TAG_RE.sub("", body)
        body = html.unescape(body).strip()
        body = re.sub(r"\s+", " ", body)
        if not body:
            continue
        cues.append({"start": start, "end": end if end is not None else start + 3, "text": body})

    # Collapse the rolling-window duplication.
    cleaned = []
    for cue in cues:
        if cleaned:
            prev = cleaned[-1]
            if cue["text"] == prev["text"]:
                prev["end"] = max(prev["end"], cue["end"])
                continue
            # auto-caption case: the new cue is the previous one plus a tail
            if cue["text"].startswith(prev["text"]) and len(prev["text"]) > 12:
                tail = cue["text"][len(prev["text"]):].strip()
                if tail:
                    cleaned.append({"start": cue["start"], "end": cue["end"], "text": tail})
                else:
                    prev["end"] = max(prev["end"], cue["end"])
                continue
        cleaned.append(cue)
    return cleaned


def subtitle_is_auto(path):
    """Distinguish YouTube's auto-generated captions from human-written ones.

    The filenames cannot tell you: --write-subs and --write-auto-subs both land
    in Subtitles/ under the same 'Subtitles.<lang>.vtt' base name, so a name
    like 'Subtitles.en-orig.vtt' is not evidence either way. The file contents
    are: ASR output carries per-word <c> karaoke tags and cue-positioning
    directives that uploaded subtitle tracks do not."""
    head = read_text(path, 8000)
    return bool(re.search(r"<c[.>]|align:start position:", head))


def srt_to_vtt(path):
    body = read_text(path).replace("\r\n", "\n")
    body = re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", body)
    return "WEBVTT\n\n" + body


# ---------------------------------------------------------------------------
# The index
# ---------------------------------------------------------------------------

class VideoEntry(object):
    """One archived video: where its files are, and the light metadata the
    library grid needs. The heavy stuff (full info.json, comments) stays on
    disk in the cache and is only read when a page actually asks for it."""

    __slots__ = ("key", "root", "dir", "rel", "channel", "files", "meta",
                 "signature", "cache_dir")

    def __init__(self, key, root, directory):
        self.key = key
        self.root = root
        self.dir = directory
        self.rel = str(directory.relative_to(root))
        self.channel = directory.parent.name
        self.files = []
        self.meta = {}
        self.signature = ""
        self.cache_dir = None

    # -- file discovery ---------------------------------------------------
    def scan_files(self):
        found = []
        for dirpath, dirnames, filenames in os.walk(str(self.dir)):
            dirnames.sort()
            for name in sorted(filenames):
                full = Path(dirpath) / name
                try:
                    size = full.stat().st_size
                except OSError:
                    size = 0
                rel = str(full.relative_to(self.dir))
                found.append({"rel": rel.replace(os.sep, "/"), "size": size,
                              "ext": full.suffix.lower(),
                              "folder": (str(Path(dirpath).relative_to(self.dir))
                                         .replace(os.sep, "/") or ".")})
        self.files = found
        return found

    def find(self, predicate):
        for i, f in enumerate(self.files):
            if predicate(f):
                return i, f
        return None, None

    def path_for_index(self, idx):
        try:
            idx = int(idx)
        except (TypeError, ValueError):
            return None
        if idx < 0 or idx >= len(self.files):
            return None
        candidate = (self.dir / self.files[idx]["rel"]).resolve()
        # Belt and braces: the index came from our own list, but re-verify the
        # resolved path is still inside the video folder (a symlink inside the
        # archive could otherwise point anywhere).
        try:
            candidate.relative_to(self.dir.resolve())
        except ValueError:
            return None
        return candidate if candidate.is_file() else None


class Index(object):
    def __init__(self, root, cache_dir):
        self.root = root
        self.cache_dir = cache_dir
        self.entries = {}
        self.order = []
        self.channels = {}
        self.lock = threading.RLock()
        self.scanning = False
        self.scan_progress = {"done": 0, "total": 0, "current": ""}
        self.last_scan = 0

    # -- discovery --------------------------------------------------------
    def discover_dirs(self):
        out = []
        try:
            channels = sorted([c for c in self.root.iterdir() if c.is_dir()],
                              key=lambda p: p.name.lower())
        except OSError as exc:
            log("cannot read archive root: %s" % exc)
            return out
        for channel in channels:
            try:
                children = sorted([v for v in channel.iterdir() if v.is_dir()],
                                  key=lambda p: p.name.lower())
            except OSError:
                continue
            for vd in children:
                if vd.name == "Channel Info":
                    continue
                if (vd / "Video metadata").is_dir() or (vd / "Final files").is_dir():
                    out.append(vd)
                    continue
                # Tolerate a flatter layout (someone reorganised, or an older
                # pipeline version): any folder directly holding a video file
                # counts.
                try:
                    if any(f.suffix.lower() in VIDEO_EXTS for f in vd.iterdir() if f.is_file()):
                        out.append(vd)
                except OSError:
                    pass
        return out

    def scan(self, force=False):
        with self.lock:
            if self.scanning:
                return
            self.scanning = True
        try:
            dirs = self.discover_dirs()
            self.scan_progress = {"done": 0, "total": len(dirs), "current": ""}
            entries, order = {}, []
            for i, vd in enumerate(dirs):
                self.scan_progress["done"] = i
                self.scan_progress["current"] = vd.name
                try:
                    entry = self.build_entry(vd, force=force)
                except Exception as exc:
                    log("skipping %s (%s)" % (vd.name, exc))
                    continue
                entries[entry.key] = entry
                order.append(entry.key)
            with self.lock:
                self.entries = entries
                self.order = order
                self.channels = self.build_channels()
                self.last_scan = time.time()
            self.scan_progress = {"done": len(dirs), "total": len(dirs), "current": ""}
            log("indexed %d video(s) across %d channel(s)" % (len(order), len(self.channels)))
        finally:
            self.scanning = False

    def build_channels(self):
        chans = {}
        for key in self.order:
            e = self.entries[key]
            c = chans.setdefault(e.channel, {"name": e.channel, "count": 0,
                                             "avatar": None, "banner": None,
                                             "description": None, "url": None})
            c["count"] += 1
            if not c["url"]:
                c["url"] = e.meta.get("channel_url")
        # Channel Info assets, written by postprocess.ps1's throttled refresh.
        for name, info in chans.items():
            cdir = self.root / name / "Channel Info"
            if not cdir.is_dir():
                continue
            try:
                for f in cdir.iterdir():
                    low = f.name.lower()
                    if f.suffix.lower() in IMAGE_EXTS:
                        if "avatar" in low and not info["avatar"]:
                            info["avatar"] = f.name
                        elif "banner" in low and not info["banner"]:
                            info["banner"] = f.name
                    elif low.endswith((".description", ".txt")) and not info["description"]:
                        info["description"] = read_text(f, 20000)
            except OSError:
                pass
        return chans

    # -- per-video cache ---------------------------------------------------
    def build_entry(self, video_dir, force=False):
        rel = video_dir.relative_to(self.root)
        entry = VideoEntry(key_for(rel), self.root, video_dir)
        entry.scan_files()
        entry.cache_dir = self.cache_dir / "videos" / entry.key
        info_idx, info_file = entry.find(lambda f: f["rel"].endswith(".info.json"))
        manifest_idx, _ = entry.find(lambda f: f["rel"].endswith("manifest.json"))

        sig_sources = []
        if info_file:
            sig_sources.append(str(video_dir / info_file["rel"]))
        sig_sources.append(str(video_dir))
        entry.signature = dir_signature(sig_sources) + ":%d" % len(entry.files)

        cached = None
        light_path = entry.cache_dir / "light.json"
        if not force and light_path.exists():
            cached = safe_json_load(light_path)
            if not cached or cached.get("_sig") != entry.signature:
                cached = None
        if cached is None:
            cached = self.rebuild_cache(entry, info_file)
        entry.meta = cached
        return entry

    def rebuild_cache(self, entry, info_file):
        entry.cache_dir.mkdir(parents=True, exist_ok=True)
        info = None
        if info_file:
            info = safe_json_load(entry.dir / info_file["rel"])
        if info is None:
            info = {}

        comments = info.get("comments") or []
        # Comments are written to their own file so the (potentially very
        # large) info.json is never re-read to answer a comments request.
        try:
            with open(entry.cache_dir / "comments.json", "w", encoding="utf-8") as fh:
                json.dump(comments, fh, ensure_ascii=False)
        except Exception as exc:
            log("could not cache comments for %s (%s)" % (entry.rel, exc))

        stripped = {}
        dropped = []
        for k, v in info.items():
            if k in HEAVY_INFO_KEYS:
                if v:
                    dropped.append(k)
                continue
            stripped[k] = v
        try:
            with open(entry.cache_dir / "info.json", "w", encoding="utf-8") as fh:
                json.dump({"info": stripped, "dropped": dropped}, fh, ensure_ascii=False)
        except Exception as exc:
            log("could not cache metadata for %s (%s)" % (entry.rel, exc))

        # Fall back to the folder name when info.json is missing or unreadable
        # -- '<uploader> - <date> - <id> - <title>' is a documented, stable
        # part of this pipeline's layout, so it is a genuine source of truth,
        # not a guess.
        title = info.get("title")
        upload_date = info.get("upload_date")
        video_id = info.get("id")
        uploader = info.get("uploader") or info.get("channel")
        if not (title and upload_date and video_id):
            m = re.match(r"^(.*?) - (\d{8}) - ([^ ]+) - (.*)$", entry.dir.name)
            if m:
                uploader = uploader or m.group(1)
                upload_date = upload_date or m.group(2)
                video_id = video_id or m.group(3)
                title = title or m.group(4)
        light = {
            "_sig": entry.signature,
            "key": entry.key,
            "rel": entry.rel,
            "folder_name": entry.dir.name,
            "channel_folder": entry.channel,
            "id": video_id,
            "title": title or entry.dir.name,
            "uploader": uploader or entry.channel,
            "channel_url": info.get("channel_url") or info.get("uploader_url"),
            "upload_date": upload_date,
            "timestamp": info.get("timestamp") or info.get("release_timestamp"),
            "duration": info.get("duration"),
            "view_count": info.get("view_count"),
            "like_count": info.get("like_count"),
            "comment_count": info.get("comment_count") or len(comments),
            "comments_cached": len(comments),
            "description": info.get("description") or "",
            "categories": info.get("categories") or [],
            "tags": info.get("tags") or [],
            "chapters": info.get("chapters") or [],
            "webpage_url": info.get("webpage_url") or info.get("original_url"),
            "resolution": info.get("resolution"),
            "fps": info.get("fps"),
            "vcodec": info.get("vcodec"),
            "acodec": info.get("acodec"),
            "live_status": info.get("live_status"),
            "age_limit": info.get("age_limit"),
            "language": info.get("language"),
            "has_info_json": bool(info_file),
            "dropped_keys": dropped,
            "files": entry.files,
        }
        # Description file on disk wins if info.json had none (it is the same
        # text, but a run that lost its info.json still has the .description).
        if not light["description"]:
            _, desc = entry.find(lambda f: f["rel"].endswith(".description"))
            if desc:
                light["description"] = read_text(entry.dir / desc["rel"], 200000)
        try:
            with open(entry.cache_dir / "light.json", "w", encoding="utf-8") as fh:
                json.dump(light, fh, ensure_ascii=False)
        except Exception as exc:
            log("could not write index cache for %s (%s)" % (entry.rel, exc))
        return light

    # -- access -----------------------------------------------------------
    def get(self, key):
        with self.lock:
            return self.entries.get(key)

    def library(self):
        with self.lock:
            out = []
            for key in self.order:
                e = self.entries[key]
                m = e.meta
                thumb_idx, _ = e.find(lambda f: f["ext"] in IMAGE_EXTS
                                      and "thumbnail" in f["rel"].lower())
                vid_idx, _ = find_media(e)
                subs = [f for f in e.files if f["ext"] in SUB_EXTS]
                out.append({
                    "key": key,
                    "title": m.get("title"),
                    "uploader": m.get("uploader"),
                    "channel_folder": e.channel,
                    "id": m.get("id"),
                    "upload_date": m.get("upload_date"),
                    "duration": m.get("duration"),
                    "view_count": m.get("view_count"),
                    "like_count": m.get("like_count"),
                    "comment_count": m.get("comments_cached"),
                    "resolution": m.get("resolution"),
                    "description": (m.get("description") or "")[:400],
                    "has_thumb": thumb_idx is not None,
                    "thumb_idx": thumb_idx,
                    "has_video": vid_idx is not None,
                    "sub_count": len(subs),
                    "file_count": len(e.files),
                })
            return out


# ---------------------------------------------------------------------------
# Playback: probing, WebM-safe passthrough, and stream-copy remux
# ---------------------------------------------------------------------------

# Codec sets a browser can play. VP8/VP9/AV1 + Opus/Vorbis in a Matroska file
# is bit-identical to WebM, so it can be served straight from the archive with
# a WebM content type -- no ffmpeg, no copy, no disk cost.
WEBM_VIDEO = {"vp8", "vp9", "av01", "av1"}
WEBM_AUDIO = {"opus", "vorbis"}
# Encoder profiles for the ONE path that actually re-encodes, in descending
# order of preference. The first whose video AND audio encoders both exist in
# this ffmpeg build is the one used.
#
# libx264 is not universally available, and that is not an exotic edge case:
# it is an EXTERNAL library that distributions with patent concerns leave
# out, so Fedora's stock ffmpeg-free -- what `dnf install ffmpeg` gives you
# without RPM Fusion -- has no libx264 at all. A hardcoded libx264 meant the
# transcode button failed there with "Unknown encoder 'libx264'", which is
# opaque unless you already know why.
#
# The rest of this program is unaffected by any of that, because nothing else
# here encodes anything: WebM-compatible Matroska is served straight from the
# archive, and everything MP4-copyable is `-c copy`. Only this list needed to
# learn that ffmpeg builds differ.
#
# openh264 comes second because it keeps the output in MP4/h264 -- same
# container, same compatibility, just Cisco's encoder instead of x264 -- and
# Fedora enables it by default. VP9 and VP8 in WebM are the last resorts:
# royalty-free, so present in essentially every build, and playable in every
# modern browser, at the cost of a slower encode.
TRANSCODE_PROFILES = [
    {"name": "h264 (libx264) in MP4",
     "video": ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"],
     "audio": ["-c:a", "aac", "-b:a", "192k"],
     "vencoder": "libx264", "aencoder": "aac",
     "mux": ["-movflags", "+faststart", "-f", "mp4"], "ext": "mp4", "mime": "video/mp4"},
    {"name": "h264 (libopenh264) in MP4",
     "video": ["-c:v", "libopenh264", "-pix_fmt", "yuv420p"],
     "audio": ["-c:a", "aac", "-b:a", "192k"],
     "vencoder": "libopenh264", "aencoder": "aac",
     "mux": ["-movflags", "+faststart", "-f", "mp4"], "ext": "mp4", "mime": "video/mp4"},
    {"name": "VP9 + Opus in WebM",
     # -b:v 0 is what makes -crf constant-quality rather than a ceiling on a
     # bitrate that was never set; -row-mt and -cpu-used keep libvpx-vp9 from
     # being unusably slow at default settings.
     "video": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0",
               "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
               "-pix_fmt", "yuv420p"],
     "audio": ["-c:a", "libopus", "-b:a", "128k"],
     "vencoder": "libvpx-vp9", "aencoder": "libopus",
     "mux": ["-f", "webm"], "ext": "webm", "mime": "video/webm"},
    {"name": "VP8 + Opus in WebM",
     "video": ["-c:v", "libvpx", "-crf", "10", "-b:v", "1M", "-pix_fmt", "yuv420p"],
     "audio": ["-c:a", "libopus", "-b:a", "128k"],
     "vencoder": "libvpx", "aencoder": "libopus",
     "mux": ["-f", "webm"], "ext": "webm", "mime": "video/webm"},
]


# What an MP4 can legally carry AND a browser will decode, so `-c copy` works.
MP4_VIDEO = {"h264", "avc1", "hevc", "h265", "av01", "av1", "vp9"}
MP4_AUDIO = {"aac", "mp3", "opus", "flac", "alac", "mp4a"}


class MediaManager(object):
    """Decides how each video can be played, and produces a remuxed copy when
    the browser cannot read the original container.

    Nothing here is ever re-encoded unless the user explicitly asks for it:
    the default path is `-c copy`, which rewrites the container and leaves
    every compressed byte of video and audio untouched."""

    def __init__(self, cache_dir, ffmpeg, ffprobe, allow_transcode=True):
        self.cache_dir = cache_dir
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.allow_transcode = allow_transcode
        self.jobs = {}
        self.probes = {}
        self.lock = threading.Lock()
        self._encoders = None
        self._profile = False   # False = not yet resolved; None = none usable
        (self.cache_dir / "media").mkdir(parents=True, exist_ok=True)

    # -- what this ffmpeg can actually encode ------------------------------
    def encoders(self):
        """Encoder names this ffmpeg build has, read once and cached."""
        if self._encoders is not None:
            return self._encoders
        names = set()
        if self.ffmpeg:
            try:
                out = subprocess.run([self.ffmpeg, "-hide_banner", "-encoders"],
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, timeout=30)
                for line in out.stdout.decode("utf-8", "replace").splitlines():
                    # Rows look like " V....D libx264   libx264 H.264 ..."
                    parts = line.split()
                    if len(parts) >= 2 and len(parts[0]) == 6 and parts[0][0] in "VAS":
                        names.add(parts[1])
            except Exception as exc:
                log("could not list ffmpeg encoders (%s)" % exc)
        self._encoders = names
        return names

    def transcode_profile(self):
        """The first profile this ffmpeg can actually run, or None."""
        if self._profile is not False:
            return self._profile
        available = self.encoders()
        chosen = None
        for prof in TRANSCODE_PROFILES:
            if prof["vencoder"] in available and prof["aencoder"] in available:
                chosen = prof
                break
        if chosen:
            log("transcode profile: %s" % chosen["name"])
        elif self.ffmpeg:
            log("no usable transcode profile -- this ffmpeg has none of: %s"
                % ", ".join(p["vencoder"] for p in TRANSCODE_PROFILES))
        self._profile = chosen
        return chosen

    # -- probing ----------------------------------------------------------
    def probe(self, path):
        stat_key = None
        try:
            st = os.stat(path)
            stat_key = "%s:%d:%d" % (path, st.st_size, int(st.st_mtime))
        except OSError:
            return None
        with self.lock:
            if stat_key in self.probes:
                return self.probes[stat_key]
        result = {"ok": False, "video": None, "audio": None, "vindex": 0,
                  "aindex": 0, "duration": None, "streams": [], "container": ""}
        if self.ffprobe:
            try:
                out = subprocess.run(
                    [self.ffprobe, "-v", "quiet", "-print_format", "json",
                     "-show_streams", "-show_format", str(path)],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
                data = json.loads(out.stdout.decode("utf-8", "replace") or "{}")
                streams = data.get("streams") or []
                result["container"] = (data.get("format") or {}).get("format_name", "")
                try:
                    result["duration"] = float((data.get("format") or {}).get("duration"))
                except (TypeError, ValueError):
                    pass
                vcount = acount = 0
                for s in streams:
                    kind = s.get("codec_type")
                    entry = {"type": kind, "codec": s.get("codec_name"),
                             "index": s.get("index"),
                             "lang": (s.get("tags") or {}).get("language"),
                             "title": (s.get("tags") or {}).get("title"),
                             "filename": (s.get("tags") or {}).get("filename")}
                    if kind == "video":
                        # --embed-thumbnail leaves a cover image behind as a
                        # video stream on some containers; picking it as "the"
                        # video stream would remux a still image.
                        attached = (s.get("disposition") or {}).get("attached_pic")
                        entry["attached_pic"] = bool(attached)
                        entry["width"] = s.get("width")
                        entry["height"] = s.get("height")
                        if not attached and result["video"] is None:
                            result["video"] = (s.get("codec_name") or "").lower()
                            result["vindex"] = vcount
                        if not attached:
                            vcount += 1
                    elif kind == "audio":
                        entry["channels"] = s.get("channels")
                        if result["audio"] is None:
                            result["audio"] = (s.get("codec_name") or "").lower()
                            result["aindex"] = acount
                        acount += 1
                    result["streams"].append(entry)
                result["ok"] = True
            except Exception as exc:
                log("ffprobe failed on %s (%s)" % (path, exc))
        with self.lock:
            self.probes[stat_key] = result
        return result

    def plan(self, path):
        """How should this file be played? Returns a dict the UI can act on."""
        ext = path.suffix.lower()
        if ext in (".mp4", ".m4v", ".webm"):
            return {"mode": "direct", "mime": mimetypes.guess_type(path.name)[0]
                    or "video/mp4", "reason": "Container is natively supported."}
        probe = self.probe(path)
        v = (probe or {}).get("video") or ""
        a = (probe or {}).get("audio") or ""
        if not (probe and probe.get("ok")):
            # No ffprobe available. .mkv is still very often VP9/Opus from this
            # pipeline's `-f bv*+ba/b`, so offering the WebM gamble beats
            # refusing to play anything at all -- but say so honestly.
            return {"mode": "direct", "mime": "video/webm",
                    "reason": "ffprobe unavailable -- serving the .mkv as WebM. "
                              "This works if the streams are VP9/AV1 + Opus and "
                              "silently fails otherwise.",
                    "uncertain": True}
        if v in WEBM_VIDEO and a in WEBM_AUDIO:
            return {"mode": "direct", "mime": "video/webm",
                    "reason": "%s + %s in Matroska is byte-compatible with WebM, "
                              "so it streams straight from the archive." % (v, a)}
        if v in MP4_VIDEO and a in MP4_AUDIO:
            return {"mode": "remux", "mime": "video/mp4",
                    "reason": "%s + %s can be copied into MP4 without "
                              "re-encoding." % (v or "?", a or "?")}
        why = ("%s + %s cannot be copied into a browser-playable container; "
               "playing it here needs a real re-encode." % (v or "?", a or "?"))
        if not self.allow_transcode:
            return {"mode": "unsupported", "mime": "video/mp4", "reason": why}
        prof = self.transcode_profile()
        if not prof:
            # Better to say this than to offer a button that fails on click.
            return {"mode": "unsupported", "mime": "video/mp4",
                    "reason": why + " This ffmpeg build has no encoder this "
                                    "viewer can use -- on Fedora and similar, "
                                    "install the full ffmpeg (RPM Fusion) or a "
                                    "build with libx264, libopenh264 or libvpx."}
        return {"mode": "transcode", "mime": prof["mime"],
                "profile": prof["name"],
                "reason": why + " Re-encoding as %s." % prof["name"]}

    # -- remux / transcode -------------------------------------------------
    def output_path(self, key, mode):
        # Remux is only ever chosen for MP4-copyable streams, so it is always
        # .mp4. Transcode follows whichever profile this build resolved to,
        # which may be WebM -- the extension has to match or the file is
        # served with the wrong type.
        ext = "mp4"
        if mode == "transcode":
            prof = self.transcode_profile()
            if prof:
                ext = prof["ext"]
        return self.cache_dir / "media" / ("%s.%s.%s" % (key, mode, ext))

    def status(self, key, src, mode):
        out = self.output_path(key, mode)
        if out.exists():
            try:
                if out.stat().st_mtime >= os.stat(src).st_mtime and out.stat().st_size > 0:
                    return {"state": "ready", "progress": 1.0}
            except OSError:
                pass
        with self.lock:
            job = self.jobs.get((key, mode))
        if job:
            return dict(job)
        return {"state": "idle", "progress": 0.0}

    def start(self, key, src, mode, duration=None):
        with self.lock:
            job = self.jobs.get((key, mode))
            if job and job.get("state") == "running":
                return dict(job)
            self.jobs[(key, mode)] = {"state": "running", "progress": 0.0, "error": None}
        t = threading.Thread(target=self._run, args=(key, src, mode, duration), daemon=True)
        t.start()
        return {"state": "running", "progress": 0.0}

    def _run(self, key, src, mode, duration):
        out = self.output_path(key, mode)
        # Recreated per job, not just at startup: the cache is disposable by
        # design, so someone clearing it while the viewer is running must not
        # turn the next playback into a confusing ffmpeg rename failure.
        out.parent.mkdir(parents=True, exist_ok=True)
        part = out.with_suffix(".part.mp4")
        probe = self.probe(src) or {}
        if duration is None:
            duration = probe.get("duration")
        vidx = probe.get("vindex", 0)
        aidx = probe.get("aindex", 0)
        has_audio = probe.get("audio") is not None
        cmd = [self.ffmpeg, "-nostdin", "-y", "-hide_banner", "-loglevel", "error",
               "-progress", "pipe:1", "-i", str(src),
               "-map", "0:v:%d" % vidx]
        if has_audio:
            cmd += ["-map", "0:a:%d" % aidx]
        if mode == "remux":
            # +faststart moves the moov atom to the front so the browser can
            # seek immediately instead of waiting for the whole file.
            cmd += ["-c", "copy", "-movflags", "+faststart", "-f", "mp4", str(part)]
        else:
            prof = self.transcode_profile()
            if not prof:
                with self.lock:
                    self.jobs[(key, mode)] = {
                        "state": "error", "progress": 0.0,
                        "error": "This ffmpeg build has no encoder this viewer "
                                 "can use (looked for %s)."
                                 % ", ".join(p["vencoder"] for p in TRANSCODE_PROFILES)}
                return
            cmd += prof["video"] + prof["audio"] + prof["mux"] + [str(part)]
        log("%s -> %s" % (mode, out.name))
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE)
            for raw in proc.stdout:
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("out_time_us=") and duration:
                    try:
                        secs = int(line.split("=", 1)[1]) / 1_000_000.0
                        pct = max(0.0, min(0.999, secs / float(duration)))
                        with self.lock:
                            self.jobs[(key, mode)]["progress"] = pct
                    except (ValueError, ZeroDivisionError):
                        pass
            proc.wait()
            err = proc.stderr.read().decode("utf-8", "replace")[-2000:]
            if proc.returncode == 0 and part.exists() and part.stat().st_size > 0:
                part.replace(out)
                with self.lock:
                    self.jobs[(key, mode)] = {"state": "ready", "progress": 1.0, "error": None}
                log("%s finished: %s" % (mode, out.name))
            else:
                try:
                    part.unlink()
                except OSError:
                    pass
                with self.lock:
                    self.jobs[(key, mode)] = {"state": "error", "progress": 0.0,
                                              "error": err or "ffmpeg exited %s" % proc.returncode}
                log("%s FAILED: %s" % (mode, err.splitlines()[-1] if err else proc.returncode))
        except Exception as exc:
            with self.lock:
                self.jobs[(key, mode)] = {"state": "error", "progress": 0.0, "error": str(exc)}


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def send_file_range(handler, path, mime=None, download_name=None):
    """Serve a file with HTTP range support. Without this, seeking in the
    player does not work in Safari at all and is unreliable in Chrome."""
    try:
        size = path.stat().st_size
    except OSError:
        handler.send_error(404, "File not found")
        return
    mime = mime or mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    rng = handler.headers.get("Range")
    start, end = 0, size - 1
    status = 200
    if rng:
        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        if m:
            g1, g2 = m.group(1), m.group(2)
            if g1:
                start = int(g1)
                if g2:
                    end = min(int(g2), size - 1)
            elif g2:
                start = max(0, size - int(g2))
            if start >= size or start > end:
                handler.send_response(416)
                handler.send_header("Content-Range", "bytes */%d" % size)
                handler.end_headers()
                return
            status = 206
    length = end - start + 1
    handler.send_response(status)
    handler.send_header("Content-Type", mime)
    handler.send_header("Accept-Ranges", "bytes")
    handler.send_header("Content-Length", str(length))
    if status == 206:
        handler.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
    if download_name:
        handler.send_header("Content-Disposition",
                            'attachment; filename="%s"' % download_name.replace('"', ""))
    handler.end_headers()
    if handler.command == "HEAD":
        return
    try:
        with open(path, "rb") as fh:
            fh.seek(start)
            remaining = length
            while remaining > 0:
                chunk = fh.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                handler.wfile.write(chunk)
                remaining -= len(chunk)
    except (BrokenPipeError, ConnectionResetError):
        pass  # the browser closed the connection -- normal while seeking


def make_handler(app):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "ytdlp-archive-viewer/" + VIEWER_VERSION
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            if app.verbose:
                log("%s - %s" % (self.address_string(), fmt % args))

        # -- small response helpers -----------------------------------
        def _send(self, body, mime="text/html; charset=utf-8", status=200, cache=None):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            if cache:
                self.send_header("Cache-Control", cache)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def _json(self, obj, status=200):
            self._send(json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8", status)

        def _err(self, status, msg):
            self._json({"error": msg}, status)

        def is_local(self):
            return self.client_address[0] in ("127.0.0.1", "::1", "localhost")

        def do_HEAD(self):
            self.do_GET()

        def do_POST(self):
            self.do_GET()

        # -- routing ---------------------------------------------------
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            path = urllib.parse.unquote(parsed.path)
            query = urllib.parse.parse_qs(parsed.query)
            try:
                self.route(path, query)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as exc:
                import traceback
                traceback.print_exc()
                try:
                    self._err(500, str(exc))
                except Exception:
                    pass

        def route(self, path, query):
            parts = [p for p in path.split("/") if p]

            if path == "/" or path == "/index.html":
                return self._send(PAGE_HTML)
            if path == "/app.css":
                return self._send(APP_CSS, "text/css; charset=utf-8", cache="no-cache")
            if path == "/app.js":
                return self._send(APP_JS, "application/javascript; charset=utf-8", cache="no-cache")
            if path == "/favicon.ico":
                return self._send(b"", "image/x-icon", cache="max-age=86400")

            if parts and parts[0] == "api":
                return self.api(parts[1:], query)
            if parts and parts[0] == "media":
                return self.media(parts[1:], query)
            if parts and parts[0] == "watch":
                return self._send(PAGE_HTML)  # client-side routing
            return self._err(404, "No such route: %s" % path)

        # -- JSON API --------------------------------------------------
        def api(self, parts, query):
            idx = app.index
            if not parts:
                return self._err(404, "unknown endpoint")
            head = parts[0]

            if head == "status":
                return self._json({
                    "root": str(idx.root),
                    "cache": str(app.cache_dir),
                    "count": len(idx.order),
                    "channels": len(idx.channels),
                    "scanning": idx.scanning,
                    "progress": idx.scan_progress,
                    "ffmpeg": bool(app.media.ffmpeg),
                    "ffprobe": bool(app.media.ffprobe),
                    # Which encoder a re-encode would actually use here.
                    # Surfaced because it varies by ffmpeg BUILD, not just by
                    # whether ffmpeg exists -- null means this build has none
                    # of the encoders this viewer knows how to drive.
                    "transcode_profile": (app.media.transcode_profile() or {}).get("name"),
                    "can_open_local": app.allow_open_local and self.is_local(),
                    "version": VIEWER_VERSION,
                    "last_scan": idx.last_scan,
                })

            if head == "library":
                return self._json({"videos": idx.library(),
                                   "channels": sorted(idx.channels.values(),
                                                      key=lambda c: c["name"].lower())})

            if head == "rescan":
                threading.Thread(target=idx.scan,
                                 kwargs={"force": query.get("force", ["0"])[0] == "1"},
                                 daemon=True).start()
                return self._json({"started": True})

            if head == "channel" and len(parts) > 1:
                name = parts[1]
                info = idx.channels.get(name)
                if not info:
                    return self._err(404, "unknown channel")
                assets = []
                cdir = idx.root / name / "Channel Info"
                if cdir.is_dir():
                    for f in sorted(cdir.iterdir()):
                        if f.is_file():
                            assets.append({"name": f.name, "size": f.stat().st_size})
                out = dict(info)
                out["assets"] = assets
                return self._json(out)

            if head in ("video", "comments", "transcript", "file-text", "playback", "open") \
                    and len(parts) > 1:
                entry = idx.get(parts[1])
                if not entry:
                    return self._err(404, "unknown video")
                return getattr(self, "api_" + head.replace("-", "_"))(entry, parts[2:], query)

            return self._err(404, "unknown endpoint")

        def api_video(self, entry, rest, query):
            meta = dict(entry.meta)
            cached_info = safe_json_load(entry.cache_dir / "info.json") or {}
            meta["full_info"] = cached_info.get("info", {})
            meta["dropped_keys"] = cached_info.get("dropped", [])
            meta["manifest"] = None
            _, mf = entry.find(lambda f: f["rel"].endswith("manifest.json"))
            if mf:
                meta["manifest"] = safe_json_load(entry.dir / mf["rel"])
            _, uf = entry.find(lambda f: f["rel"].endswith("urls.json"))
            meta["urls"] = safe_json_load(entry.dir / uf["rel"]) if uf else None
            _, cf = entry.find(lambda f: f["rel"].endswith("checksums.sha256"))
            meta["has_checksums"] = cf is not None

            subs = []
            for i, f in enumerate(entry.files):
                if f["ext"] in SUB_EXTS:
                    name = os.path.basename(f["rel"])
                    stem = name.rsplit(".", 1)[0]
                    lang = stem.split(".", 1)[1] if "." in stem else "und"
                    subs.append({"idx": i, "name": name, "lang": lang,
                                 "auto": subtitle_is_auto(entry.dir / f["rel"]),
                                 "size": f["size"], "ext": f["ext"]})
            # Human-written subtitles first, then the shortest language tag --
            # so the track the player defaults to (and the transcript tab
            # opens) is the best one available rather than whichever filename
            # happened to sort first.
            subs.sort(key=lambda s: (s["auto"], len(s["lang"]), s["name"]))
            meta["subtitles_files"] = subs

            images = [{"idx": i, "name": os.path.basename(f["rel"]), "size": f["size"]}
                      for i, f in enumerate(entry.files) if f["ext"] in IMAGE_EXTS]
            meta["images"] = images
            thumb_idx, _ = entry.find(lambda f: f["ext"] in IMAGE_EXTS
                                      and "thumbnail" in f["rel"].lower())
            meta["thumb_idx"] = thumb_idx if thumb_idx is not None else (
                images[0]["idx"] if images else None)

            vid_idx, vid = find_media(entry)
            meta["video_idx"] = vid_idx
            meta["video_name"] = os.path.basename(vid["rel"]) if vid else None
            meta["video_size"] = vid["size"] if vid else None
            if vid_idx is not None:
                src = entry.path_for_index(vid_idx)
                plan = app.media.plan(src)
                probe = app.media.probe(src) or {}
                plan["streams"] = probe.get("streams", [])
                plan["probe_duration"] = probe.get("duration")
                plan["status"] = app.media.status(entry.key, str(src), plan["mode"]) \
                    if plan["mode"] in ("remux", "transcode") else {"state": "ready"}
                meta["playback"] = plan
            else:
                meta["playback"] = {"mode": "none", "reason": "No video file in this folder."}

            logs = [{"idx": i, "name": os.path.basename(f["rel"]), "size": f["size"]}
                    for i, f in enumerate(entry.files)
                    if f["ext"] in (".log", ".txt") or f["rel"].endswith(".description")]
            meta["logs"] = logs
            meta["channel_info"] = app.index.channels.get(entry.channel)
            return self._json(meta)

        def api_playback(self, entry, rest, query):
            vid_idx = query.get("idx", [None])[0]
            if vid_idx is None:
                vid_idx, _ = find_media(entry)
            src = entry.path_for_index(vid_idx)
            if not src:
                return self._err(404, "no video file")
            mode = query.get("mode", [None])[0] or app.media.plan(src)["mode"]
            if mode not in ("remux", "transcode"):
                return self._json({"state": "ready", "mode": mode})
            if not app.media.ffmpeg:
                return self._json({"state": "error", "mode": mode,
                                   "error": "ffmpeg was not found on PATH, so this "
                                            "file cannot be prepared for the browser. "
                                            "Use “Open in local player” instead."})
            if query.get("start", ["0"])[0] == "1":
                st = app.media.start(entry.key, str(src), mode,
                                     duration=entry.meta.get("duration"))
            else:
                st = app.media.status(entry.key, str(src), mode)
            st["mode"] = mode
            return self._json(st)

        def api_comments(self, entry, rest, query):
            data = safe_json_load(entry.cache_dir / "comments.json")
            if data is None:
                data = []
            keep = ("id", "parent", "text", "author", "author_id", "author_thumbnail",
                    "author_is_uploader", "author_is_verified", "is_favorited",
                    "is_pinned", "like_count", "timestamp", "time_text",
                    "author_url", "edited")
            slim = [{k: c.get(k) for k in keep if k in c} for c in data if isinstance(c, dict)]
            return self._json({"count": len(slim), "comments": slim,
                               "reported_count": entry.meta.get("comment_count")})

        def api_transcript(self, entry, rest, query):
            idx = query.get("idx", [None])[0]
            path = entry.path_for_index(idx) if idx is not None else None
            if path is None:
                _, sub = entry.find(lambda f: f["ext"] == ".vtt")
                if sub:
                    path = entry.dir / sub["rel"]
            if not path or not path.exists():
                return self._json({"cues": [], "error": "No subtitle file found."})
            return self._json({"cues": parse_subtitle_cues(path), "name": path.name})

        def api_file_text(self, entry, rest, query):
            path = entry.path_for_index(query.get("idx", [None])[0])
            if not path:
                return self._err(404, "no such file")
            if path.stat().st_size > 4 * 1024 * 1024:
                return self._json({"text": read_text(path, 4 * 1024 * 1024),
                                   "truncated": True, "name": path.name})
            return self._json({"text": read_text(path), "truncated": False, "name": path.name})

        def api_open(self, entry, rest, query):
            if not (app.allow_open_local and self.is_local()):
                return self._err(403, "Launching a local player is disabled. Start the "
                                      "viewer with --allow-open-local, from the machine "
                                      "you are browsing on.")
            path = entry.path_for_index(query.get("idx", [None])[0])
            if not path:
                vid_idx, _ = find_media(entry)
                path = entry.path_for_index(vid_idx)
            if not path:
                return self._err(404, "nothing to open")
            player = app.player_command(path)
            if not player:
                return self._err(500, "No media player found (looked for mpv, vlc, "
                                      "and the system opener).")
            try:
                subprocess.Popen(player, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            except Exception as exc:
                return self._err(500, "Could not launch %s: %s" % (player[0], exc))
            return self._json({"launched": player[0], "file": path.name})

        # -- media / raw files -----------------------------------------
        def media(self, parts, query):
            if len(parts) < 2:
                return self._err(404, "bad media request")
            entry = app.index.get(parts[0])
            if not entry:
                return self._err(404, "unknown video")
            kind = parts[1]

            if kind == "file":
                path = entry.path_for_index(query.get("idx", [None])[0])
                if not path:
                    return self._err(404, "no such file")
                mime = mimetypes.guess_type(path.name)[0]
                if path.suffix.lower() == ".vtt":
                    mime = "text/vtt; charset=utf-8"
                elif path.suffix.lower() == ".webp":
                    mime = "image/webp"
                elif path.suffix.lower() in (".description", ".log", ".sha256", ".url"):
                    mime = "text/plain; charset=utf-8"
                dl = os.path.basename(path.name) if query.get("dl", ["0"])[0] == "1" else None
                return send_file_range(self, path, mime, dl)

            if kind == "sub":
                path = entry.path_for_index(query.get("idx", [None])[0])
                if not path:
                    return self._err(404, "no such subtitle")
                if path.suffix.lower() == ".srt":
                    return self._send(srt_to_vtt(path), "text/vtt; charset=utf-8")
                return send_file_range(self, path, "text/vtt; charset=utf-8")

            if kind == "channel-asset":
                name = query.get("name", [""])[0]
                cdir = (app.index.root / entry.channel / "Channel Info").resolve()
                target = (cdir / os.path.basename(name)).resolve()
                try:
                    target.relative_to(cdir)
                except ValueError:
                    return self._err(403, "denied")
                if not target.is_file():
                    return self._err(404, "no such asset")
                return send_file_range(self, target)

            if kind == "video":
                vid_idx = query.get("idx", [None])[0]
                if vid_idx is None:
                    vid_idx, _ = find_media(entry)
                src = entry.path_for_index(vid_idx)
                if not src:
                    return self._err(404, "no video file")
                mode = query.get("mode", [None])[0] or app.media.plan(src)["mode"]
                if mode in ("remux", "transcode"):
                    out = app.media.output_path(entry.key, mode)
                    if out.exists():
                        # Derived from the actual file, not assumed: a
                        # transcode may have landed as WebM.
                        mime = mimetypes.guess_type(out.name)[0] or "video/mp4"
                        return send_file_range(self, out, mime)
                    return self._err(409, "Playback copy is not ready yet.")
                plan = app.media.plan(src)
                return send_file_range(self, src, plan.get("mime") or "video/webm")

            return self._err(404, "bad media kind")

    return Handler


# ---------------------------------------------------------------------------
# Front-end (served from memory; no build step, no external requests)
# ---------------------------------------------------------------------------

PAGE_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Archive Viewer</title>
<link rel="stylesheet" href="/app.css">
</head>
<body>
<header class="topbar">
  <a class="brand" href="#/"><span class="brand-mark"></span>Archive</a>
  <div class="searchwrap">
    <input id="q" type="search" placeholder="Search titles, channels, descriptions..." autocomplete="off">
  </div>
  <select id="channelFilter" title="Filter by channel"><option value="">All channels</option></select>
  <select id="sortBy" title="Sort">
    <option value="date_desc">Newest first</option>
    <option value="date_asc">Oldest first</option>
    <option value="title">Title A-Z</option>
    <option value="channel">Channel A-Z</option>
    <option value="views">Most viewed</option>
    <option value="comments">Most comments</option>
    <option value="duration">Longest</option>
  </select>
  <button id="rescan" class="ghost" title="Re-read the archive from disk">Rescan</button>
  <span id="status" class="status"></span>
</header>

<main id="view"></main>

<div id="toast" class="toast" hidden></div>
<script src="/app.js"></script>
</body>
</html>
"""

APP_CSS = r"""
:root{
  --bg:#0e0f13; --bg2:#15171d; --bg3:#1c1f27; --line:#282c37;
  --fg:#e8eaf0; --fg2:#a2a9bb; --fg3:#6f7789;
  --accent:#6ea8fe; --accent2:#3d7ff0; --warn:#e6a23c; --bad:#f06a6a;
  --ok:#4ec9a0; --radius:10px;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
}
@media (prefers-color-scheme: light){
  :root{ --bg:#f6f7f9; --bg2:#fff; --bg3:#eef0f4; --line:#dcdfe6;
         --fg:#1a1c22; --fg2:#565d6c; --fg3:#8b93a3; --accent:#2563eb; --accent2:#1d4ed8; }
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{background:var(--bg);color:var(--fg);
  font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Inter,sans-serif;
  -webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
button,select,input{font:inherit;color:inherit}
button{cursor:pointer}

/* ---- top bar ---- */
.topbar{position:sticky;top:0;z-index:50;display:flex;gap:10px;align-items:center;
  flex-wrap:wrap;padding:10px 16px;background:rgba(14,15,19,.86);backdrop-filter:blur(12px);
  border-bottom:1px solid var(--line)}
@media (prefers-color-scheme: light){.topbar{background:rgba(255,255,255,.9)}}
.brand{display:flex;align-items:center;gap:8px;font-weight:650;color:var(--fg);
  letter-spacing:.2px;white-space:nowrap}
.brand:hover{text-decoration:none}
.brand-mark{width:11px;height:11px;border-radius:3px;background:var(--accent);
  box-shadow:0 0 0 3px rgba(110,168,254,.18)}
.searchwrap{flex:1;min-width:120px}
#q{width:100%;padding:8px 12px;border-radius:var(--radius);border:1px solid var(--line);
  background:var(--bg2);outline:none}
#q:focus{border-color:var(--accent)}
.topbar select,.ghost{padding:8px 10px;border-radius:var(--radius);
  border:1px solid var(--line);background:var(--bg2);min-width:0;max-width:42vw}
/* On a phone the controls stack instead of forcing the page sideways: a
   long channel name in the filter would otherwise widen the whole document. */
@media (max-width:720px){
  /* Three rows of controls sticking to the top of a phone screen would eat
     most of the viewport, so the bar scrolls away here. */
  .topbar{position:static}
  .searchwrap{order:9;flex-basis:100%}
  .topbar select{flex:1 1 40%}
  .status{margin-left:auto;order:8}
  .watch{padding:12px 10px 60px}
  .tabs{top:0;position:relative}
}
.ghost:hover{border-color:var(--accent)}
.status{font-size:12px;color:var(--fg3);white-space:nowrap}

/* ---- library ---- */
.wrap{max-width:1500px;margin:0 auto;padding:20px 16px 60px}
.grid{display:grid;gap:18px;grid-template-columns:repeat(auto-fill,minmax(268px,1fr))}
.card{background:var(--bg2);border:1px solid var(--line);border-radius:var(--radius);
  overflow:hidden;display:flex;flex-direction:column;transition:transform .12s,border-color .12s}
.card:hover{transform:translateY(-2px);border-color:var(--accent)}
.card a.thumb{display:block;position:relative;aspect-ratio:16/9;background:var(--bg3)}
.card a.thumb img{width:100%;height:100%;object-fit:cover;display:block}
.thumb .dur{position:absolute;right:6px;bottom:6px;background:rgba(0,0,0,.8);color:#fff;
  font-size:12px;padding:1px 6px;border-radius:5px;font-variant-numeric:tabular-nums}
.thumb .noimg{display:flex;align-items:center;justify-content:center;height:100%;
  color:var(--fg3);font-size:12px}
.card .body{padding:10px 12px 12px;display:flex;flex-direction:column;gap:5px}
.card h3{margin:0;font-size:14.5px;line-height:1.35;font-weight:600;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.card h3 a{color:var(--fg)}
.card .sub{font-size:12.5px;color:var(--fg2)}
.card .facts{font-size:12px;color:var(--fg3);display:flex;gap:8px;flex-wrap:wrap}
.pill{display:inline-flex;align-items:center;gap:4px;background:var(--bg3);
  border:1px solid var(--line);border-radius:99px;padding:1px 8px;font-size:11.5px;color:var(--fg2)}
.pill.hot{border-color:var(--accent);color:var(--accent)}

/* ---- watch page ---- */
.watch{display:grid;gap:22px;grid-template-columns:minmax(0,1fr) 420px;
  max-width:1600px;margin:0 auto;padding:18px 16px 70px}
@media (max-width:1100px){.watch{grid-template-columns:minmax(0,1fr)}}
.player-shell{background:#000;border-radius:var(--radius);overflow:hidden;
  aspect-ratio:16/9;display:flex;align-items:center;justify-content:center;position:relative}
video{width:100%;height:100%;background:#000;display:block}
.prep{color:#dfe3ec;text-align:center;padding:24px;max-width:560px}
.prep h4{margin:0 0 6px;font-size:15px}
.prep p{margin:0 0 14px;color:#9aa2b4;font-size:13px;line-height:1.5}
.bar{height:6px;background:#2a2f3c;border-radius:99px;overflow:hidden;margin:12px 0 6px}
.bar>i{display:block;height:100%;background:var(--accent);width:0;transition:width .3s}
h1.vtitle{font-size:21px;line-height:1.3;margin:16px 0 8px}
.metarow{display:flex;flex-wrap:wrap;gap:8px;align-items:center;color:var(--fg2);font-size:13px}
.actions{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0}
.btn{padding:7px 12px;border-radius:99px;border:1px solid var(--line);background:var(--bg2);
  font-size:13px;display:inline-flex;align-items:center;gap:6px}
.btn:hover{border-color:var(--accent);text-decoration:none}
.btn.primary{background:var(--accent2);border-color:var(--accent2);color:#fff}
.panel{background:var(--bg2);border:1px solid var(--line);border-radius:var(--radius);
  padding:14px;margin-top:14px}
.panel h4{margin:0 0 8px;font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--fg3)}
.desc{white-space:pre-wrap;word-break:break-word;font-size:14px;line-height:1.6}
.desc.clamped{max-height:190px;overflow:hidden;
  -webkit-mask-image:linear-gradient(180deg,#000 60%,transparent);
  mask-image:linear-gradient(180deg,#000 60%,transparent)}
.more{margin-top:6px;background:none;border:none;color:var(--accent);padding:0;font-size:13px}
.chapters{display:flex;flex-direction:column;gap:2px;max-height:260px;overflow:auto}
.chapters button{display:flex;justify-content:space-between;gap:10px;text-align:left;
  background:none;border:none;padding:6px 8px;border-radius:6px;font-size:13.5px}
.chapters button:hover{background:var(--bg3)}
.chapters .t{color:var(--accent);font-variant-numeric:tabular-nums;font-family:var(--mono);font-size:12.5px}

/* ---- side tabs ---- */
.side{min-width:0}
.tabs{display:flex;gap:4px;border-bottom:1px solid var(--line);margin-bottom:12px;
  position:sticky;top:57px;background:var(--bg);z-index:20;padding-top:2px;overflow-x:auto}
.tabs button{background:none;border:none;padding:9px 12px;color:var(--fg2);font-size:13.5px;
  border-bottom:2px solid transparent;white-space:nowrap}
.tabs button.on{color:var(--fg);border-bottom-color:var(--accent);font-weight:600}
.tabs .n{color:var(--fg3);font-size:11.5px;margin-left:4px}
.tabpane{display:none}
.tabpane.on{display:block}

/* ---- comments ---- */
.ctools{display:flex;gap:8px;align-items:center;margin-bottom:12px;flex-wrap:wrap}
.ctools input[type=search]{flex:1;min-width:130px;padding:7px 10px;border-radius:8px;
  border:1px solid var(--line);background:var(--bg2)}
.ctools select{padding:7px 8px;border-radius:8px;border:1px solid var(--line);background:var(--bg2)}
.chk{display:inline-flex;align-items:center;gap:5px;font-size:12.5px;color:var(--fg2)}
.cmt{padding:10px 0;border-bottom:1px solid var(--line)}
.cmt:last-child{border-bottom:none}
.chead{display:flex;align-items:center;gap:7px;flex-wrap:wrap;font-size:12.5px;color:var(--fg3)}
.av{width:26px;height:26px;border-radius:50%;background:var(--bg3);flex:none;
  display:flex;align-items:center;justify-content:center;font-size:11px;color:var(--fg2);
  object-fit:cover;font-weight:600}
.cauthor{color:var(--fg);font-weight:600;font-size:13px}
.badge{font-size:10.5px;padding:1px 6px;border-radius:99px;border:1px solid var(--line);color:var(--fg2)}
.badge.op{background:var(--accent2);border-color:var(--accent2);color:#fff}
.badge.pin{color:var(--warn);border-color:var(--warn)}
.badge.heart{color:var(--bad);border-color:var(--bad)}
.ctext{margin:5px 0 4px;white-space:pre-wrap;word-break:break-word;font-size:14px;line-height:1.55}
.cfoot{display:flex;gap:12px;align-items:center;font-size:12px;color:var(--fg3)}
.cfoot button{background:none;border:none;color:var(--accent);padding:0;font-size:12px}
.replies{margin:8px 0 0 18px;padding-left:12px;border-left:2px solid var(--line);display:none}
.replies.on{display:block}
.tstamp{color:var(--accent);cursor:pointer;font-variant-numeric:tabular-nums}
.loadmore{width:100%;margin-top:12px;padding:9px;border-radius:8px;border:1px solid var(--line);
  background:var(--bg2);color:var(--fg2)}

/* ---- transcript ---- */
.tr{display:flex;flex-direction:column;gap:1px;max-height:70vh;overflow:auto}
.tr button{display:flex;gap:10px;text-align:left;background:none;border:none;padding:5px 7px;
  border-radius:6px;font-size:13.5px;line-height:1.45}
.tr button:hover{background:var(--bg3)}
.tr button.cur{background:var(--bg3);box-shadow:inset 2px 0 0 var(--accent)}
.tr .t{color:var(--accent);font-family:var(--mono);font-size:12px;flex:none;
  font-variant-numeric:tabular-nums;padding-top:1px}

/* ---- metadata / files ---- */
pre.j{background:var(--bg2);border:1px solid var(--line);border-radius:8px;padding:12px;
  overflow:auto;max-height:70vh;font-family:var(--mono);font-size:12.5px;line-height:1.5;
  white-space:pre-wrap;word-break:break-word;margin:0}
.kv{width:100%;border-collapse:collapse;font-size:13px}
.kv td{padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}
.kv td:first-child{color:var(--fg3);white-space:nowrap;width:34%;font-family:var(--mono);font-size:12px}
.filegroup{margin-bottom:12px}
.filegroup h5{margin:0 0 4px;font-size:12px;color:var(--fg3);font-family:var(--mono)}
.filerow{display:flex;align-items:center;gap:8px;padding:5px 6px;border-radius:6px;font-size:13px}
.filerow:hover{background:var(--bg3)}
.filerow .nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.filerow .sz{color:var(--fg3);font-size:12px;font-variant-numeric:tabular-nums}

/* ---- misc ---- */
.empty{padding:60px 20px;text-align:center;color:var(--fg2)}
.empty code{background:var(--bg3);padding:2px 6px;border-radius:5px;font-family:var(--mono)}
.note{font-size:12.5px;color:var(--fg3);line-height:1.5}
.note.warn{color:var(--warn)}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--bg3);
  border:1px solid var(--line);padding:9px 16px;border-radius:99px;font-size:13px;z-index:99;
  box-shadow:0 8px 30px rgba(0,0,0,.35)}
.spinner{display:inline-block;width:12px;height:12px;border:2px solid var(--line);
  border-top-color:var(--accent);border-radius:50%;animation:sp .7s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.imgstrip{display:flex;gap:8px;flex-wrap:wrap}
.imgstrip img{max-width:180px;border-radius:8px;border:1px solid var(--line)}
"""

APP_JS = r"""
'use strict';
// ---------------------------------------------------------------------------
// Tiny helpers
// ---------------------------------------------------------------------------
const $ = (s, r) => (r || document).querySelector(s);
const view = $('#view');
let LIB = null, STATUS = null, CUR = null;

const esc = s => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

function el(tag, attrs, kids) {
  const n = document.createElement(tag);
  if (attrs) for (const k in attrs) {
    if (k === 'class') n.className = attrs[k];
    else if (k === 'html') n.innerHTML = attrs[k];
    else if (k === 'text') n.textContent = attrs[k];
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), attrs[k]);
    else if (attrs[k] !== null && attrs[k] !== undefined) n.setAttribute(k, attrs[k]);
  }
  (kids || []).forEach(c => c && n.appendChild(c));
  return n;
}

function hhmmss(sec) {
  if (sec == null || isNaN(sec)) return '';
  sec = Math.max(0, Math.floor(sec));
  const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60;
  const pad = n => String(n).padStart(2, '0');
  return h ? h + ':' + pad(m) + ':' + pad(s) : m + ':' + pad(s);
}
function num(n) {
  if (n == null) return '';
  if (n >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, '') + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'K';
  return String(n);
}
function bytes(n) {
  if (!n && n !== 0) return '';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i ? n.toFixed(1) : n) + ' ' + u[i];
}
function ymd(d) {
  if (!d || d.length !== 8) return d || '';
  const dt = new Date(+d.slice(0, 4), +d.slice(4, 6) - 1, +d.slice(6, 8));
  return dt.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}
function ago(ts) {
  if (!ts) return '';
  const d = Math.floor(Date.now() / 1000) - ts;
  const steps = [[31536000, 'year'], [2592000, 'month'], [604800, 'week'],
                 [86400, 'day'], [3600, 'hour'], [60, 'minute']];
  for (const [s, name] of steps) {
    if (d >= s) { const v = Math.floor(d / s); return v + ' ' + name + (v > 1 ? 's' : '') + ' ago'; }
  }
  return 'just now';
}
function toast(msg, ms) {
  const t = $('#toast');
  t.textContent = msg; t.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { t.hidden = true; }, ms || 3200);
}
async function api(path) {
  const r = await fetch(path);
  const j = await r.json().catch(() => ({ error: 'Bad response from server' }));
  if (!r.ok && j.error) throw new Error(j.error);
  return j;
}

// Turn 1:23 / 01:02:03 into seek links, and bare URLs into real links.
const TS_RE = /\b(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)\b/g;
const URL_RE = /\bhttps?:\/\/[^\s<>()"']+/g;
function richText(raw) {
  let s = esc(raw || '');
  s = s.replace(URL_RE, u => '<a href="' + u + '" target="_blank" rel="noreferrer noopener">' + u + '</a>');
  s = s.replace(TS_RE, (m, h, mi, se) => {
    const t = (+(h || 0)) * 3600 + (+mi) * 60 + (+se);
    return '<span class="tstamp" data-seek="' + t + '">' + m + '</span>';
  });
  return s;
}
function wireSeeks(root) {
  root.querySelectorAll('.tstamp[data-seek]').forEach(n => {
    n.onclick = () => seekTo(+n.dataset.seek);
  });
}
function seekTo(t) {
  const v = $('#player');
  if (!v) return;
  v.currentTime = t;
  v.play().catch(() => {});
  v.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------
async function loadLibrary(force) {
  if (LIB && !force) return LIB;
  LIB = await api('/api/library');
  const sel = $('#channelFilter');
  const cur = sel.value;
  sel.innerHTML = '<option value="">All channels</option>';
  LIB.channels.forEach(c => sel.appendChild(
    el('option', { value: c.name, text: c.name + '  (' + c.count + ')' })));
  sel.value = cur;
  return LIB;
}

function filterSort(videos) {
  const q = $('#q').value.trim().toLowerCase();
  const ch = $('#channelFilter').value;
  const sort = $('#sortBy').value;
  let out = videos.filter(v => {
    if (ch && v.channel_folder !== ch) return false;
    if (!q) return true;
    return (v.title || '').toLowerCase().includes(q)
      || (v.uploader || '').toLowerCase().includes(q)
      || (v.description || '').toLowerCase().includes(q)
      || (v.id || '').toLowerCase().includes(q);
  });
  const by = {
    date_desc: (a, b) => (b.upload_date || '').localeCompare(a.upload_date || ''),
    date_asc: (a, b) => (a.upload_date || '').localeCompare(b.upload_date || ''),
    title: (a, b) => (a.title || '').localeCompare(b.title || ''),
    channel: (a, b) => (a.uploader || '').localeCompare(b.uploader || '')
      || (b.upload_date || '').localeCompare(a.upload_date || ''),
    views: (a, b) => (b.view_count || 0) - (a.view_count || 0),
    comments: (a, b) => (b.comment_count || 0) - (a.comment_count || 0),
    duration: (a, b) => (b.duration || 0) - (a.duration || 0),
  }[sort];
  return out.sort(by);
}

function card(v) {
  const href = '#/watch/' + v.key;
  const thumb = v.has_thumb
    ? el('img', { src: '/media/' + v.key + '/file?idx=' + v.thumb_idx, loading: 'lazy', alt: '' })
    : el('div', { class: 'noimg', text: 'no thumbnail' });
  const a = el('a', { class: 'thumb', href }, [thumb]);
  if (v.duration) a.appendChild(el('span', { class: 'dur', text: hhmmss(v.duration) }));
  const facts = [];
  if (v.view_count) facts.push(num(v.view_count) + ' views');
  if (v.upload_date) facts.push(ymd(v.upload_date));
  if (v.resolution) facts.push(v.resolution);
  return el('div', { class: 'card' }, [
    a,
    el('div', { class: 'body' }, [
      el('h3', {}, [el('a', { href, text: v.title || '(untitled)' })]),
      el('div', { class: 'sub', text: v.uploader || v.channel_folder }),
      el('div', { class: 'facts', text: facts.join(' · ') }),
      el('div', { class: 'facts' }, [
        el('span', { class: 'pill' + (v.comment_count ? ' hot' : ''),
                     text: v.comment_count ? num(v.comment_count) + ' comments' : 'no comments' }),
        v.sub_count ? el('span', { class: 'pill', text: v.sub_count + ' sub file' + (v.sub_count > 1 ? 's' : '') }) : null,
        !v.has_video ? el('span', { class: 'pill', text: 'metadata only' }) : null,
      ]),
    ]),
  ]);
}

async function renderLibrary() {
  view.innerHTML = '<div class="wrap"><div class="empty"><span class="spinner"></span> Loading library...</div></div>';
  let lib;
  try { lib = await loadLibrary(); } catch (e) {
    view.innerHTML = '<div class="wrap"><div class="empty">' + esc(e.message) + '</div></div>';
    return;
  }
  const wrap = el('div', { class: 'wrap' });
  if (!lib.videos.length) {
    wrap.appendChild(el('div', { class: 'empty', html:
      'No videos found under <code>' + esc(STATUS ? STATUS.root : '') + '</code>.<br><br>' +
      'Point the viewer somewhere else with <code>--root /path/to/archive</code>, ' +
      'or run <code>ytdl &lt;url&gt;</code> first.' }));
  } else {
    const list = filterSort(lib.videos);
    wrap.appendChild(el('div', { class: 'status', style: 'margin-bottom:12px',
      text: list.length + ' of ' + lib.videos.length + ' video' + (lib.videos.length > 1 ? 's' : '') }));
    const grid = el('div', { class: 'grid' });
    list.forEach(v => grid.appendChild(card(v)));
    wrap.appendChild(grid);
  }
  view.innerHTML = '';
  view.appendChild(wrap);
}

// ---------------------------------------------------------------------------
// Watch page
// ---------------------------------------------------------------------------
async function renderWatch(key) {
  view.innerHTML = '<div class="wrap"><div class="empty"><span class="spinner"></span> Loading...</div></div>';
  let d;
  try { d = await api('/api/video/' + key); } catch (e) {
    view.innerHTML = '<div class="wrap"><div class="empty">' + esc(e.message) + '</div></div>';
    return;
  }
  CUR = d;
  // Reset per-video state so a transcript or comment thread from the previous
  // video can never leak into this one.
  TR = { key: null, cues: [], nodes: [], follow: true, cur: -1 };
  document.title = (d.title || 'Video') + ' — Archive';

  const left = el('div', { class: 'main' });
  const shell = el('div', { class: 'player-shell', id: 'shell' });
  left.appendChild(shell);
  left.appendChild(el('h1', { class: 'vtitle', text: d.title || d.folder_name }));

  const facts = [];
  if (d.view_count != null) facts.push(num(d.view_count) + ' views');
  if (d.like_count != null) facts.push(num(d.like_count) + ' likes');
  if (d.upload_date) facts.push('uploaded ' + ymd(d.upload_date));
  if (d.duration) facts.push(hhmmss(d.duration));
  if (d.resolution) facts.push(d.resolution + (d.fps ? ' @ ' + d.fps + 'fps' : ''));
  const metarow = el('div', { class: 'metarow' }, [
    el('strong', { text: d.uploader || d.channel_folder }),
    el('span', { text: '· ' + facts.join(' · ') }),
  ]);
  left.appendChild(metarow);

  // --- actions
  const actions = el('div', { class: 'actions' });
  if (d.webpage_url) actions.appendChild(el('a', { class: 'btn', href: d.webpage_url,
    target: '_blank', rel: 'noreferrer noopener', text: 'Open on YouTube' }));
  if (d.video_idx != null) {
    actions.appendChild(el('a', { class: 'btn', text: 'Download original (' + bytes(d.video_size) + ')',
      href: '/media/' + key + '/file?idx=' + d.video_idx + '&dl=1' }));
    if (STATUS && STATUS.can_open_local) {
      actions.appendChild(el('button', { class: 'btn', text: 'Open in local player',
        onclick: async (ev) => {
          ev.target.disabled = true;
          try { const r = await api('/api/open/' + key + '?idx=' + d.video_idx);
                toast('Launched ' + r.launched); }
          catch (e) { toast(e.message, 6000); }
          ev.target.disabled = false;
        } }));
    }
  }
  left.appendChild(actions);

  // --- description
  if (d.description) {
    const body = el('div', { class: 'desc clamped', html: richText(d.description) });
    wireSeeks(body);
    const more = el('button', { class: 'more', text: 'Show more', onclick: () => {
      body.classList.toggle('clamped');
      more.textContent = body.classList.contains('clamped') ? 'Show more' : 'Show less';
    } });
    left.appendChild(el('div', { class: 'panel' }, [
      el('h4', { text: 'Description' }), body,
      d.description.length > 420 ? more : null]));
  }

  // --- chapters
  if (d.chapters && d.chapters.length) {
    const list = el('div', { class: 'chapters' });
    d.chapters.forEach(c => list.appendChild(el('button', {
      onclick: () => seekTo(c.start_time) }, [
      el('span', { text: c.title || '(chapter)' }),
      el('span', { class: 't', text: hhmmss(c.start_time) })])));
    left.appendChild(el('div', { class: 'panel' }, [
      el('h4', { text: 'Chapters (' + d.chapters.length + ')' }), list]));
  }

  // --- side tabs
  const side = el('div', { class: 'side' });
  const tabs = el('div', { class: 'tabs' });
  const panes = {};
  const defs = [
    ['comments', 'Comments', d.comments_cached || 0],
    ['transcript', 'Transcript', d.subtitles_files.length],
    ['meta', 'Metadata', null],
    ['files', 'Files', d.files.length],
  ];
  defs.forEach(([id, label, n], i) => {
    const b = el('button', { class: i === 0 ? 'on' : '', html: esc(label) +
      (n ? '<span class="n">' + num(n) + '</span>' : '') });
    b.onclick = () => {
      tabs.querySelectorAll('button').forEach(x => x.classList.remove('on'));
      b.classList.add('on');
      for (const k in panes) panes[k].classList.toggle('on', k === id);
      if (id === 'transcript') ensureTranscript(d);
      if (id === 'comments') ensureComments(d);
    };
    tabs.appendChild(b);
    panes[id] = el('div', { class: 'tabpane' + (i === 0 ? ' on' : ''), id: 'pane-' + id });
  });
  side.appendChild(tabs);
  defs.forEach(([id]) => side.appendChild(panes[id]));

  const root = el('div', { class: 'watch' }, [left, side]);
  view.innerHTML = '';
  view.appendChild(root);

  renderMeta(d, panes.meta);
  renderFiles(d, panes.files);
  ensureComments(d);
  setupPlayer(d, shell);
}

// --- player -----------------------------------------------------------------
function buildVideoEl(d, src, mime) {
  const v = el('video', { id: 'player', controls: '', preload: 'metadata',
                          playsinline: '', crossorigin: 'anonymous', src: src });
  // src is set on the <video> itself rather than a child <source>, because a
  // failing <source> does not fire an error event the page can react to --
  // and a browser that cannot decode this file is exactly the case that most
  // needs an explanation instead of a black rectangle.
  v.addEventListener('error', () => {
    const shell = v.parentElement;
    if (!shell) return;
    const why = v.error ? (v.error.message || ('media error ' + v.error.code)) : 'unknown';
    shell.innerHTML = '';
    shell.appendChild(el('div', { class: 'prep' }, [
      el('h4', { text: 'Your browser could not play this file' }),
      el('p', { text: why }),
      el('p', { class: 'note', text: 'The archive copy is fine — this is a decoder '
        + 'limitation in the browser, not a damaged download. Open it in a local '
        + 'player (mpv plays everything yt-dlp produces), or download the original.' }),
    ]));
  });
  d.subtitles_files.forEach((s, i) => {
    v.appendChild(el('track', { kind: 'subtitles', label: s.lang + (s.auto ? ' (auto)' : ''),
      srclang: (s.lang || 'en').split('-')[0],
      src: '/media/' + d.key + '/sub?idx=' + s.idx, default: i === 0 ? '' : null }));
  });
  if (d.thumb_idx != null) v.setAttribute('poster', '/media/' + d.key + '/file?idx=' + d.thumb_idx);
  v.addEventListener('timeupdate', onTime);
  return v;
}

function setupPlayer(d, shell) {
  const pb = d.playback || {};
  if (pb.mode === 'none') {
    shell.appendChild(el('div', { class: 'prep' }, [
      el('h4', { text: 'No video file' }),
      el('p', { text: pb.reason || '' })]));
    return;
  }
  const url = '/media/' + d.key + '/video?idx=' + d.video_idx + '&mode=' + pb.mode;
  if (pb.mode === 'direct') {
    shell.innerHTML = '';
    shell.appendChild(buildVideoEl(d, url, pb.mime));
    return;
  }
  const st = pb.status || {};
  if (st.state === 'ready') {
    shell.innerHTML = '';
    shell.appendChild(buildVideoEl(d, url, 'video/mp4'));
    return;
  }
  // Needs preparing.
  const isTranscode = pb.mode === 'transcode';
  const bar = el('div', { class: 'bar' }, [el('i')]);
  const msg = el('p', { text: pb.reason || '' });
  const go = el('button', { class: 'btn primary',
    text: isTranscode ? 'Re-encode for the browser' : 'Prepare for playback (copy, no re-encode)' });
  const box = el('div', { class: 'prep' }, [
    el('h4', { text: isTranscode ? 'This file needs re-encoding' : 'This file needs a container swap' }),
    msg,
    el('p', { class: 'note', text: isTranscode
      ? 'This re-compresses the video and can take a long time. The archive is not modified — the copy lives in the viewer cache. Opening it in a local player instead is free and lossless.'
      : 'ffmpeg copies the existing video and audio streams into an MP4 — no quality is lost and the archive is left untouched. Usually seconds to a couple of minutes.' }),
    go,
  ]);
  shell.innerHTML = '';
  shell.appendChild(box);

  go.onclick = async () => {
    go.remove();
    box.appendChild(bar);
    const label = el('p', { class: 'note', text: 'Starting ffmpeg...' });
    box.appendChild(label);
    try { await api('/api/playback/' + d.key + '?idx=' + d.video_idx + '&mode=' + pb.mode + '&start=1'); }
    catch (e) { label.textContent = e.message; return; }
    const poll = setInterval(async () => {
      let s;
      try { s = await api('/api/playback/' + d.key + '?idx=' + d.video_idx + '&mode=' + pb.mode); }
      catch (e) { clearInterval(poll); label.textContent = e.message; return; }
      if (s.state === 'error') {
        clearInterval(poll);
        label.innerHTML = '<span style="color:#f06a6a">ffmpeg failed:</span> ' + esc(s.error || '');
        return;
      }
      $('.bar > i', box).style.width = Math.round((s.progress || 0) * 100) + '%';
      label.textContent = s.state === 'ready' ? 'Done.' :
        'Working... ' + Math.round((s.progress || 0) * 100) + '%';
      if (s.state === 'ready') {
        clearInterval(poll);
        shell.innerHTML = '';
        shell.appendChild(buildVideoEl(d, url, 'video/mp4'));
        $('#player').play().catch(() => {});
      }
    }, 900);
  };
}

// --- comments ---------------------------------------------------------------
let CMT = { key: null, all: [], roots: [], byParent: {}, shown: 0 };

async function ensureComments(d) {
  const pane = $('#pane-comments');
  if (CMT.key === d.key) return;
  pane.innerHTML = '<div class="empty"><span class="spinner"></span> Loading comments...</div>';
  let r;
  try { r = await api('/api/comments/' + d.key); }
  catch (e) { pane.innerHTML = '<div class="empty">' + esc(e.message) + '</div>'; return; }
  CMT = { key: d.key, all: r.comments || [], roots: [], byParent: {}, shown: 0 };
  CMT.all.forEach(c => {
    const p = c.parent && c.parent !== 'root' ? c.parent : null;
    if (p) (CMT.byParent[p] = CMT.byParent[p] || []).push(c);
    else CMT.roots.push(c);
  });
  if (!CMT.all.length) {
    pane.innerHTML = '<div class="empty">No comments were saved for this video.' +
      (r.reported_count ? ' YouTube reported ' + num(r.reported_count) +
        ' at download time — the comments pass may have failed; check ' +
        'Files → video_postprocessing.log.' : '') + '</div>';
    return;
  }
  pane.innerHTML = '';
  const tools = el('div', { class: 'ctools' }, [
    el('input', { type: 'search', id: 'csearch', placeholder: 'Search ' + num(CMT.all.length) + ' comments...' }),
    el('select', { id: 'csort' }, [
      el('option', { value: 'top', text: 'Top' }),
      el('option', { value: 'new', text: 'Newest' }),
      el('option', { value: 'old', text: 'Oldest' }),
    ]),
    el('label', { class: 'chk' }, [
      el('input', { type: 'checkbox', id: 'cav' }), el('span', { text: 'Avatars' })]),
  ]);
  pane.appendChild(tools);
  pane.appendChild(el('div', { class: 'note', id: 'cnote' }));
  pane.appendChild(el('div', { id: 'clist' }));
  $('#csearch').oninput = debounce(drawComments, 220);
  $('#csort').onchange = drawComments;
  $('#cav').onchange = drawComments;
  drawComments();
}

function debounce(fn, ms) {
  let t; return function () { clearTimeout(t); t = setTimeout(fn, ms); };
}

function sortComments(list, how) {
  const c = list.slice();
  if (how === 'top') c.sort((a, b) => (b.is_pinned ? 1 : 0) - (a.is_pinned ? 1 : 0)
    || (b.like_count || 0) - (a.like_count || 0));
  else if (how === 'new') c.sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0));
  else c.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
  return c;
}

function drawComments() {
  const q = ($('#csearch').value || '').trim().toLowerCase();
  const how = $('#csort').value;
  const list = $('#clist');
  list.innerHTML = '';
  let roots = CMT.roots;
  let matchedReplies = 0;
  if (q) {
    // Search every comment, replies included, but keep threads intact: a root
    // is shown if it matches OR any of its replies does.
    const hit = c => (c.text || '').toLowerCase().includes(q)
      || (c.author || '').toLowerCase().includes(q);
    roots = CMT.roots.filter(c => {
      if (hit(c)) return true;
      const kids = CMT.byParent[c.id] || [];
      const n = kids.filter(hit).length;
      matchedReplies += n;
      return n > 0;
    });
  }
  roots = sortComments(roots, how);
  CMT.shown = 0;
  $('#cnote').textContent = q
    ? roots.length + ' thread(s) match “' + q + '”'
    : num(CMT.roots.length) + ' top-level, ' + num(CMT.all.length - CMT.roots.length) + ' replies';
  appendComments(list, roots, how, q);
}

function appendComments(list, roots, how, q) {
  const batch = roots.slice(CMT.shown, CMT.shown + 50);
  batch.forEach(c => list.appendChild(commentNode(c, how, q)));
  CMT.shown += batch.length;
  const old = $('#loadmore');
  if (old) old.remove();
  if (CMT.shown < roots.length) {
    const b = el('button', { class: 'loadmore', id: 'loadmore',
      text: 'Load ' + Math.min(50, roots.length - CMT.shown) + ' more (' +
            (roots.length - CMT.shown) + ' left)' });
    b.onclick = () => appendComments(list, roots, how, q);
    list.appendChild(b);
  }
}

function avatarNode(c) {
  const showAv = $('#cav') && $('#cav').checked;
  const name = (c.author || '?').replace(/^@/, '');
  if (showAv && c.author_thumbnail) {
    return el('img', { class: 'av', src: c.author_thumbnail, loading: 'lazy',
                       referrerpolicy: 'no-referrer', alt: '' });
  }
  return el('div', { class: 'av', text: name.slice(0, 1).toUpperCase() });
}

function commentNode(c, how, q) {
  const head = el('div', { class: 'chead' }, [
    avatarNode(c),
    el('span', { class: 'cauthor', text: c.author || '(unknown)' }),
    c.author_is_uploader ? el('span', { class: 'badge op', text: 'creator' }) : null,
    c.author_is_verified ? el('span', { class: 'badge', text: 'verified' }) : null,
    c.is_pinned ? el('span', { class: 'badge pin', text: 'pinned' }) : null,
    c.is_favorited ? el('span', { class: 'badge heart', text: '♥ by creator' }) : null,
    el('span', { text: c.time_text || ago(c.timestamp) }),
    c.edited ? el('span', { text: '(edited)' }) : null,
  ]);
  const text = el('div', { class: 'ctext', html: richText(c.text) });
  wireSeeks(text);
  const foot = el('div', { class: 'cfoot' }, [
    el('span', { title: 'likes', text: '▲ ' + (c.like_count || 0).toLocaleString() }),
  ]);
  const kids = CMT.byParent[c.id] || [];
  const node = el('div', { class: 'cmt' }, [head, text, foot]);
  if (kids.length) {
    const box = el('div', { class: 'replies' });
    const toggle = el('button', { text: 'Show ' + kids.length + ' repl' + (kids.length > 1 ? 'ies' : 'y') });
    let built = false;
    toggle.onclick = () => {
      if (!built) {
        sortComments(kids, how === 'top' ? 'old' : how)
          .forEach(k => box.appendChild(commentNode(k, how, q)));
        built = true;
      }
      box.classList.toggle('on');
      toggle.textContent = (box.classList.contains('on') ? 'Hide ' : 'Show ') +
        kids.length + ' repl' + (kids.length > 1 ? 'ies' : 'y');
    };
    foot.appendChild(toggle);
    node.appendChild(box);
    if (q) toggle.click();
  }
  return node;
}

// --- transcript -------------------------------------------------------------
let TR = { key: null, cues: [], nodes: [], follow: true, cur: -1 };

async function ensureTranscript(d) {
  const pane = $('#pane-transcript');
  if (TR.key === d.key) return;
  if (!d.subtitles_files.length) {
    pane.innerHTML = '<div class="empty">No subtitle files in this folder.</div>';
    TR.key = d.key; return;
  }
  pane.innerHTML = '<div class="empty"><span class="spinner"></span> Parsing subtitles...</div>';
  const pick = el('select', {}, d.subtitles_files.map(s =>
    el('option', { value: s.idx, text: s.name + '  (' + bytes(s.size) + ')' })));
  const search = el('input', { type: 'search', placeholder: 'Search transcript...' });
  const follow = el('label', { class: 'chk' }, [
    el('input', { type: 'checkbox', checked: '' }), el('span', { text: 'Follow' })]);
  const listBox = el('div', { class: 'tr' });

  async function load(idx) {
    listBox.innerHTML = '<div class="empty"><span class="spinner"></span></div>';
    const r = await api('/api/transcript/' + d.key + '?idx=' + idx);
    TR.cues = r.cues || [];
    draw();
  }
  function draw() {
    const q = search.value.trim().toLowerCase();
    listBox.innerHTML = '';
    TR.nodes = [];
    if (!TR.cues.length) {
      listBox.innerHTML = '<div class="empty">Nothing readable in that subtitle file.</div>';
      return;
    }
    TR.cues.forEach((c, i) => {
      if (q && !c.text.toLowerCase().includes(q)) return;
      const b = el('button', { onclick: () => seekTo(c.start) }, [
        el('span', { class: 't', text: hhmmss(c.start) }),
        el('span', { text: c.text })]);
      b.dataset.i = i;
      listBox.appendChild(b);
      TR.nodes.push(b);
    });
  }
  pane.innerHTML = '';
  pane.appendChild(el('div', { class: 'ctools' }, [search, pick, follow,
    el('button', { class: 'ghost', text: 'Copy', onclick: () => {
      navigator.clipboard.writeText(TR.cues.map(c => c.text).join('\n'))
        .then(() => toast('Transcript copied')).catch(() => toast('Clipboard blocked'));
    } })]));
  pane.appendChild(listBox);
  pick.onchange = () => load(pick.value);
  search.oninput = debounce(draw, 200);
  follow.querySelector('input').onchange = e => { TR.follow = e.target.checked; };
  TR.key = d.key;
  await load(d.subtitles_files[0].idx);
}

function onTime(e) {
  if (!TR.cues.length || !TR.follow) return;
  const t = e.target.currentTime;
  let idx = -1;
  for (let i = 0; i < TR.cues.length; i++) {
    if (TR.cues[i].start <= t) idx = i; else break;
  }
  if (idx === TR.cur) return;
  TR.cur = idx;
  TR.nodes.forEach(n => n.classList.remove('cur'));
  const node = TR.nodes.find(n => +n.dataset.i === idx);
  if (node) {
    node.classList.add('cur');
    const box = node.parentElement;
    const top = node.offsetTop - box.offsetTop;
    if (top < box.scrollTop || top > box.scrollTop + box.clientHeight - 40) {
      box.scrollTop = top - box.clientHeight / 3;
    }
  }
}

// --- metadata ---------------------------------------------------------------
function kvTable(obj, keys) {
  const t = el('table', { class: 'kv' });
  (keys || Object.keys(obj)).forEach(k => {
    if (obj[k] === undefined || obj[k] === null || obj[k] === '') return;
    let v = obj[k];
    if (typeof v === 'object') v = JSON.stringify(v);
    t.appendChild(el('tr', {}, [el('td', { text: k }), el('td', { text: String(v) })]));
  });
  return t;
}

function renderMeta(d, pane) {
  pane.innerHTML = '';
  const info = d.full_info || {};
  pane.appendChild(el('div', { class: 'panel' }, [
    el('h4', { text: 'Key facts' }),
    kvTable({
      'Video ID': d.id, 'Title': d.title, 'Uploader': d.uploader,
      'Channel URL': d.channel_url, 'Upload date': ymd(d.upload_date),
      'Duration': hhmmss(d.duration), 'Views': d.view_count && d.view_count.toLocaleString(),
      'Likes': d.like_count && d.like_count.toLocaleString(),
      'Comments saved': d.comments_cached, 'Comments reported': d.comment_count,
      'Resolution': d.resolution, 'FPS': d.fps, 'Codecs': [d.vcodec, d.acodec].filter(Boolean).join(' + '),
      'Categories': (d.categories || []).join(', '), 'Language': d.language,
      'Age limit': d.age_limit, 'Live status': d.live_status,
      'Archive folder': d.rel,
    }),
  ]));

  if (d.playback && d.playback.streams && d.playback.streams.length) {
    const t = el('table', { class: 'kv' });
    d.playback.streams.forEach(s => t.appendChild(el('tr', {}, [
      el('td', { text: s.type + (s.attached_pic ? ' (cover)' : '') }),
      el('td', { text: [s.codec, s.width ? s.width + 'x' + s.height : null, s.channels ?
        s.channels + 'ch' : null, s.lang, s.filename, s.title].filter(Boolean).join(' · ') })])));
    pane.appendChild(el('div', { class: 'panel' }, [
      el('h4', { text: 'Streams inside the file' }), t,
      el('div', { class: 'note', text: d.playback.reason || '' })]));
  }

  if (d.tags && d.tags.length) {
    pane.appendChild(el('div', { class: 'panel' }, [
      el('h4', { text: 'Tags (' + d.tags.length + ')' }),
      el('div', { class: 'facts', html: d.tags.map(t =>
        '<span class="pill">' + esc(t) + '</span>').join(' ') })]));
  }

  if (d.images && d.images.length) {
    const strip = el('div', { class: 'imgstrip' });
    d.images.forEach(im => strip.appendChild(el('a', {
      href: '/media/' + d.key + '/file?idx=' + im.idx, target: '_blank' }, [
      el('img', { src: '/media/' + d.key + '/file?idx=' + im.idx, loading: 'lazy',
                  title: im.name + ' (' + bytes(im.size) + ')', alt: im.name })])));
    pane.appendChild(el('div', { class: 'panel' }, [
      el('h4', { text: 'Images' }), strip]));
  }

  const raw = el('pre', { class: 'j', text: JSON.stringify(info, null, 2) });
  const note = d.dropped_keys && d.dropped_keys.length
    ? el('div', { class: 'note', text: 'Omitted from this view because they are huge: ' +
        d.dropped_keys.join(', ') + '. Comments are in the Comments tab; the untouched ' +
        'original is Info.info.json under Files.' })
    : null;
  pane.appendChild(el('div', { class: 'panel' }, [
    el('h4', { text: 'Full info.json' }), note, raw]));

  if (d.manifest) pane.appendChild(el('div', { class: 'panel' }, [
    el('h4', { text: 'manifest.json (written by postprocess.ps1)' }),
    el('pre', { class: 'j', text: JSON.stringify(d.manifest, null, 2) })]));
  if (d.urls) pane.appendChild(el('div', { class: 'panel' }, [
    el('h4', { text: 'urls.json' }),
    el('pre', { class: 'j', text: JSON.stringify(d.urls, null, 2) })]));
}

// --- files ------------------------------------------------------------------
const TEXTY = ['.log', '.txt', '.json', '.sha256', '.description', '.vtt', '.srt', '.url', '.conf'];

function renderFiles(d, pane) {
  pane.innerHTML = '';
  const groups = {};
  d.files.forEach((f, i) => { (groups[f.folder] = groups[f.folder] || []).push([i, f]); });
  const holder = el('div');
  Object.keys(groups).sort().forEach(g => {
    const box = el('div', { class: 'filegroup' }, [
      el('h5', { text: g === '.' ? '(root of the video folder)' : g + '/' })]);
    groups[g].forEach(([i, f]) => {
      const name = f.rel.split('/').pop();
      const row = el('div', { class: 'filerow' }, [
        el('span', { class: 'nm', text: name }),
        el('span', { class: 'sz', text: bytes(f.size) }),
      ]);
      if (TEXTY.includes(f.ext)) {
        row.appendChild(el('button', { class: 'ghost', text: 'View', onclick: async () => {
          const r = await api('/api/file-text/' + d.key + '?idx=' + i);
          const pre = el('pre', { class: 'j', text: r.text + (r.truncated ? '\n\n[truncated]' : '') });
          const w = el('div', { class: 'panel' }, [el('h4', { text: r.name }), pre]);
          row.after(w);
        } }));
      }
      row.appendChild(el('a', { class: 'ghost', text: 'Save',
        href: '/media/' + d.key + '/file?idx=' + i + '&dl=1' }));
      box.appendChild(row);
    });
    holder.appendChild(box);
  });
  pane.appendChild(el('div', { class: 'panel' }, [
    el('h4', { text: 'Every file in this video’s folder' }), holder,
    el('div', { class: 'note', text: 'Path on disk: ' + d.rel })]));
}

// ---------------------------------------------------------------------------
// Router + boot
// ---------------------------------------------------------------------------
function route() {
  const h = location.hash.replace(/^#/, '') || '/';
  const m = h.match(/^\/watch\/([a-f0-9]+)/);
  if (m) { renderWatch(m[1]); }
  else { document.title = 'Archive Viewer'; renderLibrary(); }
}

async function refreshStatus() {
  try { STATUS = await api('/api/status'); } catch (e) { return; }
  const bits = [STATUS.count + ' videos'];
  if (!STATUS.ffmpeg) bits.push('no ffmpeg');
  if (STATUS.scanning) bits.push('scanning ' + STATUS.progress.done + '/' + STATUS.progress.total);
  $('#status').textContent = bits.join(' · ');
  if (STATUS.scanning) setTimeout(refreshStatus, 700);
}

window.addEventListener('hashchange', route);
$('#q').addEventListener('input', debounce(() => { if (!location.hash.startsWith('#/watch')) renderLibrary(); }, 200));
$('#channelFilter').addEventListener('change', () => { if (!location.hash.startsWith('#/watch')) renderLibrary(); });
$('#sortBy').addEventListener('change', () => { if (!location.hash.startsWith('#/watch')) renderLibrary(); });
$('#rescan').addEventListener('click', async (ev) => {
  // Shift-click forces a full re-parse of every info.json instead of trusting
  // the cached index -- the escape hatch if a cache entry ever goes stale.
  toast(ev.shiftKey ? 'Full rescan (ignoring cache)...' : 'Rescanning the archive...');
  await api('/api/rescan?force=' + (ev.shiftKey ? '1' : '0'));
  const wait = setInterval(async () => {
    const s = await api('/api/status');
    $('#status').textContent = 'scanning ' + s.progress.done + '/' + s.progress.total;
    if (!s.scanning) {
      clearInterval(wait); LIB = null; CMT.key = null; TR.key = null;
      await refreshStatus(); route(); toast('Rescan complete');
    }
  }, 600);
});

refreshStatus().then(route);
"""


# ---------------------------------------------------------------------------
# Application wiring
# ---------------------------------------------------------------------------

class App(object):
    def __init__(self, args):
        self.args = args
        self.verbose = args.verbose
        self.allow_open_local = args.allow_open_local

        root = resolve_archive_root(args.root) if args.root else autodetect_root()
        if root is None:
            if args.root:
                die("Could not find an archive under %s.\n"
                    "Expected a folder containing 'Youtube Videos/Complete Archive' "
                    "(a data root), or the 'Complete Archive' folder itself."
                    % args.root)
            die("Could not auto-detect the archive.\n"
                "Looked for 'Youtube Videos/Complete Archive' under ~/yt-dlp and the "
                "current directory.\nPass --root /path/to/your/archive "
                "(the same place you pass to ytdl --path, or the 'Complete Archive' "
                "folder itself).")
        self.root = root

        self.cache_dir = (Path(args.cache_dir).expanduser() if args.cache_dir
                          else default_cache_dir())
        self.cache_dir.mkdir(parents=True, exist_ok=True)

        ffmpeg = which("ffmpeg", args.ffmpeg)
        ffprobe = which("ffprobe", args.ffprobe)
        if not ffmpeg:
            log("ffmpeg not found -- metadata, comments and subtitles all still work, "
                "but .mkv files that are not WebM-compatible cannot be played in the "
                "browser. Install ffmpeg, or use --allow-open-local.")
        self.media = MediaManager(self.cache_dir, ffmpeg, ffprobe,
                                  allow_transcode=not args.no_transcode)
        self.index = Index(self.root, self.cache_dir)

    def player_command(self, path):
        """A media player to hand a file to, in order of how well it handles
        this pipeline's output. mpv first: it plays every codec combination
        yt-dlp can produce and reads embedded subtitles and chapters."""
        for name in ("mpv", "vlc"):
            exe = shutil.which(name)
            if exe:
                return [exe, str(path)]
        system = platform.system()
        if system == "Darwin" and shutil.which("open"):
            return ["open", str(path)]
        if system == "Windows":
            return ["cmd", "/c", "start", "", str(path)]
        if shutil.which("xdg-open"):
            return ["xdg-open", str(path)]
        return None


def default_cache_dir():
    """Never inside the archive: postprocess.ps1 writes checksums.sha256 over
    every file in a video folder, and dropping derived files in there would
    make those checksums fail to verify for no good reason."""
    system = platform.system()
    if system == "Darwin":
        base = Path.home() / "Library" / "Caches"
    elif system == "Windows":
        base = Path(os.environ.get("LOCALAPPDATA") or (Path.home() / "AppData" / "Local"))
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    return base / "ytdlp-archive-viewer"


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(2)


def lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def build_parser():
    p = argparse.ArgumentParser(
        prog="archive-viewer.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Browse the yt-dlp archive in a browser: video, subtitles, "
                    "transcript, thumbnail, description, chapters, metadata, and "
                    "the full comment thread.",
        epilog="""examples:
  python3 archive-viewer.py
      Auto-detect ~/yt-dlp, serve on http://127.0.0.1:8777 and open a browser.

  python3 archive-viewer.py --root ~/scratch-test
      Point at a -DataRoot / `ytdl --path` archive instead.

  python3 archive-viewer.py --root "/Volumes/Media/yt-dlp" --allow-open-local
      Read an archive on a mounted share, and let the page hand files to mpv/VLC.

  python3 archive-viewer.py --host 0.0.0.0 --port 8777
      Serve to other devices on your LAN. There is NO authentication -- only do
      this on a network you trust, and remember it exposes every archived file.
""")
    p.add_argument("--root", help="Archive location. Accepts a data root (the folder "
                                  "holding 'Youtube Videos'), the 'Youtube Videos' "
                                  "folder, or 'Complete Archive' itself.")
    p.add_argument("--port", type=int, default=8777, help="Port (default: 8777).")
    p.add_argument("--host", default="127.0.0.1",
                   help="Bind address (default: 127.0.0.1, this machine only).")
    p.add_argument("--cache-dir", help="Where derived files live. Never inside the archive.")
    p.add_argument("--no-browser", action="store_true", help="Do not open a browser.")
    p.add_argument("--rescan", action="store_true",
                   help="Ignore the cached index and re-read every info.json.")
    p.add_argument("--allow-open-local", action="store_true",
                   help="Let the page launch mpv/VLC on this machine for a file. "
                        "Only honoured for requests from localhost.")
    p.add_argument("--no-transcode", action="store_true",
                   help="Never offer re-encoding, only lossless container copies.")
    p.add_argument("--ffmpeg", help="Path to ffmpeg, if it is not on PATH.")
    p.add_argument("--ffprobe", help="Path to ffprobe, if it is not on PATH.")
    p.add_argument("--verbose", action="store_true", help="Log every HTTP request.")
    p.add_argument("--version", action="version", version="archive-viewer " + VIEWER_VERSION)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    app = App(args)

    log("archive : %s" % app.root)
    log("cache   : %s" % app.cache_dir)
    log("indexing...")
    app.index.scan(force=args.rescan)

    handler = make_handler(app)
    try:
        httpd = Server((args.host, args.port), handler)
    except OSError as exc:
        die("could not bind %s:%d (%s).\nAnother copy may already be running; "
            "try --port %d." % (args.host, args.port, exc, args.port + 1))

    shown_host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    url = "http://%s:%d/" % (shown_host, args.port)
    log("serving %s" % url)
    if args.host in ("0.0.0.0", "::"):
        ip = lan_ip()
        if ip:
            log("LAN     : http://%s:%d/  (no authentication -- trusted networks only)"
                % (ip, args.port))
    if app.allow_open_local:
        log("local player launching is ENABLED for requests from this machine")
    log("Ctrl-C to stop.")

    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("bye")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
