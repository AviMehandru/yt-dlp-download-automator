# The desktop GUI (`ytdl-gui`)

**Optional.** Nothing else in this project depends on it. `ytdl` and
`ytdl-view` behave exactly the same whether or not it is installed, and the
installer skips building it without complaint when Rust is absent.

It is one window over the whole project: start downloads and watch them, queue
several, read the run history, browse the archive, and check that the pipeline
around it is healthy.

## What it is, and what it deliberately is not

It does **not** reimplement the pipeline. Starting a download builds a `ytdl`
command line and hands it to the installed `scripts/ytdl.ps1` — the single
argument parser, on every platform — exactly as a terminal would. Every
control maps one-to-one onto a flag `ytdl.ps1` already accepts, and the window
shows you the command before it runs it:

```
ytdl "https://www.youtube.com/@SomeChannel/videos" --sync --workers 3
```

That preview is rendered by the same Rust function that builds the real
argument list, not by a second copy of the logic in JavaScript, so it cannot
drift from what actually runs.

It **does** own its archive browsing. The library, comment threading,
transcript parsing and playback decisions are a native reimplementation of
what `archive-viewer.py` does in Python. That duplication is real and has a
cost: the archive layout now has three consumers to keep in step —
`postprocess.ps1` writes it, `archive-viewer.py` reads it, and
`gui/src-tauri/src/archive.rs` reads it. The notes at the top of `archive.rs`
say what must stay equivalent.

The invariants it inherits from `archive-viewer.py`, none of them negotiable:

- **The archive is read-only.** Nothing is created, moved or modified under
  `Youtube Videos/`. `postprocess.ps1` writes a `checksums.sha256` covering
  every file in a video folder, so a derived file dropped in there would make
  that manifest stop verifying. Everything derived — the metadata index, the
  split-out comment files, playback copies — lives in a cache directory
  outside the archive.
- **The window never sends a filesystem path.** Content is addressed by an
  opaque key plus an index into a server-side file list, and the resolved path
  is re-checked against the video folder before anything is opened. There is
  no route that takes a path, which is what keeps traversal off the table
  rather than a filter that has to be right.
- **Nothing is re-encoded without being asked.**

## Installing

The installer handles it as Step 14, but only if a Rust toolchain is already
on the machine. Rust is not installed for you: `pwsh`, `deno`, Node and
`yt-dlp` are dependencies of *downloading* and are installed automatically; a
Rust toolchain is a dependency only of this window, it is about 1.5 GB, and
rustup's installer is another unverified curl-to-shell of the kind
`SECURITY.md` already accounts for one instance of.

So, to get the GUI:

1. Install Rust, if you have not already:

   ```
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o rustup.sh
   sh rustup.sh
   ```

2. On **Linux only**, install the system webview. Tauri uses the OS's own
   webview rather than shipping a browser, and on Linux that is a system
   library cargo cannot fetch:

   ```
   sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev patchelf   # Debian/Ubuntu
   sudo dnf install webkit2gtk4.1-devel gtk3-devel librsvg2-devel              # Fedora
   ```

   macOS uses WKWebView and Windows uses WebView2; both are already there.

3. Re-run `./setup.sh` (or `setup.ps1`). It is idempotent — every step checks
   before acting — and Step 14 will now find cargo, build the app, and write
   the `ytdl-gui` launcher into the same bin directory as `ytdl`.

Then:

```
ytdl-gui
```

A first build compiles several hundred crates and takes minutes. Rebuilds
after an edit take seconds.

### Building it by hand

The installer's build is nothing more than:

```
cargo build --release --manifest-path ~/yt-dlp/gui/src-tauri/Cargo.toml
```

and the binary lands at `~/yt-dlp/gui/src-tauri/target/release/ytdl-gui`.
(`C:\yt-dlp\...` on Windows.) Running that path directly works; the launcher
exists so you do not have to type it.

### Packaged installers

`tauri.conf.json` carries a complete bundle configuration, so
`cargo tauri build` produces a `.dmg`, `.msi`/`.exe` or `.AppImage`/`.deb`
depending on which platform you run it on. That path is configured but **not
exercised** — see Verification status below. Each installer has to be built on
the platform it targets; there is no cross-compilation here.

## The panes

### Download

URL, options, and the command preview. The options are exactly `ytdl.ps1`'s:
`--sync`, `--items`, `--after`, `--lazy`, `--workers`, `--path`, `--no-pot`,
`--skip-pot-update`, `--pot-port`. Each carries the same caveat it has in
`docs/ytdl-usage.md` — `--sync` is only safe for newest-first listings,
`--lazy` does nothing when workers > 1, and raising workers multiplies your
aggregate request rate at YouTube.

Below it, live output. yt-dlp redraws its progress line with a carriage return
and `yt-dlp.conf` sets no `--newline`, so the app reads the child's output
byte-wise and splits on both `\n` and `\r`: progress updates replace the
previous line instead of appending, and one download does not produce
thousands of near-identical log lines.

Cancelling kills the whole process tree, not just the child. `ytdl.ps1` starts
`run_ytdlp.ps1` as a child `pwsh`, which starts yt-dlp, which starts
`postprocess.ps1` and ffmpeg; killing only the top process would leave a
download running with nothing reading its output. On Unix the run gets its own
process group and the group is signalled; on Windows `taskkill /T` does it.

### Queue & history

**The queue runs strictly one at a time, and that is not a limitation to be
fixed.** Independent `ytdl` invocations race on shared state —
`global_manifest.json`, the channel manifests, the Channel Info refresh
throttle, `download.log` itself. `--workers N` is the supported way to get
real parallelism, because it enumerates every video up front so no two workers
are assigned the same one, and `postprocess.ps1` has matching file locking.
So "several at once" is the workers spinner; the queue never starts a second
process.

History rows carry the counts from `run_ytdlp.ps1`'s own session summary line
(videos touched, already-archived skips, errors, warnings) plus the exit code.
The queue and history survive restarts.

### Library

The archive, indexed. It tolerates the states a real run produces: a missing
or unparseable `info.json` (it falls back to parsing
`<uploader> - <date> - <id> - <title>` off the folder name, which is a
documented, stable part of the layout rather than a guess), a folder with no
video file at all, and `Pre-merge streams/` — which is skipped when choosing
the video, since `--keep-video` leaves video-only and audio-only files that
would otherwise be mistaken for the real one.

A video page gives you the player, threaded comments, a clickable transcript
that follows playback, description and chapters with seek links, the full
metadata, and the file list. **Verify checksums** re-hashes every file in the
folder against its own `checksums.sha256`.

Comments are threaded from the flat list yt-dlp writes, whose `parent` field
is either `"root"` or a parent id, in no guaranteed order — so a reply can
appear before its parent. A reply whose parent is genuinely absent (a deleted
comment, a truncated fetch) is shown at top level rather than dropped.

Transcripts strip the inline karaoke timestamps and collapse the rolling
two-line repetition in YouTube's auto-generated VTT, which is otherwise
unreadable as prose. Auto-generated tracks are told apart from human-written
ones by their *contents*, not their filenames — `--write-subs` and
`--write-auto-subs` both land in `Subtitles/` under the same base name.

#### About playback

`.mkv` cannot be played by any browser engine, and this pipeline produces
almost nothing else. Three outcomes, in order of cost:

1. **Direct.** VP8/VP9/AV1 + Opus/Vorbis inside Matroska is byte-compatible
   with WebM, so it is served straight from the archive with a WebM content
   type and costs nothing.
2. **A container rewrite.** `--merge-output-format mkv` writes an EBML header
   whose DocType is `matroska`. A strict demuxer reads that before it reads
   codecs and refuses the file even when the streams are perfectly playable.
   The app then stream-copies into a real `.webm` — every packet copied
   verbatim, only the header changed. This happens **automatically**, because
   there is nothing for you to weigh up: it is lossless and takes seconds.
3. **A re-encode.** Only ever offered as an explicit button, never automatic,
   and never for anything that could have been copied instead.

If all three fail, the app says so plainly and points you at **Open in
mpv/VLC** — mpv plays every codec combination this pipeline can produce and
reads the embedded subtitles and chapters.

Playback copies go to the cache directory, never into the archive.

### Health

Read-only, on purpose. It reports dependency versions and paths, which
pipeline files are actually installed (the repo holds the *sources*; editing a
file in a clone changes nothing until it is copied over), the PO token
provider's state, the installed `yt-dlp.conf` with its `CONFIG_VERSION`, and
archive statistics.

It does not install or update anything. `run_ytdlp.ps1` runs its own
once-per-24h dependency check, and a second updater racing it from a GUI is
exactly the kind of shared-state collision the rest of this project is built
to avoid.

### Settings

Data root (the `ytdl --path` equivalent), an archive-root override for when
autodetection guesses wrong, default worker count, whether re-encoding is
offered at all, and the theme. Settings, queue and history live in a platform
config directory; the index and playback copies live in a platform cache
directory. The cache is disposable — deleting it costs one re-index.

## Where things live

| | Linux | macOS | Windows |
|---|---|---|---|
| Source | `~/yt-dlp/gui` | `~/yt-dlp/gui` | `C:\yt-dlp\gui` |
| Binary | `…/gui/src-tauri/target/release/ytdl-gui` | same | `…\ytdl-gui.exe` |
| Settings, queue, history | `~/.config/ytdlp-gui` | `~/Library/Application Support/ytdlp-gui` | `%LOCALAPPDATA%\ytdlp-gui` |
| Index and playback copies | `~/.cache/ytdlp-gui` | `~/Library/Caches/ytdlp-gui` | `%LOCALAPPDATA%\Cache\ytdlp-gui` |

`YTDLP_INSTALL_ROOT` overrides the install root here as it does everywhere
else in the project.

The cache is deliberately a *different* directory from
`archive-viewer.py`'s `ytdlp-archive-viewer`: the two index formats are not
the same, and sharing a directory would mean each tool treating the other's
files as corrupt.

## Dependencies

Four crates: `tauri`, `serde`, `serde_json`, `sha2`, plus `libc` on Unix for
the process-group kill. No regex crate (hand-rolled scanners), no `walkdir`
(a recursive `read_dir`), no `rand` (pid plus a counter), no HTTP client
(nothing here talks to the network), no date library.

The frontend is plain HTML, CSS and ES2020 with **no build step and no
`package.json`** — `withGlobalTauri` exposes the API on `window`, so there is
no bundler, no `npm install`, and no lockfile. That was the point: choosing
Tauri already spends this project's "no build system" principle once, and
spending it again on a JavaScript toolchain would have made the GUI by far the
largest supply-chain surface in a repo that otherwise has almost none.

The capability set grants core window and event permissions and nothing else.
There is no filesystem plugin and no shell plugin, so the frontend cannot read
a path or run a command even in principle — it can only call the specific
commands `main.rs` chose to expose.

## Verification status

Honest, and narrower than the rest of this document might suggest:

- **Linux**: built and run. The window, the library index, comment threading,
  transcript parsing, the media protocol, the automatic WebM container
  rewrite, dependency detection and the health pane were all exercised against
  a fabricated archive and confirmed by screenshot.
- **Decode itself was never verified.** The test container has no audio device
  at all, so WebKitGTK cannot construct a playback pipeline and every video
  errors regardless of the file. The container rewrite was confirmed correct
  by inspecting the file it produced (valid VP9/Opus, DocType `webm`), not by
  watching it play.
- **No real download has ever been started through this window.** YouTube is
  unreachable from the environment it was built in. The command construction
  and process handling are covered by reasoning and by the pipeline's own test
  suite, not by a real run.
- **macOS and Windows have never been built or run**, matching the rest of the
  project. The platform branches — install root, launcher shape, `taskkill`
  instead of a process-group signal, and the `http://media.localhost` URL form
  that Windows rewrites custom schemes into — are reviewed and statically
  checked only.
- **The packaged-installer path is configured but unexercised.**

If you run it on macOS or Windows and something breaks, that is expected
rather than surprising, and the platform branch is the first place to look.
