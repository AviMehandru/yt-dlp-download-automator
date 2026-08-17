# Setting Up the yt-dlp Archival Pipeline on a Fresh Linux VM

This assumes a fresh **Ubuntu 26.04** VM running as a guest under **VMware
Workstation Pro** (matches the `apt`-based dependency checks baked into
`linux-run_ytdlp.ps1`). The scripts are hardcoded to the username
`linuxisthebest`, so **Step 0 matters** — don't skip it.

---

## Step 0: Make sure the VM's user account is actually named `linuxisthebest`

The scripts use literal paths like `/home/linuxisthebest/yt-dlp/...` (not
`$HOME` — see the comment at the top of `linux-yt-dlp.conf` explaining why:
`~` doesn't reliably expand inside `--exec`'s embedded shell command).

- **If you're creating the VM's user account now**, just name it
  `linuxisthebest` and everything below works as-is.
- **If the VM already has a different username**, you have two options:
  1. Re-run the same find-and-replace from before, swapping in the real
     username, on all four files, or
  2. Create a second user actually named `linuxisthebest` and do everything
     under that account.

Check your current username any time with:
```bash
whoami
```

---

## Step 1: Update the system

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Step 2: Install base dependencies

```bash
sudo apt install -y curl wget ffmpeg ca-certificates apt-transport-https software-properties-common
```

`ffmpeg` from Ubuntu's repo is what the dependency-check logic in
`run_ytdlp.ps1` expects (it checks `apt list --upgradable` for `ffmpeg/`, not
an upstream version number, unlike the Windows version).

Verify:
```bash
ffmpeg -version
ffprobe -version
```

---

## Step 3: Install yt-dlp

Install the **standalone binary** (not the `apt` package). This matters
because `run_ytdlp.ps1` calls `yt-dlp -U` for self-updates, which only
actually does anything for a standalone-binary install — it silently no-ops
if yt-dlp came from `apt`.

```bash
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp
```

Verify:
```bash
yt-dlp --version
```

---

## Step 4: Install PowerShell 7 (`pwsh`)

**As of this writing, Microsoft has not published `apt` packages for Ubuntu
26.04 ("Resolute Raccoon")** — the repo bootstrap file exists (so `apt
update` succeeds and lists the repo), but the actual `powershell` package
isn't in it yet, which is what produces `Unable to locate package
powershell`. This is a known, open gap on Microsoft's end with no published
ETA — not something wrong with your VM or these steps. Once it's published,
you can migrate from snap to `apt` at any point with no changes to the
pipeline itself; it's still just `pwsh` on `PATH` either way.

**For now, use snap** (you may have already done this):
```bash
sudo snap install powershell --classic
```

Verify:
```bash
pwsh --version
```

> **Only functional difference:** the `apt list --upgradable` dependency
> check in `run_ytdlp.ps1` looks for a `powershell/` line to warn you about
> pwsh updates — that check won't ever fire for a snap install, since snap
> updates don't show up there. Not worth working around; just run
> `sudo snap refresh powershell` yourself occasionally, or switch to `apt`
> once Microsoft publishes the 26.04 package.

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

## Step 5: Set up the VMware Workstation Pro shared folder

This lets you browse the archive (or drop in files) from the Windows/macOS
host without SCP/SFTP. Two sides: enable it in the VM's settings, then mount
it inside Ubuntu.

**5a. Enable the shared folder in VMware Workstation Pro (on the host):**
1. Shut down or just have the VM powered on — either works, but it's
   simplest with the VM off: **VM menu → Settings → Options tab → Shared
   Folders**.
2. Select **Always enabled**.
3. Click **Add...**, browse to the host folder you want shared, give it a
   name (e.g. `yt-dlp-share`), and finish the wizard.
4. Power on (or resume) the VM.

**5b. Install the guest tools that expose it (inside Ubuntu):**
```bash
sudo apt install -y open-vm-tools open-vm-tools-desktop
```
(`open-vm-tools-desktop` is only needed if you're running a GUI desktop
environment; skip it on a headless/server install.)

**5c. Mount it:**

With `open-vm-tools` installed, shared folders normally show up
automatically at `/mnt/hgfs/<share-name>` after a reboot:
```bash
sudo reboot
```
then:
```bash
ls /mnt/hgfs
```

If nothing appears there, mount it manually:
```bash
sudo mkdir -p /mnt/hgfs
sudo vmhgfs-fuse .host:/ /mnt/hgfs -o subtype=vmhgfs-fuse,allow_other
```

To make that persist across reboots without re-running the command every
time, add it to `/etc/fstab`:
```bash
echo '.host:/    /mnt/hgfs   fuse.vmhgfs-fuse    defaults,allow_other    0    0' | sudo tee -a /etc/fstab
```

You should now see your named share (e.g. `/mnt/hgfs/yt-dlp-share`) with
read/write access from both host and guest. This is optional for the
pipeline itself — nothing in the scripts requires it — but it's a
convenient way to pull finished archives off the VM, or drop in the four
pipeline files from the host instead of re-typing them.

---

## Step 6: Create the folder structure

```bash
mkdir -p /home/linuxisthebest/yt-dlp/scripts
mkdir -p /home/linuxisthebest/yt-dlp/configs
mkdir -p "/home/linuxisthebest/yt-dlp/Archive Logs/Archive History"
mkdir -p "/home/linuxisthebest/yt-dlp/Archive Logs/Logs"
mkdir -p "/home/linuxisthebest/yt-dlp/Youtube Videos/Complete Archive"
mkdir -p "/home/linuxisthebest/yt-dlp/Youtube Videos/_incomplete"
mkdir -p "/home/linuxisthebest/yt-dlp/Youtube Videos/Pure Video"
```

This matches exactly what `linux-yt-dlp.conf` and `linux-postprocess.ps1`
expect: `scripts/`, `configs/`, the paired `Archive Logs` subfolders,
`Complete Archive`, `_incomplete`, and `Pure Video` all under
`~/yt-dlp/`.

---

## Step 7: Place the four pipeline files

Copy the four files (already updated with `linuxisthebest` baked in) into
place — e.g. straight from the VMware shared folder if you dropped them
there in Step 5:

```bash
cp linux-run_ytdlp.ps1   /home/linuxisthebest/yt-dlp/scripts/run_ytdlp.ps1
cp linux-postprocess.ps1 /home/linuxisthebest/yt-dlp/scripts/postprocess.ps1
cp linux-yt-dlp.conf     /home/linuxisthebest/yt-dlp/configs/yt-dlp.conf
cp linux-ytdl            /home/linuxisthebest/.local/bin/ytdl
```

Note the renames — `run_ytdlp.ps1` and `postprocess.ps1` on disk shouldn't
keep the `linux-` prefix, since that's just how they're labeled in this
conversation to distinguish them from the Windows copies.

---

## Step 8: Make `ytdl` executable and put it on your `PATH`

```bash
mkdir -p /home/linuxisthebest/.local/bin
chmod +x /home/linuxisthebest/.local/bin/ytdl
```

Ubuntu usually adds `~/.local/bin` to `PATH` automatically for login shells,
but confirm it's actually there:

```bash
echo $PATH | tr ':' '\n' | grep -q "$HOME/.local/bin" && echo "already on PATH" || echo "NOT on PATH yet"
```

If it says "NOT on PATH yet", add it:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

---

## Step 9: Install `curl_cffi` (fixes the "no impersonate target" warning)

Some extractors ask yt-dlp to impersonate a real browser's TLS/HTTP
fingerprint to avoid bot detection. The plain `yt-dlp` binary from Step 3 is
a Python zipapp that relies on your system's Python packages for that
capability — it doesn't bundle it — so without `curl_cffi` installed you'll
see:
```
WARNING: The extractor specified to use impersonation for this download, but no impersonate target is available.
```

Install it:
```bash
sudo apt install -y python3-pip
python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages
```

(`--break-system-packages` is needed because Ubuntu 26.04, like recent
Debian/Ubuntu releases, marks the system Python environment as
externally-managed by default and refuses plain `pip install` otherwise.
This is a safe, deliberate override here — yt-dlp's zipapp just needs the
package importable, not a fully isolated environment.)

Verify it's picked up:
```bash
yt-dlp --verbose 2>&1 | grep -i impersonate
```
You should see a line listing available impersonate targets (e.g.
`chrome-...`) instead of the warning. The warning is non-fatal either
way — it only actually blocks a download if that specific extractor
*requires* impersonation and has no fallback — but it's worth fixing so you
don't hit a silent failure later on a site that does require it.

---

## Step 10: Verify everything is wired up

```bash
which ytdl
yt-dlp --version
ffmpeg -version
pwsh --version
```

All four should resolve without error. Also confirm the config version
comment is readable (sanity-checks that the file landed intact):
```bash
head -n 1 /home/linuxisthebest/yt-dlp/configs/yt-dlp.conf
```

---

## Step 11: First real test run

Pick a short, low-comment-count video for the first run (not something with
tens of thousands of comments — that's a 30-60+ minute comments pass, and
you want a fast first signal on whether the whole pipeline works end-to-end).

```bash
ytdl "https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID"
```

Watch for:
- The `Youtube Videos/Complete Archive/<uploader>/...` folder tree getting
  created with real (not literal `%(uploader)s`) names.
- `Archive Logs/Logs/download.log` growing with session start/end markers.
- After the main download finishes, `postprocess.ps1` kicking off — you'll
  see its `[comments]`, `[ffmpeg-reembed]`, and `[channel-info]`-prefixed
  lines appear in the console.
- A finished `video_postprocessing.log` inside that video's own `Logs/`
  subfolder — **this is the file to paste back into a Claude conversation**
  if anything looks wrong, per the project's usual debugging pattern.

---

## Quick reference: what lives where after setup

```
/home/linuxisthebest/yt-dlp/
├── scripts/
│   ├── run_ytdlp.ps1
│   └── postprocess.ps1
├── configs/
│   └── yt-dlp.conf
├── Archive Logs/
│   ├── Archive History/
│   └── Logs/            (download.log, archive.txt)
└── Youtube Videos/
    ├── Complete Archive/
    ├── _incomplete/
    └── Pure Video/

/home/linuxisthebest/.local/bin/
└── ytdl                  (entry point, on PATH)

/mnt/hgfs/<share-name>/   (VMware shared folder, host <-> guest)
```
