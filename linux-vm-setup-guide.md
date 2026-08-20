# Setting Up the yt-dlp Archival Pipeline on a Fresh Linux VM

> **Shortcut:** `setup.sh` (attached alongside the four pipeline files) automates every step below (1 through 9) in one run. Place it in the same folder as `linux-ytdl`, `linux-run_ytdlp.ps1`, `linux-postprocess.ps1`, and `linux-yt-dlp.conf`, then run `chmod +x setup.sh && ./setup.sh`. It's idempotent -- safe to re-run if you want to retry a step that needed manual attention. It does **not** hard-abort on a failed non-critical step (an earlier version did, which is what caused `ytdl` not to get installed automatically the first time around -- see the note in Step 7 below); instead it prints a summary of anything that needs a manual look at the very end. The manual steps below are still here for reference, or if you want to run things by hand.

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
sudo apt install -y curl wget ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip
```

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
sudo cp "$HOME/.deno/bin/deno" /usr/local/bin/deno
sudo chmod a+rx /usr/local/bin/deno
```

Verify:
```bash
deno --version
```

`yt-dlp.conf` already points at this fixed location
(`--js-runtimes "deno:/usr/local/bin/deno"`), rather than relying on `deno`
merely being somewhere on your interactive shell's `PATH` — that matters
because the `PATH` inside yt-dlp's own process (and anything it spawns)
isn't guaranteed to match your shell's.

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
drop in the four pipeline files from the host instead of re-typing them.

---

## Step 8: Create the folder structure

```bash
mkdir -p "$HOME/yt-dlp/scripts"
mkdir -p "$HOME/yt-dlp/configs"
mkdir -p "$HOME/yt-dlp/Archive Logs/Archive History"
mkdir -p "$HOME/yt-dlp/Archive Logs/Logs"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Complete Archive"
mkdir -p "$HOME/yt-dlp/Youtube Videos/_incomplete"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Pure Video"
mkdir -p "$HOME/yt-dlp/Youtube Videos/Final Video"
```

(`run_ytdlp.ps1` also self-heals this same structure on every run, so a
later wipe doesn't require redoing this step by hand.)

---

## Step 9: Place the four pipeline files and put `ytdl` on your `PATH`

```bash
cp linux-run_ytdlp.ps1   "$HOME/yt-dlp/scripts/run_ytdlp.ps1"
cp linux-postprocess.ps1 "$HOME/yt-dlp/scripts/postprocess.ps1"
cp linux-yt-dlp.conf     "$HOME/yt-dlp/configs/yt-dlp.conf"
mkdir -p "$HOME/.local/bin"
cp linux-ytdl "$HOME/.local/bin/ytdl"
chmod +x "$HOME/.local/bin/ytdl"
```

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

## Step 10: Verify everything is wired up

```bash
which ytdl
yt-dlp --version
ffmpeg -version
pwsh --version
deno --version
head -n 1 "$HOME/yt-dlp/configs/yt-dlp.conf"
```

All five tools should resolve without error, and the last command should
print the current `CONFIG_VERSION` line.

---

## Step 11: First real test run

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

## Quick reference: what lives where after setup

```
$HOME/yt-dlp/                      (install root -- always here, regardless of -DataRoot)
├── scripts/
│   ├── run_ytdlp.ps1
│   └── postprocess.ps1
└── configs/
    └── yt-dlp.conf

$HOME/yt-dlp/  <or a custom -DataRoot>
├── Archive Logs/
│   ├── Archive History/
│   └── Logs/            (download.log, archive.txt)
└── Youtube Videos/
    ├── Complete Archive/
    ├── _incomplete/
    ├── Pure Video/
    └── Final Video/

$HOME/.local/bin/
└── ytdl                  (entry point, on PATH)

/mnt/hgfs/<share-name>/   (VMware shared folder, host <-> guest)
```
