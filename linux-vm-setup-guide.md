# Setting Up the yt-dlp Archival Pipeline on a Fresh Linux VM

This assumes a fresh **Ubuntu** VM (matches the `apt`-based dependency checks
baked into `linux-run_ytdlp.ps1`). The scripts are hardcoded to the username
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

This uses Microsoft's official apt repo, which is also what lets the
dependency-check logic detect `pwsh` updates via `apt list --upgradable`
(it checks for a `powershell/` line).

```bash
source /etc/os-release
wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt update
sudo apt install -y powershell
```

Verify:
```bash
pwsh --version
```

> If Microsoft hasn't published a repo for your exact Ubuntu release yet
> (common right after a new Ubuntu version ships), use the next-oldest LTS's
> `VERSION_ID` in the URL above instead — the `.deb` packages are
> version-agnostic enough that this normally works fine.

---

## Step 5: Create the folder structure

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

## Step 6: Place the four pipeline files

Copy the four files (already updated with `linuxisthebest` baked in) into
place:

```bash
cp linux-run_ytdlp.ps1  /home/linuxisthebest/yt-dlp/scripts/run_ytdlp.ps1
cp linux-postprocess.ps1 /home/linuxisthebest/yt-dlp/scripts/postprocess.ps1
cp linux-yt-dlp.conf     /home/linuxisthebest/yt-dlp/configs/yt-dlp.conf
cp linux-ytdl            /home/linuxisthebest/.local/bin/ytdl
```

Note the renames — `run_ytdlp.ps1` and `postprocess.ps1` on disk shouldn't
keep the `linux-` prefix, since that's just how they're labeled in this
conversation to distinguish them from the Windows copies.

---

## Step 7: Make `ytdl` executable and put it on your `PATH`

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

## Step 8: Verify everything is wired up

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

## Step 9: First real test run

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
```
