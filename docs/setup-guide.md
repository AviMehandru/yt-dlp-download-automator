# Setting Up the yt-dlp Archival Pipeline

One guide for Linux, macOS and Windows. Every step below shows the command for
each platform side by side, because the twelve steps are the same twelve steps
everywhere — only the package manager and the path separators change.

This replaces the four separate guides this repo used to carry
(`linux-setup-guide.md`, `mac-setup-guide.md`, `windows-setup-guide.md` and
`linux-vm-setup-guide.md`). They shared roughly two-thirds of their prose, and
keeping four copies of the same explanation in sync was a losing game — the
same reason the installer itself was consolidated. The genuinely
VMware-specific material survives intact as [Step 5](#step-5-vmware-shared-folder-linux-vm-guests-only)
and the [VM supplement](#supplement-running-in-a-vmware-vm) at the end.

The pipeline scripts themselves — `run_ytdlp.ps1`, `postprocess.ps1`,
`ytdl.ps1`, `yt-dlp.conf`, `archive-viewer.py` — are one shared set, installed
unmodified on all three platforms. Only the installation differs.

---

## Shortcut: just run the installer

Everything below Step 1 is automated. The manual steps are here for reference
and for when a step needs attention.

**Linux and macOS**

```bash
chmod +x setup.sh && ./setup.sh
```

**Windows**

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Both are idempotent and safe to re-run — every step checks before it acts.
Neither needs administrator rights. Neither hard-aborts on a failed
non-critical step; each prints a summary of anything needing a manual look at
the end.

`setup.sh` needs no flag to tell it which situation it is in. It reads
`uname -s` for macOS versus Linux, `/etc/os-release` for the distribution
family, and `systemd-detect-virt` plus the DMI product name for whether it is
running inside a VMware guest. On bare metal it prints *"Not detected as a
VMware guest — skipping shared folder setup"* and moves on.

### How the installer is put together

The installer is two files, and knowing which is which helps when a step fails.

| | Steps | What it is |
|---|---|---|
| `setup.sh` / `setup.ps1` | 1–6 | **Bootstrap.** Package-manager work, plus installing `pwsh` itself. Native to each platform: bash for Linux and macOS, Windows PowerShell 5.1 for Windows. |
| `scripts/setup-common.ps1` | 7–12 | **Shared.** Identical on all three platforms. Runs under the `pwsh` that Step 4 just installed. |

The split lands there because Steps 1–6 have nearly nothing worth sharing —
they are apt/dnf/pacman/zypper/brew/winget invocations with per-family quirks,
plus two steps (VMware shared folders, desktop previews) that mean something
different on every platform. Steps 7–12 are the opposite: fetching files,
creating folders, copying things into place, wiring `PATH` and verifying are
the same work everywhere.

**One consequence worth stating plainly.** Steps 7–12 run under `pwsh`, so if
Step 4 fails to install it, the bootstrap stops with an explanation instead of
continuing. Previously it carried on and placed the files anyway — but every
one of those files is a PowerShell script, so that produced a
complete-looking install that could not download anything. Install `pwsh` by
hand and re-run; re-running is cheap.

---

## Prerequisites

**Linux** — none beyond a working package manager. See
[the note on distributions](#a-note-on-distributions).

**macOS** — two things, and neither is installed for you.

Xcode Command Line Tools, which provide `git` and `python3`:

```bash
xcode-select --install
```

Homebrew, which installs everything else:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

`setup.sh` deliberately does **not** install Homebrew for you. Its installer
needs `sudo` and writes into system-owned directories, and running that
silently as a side effect of setting up a video archiver is not a reasonable
thing for a script to decide on its own. If Homebrew is missing, `setup.sh`
warns and skips the package steps.

**Windows** — winget, which installs everything except yt-dlp and deno. It
ships with Windows 11 and Windows 10 1809+ as part of "App Installer", but can
be missing on a stripped image or an account that has never opened the Store.

```powershell
winget --version
```

If that fails, install App Installer from the Microsoft Store or
<https://aka.ms/getwinget>. `setup.ps1` warns and continues without it.

---

## A note on the install root

| Platform | Install root | Commands land in |
|---|---|---|
| Linux | `~/yt-dlp` | `~/.local/bin` |
| macOS | `~/yt-dlp` | `~/.local/bin` |
| Windows | `C:\yt-dlp` | `%USERPROFILE%\.local\bin` |

Everything resolves from `$HOME` (or `%USERPROFILE%`) automatically, so there
is no find-and-replace step and nothing below depends on your username.

**Why Windows is the exception.** `MAX_PATH`. Windows still caps most paths at
260 characters unless long-path support is explicitly enabled, and this
pipeline's per-video paths are genuinely long — a 40-character uploader folder,
then a second folder repeating uploader + upload date + video id + a
60-character title, then `Pre-merge streams\Final Video.f137.mp4`. That reaches
roughly 240 characters *before* the data root is prefixed. `C:\yt-dlp` spends 9
characters of that budget; `C:\Users\<your name>\yt-dlp` can easily spend twice
as much and push real videos over the limit. Creating a folder at the root of
`C:` does not require administrator rights.

To install somewhere else entirely, set `YTDLP_INSTALL_ROOT` — every component
reads it (both launcher shims, `ytdl.ps1`, both pipeline scripts, the
installer):

```powershell
[Environment]::SetEnvironmentVariable("YTDLP_INSTALL_ROOT", "D:\yt-dlp", "User")
```

```bash
export YTDLP_INSTALL_ROOT="/srv/yt-dlp"      # and add it to your shell rc
```

### Enabling long paths on Windows (recommended)

Worth doing regardless. As Administrator:

```powershell
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
  -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
```

Then reboot. Step 12 reports whether this is set. The install root stays at
`C:\yt-dlp` either way — a data root that moved depending on a machine setting
would be worse than one that is merely inconsistent between platforms, because
you would not reliably know where your own archive is.

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
keeps going. The package steps are skipped, but everything that places the
pipeline still runs. Install the dependencies however your system does it and
let the installer do the rest.

### PowerShell is no longer a distro problem

It used to be the one genuinely awkward dependency: Microsoft publishes
repositories for only a handful of distributions, Arch has just an AUR package
that cannot be installed non-interactively, and there was no Ubuntu 26.04
package for a long stretch.

`setup.sh` now installs Microsoft's **self-contained tarball** into
`~/.local/share/powershell` and symlinks `pwsh` into `~/.local/bin` — no root,
no repository added to your system, one code path on every glibc distribution.
It is the same approach the script already uses for `yt-dlp` and `deno`.

Two consequences worth knowing:

- **Nothing updates it for you.** A package-managed install would ride your
  system's upgrade cycle; this one will not. `run_ytdlp.ps1`'s daily dependency
  check compares your running version against the newest published release and
  tells you to re-run `setup.sh` when you are behind.
- **It is not small** — roughly 176 MB extracted, since it bundles its own .NET
  runtime. That is the price of not depending on your distribution shipping one.

If `pwsh` extracts but will not run, the cause is almost always a missing
native library — `libicu` and `libssl` are the usual suspects, since the
tarball is self-contained for .NET but still links against those.

### ffmpeg on Fedora and openSUSE

Both ship ffmpeg only through a third-party repository for patent reasons —
RPM Fusion on Fedora, Packman on openSUSE. `setup.sh` deliberately **does not**
enable those automatically: adding a third-party package source is a lasting,
system-wide change affecting every future update on the machine, which is not a
reasonable thing for a video-archiver installer to decide unattended. If
`ffmpeg` is missing after the base install, the script warns with the exact
command for your distribution. Run it, then re-run `setup.sh`.

---

# Steps 1–6: the bootstrap

## Step 1: Update your system

**Linux**

```bash
sudo apt update && sudo apt upgrade -y          # debian family
sudo dnf upgrade -y                             # fedora family
sudo pacman -Syu --noconfirm                    # arch family
sudo zypper --non-interactive update            # suse family
```

On a machine that is not a disposable VM you may reasonably prefer to skip the
blanket upgrade and just refresh the index. Nothing below depends on a full
system upgrade.

> On Arch, note there is no index-only refresh step. A bare `pacman -Sy`
> without `-u` is a partial upgrade — the classic way to break an Arch install,
> since you refresh the package index but leave the system on older libraries.
> `setup.sh` does the full `-Syu` for this reason.

**macOS**

```bash
brew update
brew upgrade
```

**Windows**

```powershell
winget source update
```

Only the source index. Unlike the Unix installer, `setup.ps1` does **not** run
`winget upgrade --all` — a full system upgrade is defensible on a purpose-built
VM, but a Windows machine running this is far more likely to be your daily
driver, and silently upgrading every installed application as a side effect of
setting up a video archiver is not this script's call to make.

---

## Step 2: Install base dependencies

**Linux**

```bash
sudo apt install -y curl wget git ffmpeg ca-certificates \
                    apt-transport-https software-properties-common python3-pip
```

(The installer asks for packages by *role* rather than naming apt packages
inline, so the equivalent lists for dnf, pacman and zypper are already built in.)

**macOS**

```bash
brew install ffmpeg git wget
```

Far shorter than the Linux list, because macOS already ships `curl` and the
Command Line Tools provide `git` and `python3`.

**Windows**

```powershell
winget install --id Gyan.FFmpeg         --exact --silent --accept-source-agreements --accept-package-agreements
winget install --id Git.Git             --exact --silent --accept-source-agreements --accept-package-agreements
winget install --id Python.Python.3.12  --exact --silent --accept-source-agreements --accept-package-agreements
```

The `--accept-*-agreements` flags are required for an unattended run; without
them winget stops and waits for a keypress that will never come.

**Open a new terminal after this step.** winget puts these on `PATH`, but your
current session inherited its environment before that happened.

**All platforms:** `ffprobe` ships inside the same ffmpeg package —
`postprocess.ps1` needs it for the info.json re-embed step, so if `ffmpeg`
installed correctly there is nothing extra to do. Python is only needed by the
archive viewer; nothing in the download pipeline touches it.

---

## Step 3: Install yt-dlp

Installed as a **standalone binary** into your own `bin` directory on every
platform, not through the package manager. Two reasons, and the second is the
important one:

1. Distribution packages of yt-dlp go stale fast, and a stale yt-dlp is the
   single most common cause of extraction breaking.
2. yt-dlp's `-U` self-update rewrites its own binary by writing a temp file
   into the *containing directory* and renaming over the old one. That
   directory therefore has to be yours. `/usr/local/bin` is root-owned no
   matter who owns the file inside it, which is why `chown`-ing just the binary
   does not fix it — this was found the hard way. Homebrew's prefix has the
   same problem from the other direction: a Homebrew-installed yt-dlp refuses
   to self-update and tells you to use `brew upgrade`, which means the
   once-a-day `yt-dlp -U` in `run_ytdlp.ps1` silently does nothing.

Each platform has its own release asset:

| Platform | Asset |
|---|---|
| Linux | `yt-dlp` |
| macOS | `yt-dlp_macos` (universal — same file on Apple silicon and Intel) |
| Windows | `yt-dlp.exe` |

**Linux**

```bash
mkdir -p "$HOME/.local/bin"
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
  -o "$HOME/.local/bin/yt-dlp"
chmod a+rx "$HOME/.local/bin/yt-dlp"
```

**macOS**

```bash
mkdir -p "$HOME/.local/bin"
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos \
  -o "$HOME/.local/bin/yt-dlp"
chmod a+rx "$HOME/.local/bin/yt-dlp"
xattr -d com.apple.quarantine "$HOME/.local/bin/yt-dlp" 2>/dev/null
```

The `xattr` line matters. Anything downloaded carries a `com.apple.quarantine`
attribute, and Gatekeeper refuses to run a quarantined unsigned binary with
*"cannot be opened because the developer cannot be verified"* — which surfaces
as what looks like a broken download rather than a security prompt. Stripping
the attribute from a binary you just fetched over HTTPS from a known URL is the
same trust decision as choosing to install it at all.

**Windows**

```powershell
$localBin = Join-Path $env:USERPROFILE ".local\bin"
New-Item -ItemType Directory -Path $localBin -Force | Out-Null
Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" `
  -OutFile (Join-Path $localBin "yt-dlp.exe") -UseBasicParsing
Unblock-File -Path (Join-Path $localBin "yt-dlp.exe")
```

`-UseBasicParsing` is harmless on PowerShell 7 and **required** on Windows
PowerShell 5.1, where `Invoke-WebRequest` otherwise tries to use the Internet
Explorer engine to parse the response and fails outright on a machine where IE
has never been configured.

`Unblock-File` clears the `Zone.Identifier` stream that marks internet
downloads — the Windows counterpart of macOS's `xattr` line above. For an
`.exe` this usually only means a SmartScreen prompt, but for a `.ps1` it is a
hard block under the default `RemoteSigned` execution policy, which is why the
installer unblocks every file it places.

---

## Step 4: Install PowerShell 7 (`pwsh`)

**Nothing in this pipeline runs without `pwsh`,** and Windows PowerShell 5.1 is
not a substitute — `run_ytdlp.ps1` uses `ForEach-Object -Parallel` and the
`$IsWindows` automatic variable, neither of which exists in 5.1. From Step 7
onward, the installer itself runs under `pwsh` too.

**Linux**

`setup.sh` installs Microsoft's self-contained tarball into
`~/.local/share/powershell` and symlinks `pwsh` into `~/.local/bin`. See
[PowerShell is no longer a distro problem](#powershell-is-no-longer-a-distro-problem)
for why it does that rather than using your package manager. To do it by hand,
download the `powershell-<version>-linux-<arch>.tar.gz` asset from
<https://github.com/PowerShell/PowerShell/releases/latest>, extract it into a
clean directory, and symlink the `pwsh` inside it onto your `PATH`.

**macOS**

```bash
brew install --cask powershell
```

**`--cask` is required.** PowerShell is distributed as a signed package from
Microsoft, not a source formula, and plain `brew install powershell` fails with
*"No available formula with the name"*. This trips people up regularly.

**Windows**

```powershell
winget install --id Microsoft.PowerShell --exact --silent --accept-source-agreements --accept-package-agreements
```

Then **open a new terminal**. Verify on any platform with:

```
pwsh --version
```

---

## Step 5: VMware shared folder (Linux VM guests only)

This step exists so that the step numbering is the same on every platform,
which makes a Windows setup log and a Linux one directly comparable. It has
work to do only inside a Linux VMware guest.

- **On macOS and Windows** it is a no-op. It configures a Linux VM *guest's*
  access to its host's shared folders, and a Mac or PC running this installer
  is the host.
- **On bare-metal Linux** it detects that there is no hypervisor and skips.
- **Inside a VMware Linux guest** see
  [the VM supplement](#supplement-running-in-a-vmware-vm) at the end of this
  guide for the host-side setup and the manual commands.

---

## Step 6: Desktop preview support

**Nothing in the pipeline needs any of this.** Downloads and post-processing
are byte-identical without it. It matters only so the archive is *browsable*:
thumbnails that preview in the file manager instead of showing a generic icon,
and a player that renders the subtitle tracks next to each video.

**On a headless machine, skip this step entirely.** `setup.sh` detects whether
a desktop is actually installed — by looking for a file manager binary or a
desktop session directory, *not* by reading `$DISPLAY`, which would wrongly
report headless when you are simply connected over SSH — and skips the whole
step on a server install, where these packages would drag in a large GUI
dependency tree for nothing.

**Linux**

```bash
sudo apt install -y webp-pixbuf-loader ffmpegthumbnailer gnome-sushi
sudo apt install -y mpv vlc
```

- `webp-pixbuf-loader` — yt-dlp saves the original thumbnail in whatever format
  YouTube served, which is almost always `.webp`. GTK and Nautilus cannot
  render webp at all without this, so `Images/Thumbnail.webp` shows a generic
  icon. (`postprocess.ps1` also writes a `Thumbnail.png` alongside it, which
  displays regardless — this is what makes the original viewable too.)
- `ffmpegthumbnailer` — poster-frame thumbnails for the `.mkv` files.
- `gnome-sushi` — spacebar preview in Nautilus, which works on the images, the
  videos, and the `.vtt` subtitle files as plain text.

Nautilus refuses to thumbnail files above a size cap that defaults to 10 MB —
far below any real video here — so raise it, or `ffmpegthumbnailer` will appear
to do nothing at all:

```bash
gsettings set org.gnome.nautilus.preferences thumbnail-limit 4096
```

That value is in megabytes, so 4096 is 4 GB. The key has come and gone across
GNOME versions; if `gsettings` errors that the key does not exist, your version
does not have it and video thumbnails should work anyway.

Thumbnails are cached, so folders you browsed before this step may keep showing
generic icons until you log out and back in, or `rm -rf ~/.cache/thumbnails`.

**macOS**

```bash
brew install --cask iina vlc
```

**There is no thumbnailer work to do on macOS.** Finder and Quick Look already
render `.webp` natively (since macOS 11), generate poster frames for `.mkv`,
and preview `.vtt` files as plain text, with no size cap worth raising. What
macOS genuinely lacks is a player: **QuickTime Player cannot open `.mkv` at
all**, and `.mkv` is what this pipeline produces. IINA is the native-feeling
option; VLC is included as well because its subtitle track menu is more
discoverable and it auto-loads a sidecar subtitle file sitting next to a video
without being asked.

**Windows**

```powershell
winget install --id VideoLAN.VLC --exact --silent --accept-source-agreements --accept-package-agreements
```

Explorer renders `.webp` natively on Windows 10 1809+ and Windows 11, so the
`webp-pixbuf-loader` work has no counterpart. What Windows lacks is a reliable
built-in way to play `.mkv` with selectable subtitle tracks — the Media Player
app's Matroska support is inconsistent and it will not auto-load the sidecar
`.vtt` files this pipeline writes.

Explorer does **not** generate poster-frame thumbnails for `.mkv` out of the
box. If you want those, a shell thumbnail extension such as Icaros provides
them. Nothing in the pipeline depends on it.

**All platforms:** both players handle the two ways this pipeline stores
subtitles — tracks muxed into the `.mkv` by `--embed-subs`, and the sidecar
`.vtt` files under each video's `Subtitles/` folder.

---

# Steps 7–12: the shared half

From here the installer is one file, `scripts/setup-common.ps1`, running under
the `pwsh` installed in Step 4. The manual commands below still differ by
platform; the *script* no longer does.

## Step 7: Install `curl_cffi`

Fixes yt-dlp's "no impersonate target available" warning by giving it
browser-impersonation support.

**Linux and macOS**

```bash
python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages
```

`--break-system-packages` is what lets pip write into an externally-managed
environment (PEP 668), which both modern Linux distributions and Homebrew's
Python are. If your pip is old enough not to recognise the flag,
`python3 -m pip install -U --user "curl_cffi>=0.10"` gets there another way.

**Windows**

```powershell
python -m pip install -U "curl_cffi>=0.10"
```

No `--break-system-packages` here: Windows Python installations are not
"externally managed" in the PEP 668 sense, so the flag is unnecessary and older
pip versions reject it outright.

---

## Step 8: Install Deno

YouTube requires solving a JavaScript challenge for cipher decryption. Without
a JS runtime, yt-dlp falls back to less reliable client/format combinations,
and the usual symptom is **mid-download HTTP 403 errors** rather than an
obvious "no JavaScript runtime" message — see yt-dlp/yt-dlp#14404.

**Linux**

```bash
curl -fsSL https://deno.land/install.sh -o /tmp/deno-install.sh
sh /tmp/deno-install.sh -y
cp "$HOME/.deno/bin/deno" "$HOME/.local/bin/deno"
chmod a+rx "$HOME/.local/bin/deno"
```

**macOS** — same, plus the quarantine strip:

```bash
curl -fsSL https://deno.land/install.sh -o /tmp/deno-install.sh
sh /tmp/deno-install.sh -y
cp "$HOME/.deno/bin/deno" "$HOME/.local/bin/deno"
chmod a+rx "$HOME/.local/bin/deno"
xattr -d com.apple.quarantine "$HOME/.local/bin/deno" 2>/dev/null
```

> Downloaded and then run, rather than the more familiar
> `curl ... | sh`. A pipeline reports the exit status of `sh`, not of `curl`,
> so a failed download feeds `sh` an empty script, `sh` exits 0, and the
> failure gets misreported as "the installer ran but produced no binary" —
> which sends you looking in entirely the wrong place. The installer does it
> in two steps for the same reason.

The same installer script serves Linux and macOS and picks the right build for
your architecture itself.

**Windows**

```powershell
irm https://deno.land/install.ps1 | iex
```

This installs to `%USERPROFILE%\.deno\bin\deno.exe`, which is exactly where
`run_ytdlp.ps1` looks first on Windows.

**All platforms:** you are not obliged to put deno in exactly these locations.
`run_ytdlp.ps1` probes `~/.local/bin`, then `~/.deno/bin`, then Homebrew's
prefixes on macOS, then `PATH` — and if it finds none of them it omits
`--js-runtimes` entirely and logs a clear warning rather than failing
confusingly.

---

## Step 9: Get the project files

If you are following this guide by hand you already have the files in front of
you, and there is nothing to do here. The installer's version of this step
fetches them from GitHub into a scratch folder so that Step 11 can find them on
a machine that has nothing but `setup.sh` on it.

It fetches **individual files over HTTPS rather than cloning the repo**, and
the reason is not disk space — the clone was scratch, deleted a few steps
later, costing roughly 400 KB transiently against an archive measured in
gigabytes. The actual reasons are that this was the only thing in the entire
project that ever needed `git`, that it no longer matters whether the repo is
public, private, or reachable over SSH versus HTTPS, and that a plain GET of
six known filenames has far fewer ways to fail on a fresh machine than a clone
does. `git` is still installed in Step 2 and still reported in Step 12 —
you will want it to work on the project; the pipeline just no longer depends
on it.

**Files already sitting beside the installer are used as-is and never
downloaded over.** That is load-bearing for the edit-then-reinstall loop: if
you cloned this repo and are running the installer from inside it, your local
edits win and nothing is fetched at all. Both layouts are accepted — the
repo-relative path (`scripts/run_ytdlp.ps1`) and a bare filename dropped flat
beside the installer.

---

## Step 10: Create the folder structure

**Linux and macOS**

```bash
mkdir -p "$HOME/yt-dlp/scripts" "$HOME/yt-dlp/configs"
mkdir -p "$HOME/yt-dlp/Archive Logs/Archive History" "$HOME/yt-dlp/Archive Logs/Logs"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Complete Archive"
mkdir -p "$HOME/yt-dlp/Youtube Videos/_incomplete"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Final Video"
```

**Windows**

```powershell
$root = "C:\yt-dlp"
foreach ($f in @("scripts","configs","Archive Logs\Archive History","Archive Logs\Logs",
                 "Youtube Videos\Complete Archive","Youtube Videos\_incomplete",
                 "Youtube Videos\Final Video")) {
    New-Item -ItemType Directory -Path (Join-Path $root $f) -Force | Out-Null
}
```

`run_ytdlp.ps1` self-heals this tree on every invocation, so a missing folder is
recreated rather than being an error — but creating it up front means the first
run has nothing to report.

---

## Step 11: Place the project files

### What goes where

| Repo file | Installed to | Notes |
|---|---|---|
| `scripts/run_ytdlp.ps1` | `<root>/scripts/` | shared, unmodified |
| `scripts/postprocess.ps1` | `<root>/scripts/` | shared, unmodified |
| `scripts/ytdl.ps1` | `<root>/scripts/` | **the only argument parser**, all platforms |
| `scripts/archive-viewer.py` | `<root>/scripts/` | a program, not a command |
| `config/yt-dlp.conf` | `<root>/configs/` | shared, unmodified |
| `scripts/ytdl` | `~/.local/bin/ytdl` | Linux and macOS shim |
| `scripts/ytdl.cmd` | `%USERPROFILE%\.local\bin\` | Windows shim |

**`ytdl.ps1` is installed on every platform now**, which is new. It used to be
Windows-only, with a full bash reimplementation of the same seven options
living in the POSIX `ytdl` script. Both had to be edited, in two languages, to
change any one flag. Today `ytdl` (bash) and `ytdl.cmd` are both thin shims
that locate `ytdl.ps1`, hand it the command line untouched and propagate its
exit code — so a command that works on one platform works verbatim on all
three because there is literally one parser, not because two parsers were kept
in agreement by hand.

The Windows shim passes `%*` rather than `%1 %2 %3`, which is what makes a URL
containing `=` work: cmd.exe treats `=` as an argument delimiter alongside
spaces when it splits a line into the numbered variables, so `?v=abc123` would
arrive as two arguments and the URL would be truncated. The bash shim needs no
such workaround — `"$@"` already expands to one word per original argument.

**Linux and macOS**

```bash
cp scripts/run_ytdlp.ps1     "$HOME/yt-dlp/scripts/run_ytdlp.ps1"
cp scripts/postprocess.ps1   "$HOME/yt-dlp/scripts/postprocess.ps1"
cp scripts/ytdl.ps1          "$HOME/yt-dlp/scripts/ytdl.ps1"
cp scripts/archive-viewer.py "$HOME/yt-dlp/scripts/archive-viewer.py"
cp config/yt-dlp.conf        "$HOME/yt-dlp/configs/yt-dlp.conf"
cp scripts/ytdl              "$HOME/.local/bin/ytdl"
chmod +x "$HOME/.local/bin/ytdl" "$HOME/yt-dlp/scripts/archive-viewer.py"
```

**Windows**

```powershell
$root = "C:\yt-dlp"
$localBin = Join-Path $env:USERPROFILE ".local\bin"
Copy-Item scripts\run_ytdlp.ps1     (Join-Path $root "scripts\run_ytdlp.ps1")     -Force
Copy-Item scripts\postprocess.ps1   (Join-Path $root "scripts\postprocess.ps1")   -Force
Copy-Item scripts\ytdl.ps1          (Join-Path $root "scripts\ytdl.ps1")          -Force
Copy-Item scripts\archive-viewer.py (Join-Path $root "scripts\archive-viewer.py") -Force
Copy-Item config\yt-dlp.conf        (Join-Path $root "configs\yt-dlp.conf")       -Force
Copy-Item scripts\ytdl.cmd          (Join-Path $localBin "ytdl.cmd")              -Force
Get-ChildItem (Join-Path $root "scripts") -File | Unblock-File
Unblock-File (Join-Path $localBin "ytdl.cmd")
```

### The viewer launcher

Generated by the installer rather than shipped as a repo file, because its
entire body is a single line — a repo file would exist only to be copied and
would be one more thing to keep in sync.

**Linux and macOS** — `~/.local/bin/ytdl-view`:

```bash
cat > "$HOME/.local/bin/ytdl-view" <<'EOF'
#!/usr/bin/env bash
exec python3 "$HOME/yt-dlp/scripts/archive-viewer.py" "$@"
EOF
chmod +x "$HOME/.local/bin/ytdl-view"
```

**Windows** — `%USERPROFILE%\.local\bin\ytdl-view.cmd`:

```bat
@echo off
python "C:\yt-dlp\scripts\archive-viewer.py" %*
```

### Putting the launchers on `PATH`

**Linux** (bash is the usual default):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
source "$HOME/.bashrc"
```

**macOS** (zsh is the default):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
source "$HOME/.zshrc"
```

The installer checks `$SHELL` rather than assuming, so it gets the right answer
on a machine where you have switched your login shell.

**Windows** — **User** environment, not Machine, so no elevation is needed:

```powershell
$localBin = Join-Path $env:USERPROFILE ".local\bin"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ';') -notcontains $localBin) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$localBin", "User")
}
```

Open a new terminal for this to take effect.

---

## Step 12: Verify

**Linux and macOS**

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

**Windows**

```powershell
& "$env:USERPROFILE\.local\bin\yt-dlp.exe" --version
ffmpeg -version | Select-Object -First 1
ffprobe -version | Select-Object -First 1
pwsh --version
& "$env:USERPROFILE\.deno\bin\deno.exe" --version | Select-Object -First 1
git --version
python --version
```

**Check `yt-dlp` and `deno` by full path, not bare command name.** Your `bin`
directory was only just added to `PATH`, and a shell or session started before
that change reports "not found" immediately after a successful install.

The installer's own Step 12 does more than the above. It parse-checks
`run_ytdlp.ps1`, `postprocess.ps1` and `ytdl.ps1` with the PowerShell parser
and compiles `archive-viewer.py` with `py_compile` — both without executing
anything. That catches a truncated download or a bad edit at install time
rather than at the end of a real download, after the video is already on disk
and the `after_move` hook fires. On Windows it also reports the
`LongPathsEnabled` state.

---

# After setup

## First test run

Point the first run at a scratch data root so test output never lands in the
real archive. The second positional argument sets `-DataRoot`:

```bash
ytdl "https://youtu.be/<short-video-id>" "$HOME/scratch-test"
```

```powershell
ytdl "https://youtu.be/<short-video-id>" "D:\scratch-test"
```

Pick something short. The comments pass on a heavily-commented video can take
30–60+ minutes on its own, and it runs *after* the video is already safely
downloaded — so a long silence late in the run is usually the comments fetch
working, not a hang.

Watch it work:

```bash
tail -f "$HOME/scratch-test/Archive Logs/Logs/download.log"
```

```powershell
Get-Content "D:\scratch-test\Archive Logs\Logs\download.log" -Wait -Tail 20
```

When it finishes, the video folder should contain `Final files/Final Video.mkv`
and nothing else at that level — the `--keep-video` pre-merge streams are moved
to a sibling `Pre-merge streams/` folder.

### Verifying integrity

The checksum file is written in standard `sha256sum` format, so each platform
verifies it with its own native tool.

**Linux**

```bash
cd "$HOME/scratch-test/Youtube Videos/Complete Archive/<Uploader>/<video folder>"
sha256sum -c "Video metadata/checksums.sha256"
```

**macOS** (ships `shasum` rather than `sha256sum`):

```bash
shasum -a 256 -c "Video metadata/checksums.sha256"
```

**Windows** (no `sha256sum -c` equivalent, hence the loop):

```powershell
cd "D:\scratch-test\Youtube Videos\Complete Archive\<Uploader>\<video folder>"
Get-Content "Video metadata\checksums.sha256" | ForEach-Object {
    $expected, $rel = $_ -split '\s+', 2
    $actual = (Get-FileHash -Path $rel -Algorithm SHA256).Hash
    "{0}  {1}" -f $(if ($actual -eq $expected) { "OK  " } else { "FAIL" }), $rel
}
```

Every line should read `OK`.

## Read what you archived

```
ytdl-view --root "<your scratch root>"
```

Then open <http://127.0.0.1:8777>. Add `--allow-open-local` to let the page
hand files to a local player. The viewer is pure Python standard library, reads
the archive without ever writing to it, and keeps derived state outside the
archive so the `checksums.sha256` files keep verifying:

| Platform | Viewer cache |
|---|---|
| Linux | `~/.cache/ytdlp-archive-viewer` |
| macOS | `~/Library/Caches/ytdlp-archive-viewer` |
| Windows | `%LOCALAPPDATA%\ytdlp-archive-viewer` |

See [`archive-viewer-usage.md`](archive-viewer-usage.md) for what the viewer
can do, and [`ytdl-usage.md`](ytdl-usage.md) for the full `ytdl` option set.

---

# Supplement: running in a VMware VM

Everything above applies unchanged inside a Linux VMware guest. This is the
one step that has no counterpart on bare metal, macOS or Windows: giving the
guest access to a folder on the host, so you can browse the archive (or drop
files in) without SCP/SFTP.

It is **optional for the pipeline itself** — nothing in the scripts requires
it. `setup.sh` runs it as Step 5, detecting a VMware guest via
`systemd-detect-virt` with a DMI product-name fallback, and skipping silently
everywhere else.

**On the host, in VMware Workstation Pro:**

1. **VM menu → Settings → Options tab → Shared Folders**
2. Select **Always enabled**
3. Click **Add…**, browse to the host folder you want shared, name it (e.g.
   `yt-dlp-share`), finish the wizard
4. Make sure the VM is powered on

**Inside the Linux guest:**

```bash
sudo apt install -y open-vm-tools open-vm-tools-desktop
sudo systemctl restart open-vm-tools.service
sudo mkdir -p /mnt/hgfs
sudo vmhgfs-fuse .host:/ /mnt/hgfs -o subtype=vmhgfs-fuse,allow_other
```

> `open-vm-tools-desktop` is only needed for GUI integration; on a
> headless/server install it can fail to resolve its desktop-environment
> dependencies. If the `apt install` above fails, drop `-desktop` — the
> shared-folder mount itself does not need it.

Make the mount persist across reboots:

```bash
echo '.host:/    /mnt/hgfs   fuse.vmhgfs-fuse    defaults,allow_other    0    0' | sudo tee -a /etc/fstab
```

You should now see your named share (e.g. `/mnt/hgfs/yt-dlp-share`)
immediately, with no reboot involved.

### Why this deliberately does not reboot

An earlier version of `setup.sh` told you to `sudo reboot` after installing the
guest tools, which caused two real problems. First, some VMware/Ubuntu
combinations do not shut down cleanly on `sudo reboot` and need `sudo reboot -f`
to actually restart. Second — and this is the more important one — if a script
triggers a reboot mid-run, **the script's own process dies right there along
with the OS.** A shell script is not a background service; it does not wake
back up and resume after the machine comes back. Any steps after the reboot
line simply never ran. Restarting the tools service directly and mounting
immediately gets it working in the same session, so the reboot is not needed at
all. A full `sudo reboot -f` remains the last-resort fallback if the direct
mount genuinely fails.

With the archive visible on the host, you can also run the viewer **on the
host** against the mounted share instead of inside the VM, which is usually the
nicer place to watch things.

---

# Where to put the archive

Only the *data* moves when you pass a custom root — `scripts/` and `configs/`
always stay at the install root, because the launcher shim has to find
`ytdl.ps1` before it can parse any arguments. To move the install itself, set
`YTDLP_INSTALL_ROOT`.

**On the system disk (the default).** Do nothing. Fine until it isn't: this
pipeline keeps the merged video, the pre-merge video-only and audio-only
streams (`--keep-video`), *and* a second full copy of the merged file under
`Final Video/`. Budget roughly **three times** the nominal size of what you
download.

**On a separate disk or mount.** Pass the path and nothing else changes:

```bash
ytdl "<url>" /mnt/archive
```

**On a NAS or network mount — one real caveat.** `postprocess.ps1` serialises
its manifest writes with advisory file locks (opening a lock file with
`FileShare.None`). File locking semantics over NFS and SMB are notoriously
inconsistent, and this has not been tested on a network mount. If you put the
data root on a network share, **either keep `--workers` at 1**, or test a
parallel run and confirm afterwards that `global_manifest.json` contains one
entry per video with none silently lost. On local storage this is a solved
problem and needs no thought.

---

# Running it unattended

**Scheduled channel syncs.** `--sync` stops as soon as it reaches a video
already in the archive, which makes it cheap to re-run against a channel you
have mostly archived.

On Linux, a systemd user timer is the tidy way to do that periodically.
`~/.config/systemd/user/ytdl-sync.service`:

```ini
[Unit]
Description=yt-dlp channel sync

[Service]
Type=oneshot
ExecStart=%h/.local/bin/ytdl "https://www.youtube.com/@SomeChannel/videos" --sync
```

`~/.config/systemd/user/ytdl-sync.timer`:

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
timers only run while you have an active session. On macOS the equivalent is a
`launchd` agent; on Windows, Task Scheduler pointed at `ytdl.cmd`.

**One caution on `--sync` plus `--workers`.** `--sync` relies on the source
being in newest-first order, which a channel's default `/videos` listing is.
Combined with `--workers > 1` it is reimplemented manually — the enumerated
list is truncated at the first already-archived ID. That is correct for a
channel listing and wrong for a reordered or filtered source, which could stop
before reaching genuinely new videos further down.

**Sleep and suspend.** A long channel archive will be interrupted by the
machine sleeping.

| Platform | Keep it awake |
|---|---|
| Linux | `systemd-inhibit --what=sleep --why="archiving" ytdl "<url>" --workers 3` |
| macOS | `caffeinate -i ytdl "<url>" --workers 3` |
| Windows | `powercfg /change standby-timeout-ac 0` (set it back afterward) |

**Logs grow.** `download.log` is cumulative and never rotated, and a run with
`--workers N` also leaves one `download.worker-<id>.log` per video under
`Archive Logs/Logs/`. Those are deliberately not cleaned up — keeping real logs
is this project's stated preference — but on a long-running box they
accumulate. Everything in a worker log is duplicated into that video's own
`Logs/video_complete.log`, so deleting old ones by hand costs nothing.

---

# Platform-specific notes

## macOS

**Gatekeeper.** Any binary you download rather than install through Homebrew
carries a quarantine attribute, and the resulting failure looks like a corrupt
file rather than a policy decision. If something you installed by hand refuses
to run, check `xattr -l <file>` before assuming the download failed.

**Full Disk Access.** If you point `-DataRoot` at `~/Desktop`, `~/Documents` or
`~/Downloads`, macOS may block your terminal from writing there until you grant
it access under System Settings → Privacy & Security → Full Disk Access. This
shows up as a permission error from a folder you can plainly see in Finder.
Archiving under `~/yt-dlp` (the default) avoids it entirely.

**Case-insensitive filesystem.** APFS is case-insensitive by default. Nothing
here depends on case-sensitive filenames, but it is worth knowing if you ever
move an archive from a Linux box where two folders differed only in case.

**Spotlight.** A large archive gets indexed, which costs time and disk. If you
would rather it were not, add the archive folder under System Settings → Siri &
Spotlight → Spotlight Privacy.

## Windows

**Execution policy.** The default `RemoteSigned` policy blocks `.ps1` files
that carry the internet-download marker. The installer unblocks everything it
places, but if you copy a script in by hand and `ytdl` fails with a security
error rather than anything about yt-dlp, run `Unblock-File` on it. Launching
`setup.ps1` with `-ExecutionPolicy Bypass` covers the installer itself.

**Antivirus.** Real-time scanning routinely holds a just-written file open for
a moment. `postprocess.ps1` already retries for a few seconds when locating the
`info.json` for exactly this reason. If you see intermittent access errors on a
large archive, excluding the archive folder from real-time scanning also
removes a meaningful amount of I/O overhead.

**`--windows-filenames`.** Off by default in `yt-dlp.conf`, and not needed when
downloading *on* Windows — yt-dlp already sanitizes for the OS it is running
on. Turn it on if the archive is written on Linux or macOS and *read* from
Windows (a NAS or SMB share, an external drive moved between machines, a
dual-boot setup). The cost is cosmetic: a video titled `Q4: What now?` loses
its colon and question mark in the folder name.

**Path separators in manifests.** `postprocess.ps1` normalizes every path it
records to `/` regardless of platform, so a video archived on Windows produces
a `manifest.json` directly comparable with one archived on Linux or macOS.
Windows accepts `/` as a separator everywhere, so those values still resolve
natively.

---

# Quick reference: what lives where after setup

**Linux and macOS**

```
~/.local/bin/
  ytdl                 launcher shim (bash) -- what you type
  ytdl-view            viewer launcher (generated, not a repo file)
  yt-dlp               standalone binary, self-updating
  deno                 JS runtime for YouTube's cipher challenge
  pwsh                 symlink into ~/.local/share/powershell (Linux only)

~/yt-dlp/
  scripts/             run_ytdlp.ps1, postprocess.ps1, ytdl.ps1, archive-viewer.py
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
```

**Windows**

```
%USERPROFILE%\.local\bin\
  ytdl.cmd             launcher shim -- what you type
  ytdl-view.cmd        viewer launcher (generated, not a repo file)
  yt-dlp.exe           standalone binary, self-updating

%USERPROFILE%\.deno\bin\
  deno.exe             JS runtime for YouTube's cipher challenge

C:\yt-dlp\
  scripts\             run_ytdlp.ps1, postprocess.ps1, ytdl.ps1, archive-viewer.py
  configs\             yt-dlp.conf
  .last_dependency_check    24h throttle marker for yt-dlp -U
  Archive Logs\        (as above, with backslashes)
  Youtube Videos\      (as above, with backslashes)
```

If you passed a custom data root, only `Archive Logs/` and `Youtube Videos/`
move there; everything above them stays at the install root.
