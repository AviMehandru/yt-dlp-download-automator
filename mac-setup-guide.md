# Setting Up the yt-dlp Archival Pipeline on macOS

> **On Linux or Windows instead?** See [`linux-vm-setup-guide.md`](linux-vm-setup-guide.md)
> or [`windows-setup-guide.md`](windows-setup-guide.md). The pipeline scripts
> themselves are byte-identical on all three platforms — `run_ytdlp.ps1`,
> `postprocess.ps1` and `yt-dlp.conf` are one shared set — so only the
> installation differs.

> **Shortcut:** `setup.sh` automates Steps 1 through 10 in one run. It detects
> macOS from `uname -s` and takes the Homebrew path automatically; it is the
> same script Linux uses. Run `chmod +x setup.sh && ./setup.sh`. It is
> idempotent, safe to re-run, and does not hard-abort on a failed non-critical
> step — it prints a summary of anything needing a manual look at the end. The
> manual steps below are here for reference, and for when a step needs
> attention.

Everything resolves from `$HOME` automatically, so there is no
find-and-replace step and nothing below depends on your username.

**Apple silicon and Intel are both supported** and need no different steps.
The yt-dlp macOS build is a universal binary, and Homebrew handles the
architecture difference itself — the only visible consequence is that
Homebrew's prefix is `/opt/homebrew` on Apple silicon and `/usr/local` on
Intel, which `run_ytdlp.ps1` probes for both.

---

## Prerequisites

Two things this guide assumes, and neither is installed for you:

**Xcode Command Line Tools**, which provide `git` and `python3`:

```bash
xcode-select --install
```

**Homebrew**, which installs everything else:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

`setup.sh` deliberately does **not** install Homebrew for you. Its installer
needs `sudo` and writes into system-owned directories, and running that
silently as a side effect of setting up a video archiver is not a reasonable
thing for a script to decide on its own. If Homebrew is missing, `setup.sh`
warns, skips the package steps, and still creates the folder structure and
places the pipeline files — so you can install Homebrew and re-run.

---

## Step 1: Update Homebrew

```bash
brew update
brew upgrade
```

---

## Step 2: Install base dependencies

```bash
brew install ffmpeg git wget
```

Far shorter than the Ubuntu list, because macOS already ships `curl`, and the
Command Line Tools provide `git` and `python3`. `ffprobe` comes inside the
same `ffmpeg` formula — `postprocess.ps1` needs it for the info.json re-embed
step, so if `ffmpeg` installed correctly there is nothing extra to do.

---

## Step 3: Install yt-dlp

Installed as a standalone binary into `~/.local/bin`, **not** via
`brew install yt-dlp`, and this is deliberate. yt-dlp's `-U` self-update
rewrites its own binary by writing a temp file into the *containing
directory* and renaming over the old one. That directory therefore has to be
yours. Homebrew's prefix is not, and a Homebrew-installed yt-dlp will refuse
to self-update and tell you to use `brew upgrade` instead — which works, but
means the once-a-day `yt-dlp -U` in `run_ytdlp.ps1` silently does nothing,
and yt-dlp going stale is the single most common cause of extraction
breaking.

```bash
mkdir -p "$HOME/.local/bin"
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos \
  -o "$HOME/.local/bin/yt-dlp"
chmod a+rx "$HOME/.local/bin/yt-dlp"
xattr -d com.apple.quarantine "$HOME/.local/bin/yt-dlp" 2>/dev/null
```

Note the asset name: **`yt-dlp_macos`**, not the plain `yt-dlp` asset (that
one is the Linux build). It is a universal binary, so the same file is
correct on both Apple silicon and Intel.

The `xattr` line matters. Anything downloaded carries a
`com.apple.quarantine` attribute, and Gatekeeper refuses to run a quarantined
unsigned binary with *"cannot be opened because the developer cannot be
verified"* — which surfaces as what looks like a broken download rather than
a security prompt. Stripping the attribute from a binary you just fetched
over HTTPS from a known URL is the same trust decision as choosing to install
it at all.

---

## Step 4: Install PowerShell 7 (`pwsh`)

```bash
brew install --cask powershell
```

**`--cask` is required.** PowerShell is distributed as a signed package from
Microsoft, not a source formula, and plain `brew install powershell` fails
with *"No available formula with the name"*. This trips people up regularly.

Verify:

```bash
pwsh --version
```

Nothing in this pipeline runs without `pwsh` — both `run_ytdlp.ps1` and
`postprocess.ps1` are PowerShell 7 scripts, and yt-dlp invokes the latter
directly through its `--exec` hook.

---

## Step 5: Install `curl_cffi`

Fixes yt-dlp's "no impersonate target available" warning by giving it
browser-impersonation support.

```bash
python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages
```

`--break-system-packages` is what lets pip write into an externally-managed
environment (PEP 668), which Homebrew's Python is. If your pip is old enough
not to recognize the flag, `python3 -m pip install -U --user "curl_cffi>=0.10"`
achieves the same thing a different way.

---

## Step 6: Install Deno

YouTube requires solving a JavaScript challenge for cipher decryption. Without
a JS runtime, yt-dlp falls back to less reliable client/format combinations,
and the usual symptom is **mid-download HTTP 403 errors** rather than an
obvious "no JavaScript runtime" message — see yt-dlp/yt-dlp#14404.

```bash
curl -fsSL https://deno.land/install.sh | sh -s -- -y
cp "$HOME/.deno/bin/deno" "$HOME/.local/bin/deno"
chmod a+rx "$HOME/.local/bin/deno"
xattr -d com.apple.quarantine "$HOME/.local/bin/deno" 2>/dev/null
```

The same installer script serves Linux and macOS and picks the right build for
your architecture itself.

You do not have to put deno in exactly this location. `run_ytdlp.ps1` probes
`~/.local/bin/deno`, then `~/.deno/bin/deno`, then `/opt/homebrew/bin/deno`,
then `/usr/local/bin/deno`, then `PATH` — and if it finds none of them it omits
`--js-runtimes` entirely and logs a warning rather than failing confusingly.

---

## Step 7: Create the folder structure

```bash
mkdir -p "$HOME/yt-dlp/scripts" "$HOME/yt-dlp/configs"
mkdir -p "$HOME/yt-dlp/Archive Logs/Archive History" "$HOME/yt-dlp/Archive Logs/Logs"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Complete Archive"
mkdir -p "$HOME/yt-dlp/Youtube Videos/_incomplete"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Final Video"
```

`run_ytdlp.ps1` self-heals this tree on every invocation, so a missing folder
is recreated rather than being an error — but creating it up front means the
first run has nothing to report.

---

## Step 8: Place the project files

```bash
cp run_ytdlp.ps1     "$HOME/yt-dlp/scripts/run_ytdlp.ps1"
cp postprocess.ps1   "$HOME/yt-dlp/scripts/postprocess.ps1"
cp yt-dlp.conf       "$HOME/yt-dlp/configs/yt-dlp.conf"
cp archive-viewer.py "$HOME/yt-dlp/scripts/archive-viewer.py"
cp ytdl              "$HOME/.local/bin/ytdl"
chmod +x "$HOME/.local/bin/ytdl" "$HOME/yt-dlp/scripts/archive-viewer.py"
```

`ytdl` is the same bash launcher Linux uses — there is no separate macOS
version, because there is nothing in it that would differ.

The viewer launcher, which `setup.sh` generates rather than shipping as a
repo file:

```bash
cat > "$HOME/.local/bin/ytdl-view" <<'EOF'
#!/usr/bin/env bash
exec python3 "$HOME/yt-dlp/scripts/archive-viewer.py" "$@"
EOF
chmod +x "$HOME/.local/bin/ytdl-view"
```

Then put `~/.local/bin` on your `PATH`. macOS defaults to **zsh**, so this is
`.zshrc` rather than Ubuntu's `.bashrc`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
source "$HOME/.zshrc"
```

(`setup.sh` checks `$SHELL` rather than assuming, so if you have switched your
login shell to bash it appends to `.bashrc` instead.)

---

## Step 9: Install a video player

Nothing in the pipeline needs this — downloads and post-processing are
identical without it. It matters because **QuickTime Player cannot open
`.mkv` at all**, and `.mkv` is what this pipeline produces.

```bash
brew install --cask iina vlc
```

IINA is the native-feeling macOS player; VLC is included as well because its
subtitle track menu is more discoverable and it auto-loads a sidecar subtitle
file sitting next to a video without being asked. Both handle the two ways
this pipeline stores subtitles: tracks muxed into the `.mkv` by `--embed-subs`,
and the sidecar `.vtt` files under each video's `Subtitles/` folder.

**There is no thumbnailer work to do on macOS.** The Linux guide spends a long
step on `webp-pixbuf-loader`, `ffmpegthumbnailer`, `gnome-sushi` and raising
Nautilus's 10 MB thumbnail cap. Finder and Quick Look already render `.webp`
natively (since macOS 11), generate poster frames for `.mkv`, and preview
`.vtt` files as plain text, with no size cap worth raising.

---

## Step 10: Verify

```bash
"$HOME/.local/bin/yt-dlp" --version
ffmpeg -version | head -n1
ffprobe -version | head -n1
pwsh --version
"$HOME/.local/bin/deno" --version | head -n1
python3 --version
command -v ytdl
command -v ytdl-view
```

Check `yt-dlp` and `deno` **by full path**, not bare command name. `~/.local/bin`
was only just added to your `PATH`, and in a shell started before that change
a bare `yt-dlp` reports "not found" immediately after a successful install.

`setup.sh`'s own Step 12 additionally parse-checks the PowerShell scripts and
`archive-viewer.py` without running them, which catches a truncated download or
a bad edit at install time rather than at the end of a real download.

---

## Step 11: First real test run

Point the first run at a scratch data root so test output never lands in the
real archive. The second positional argument sets `-DataRoot`:

```bash
ytdl "https://youtu.be/<short-video-id>" "$HOME/scratch-test"
```

Pick something short. The comments pass on a heavily-commented video can take
30–60+ minutes on its own, and it runs *after* the video is already safely
downloaded — so a long silence late in the run is usually the comments fetch
working, not a hang. It streams its progress into the log as it goes.

Watch it work:

```bash
tail -f "$HOME/scratch-test/Archive Logs/Logs/download.log"
```

When it finishes, the video folder should contain `Final files/Final Video.mkv`
and nothing else at that level — the `--keep-video` pre-merge streams are moved
to a sibling `Pre-merge streams/` folder. Verify integrity:

```bash
cd "$HOME/scratch-test/Youtube Videos/Complete Archive/<Uploader>/<video folder>"
shasum -a 256 -c "Video metadata/checksums.sha256"
```

Every line should read `OK`. (On Linux the equivalent is `sha256sum -c`; macOS
ships `shasum` instead.)

---

## Step 12: Read what you archived

```bash
ytdl-view --root "$HOME/scratch-test"
```

Then open `http://127.0.0.1:8777`. Add `--allow-open-local` to let the page
hand files to IINA or VLC. The viewer is pure Python standard library, reads
the archive without ever writing to it, and keeps all derived state in
`~/Library/Caches/ytdlp-archive-viewer` — deliberately outside the archive, so
the `checksums.sha256` files keep verifying.

---

## macOS-specific notes

**Gatekeeper.** Covered in Steps 3 and 6, but worth stating plainly: any
binary you download rather than install through Homebrew carries a quarantine
attribute, and the resulting failure looks like a corrupt file rather than a
policy decision. If something you installed by hand refuses to run, check
`xattr -l <file>` before assuming the download failed.

**Full Disk Access.** If you point `-DataRoot` at `~/Desktop`, `~/Documents`
or `~/Downloads`, macOS may block your terminal from writing there until you
grant it access under System Settings → Privacy & Security → Full Disk Access.
This shows up as a permission error from a folder you can plainly see in
Finder. Archiving under `~/yt-dlp` (the default) avoids it entirely.

**Case-insensitive filesystem.** APFS is case-insensitive by default. Nothing
here depends on case-sensitive filenames, but it is worth knowing if you ever
move an archive from a Linux box where two folders differed only in case.

**Sleep.** A long channel archive will be interrupted by the machine sleeping.
`caffeinate -i ytdl "<url>" --workers 3` keeps it awake for the duration of
the run.

**Spotlight.** A large archive gets indexed, which costs time and disk. If you
would rather it were not, add the archive folder under System Settings →
Siri & Spotlight → Spotlight Privacy.

---

## Quick reference: what lives where after setup

```
~/.local/bin/
  ytdl                 launcher (bash) -- what you type
  ytdl-view            viewer launcher (generated, not a repo file)
  yt-dlp               standalone binary, self-updating
  deno                 JS runtime for YouTube's cipher challenge

~/yt-dlp/
  scripts/             run_ytdlp.ps1, postprocess.ps1, archive-viewer.py
  configs/             yt-dlp.conf
  .last_dependency_check    24h throttle marker for yt-dlp -U
  Archive Logs/
    Archive History/   timestamped archive.txt + global_manifest.json snapshots
    Logs/              download.log, archive.txt, setup_*.log
  Youtube Videos/
    Complete Archive/<Uploader>/<Uploader> - <date> - <id> - <title>/
      Final files/        Final Video.mkv, Link.*
      Pre-merge streams/  --keep-video's raw streams, moved out of Final files
      Subtitles/ Images/ URLs/ Logs/
      Video metadata/     Info.info.json, Description.*, manifest.json, checksums.sha256
    Complete Archive/<Uploader>/Channel Info/    avatar, banner, description
    Final Video/<Uploader>/   flat "point a player here" copies
    _incomplete/         yt-dlp temp path; empty dirs swept after each video
    global_manifest.json

~/Library/Caches/ytdlp-archive-viewer/    viewer's derived state (disposable)
```

Homebrew installs `ffmpeg`, `ffprobe`, `pwsh`, IINA and VLC into its own
prefix (`/opt/homebrew` on Apple silicon, `/usr/local` on Intel), which is
already on your `PATH`.
