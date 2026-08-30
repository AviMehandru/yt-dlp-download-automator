# Setting Up the yt-dlp Archival Pipeline on Windows

> **On Linux or macOS instead?** See [`linux-setup-guide.md`](linux-setup-guide.md)
> (bare metal), [`linux-vm-setup-guide.md`](linux-vm-setup-guide.md) (in a
> VMware VM), or [`mac-setup-guide.md`](mac-setup-guide.md). The pipeline scripts themselves
> are byte-identical on all three platforms — `run_ytdlp.ps1`, `postprocess.ps1`
> and `yt-dlp.conf` are one shared set — so only the installation differs.

> **Shortcut:** `setup.ps1` automates Steps 1 through 10 in one run:
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\setup.ps1
> ```
>
> It is idempotent, safe to re-run, needs **no administrator rights**, and does
> not hard-abort on a failed non-critical step — it prints a summary of anything
> needing a manual look at the end. The manual steps below are here for
> reference, and for when a step needs attention.

`setup.ps1` is written to run under **Windows PowerShell 5.1**, the version
that ships with Windows, because installing PowerShell 7 is one of the things
it does. The pipeline scripts it installs are PowerShell 7 scripts and require
`pwsh`.

---

## Prerequisites

**winget**, which installs everything except yt-dlp and deno. It ships with
Windows 11 and Windows 10 1809+ as part of "App Installer", but can be missing
on a stripped image or an account that has never opened the Store. Check:

```powershell
winget --version
```

If that fails, install App Installer from the Microsoft Store or
<https://aka.ms/getwinget>. `setup.ps1` warns and continues without it — the
folder structure and file placement still happen, so you can install winget and
re-run.

---

## A note on the install root

The pipeline installs to **`C:\yt-dlp`**, not under your user profile, and this
is a deliberate exception to how the Linux and macOS installs work.

The reason is `MAX_PATH`. Windows still caps most paths at 260 characters
unless long-path support is explicitly enabled, and this pipeline's per-video
paths are genuinely long — a 40-character uploader folder, then a second folder
repeating uploader + upload date + video id + a 60-character title, then
`Pre-merge streams\Final Video.f137.mp4`. That reaches roughly 240 characters
*before* the data root is prefixed. `C:\yt-dlp` spends 9 of the budget;
`C:\Users\<your name>\yt-dlp` can easily spend twice that and push real videos
over the limit.

Creating a folder at the root of `C:` does not require administrator rights.
Everything else installs under your profile.

If you would rather it lived elsewhere, set `YTDLP_INSTALL_ROOT` — every
component reads it (both launchers, both pipeline scripts, the installer):

```powershell
[Environment]::SetEnvironmentVariable("YTDLP_INSTALL_ROOT", "D:\yt-dlp", "User")
```

### Enabling long paths (recommended)

Worth doing regardless. As Administrator:

```powershell
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" `
  -Name "LongPathsEnabled" -Value 1 -PropertyType DWORD -Force
```

Then reboot. `setup.ps1`'s verification step reports whether this is set. The
install root stays at `C:\yt-dlp` either way — a data root that moved depending
on a machine setting would be worse than one that is merely inconsistent
between platforms, because you would not reliably know where your own archive
is.

---

## Step 1: Update the winget source

```powershell
winget source update
```

Only the source index. Unlike the Linux installer, `setup.ps1` does **not** run
`winget upgrade --all` — a full system upgrade is defensible on a purpose-built
VM, but a Windows machine running this is far more likely to be your daily
driver, and silently upgrading every installed application as a side effect of
setting up a video archiver is not this script's call to make.

---

## Step 2: Install ffmpeg, git and Python

```powershell
winget install --id Gyan.FFmpeg   --exact --silent --accept-source-agreements --accept-package-agreements
winget install --id Git.Git       --exact --silent --accept-source-agreements --accept-package-agreements
winget install --id Python.Python.3.12 --exact --silent --accept-source-agreements --accept-package-agreements
```

The `--accept-*-agreements` flags are required for an unattended run; without
them winget stops and waits for a keypress.

`ffprobe` comes inside the Gyan ffmpeg package — `postprocess.ps1` needs it for
the info.json re-embed step. Python is only needed by the archive viewer;
nothing in the download pipeline touches it.

**Open a new terminal after this step.** winget puts these on `PATH`, but your
current session inherited its environment before that happened.

---

## Step 3: Install yt-dlp

As a standalone binary into `~\.local\bin`, mirroring the Unix installs.
yt-dlp's `-U` self-update writes a temp file into its *containing directory*
and renames over the old binary, so that directory has to be yours — which is
also why nothing here needs elevation.

```powershell
$localBin = Join-Path $env:USERPROFILE ".local\bin"
New-Item -ItemType Directory -Path $localBin -Force | Out-Null
Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" `
  -OutFile (Join-Path $localBin "yt-dlp.exe") -UseBasicParsing
Unblock-File -Path (Join-Path $localBin "yt-dlp.exe")
```

Note the asset: **`yt-dlp.exe`** (the plain `yt-dlp` asset is the Linux build,
`yt-dlp_macos` the Mac one).

`-UseBasicParsing` is harmless on PowerShell 7 and **required** on Windows
PowerShell 5.1, where `Invoke-WebRequest` otherwise tries to use the Internet
Explorer engine to parse the response and fails outright on a machine where IE
has never been configured.

`Unblock-File` clears the `Zone.Identifier` stream that marks internet
downloads. For an `.exe` this usually only means a SmartScreen prompt, but for
a `.ps1` it is a hard block under the default `RemoteSigned` execution policy —
which is why the installer unblocks every file it places.

---

## Step 4: Install PowerShell 7 (`pwsh`)

```powershell
winget install --id Microsoft.PowerShell --exact --silent --accept-source-agreements --accept-package-agreements
```

Then **open a new terminal** and verify:

```powershell
pwsh --version
```

Nothing in this pipeline runs without `pwsh`. Windows PowerShell 5.1 is not a
substitute — `run_ytdlp.ps1` uses `ForEach-Object -Parallel` and the
`$IsWindows` automatic variable, neither of which exists in 5.1.

---

## Step 5: Install `curl_cffi`

```powershell
python -m pip install -U "curl_cffi>=0.10"
```

No `--break-system-packages` here, unlike the Unix installs: Windows Python
installations are not "externally managed" in the PEP 668 sense, so the flag is
unnecessary and older pip versions reject it outright.

---

## Step 6: Install Deno

YouTube requires solving a JavaScript challenge for cipher decryption. Without
a JS runtime, yt-dlp falls back to less reliable client/format combinations,
and the usual symptom is **mid-download HTTP 403 errors** rather than an
obvious "no JavaScript runtime" message — see yt-dlp/yt-dlp#14404.

```powershell
irm https://deno.land/install.ps1 | iex
```

This installs to `%USERPROFILE%\.deno\bin\deno.exe`, which is exactly where
`run_ytdlp.ps1` looks first on Windows. It also probes `~\.local\bin\deno.exe`
and then `PATH`; if it finds none of them it omits `--js-runtimes` entirely and
logs a warning rather than failing confusingly.

---

## Step 7: Create the folder structure

```powershell
$root = "C:\yt-dlp"
foreach ($f in @("scripts","configs","Archive Logs\Archive History","Archive Logs\Logs",
                 "Youtube Videos\Complete Archive","Youtube Videos\_incomplete",
                 "Youtube Videos\Final Video")) {
    New-Item -ItemType Directory -Path (Join-Path $root $f) -Force | Out-Null
}
```

`run_ytdlp.ps1` self-heals this tree on every invocation, so a missing folder
is recreated rather than being an error.

---

## Step 8: Place the project files

```powershell
$root = "C:\yt-dlp"
$localBin = Join-Path $env:USERPROFILE ".local\bin"
Copy-Item run_ytdlp.ps1     (Join-Path $root "scripts\run_ytdlp.ps1")     -Force
Copy-Item postprocess.ps1   (Join-Path $root "scripts\postprocess.ps1")   -Force
Copy-Item ytdl.ps1          (Join-Path $root "scripts\ytdl.ps1")          -Force
Copy-Item yt-dlp.conf       (Join-Path $root "configs\yt-dlp.conf")       -Force
Copy-Item archive-viewer.py (Join-Path $root "scripts\archive-viewer.py") -Force
Copy-Item ytdl.cmd          (Join-Path $localBin "ytdl.cmd")              -Force
Get-ChildItem (Join-Path $root "scripts") -File | Unblock-File
Unblock-File (Join-Path $localBin "ytdl.cmd")
```

**Windows is the one platform that needs two launcher files.** `ytdl.ps1` does
the real argument parsing and lives with the other scripts; `ytdl.cmd` is a
one-line shim that goes on your `PATH`, so typing `ytdl` works from Command
Prompt, PowerShell and the Run box alike — none of which can execute a `.ps1`
directly. Linux and macOS use a single bash `ytdl` instead. All three accept
identical options.

The shim passes `%*` rather than `%1 %2 %3`, which is what makes a URL
containing `=` work: cmd.exe treats `=` as an argument delimiter alongside
spaces when it splits a line into the numbered variables, so `?v=abc123` would
arrive as two arguments and the URL would be truncated.

The viewer launcher, which `setup.ps1` generates rather than shipping as a repo
file — save as `%USERPROFILE%\.local\bin\ytdl-view.cmd`:

```bat
@echo off
python "C:\yt-dlp\scripts\archive-viewer.py" %*
```

Then put `~\.local\bin` on your `PATH`. **User** environment, not Machine, so
no elevation is needed:

```powershell
$localBin = Join-Path $env:USERPROFILE ".local\bin"
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ';') -notcontains $localBin) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$localBin", "User")
}
```

Open a new terminal for this to take effect.

---

## Step 9: Install a video player

Nothing in the pipeline needs this. It matters because Windows has no reliable
built-in way to play `.mkv` with selectable subtitle tracks — the Media Player
app's Matroska support is inconsistent and it will not auto-load the sidecar
`.vtt` files this pipeline writes.

```powershell
winget install --id VideoLAN.VLC --exact --silent --accept-source-agreements --accept-package-agreements
```

**There is no thumbnailer work to do for images.** Explorer renders `.webp`
natively on Windows 10 1809+ and Windows 11, so the `webp-pixbuf-loader` step
from the Linux guide has no counterpart.

Explorer does **not** generate poster-frame thumbnails for `.mkv` out of the
box. If you want those, a shell thumbnail extension such as Icaros provides
them. Nothing in the pipeline depends on it.

---

## Step 10: Verify

```powershell
& "$env:USERPROFILE\.local\bin\yt-dlp.exe" --version
ffmpeg -version | Select-Object -First 1
ffprobe -version | Select-Object -First 1
pwsh --version
& "$env:USERPROFILE\.deno\bin\deno.exe" --version | Select-Object -First 1
git --version
python --version
```

Check `yt-dlp` and `deno` **by full path**, not bare command name — `~\.local\bin`
was only just added to `PATH`, and a session started before that reports "not
found" immediately after a successful install.

`setup.ps1`'s own verification additionally parse-checks `run_ytdlp.ps1`,
`postprocess.ps1`, `ytdl.ps1` and `archive-viewer.py` without running them, and
reports the `LongPathsEnabled` state.

---

## Step 11: First real test run

Point the first run at a scratch data root so test output never lands in the
real archive:

```powershell
ytdl "https://youtu.be/<short-video-id>" "D:\scratch-test"
```

Pick something short. The comments pass on a heavily-commented video can take
30–60+ minutes on its own, and it runs *after* the video is already safely
downloaded — so a long silence late in the run is usually the comments fetch
working, not a hang.

Watch it work:

```powershell
Get-Content "D:\scratch-test\Archive Logs\Logs\download.log" -Wait -Tail 20
```

When it finishes, the video folder should contain `Final files\Final Video.mkv`
and nothing else at that level — the `--keep-video` pre-merge streams are moved
to a sibling `Pre-merge streams\` folder. Verify integrity:

```powershell
cd "D:\scratch-test\Youtube Videos\Complete Archive\<Uploader>\<video folder>"
Get-Content "Video metadata\checksums.sha256" | ForEach-Object {
    $expected, $rel = $_ -split '\s+', 2
    $actual = (Get-FileHash -Path $rel -Algorithm SHA256).Hash
    "{0}  {1}" -f $(if ($actual -eq $expected) { "OK  " } else { "FAIL" }), $rel
}
```

Every line should read `OK`. (Windows has no `sha256sum -c`, hence the loop.
The file is written in standard `sha256sum` format so it verifies with that
tool on Linux and `shasum -a 256 -c` on macOS.)

---

## Step 12: Read what you archived

```powershell
ytdl-view --root "D:\scratch-test"
```

Then open `http://127.0.0.1:8777`. Add `--allow-open-local` to let the page
hand files to VLC. The viewer reads the archive without ever writing to it, and
keeps derived state in `%LOCALAPPDATA%\ytdlp-archive-viewer` — deliberately
outside the archive, so the `checksums.sha256` files keep verifying.

---

## Windows-specific notes

**Execution policy.** The default `RemoteSigned` policy blocks `.ps1` files
that carry the internet-download marker. `setup.ps1` unblocks everything it
places, but if you copy a script in by hand and `ytdl` fails with a security
error rather than anything about yt-dlp, run `Unblock-File` on it. Launching
`setup.ps1` itself with `-ExecutionPolicy Bypass` covers the installer.

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

**Sleep.** A long channel archive will be interrupted by the machine sleeping.
`powercfg /change standby-timeout-ac 0` disables sleep on AC power for the
duration; set it back afterward.

---

## Quick reference: what lives where after setup

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
  Archive Logs\
    Archive History\   timestamped archive.txt + global_manifest.json snapshots
    Logs\              download.log, archive.txt, setup_*.log
  Youtube Videos\
    Complete Archive\<Uploader>\<Uploader> - <date> - <id> - <title>\
      Final files\        Final Video.mkv, Link.*
      Pre-merge streams\  --keep-video's raw streams, moved out of Final files
      Subtitles\ Images\ URLs\ Logs\
      Video metadata\     Info.info.json, Description.*, manifest.json, checksums.sha256
    Complete Archive\<Uploader>\Channel Info\    avatar, banner, description
    Final Video\<Uploader>\   flat "point a player here" copies
    _incomplete\         yt-dlp temp path; empty dirs swept after each video
    global_manifest.json

%LOCALAPPDATA%\ytdlp-archive-viewer\    viewer's derived state (disposable)
```

winget installs ffmpeg, git, Python and VLC into their own locations, all
already on `PATH`.
