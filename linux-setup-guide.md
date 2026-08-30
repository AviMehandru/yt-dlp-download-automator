# Setting Up the yt-dlp Archival Pipeline on Linux (bare metal)

> **Running this inside a VMware VM?** Use
> [`linux-vm-setup-guide.md`](linux-vm-setup-guide.md) instead — it is this
> guide plus the hypervisor-specific setup (open-vm-tools, the `/mnt/hgfs`
> shared folder, and the host/guest arrangement).
> **On macOS or Windows?** See [`mac-setup-guide.md`](mac-setup-guide.md) or
> [`windows-setup-guide.md`](windows-setup-guide.md).

This guide covers installing directly onto a Linux machine you own outright —
a desktop, a laptop, a home server, or a NAS box. No hypervisor, no guest
additions, no shared folders. The pipeline itself is identical; only the
surrounding environment differs.

> **Shortcut:** `setup.sh` automates Steps 1 through 9 in one run:
>
> ```bash
> chmod +x setup.sh && ./setup.sh
> ```
>
> **It is the same script the VM guide uses, and it needs no flag to tell it
> which situation it is in.** Its VMware step checks `systemd-detect-virt` and
> the DMI product name, finds neither, prints *"Not detected as a VMware guest
> — skipping shared folder setup"*, and moves on. Nothing about a bare-metal
> install requires editing it. The script is idempotent, safe to re-run, and
> prints a summary of anything needing attention at the end rather than
> hard-aborting.

Everything resolves from `$HOME`, so there is no find-and-replace step and
nothing below depends on your username.

---

## A note on distributions

`setup.sh` supports four distribution families natively, which between them
cover the overwhelming majority of desktop and server Linux:

| Family | Package manager | Includes |
|---|---|---|
| `debian` | apt | Debian, Ubuntu, Mint, Pop!\_OS, Raspberry Pi OS |
| `fedora` | dnf | Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux |
| `arch` | pacman | Arch, Manjaro, EndeavourOS |
| `suse` | zypper | openSUSE Tumbleweed, openSUSE Leap, SLES |

Detection reads `ID` and then `ID_LIKE` from `/etc/os-release`. `ID_LIKE` is
why the derivatives come along for free — Mint declares `ID_LIKE=ubuntu`,
Manjaro `arch`, Rocky `rhel centos fedora` — so none of them are named
anywhere in the script.

**On a distribution outside those families** the script says so plainly and
keeps going. The package steps are skipped, but **everything that places the
pipeline still runs**: folder creation, file placement, the `ytdl` and
`ytdl-view` launchers, and `PATH` wiring are all package-manager-agnostic. So
on NixOS, Gentoo, Alpine or anything else, install the dependencies however
your system does it and let `setup.sh` do the rest.

### PowerShell is no longer a distro problem

It used to be the one genuinely awkward dependency: Microsoft publishes
repositories for only a handful of distributions, Arch has just an AUR package
that cannot be installed non-interactively, and there was no Ubuntu 26.04
package for a long stretch.

`setup.sh` now installs Microsoft's **self-contained tarball** into
`~/.local/share/powershell` and symlinks `pwsh` into `~/.local/bin` — no root,
no repository added to your system, one code path on every glibc distribution.
It is the same approach the script already uses for `yt-dlp` and `deno`, both
of which live in `~/.local/bin` for the same reason.

Two consequences worth knowing:

- **Nothing updates it for you.** A package-managed install would ride your
  system's upgrade cycle; this one will not. `run_ytdlp.ps1`'s daily
  dependency check compares your running version against the newest published
  release and tells you to re-run `setup.sh` when you are behind.
- **It is not small** — roughly 176 MB extracted, since it bundles its own
  .NET runtime. That is the price of not depending on your distribution
  shipping one.

If `pwsh` extracts but will not run, the cause is almost always a missing
native library — `libicu` and `libssl` are the usual suspects, since the
tarball is self-contained for .NET but still links against those. Install your
distribution's ICU and OpenSSL packages.

### ffmpeg on Fedora and openSUSE

The one package that is still awkward. Both ship ffmpeg only through a
third-party repository for patent reasons — RPM Fusion on Fedora, Packman on
openSUSE. `setup.sh` deliberately **does not** enable those automatically:
adding a third-party package source is a lasting, system-wide change
affecting every future update on the machine, which is not a reasonable thing
for a video-archiver installer to decide unattended. If `ffmpeg` is missing
after the base install, the script warns with the exact command for your
distribution. Run it, then re-run `setup.sh`.

---

## Step 1: Update your system

```bash
sudo apt update && sudo apt upgrade -y
```

On a machine that is not a disposable VM, you may reasonably prefer to skip
the blanket `upgrade` and just refresh the index with `sudo apt update`.
Nothing below depends on a full system upgrade.

---

## Step 2: Install base dependencies

```bash
sudo apt install -y curl wget git ffmpeg ca-certificates \
                    apt-transport-https software-properties-common python3-pip
```

`ffprobe` ships inside the `ffmpeg` package — `postprocess.ps1` needs it for
the info.json re-embed step, so if `ffmpeg` installed correctly there is
nothing extra to do.

---

## Step 3: Install yt-dlp

Installed as a standalone binary into `~/.local/bin`, **not** via
`apt install yt-dlp`. Two reasons, and the second is the important one:

1. Distribution packages of yt-dlp go stale fast, and a stale yt-dlp is the
   single most common cause of extraction breaking.
2. yt-dlp's `-U` self-update rewrites its own binary by writing a temp file
   into the *containing directory* and renaming over the old one. That
   directory therefore has to be yours. `/usr/local/bin` is root-owned no
   matter who owns the file inside it, which is why `chown`-ing just the
   binary does not fix it — this was found the hard way.

```bash
mkdir -p "$HOME/.local/bin"
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
  -o "$HOME/.local/bin/yt-dlp"
chmod a+rx "$HOME/.local/bin/yt-dlp"
```

The plain `yt-dlp` asset is the Linux build (`yt-dlp_macos` and `yt-dlp.exe`
are the other two).

---

## Step 4: Install PowerShell 7 (`pwsh`)

```bash
source /etc/os-release
wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
  -O /tmp/packages-microsoft-prod.deb
sudo dpkg -i /tmp/packages-microsoft-prod.deb
rm -f /tmp/packages-microsoft-prod.deb
sudo apt update && sudo apt install -y powershell
```

If Microsoft has not published packages for your release — as was the case for
Ubuntu 26.04 for a while — fall back to the snap:

```bash
sudo snap install powershell --classic
```

Nothing in this pipeline runs without `pwsh`. Both `run_ytdlp.ps1` and
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
environment (PEP 668), which modern Debian and Ubuntu are. If your pip is old
enough not to recognise the flag, `python3 -m pip install -U --user "curl_cffi>=0.10"`
gets there another way.

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
```

You are not obliged to put it exactly there. `run_ytdlp.ps1` probes
`~/.local/bin/deno`, then `~/.deno/bin/deno`, then `PATH` — and if it finds
none of them it omits `--js-runtimes` entirely and logs a warning rather than
failing confusingly.

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
is recreated rather than being an error.

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

The viewer launcher, which `setup.sh` generates rather than shipping as a repo
file:

```bash
cat > "$HOME/.local/bin/ytdl-view" <<'EOF'
#!/usr/bin/env bash
exec python3 "$HOME/yt-dlp/scripts/archive-viewer.py" "$@"
EOF
chmod +x "$HOME/.local/bin/ytdl-view"
```

Then put `~/.local/bin` on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
source "$HOME/.bashrc"
```

(`setup.sh` checks `$SHELL` rather than assuming, so if your login shell is
zsh it appends to `.zshrc` instead.)

---

## Step 9: Desktop preview support — or skip it entirely

**On a headless machine, skip this step.** Nothing in the pipeline needs any
of it; downloads and post-processing are byte-identical without it. `setup.sh`
detects whether a desktop is actually installed (by looking for a file manager
binary or a desktop metapackage, *not* by reading `$DISPLAY`, which would
wrongly report headless when you are simply connected over SSH) and skips the
whole step on a server install, where these packages would drag in a large GUI
dependency tree for nothing.

On a desktop machine:

```bash
sudo apt install -y webp-pixbuf-loader ffmpegthumbnailer gnome-sushi
sudo apt install -y mpv vlc
```

- `webp-pixbuf-loader` — yt-dlp saves the original thumbnail in whatever
  format YouTube served, which is almost always `.webp`. GTK and Nautilus
  cannot render webp at all without this, so `Images/Thumbnail.webp` shows a
  generic icon. (`postprocess.ps1` also writes a `Thumbnail.png` alongside it,
  which displays regardless — this is what makes the original viewable too.)
- `ffmpegthumbnailer` — poster-frame thumbnails for the `.mkv` files.
- `gnome-sushi` — spacebar preview in Nautilus, which works on the images, the
  videos, and the `.vtt` subtitle files as plain text.

Nautilus refuses to thumbnail files above a size cap that defaults to 10 MB —
far below any real video here — so raise it, or `ffmpegthumbnailer` will
appear to do nothing:

```bash
gsettings set org.gnome.nautilus.preferences thumbnail-limit 4096
```

That value is in megabytes, so 4096 is 4 GB. The key has come and gone across
GNOME versions; if `gsettings` errors that the key does not exist, your version
does not have it and video thumbnails should work anyway.

Thumbnails are cached, so folders you browsed before this step may keep showing
generic icons until you log out and back in, or `rm -rf ~/.cache/thumbnails`.

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

Check `yt-dlp` and `deno` **by full path**, not bare command name.
`~/.local/bin` was only just added to `PATH`, and in a shell started before
that change a bare `yt-dlp` reports "not found" immediately after a successful
install.

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
working, not a hang.

Watch it work:

```bash
tail -f "$HOME/scratch-test/Archive Logs/Logs/download.log"
```

When it finishes, the video folder should contain `Final files/Final Video.mkv`
and nothing else at that level — the `--keep-video` pre-merge streams are moved
to a sibling `Pre-merge streams/` folder. Verify integrity:

```bash
cd "$HOME/scratch-test/Youtube Videos/Complete Archive/<Uploader>/<video folder>"
sha256sum -c "Video metadata/checksums.sha256"
```

Every line should read `OK`.

---

## Step 12: Read what you archived

```bash
ytdl-view --root "$HOME/scratch-test"
```

Then open `http://127.0.0.1:8777`. Add `--allow-open-local` to let the page
hand files to mpv or VLC. The viewer reads the archive without ever writing to
it and keeps derived state in `~/.cache/ytdlp-archive-viewer`, deliberately
outside the archive so the `checksums.sha256` files keep verifying.

---

## Where to put the archive

This is the main thing a bare-metal install has to decide for itself. In the VM
setup, the archive lives inside the guest and reaches the host through a
VMware shared folder. With no hypervisor there is no shared folder, and the
question becomes a plain one about local storage.

**On the system disk (the default).** Do nothing; the archive lives at
`~/yt-dlp/Youtube Videos`. Fine until it isn't — this pipeline keeps the merged
video, the pre-merge video-only and audio-only streams (`--keep-video`), *and*
a second full copy of the merged file under `Final Video/`. Budget roughly
**three times** the nominal size of what you download.

**On a separate disk or a mount.** Pass the path and nothing else changes:

```bash
ytdl "<url>" /mnt/archive
```

Or set it once so you never type it:

```bash
alias ytdl-archive='ytdl "$1" /mnt/archive'
```

Only the *data* moves. `scripts/` and `configs/` always stay at
`~/yt-dlp`, because `ytdl` has to find `run_ytdlp.ps1` before it can parse any
arguments. If you want the install itself elsewhere too, set
`YTDLP_INSTALL_ROOT` — every component reads it.

**On a NAS or network mount — one real caveat.** `postprocess.ps1` serialises
its manifest writes with advisory file locks (opening a lock file with
`FileShare.None`). File locking semantics over NFS and SMB are notoriously
inconsistent, and this has not been tested on a network mount. If you put the
data root on a network share, **either keep `--workers` at 1**, or test a
parallel run and confirm afterwards that `global_manifest.json` contains one
entry per video with none silently lost. On local storage this is a solved
problem and needs no thought.

---

## Running it unattended

A machine that is always on is the case a VM guide never really addresses.

**Scheduled channel syncs.** `--sync` stops as soon as it reaches a video
already in the archive, which makes it cheap to re-run against a channel you
have mostly archived. A systemd user timer is the tidy way to do that
periodically. `~/.config/systemd/user/ytdl-sync.service`:

```ini
[Unit]
Description=yt-dlp channel sync

[Service]
Type=oneshot
ExecStart=%h/.local/bin/ytdl "https://www.youtube.com/@SomeChannel/videos" --sync
```

And `~/.config/systemd/user/ytdl-sync.timer`:

```ini
[Unit]
Description=Run the yt-dlp channel sync daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Then:

```bash
systemctl --user daemon-reload
systemctl --user enable --now ytdl-sync.timer
sudo loginctl enable-linger "$USER"     # so it runs when you are not logged in
```

The `loginctl enable-linger` line is the one people miss: without it, user
timers only run while you have an active session.

**One caution on `--sync` plus `--workers`.** `--sync` relies on the source
being in newest-first order, which a channel's default `/videos` listing is.
Combined with `--workers > 1` it is reimplemented manually — the enumerated
list is truncated at the first already-archived ID. That is correct for a
channel listing and wrong for a reordered or filtered source, which could stop
before reaching genuinely new videos further down.

**Sleep and suspend.** A desktop will suspend mid-download. Either disable
suspend, or wrap long runs:

```bash
systemd-inhibit --what=sleep --why="archiving" ytdl "<url>" --workers 3
```

**Logs grow.** `download.log` is cumulative and never rotated, and a run with
`--workers N` also leaves one `download.worker-<id>.log` per video under
`Archive Logs/Logs/`. Those are deliberately not cleaned up — keeping real logs
is this project's stated preference — but on a long-running box they
accumulate. Everything in a worker log is duplicated into that video's own
`Logs/video_complete.log`, so deleting old ones by hand costs nothing.

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
    Logs/              download.log, archive.txt, download.worker-<id>.log, setup_*.log
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

~/.cache/ytdlp-archive-viewer/    viewer's derived state (disposable)
```

If you passed a custom data root, only `Archive Logs/` and `Youtube Videos/`
move there; everything above them stays at `~/yt-dlp`.
