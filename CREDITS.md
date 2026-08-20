# Credits

This project is an automation/orchestration layer written around the
following third-party tools, libraries, and platforms. None of the
underlying extraction, encoding, or system functionality is original —
credit for all of it belongs to these projects.

## Core pipeline

| Tool | What it's used for | License |
|---|---|---|
| **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** | The downloader itself — extraction, format selection, subtitles, thumbnails, metadata, comments, everything the pipeline orchestrates around. | Unlicense (public domain) |
| **[FFmpeg](https://ffmpeg.org/)** (`ffmpeg` / `ffprobe`) | Merging video/audio, thumbnail conversion, embedding thumbnails/metadata/chapters, the manual `info.json` attachment remux, stream inspection. | LGPL v2.1+ / GPL v2+ (build-dependent) |
| **[PowerShell](https://github.com/PowerShell/PowerShell)** (`pwsh` 7) | Runs the actual orchestration and post-processing logic (`run_ytdlp.ps1`, `postprocess.ps1`). | MIT |

## Extraction reliability

| Tool | What it's used for | License |
|---|---|---|
| **[Deno](https://github.com/denoland/deno)** | JavaScript runtime yt-dlp uses to solve YouTube's cipher-decryption JS challenge. | MIT |
| **[curl_cffi](https://github.com/lexiforest/curl_cffi)** | Python library giving yt-dlp browser TLS/HTTP fingerprint impersonation. | MIT |
| **[curl-impersonate](https://github.com/lexiforest/curl-impersonate)** | The underlying impersonation engine `curl_cffi` is built on. | MIT |
| **[curl](https://curl.se/)** | The HTTP client `curl-impersonate` itself is built on, and used directly for several installer/download steps in `setup.sh`. | curl license (MIT-style) |

## Platform / environment

| Tool | What it's used for | License |
|---|---|---|
| **[Ubuntu](https://ubuntu.com/)** | The target OS for the Linux port. | Mixed (GPL and others, per-package) |
| **[Python 3](https://www.python.org/)** | Runtime for yt-dlp's own zipapp and for `curl_cffi`/`pip`. | PSF License |
| **[Bash](https://www.gnu.org/software/bash/)** | The `ytdl` launcher script and `setup.sh`. | GPL v3+ |
| **[apt](https://wiki.debian.org/Apt) / [dpkg](https://wiki.debian.org/dpkg)** | Package management throughout setup. | GPL v2+ |
| **[snapd](https://snapcraft.io/)** | Fallback install path for `pwsh` while Ubuntu 26.04's `apt` package is pending. | GPL v3 |
| **[Microsoft Package Repository](https://packages.microsoft.com/)** | Distributes the `apt` package for PowerShell. | N/A (distribution service) |

## VM / host integration

| Tool | What it's used for | License |
|---|---|---|
| **[open-vm-tools](https://github.com/vmware/open-vm-tools)** (incl. `vmhgfs-fuse`) | Host↔guest shared folder mount (`/mnt/hgfs`). | GPL v2 / LGPL v2.1 (mixed, per-component) |
| **VMware Workstation Pro** | Host-side hypervisor the shared-folder setup is built around. | Proprietary (Broadcom/VMware) |

## AI assistance

| Contributor | What it helped with | 
|---|---|
| **[Claude](https://claude.com)** (Anthropic) | Architecture, scripting, debugging, and documentation for this pipeline across its Windows and Linux versions — including the orchestration scripts, `yt-dlp.conf` tuning, the setup automation, and this file. |
| **ChatGPT** (OpenAI) | Assisted with earlier scripting and problem-solving on this project. |

---

*If you're publishing this project, it's worth double-checking current
license terms directly from each project's repository before redistributing
— the summary above is accurate as of this writing but licenses do
occasionally change, and some (like FFmpeg's) depend on which codecs/build
flags are enabled.*
