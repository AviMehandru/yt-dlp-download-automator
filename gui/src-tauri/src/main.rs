// ytdl-gui -- a desktop front end for the yt-dlp archival pipeline.
//
// WHAT THIS IS NOT: a reimplementation of the pipeline. Downloads are started
// by handing a command line to the installed ytdl.ps1, exactly as a terminal
// would, and nothing in this process knows what run_ytdlp.ps1 or
// postprocess.ps1 do with it. If a flag works here and not in a terminal,
// that is a bug in this file, not a feature.
//
// WHAT THIS DOES OWN: the archive index, comment threading, transcript
// parsing and playback decisions -- a native reimplementation of what
// archive-viewer.py does in Python, because the GUI was asked for as one
// integrated surface rather than a shell around a second server. That
// duplication is real and has a real cost: any change to the archive layout
// now has THREE consumers to update (postprocess.ps1 writes it,
// archive-viewer.py reads it, this reads it). archive.rs carries the notes on
// what must stay equivalent.
//
// The invariants inherited from archive-viewer.py, which are not negotiable:
//
//   * The archive is read-only. Nothing is created, moved or modified under
//     Youtube Videos/. postprocess.ps1 writes a checksums.sha256 covering
//     every file in a video folder, so a derived file dropped in there makes
//     that manifest stop verifying. All derived state goes to the cache dir.
//   * The client never sends a filesystem path. Content is addressed by an
//     opaque key plus an index into a server-side file list, and the resolved
//     path is re-checked against the video folder before anything is opened.
//   * Nothing is re-encoded without being asked.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod archive;
mod health;
mod media;
mod paths;
mod pipeline;

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::http::{Request, Response};
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Settings {
    /// The -DataRoot / `ytdl --path` equivalent. None means "wherever the
    /// pipeline puts it by default", which is the install root.
    pub data_root: Option<String>,
    /// An explicitly chosen archive root, if autodetection guessed wrong.
    pub archive_root: Option<String>,
    pub allow_transcode: bool,
    pub default_workers: u32,
    pub theme: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            data_root: None,
            archive_root: None,
            allow_transcode: true,
            default_workers: 1,
            theme: "system".into(),
        }
    }
}

fn settings_path() -> PathBuf {
    paths::state_dir().join("settings.json")
}

fn load_settings() -> Settings {
    std::fs::read_to_string(settings_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_settings(s: &Settings) {
    let _ = std::fs::create_dir_all(paths::state_dir());
    if let Ok(text) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(settings_path(), text);
    }
}

pub struct AppState {
    index: RwLock<archive::Index>,
    runner: Arc<pipeline::Runner>,
    media: Arc<media::Media>,
    settings: Mutex<Settings>,
    scanning: Mutex<bool>,
}

impl AppState {
    fn data_root(&self) -> PathBuf {
        self.settings
            .lock()
            .unwrap()
            .data_root
            .clone()
            .map(|s| paths::expand_tilde(Path::new(&s)))
            .unwrap_or_else(paths::install_root)
    }
}

// ---------------------------------------------------------------------------
// Settings and locations
// ---------------------------------------------------------------------------

#[tauri::command]
fn get_settings(state: State<AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
fn set_settings(state: State<AppState>, settings: Settings) -> Settings {
    {
        let mut s = state.settings.lock().unwrap();
        *s = settings.clone();
        save_settings(&s);
    }
    settings
}

#[tauri::command]
fn locations(state: State<AppState>) -> Value {
    let data_root = state.data_root();
    let configured = state
        .settings
        .lock()
        .unwrap()
        .archive_root
        .clone()
        .map(|s| paths::expand_tilde(Path::new(&s)));
    let archive_root = configured
        .as_deref()
        .and_then(paths::resolve_archive_root)
        .or_else(|| paths::resolve_archive_root(&data_root))
        .or_else(paths::autodetect_archive_root);
    json!({
        "install_root": paths::install_root().to_string_lossy(),
        "scripts_dir": paths::scripts_dir().to_string_lossy(),
        "configs_dir": paths::configs_dir().to_string_lossy(),
        "data_root": data_root.to_string_lossy(),
        "archive_root": archive_root.map(|p| p.to_string_lossy().to_string()),
        "cache_dir": paths::cache_dir().to_string_lossy(),
        "state_dir": paths::state_dir().to_string_lossy(),
        "pwsh": paths::find_pwsh().map(|p| p.to_string_lossy().to_string()),
        "platform": std::env::consts::OS,
    })
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

#[tauri::command]
fn command_preview(opts: pipeline::RunOptions) -> String {
    opts.command_preview()
}

#[tauri::command]
fn run_enqueue(app: AppHandle, state: State<AppState>, opts: pipeline::RunOptions) -> Result<String, String> {
    if opts.url.trim().is_empty() {
        return Err("Enter a URL first.".into());
    }
    let mut opts = opts;
    if opts.data_root.is_none() {
        opts.data_root = state.settings.lock().unwrap().data_root.clone();
    }
    Ok(pipeline::enqueue(&app, &state.runner, opts))
}

#[tauri::command]
fn run_cancel(app: AppHandle, state: State<AppState>) -> bool {
    pipeline::cancel_current(&app, &state.runner)
}

#[tauri::command]
fn queue_remove(app: AppHandle, state: State<AppState>, id: String) {
    pipeline::remove_queued(&app, &state.runner, &id);
}

#[tauri::command]
fn queue_set_paused(app: AppHandle, state: State<AppState>, paused: bool) {
    pipeline::set_paused(&app, &state.runner, paused);
}

#[tauri::command]
fn history_clear(app: AppHandle, state: State<AppState>) {
    pipeline::clear_history(&app, &state.runner);
}

#[tauri::command]
fn runner_snapshot(state: State<AppState>) -> Value {
    pipeline::snapshot(&state.runner)
}

// ---------------------------------------------------------------------------
// Archive
// ---------------------------------------------------------------------------

#[tauri::command]
fn archive_rescan(app: AppHandle, state: State<'_, AppState>, force: bool) -> Result<(), String> {
    {
        let mut scanning = state.scanning.lock().unwrap();
        if *scanning {
            return Err("A scan is already running.".into());
        }
        *scanning = true;
    }
    let configured = state
        .settings
        .lock()
        .unwrap()
        .archive_root
        .clone()
        .map(|s| paths::expand_tilde(Path::new(&s)));
    let data_root = state.data_root();
    let root = configured
        .as_deref()
        .and_then(paths::resolve_archive_root)
        .or_else(|| paths::resolve_archive_root(&data_root))
        .or_else(paths::autodetect_archive_root);

    let Some(root) = root else {
        *state.scanning.lock().unwrap() = false;
        return Err(format!(
            "Could not find an archive. Looked for 'Youtube Videos/Complete Archive' under {} \
             and the usual defaults. Set the data root in Settings to the same path you would \
             pass to `ytdl --path`.",
            data_root.display()
        ));
    };

    // The scan runs off the UI thread and reports progress by event, because
    // a first index of a large archive reads every info.json in it.
    let app2 = app.clone();
    std::thread::spawn(move || {
        let state = app2.state::<AppState>();
        let mut idx = archive::Index::new(paths::cache_dir());
        let result = idx.scan(root, force, |done, total, name| {
            let _ = app2.emit(
                "scan-progress",
                json!({ "done": done, "total": total, "current": name }),
            );
        });
        {
            let mut guard = state.index.write().unwrap();
            *guard = idx;
        }
        *state.scanning.lock().unwrap() = false;
        let _ = app2.emit(
            "scan-done",
            json!({ "ok": result.is_ok(), "error": result.err() }),
        );
    });
    Ok(())
}

#[tauri::command]
fn archive_library(state: State<AppState>) -> Value {
    let idx = state.index.read().unwrap();
    json!({
        "root": idx.root.as_ref().map(|p| p.to_string_lossy().to_string()),
        "videos": idx.library(),
        "channels": idx.channels,
    })
}

#[tauri::command]
fn archive_video(state: State<AppState>, key: String) -> Result<Value, String> {
    let idx = state.index.read().unwrap();
    let entry = idx.get(&key).ok_or("unknown video")?;
    let full = archive::load_full_info(entry);

    let video_idx = entry.video_index();
    let video_path = video_idx.and_then(|i| entry.path_for_index(i));
    let plan = video_path.as_deref().map(|p| state.media.plan(p));
    // Whether a lossless container rewrite is available if the webview
    // refuses the file as it stands. See Media::needs_webm_container.
    let webm_fallback = video_path
        .as_deref()
        .map(|p| state.media.needs_webm_container(p))
        .unwrap_or(false);

    // Subtitle tracks, with the auto/human distinction taken from the file
    // CONTENTS -- the filenames cannot tell you, since --write-subs and
    // --write-auto-subs both land in Subtitles/ under the same base name.
    let mut subs = Vec::new();
    for (i, f) in entry.light.files.iter().enumerate() {
        if !archive::SUB_EXTS.contains(&f.ext.as_str()) {
            continue;
        }
        let path = entry.path_for_index(i);
        subs.push(json!({
            "idx": i,
            "rel": f.rel,
            "ext": f.ext,
            "size": f.size,
            "auto": path.as_deref().map(archive::subtitle_is_auto).unwrap_or(false),
        }));
    }

    Ok(json!({
        "key": entry.key,
        "rel": entry.rel,
        "channel": entry.channel,
        "meta": entry.light,
        "info": full.get("info").cloned().unwrap_or(Value::Null),
        "dropped": full.get("dropped").cloned().unwrap_or(Value::Null),
        "video_idx": video_idx,
        "thumb_idx": entry.thumbnail_index(),
        "plan": plan,
        "webm_fallback": webm_fallback,
        "subtitles": subs,
        "folder": entry.dir.to_string_lossy(),
    }))
}

#[tauri::command]
fn archive_comments(state: State<AppState>, key: String) -> Result<Value, String> {
    let idx = state.index.read().unwrap();
    let entry = idx.get(&key).ok_or("unknown video")?;
    let threads = archive::load_comments(entry);
    let total: usize = threads.iter().map(|t| 1 + t.replies.len()).sum();
    Ok(json!({ "threads": threads, "total": total }))
}

#[tauri::command]
fn archive_transcript(state: State<AppState>, key: String, idx: usize) -> Result<Value, String> {
    let index = state.index.read().unwrap();
    let entry = index.get(&key).ok_or("unknown video")?;
    let path = entry.path_for_index(idx).ok_or("no such file")?;
    Ok(json!({ "cues": archive::parse_subtitle_cues(&path) }))
}

#[tauri::command]
fn archive_file_text(state: State<AppState>, key: String, idx: usize) -> Result<String, String> {
    let index = state.index.read().unwrap();
    let entry = index.get(&key).ok_or("unknown video")?;
    let path = entry.path_for_index(idx).ok_or("no such file")?;
    let md = std::fs::metadata(&path).map_err(|e| e.to_string())?;
    if md.len() > 8 * 1024 * 1024 {
        return Err(format!(
            "{} is {:.1} MB -- too large to show as text. Open it in the file manager instead.",
            path.file_name().unwrap_or_default().to_string_lossy(),
            md.len() as f64 / 1_048_576.0
        ));
    }
    std::fs::read_to_string(&path).map_err(|e| e.to_string())
}

/// Hand a file to a real media player. mpv first: it plays every codec
/// combination yt-dlp can produce and reads embedded subtitles and chapters,
/// which is exactly what this pipeline's .mkv output is full of.
#[tauri::command]
fn open_in_player(state: State<AppState>, key: String, idx: usize) -> Result<String, String> {
    let index = state.index.read().unwrap();
    let entry = index.get(&key).ok_or("unknown video")?;
    let path = entry.path_for_index(idx).ok_or("no such file")?;
    for name in ["mpv", "vlc"] {
        if let Some(exe) = paths::which(name) {
            std::process::Command::new(exe)
                .arg(&path)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map_err(|e| e.to_string())?;
            return Ok(name.into());
        }
    }
    open_with_os(&path)?;
    Ok("system".into())
}

#[tauri::command]
fn open_folder(state: State<AppState>, key: String) -> Result<(), String> {
    let index = state.index.read().unwrap();
    let entry = index.get(&key).ok_or("unknown video")?;
    open_with_os(&entry.dir)
}

#[tauri::command]
fn open_path(path: String) -> Result<(), String> {
    let p = paths::expand_tilde(Path::new(&path));
    if !p.exists() {
        return Err(format!("{} does not exist", p.display()));
    }
    open_with_os(&p)
}

fn open_with_os(path: &Path) -> Result<(), String> {
    let (cmd, args): (&str, Vec<String>) = if cfg!(target_os = "macos") {
        ("open", vec![path.to_string_lossy().to_string()])
    } else if cfg!(windows) {
        (
            "cmd",
            vec!["/c".into(), "start".into(), String::new(), path.to_string_lossy().to_string()],
        )
    } else {
        ("xdg-open", vec![path.to_string_lossy().to_string()])
    };
    std::process::Command::new(cmd)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("could not open {}: {}", path.display(), e))
}

// ---------------------------------------------------------------------------
// Playback preparation
// ---------------------------------------------------------------------------

#[tauri::command]
fn media_status(state: State<AppState>, key: String, mode: String) -> Result<media::JobState, String> {
    let index = state.index.read().unwrap();
    let entry = index.get(&key).ok_or("unknown video")?;
    let idx = entry.video_index().ok_or("this folder has no video file")?;
    let src = entry.path_for_index(idx).ok_or("video file is missing")?;
    Ok(state.media.status(&key, &src, &mode))
}

#[tauri::command]
fn media_start(
    app: AppHandle,
    state: State<AppState>,
    key: String,
    mode: String,
) -> Result<media::JobState, String> {
    if mode != "remux" && mode != "transcode" && mode != "webm" {
        return Err("mode must be webm, remux or transcode".into());
    }
    let (src, duration) = {
        let index = state.index.read().unwrap();
        let entry = index.get(&key).ok_or("unknown video")?;
        let idx = entry.video_index().ok_or("this folder has no video file")?;
        (
            entry.path_for_index(idx).ok_or("video file is missing")?,
            entry.light.duration,
        )
    };
    Ok(state.media.start(app, key, src, mode, duration))
}

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------

#[tauri::command]
fn health_report(state: State<AppState>) -> Value {
    let data_root = state.data_root();
    let (videos, channels, bytes) = {
        let idx = state.index.read().unwrap();
        let lib = idx.library();
        (
            lib.len(),
            idx.channels.len(),
            lib.iter().map(|v| v.total_bytes).sum::<u64>(),
        )
    };
    json!({
        "dependencies": health::dependencies(),
        "installed": health::installed_files(),
        "config": health::config_info(),
        "pot": health::pot_status(),
        "stats": health::archive_stats(&data_root, videos, channels, bytes),
        "ffmpeg": state.media.ffmpeg.as_ref().map(|p| p.to_string_lossy().to_string()),
        "ffprobe": state.media.ffprobe.as_ref().map(|p| p.to_string_lossy().to_string()),
        "transcode_profile": state.media.transcode_profile().map(|p| p.name),
    })
}

#[tauri::command]
fn verify_video(state: State<AppState>, key: String) -> Result<health::ChecksumResult, String> {
    let index = state.index.read().unwrap();
    let entry = index.get(&key).ok_or("unknown video")?;
    let dir = entry.dir.clone();
    drop(index);
    Ok(health::verify_checksums(&dir))
}

#[tauri::command]
fn read_log(state: State<AppState>, which: String, lines: usize) -> Value {
    let logs = state.data_root().join("Archive Logs").join("Logs");
    let path = match which.as_str() {
        "archive" => logs.join("archive.txt"),
        _ => logs.join("download.log"),
    };
    json!({
        "path": path.to_string_lossy(),
        "exists": path.is_file(),
        "text": health::log_tail(&path, lines),
    })
}

// ---------------------------------------------------------------------------
// The media:// protocol
// ---------------------------------------------------------------------------

const CHUNK: u64 = 4 * 1024 * 1024;

/// media://localhost/<key>/<idx>[?mode=remux|transcode]
///
/// The only way the frontend ever names a file. There is no route that takes
/// a path, which is what keeps traversal off the table rather than a filter
/// that has to be right.
fn serve_media(app: &AppHandle, request: Request<Vec<u8>>) -> Response<Vec<u8>> {
    let uri = request.uri().clone();
    let path_part = uri.path().trim_start_matches('/').to_string();
    let query = uri.query().unwrap_or("").to_string();
    if std::env::var("YTDL_GUI_DEBUG").is_ok() {
        eprintln!(
            "[media] uri={} host={:?} path={:?} query={:?} range={:?}",
            uri,
            uri.host(),
            path_part,
            query,
            request.headers().get("range")
        );
    }

    let mut mode = "direct".to_string();
    for pair in query.split('&') {
        if let Some(v) = pair.strip_prefix("mode=") {
            mode = v.to_string();
        }
    }

    let mut segs = path_part.split('/');
    let (Some(key), Some(idx_s)) = (segs.next(), segs.next()) else {
        return text_response(400, "bad media url");
    };
    let Ok(idx) = idx_s.parse::<usize>() else {
        return text_response(400, "bad index");
    };

    let state = app.state::<AppState>();
    let resolved = {
        let index = state.index.read().unwrap();
        let Some(entry) = index.get(key) else {
            return text_response(404, "unknown key");
        };
        match mode.as_str() {
            "remux" | "transcode" => {
                let out = state.media.output_path(key, &mode);
                if out.is_file() {
                    Some(out)
                } else {
                    None
                }
            }
            _ => entry.path_for_index(idx),
        }
    };
    let Some(path) = resolved else {
        return text_response(404, "not ready");
    };

    // plan() answers "how should this VIDEO be played", so it is asked only
    // about video files. Running everything through it served every
    // thumbnail in the library as video/mp4: ffprobe reports a PNG as a
    // one-frame stream with codec "png", which matches neither the WebM nor
    // the MP4 copy set, so plan() fell through to its re-encode branch and
    // handed back a video MIME type for an image. The library rendered as
    // empty boxes with no error anywhere -- the webview simply declines to
    // paint an <img> it has been told is a video.
    let is_video = archive::VIDEO_EXTS.contains(
        &path
            .extension()
            .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
            .unwrap_or_default()
            .as_str(),
    );
    let mime = if mode == "direct" && is_video {
        // An .mkv whose streams are WebM-compatible is served AS WebM. This
        // is not a lie to the browser: VP8/VP9/AV1 + Opus/Vorbis in Matroska
        // is byte-compatible with WebM, which is why it plays at all.
        state.media.plan(&path).mime
    } else {
        media::guess_mime(&path).to_string()
    };

    let Ok(md) = std::fs::metadata(&path) else {
        return text_response(404, "gone");
    };
    let size = md.len();

    let range = request
        .headers()
        .get("range")
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range);

    // 206 ONLY in answer to an actual Range request.
    //
    // This was 206-unconditionally at first, and it cost an afternoon: video
    // playback worked fine (a <video> element always sends Range), but every
    // thumbnail in the library rendered as an empty box. WebKit discards a
    // 206 for an image the page never asked a range for -- correctly, since
    // a partial response to a whole-resource request is a protocol error. A
    // small file with no Range header therefore gets a plain 200 with the
    // whole body, and only a genuine Range gets a slice back.
    //
    // A LARGE file with no Range still gets the first chunk as 206, because
    // the alternative is reading a multi-gigabyte .mkv into memory to answer
    // a request the media element is about to re-issue with a Range anyway.
    let whole_file = range.is_none() && size <= CHUNK;

    let (start, end) = match range {
        Some((s, e)) => (
            s.min(size),
            e.unwrap_or(size.saturating_sub(1)).min(size.saturating_sub(1)),
        ),
        None => (0, size.saturating_sub(1).min(CHUNK - 1)),
    };
    let end = end.min(start.saturating_add(CHUNK - 1));
    let len = end.saturating_sub(start) + 1;

    let mut buf = vec![0u8; len as usize];
    {
        use std::io::{Read, Seek, SeekFrom};
        let Ok(mut fh) = std::fs::File::open(&path) else {
            return text_response(500, "cannot open");
        };
        if fh.seek(SeekFrom::Start(start)).is_err() {
            return text_response(500, "cannot seek");
        }
        match fh.read(&mut buf) {
            Ok(n) => buf.truncate(n),
            Err(_) => return text_response(500, "cannot read"),
        }
    }

    let builder = Response::builder()
        .header("Content-Type", mime)
        .header("Accept-Ranges", "bytes")
        .header("Content-Length", buf.len().to_string())
        .header("Cache-Control", "no-store");

    let builder = if whole_file {
        builder.status(200)
    } else {
        builder.status(206).header(
            "Content-Range",
            format!(
                "bytes {}-{}/{}",
                start,
                start + buf.len().max(1) as u64 - 1,
                size
            ),
        )
    };

    builder
        .body(buf)
        .unwrap_or_else(|_| text_response(500, "response build failed"))
}

fn parse_range(header: &str) -> Option<(u64, Option<u64>)> {
    let spec = header.trim().strip_prefix("bytes=")?;
    let (s, e) = spec.split_once('-')?;
    let start = s.trim().parse::<u64>().ok()?;
    let end = e.trim();
    let end = if end.is_empty() {
        None
    } else {
        end.parse::<u64>().ok()
    };
    Some((start, end))
}

fn text_response(status: u16, msg: &str) -> Response<Vec<u8>> {
    Response::builder()
        .status(status)
        .header("Content-Type", "text/plain; charset=utf-8")
        .body(msg.as_bytes().to_vec())
        .expect("static response")
}

// ---------------------------------------------------------------------------

fn main() {
    let settings = load_settings();
    let runner = Arc::new(pipeline::Runner::default());
    pipeline::load_persisted(&runner);
    let media = Arc::new(media::Media::new(paths::cache_dir(), settings.allow_transcode));

    let state = AppState {
        index: RwLock::new(archive::Index::new(paths::cache_dir())),
        runner: runner.clone(),
        media,
        settings: Mutex::new(settings),
        scanning: Mutex::new(false),
    };

    tauri::Builder::default()
        .manage(state)
        // The handler receives a UriSchemeContext rather than an &AppHandle
        // (Tauri changed this within 2.x); app_handle() is what both spellings
        // ultimately hand you.
        .register_uri_scheme_protocol("media", |ctx, request| {
            serve_media(ctx.app_handle(), request)
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            set_settings,
            locations,
            command_preview,
            run_enqueue,
            run_cancel,
            queue_remove,
            queue_set_paused,
            history_clear,
            runner_snapshot,
            archive_rescan,
            archive_library,
            archive_video,
            archive_comments,
            archive_transcript,
            archive_file_text,
            open_in_player,
            open_folder,
            open_path,
            media_status,
            media_start,
            health_report,
            verify_video,
            read_log,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            pipeline::start_worker(handle, runner.clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running ytdl-gui");
}
