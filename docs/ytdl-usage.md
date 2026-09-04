# `ytdl` usage

`ytdl` is the entry point for the whole pipeline. It takes a URL — a single
video, a playlist, or a channel, it doesn't matter which — and hands it to
`run_ytdlp.ps1`, which runs yt-dlp and triggers `postprocess.ps1` once per
video as each one finishes.

```
ytdl <youtube-url> [download-root-path] [options]
```

Only `<youtube-url>` is required. Everything else is optional, and a plain
`ytdl "<url>"` behaves exactly as it always has.

---

## Why one URL argument covers video / playlist / channel

There's no flag for "this is a channel" or "this is a playlist" because
none is needed. yt-dlp's own extractor already determines that from the
URL far more reliably than this script could, and every step downstream —
the per-video output templates, the `--exec` hook that fires
`postprocess.ps1`, `--download-archive` deduplication, the channel-info
throttle — already operates on one video at a time, regardless of whether
that video arrived as a direct link or as item #47 of a channel backlog.
So the flags below only ever change *how much* of a playlist/channel gets
pulled, or *how* the run behaves at multi-video scale — they're inert on a
single video URL. (`--workers` is the one exception worth flagging up
front: running several videos' worth of `postprocess.ps1` genuinely at the
same time did require changes inside `postprocess.ps1` itself — see that
flag's own section below.)

---

## Positional arguments

### `<youtube-url>` (required)

Any URL yt-dlp itself understands: `watch?v=`, `youtu.be/`, `/shorts/`,
`/playlist?list=`, `/@handle/videos`, `/channel/UC.../videos`, etc.

**Quote it.** Always, on every platform:

```
ytdl "https://www.youtube.com/watch?v=-QMgcOSyf-o&list=PLabc123"
```

This is not style advice. Your shell rewrites an unquoted URL *before*
`ytdl` is started, and each one does it differently:

| Shell | What an unquoted URL does |
|---|---|
| zsh (macOS default) | `?` is a glob character. `watch?v=...` fails with `zsh: no matches found` and `ytdl` never runs. |
| bash | `?` is passed through, but `&` backgrounds the command: `...&list=PL...` is silently **truncated** at the `&`, so you archive the one video and never learn the playlist was dropped. |
| PowerShell | `&` is a reserved character and the command is a syntax error. |
| cmd.exe | Fine — `ytdl.cmd` passes `%*` through unsplit precisely so `=` survives. |

Nothing inside `ytdl` can undo any of these; by the time it runs, the
command line has already been changed. If the first argument doesn't look
like a URL at all, `ytdl` prints a warning naming quoting as the fix and
continues anyway — a hint, not a gate.

#### Hyphens in video ids are handled

A separate problem, and this one *is* fixed in the pipeline. YouTube ids
are base64url, so roughly one in thirty starts with `-` or `_`;
`-QMgcOSyf-o` is a perfectly ordinary id. yt-dlp reads any argument
beginning with `-` as an option, wherever it appears, and fails with a
bare `Usage: yt-dlp [OPTIONS] URL [URL...]` that names nothing.

So every yt-dlp invocation in the pipeline now passes `--` (end of
options) immediately before the URL, and `ytdl` treats a hyphen-leading
first argument as the URL rather than an option. Both of these work:

```
ytdl "https://youtu.be/-QMgcOSyf-o"
ytdl -QMgcOSyf-o
```

The one thing a leading hyphen can no longer do is stand in for a missing
URL: `ytdl --sync "<url>"` is now a clean error. Previously it took
`--sync` as the URL and your actual URL as the download path, and started
a doomed run without complaining. Options go **after** the URL.

### `[download-root-path]` (optional, positional)

If given as the argument immediately after the URL, it replaces the
default `$HOME/yt-dlp` data root (`Archive Logs/`, `Youtube Videos/`) for
that run only. The pipeline install itself (`scripts/`, `configs/`) always
stays at `$HOME/yt-dlp` — `ytdl` needs a fixed, known location to find
`run_ytdlp.ps1` before any argument parsing can happen.

```bash
ytdl "https://youtube.com/watch?v=abc123" /mnt/external/archive
```

Only recognized as a path if it doesn't start with `--`. If you also need
one of the flags below in the same command, use `--path` instead (see
below) — mixing the bare positional path with flags is not supported,
since the parser only checks for a positional path once, right after the
URL.

A relative path is resolved to an absolute one by `run_ytdlp.ps1` itself,
so `ytdl <url> downloads` works but resolves relative to wherever `pwsh`
happens to be running from — an absolute path is safer if you're not sure.

---

## Flags

All flags go after the URL (and after the positional path, if you're using
that form). Order among the flags themselves doesn't matter.

### `--sync`

Stops the run as soon as it hits a video ID already present in
`archive.txt`, instead of continuing through the rest of the
playlist/channel listing.

**Use this for:** periodic re-runs against a channel or playlist you've
already mostly archived — a "just grab what's new" run. Without `--sync`,
re-running against a channel walks its *entire* upload history every
single time just to confirm nothing's new, which is wasted time (and
requests) on a channel with hundreds of videos.

**Important caveat:** this only works correctly against a **newest-first**
listing, which is the default order for a channel's `/videos` page. If
you've pointed it at a differently-ordered or filtered source, `--sync`
can stop before reaching videos that are genuinely new but happen to sort
after an old, already-archived one. If you're not sure of the ordering,
leave it off and let the run complete normally — `--download-archive`
still skips anything already downloaded either way, `--sync` just saves
time by not even checking the rest.

```bash
ytdl "https://youtube.com/@somechannel/videos" --sync
```

Maps to yt-dlp's own `--break-on-existing`.

### `--items RANGE`

Restricts the run to specific positions within a playlist or channel
listing. `RANGE` is passed through verbatim to yt-dlp, so its syntax
applies directly:

- `--items 1-20` — the first 20 items
- `--items 5,8,10-15` — item 5, item 8, and items 10 through 15
- `--items 10-` — item 10 through the end

**Use this for:** pulling a specific slice of a large playlist instead of
the whole thing — e.g. testing the pipeline against a few videos before
committing to a 300-video backlog, or picking up a specific range you know
you're missing.

```bash
ytdl "https://youtube.com/playlist?list=PL..." --items 1-20
```

Maps to yt-dlp's own `--playlist-items`.

### `--after YYYYMMDD`

Skips any video uploaded before the given date.

**Use this for:** picking up a channel's history from a known point
forward, without re-walking everything before it. Combine with `--sync`
for "catch me up from this date, then stop once you hit something already
archived" behavior, though in practice `--sync` alone is usually enough
for an already-partially-archived channel.

```bash
ytdl "https://youtube.com/@somechannel/videos" --after 20250101
```

Maps to yt-dlp's own `--dateafter`.

### `--lazy`

Starts downloading videos as they're discovered in the listing, instead of
first enumerating the *entire* playlist/channel and only then starting the
first download.

**Use this for:** very large channels (hundreds of videos or more), where
eager enumeration means a long, silent wait before anything actually
starts downloading. On a small playlist or a single video this makes no
noticeable difference.

**No effect combined with `--workers` (below):** parallel dispatch already
has to enumerate the full listing up front to build the worker queue, so
there's no "lazy" phase left for this to skip. `ytdl` will still accept
both together, but `download.log` will note that `--lazy` was ignored.

```bash
ytdl "https://youtube.com/@somechannel/videos" --lazy
```

Maps to yt-dlp's own `--lazy-playlist`.

### `--workers N`

Downloads `N` videos **at the same time** instead of one after another.
`N` must be a positive integer; default is `1` (unchanged, single-stream
behavior).

**Use this for:** working through a very large backlog — hundreds or
thousands of videos — in a reasonable amount of time, instead of one at a
time sequentially.

**This is not the same as running `ytdl` several times yourself in
different terminals.** Doing that against the same channel races several
files this pipeline shares across videos (`channel_manifest.json`,
`global_manifest.json`, the Channel Info refresh throttle) with no
coordination between the independent invocations, and can silently drop
manifest entries. `--workers` is the supported way to get real
parallelism instead, and it's built specifically to avoid that:

- **No duplicate downloads:** before any worker starts, the full list of
  videos is enumerated once into a fixed queue. Workers pull from that
  fixed queue — they never decide independently what to work on next, so
  there's nothing for two workers to collide on.
- **No corrupted manifests:** `postprocess.ps1` now locks around every
  place it reads-then-writes a shared file (the channel manifest, the
  global manifest, the Channel Info refresh check), so concurrent workers
  finishing at the same moment don't overwrite each other's updates.
- **`--sync`/`--break-on-existing` still works,** just computed slightly
  differently: instead of yt-dlp stopping mid-walk, the full queue is
  built first and then truncated at the first already-archived video,
  before any worker starts. Same effect, same newest-first caveat as
  `--sync` on its own.
- **`--items` and `--after` still work** exactly as documented above —
  applied while building the queue, before workers are dispatched.

```bash
# Backfill a large channel 4 videos at a time
ytdl "https://youtube.com/@somechannel/videos" --workers 4

# Same idea, but only new uploads
ytdl "https://youtube.com/@somechannel/videos" --sync --workers 4
```

**How many workers is safe?** There's no universal answer — every worker
is also hitting YouTube's own infrastructure at the same time, and this
pipeline's pacing settings (`--sleep-requests`, etc.) were tuned assuming
one stream. More workers means a proportionally higher aggregate request
rate, which raises real risk of rate-limiting or a temporary block.
**Start low (2–4), watch `download.log` for warnings or 403s, and only
raise it if that stays clean** — treat it as an experiment on a channel
you don't mind re-running, not a setting to max out on the first try.

No yt-dlp flag equivalent — this is orchestration `run_ytdlp.ps1` does
itself, using PowerShell 7's `ForEach-Object -Parallel`.

### `--path PATH`

Explicit-flag form of the positional `[download-root-path]` argument
described above. Functionally identical — use this form specifically when
you also need one or more of the flags above in the same command, since
the parser only looks for a *bare* positional path (no `--path`,`--sync`,
etc combined) immediately after the URL.

```bash
ytdl "https://youtube.com/@somechannel/videos" --sync --path /mnt/external/archive
```

---

### `--no-pot`, `--skip-pot-update`, `--pot-port N`

PO (proof-of-origin) token controls. Full background is in
`docs/setup-guide.md` under **PO tokens and degraded mode**; the short
version is that a working token provider is what lets this pipeline use
`tv_simply` and `web_safari` instead of relying entirely on `android_vr`.

| Flag | Effect |
|---|---|
| `--no-pot` | Skip tokens entirely; run on yt-dlp's default clients. |
| `--skip-pot-update` | Use the provider if it already works, but don't try to update or repair it when it doesn't. |
| `--pot-port N` | Move the local provider server off its default port 4416. |

`--no-pot` and any run where the provider is unhealthy are both treated as
**degraded**: the videos still download, but they are withheld from
`archive.txt` and listed in `Archive Logs/Logs/needs-refetch.txt` so a
later healthy run can replace them at full quality. That is deliberate —
a degraded entry recorded in the archive would be skipped forever.

```bash
# Provider is broken upstream and you want to keep archiving meanwhile
ytdl "https://youtu.be/VIDEOID" --no-pot

# Offline or metered: use what's installed, don't go fetch updates
ytdl "https://youtu.be/VIDEOID" --skip-pot-update

# 4416 is already taken on this machine
ytdl "https://youtu.be/VIDEOID" --pot-port 8080
```

Check provider health at any time:

```bash
pwsh -File "<install root>/scripts/pot-provider.ps1" -Status
```

## What gets downloaded

Everything above decides *which videos* a session covers. The flags in this
section decide *what is fetched for each one*.

They work by being appended to the yt-dlp command line **after** the config
file, where the later option wins. `config/yt-dlp.conf` is never rewritten,
regenerated, or edited by a run — it stays exactly as static as it has always
been, and these override it the same way `--download-archive` and `--paths`
already do.

### `--mode MODE`

| Mode | What you get |
|---|---|
| `full` *(default)* | Video + audio merged, plus everything else. Unchanged behaviour. |
| `video-only` | No audio stream. |
| `audio-only` | No video stream. The media file is named **`Final Audio.<ext>`**. |
| `metadata-only` | No media at all — info.json, description, thumbnail. |
| `comments-only` | No media at all — the comments pass only. |
| `subs-only` | No media at all — subtitles only. |

The three no-media modes still write the **complete per-video folder**:
manifest, checksums, subfolders, the lot — just with no media file in it. That
is a valid archive state under layout 2, not a broken one, and it means the
media can be filled in by a later run without anything else being redone.

```bash
ytdl "https://youtu.be/VIDEOID" --mode audio-only
ytdl "https://www.youtube.com/@Chan/videos" --mode comments-only --sync
```

### `--quality N`, `--codec NAME`, `--container EXT`

```bash
ytdl "https://youtu.be/VIDEOID" --quality 1080 --codec avc1 --container mp4
```

`--quality` caps the height (or `best`, the default). It is a cap with an
unfiltered fallback behind it, so a video whose only rendition is taller still
downloads rather than failing — an archive that skips a video is worse than one
that stores it larger than asked.

`--codec` (`any`, `avc1`, `vp9`, `av01`) is a **preference**, not a filter: if
the codec isn't offered, the best available is still taken. `avc1` is the
compatibility choice; `av01` is the smallest for a given quality. Note the
zero in `av01`.

`--container` (`mkv`, `mp4`, `webm`) only matters when a merge actually
happens. `mkv` stays the default and is the only one of the three that can
carry the comment-complete `info.json` as a file attachment — under `mp4` or
`webm` the comments live in the sidecar `info.json` only, which is the system
of record in every case anyway.

### `--audio-codec NAME`

Only meaningful with `--mode audio-only`. `any` (the default) keeps the
original stream byte-for-byte; `opus`, `aac`, `mp3` and `flac` re-encode.
Leaving it alone is what the rest of this pipeline optimises for.

### Leaving components out

| Flag | Effect |
|---|---|
| `--no-comments` | Skip the comments pass. Normally the longest stage of a download. |
| `--no-subs` | No subtitles. |
| `--no-thumbnail` | No thumbnail downloaded or embedded. |
| `--no-metadata` | No description or info.json sidecars. |
| `--no-audio` | Alias for `--mode video-only`. |
| `--no-video` | Alias for `--mode audio-only`. |

`--no-comments` records `skipped_by_request` in the manifest's
`comment_audit`, which is what distinguishes "we didn't fetch comments" from
"we fetched and found none" — only one of those is worth re-running.

`--no-metadata` in a no-media mode still writes the info.json, because that
file is what triggers post-processing when there is no media file to trigger
it. The run says so rather than silently producing nothing.

### `--ytdlp-arg ARG`

Passes an argument straight to yt-dlp, after the config file so it wins.
Repeatable, one value per occurrence:

```bash
ytdl "https://youtu.be/VIDEOID" --ytdlp-arg --sponsorblock-mark --ytdlp-arg all
```

One value per occurrence rather than a joined string because a real
`--match-filter` expression contains spaces, commas and `&`, so no separator
would be safe.

Arguments that decide **where** files are written are refused:
`-o`/`--output`, `-P`/`--paths`, `--exec`, `--config-location`,
`--ignore-config`, `--download-archive`. Overriding one of those doesn't give
you a differently-configured archive — it gives you files no consumer of the
archive can find, with no error at any layer. The run stops instead.

### Combinations that are refused

Each of these would otherwise run to completion and produce nothing, or
something other than what was asked:

```
--no-audio --no-video                     leaves no media at all
--no-audio --mode audio-only              the alias contradicts the mode
--mode comments-only --no-comments        would fetch nothing
--mode comments-only --quality 1080       the mode downloads no media
```

## Combining flags

Any combination is valid — they're independent and only interact through
what they each restrict:

```bash
# Full backfill of a large channel, download-as-discovered
ytdl "https://youtube.com/@somechannel/videos" --lazy

# Same channel, months later: only check for new uploads
ytdl "https://youtube.com/@somechannel/videos" --sync

# Backfill everything from a specific date onward, into a custom drive
ytdl "https://youtube.com/@somechannel/videos" --after 20250101 --path /mnt/external/archive

# A specific slice of a big playlist, stopping early if any of it's
# already archived
ytdl "https://youtube.com/playlist?list=PL..." --items 50-100 --sync

# Large channel backfill, 4 at a time, only from a known date forward
ytdl "https://youtube.com/@somechannel/videos" --after 20250101 --workers 4
```

---

## Checking what actually happened

After any run, check:

```
~/yt-dlp/Archive Logs/Logs/download.log
```

Every session is bracketed by `==== Download session started ====` /
`==== Download session finished ====` markers, and — as of this version —
ends with a one-line summary before the finish marker:

```
-- Session summary: 12 video(s) touched, 34 already archived (skipped), 0 error(s), 0 warning(s) --
```

This is a best-effort count parsed from yt-dlp's own console text (yt-dlp
doesn't expose an official session-level counter), so treat it as
approximate rather than authoritative — but it's the fastest way to
confirm, for example, that `--sync` actually stopped where you expected,
without scrolling through the whole log by hand.

Per-video output (manifests, checksums, `video_postprocessing.log`, etc.)
still lands in each video's own folder exactly as before, regardless of
which flags were used to reach it.

**With `--workers` > 1**, `download.log` itself only gets the top-level
enumeration output and the final aggregate summary — the actual per-video
yt-dlp output goes into separate files instead, one per video:

```
~/yt-dlp/Archive Logs/Logs/download.worker-<video-id>.log
```

This is intentional, not a bug: several videos downloading at once can't
sensibly interleave into one shared log and still be readable, so each
gets its own. These per-worker logs aren't deleted automatically — their
content is also copied into that video's own `video_complete.log` inside
its per-video folder once it finishes, so the top-level copies are
redundant at that point and safe to clean up by hand later if they
accumulate on a very large channel run.

---

## Argument parsing rules, precisely

For anyone reading the script directly rather than this doc:

1. `$1` is always the URL, **including when it starts with `-`** — a
   leading hyphen does not mean "option" in this position, because
   `-QMgcOSyf-o` is a legitimate video id. Missing → usage error, exit.
2. The single exception to rule 1: if `$1` is exactly one of the known
   option spellings (`--sync`, `--items`, `--after`, `--lazy`,
   `--workers`, `--path`), it's a missing-URL error rather than a URL.
3. If `$1` doesn't look like a URL or a bare 11-character video id, a
   warning about quoting goes to stderr and the run continues.
4. After the URL, if the *next* remaining argument doesn't start with
   `--`, it's consumed as the legacy positional path.
5. Everything after that is parsed as `--flag [value]` pairs, in any
   order, until arguments run out.
6. An unrecognized `--something` is a hard error (exits with a usage
   message) rather than being silently ignored or passed through.
7. Whatever survives as the URL reaches yt-dlp after a `--` end-of-options
   marker, at every call site in the pipeline.

---

## What's unchanged, and what's not

- `yt-dlp.conf` — fully untouched.
- Plain `ytdl "<url>"` with no flags, and `--sync`/`--items`/`--after`/`--lazy`
  on their own (i.e. `--workers` left at its default of `1`) — byte-for-byte
  the same invocation as before `--workers` existed.
- The old two-argument form, `ytdl <url> <path>` — still works.
- `postprocess.ps1` **did** change, specifically to support `--workers`
  safely: it now takes an internal `-LogFileName` parameter (defaults to
  `download.log`, so nothing changes unless a worker passes something
  else) and locks around every shared-file read-modify-write, so several
  instances of it can now safely run at the same time. None of this is
  visible or relevant unless you're using `--workers` > 1.