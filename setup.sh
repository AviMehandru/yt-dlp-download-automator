#!/usr/bin/env bash
# Automated setup for the yt-dlp archival pipeline on Linux (Ubuntu) and
# macOS. Mirrors the manual setup guide step-for-step.
#
# ONE script for both Unix platforms rather than a separate mac-setup.sh.
# The two genuinely differ in only three places -- which package manager
# installs things, which yt-dlp release asset to download, and what
# "desktop preview support" means -- and each of those is a small branch
# below, marked with a PLATFORM comment. Everything else (the folder tree,
# the file placement, the ytdl-view launcher, PATH wiring, verification) is
# byte-for-byte identical, and keeping it in one file is what stops the
# macOS half from quietly falling behind the Linux half the way the Windows
# scripts previously did.
#
# Windows has its own installer, setup.ps1, since nothing here can run
# there. It performs the same twelve steps with winget in place of
# apt/brew.
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

# --- PLATFORM detection ---
# Done first, before anything else, since almost every step below reads it.
# uname -s is the portable answer here and needs no external tooling.
case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)
        echo "ERROR: unsupported platform '$(uname -s)'. This installer covers Linux and macOS; use setup.ps1 on Windows." >&2
        exit 1
        ;;
esac

# --- Linux distribution family detection ---
# Sets DISTRO_FAMILY and PKG. Every step below asks for packages by ROLE
# ($PKGS_BASE, $PKGS_THUMB) rather than naming apt packages inline, so
# supporting another distro means extending the maps here and nothing else.
#
# Detection reads ID first, then ID_LIKE, from /etc/os-release. ID_LIKE is
# what makes derivatives work for free, and is the whole reason this is worth
# doing properly rather than matching a hardcoded list of distro names: Mint
# declares ID_LIKE=ubuntu, Pop!_OS "ubuntu debian", Manjaro and EndeavourOS
# "arch", Rocky and Alma "rhel centos fedora". None of them need naming here.
#
# The surrounding spaces in the case patterns are deliberate. ID_LIKE is a
# space-separated list, so matching *" arch "* against " $id $id_like "
# tests for a whole word and cannot match "archlabs" or similar by accident.
DISTRO_FAMILY="unknown"
PKG=""
DISTRO_PRETTY=""
if [ "$PLATFORM" = "linux" ]; then
    _id=""; _id_like=""
    if [ -r /etc/os-release ]; then
        . /etc/os-release 2>/dev/null || true
        _id="${ID:-}"
        _id_like="${ID_LIKE:-}"
        DISTRO_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
    fi
    case " ${_id} ${_id_like} " in
        *" debian "*|*" ubuntu "*)             DISTRO_FAMILY="debian"; PKG="apt" ;;
        *" fedora "*|*" rhel "*|*" centos "*)  DISTRO_FAMILY="fedora"; PKG="dnf" ;;
        *" arch "*)                            DISTRO_FAMILY="arch";   PKG="pacman" ;;
        *" suse "*|*" opensuse "*)             DISTRO_FAMILY="suse";   PKG="zypper" ;;
        *)
            # ID itself can be a hyphenated variant the word-boundary patterns
            # above miss: openSUSE uses ID=opensuse-tumbleweed and
            # ID=opensuse-leap. Handled separately rather than by loosening
            # those patterns, which would invite false positives.
            case "${_id}" in
                opensuse*) DISTRO_FAMILY="suse";    PKG="zypper" ;;
                *)         DISTRO_FAMILY="unknown"; PKG="" ;;
            esac
            ;;
    esac
    unset _id _id_like
fi

# --- Package name maps ---
# Same role, different names. Where every family agrees (mpv, vlc,
# ffmpegthumbnailer, webp-pixbuf-loader) the string is simply repeated, which
# reads better than a conditional for one shared value.
#
# NO LONGER LISTED: apt-transport-https and software-properties-common. Those
# existed only to add Microsoft's apt repository for PowerShell, and
# PowerShell no longer comes from a distro repository at all -- see Step 4.
case "$DISTRO_FAMILY" in
    debian)
        PKGS_BASE="curl wget git ffmpeg ca-certificates python3-pip"
        PKGS_THUMB="webp-pixbuf-loader ffmpegthumbnailer gnome-sushi"
        PKGS_PLAYERS="mpv vlc"
        ;;
    fedora)
        PKGS_BASE="curl wget git ffmpeg ca-certificates python3-pip"
        PKGS_THUMB="webp-pixbuf-loader ffmpegthumbnailer sushi"
        PKGS_PLAYERS="mpv vlc"
        ;;
    arch)
        # python-pip, not python3-pip: on Arch, python IS Python 3 and the
        # package names carry no version prefix.
        PKGS_BASE="curl wget git ffmpeg ca-certificates python-pip"
        PKGS_THUMB="webp-pixbuf-loader ffmpegthumbnailer sushi"
        PKGS_PLAYERS="mpv vlc"
        ;;
    suse)
        PKGS_BASE="curl wget git ffmpeg ca-certificates python3-pip"
        PKGS_THUMB="webp-pixbuf-loader ffmpegthumbnailer gnome-sushi"
        PKGS_PLAYERS="mpv vlc"
        ;;
    *)
        PKGS_BASE=""; PKGS_THUMB=""; PKGS_PLAYERS=""
        ;;
esac

DATA_ROOT="${YTDLP_INSTALL_ROOT:-${HOME}/yt-dlp}"
LOCAL_BIN="${HOME}/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Raw-file base rather than a clone URL -- see the long comment at Step 7
# for why this fetches individual files instead of cloning the repo.
# "main" is this repo's default branch; if that ever changes, change it here.
RAW_BASE="https://raw.githubusercontent.com/AviMehandru/yt-dlp-download-automator/main"
DOWNLOAD_DIR="${SCRIPT_DIR}/YT-DLP Installation Files"
# The exact set of files this installer needs. Everything else in the repo
# (docs, LICENSE, SECURITY.md, CREDITS.md) is not needed to run anything, so
# it is never fetched. Keep this list in sync with the copy_file calls in
# Step 11 -- a file downloaded but never copied is dead weight, and a file
# copied but never downloaded only works when it happens to sit next to
# setup.sh already.
#
# These names lost their "linux-" prefix when the Linux and Windows script
# copies were merged into one cross-platform set: there is now a single
# run_ytdlp.ps1 and a single postprocess.ps1 that both platforms (and
# Windows) install unmodified.
PROJECT_FILES=(
    "run_ytdlp.ps1"
    "postprocess.ps1"
    "yt-dlp.conf"
    "ytdl"
    "archive-viewer.py"
)
WARNINGS=()

# --- Console log capture ---
# Saves a full, byte-for-byte copy of everything this script prints (both
# the script's own echo/log/warn lines AND the raw output of every
# external command it runs -- apt/brew, curl, yt-dlp -U, the deno
# installer, git, etc) to a timestamped file, while still showing it all
# on the terminal live as normal. Uses the same "Archive Logs/Logs"
# directory the rest of the pipeline already logs into (download.log,
# video_postprocessing.log), for one consistent place to look, rather
# than inventing a separate logs location just for setup runs.
#
# This log dir is created here, standalone, rather than waiting for Step
# 10 (which creates the full folder tree) -- setup needs somewhere to log
# its own very first commands (apt update etc.), well before Step 10 runs.
# Step 10's later `mkdir -p` of the same path is a harmless no-op once this
# has already created it.
#
# exec > >(tee -a "$LOG_FILE") 2>&1 replaces the script's own stdout/stderr
# for the rest of the run: every command's output flows through `tee`,
# which duplicates it to both the terminal (so you still watch it live,
# including e.g. apt's own progress bars) and appends it to $LOG_FILE.
# This needs bash's process-substitution support (>(...)), which is why
# the shebang above is bash specifically, not /bin/sh. macOS ships bash 3.2
# as /bin/bash, which supports process substitution and everything else
# used here -- the shebang is /usr/bin/env bash so a newer Homebrew bash is
# preferred when present, but 3.2 is sufficient.
LOG_DIR="${DATA_ROOT}/Archive Logs/Logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging full console output to: ${LOG_FILE}"
echo "Detected platform: ${PLATFORM}"

# --- Overall progress bar ---
# This is a step-counter bar, not a byte/percent-of-work bar: it advances
# once per top-level step (12 total, matching the "Step N/12" labels this
# script prints), regardless of how long that step's actual work takes.
# That's a deliberate simplification -- the individual installers/downloads
# below (apt/brew, curl, yt-dlp -U, deno's installer) already print their
# own real progress bars for their own work, so this one only needs to
# answer "how far through the whole script am I", not duplicate byte-level
# progress that's already visible.
# TOTAL_STEPS must match the number of log() calls below (currently 12) --
# if a step is ever added or removed, update this constant in the same
# commit, or the bar will finish early/late relative to the actual work.
# Note the step COUNT is the same on both platforms even though two of the
# steps (VMware, desktop previews) do different or no work on macOS -- they
# still run and still report, so the numbering matches between a Linux log
# and a macOS log.
TOTAL_STEPS=12
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

# log() does double duty: it's the per-step header, but it also owns the
# step counter -- every call advances the overall bar by exactly one step.
# This keeps the bar's step count and the actual "Step N/12" numbering
# impossible to drift apart from each other, since there's only one place
# (this function) that increments anything, instead of hand-typing
# "Step 3/12" etc. at each call site where it could get out of sync if
# steps are ever reordered/added later.
log()  {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    draw_progress_bar
    echo -e ">>> Step ${CURRENT_STEP}/${TOTAL_STEPS}: $*"
}
warn() { echo "WARNING: $*"; WARNINGS+=("$*"); }

# --- Package manager abstraction ---
# Three verbs, one per family. Defined after warn() because they call it;
# bash resolves function names at call time, so the ordering only matters for
# invocation, not definition.
#
# Two per-family quirks are load-bearing and easy to get wrong:
#
#   Arch: `pacman -Sy` WITHOUT `-u` is a partial upgrade, which is the classic
#   way to break an Arch install -- you refresh the package index but leave
#   the system on older libraries, and the next package you install links
#   against something that is no longer there. So the Arch path deliberately
#   has no separate "refresh" step; pkg_update does the full `-Syu`, and
#   pkg_refresh_only is a no-op that says so.
#
#   Fedora: `dnf check-update` exits 100 when updates ARE available. That is
#   documented behaviour, not an error, so it must not be treated as failure.
pkg_refresh_only() {
    case "$PKG" in
        apt)    sudo apt update ;;
        dnf)    sudo dnf check-update || [ $? -eq 100 ] ;;
        zypper) sudo zypper --non-interactive refresh ;;
        pacman) echo "Skipping index-only refresh on Arch -- see pkg_update (a bare 'pacman -Sy' risks a partial upgrade)." ;;
        *)      return 1 ;;
    esac
}
pkg_update() {
    case "$PKG" in
        apt)    sudo apt upgrade -y ;;
        dnf)    sudo dnf upgrade -y ;;
        zypper) sudo zypper --non-interactive update ;;
        pacman) sudo pacman -Syu --noconfirm ;;
        *)      return 1 ;;
    esac
}
# Takes a space-separated package list; unquoted on purpose so it word-splits
# into separate arguments.
pkg_install() {
    local pkgs="$*"
    [ -z "$pkgs" ] && return 0
    case "$PKG" in
        apt)    sudo apt install -y $pkgs ;;
        dnf)    sudo dnf install -y $pkgs ;;
        zypper) sudo zypper --non-interactive install $pkgs ;;
        # --needed skips anything already present rather than reinstalling it,
        # which is what makes re-running this script cheap on Arch.
        pacman) sudo pacman -S --noconfirm --needed $pkgs ;;
        *)      return 1 ;;
    esac
}

mkdir -p "$LOCAL_BIN"

# --- Step 1: update the system ---
log "Updating system packages"
if [ "$PLATFORM" = "macos" ]; then
    # PLATFORM: Homebrew instead of apt. Deliberately NOT auto-installing
    # Homebrew if it's missing -- its installer needs sudo, modifies
    # system-owned directories, and prompts for confirmation; running that
    # silently from inside another script is exactly the kind of unattended
    # privileged side effect this project avoids elsewhere (see the apt
    # comment in run_ytdlp.ps1's dependency check). A clear warning with
    # the command to run is more useful than a surprising install.
    if ! command -v brew >/dev/null 2>&1; then
        warn "Homebrew is not installed, so ffmpeg/pwsh/players below cannot be installed automatically. Install it first with: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" -- then re-run this script. The folder-structure and file-placement steps further down will still run without it."
    else
        brew update || warn "brew update failed -- package installs below may use a stale index."
        brew upgrade || warn "brew upgrade failed -- continuing anyway."
    fi
elif [ "$DISTRO_FAMILY" = "unknown" ]; then
    warn "Could not identify this distribution from /etc/os-release (ID/ID_LIKE did not match debian, fedora, arch or suse), so no packages can be installed automatically. Install the dependencies by hand -- ffmpeg, git, curl, wget, python3-pip -- and re-run this script: the folder-structure, file-placement, launcher and PATH steps below are package-manager-agnostic and will still do their work."
else
    echo "Detected ${DISTRO_PRETTY:-$DISTRO_FAMILY} (family: $DISTRO_FAMILY, package manager: $PKG)."
    # Arch has no index-only refresh here on purpose -- see pkg_refresh_only.
    if ! pkg_refresh_only; then
        warn "Package index refresh failed -- installs below may use a stale index."
    fi
    pkg_update || warn "System upgrade failed -- continuing anyway."
fi

# --- Step 2: base dependencies ---
log "Installing ffmpeg, git, and base tools"
if [ "$PLATFORM" = "macos" ]; then
    # PLATFORM: macOS already ships curl and (via the Xcode Command Line
    # Tools) git and python3, so the list is much shorter than Ubuntu's --
    # only ffmpeg and wget genuinely need installing. git is still listed
    # so a Mac without the CLT installed gets a working one.
    if command -v brew >/dev/null 2>&1; then
        if ! brew install ffmpeg git wget; then
            warn "Base package install failed. Retry with: brew install ffmpeg git wget"
        fi
    else
        warn "Skipped base package install -- Homebrew is not available (see Step 1)."
    fi
    # ffprobe ships inside the same ffmpeg formula on macOS, same as the
    # Ubuntu package, so there's nothing extra to install for
    # postprocess.ps1's attachment-count probe.
elif [ "$DISTRO_FAMILY" = "unknown" ]; then
    warn "Skipped base package install -- unrecognised distribution (see Step 1). Install ffmpeg, git, curl, wget and pip by hand."
else
    if ! pkg_install "$PKGS_BASE"; then
        warn "Base package install failed. yt-dlp/ffmpeg/git may not work until you install these by hand: $PKGS_BASE"
    fi

    # ffmpeg is the one package that is genuinely awkward outside Debian.
    # Fedora and openSUSE both ship it only through a third-party repository
    # (RPM Fusion and Packman respectively) for patent reasons; the versions
    # in their own repos are either absent or codec-stripped.
    #
    # Those repositories are deliberately NOT enabled automatically. Adding a
    # third-party package source is a lasting, system-wide change that affects
    # every future update on the machine, which is not a reasonable thing for
    # a video-archiver installer to decide unattended -- the same reasoning
    # that keeps this script from installing Homebrew on macOS. The warning
    # names the exact command instead.
    if ! command -v ffmpeg >/dev/null 2>&1; then
        case "$DISTRO_FAMILY" in
            fedora)
                warn "ffmpeg is not available from Fedora's own repositories (patent-encumbered codecs). Enable RPM Fusion, then re-run this script: sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm && sudo dnf install -y ffmpeg"
                ;;
            suse)
                warn "ffmpeg is not available from openSUSE's own repositories (patent-encumbered codecs). Add the Packman repository, then re-run this script. See https://en.opensuse.org/Additional_package_repositories#Packman -- afterwards: sudo zypper install ffmpeg"
                ;;
            *)
                warn "ffmpeg was not installed and is required. Install it however this distribution provides it, then re-run this script."
                ;;
        esac
    fi
fi

# --- Step 3: yt-dlp (standalone binary, so -U self-update actually works) ---
# Installed to $HOME/.local/bin, NOT /usr/local/bin. A real run showed
# self-update failing even after chown'ing just the binary file -- yt-dlp's
# updater needs to write into the CONTAINING directory too (it writes a
# temp file and renames over the old one), and /usr/local/bin is root-owned
# regardless of who owns the file inside it. Installing into a directory
# the user already owns outright sidesteps the whole problem rather than
# patching around it. Same reasoning applies on macOS, where
# /usr/local/bin (Intel) or /opt/homebrew/bin (Apple silicon) is owned by
# Homebrew rather than by the pipeline.
log "Installing yt-dlp"
# PLATFORM: different release asset per OS. The plain "yt-dlp" asset is the
# Linux binary; macOS needs "yt-dlp_macos", which is a universal binary
# covering both Apple silicon and Intel, so no arch branch is needed beyond
# this one filename.
if [ "$PLATFORM" = "macos" ]; then
    YTDLP_ASSET="yt-dlp_macos"
else
    YTDLP_ASSET="yt-dlp"
fi
if [ -x "${LOCAL_BIN}/yt-dlp" ]; then
    echo "yt-dlp already present at ${LOCAL_BIN}/yt-dlp ($(${LOCAL_BIN}/yt-dlp --version 2>/dev/null)) -- skipping install, run 'yt-dlp -U' to update."
else
    if curl -L "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${YTDLP_ASSET}" -o "${LOCAL_BIN}/yt-dlp"; then
        chmod a+rx "${LOCAL_BIN}/yt-dlp"
        echo "Installed yt-dlp to ${LOCAL_BIN}/yt-dlp (from asset ${YTDLP_ASSET})."
        if [ "$PLATFORM" = "macos" ]; then
            # PLATFORM: Gatekeeper quarantines anything downloaded with a
            # com.apple.quarantine attribute, and a quarantined binary run
            # from the terminal fails with a "cannot be opened because the
            # developer cannot be verified" dialog rather than a normal
            # error -- which looks like a broken download rather than a
            # security prompt. Stripping the attribute on a binary we just
            # fetched ourselves over HTTPS from a known URL is the same
            # trust decision as choosing to install it at all.
            xattr -d com.apple.quarantine "${LOCAL_BIN}/yt-dlp" 2>/dev/null || true
        fi
    else
        warn "yt-dlp download failed. Retry manually: curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/${YTDLP_ASSET} -o ${LOCAL_BIN}/yt-dlp && chmod a+rx ${LOCAL_BIN}/yt-dlp"
    fi
fi

# --- Step 4: PowerShell 7 ---
log "Installing PowerShell 7 (pwsh)"
if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh already present ($(pwsh --version)) -- skipping."
elif [ "$PLATFORM" = "macos" ]; then
    # PLATFORM: pwsh ships as a Homebrew CASK on macOS (it's a signed pkg
    # from Microsoft), not a formula -- "brew install powershell" without
    # --cask fails with "No available formula".
    if command -v brew >/dev/null 2>&1; then
        if ! brew install --cask powershell; then
            warn "pwsh install failed via Homebrew. Install manually before using the pipeline -- nothing else here can run without it. Retry with: brew install --cask powershell"
        fi
    else
        warn "Cannot install pwsh -- Homebrew is not available (see Step 1). Nothing in this pipeline can run without pwsh."
    fi
else
    # PowerShell is installed from Microsoft's own self-contained tarball into
    # $HOME/.local, NOT from any distribution's package manager. This is the
    # single change that made multi-distro support tractable, so it is worth
    # explaining why rather than just how.
    #
    # Microsoft publishes repositories for only a handful of distributions,
    # and the coverage is uneven in ways that bite exactly where you would not
    # want them to: there was no apt package for Ubuntu 26.04 for a long while
    # (which is why this step used to fall back to snap), Arch has only an AUR
    # package -- which cannot be installed non-interactively without dragging
    # in an AUR helper -- and openSUSE's situation shifts between releases.
    # Supporting four families through their package managers would mean four
    # fragile code paths, each capable of breaking independently whenever
    # Microsoft changed its publishing.
    #
    # The tarball is one code path for every glibc distribution, needs no
    # root, adds no repository to the system, and is exactly how this script
    # already installs yt-dlp (Step 3) and Deno (Step 6) -- both of which live
    # in $HOME/.local/bin for the same "no root-owned location" reasoning.
    # Making pwsh the third is consistency, not a new idea.
    #
    # Trade-off, stated plainly: a package-manager install would be updated by
    # the system's own upgrade cycle, and this one will not. That is why the
    # dependency check in run_ytdlp.ps1 gained a version comparison for this
    # case -- see the tarball branch there.
    PWSH_DIR="${HOME}/.local/share/powershell"
    # Pinned fallback, used only if the "latest" lookup below cannot reach
    # GitHub. Bump it when convenient; it is a floor, not a ceiling.
    PWSH_PINNED="7.4.6"

    PWSH_ARCH=""
    case "$(uname -m)" in
        x86_64|amd64)   PWSH_ARCH="x64" ;;
        aarch64|arm64)  PWSH_ARCH="arm64" ;;
        armv7l|armv7)   PWSH_ARCH="arm32" ;;
    esac

    if [ -z "$PWSH_ARCH" ]; then
        warn "Unsupported CPU architecture '$(uname -m)' -- Microsoft does not publish a PowerShell build for it, so pwsh cannot be installed automatically. Nothing in this pipeline can run without pwsh."
    else
        # Resolve the newest release by following GitHub's /releases/latest
        # redirect and reading the tag out of the final URL. Deliberately not
        # the GitHub API: the API is rate-limited per IP for unauthenticated
        # callers, which fails unpredictably on shared or NATed networks,
        # whereas the redirect is a plain HTTP 302 with no quota. Falls back
        # to the pinned version if anything about that fails.
        PWSH_VER="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
                      https://github.com/PowerShell/PowerShell/releases/latest 2>/dev/null \
                    | sed -n 's#.*/tag/v##p')"
        case "$PWSH_VER" in
            [0-9]*) : ;;                       # looks like a version, keep it
            *) PWSH_VER="$PWSH_PINNED"
               echo "Could not determine the latest PowerShell release -- falling back to the pinned version ${PWSH_PINNED}." ;;
        esac

        PWSH_TGZ="powershell-${PWSH_VER}-linux-${PWSH_ARCH}.tar.gz"
        PWSH_URL="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/${PWSH_TGZ}"
        echo "Installing PowerShell ${PWSH_VER} (linux-${PWSH_ARCH}) to ${PWSH_DIR}"

        if curl -fsSL --retry 3 --retry-delay 2 -o "/tmp/${PWSH_TGZ}" "$PWSH_URL"; then
            # Extracted into a clean directory: an in-place overwrite of an
            # existing install can leave stale files from a previous version
            # behind, and pwsh loads assemblies from this tree by name.
            rm -rf "$PWSH_DIR"
            mkdir -p "$PWSH_DIR"
            if tar -xzf "/tmp/${PWSH_TGZ}" -C "$PWSH_DIR"; then
                chmod +x "${PWSH_DIR}/pwsh"
                ln -sf "${PWSH_DIR}/pwsh" "${LOCAL_BIN}/pwsh"
                rm -f "/tmp/${PWSH_TGZ}"
                if "${LOCAL_BIN}/pwsh" --version >/dev/null 2>&1; then
                    echo "Installed pwsh ($("${LOCAL_BIN}/pwsh" --version)) -> ${LOCAL_BIN}/pwsh"
                else
                    # The usual cause is a missing native dependency -- the
                    # tarball is self-contained for .NET but still links
                    # against system libicu and libssl, which a minimal or
                    # container image may not carry.
                    warn "pwsh was extracted but will not run. This is usually a missing native library (libicu and libssl are the common ones). Install your distribution's ICU and OpenSSL packages and try '${LOCAL_BIN}/pwsh --version' again."
                fi
            else
                warn "Could not extract ${PWSH_TGZ}. Nothing in this pipeline can run without pwsh."
                rm -f "/tmp/${PWSH_TGZ}"
            fi
        else
            warn "PowerShell download failed from ${PWSH_URL}. Nothing in this pipeline can run without pwsh. Retry that URL by hand, extract it to ${PWSH_DIR}, and symlink ${PWSH_DIR}/pwsh into ${LOCAL_BIN}."
        fi
    fi
fi

# --- Step 5: curl_cffi (fixes the "no impersonate target" warning) ---
log "Installing curl_cffi (browser-impersonation support for yt-dlp)"
# --break-system-packages is what lets pip write into an externally-managed
# environment (PEP 668), which both modern Ubuntu and Homebrew's python
# are. Falling back to --user covers an older pip that doesn't recognize
# the flag at all, where --user achieves the same "don't touch the system
# site-packages" outcome by a different route.
if ! python3 -m pip install -U "curl_cffi>=0.10" --break-system-packages 2>/dev/null; then
    if ! python3 -m pip install -U --user "curl_cffi>=0.10"; then
        warn "curl_cffi install failed. yt-dlp will keep warning about missing impersonation targets until you retry: python3 -m pip install -U \"curl_cffi>=0.10\" --break-system-packages"
    fi
fi

# --- Step 6: Deno (JS runtime -- YouTube now requires solving a JS ---
# challenge for cipher decryption). Installed to $HOME/.local/bin for the
# same reason as yt-dlp above -- no root-owned install location, no
# possible ownership/permission mismatch down the line.
log "Installing Deno (JavaScript runtime required for current YouTube extraction)"
if [ -x "${LOCAL_BIN}/deno" ]; then
    echo "deno already present at ${LOCAL_BIN}/deno ($(${LOCAL_BIN}/deno --version | head -n1)) -- skipping."
else
    # The same official installer script works on both Linux and macOS and
    # picks the right build for the running architecture itself, so there
    # is no platform branch needed here at all.
    if curl -fsSL https://deno.land/install.sh | sh -s -- -y >/tmp/deno-install.log 2>&1; then
        DENO_BIN="$(find "${HOME}/.deno/bin" -name deno 2>/dev/null | head -n1)"
        if [ -n "$DENO_BIN" ]; then
            cp "$DENO_BIN" "${LOCAL_BIN}/deno"
            chmod a+rx "${LOCAL_BIN}/deno"
            [ "$PLATFORM" = "macos" ] && xattr -d com.apple.quarantine "${LOCAL_BIN}/deno" 2>/dev/null || true
            echo "Installed deno to ${LOCAL_BIN}/deno ($(${LOCAL_BIN}/deno --version | head -n1))."
        else
            warn "Deno installer ran but the binary wasn't found under ${HOME}/.deno/bin -- see /tmp/deno-install.log."
        fi
    else
        warn "Deno install failed -- see /tmp/deno-install.log. YouTube downloads may hit errors or miss formats until this is resolved. Retry manually: curl -fsSL https://deno.land/install.sh | sh"
    fi
fi
# run_ytdlp.ps1 no longer requires deno at one exact hardcoded path: it
# probes $HOME/.local/bin/deno, then $HOME/.deno/bin/deno, then Homebrew's
# prefixes, then PATH, and logs a clear warning if none of them hit. So an
# install somewhere else still works -- it just isn't the tidiest outcome.

# --- Step 7: fetch the project files ---
# Convenience step: pulls the actual project files down automatically so
# Step 11 below can find them without you having to place them by hand.
#
# WHY THIS FETCHES INDIVIDUAL FILES INSTEAD OF CLONING (changed from an
# earlier `git clone` of the whole repo): the honest answer is NOT disk
# space. The clone was already scratch -- deleted a few steps below once
# the files were copied into place -- so it cost roughly 400 KB
# transiently against an archive measured in gigabytes, which is nothing.
# The real reasons are that this is the only thing in the entire project
# that ever needed git (nothing in ytdl, run_ytdlp.ps1 or postprocess.ps1
# touches it), that it no longer matters whether the repo is public,
# private, or reachable over SSH vs HTTPS, and that a plain HTTPS GET of
# five known filenames has far fewer ways to fail on a fresh machine than
# a clone does. git is still installed in Step 2 and still reported in the
# Step 12 verification, because you will want it on this machine to edit
# the project -- the pipeline just no longer *depends* on it.
#
# Files already sitting next to setup.sh are used as-is and never
# downloaded over. That is deliberate and load-bearing for the
# edit-then-reinstall loop: if you cloned the repo and are running
# ./setup.sh from inside it, your local edits win, and nothing is fetched
# from GitHub at all.
log "Downloading project files"
mkdir -p "$DOWNLOAD_DIR"

# curl first (already required by the Deno install in Step 6, and present
# by default on macOS), wget as the fallback.
download_to() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -t 3 -O "$dest" "$url" && return 0
    fi
    return 1
}

for project_file in "${PROJECT_FILES[@]}"; do
    if [ -f "${SCRIPT_DIR}/${project_file}" ]; then
        echo "Using local '${project_file}' from ${SCRIPT_DIR} -- not downloading."
        continue
    fi
    part="${DOWNLOAD_DIR}/${project_file}.part"
    if download_to "${RAW_BASE}/${project_file}" "$part"; then
        # curl -f / wget catch an HTTP *error status*, but not a proxy or
        # captive portal that answers 200 with its own HTML page. None of
        # these files is HTML, so a first line that looks like markup means
        # something intercepted the request and the "download" is garbage.
        if [ ! -s "$part" ]; then
            rm -f "$part"
            warn "Downloaded '${project_file}' was empty -- treating as a failed download. Fetch it manually from ${RAW_BASE}/${project_file} into ${DOWNLOAD_DIR}"
        elif head -n 1 "$part" | grep -qiE '^\s*<(!doctype|html)'; then
            rm -f "$part"
            warn "'${project_file}' came back as an HTML page rather than the file itself -- something (a proxy, captive portal, or DNS interception) answered instead of GitHub. Check this machine's network, then re-run."
        else
            mv "$part" "${DOWNLOAD_DIR}/${project_file}"
            echo "Downloaded ${project_file}"
        fi
    else
        rm -f "$part"
        warn "Could not download '${project_file}' from ${RAW_BASE}/${project_file}. Check network/DNS, or place the file next to setup.sh (${SCRIPT_DIR}) and re-run."
    fi
done

# --- VMware guest detection (used by Step 8 below) ---
# Linux-only: this whole concept is about a Linux VM mounting a shared
# folder from its host, which has no macOS counterpart worth automating
# (a Mac running this is the host, not the guest).
IS_VMWARE=0
if [ "$PLATFORM" = "linux" ]; then
    # systemd-detect-virt is the primary check -- reliable on any
    # systemd-based Ubuntu install, which this always is. A DMI fallback is
    # included as a second, independent signal in case systemd-detect-virt
    # is ever inconclusive (e.g. it can report "none" from inside some
    # nested-virt or minimal-container setups even under VMware) -- VMware's
    # virtual hardware always identifies itself in the DMI product_name
    # table regardless, so this catches that case without depending on
    # systemd's own detection at all.
    if systemd-detect-virt 2>/dev/null | grep -qi vmware; then
        IS_VMWARE=1
    elif [ -r /sys/class/dmi/id/product_name ] && grep -qi vmware /sys/class/dmi/id/product_name 2>/dev/null; then
        IS_VMWARE=1
    fi
fi

# --- Step 8: VMware shared folder support (safe no-op outside VMware) ---
# Deliberately does NOT reboot. A reboot would kill this script mid-run
# (a shell script isn't a service -- it doesn't resume itself afterward),
# and it isn't actually necessary: restarting the vmtoolsd service and
# mounting directly gets the shared folder working immediately.
log "Setting up VMware shared folder (open-vm-tools)"
if [ "$PLATFORM" = "macos" ]; then
    echo "Not applicable on macOS (this step configures a Linux VM guest's access to its host's shared folders) -- skipping."
elif [ "$IS_VMWARE" -eq 1 ]; then
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
    echo "Not detected as a VMware guest (systemd-detect-virt and DMI both came back negative) -- skipping shared folder setup."
fi

# --- Desktop-environment detection (used by Step 9 below) ---
# Linux-only concept. On macOS there is always a desktop, and the file
# manager (Finder) previews everything this pipeline produces natively --
# see Step 9.
HAS_DESKTOP=0
if [ "$PLATFORM" = "macos" ]; then
    HAS_DESKTOP=1
else
    # Checked by looking for an installed file manager / desktop
    # metapackage rather than reading $XDG_CURRENT_DESKTOP or $DISPLAY:
    # those describe the session this script happens to be RUNNING in,
    # which is wrong twice over -- setup run over SSH into a VM that does
    # have a desktop would look headless, and nothing here needs a GUI at
    # install time anyway, only at the point someone later opens the file
    # manager. What actually matters is whether a desktop is INSTALLED,
    # which is what this tests. Skipping on a genuinely headless box
    # matters because the packages below pull in a large GUI dependency
    # tree that would be dead weight on a server install.
    for gui_bin in nautilus nemo thunar dolphin pcmanfm; do
        if command -v "$gui_bin" >/dev/null 2>&1; then
            HAS_DESKTOP=1
            break
        fi
    done
    # Second signal: a desktop session directory exists. Replaces the previous
    # `dpkg -s ubuntu-desktop` metapackage check, which could only ever answer
    # for Debian-family systems -- Fedora, Arch and openSUSE have no such
    # metapackage names, so on those it silently contributed nothing.
    # /usr/share/xsessions (X11) and /usr/share/wayland-sessions are written
    # by every desktop environment's own packaging on every distribution, so
    # this is both more portable AND more accurate than naming metapackages.
    if [ "$HAS_DESKTOP" -eq 0 ]; then
        for session_dir in /usr/share/xsessions /usr/share/wayland-sessions; do
            if [ -d "$session_dir" ] && [ -n "$(ls -A "$session_dir" 2>/dev/null)" ]; then
                HAS_DESKTOP=1
                break
            fi
        done
    fi
fi

# --- Step 9: viewing thumbnails and subtitles in the desktop ---
# Nothing in the pipeline itself needs any of this -- it downloads and
# post-processes identically without it. This is purely so the archive is
# BROWSABLE from the desktop: thumbnail images that preview in the file
# manager instead of showing a generic icon, and a player that actually
# renders the subtitle tracks next to each video.
log "Installing desktop preview support (thumbnails and subtitles)"
if [ "$PLATFORM" = "macos" ]; then
    # PLATFORM: almost all of the Linux work here is unnecessary on macOS.
    # Finder and Quick Look already render .webp images (natively since
    # macOS 11), generate poster frames for .mkv, and preview .vtt subtitle
    # files as plain text -- no thumbnailer packages, no size-limit setting
    # to raise. The only genuinely useful part is a player that renders the
    # subtitle tracks, since QuickTime Player will not open .mkv at all.
    if command -v brew >/dev/null 2>&1; then
        if ! brew install --cask iina vlc; then
            warn "Video player install failed -- QuickTime Player cannot open .mkv, so you'll have no way to view these videos or their subtitles until this is resolved. Retry with: brew install --cask iina vlc"
        fi
    else
        warn "Skipped video player install -- Homebrew is not available (see Step 1). Note QuickTime Player cannot open .mkv files at all; install IINA or VLC to watch anything this pipeline produces."
    fi
    echo "Finder/Quick Look already preview .webp thumbnails, .mkv poster frames and .vtt subtitles natively -- no thumbnailer packages needed on macOS."
elif [ "$HAS_DESKTOP" -eq 0 ]; then
    echo "No desktop environment detected (no file manager or desktop metapackage installed) -- skipping. The pipeline itself is unaffected; re-run this script after installing a desktop if you later want in-VM previews."
else
    # Split into two independent apt calls rather than one combined package
    # list, so a failure in one group (e.g. a player package temporarily
    # unavailable) doesn't take the other group down with it -- same
    # keep-going principle as the rest of this script.
    #
    # Thumbnailers.
    #   webp-pixbuf-loader -- yt-dlp saves the ORIGINAL thumbnail in
    #     whatever format YouTube served, which for YouTube is almost
    #     always .webp. GTK/Nautilus cannot render webp at all without
    #     this loader, so Images/Thumbnail.webp shows a generic icon and
    #     won't open in the image viewer either. (postprocess.ps1 also
    #     writes a Thumbnail.png alongside it, which displays fine
    #     regardless -- this is what makes the original viewable too.)
    #   ffmpegthumbnailer -- installs a .thumbnailer entry that lets the
    #     file manager generate poster frames for the .mkv files
    #     themselves, so Final Video.mkv previews as its own first frame.
    #   gnome-sushi -- spacebar preview in Nautilus: works on the images,
    #     on the videos, and on the .vtt subtitle files as plain text,
    #     without opening a separate application for each.
    if ! pkg_install "$PKGS_THUMB"; then
        warn "Thumbnailer install failed. Thumbnails (especially the original .webp) may show as generic icons in the file manager. Install these by hand to fix it: $PKGS_THUMB"
    fi

    # Players. Both handle the subtitles this pipeline produces two
    # different ways: the tracks muxed into the .mkv by --embed-subs, and
    # the sidecar .vtt files under each video's Subtitles/ folder. mpv is
    # the lightweight one; vlc is included as well because its subtitle
    # track menu is far more discoverable, and it auto-loads a sidecar
    # subtitle file sitting next to the video without being asked.
    if ! pkg_install "$PKGS_PLAYERS"; then
        warn "Video player install failed -- you'll have no way to view subtitles rendered over the video on this machine. Install these by hand to fix it: $PKGS_PLAYERS"
    fi

    # Nautilus refuses to thumbnail files above a size cap, which defaults
    # to 10 MB -- far below any real video here, so without raising it the
    # ffmpegthumbnailer install above would appear to do nothing at all for
    # the .mkv files (the thumbnailer is installed and working; it just
    # never gets invoked). Nautilus's own schema documents this value as
    # megabytes, so 4096 = 4 GB, comfortably above a long 4K download.
    #
    # Guarded on the key actually existing rather than set blindly: this
    # key has come and gone across GNOME versions, and `gsettings set` on
    # a key the installed schema doesn't have is a hard error, not a
    # no-op. Also skipped when there's no session bus to write to (a
    # sudo/SSH context), where gsettings would fail for an unrelated
    # reason.
    if ! command -v gsettings >/dev/null 2>&1; then
        echo "gsettings not available -- skipped raising the Nautilus thumbnail size limit."
    elif ! gsettings list-keys org.gnome.nautilus.preferences 2>/dev/null | grep -qx 'thumbnail-limit'; then
        echo "No 'thumbnail-limit' key in this GNOME version's Nautilus schema -- nothing to raise, skipping (video thumbnails should work regardless)."
    elif gsettings set org.gnome.nautilus.preferences thumbnail-limit 4096 2>/dev/null; then
        echo "Raised the Nautilus thumbnail size limit to 4096 MB (default is 10 MB, which is below every video this pipeline produces)."
    else
        warn "Could not raise the Nautilus thumbnail size limit. Video files larger than the current limit will show a generic icon instead of a poster frame. Set it yourself from a desktop terminal with: gsettings set org.gnome.nautilus.preferences thumbnail-limit 4096"
    fi

    echo "Note: the file manager caches thumbnails, so folders you already browsed before this step may keep showing generic icons. Log out and back in (or run 'rm -rf ~/.cache/thumbnails' and reopen the file manager) to force them to regenerate."
fi

# --- Step 10: folder structure ---
log "Creating folder structure under ${DATA_ROOT}"
mkdir -p "${DATA_ROOT}/scripts"
mkdir -p "${DATA_ROOT}/configs"
mkdir -p "${DATA_ROOT}/Archive Logs/Archive History"
mkdir -p "${DATA_ROOT}/Archive Logs/Logs"
mkdir -p "${DATA_ROOT}/Youtube Videos/Complete Archive"
mkdir -p "${DATA_ROOT}/Youtube Videos/_incomplete"
mkdir -p "${DATA_ROOT}/Youtube Videos/Final Video"
echo "Folder structure created."

# --- Step 11: place the pipeline files and the archive viewer ---
# Looks in two places, in order: next to setup.sh itself, then inside the
# download folder Step 7 filled. Each file is resolved and copied
# independently -- a missing one only warns about itself and doesn't block
# the others.
log "Installing pipeline files"
copy_file() {
    local src="$1" dest="$2" label="$3"
    local candidates=(
        "${SCRIPT_DIR}/${src}"
        "${DOWNLOAD_DIR}/${src}"
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
# Snapshot the warning count right before these copies -- compared again
# below, after they've all run, to decide whether it's safe to delete the
# downloaded files (see the cleanup block further down).
WARNINGS_BEFORE_INSTALL="${#WARNINGS[@]}"
# No filename rewriting here anymore. These used to be copied from
# "linux-run_ytdlp.ps1" to "run_ytdlp.ps1" etc, because the repo carried a
# separate prefixed copy per platform; there is now one unprefixed
# cross-platform file, so source and destination names match.
copy_file "run_ytdlp.ps1"     "${DATA_ROOT}/scripts/run_ytdlp.ps1"      "run_ytdlp.ps1"
copy_file "postprocess.ps1"   "${DATA_ROOT}/scripts/postprocess.ps1"    "postprocess.ps1"
copy_file "yt-dlp.conf"       "${DATA_ROOT}/configs/yt-dlp.conf"        "yt-dlp.conf"
copy_file "ytdl"              "${LOCAL_BIN}/ytdl"                       "ytdl"
# The viewer lives with the scripts rather than in ${LOCAL_BIN} because it is
# a program, not a command -- ${LOCAL_BIN}/ytdl-view below is what you type.
copy_file "archive-viewer.py" "${DATA_ROOT}/scripts/archive-viewer.py"  "archive-viewer.py"
if [ -f "${LOCAL_BIN}/ytdl" ]; then
    chmod +x "${LOCAL_BIN}/ytdl"
fi
if [ -f "${DATA_ROOT}/scripts/archive-viewer.py" ]; then
    chmod +x "${DATA_ROOT}/scripts/archive-viewer.py"
fi

# --- ytdl-view launcher ---
# Written here rather than shipped as a repo file. Every other installed
# file is a copy of a repo source, and this one deliberately is not: its
# entire content is a single exec line, so a repo file would exist only to
# be copied and would be one more thing to keep in sync. A custom data root
# is handled at runtime instead:
#     ytdl-view --root /mnt/hgfs/yt-dlp-share/archive
# The heredoc delimiter is quoted so "$@" is written literally and expands
# when the launcher runs, not now -- but ${DATA_ROOT} is substituted in
# beforehand, so an install at a custom YTDLP_INSTALL_ROOT still points at
# the right script.
if [ -f "${DATA_ROOT}/scripts/archive-viewer.py" ]; then
    cat > "${LOCAL_BIN}/ytdl-view" <<YTDL_VIEW_LAUNCHER
#!/usr/bin/env bash
# Generated by setup.sh -- thin launcher for archive-viewer.py.
# All arguments pass straight through: --root, --port, --host,
# --allow-open-local, --rescan, --help, and so on.
exec python3 "${DATA_ROOT}/scripts/archive-viewer.py" "\$@"
YTDL_VIEW_LAUNCHER
    chmod +x "${LOCAL_BIN}/ytdl-view"
    echo "Installed ytdl-view -> ${LOCAL_BIN}/ytdl-view (launches the archive viewer)"
    # The viewer is pure standard library, so there is nothing to install for
    # it -- but it does need python3 to exist. Ubuntu always ships it, and
    # macOS provides it with the Xcode Command Line Tools, so this is a
    # belt-and-braces check rather than an expected failure.
    if ! command -v python3 >/dev/null 2>&1; then
        if [ "$PLATFORM" = "macos" ]; then
            warn "python3 was not found, so 'ytdl-view' will not run. Install it with: xcode-select --install (or: brew install python3)"
        else
            warn "python3 was not found, so 'ytdl-view' will not run. Install it with: sudo apt install -y python3"
        fi
    fi
else
    warn "archive-viewer.py was not installed, so the 'ytdl-view' launcher was skipped."
fi

# PATH wiring. PLATFORM: which startup file to append to depends on the
# login shell, not on the OS as such -- but in practice macOS defaults to
# zsh and Ubuntu to bash, so this checks $SHELL rather than $PLATFORM and
# gets the right answer on a machine where the user changed it.
if ! echo "$PATH" | tr ':' '\n' | grep -q "^${LOCAL_BIN}$"; then
    case "$SHELL" in
        */zsh)  SHELL_RC="${HOME}/.zshrc" ;;
        */bash) SHELL_RC="${HOME}/.bashrc" ;;
        *)
            # Unknown shell: fall back to whichever rc file already exists,
            # preferring the platform default.
            if [ "$PLATFORM" = "macos" ]; then SHELL_RC="${HOME}/.zshrc"; else SHELL_RC="${HOME}/.bashrc"; fi
            ;;
    esac
    echo "export PATH=\"${LOCAL_BIN}:\$PATH\"" >> "$SHELL_RC"
    echo "Added ${LOCAL_BIN} to PATH in ${SHELL_RC} -- run 'source ${SHELL_RC}' or start a new shell before using 'ytdl'."
fi

# --- Clean up the downloaded installation files now that they're copied ---
# ${DOWNLOAD_DIR} ("YT-DLP Installation Files") is scratch: it exists only
# to source the files above. Once those are safely sitting in their real
# destinations (under ${DATA_ROOT} and ${LOCAL_BIN}), there's no reason to
# leave a second copy on disk.
#
# Only deleted if every copy_file call above actually succeeded (checked
# by comparing the warning count before/after that block, rather than
# tracking each call's return value separately -- copy_file already
# reports failures via warn(), so re-using that as the single source of
# truth avoids keeping two parallel "did it work" mechanisms in sync). If
# anything failed to install, the download is deliberately left in place --
# it may be the only remaining copy of a file that never made it to its
# destination, so deleting it here would destroy the one thing you'd need
# to fix the problem by hand.
#
# Note this never deletes anything you placed next to setup.sh yourself:
# ${DOWNLOAD_DIR} is a subfolder Step 7 creates, and Step 7 skips
# downloading anything already present beside setup.sh, so a repo you
# cloned by hand is untouched by this.
if [ -d "$DOWNLOAD_DIR" ]; then
    if [ "${#WARNINGS[@]}" -eq "$WARNINGS_BEFORE_INSTALL" ]; then
        rm -rf "$DOWNLOAD_DIR"
        echo "Removed downloaded installation files at '${DOWNLOAD_DIR}' (already copied into place, no longer needed)."
    else
        echo "Leaving '${DOWNLOAD_DIR}' in place -- at least one file above failed to install from it (see the WARNING(s) further up). Once that's resolved and you've confirmed everything under ${DATA_ROOT}/scripts and ${DATA_ROOT}/configs is correct, it's safe to delete manually."
    fi
fi

# --- Step 12: verify ---
# NOTE: yt-dlp is installed to ${LOCAL_BIN} (not via the package manager),
# same as deno -- so it's checked via its full path below rather than the
# bare "yt-dlp" command. Checking via bare "yt-dlp" here previously
# produced a false "NOT FOUND" on a fresh install: ${LOCAL_BIN} was only
# just added to PATH a few lines up, which (per the ytdl check's own caveat
# below) doesn't take effect until a new shell -- so on a fresh install
# this step would ALWAYS report yt-dlp missing immediately after
# successfully installing it two steps earlier. ffmpeg/pwsh/git are
# unaffected since those are installed onto a location already on PATH.
log "Verifying installation"
echo "platform: ${PLATFORM}$([ "$PLATFORM" = "linux" ] && echo " (${DISTRO_PRETTY:-unknown} -- family ${DISTRO_FAMILY}, package manager ${PKG:-none})")"
echo "yt-dlp:  $(${LOCAL_BIN}/yt-dlp --version 2>/dev/null || echo 'NOT FOUND')"
echo "ffmpeg:  $(ffmpeg -version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "ffprobe: $(ffprobe -version 2>/dev/null | head -n1 || echo 'NOT FOUND (postprocess.ps1 needs this for the info.json re-embed)')"
echo "pwsh:    $(pwsh --version 2>/dev/null || echo 'NOT FOUND')"
echo "deno:    $(${LOCAL_BIN}/deno --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
echo "git:     $(git --version 2>/dev/null || echo 'NOT FOUND')"
# python3 is only needed by the archive viewer -- nothing in the download
# pipeline itself touches it -- so a miss here is not a broken install.
echo "python3: $(python3 --version 2>/dev/null || echo 'NOT FOUND (only the archive viewer needs it)')"
echo "ytdl:    $(command -v ytdl || echo 'NOT FOUND (open a new shell if PATH was just updated)')"
echo "ytdl-view: $(command -v ytdl-view || echo 'NOT FOUND (open a new shell if PATH was just updated)')"
# Compiles the viewer without running it -- catches a truncated or corrupted
# download that copy_file itself has no way to notice.
if [ -f "${DATA_ROOT}/scripts/archive-viewer.py" ] && command -v python3 >/dev/null 2>&1; then
    # PYTHONPYCACHEPREFIX keeps the resulting .pyc out of scripts/ -- this is
    # a check, and it should not leave a __pycache__ folder behind in an
    # install directory that otherwise holds exactly three known files.
    if PYTHONPYCACHEPREFIX=/tmp python3 -m py_compile "${DATA_ROOT}/scripts/archive-viewer.py" 2>/dev/null; then
        echo "viewer:  archive-viewer.py installed and parses cleanly"
    else
        warn "archive-viewer.py is installed but does not compile -- the download may be truncated. Delete ${DATA_ROOT}/scripts/archive-viewer.py and re-run this script."
    fi
fi
# Same idea for the two pwsh scripts: a syntax check that never executes
# them. This did not exist before and is worth having now that one file
# serves three platforms -- a syntax error introduced while editing would
# otherwise only surface at the end of a real download, after the video is
# already on disk and the after_move hook fires.
if command -v pwsh >/dev/null 2>&1; then
    for ps_script in run_ytdlp.ps1 postprocess.ps1; do
        if [ -f "${DATA_ROOT}/scripts/${ps_script}" ]; then
            if pwsh -NoProfile -Command "
                \$errors = \$null
                [System.Management.Automation.Language.Parser]::ParseFile('${DATA_ROOT}/scripts/${ps_script}', [ref]\$null, [ref]\$errors) | Out-Null
                if (\$errors.Count -gt 0) { \$errors | ForEach-Object { Write-Output \$_.Message }; exit 1 }
                exit 0" >/dev/null 2>&1; then
                echo "syntax:  ${ps_script} parses cleanly"
            else
                warn "${ps_script} has a PowerShell syntax error -- it will fail at runtime. Re-download it or check your edits."
            fi
        fi
    done
fi
# Desktop-only, and only meaningful if Step 9 actually ran -- reported as
# "skipped (no desktop)" rather than "NOT FOUND" on a headless install, so
# a deliberate skip doesn't read as a failure in the summary.
if [ "$PLATFORM" = "macos" ]; then
    echo "iina:    $([ -d '/Applications/IINA.app' ] && echo 'installed' || echo 'NOT FOUND')"
    echo "vlc:     $([ -d '/Applications/VLC.app' ] && echo 'installed' || echo 'NOT FOUND')"
    echo "previews: handled natively by Finder/Quick Look on macOS"
elif [ "$HAS_DESKTOP" -eq 1 ]; then
    echo "mpv:     $(mpv --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    echo "vlc:     $(vlc --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    # Checked by looking for the files these packages install rather than by
    # querying a package database. `dpkg -s` only answers on Debian-family
    # systems, and adding rpm/pacman/zypper equivalents would mean three more
    # branches to test what is ultimately one question: is the loader present
    # on disk. The webp pixbuf loader and the .thumbnailer entry land in the
    # same locations on every distribution, so a glob is both shorter and more
    # portable. The glob on the pixbuf path covers the architecture triplet
    # in the directory name, which differs per distro and per arch.
    echo "webp:    $(ls /usr/lib*/gdk-pixbuf-2.0/*/loaders/libpixbufloader-webp.so \
                        /usr/lib/*/gdk-pixbuf-2.0/*/loaders/libpixbufloader-webp.so 2>/dev/null | head -n1 >/dev/null \
                     && echo 'webp-pixbuf-loader installed (.webp thumbnails will render)' || echo 'NOT FOUND')"
    echo "vidthumb: $(ls /usr/share/thumbnailers/ffmpegthumbnailer.thumbnailer 2>/dev/null >/dev/null \
                     && echo 'ffmpegthumbnailer installed (.mkv poster frames will render)' || echo 'NOT FOUND')"
else
    echo "previews: skipped (no desktop environment detected)"
fi

# NOTE: this final summary deliberately does NOT call log() -- log() is
# what advances the step counter, and all 12 real steps are already done
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
echo -e "Then browse what you archived -- video, subtitles, transcript, metadata"
echo -e "and the full comment thread -- with: ytdl-view"
echo -e "  (add --root /path/to/archive if you downloaded to a custom data root,"
echo -e "   and --allow-open-local to let the page hand files to a local player)"
