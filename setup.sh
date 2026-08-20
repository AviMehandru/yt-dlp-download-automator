#!/usr/bin/env bash
# Automated setup for the yt-dlp archival pipeline on a fresh Ubuntu VM.
# Mirrors the manual setup guide step-for-step.
#
# Deliberately does NOT use "set -e". Every external command that could
# plausibly fail on some systems (a package temporarily unavailable, no
# GUI packages on a minimal server install, a flaky network blip) is
# wrapped so a failure prints a clear WARNING and the script keeps going,
# rather than dying silently partway through. This matters most for
# Steps 8/9 (folder structure + placing the pipeline files, including
# ytdl itself) -- those should basically ALWAYS run, since nothing about
# them depends on earlier steps having succeeded. A previous version of
# this script used "set -euo pipefail" with one unguarded "apt install"
# for VMware guest tools; if that one command failed, the whole script
# died right there and the folder/file-placement steps never ran at all.
# That's fixed now: every step is independent, and a summary of anything
# that needs manual attention prints at the very end.
#
# Safe to re-run -- every step checks before it acts.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh

TARGET_USER="$(whoami)"
DATA_ROOT="${HOME}/yt-dlp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARNINGS=()

log()  { echo -e "\n>>> $*"; }
warn() { echo "WARNING: $*"; WARNINGS+=("$*"); }

# --- Step 1: update the system ---
log "Step 1/10: Updating system packages"
if ! sudo apt update; then
    warn "apt update failed -- package installs below may use a stale index. Run 'sudo apt update' manually and re-run this script."
fi
sudo apt upgrade -y || warn "apt upgrade failed -- continuing anyway."

# --- Step 2: base dependencies ---
log "Step 2/10: Installing ffmpeg and base tools"
if ! sudo apt install -y curl wget ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip; then
    warn "Base package install failed. yt-dlp/ffmpeg may not work until you run: sudo apt install -y curl wget ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip"
fi

# --- Step 3: yt-dlp (standalone binary, so -U self-update actually works) ---
log "Step 3/10: Installing yt-dlp"
if command -v yt-dlp >/dev/null 2>&1; then
    echo "yt-dlp already present ($(yt-dlp --version)) -- skipping install, run 'yt-dlp -U' to update."
    # Fix ownership even on an already-installed binary -- this is exactly
    # the bug that caused "Unable to write to /usr/local/bin/yt-dlp; try
    # running as administrator" during a real run: the binary was installed
    # via sudo (root-owned) but run_ytdlp.ps1 correctly runs yt-dlp -U as
    # the regular user, never sudo, so self-update couldn't write over it.
    YT_DLP_PATH="$(command -v yt-dlp)"
    if [ -w "$YT_DLP_PATH" ]; then
        : # already writable by this user, nothing to fix
    else
        sudo chown "$(id -u):$(id -g)" "$YT_DLP_PATH" 2>/dev/null \
            && echo "Fixed ownership of $YT_DLP_PATH so 'yt-dlp -U' can self-update without sudo." \
            || warn "$YT_DLP_PATH isn't writable by you and chown failed. Self-updates will keep failing with 'Unable to write' until you run: sudo chown \$(whoami):\$(whoami) $YT_DLP_PATH"
    fi
else
    if sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp; then
        sudo chmod a+rx /usr/local/bin/yt-dlp
        # Owned by the actual user (not root) specifically so the
        # dependency-check step in run_ytdlp.ps1 -- which deliberately runs
        # as a normal user, never sudo, per this project's own stance on not
        # having an unattended script silently invoke sudo -- can actually
        # complete "yt-dlp -U" self-updates going forward.
        sudo chown "$(id -u):$(id -g)" /usr/local/bin/yt-dlp
    else
        warn "yt-dlp download failed. Retry manually: sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp && sudo chmod a+rx /usr/local/bin/yt-dlp && sudo chown \$(whoami):\$(whoami) /usr/local/bin/yt-dlp"
    fi
fi

# --- Step 4: PowerShell 7 ---
log "Step 4/10: Installing PowerShell 7 (pwsh)"
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
log "Step 5/10: Installing curl_cffi (browser-impersonation support for yt-dlp)"
if ! python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages; then
    warn "curl_cffi install failed. yt-dlp will keep warning about missing impersonation targets until you retry: python3 -m pip install -U \"curl_cffi>=0.10\" --break-system-packages"
fi

# --- Step 6: Deno (JS runtime -- YouTube now requires solving a JS ---
# challenge for cipher decryption; without a JS runtime, yt-dlp falls back
# to less reliable extraction paths, which is also a common cause of
# mid-download HTTP 403 errors, not just the warning text itself.
log "Step 6/10: Installing Deno (JavaScript runtime required for current YouTube extraction)"
if command -v deno >/dev/null 2>&1; then
    echo "deno already present ($(deno --version | head -n1)) -- skipping."
else
    if curl -fsSL https://deno.land/install.sh | sh -s -- -y >/tmp/deno-install.log 2>&1; then
        DENO_BIN="$(find "${HOME}/.deno/bin" -name deno 2>/dev/null | head -n1)"
        if [ -n "$DENO_BIN" ]; then
            sudo cp "$DENO_BIN" /usr/local/bin/deno
            sudo chmod a+rx /usr/local/bin/deno
            echo "Installed deno to /usr/local/bin/deno ($(deno --version | head -n1))."
        else
            warn "Deno installer ran but the binary wasn't found under ${HOME}/.deno/bin -- see /tmp/deno-install.log."
        fi
    else
        warn "Deno install failed -- see /tmp/deno-install.log. YouTube downloads may hit 403 errors or miss formats until this is resolved (yt-dlp/yt-dlp#14404). Retry manually: curl -fsSL https://deno.land/install.sh | sh"
    fi
fi

# --- Step 7: VMware shared folder support (safe no-op outside VMware) ---
# Deliberately does NOT reboot. A reboot would kill this script mid-run
# (a shell script isn't a service -- it doesn't resume itself afterward),
# and it isn't actually necessary: restarting the vmtoolsd service and
# mounting directly gets the shared folder working immediately.
log "Step 7/10: Setting up VMware shared folder (open-vm-tools)"
if systemd-detect-virt 2>/dev/null | grep -qi vmware; then
    if ! sudo apt install -y open-vm-tools open-vm-tools-desktop; then
        warn "open-vm-tools install failed (open-vm-tools-desktop in particular can fail on a minimal/headless install if its GUI dependencies don't resolve). Shared folder won't be available. Retry with: sudo apt install -y open-vm-tools (drop -desktop if you're headless)."
    else
        # Restart the service so the newly-installed tools take effect
        # immediately, without a reboot.
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

# --- Step 8: folder structure ---
log "Step 8/10: Creating folder structure under ${DATA_ROOT}"
mkdir -p "${DATA_ROOT}/scripts"
mkdir -p "${DATA_ROOT}/configs"
mkdir -p "${DATA_ROOT}/Archive Logs/Archive History"
mkdir -p "${DATA_ROOT}/Archive Logs/Logs"
mkdir -p "${DATA_ROOT}/Youtube Videos/Complete Archive"
mkdir -p "${DATA_ROOT}/Youtube Videos/_incomplete"
mkdir -p "${DATA_ROOT}/Youtube Videos/Pure Video"
mkdir -p "${DATA_ROOT}/Youtube Videos/Final Video"
mkdir -p "${HOME}/.local/bin"
echo "Folder structure created."

# --- Step 9: place the four pipeline files ---
# Each file is copied independently -- a missing one only warns about
# itself and doesn't block the others, unlike a previous version of this
# script which checked all four up front and skipped the ENTIRE step
# (including ytdl) if even one was absent.
log "Step 9/10: Installing pipeline files"
copy_file() {
    local src="$1" dest="$2" label="$3"
    if [ -f "${SCRIPT_DIR}/${src}" ]; then
        cp "${SCRIPT_DIR}/${src}" "$dest"
        echo "Installed ${label} -> ${dest}"
    else
        warn "${src} not found next to setup.sh (looked in ${SCRIPT_DIR}) -- ${label} was NOT installed. Copy it to ${dest} manually."
    fi
}
copy_file "linux-run_ytdlp.ps1"   "${DATA_ROOT}/scripts/run_ytdlp.ps1"   "run_ytdlp.ps1"
copy_file "linux-postprocess.ps1" "${DATA_ROOT}/scripts/postprocess.ps1" "postprocess.ps1"
copy_file "linux-yt-dlp.conf"     "${DATA_ROOT}/configs/yt-dlp.conf"     "yt-dlp.conf"
copy_file "linux-ytdl"            "${HOME}/.local/bin/ytdl"              "ytdl"
if [ -f "${HOME}/.local/bin/ytdl" ]; then
    chmod +x "${HOME}/.local/bin/ytdl"
fi

if ! echo "$PATH" | tr ':' '\n' | grep -q "${HOME}/.local/bin"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
    echo "Added \$HOME/.local/bin to PATH in ~/.bashrc -- run 'source ~/.bashrc' or start a new shell before using 'ytdl'."
fi

# --- Step 10: verify ---
log "Step 10/10: Verifying installation"
echo "yt-dlp:  $(yt-dlp --version 2>/dev/null || echo 'NOT FOUND')"
echo "ffmpeg:  $(ffmpeg -version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "pwsh:    $(pwsh --version 2>/dev/null || echo 'NOT FOUND')"
echo "deno:    $(deno --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "ytdl:    $(command -v ytdl || echo 'NOT FOUND (open a new shell if PATH was just updated)')"

if [ "${#WARNINGS[@]}" -gt 0 ]; then
    log "Setup finished with ${#WARNINGS[@]} item(s) needing attention:"
    for w in "${WARNINGS[@]}"; do
        echo "  - $w"
    done
else
    log "Setup complete, no issues detected."
fi
echo -e "\nTest with: ytdl \"https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID\""
