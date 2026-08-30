# Setting Up the yt-dlp Archival Pipeline on a Fresh Linux VM

> **Shortcut:** `setup.sh` automates every step below (1 through 11) in one run. Run `chmod +x setup.sh && ./setup.sh`. It's idempotent -- safe to re-run if you want to retry a step that needed manual attention. It also does one thing with no manual equivalent below: it downloads the five project files it needs (`linux-ytdl`, `linux-run_ytdlp.ps1`, `linux-postprocess.ps1`, `linux-yt-dlp.conf`, `archive-viewer.py`) straight from GitHub into a scratch folder, then deletes that folder once they're copied into place -- unnecessary when you already have the files in front of you, which is the case if you're following these steps by hand. If any of those files are already sitting next to `setup.sh`, it uses those and doesn't download over them, so running it from inside a clone of this repo keeps your local edits. Steps 12 and 13 (the first test run, and opening the viewer) are yours to do either way. It does **not** hard-abort on a failed non-critical step (an earlier version did, which is what caused `ytdl` not to get installed automatically the first time around -- see the note in Step 7 below); instead it prints a summary of anything that needs a manual look at the very end. The manual steps below are still here for reference, or if you want to run things by hand.
>
> **It used to `git clone` the whole repo here and no longer does.** To be clear about why, since the obvious guess is wrong: it was not for disk space. That clone was scratch and got deleted a few steps later, so it cost roughly 400 KB transiently against an archive measured in gigabytes. The actual reasons are that this was the only thing in the entire project that ever needed `git`, that a plain HTTPS GET of five known filenames doesn't care whether the repo is public, private, or reachable over SSH, and that it has fewer ways to fail on a fresh VM. `git` is still installed in Step 2 and still checked in Step 11 -- you want it on this VM to work on the project; the pipeline just doesn't depend on it any more.

As of this version, `setup.sh` and the pipeline files are also fully
**username- and path-independent** -- nothing below needs any
find-and-replace step. Everything resolves from `$HOME` automatically,
whichever account actually runs it.

---

## Step 1: Update the system

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Step 2: Install base dependencies

```bash
sudo apt install -y curl wget git ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip
```

Verify:
```bash
ffmpeg -version
ffprobe -version
python3 --version
```

`python3` is not in the install line above because Ubuntu always ships it and
`python3-pip` depends on it anyway. It is listed here because the archive
viewer (Step 10) needs it, and nothing else in the pipeline does — if that
line fails, `sudo apt install -y python3` and everything else still works in
the meantime.

---

## Step 3: Install yt-dlp

Install the **standalone binary** (not the `apt` package). This matters
because `run_ytdlp.ps1` calls `yt-dlp -U` for self-updates, which only
actually does anything for a standalone-binary install — it silently no-ops
if yt-dlp came from `apt`.

Install it into `$HOME/.local/bin`, **not** `/usr/local/bin`. A real run
showed self-update failing even after `chown`ing the binary itself:
yt-dlp's updater writes a temp file into the **containing directory** and
renames it over the old binary, and `/usr/local/bin` is root-owned no
matter who owns the file inside it. Installing into a directory you
already own outright sidesteps the problem instead of patching around it.

```bash
mkdir -p "$HOME/.local/bin"
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "$HOME/.local/bin/yt-dlp"
chmod a+rx "$HOME/.local/bin/yt-dlp"
```

Verify (by full path — `~/.local/bin` may not be on this shell's `PATH`
until Step 10 adds it and you open a new shell):
```bash
"$HOME/.local/bin/yt-dlp" --version
```

---

## Step 4: Install PowerShell 7 (`pwsh`)

**As of this writing, Microsoft has not published `apt` packages for Ubuntu
26.04 ("Resolute Raccoon")** — the repo bootstrap file exists, but the actual
`powershell` package isn't in it yet. This is a known, open gap on
Microsoft's end with no published ETA. `setup.sh` tries `apt` first and
falls back to `snap` automatically; doing it by hand:

```bash
sudo snap install powershell --classic
```

Verify:
```bash
pwsh --version
```

<details>
<summary>Once Microsoft publishes the 26.04 apt package (for later)</summary>

```bash
sudo snap remove powershell
source /etc/os-release
wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt update
sudo apt install -y powershell
pwsh --version
```
</details>

---

## Step 5: Install `curl_cffi` (fixes the "no impersonate target" warning)

Some extractors ask yt-dlp to impersonate a real browser's TLS/HTTP
fingerprint to avoid bot detection. Without `curl_cffi` installed, you'll
see:
```
WARNING: The extractor specified to use impersonation for this download, but no impersonate target is available.
```

```bash
python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages
```

(`--break-system-packages` is needed because Ubuntu marks the system Python
environment as externally-managed by default.)

---

## Step 6: Install Deno (JavaScript runtime — required for current YouTube extraction)

**This is a newer requirement, and it's important.** As of mid-2026,
YouTube requires solving a JavaScript challenge for cipher decryption
before it will serve video data. Without a JS runtime installed, yt-dlp
falls back to less reliable client/format combinations — which shows up
not just as a warning, but as a real, tangible failure mode:

```
WARNING: [youtube] No supported JavaScript runtime could be found. Only deno is enabled by default...
```
...often followed, mid-download, by:
```
ERROR: unable to download video data: HTTP Error 403: Forbidden
```

These two are connected. If you're seeing the JS-runtime warning, expect
403s on some videos until this is fixed — updating yt-dlp alone does not
resolve it (see yt-dlp/yt-dlp#14404).

Install Deno:
```bash
curl -fsSL https://deno.land/install.sh | sh -s -- -y
mkdir -p "$HOME/.local/bin"
cp "$HOME/.deno/bin/deno" "$HOME/.local/bin/deno"
chmod a+rx "$HOME/.local/bin/deno"
```

Verify:
```bash
"$HOME/.local/bin/deno" --version
```

`$HOME/.local/bin/deno` is the exact path the pipeline looks for, so don't
substitute another location without updating the pipeline too. It's
`run_ytdlp.ps1` that passes `--js-runtimes "deno:$HOME/.local/bin/deno"`,
built fresh from `$HOME` at invocation time — **not** `yt-dlp.conf`, which
is deliberately static, username-independent text with no per-user paths
in it at all (yt-dlp config files are read as plain text and never expand
`~` or `$HOME`). Passing it explicitly also means yt-dlp doesn't have to
find `deno` on a `PATH`, which inside yt-dlp's own process — and anything
it spawns — isn't guaranteed to match your interactive shell's.

> If you already ran a video through the pipeline before installing Deno
> and hit a 403 partway through, just re-run the same URL — the
> `--download-archive` dedup only marks a video complete after it fully
> finishes, so a failed attempt doesn't block a retry.

---

## Step 7: Set up the VMware Workstation Pro shared folder (no reboot needed)

This lets you browse the archive (or drop in files) from the Windows/macOS
host without SCP/SFTP.

> **Why this step used to need a reboot, and why it doesn't anymore:** an
> earlier version of `setup.sh` told you to `sudo reboot` after installing
> the guest tools, which caused two real problems. First, some VMware/Ubuntu
> combinations don't shut down cleanly on `sudo reboot` and need
> `sudo reboot -f` to actually restart. Second — and this is the more
> important one — if a script triggers a reboot mid-run, **the script's own
> process dies right there along with the OS**. A shell script isn't a
> background service; it doesn't wake back up and resume after the machine
> comes back. Any steps after the reboot line (folder creation, placing
> the pipeline files) simply never ran. The fix is to not need a reboot at
> all: restarting the VMware tools service directly and mounting the share
> immediately gets it working in the same session.

**7a. Enable the shared folder in VMware Workstation Pro (on the host):**
1. **VM menu → Settings → Options tab → Shared Folders**.
2. Select **Always enabled**.
3. Click **Add...**, browse to the host folder you want shared, name it
   (e.g. `yt-dlp-share`), finish the wizard.
4. Make sure the VM is powered on.

**7b. Install the guest tools and mount immediately (inside Ubuntu):**
```bash
sudo apt install -y open-vm-tools open-vm-tools-desktop
sudo systemctl restart open-vm-tools.service
sudo mkdir -p /mnt/hgfs
sudo vmhgfs-fuse .host:/ /mnt/hgfs -o subtype=vmhgfs-fuse,allow_other
```

> `open-vm-tools-desktop` is only needed for GUI integration; on a
> headless/server install it can fail to resolve its desktop-environment
> dependencies. If the `apt install` above fails, drop `-desktop` and just
> run `sudo apt install -y open-vm-tools` — the shared-folder mount itself
> doesn't need it.

**7c. Make the mount persist across reboots:**
```bash
echo '.host:/    /mnt/hgfs   fuse.vmhgfs-fuse    defaults,allow_other    0    0' | sudo tee -a /etc/fstab
```

You should now see your named share (e.g. `/mnt/hgfs/yt-dlp-share`)
immediately, with no reboot involved. If the direct mount genuinely doesn't
work (rare), a full `sudo reboot -f` is the last-resort fallback — but try
the above first.

This is optional for the pipeline itself — nothing in the scripts requires
it — but it's a convenient way to pull finished archives off the VM, or
drop in the project files from the host instead of re-typing them.

It also makes the second half of Step 13 possible: with the archive visible
on the host, you can run the viewer **on the host** against the mounted
share instead of inside the VM, which is usually the nicer place to watch
things.

---

## Step 8: Install desktop preview support (thumbnails and subtitles)

Optional, and desktop-only. Nothing in the pipeline needs any of this —
downloads and post-processing behave identically without it. This is
purely so the finished archive is **browsable from inside the VM**:
thumbnails that preview in the file manager instead of showing generic
icons, and a player that renders the subtitle tracks over the video.
Skip this entirely on a headless/server install (`setup.sh` detects that
case and skips it for you); the packages pull in a large GUI dependency
tree that would be dead weight there.

**8a. Thumbnailers:**
```bash
sudo apt install -y webp-pixbuf-loader ffmpegthumbnailer gnome-sushi
```

- `webp-pixbuf-loader` is the one that matters most. yt-dlp saves the
  **original** thumbnail in whatever format YouTube served, which is
  essentially always `.webp`, and GTK/Nautilus cannot render webp at all
  without this loader — so `Images/Thumbnail.webp` shows a generic icon
  and won't open in the image viewer either. (`postprocess.ps1` also
  writes a `Thumbnail.png` next to it, which displays fine regardless;
  this is what makes the original viewable too.)
- `ffmpegthumbnailer` installs a `.thumbnailer` entry so `Final
  Video.mkv` previews as its own poster frame rather than a generic film
  icon.
- `gnome-sushi` gives you spacebar preview in Nautilus — works on the
  images, the videos, **and** the `.vtt` subtitle files as plain text,
  without opening a separate application for each.

**8b. A player that shows the subtitles:**
```bash
sudo apt install -y mpv vlc
```

Both handle the subtitles this pipeline produces in each of the two forms
it writes them: the tracks muxed into the `.mkv` by `--embed-subs`, and
the sidecar `.vtt` files under each video's `Subtitles/` folder. `mpv` is
the lightweight one; `vlc` is worth having as well because its subtitle
track menu is far more discoverable, and it auto-loads a sidecar subtitle
file sitting next to the video without being asked.

**8c. Raise the Nautilus thumbnail size limit:**
```bash
gsettings set org.gnome.nautilus.preferences thumbnail-limit 4096
```

Nautilus refuses to thumbnail files above a size cap that **defaults to 10
MB** — far below any real video here. Without raising it, the
`ffmpegthumbnailer` install above appears to do nothing at all for your
`.mkv` files: the thumbnailer is installed and working, it just never gets
invoked. The value is in megabytes per Nautilus's own schema, so 4096 = 4
GB, comfortably above a long 4K download.

> If this errors with something like *"No such key"*, your GNOME version's
> Nautilus schema doesn't have that key — it has come and gone across
> releases. That's harmless; skip it and video thumbnails should still
> work. (`setup.sh` checks for the key before setting it, for this
> reason.)

**8d. Clear stale thumbnail caches:**

The file manager caches thumbnails, so any folder you already browsed
*before* installing the loaders above will keep showing generic icons.
Force them to regenerate:
```bash
rm -rf ~/.cache/thumbnails
```
Then reopen the file manager (or log out and back in).

---

## Step 9: Create the folder structure

```bash
mkdir -p "$HOME/yt-dlp/scripts"
mkdir -p "$HOME/yt-dlp/configs"
mkdir -p "$HOME/yt-dlp/Archive Logs/Archive History"
mkdir -p "$HOME/yt-dlp/Archive Logs/Logs"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Complete Archive"
mkdir -p "$HOME/yt-dlp/Youtube Videos/_incomplete"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Final Video"
```

(`run_ytdlp.ps1` also self-heals this same structure on every run, so a
later wipe doesn't require redoing this step by hand.)

---

## Step 10: Place the project files and put `ytdl` / `ytdl-view` on your `PATH`

```bash
cp linux-run_ytdlp.ps1   "$HOME/yt-dlp/scripts/run_ytdlp.ps1"
cp linux-postprocess.ps1 "$HOME/yt-dlp/scripts/postprocess.ps1"
cp linux-yt-dlp.conf     "$HOME/yt-dlp/configs/yt-dlp.conf"
cp archive-viewer.py     "$HOME/yt-dlp/scripts/archive-viewer.py"
mkdir -p "$HOME/.local/bin"
cp linux-ytdl "$HOME/.local/bin/ytdl"
chmod +x "$HOME/.local/bin/ytdl" "$HOME/yt-dlp/scripts/archive-viewer.py"
```

`archive-viewer.py` goes in `scripts/` rather than on your `PATH` because it
is a program, not a command. The command is a one-line launcher, which
`setup.sh` generates rather than shipping as a repo file — by hand it is:

```bash
cat > "$HOME/.local/bin/ytdl-view" <<'EOF'
#!/usr/bin/env bash
exec python3 "$HOME/yt-dlp/scripts/archive-viewer.py" "$@"
EOF
chmod +x "$HOME/.local/bin/ytdl-view"
```

Note this file has no `linux-` prefix, unlike the four above. That's
deliberate: it's pure Python standard library with no OS-specific anything,
so the exact same file runs on the Windows/macOS host against a mounted
archive. Nothing to install for it beyond `python3` itself — no pip, no
virtualenv.

Ubuntu usually adds `~/.local/bin` to `PATH` automatically for login shells,
but confirm it's actually there:
```bash
echo $PATH | tr ':' '\n' | grep -q "$HOME/.local/bin" && echo "already on PATH" || echo "NOT on PATH yet"
```
If it says "NOT on PATH yet":
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

---

## Step 11: Verify everything is wired up

```bash
"$HOME/.local/bin/yt-dlp" --version
ffmpeg -version | head -n 1
pwsh --version
"$HOME/.local/bin/deno" --version | head -n 1
git --version
python3 --version
command -v ytdl
command -v ytdl-view
PYTHONPYCACHEPREFIX=/tmp python3 -m py_compile "$HOME/yt-dlp/scripts/archive-viewer.py" && echo "viewer: OK"
head -n 1 "$HOME/yt-dlp/configs/yt-dlp.conf"
```

All of these should resolve without error, and the last command should
print the current `CONFIG_VERSION` line.

The `py_compile` line parses the viewer without running it — it is there to
catch a truncated or corrupted copy, which a plain `cp` has no way to
notice. `PYTHONPYCACHEPREFIX=/tmp` keeps the resulting `.pyc` out of
`scripts/`.

`yt-dlp` and `deno` are checked **by full path** on purpose. Both live in
`$HOME/.local/bin`, which Step 10 may have only just appended to
`~/.bashrc` — that doesn't take effect until you open a new shell, so a
bare `yt-dlp --version` here can report "not found" immediately after a
perfectly successful install. `ffmpeg`/`pwsh`/`git` are unaffected, being
apt-installed onto a location already on `PATH`.

If you did Step 8, these should work too (skip if you went headless):
```bash
mpv --version | head -n 1
vlc --version | head -n 1
dpkg -s webp-pixbuf-loader >/dev/null 2>&1 && echo "webp thumbnails: OK"
[ -f /usr/share/thumbnailers/ffmpegthumbnailer.thumbnailer ] && echo "video thumbnails: OK"
```

---

## Step 12: First real test run

Pick a short, low-comment-count video for the first run:
```bash
ytdl "https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID"
```

Or, to send data somewhere other than the default `$HOME/yt-dlp`:
```bash
ytdl "https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID" "/mnt/hgfs/yt-dlp-share/archive"
```

Watch for:
- The `Youtube Videos/Complete Archive/<uploader>/...` folder tree getting
  created with real (not literal `%(uploader)s`) names.
- `Archive Logs/Logs/download.log` growing with session start/end markers.
- No `No supported JavaScript runtime` warning (Step 6 should have
  resolved that).
- After the main download finishes, `postprocess.ps1` kicking off — its
  `[comments]`, `[ffmpeg-reembed]`, and `[channel-info]`-prefixed lines
  appearing in the console.
- A finished `video_postprocessing.log` inside that video's own `Logs/`
  subfolder — **this is the file to paste back into a Claude conversation**
  if anything looks wrong.

---

## Step 13: Read what you just archived

The pipeline saves far more than a media player can show you — the whole
comment thread most of all. `ytdl-view` serves the archive as a local web
page: video with the subtitle tracks attached, the full threaded comment
section (sortable, searchable, with in-comment timestamps that seek the
player), a clickable transcript, the description and chapters as seek links,
every metadata file, and a browser for every file in the folder.

```bash
ytdl-view
```

That auto-detects `$HOME/yt-dlp`, prints a URL, and opens it. If you archived
somewhere else, point it there:

```bash
ytdl-view --root "/mnt/hgfs/yt-dlp-share/archive"
```

Useful additions:

```bash
ytdl-view --allow-open-local     # let the page hand a file to mpv/vlc (Step 8)
ytdl-view --rescan               # ignore the cached index, re-read every info.json
ytdl-view --help                 # everything else
```

**On the host instead of in the VM.** The viewer only reads the archive, and
it is plain Python with no dependencies, so if you set up the shared folder
in Step 7 you can copy `archive-viewer.py` to the Windows/macOS host and run
it there against the mounted archive:

```bash
python3 archive-viewer.py --root "/Volumes/yt-dlp-share/archive" --allow-open-local
```

Three things worth knowing before you use it:

- **It never writes to the archive.** Its index, the split-out comment files,
  and any remuxed playback copies live in `~/.cache/ytdlp-archive-viewer`
  (`~/Library/Caches/...` on macOS, `%LOCALAPPDATA%\...` on Windows). This
  matters because `postprocess.ps1` writes a `checksums.sha256` covering
  every file in a video folder — derived files dropped in there would make
  that stop verifying. The cache is disposable; delete it any time.
- **Some videos show a one-click "prepare" step before playing.** No browser
  plays Matroska. When the streams inside are VP9/AV1 + Opus the `.mkv` is
  byte-compatible with WebM and plays straight from the archive with no copy
  at all — that's most of what this pipeline pulls. Otherwise ffmpeg copies
  the existing video and audio into an MP4 (`-c copy`, nothing re-encoded,
  usually seconds) in the cache. A genuine re-encode is only ever offered
  explicitly, and `--no-transcode` removes even the offer.
- **`--host 0.0.0.0` has no authentication of any kind.** It's how you watch
  on a phone or TV, and it exposes every file in the archive to anything that
  can reach the port. Fine on a home LAN, a bad idea anywhere else — which is
  why the default binds to this machine only.

If a video's comment tab is empty but the count on the card says otherwise,
the comments pass failed at download time rather than the viewer failing to
read them: open the **Files** tab and read `video_postprocessing.log`.

---

## Quick reference: what lives where after setup

```
$HOME/yt-dlp/                      (install root -- always here, regardless of -DataRoot)
├── scripts/
│   ├── run_ytdlp.ps1
│   ├── postprocess.ps1
│   └── archive-viewer.py  (read-only consumer of the archive; not part of a download)
└── configs/
    └── yt-dlp.conf

$HOME/yt-dlp/  <or a custom -DataRoot>
├── Archive Logs/
│   ├── Archive History/
│   └── Logs/            (download.log, archive.txt)
└── Youtube Videos/
    ├── Complete Archive/
    ├── _incomplete/
    └── Final Video/

$HOME/.local/bin/
├── ytdl                  (download entry point, on PATH)
├── ytdl-view             (viewer launcher, on PATH -- generated by setup.sh, not copied)
├── yt-dlp                (standalone binary -- here, not /usr/local/bin, so -U can self-update)
└── deno                  (exact path run_ytdlp.ps1 passes via --js-runtimes)

$HOME/.cache/ytdlp-archive-viewer/   (viewer's own derived files -- deliberately NOT
                                      inside the archive, so checksums.sha256 keeps
                                      verifying; safe to delete at any time)

/mnt/hgfs/<share-name>/   (VMware shared folder, host <-> guest)
```
