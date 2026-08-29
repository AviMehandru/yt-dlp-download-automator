#!/usr/bin/env bash
# Automated setup for the yt-dlp archival pipeline on a fresh Ubuntu VM.
# Mirrors the manual setup guide step-for-step.
#
# Deliberately does NOT use "set -e". Every external command that could
# plausibly fail on some systems (a package temporarily unavailable, no
# GUI packages on a minimal server install, a flaky network blip) is
# wrapped so a failure prints a clear WARNING and the script keeps going,
# rather than dying silently partway through. This matters most for the
# folder-structure and file-placement steps -- those should basically
# ALWAYS run, since nothing about them depends on earlier steps having
# succeeded.
#
# Safe to re-run -- every step checks before it acts.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh

DATA_ROOT="${HOME}/yt-dlp"
LOCAL_BIN="${HOME}/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://github.com/AviMehandru/yt-dlp-download-automator.git"
REPO_DIR="${SCRIPT_DIR}/YT-DLP Installation Files"
WARNINGS=()

# --- Console log capture ---
# Saves a full, byte-for-byte copy of everything this script prints (both
# the script's own echo/log/warn lines AND the raw output of every
# external command it runs -- apt, curl, yt-dlp -U, the deno installer,
# git, etc) to a timestamped file, while still showing it all on the
# terminal live as normal. Uses the same "Archive Logs/Logs" directory
# the rest of the pipeline already logs into (download.log,
# video_postprocessing.log), for one consistent place to look, rather
# than inventing a separate logs location just for setup runs.
#
# This log dir is created here, standalone, rather than waiting for Step
# 9 (which creates the full folder tree) -- setup needs somewhere to log
# its own very first commands (apt update etc.), well before Step 9 runs.
# Step 9's later `mkdir -p` of the same path is a harmless no-op once this
# has already created it.
#
# exec > >(tee -a "$LOG_FILE") 2>&1 replaces the script's own stdout/stderr
# for the rest of the run: every command's output flows through `tee`,
# which duplicates it to both the terminal (so you still watch it live,
# including e.g. apt's own progress bars) and appends it to $LOG_FILE.
# This needs bash's process-substitution support (>(...)), which is why
# the shebang above is bash specifically, not /bin/sh.
LOG_DIR="${DATA_ROOT}/Archive Logs/Logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging full console output to: ${LOG_FILE}"

# --- Overall progress bar ---
# This is a step-counter bar, not a byte/percent-of-work bar: it advances
# once per top-level step (11 total, matching the "Step N/11" labels this
# script has always printed), regardless of how long that step's actual
# work takes. That's a deliberate simplification -- the individual
# installers/downloads below (apt, curl, yt-dlp -U, deno's installer, git
# clone) already print their own real progress bars for their own work,
# so this one only needs to answer "how far through the whole script am
# I", not duplicate byte-level progress that's already visible.
# TOTAL_STEPS must match the number of log() calls below (currently 11) --
# if a step is ever added or removed, update this constant in the same
# commit, or the bar will finish early/late relative to the actual work.
TOTAL_STEPS=11
CURRENT_STEP=0

draw_progress_bar() {
    local width=30
    local pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local filled=$(( CURRENT_STEP * width / TOTAL_STEPS ))
    local empty=$(( width - filled ))
    local bar=""
    if [ "$filled" -gt 0 ]; then
        bar+=$(printf '%*s' "$filled" '' | tr ' ' '#')
    fi
    if [ "$empty" -gt 0 ]; then
        bar+=$(printf '%*s' "$empty" '' | tr ' ' '-')
    fi
    printf 'Overall progress: [%s] %3d%%  (step %d/%d)\n' "$bar" "$pct" "$CURRENT_STEP" "$TOTAL_STEPS"
}

# log() now does double duty: it's still the per-step header (as before),
# but it also owns the step counter -- every call advances the overall bar
# by exactly one step. This keeps the bar's step count and the actual
# "Step N/11" numbering impossible to drift apart from each other, since
# there's only one place (this function) that increments anything, instead
# of hand-typing "Step 3/11" etc. at each call site where it could get out
# of sync if steps are ever reordered/added later.
log()  {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    draw_progress_bar
    echo -e ">>> Step ${CURRENT_STEP}/${TOTAL_STEPS}: $*"
}
warn() { echo "WARNING: $*"; WARNINGS+=("$*"); }

mkdir -p "$LOCAL_BIN"

# --- Step 1: update the system ---
log "Updating system packages"
if ! sudo apt update; then
    warn "apt update failed -- package installs below may use a stale index. Run 'sudo apt update' manually and re-run this script."
fi
sudo apt upgrade -y || warn "apt upgrade failed -- continuing anyway."

# --- Step 2: base dependencies ---
log "Installing ffmpeg, git, and base tools"
if ! sudo apt install -y curl wget git ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip; then
    warn "Base package install failed. yt-dlp/ffmpeg/git may not work until you run: sudo apt install -y curl wget git ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip"
fi

# --- Step 3: yt-dlp (standalone binary, so -U self-update actually works) ---
# Installed to $HOME/.local/bin, NOT /usr/local/bin. A real run showed
# self-update failing even after chown'ing just the binary file -- yt-dlp's
# updater needs to write into the CONTAINING directory too (it writes a
# temp file and renames over the old one), and /usr/local/bin is root-owned
# regardless of who owns the file inside it. Installing into a directory
# the user already owns outright sidesteps the whole problem rather than
# patching around it.
log "Installing yt-dlp"
if command -v yt-dlp >/dev/null 2>&1 && [ "$(command -v yt-dlp)" = "${LOCAL_BIN}/yt-dlp" ]; then
    echo "yt-dlp already present at ${LOCAL_BIN}/yt-dlp ($(yt-dlp --version)) -- skipping install, run 'yt-dlp -U' to update."
else
    if curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o "${LOCAL_BIN}/yt-dlp"; then
        chmod a+rx "${LOCAL_BIN}/yt-dlp"
        echo "Installed yt-dlp to ${LOCAL_BIN}/yt-dlp."
    else
        warn "yt-dlp download failed. Retry manually: curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o ${LOCAL_BIN}/yt-dlp && chmod a+rx ${LOCAL_BIN}/yt-dlp"
    fi
fi

# --- Step 4: PowerShell 7 ---
log "Installing PowerShell 7 (pwsh)"
if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh already present ($(pwsh --version)) -- skipping."
else
    # As of this writing, Microsoft has not published apt packages for
    # Ubuntu 26.04 (open, unresolved gap on their end). Try apt first anyway
    # in case that's changed by the time this runs; fall back to snap.
    source /etc/os-release
    APT_INSTALL_OK=0
    if wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb 2>/dev/null; then
        sudo dpkg -i /tmp/packages-microsoft-prod.deb >/dev/null 2>&1 || true
        rm -f /tmp/packages-microsoft-prod.deb
        sudo apt update >/dev/null 2>&1 || true
        if sudo apt install -y powershell 2>/dev/null; then
            APT_INSTALL_OK=1
        fi
    fi
    if [ "$APT_INSTALL_OK" -eq 0 ]; then
        echo "apt package for pwsh not available for Ubuntu ${VERSION_ID} -- falling back to snap."
        if ! sudo snap install powershell --classic; then
            warn "pwsh install failed via both apt and snap. Install manually before using the pipeline -- nothing else here can run without it."
        fi
    fi
fi

# --- Step 5: curl_cffi (fixes the "no impersonate target" warning) ---
log "Installing curl_cffi (browser-impersonation support for yt-dlp)"
if ! python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages; then
    warn "curl_cffi install failed. yt-dlp will keep warning about missing impersonation targets until you retry: python3 -m pip install -U \"curl_cffi>=0.10\" --break-system-packages"
fi

# --- Step 6: Deno (JS runtime -- YouTube now requires solving a JS ---
# challenge for cipher decryption). Installed to $HOME/.local/bin for the
# same reason as yt-dlp above -- no root-owned install location, no
# possible ownership/permission mismatch down the line.
log "Installing Deno (JavaScript runtime required for current YouTube extraction)"
if [ -x "${LOCAL_BIN}/deno" ]; then
    echo "deno already present at ${LOCAL_BIN}/deno ($(${LOCAL_BIN}/deno --version | head -n1)) -- skipping."
else
    if curl -fsSL https://deno.land/install.sh | sh -s -- -y >/tmp/deno-install.log 2>&1; then
        DENO_BIN="$(find "${HOME}/.deno/bin" -name deno 2>/dev/null | head -n1)"
        if [ -n "$DENO_BIN" ]; then
            cp "$DENO_BIN" "${LOCAL_BIN}/deno"
            chmod a+rx "${LOCAL_BIN}/deno"
            echo "Installed deno to ${LOCAL_BIN}/deno ($(${LOCAL_BIN}/deno --version | head -n1))."
        else
            warn "Deno installer ran but the binary wasn't found under ${HOME}/.deno/bin -- see /tmp/deno-install.log."
        fi
    else
        warn "Deno install failed -- see /tmp/deno-install.log. YouTube downloads may hit errors or miss formats until this is resolved. Retry manually: curl -fsSL https://deno.land/install.sh | sh"
    fi
fi
# run_ytdlp.ps1 expects deno at exactly $HOME/.local/bin/deno (it builds
# this path itself via --js-runtimes, not read from PATH) -- if you ever
# install deno somewhere else, that line needs updating too.

# --- Step 7: clone the project repo ---
# Convenience step: pulls the actual project files down automatically so
# Step 10 below can find them without you having to place them by hand.
# ASSUMPTION: this expects the repo to contain files named the same way
# they've been named throughout this project (linux-run_ytdlp.ps1,
# linux-postprocess.ps1, linux-yt-dlp.conf, linux-ytdl) either at the repo
# root or in a "linux" subfolder -- Step 10 checks both. If your repo's
# actual layout differs, this clone still succeeds (it's just a git
# clone), but Step 10's automatic file-matching may not find them --
# check the warnings at the end if so.
log "Cloning project repository"
if [ -d "$REPO_DIR/.git" ]; then
    echo "Repository already cloned at '${REPO_DIR}' -- pulling latest instead."
    if ! git -C "$REPO_DIR" pull; then
        warn "git pull failed in '${REPO_DIR}'. Check it manually if you expect updates from the repo."
    fi
else
    if ! git clone "$REPO_URL" "$REPO_DIR"; then
        warn "git clone of $REPO_URL failed. If the repo is private, you'll need to authenticate (e.g. gh auth login, or an SSH remote) and clone manually into: $REPO_DIR"
    fi
fi

# --- Step 8: VMware shared folder support (safe no-op outside VMware) ---
# Deliberately does NOT reboot. A reboot would kill this script mid-run
# (a shell script isn't a service -- it doesn't resume itself afterward),
# and it isn't actually necessary: restarting the vmtoolsd service and
# mounting directly gets the shared folder working immediately.
log "Setting up VMware shared folder (open-vm-tools)"
if systemd-detect-virt 2>/dev/null | grep -qi vmware; then
    if ! sudo apt install -y open-vm-tools open-vm-tools-desktop; then
        warn "open-vm-tools install failed (open-vm-tools-desktop in particular can fail on a minimal/headless install if its GUI dependencies don't resolve). Shared folder won't be available. Retry with: sudo apt install -y open-vm-tools (drop -desktop if you're headless)."
    else
        sudo systemctl restart open-vm-tools.service 2>/dev/null \
            || sudo systemctl restart vmtoolsd.service 2>/dev/null \
            || warn "Could not restart the VMware tools service by either known name -- shared folder may need a manual 'sudo reboot' if the direct mount below also fails."

        sudo mkdir -p /mnt/hgfs
        if sudo vmhgfs-fuse .host:/ /mnt/hgfs -o subtype=vmhgfs-fuse,allow_other 2>/tmp/vmhgfs-mount.log; then
            echo "Mounted shared folders at /mnt/hgfs (no reboot needed)."
            if ! grep -q '^\.host:/' /etc/fstab 2>/dev/null; then
                echo '.host:/    /mnt/hgfs   fuse.vmhgfs-fuse    defaults,allow_other    0    0' | sudo tee -a /etc/fstab >/dev/null
                echo "Added /mnt/hgfs to /etc/fstab so this survives future reboots."
            fi
        else
            warn "Direct vmhgfs-fuse mount failed -- see /tmp/vmhgfs-mount.log. Make sure a shared folder is actually enabled in VM Settings > Options > Shared Folders on the host, then retry: sudo vmhgfs-fuse .host:/ /mnt/hgfs -o subtype=vmhgfs-fuse,allow_other -- a full 'sudo reboot' is the last-resort fallback if that still doesn't work."
        fi
    fi
else
    echo "Not detected as a VMware guest -- skipping shared folder setup."
fi

# --- Step 9: folder structure ---
log "Creating folder structure under ${DATA_ROOT}"
mkdir -p "${DATA_ROOT}/scripts"
mkdir -p "${DATA_ROOT}/configs"
mkdir -p "${DATA_ROOT}/Archive Logs/Archive History"
mkdir -p "${DATA_ROOT}/Archive Logs/Logs"
mkdir -p "${DATA_ROOT}/Youtube Videos/Complete Archive"
mkdir -p "${DATA_ROOT}/Youtube Videos/_incomplete"
mkdir -p "${DATA_ROOT}/Youtube Videos/Pure Video"
mkdir -p "${DATA_ROOT}/Youtube Videos/Final Video"
echo "Folder structure created."

# --- Step 10: place the four pipeline files ---
# Looks in three places, in order: next to setup.sh itself, inside the
# cloned repo's root, and inside a "linux" subfolder of the cloned repo
# (covering the most likely layouts without guessing further). Each file
# is resolved and copied independently -- a missing one only warns about
# itself and doesn't block the others.
log "Installing pipeline files"
copy_file() {
    local src="$1" dest="$2" label="$3"
    local candidates=(
        "${SCRIPT_DIR}/${src}"
        "${REPO_DIR}/${src}"
        "${REPO_DIR}/linux/${src}"
    )
    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            cp "$candidate" "$dest"
            echo "Installed ${label} -> ${dest} (from ${candidate})"
            return 0
        fi
    done
    warn "${src} not found in any of: ${candidates[*]} -- ${label} was NOT installed. Copy it to ${dest} manually."
}
copy_file "linux-run_ytdlp.ps1"   "${DATA_ROOT}/scripts/run_ytdlp.ps1"   "run_ytdlp.ps1"
copy_file "linux-postprocess.ps1" "${DATA_ROOT}/scripts/postprocess.ps1" "postprocess.ps1"
copy_file "linux-yt-dlp.conf"     "${DATA_ROOT}/configs/yt-dlp.conf"     "yt-dlp.conf"
copy_file "linux-ytdl"            "${LOCAL_BIN}/ytdl"                    "ytdl"
if [ -f "${LOCAL_BIN}/ytdl" ]; then
    chmod +x "${LOCAL_BIN}/ytdl"
fi

if ! echo "$PATH" | tr ':' '\n' | grep -q "${LOCAL_BIN}"; then
    echo "export PATH=\"${LOCAL_BIN}:\$PATH\"" >> "${HOME}/.bashrc"
    echo "Added ${LOCAL_BIN} to PATH in ~/.bashrc -- run 'source ~/.bashrc' or start a new shell before using 'ytdl'."
fi

# --- Step 11: verify ---
log "Verifying installation"
echo "yt-dlp:  $(yt-dlp --version 2>/dev/null || echo 'NOT FOUND')"
echo "ffmpeg:  $(ffmpeg -version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "pwsh:    $(pwsh --version 2>/dev/null || echo 'NOT FOUND')"
echo "deno:    $(${LOCAL_BIN}/deno --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "git:     $(git --version 2>/dev/null || echo 'NOT FOUND')"
echo "ytdl:    $(command -v ytdl || echo 'NOT FOUND (open a new shell if PATH was just updated)')"

# NOTE: this final summary deliberately does NOT call log() -- log() is
# what advances the step counter, and all 11 real steps are already done
# by this point. Calling it again here would push CURRENT_STEP past
# TOTAL_STEPS and make the bar overshoot 100%/overflow its own math.
echo ""
draw_progress_bar
if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo -e ">>> Setup finished with ${#WARNINGS[@]} item(s) needing attention:"
    for w in "${WARNINGS[@]}"; do
        echo "  - $w"
    done
else
    echo -e ">>> Setup complete, no issues detected."
fi
echo -e "\nFull console log saved to: ${LOG_FILE}"
echo -e "\nTest with: ytdl \"https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID\""
