// Where everything lives.
//
// Every path rule in here is a copy of one that already exists somewhere in
// the pipeline, and the copy is deliberate: this process is started by a
// desktop launcher, not by ytdl, so it cannot inherit anything. The rules it
// mirrors, and where the original lives:
//
//   install root      run_ytdlp.ps1 / ytdl.ps1 platform block
//   data root default = install root, per run_ytdlp.ps1's -DataRoot handling
//   archive root      <dataRoot>/Youtube Videos/Complete Archive
//   cache dir         archive-viewer.py's default_cache_dir()
//
// If any of those move, this file moves with them. The one thing that must
// NEVER be relaxed is the last rule below: nothing derived is written inside
// the archive tree, because postprocess.ps1 writes a checksums.sha256 over
// every file in a video folder and a stray file there makes that manifest
// stop verifying.

use std::env;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

pub fn home_dir() -> PathBuf {
    for var in ["HOME", "USERPROFILE"] {
        if let Ok(v) = env::var(var) {
            if !v.trim().is_empty() {
                return PathBuf::from(v);
            }
        }
    }
    PathBuf::from(".")
}

/// Must agree with the platform block at the top of run_ytdlp.ps1 and
/// ytdl.ps1. Windows keeps C:/yt-dlp rather than the user profile because of
/// MAX_PATH -- a per-video path here reaches ~240 characters before the data
/// root is even prefixed.
pub fn install_root() -> PathBuf {
    if let Ok(v) = env::var("YTDLP_INSTALL_ROOT") {
        if !v.trim().is_empty() {
            return PathBuf::from(v);
        }
    }
    if cfg!(windows) {
        PathBuf::from("C:/yt-dlp")
    } else {
        home_dir().join("yt-dlp")
    }
}

pub fn scripts_dir() -> PathBuf {
    install_root().join("scripts")
}

/// Note the plural. The installed config directory is `configs/` while the
/// repo directory is `config/` -- not a typo, the installed name predates the
/// repo restructure and is baked into run_ytdlp.ps1 and postprocess.ps1.
pub fn configs_dir() -> PathBuf {
    install_root().join("configs")
}

fn platform_base(kind: Base) -> PathBuf {
    let home = home_dir();
    if cfg!(target_os = "macos") {
        match kind {
            Base::Cache => home.join("Library").join("Caches"),
            Base::State => home.join("Library").join("Application Support"),
        }
    } else if cfg!(windows) {
        let local = env::var("LOCALAPPDATA")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join("AppData").join("Local"));
        match kind {
            Base::Cache => local.join("Cache"),
            Base::State => local,
        }
    } else {
        match kind {
            Base::Cache => env::var("XDG_CACHE_HOME")
                .ok()
                .filter(|v| !v.trim().is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".cache")),
            Base::State => env::var("XDG_CONFIG_HOME")
                .ok()
                .filter(|v| !v.trim().is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".config")),
        }
    }
}

enum Base {
    Cache,
    State,
}

/// Derived, disposable: the metadata index, split-out comment files and
/// remuxed playback copies. Deleting it costs one re-index and nothing else.
/// Deliberately a DIFFERENT directory from archive-viewer.py's
/// `ytdlp-archive-viewer` cache: the two index formats are not the same, and
/// sharing a directory would mean each tool treating the other's files as
/// corrupt.
pub fn cache_dir() -> PathBuf {
    platform_base(Base::Cache).join("ytdlp-gui")
}

/// Not disposable: settings, the queue, and the run history. Losing this loses
/// real user data, which is why it is not under the cache directory.
pub fn state_dir() -> PathBuf {
    platform_base(Base::State).join("ytdlp-gui")
}

fn looks_like_channel_dir(path: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(path) else {
        return false;
    };
    for entry in entries.flatten().take(60) {
        let p = entry.path();
        if !p.is_dir() {
            continue;
        }
        if p.file_name().map(|n| n == "Channel Info").unwrap_or(false) {
            return true;
        }
        if p.join("Final files").is_dir() || p.join("Video metadata").is_dir() {
            return true;
        }
    }
    false
}

/// Accept anything reasonable the user might point at -- a data root, the
/// `Youtube Videos` folder, `Complete Archive` itself, or a reorganised tree
/// -- and find the real `Complete Archive` directory. Same acceptance set as
/// archive-viewer.py's --root, so a path that works for one works for both.
pub fn resolve_archive_root(candidate: &Path) -> Option<PathBuf> {
    let p = expand_tilde(candidate);
    if !p.exists() {
        return None;
    }
    let p = p.canonicalize().unwrap_or(p);

    let tries = [
        p.join("Youtube Videos").join("Complete Archive"),
        p.join("Complete Archive"),
        p.clone(),
    ];
    for t in tries {
        if t.is_dir() && t.file_name().map(|n| n == "Complete Archive").unwrap_or(false) {
            return Some(t);
        }
    }
    // Pointed at a channel folder, or somewhere below the root: walk up.
    let mut cur: Option<&Path> = Some(p.as_path());
    while let Some(c) = cur {
        if c.is_dir() && c.file_name().map(|n| n == "Complete Archive").unwrap_or(false) {
            return Some(c.to_path_buf());
        }
        cur = c.parent();
    }
    // Last resort: a directory whose children look like channel folders is
    // good enough to index, whatever it is called.
    if p.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&p) {
            for entry in entries.flatten().take(60) {
                let child = entry.path();
                if child.is_dir() && looks_like_channel_dir(&child) {
                    return Some(p);
                }
            }
        }
        if looks_like_channel_dir(&p) {
            return Some(p);
        }
    }
    None
}

pub fn autodetect_archive_root() -> Option<PathBuf> {
    let home = home_dir();
    let candidates = [
        install_root(),
        home.join("yt-dlp"),
        home.join("Documents").join("yt-dlp"),
        home.clone(),
    ];
    for c in candidates {
        if let Some(r) = resolve_archive_root(&c) {
            return Some(r);
        }
    }
    None
}

pub fn expand_tilde(path: &Path) -> PathBuf {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix("~/").or_else(|| s.strip_prefix("~\\")) {
        return home_dir().join(rest);
    }
    if s == "~" {
        return home_dir();
    }
    path.to_path_buf()
}

/// The opaque key a video folder is addressed by. The UI never sends a
/// filesystem path -- it sends one of these plus an index into a server-side
/// file list, and the resolved path is re-checked against the video folder
/// before anything is opened. Traversal is off the table because no route
/// takes a path, not because a filter has to be right.
pub fn key_for(rel: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(rel.replace('\\', "/").as_bytes());
    let digest = hasher.finalize();
    digest.iter().take(8).map(|b| format!("{:02x}", b)).collect()
}

/// Locate an executable on PATH, honouring PATHEXT on Windows. Used for
/// dependency detection and for finding pwsh; deliberately not a `which`
/// subprocess, which would be one more thing that can be missing.
pub fn which(name: &str) -> Option<PathBuf> {
    let direct = Path::new(name);
    if direct.components().count() > 1 && direct.is_file() {
        return Some(direct.to_path_buf());
    }
    let path_var = env::var_os("PATH")?;
    let exts: Vec<String> = if cfg!(windows) {
        env::var("PATHEXT")
            .unwrap_or_else(|_| ".EXE;.CMD;.BAT;.COM".into())
            .split(';')
            .filter(|e| !e.is_empty())
            .map(|e| e.to_lowercase())
            .collect()
    } else {
        vec![String::new()]
    };
    for dir in env::split_paths(&path_var) {
        for ext in &exts {
            let candidate = dir.join(format!("{}{}", name, ext));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// pwsh, or nothing. Every stage of this pipeline is a PowerShell 7 script,
/// so a missing pwsh is not a degraded mode -- it means no download can run
/// at all, and the UI says exactly that rather than failing at spawn time
/// with a confusing OS error.
pub fn find_pwsh() -> Option<PathBuf> {
    if let Some(p) = which("pwsh") {
        return Some(p);
    }
    let extra: &[&str] = if cfg!(target_os = "macos") {
        &["/usr/local/bin/pwsh", "/opt/homebrew/bin/pwsh"]
    } else if cfg!(windows) {
        &[
            "C:/Program Files/PowerShell/7/pwsh.exe",
            "C:/Program Files/PowerShell/7-preview/pwsh.exe",
        ]
    } else {
        &["/usr/bin/pwsh", "/usr/local/bin/pwsh", "/opt/microsoft/powershell/7/pwsh"]
    };
    for c in extra {
        let p = PathBuf::from(c);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}
