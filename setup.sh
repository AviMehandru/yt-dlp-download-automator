#!/usr/bin/env bash
# Automated setup for the yt-dlp archival pipeline on a fresh Ubuntu VM.
# Mirrors the manual setup guide step-for-step. Safe to re-run -- every
# step checks before it acts, so running this again after a partial
# failure just picks up where it left off rather than redoing everything.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh
#
# Assumes: Ubuntu (tested against 26.04 "Resolute Raccoon"), and that this
# script sits in the SAME directory as the four pipeline files (ytdl,
# run_ytdlp.ps1, postprocess.ps1, yt-dlp.conf) with the target username
# already baked into them (see the project's username-replacement step).

set -euo pipefail

TARGET_USER="linuxisthebest"
DATA_ROOT="/home/${TARGET_USER}/yt-dlp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "\n>>> $*"; }

if [ "$(whoami)" != "$TARGET_USER" ]; then
    echo "WARNING: current user is '$(whoami)', not '$TARGET_USER'."
    echo "The pipeline scripts have '/home/${TARGET_USER}/...' hardcoded."
    echo "Either re-run this as the '${TARGET_USER}' user, or edit"
    echo "TARGET_USER at the top of this script AND re-run the same"
    echo "find-and-replace on the four pipeline files first."
    read -rp "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

# --- Step 1: update the system ---
log "Step 1/9: Updating system packages"
sudo apt update && sudo apt upgrade -y

# --- Step 2: base dependencies ---
log "Step 2/9: Installing ffmpeg and base tools"
sudo apt install -y curl wget ffmpeg ca-certificates apt-transport-https software-properties-common python3-pip

# --- Step 3: yt-dlp (standalone binary, so -U self-update actually works) ---
log "Step 3/9: Installing yt-dlp"
if command -v yt-dlp >/dev/null 2>&1; then
    echo "yt-dlp already present ($(yt-dlp --version)) -- skipping install, run 'yt-dlp -U' to update."
else
    sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
    sudo chmod a+rx /usr/local/bin/yt-dlp
fi

# --- Step 4: PowerShell 7 ---
log "Step 4/9: Installing PowerShell 7 (pwsh)"
if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh already present ($(pwsh --version)) -- skipping."
else
    # As of this writing, Microsoft has not published apt packages for
    # Ubuntu 26.04 (open, unresolved gap on their end -- see
    # microsoft/linux-package-repositories#345). Try apt first anyway in
    # case that's changed by the time this runs; fall back to snap.
    source /etc/os-release
    APT_INSTALL_OK=0
    if wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb 2>/dev/null; then
        sudo dpkg -i /tmp/packages-microsoft-prod.deb >/dev/null 2>&1 || true
        rm -f /tmp/packages-microsoft-prod.deb
        sudo apt update
        if sudo apt install -y powershell 2>/dev/null; then
            APT_INSTALL_OK=1
        fi
    fi
    if [ "$APT_INSTALL_OK" -eq 0 ]; then
        echo "apt package for pwsh not available for Ubuntu ${VERSION_ID} -- falling back to snap."
        sudo snap install powershell --classic
    fi
fi

# --- Step 5: curl_cffi (fixes the "no impersonate target" warning) ---
log "Step 5/9: Installing curl_cffi (browser-impersonation support for yt-dlp)"
python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages

# --- Step 6: VMware shared folder support (safe no-op outside VMware) ---
log "Step 6/9: Installing VMware guest tools (open-vm-tools)"
if systemd-detect-virt 2>/dev/null | grep -qi vmware; then
    sudo apt install -y open-vm-tools open-vm-tools-desktop
    echo "Installed. If /mnt/hgfs doesn't show your shared folder after a reboot, see the setup guide's manual vmhgfs-fuse mount steps."
else
    echo "Not detected as a VMware guest -- skipping open-vm-tools (harmless to install manually later if needed)."
fi

# --- Step 7: folder structure ---
log "Step 7/9: Creating folder structure under ${DATA_ROOT}"
mkdir -p "${DATA_ROOT}/scripts"
mkdir -p "${DATA_ROOT}/configs"
mkdir -p "${DATA_ROOT}/Archive Logs/Archive History"
mkdir -p "${DATA_ROOT}/Archive Logs/Logs"
mkdir -p "${DATA_ROOT}/Youtube Videos/Complete Archive"
mkdir -p "${DATA_ROOT}/Youtube Videos/_incomplete"
mkdir -p "${DATA_ROOT}/Youtube Videos/Pure Video"
mkdir -p "${DATA_ROOT}/Youtube Videos/Final Video"
mkdir -p "${HOME}/.local/bin"

# --- Step 8: place the four pipeline files ---
log "Step 8/9: Installing pipeline files"
missing=0
for f in linux-run_ytdlp.ps1 linux-postprocess.ps1 linux-yt-dlp.conf linux-ytdl; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        echo "MISSING: ${SCRIPT_DIR}/${f} -- place it next to this script and re-run."
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo "Stopping before Step 8: one or more pipeline files not found next to setup.sh."
    exit 1
fi
cp "${SCRIPT_DIR}/linux-run_ytdlp.ps1"   "${DATA_ROOT}/scripts/run_ytdlp.ps1"
cp "${SCRIPT_DIR}/linux-postprocess.ps1" "${DATA_ROOT}/scripts/postprocess.ps1"
cp "${SCRIPT_DIR}/linux-yt-dlp.conf"     "${DATA_ROOT}/configs/yt-dlp.conf"
cp "${SCRIPT_DIR}/linux-ytdl"            "${HOME}/.local/bin/ytdl"
chmod +x "${HOME}/.local/bin/ytdl"

if ! echo "$PATH" | tr ':' '\n' | grep -q "${HOME}/.local/bin"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
    echo "Added \$HOME/.local/bin to PATH in ~/.bashrc -- run 'source ~/.bashrc' or start a new shell."
fi

# --- Step 9: verify ---
log "Step 9/9: Verifying installation"
echo "yt-dlp:  $(yt-dlp --version 2>/dev/null || echo 'NOT FOUND')"
echo "ffmpeg:  $(ffmpeg -version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "pwsh:    $(pwsh --version 2>/dev/null || echo 'NOT FOUND')"
echo "ytdl:    $(command -v ytdl || echo 'NOT FOUND (open a new shell if PATH was just updated)')"

log "Setup complete. Test with: ytdl \"https://www.youtube.com/watch?v=SOME_SHORT_VIDEO_ID\""
