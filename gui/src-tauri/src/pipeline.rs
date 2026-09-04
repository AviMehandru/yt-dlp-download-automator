// The download engine: what actually starts a run.
//
// This does NOT reimplement any part of the pipeline. It builds a `ytdl`
// command line and hands it to ytdl.ps1 -- the single argument parser, on
// every platform -- exactly as a terminal would. Every option below maps
// one-to-one onto a flag ytdl.ps1 already accepts, and nothing here knows
// what run_ytdlp.ps1 or postprocess.ps1 do with them.
//
// Why ytdl.ps1 and not run_ytdlp.ps1 directly, when this process could just
// as easily pass -BreakOnExisting itself: because then there would be two
// argument surfaces to keep in agreement, which is the exact problem v0.72
// collapsed into one file. A flag added to ytdl.ps1 becomes available here by
// adding a checkbox, and a flag it rejects fails the same way it fails in a
// terminal.
//
// ONE RUN AT A TIME, deliberately. The queue below is strictly sequential
// because independent `ytdl` invocations race on shared state
// (global_manifest.json, channel_manifest.json, the Channel Info refresh
// throttle, download.log). -Workers N is the supported way to get real
// parallelism -- it enumerates every video up front so no two workers are
// assigned the same one, and postprocess.ps1 has matching file locking. So
// "run several at once" is exposed as the workers spinner, not as a wider
// queue, and the queue never starts a second process.

use std::collections::VecDeque;
use std::io::{BufReader, Read};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

use crate::paths;

pub fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct RunOptions {
    pub url: String,
    #[serde(default)]
    pub data_root: Option<String>,
    #[serde(default)]
    pub sync: bool,
    #[serde(default)]
    pub items: Option<String>,
    #[serde(default)]
    pub after: Option<String>,
    #[serde(default)]
    pub lazy: bool,
    #[serde(default)]
    pub workers: Option<u32>,
    #[serde(default)]
    pub no_pot: bool,
    #[serde(default)]
    pub skip_pot_update: bool,
    #[serde(default)]
    pub pot_port: Option<u16>,
}

impl RunOptions {
    /// Everything after the script path. The URL is always first and always
    /// a full URL: ytdl.ps1 accepts a bare 11-character id, but `pwsh -File`
    /// would try to bind a leading-hyphen id as a parameter before the script
    /// ever saw it, and about one YouTube id in thirty starts with "-" or "_".
    /// Normalising here costs nothing and removes the whole class.
    pub fn to_args(&self) -> Vec<String> {
        let mut v = vec![normalize_url(&self.url)];
        if let Some(p) = self.data_root.as_ref().filter(|s| !s.trim().is_empty()) {
            v.push("--path".into());
            v.push(p.clone());
        }
        if self.sync {
            v.push("--sync".into());
        }
        if let Some(i) = self.items.as_ref().filter(|s| !s.trim().is_empty()) {
            v.push("--items".into());
            v.push(i.trim().to_string());
        }
        if let Some(a) = self.after.as_ref().filter(|s| !s.trim().is_empty()) {
            v.push("--after".into());
            v.push(a.trim().to_string());
        }
        if self.lazy {
            v.push("--lazy".into());
        }
        if let Some(w) = self.workers.filter(|w| *w > 1) {
            v.push("--workers".into());
            v.push(w.to_string());
        }
        if self.no_pot {
            v.push("--no-pot".into());
        }
        if self.skip_pot_update {
            v.push("--skip-pot-update".into());
        }
        if let Some(p) = self.pot_port {
            v.push("--pot-port".into());
            v.push(p.to_string());
        }
        v
    }

    /// What the equivalent terminal command would be. Shown in the UI above
    /// the Start button, because a GUI that hides the command it runs makes
    /// the CLI harder to learn rather than easier.
    pub fn command_preview(&self) -> String {
        let mut out = String::from("ytdl");
        for (i, a) in self.to_args().iter().enumerate() {
            out.push(' ');
            if i == 0 || a.contains(' ') {
                out.push('"');
                out.push_str(a);
                out.push('"');
            } else {
                out.push_str(a);
            }
        }
        out
    }
}

/// A bare video id becomes a watch URL; anything already URL-shaped is left
/// exactly as typed. Deliberately not a validator -- ytdl.ps1 has its own
/// "that does not look like a URL" warning and yt-dlp's extractor is the real
/// authority on what is downloadable.
pub fn normalize_url(url: &str) -> String {
    let u = url.trim();
    if u.contains("://") {
        return u.to_string();
    }
    let looks_like_id = u.len() == 11
        && u.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if looks_like_id {
        return format!("https://www.youtube.com/watch?v={}", u);
    }
    if u.starts_with("youtube.com") || u.starts_with("www.youtube.com") || u.starts_with("youtu.be")
    {
        return format!("https://{}", u);
    }
    u.to_string()
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct QueueItem {
    pub id: String,
    pub opts: RunOptions,
    pub added: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct RunRecord {
    pub id: String,
    pub opts: RunOptions,
    pub command: String,
    pub started: i64,
    pub finished: Option<i64>,
    /// queued | running | done | failed | cancelled
    pub state: String,
    pub exit_code: Option<i32>,
    pub videos_touched: Option<i64>,
    pub archive_skipped: Option<i64>,
    pub errors: Option<i64>,
    pub warnings: Option<i64>,
    pub log_path: Option<String>,
    pub last_line: String,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct Progress {
    pub percent: Option<f64>,
    pub speed: Option<String>,
    pub eta: Option<String>,
    pub total: Option<String>,
    pub stage: String,
    pub video_id: Option<String>,
    pub destination: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
pub struct LineEvent {
    pub run_id: String,
    pub stream: &'static str,
    pub text: String,
    /// True for a carriage-return progress update, which REPLACES the previous
    /// transient line instead of appending. yt-dlp redraws its progress line
    /// with \r and the config sets no --newline, so without this distinction
    /// one download produces thousands of near-identical log lines.
    pub transient: bool,
    pub progress: Option<Progress>,
}

#[derive(Default)]
pub struct RunnerState {
    pub queue: VecDeque<QueueItem>,
    pub current: Option<RunRecord>,
    pub history: Vec<RunRecord>,
    pub child_pid: Option<u32>,
    pub log: Vec<String>,
    pub progress: Progress,
    pub paused: bool,
}

pub struct Runner {
    pub state: Mutex<RunnerState>,
    pub wake: Condvar,
    pub cancel: AtomicBool,
    pub stop: AtomicBool,
}

impl Default for Runner {
    fn default() -> Self {
        Runner {
            state: Mutex::new(RunnerState::default()),
            wake: Condvar::new(),
            cancel: AtomicBool::new(false),
            stop: AtomicBool::new(false),
        }
    }
}

const MAX_LOG_LINES: usize = 4000;
const MAX_HISTORY: usize = 300;

fn history_path() -> PathBuf {
    paths::state_dir().join("history.json")
}
fn queue_path() -> PathBuf {
    paths::state_dir().join("queue.json")
}

pub fn load_persisted(runner: &Runner) {
    let mut st = runner.state.lock().unwrap();
    if let Ok(s) = std::fs::read_to_string(history_path()) {
        if let Ok(h) = serde_json::from_str::<Vec<RunRecord>>(&s) {
            st.history = h;
        }
    }
    if let Ok(s) = std::fs::read_to_string(queue_path()) {
        if let Ok(q) = serde_json::from_str::<Vec<QueueItem>>(&s) {
            st.queue = q.into();
        }
    }
}

fn persist(st: &RunnerState) {
    let _ = std::fs::create_dir_all(paths::state_dir());
    if let Ok(s) = serde_json::to_string_pretty(&st.history) {
        let _ = std::fs::write(history_path(), s);
    }
    let q: Vec<&QueueItem> = st.queue.iter().collect();
    if let Ok(s) = serde_json::to_string_pretty(&q) {
        let _ = std::fs::write(queue_path(), s);
    }
}


fn emit_state(app: &AppHandle, runner: &Runner) {
    let st = runner.state.lock().unwrap();
    let payload = serde_json::json!({
        "queue": st.queue.iter().collect::<Vec<_>>(),
        "current": st.current,
        "history": st.history.iter().take(MAX_HISTORY).collect::<Vec<_>>(),
        "progress": st.progress,
        "paused": st.paused,
    });
    let _ = app.emit("runner-state", payload);
}

// ---------------------------------------------------------------------------
// Output handling
// ---------------------------------------------------------------------------

/// Strip ANSI escape sequences. yt-dlp turns colour off when stdout is not a
/// terminal, but pwsh does not always, and a progress line full of escape
/// bytes renders as garbage in a webview.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c2 in chars.by_ref() {
                    if c2.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// yt-dlp's own progress line, e.g.
///   [download]  45.2% of  120.00MiB at   2.00MiB/s ETA 00:30
/// Parsed by scanning tokens rather than with a regex, to keep the crate
/// list to what the build actually needs.
fn parse_progress(line: &str, prev: &Progress) -> Option<Progress> {
    let mut p = prev.clone();
    let mut matched = false;

    if let Some(rest) = line.trim().strip_prefix("[download]") {
        let toks: Vec<&str> = rest.split_whitespace().collect();
        if let Some(dest) = rest.trim().strip_prefix("Destination:") {
            p.destination = Some(dest.trim().to_string());
            p.stage = "downloading".into();
            return Some(p);
        }
        for (i, t) in toks.iter().enumerate() {
            if let Some(num) = t.strip_suffix('%') {
                if let Ok(v) = num.parse::<f64>() {
                    p.percent = Some(v);
                    p.stage = "downloading".into();
                    matched = true;
                }
            }
            if *t == "of" {
                if let Some(next) = toks.get(i + 1) {
                    p.total = Some(next.to_string());
                }
            }
            if *t == "at" {
                if let Some(next) = toks.get(i + 1) {
                    p.speed = Some(next.to_string());
                }
            }
            if *t == "ETA" {
                if let Some(next) = toks.get(i + 1) {
                    p.eta = Some(next.to_string());
                }
            }
        }
        if matched {
            return Some(p);
        }
    }

    // Stage markers worth surfacing, all emitted by the pipeline itself or by
    // yt-dlp's own extractor chatter.
    let stages: &[(&str, &str)] = &[
        ("[Merger]", "merging"),
        ("[Metadata]", "embedding metadata"),
        ("[EmbedSubtitle]", "embedding subtitles"),
        ("[ThumbnailsConvertor]", "thumbnail"),
        ("[postprocess]", "post-processing"),
        ("Fetching comments", "fetching comments"),
        ("[info] Writing video subtitles", "subtitles"),
        ("-- Enumerating videos", "enumerating"),
    ];
    for (needle, stage) in stages {
        if line.contains(needle) {
            p.stage = (*stage).to_string();
            p.percent = None;
            return Some(p);
        }
    }

    // "[youtube] dQw4w9WgXcQ: Downloading webpage" -- the id of the video the
    // session is currently on, which is the only reliable per-video marker in
    // a multi-video run.
    if let Some(rest) = line.trim().strip_prefix("[youtube] ") {
        if let Some((id, _)) = rest.split_once(':') {
            let id = id.trim();
            if id.len() == 11 && !id.contains(' ') {
                p.video_id = Some(id.to_string());
                return Some(p);
            }
        }
    }
    None
}

/// Reads a child stream byte-wise and splits on BOTH \n and \r.
///
/// This is not defensiveness: yt-dlp redraws its progress line with a
/// carriage return and yt-dlp.conf sets no --newline, so a line-oriented
/// reader would either block until the download finished or deliver one
/// enormous line. Splitting on \r as well is what makes the progress bar
/// move.
fn pump<R: Read + Send + 'static>(
    reader: R,
    stream: &'static str,
    run_id: String,
    app: AppHandle,
    runner: Arc<Runner>,
) {
    let mut buf = Vec::with_capacity(4096);
    let mut r = BufReader::new(reader);
    let mut byte = [0u8; 1];
    loop {
        match r.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        let c = byte[0];
        if c == b'\n' || c == b'\r' {
            let text = strip_ansi(&String::from_utf8_lossy(&buf));
            let transient = c == b'\r';
            buf.clear();
            if text.trim().is_empty() {
                continue;
            }
            let progress = {
                let mut st = runner.state.lock().unwrap();
                let updated = parse_progress(&text, &st.progress);
                if let Some(p) = &updated {
                    st.progress = p.clone();
                }
                if !transient {
                    st.log.push(text.clone());
                    if st.log.len() > MAX_LOG_LINES {
                        let drop = st.log.len() - MAX_LOG_LINES;
                        st.log.drain(0..drop);
                    }
                }
                if let Some(cur) = st.current.as_mut() {
                    cur.last_line = text.clone();
                    absorb_summary(cur, &text);
                }
                updated
            };
            let _ = app.emit(
                "run-line",
                LineEvent {
                    run_id: run_id.clone(),
                    stream,
                    text,
                    transient,
                    progress,
                },
            );
        } else {
            buf.push(c);
            if buf.len() > 64 * 1024 {
                buf.clear();
            }
        }
    }
}

/// run_ytdlp.ps1 closes every session with
///   -- Session summary: N video(s) touched, M already archived (skipped), E error(s), W warning(s) --
/// which is the only place those counts exist. Parsed here so the history
/// row can show them without re-reading download.log.
fn absorb_summary(rec: &mut RunRecord, line: &str) {
    if !line.contains("Session summary:") {
        if line.contains("Data root override:") {
            // nothing to record, but keep the branch obvious
        }
        return;
    }
    let nums: Vec<i64> = line
        .split_whitespace()
        .filter_map(|t| t.trim_matches(|c: char| !c.is_ascii_digit()).parse::<i64>().ok())
        .collect();
    if nums.len() >= 4 {
        rec.videos_touched = Some(nums[0]);
        rec.archive_skipped = Some(nums[1]);
        rec.errors = Some(nums[2]);
        rec.warnings = Some(nums[3]);
    }
}

// ---------------------------------------------------------------------------
// Cancellation
// ---------------------------------------------------------------------------

/// Kill the whole tree, not just the child.
///
/// `ytdl.ps1` starts run_ytdlp.ps1 as a CHILD pwsh process, which starts
/// yt-dlp, which starts postprocess.ps1 and ffmpeg. Killing only the process
/// this app spawned would leave a download running with nothing reading its
/// output. On unix the run gets its own process group and the group is
/// signalled; on Windows taskkill /T does the same job.
#[cfg(unix)]
fn kill_tree(pid: u32) {
    unsafe {
        libc::kill(-(pid as i32), libc::SIGTERM);
    }
    std::thread::sleep(std::time::Duration::from_millis(1500));
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
    }
}

#[cfg(windows)]
fn kill_tree(pid: u32) {
    let _ = Command::new("taskkill")
        .args(["/T", "/F", "/PID", &pid.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn spawn_child(pwsh: &PathBuf, script: &PathBuf, args: &[String]) -> std::io::Result<Child> {
    let mut cmd = Command::new(pwsh);
    cmd.arg("-NoProfile")
        .arg("-File")
        .arg(script)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // Own process group, so cancel can signal the whole tree.
        cmd.process_group(0);
    }
    cmd.spawn()
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

pub fn start_worker(app: AppHandle, runner: Arc<Runner>) {
    std::thread::spawn(move || loop {
        if runner.stop.load(Ordering::Relaxed) {
            return;
        }
        let item = {
            let mut st = runner.state.lock().unwrap();
            while st.queue.is_empty() || st.paused {
                if runner.stop.load(Ordering::Relaxed) {
                    return;
                }
                let (guard, _) = runner
                    .wake
                    .wait_timeout(st, std::time::Duration::from_millis(500))
                    .unwrap();
                st = guard;
            }
            st.queue.pop_front()
        };
        let Some(item) = item else { continue };
        run_one(&app, &runner, item);
    });
}

fn run_one(app: &AppHandle, runner: &Arc<Runner>, item: QueueItem) {
    let opts = item.opts.clone();
    let command = opts.command_preview();

    let mut rec = RunRecord {
        id: item.id.clone(),
        opts: opts.clone(),
        command: command.clone(),
        started: now_secs(),
        finished: None,
        state: "running".into(),
        exit_code: None,
        videos_touched: None,
        archive_skipped: None,
        errors: None,
        warnings: None,
        log_path: None,
        last_line: String::new(),
    };

    let Some(pwsh) = paths::find_pwsh() else {
        rec.state = "failed".into();
        rec.finished = Some(now_secs());
        rec.last_line = "pwsh (PowerShell 7) was not found. Every stage of this pipeline is a \
                         PowerShell script, so nothing can run without it -- install it and \
                         re-run setup."
            .into();
        finish(app, runner, rec);
        return;
    };
    let script = paths::scripts_dir().join("ytdl.ps1");
    if !script.is_file() {
        rec.state = "failed".into();
        rec.finished = Some(now_secs());
        rec.last_line = format!(
            "{} does not exist. The GUI drives the installed pipeline, not the repo -- run the \
             installer, or set YTDLP_INSTALL_ROOT to where it lives.",
            script.display()
        );
        finish(app, runner, rec);
        return;
    }

    // The log this run will write to. -Workers > 1 splits into
    // download.worker-<id>.log files instead, which the history row links to
    // by directory rather than by name.
    let data_root = opts
        .data_root
        .clone()
        .map(PathBuf::from)
        .unwrap_or_else(paths::install_root);
    rec.log_path = Some(
        data_root
            .join("Archive Logs")
            .join("Logs")
            .join("download.log")
            .to_string_lossy()
            .to_string(),
    );

    {
        let mut st = runner.state.lock().unwrap();
        st.log.clear();
        st.progress = Progress {
            stage: "starting".into(),
            ..Default::default()
        };
        st.current = Some(rec.clone());
    }
    runner.cancel.store(false, Ordering::Relaxed);
    emit_state(app, runner);

    let args = opts.to_args();
    let child = match spawn_child(&pwsh, &script, &args) {
        Ok(c) => c,
        Err(e) => {
            rec.state = "failed".into();
            rec.finished = Some(now_secs());
            rec.last_line = format!("could not start {}: {}", pwsh.display(), e);
            finish(app, runner, rec);
            return;
        }
    };
    let pid = child.id();
    {
        let mut st = runner.state.lock().unwrap();
        st.child_pid = Some(pid);
    }

    let mut child = child;
    let out = child.stdout.take();
    let err = child.stderr.take();
    let mut handles = Vec::new();
    if let Some(o) = out {
        let (a, r, id) = (app.clone(), runner.clone(), item.id.clone());
        handles.push(std::thread::spawn(move || pump(o, "stdout", id, a, r)));
    }
    if let Some(e) = err {
        let (a, r, id) = (app.clone(), runner.clone(), item.id.clone());
        handles.push(std::thread::spawn(move || pump(e, "stderr", id, a, r)));
    }

    let status = child.wait();
    for h in handles {
        let _ = h.join();
    }

    let cancelled = runner.cancel.swap(false, Ordering::Relaxed);
    let code = status.as_ref().ok().and_then(|s| s.code());

    {
        let st = runner.state.lock().unwrap();
        if let Some(cur) = &st.current {
            rec.videos_touched = cur.videos_touched;
            rec.archive_skipped = cur.archive_skipped;
            rec.errors = cur.errors;
            rec.warnings = cur.warnings;
            rec.last_line = cur.last_line.clone();
        }
    }
    rec.exit_code = code;
    rec.finished = Some(now_secs());
    rec.state = if cancelled {
        "cancelled".into()
    } else if code == Some(0) {
        "done".into()
    } else {
        "failed".into()
    };
    finish(app, runner, rec);
}

fn finish(app: &AppHandle, runner: &Arc<Runner>, rec: RunRecord) {
    {
        let mut st = runner.state.lock().unwrap();
        st.current = None;
        st.child_pid = None;
        st.progress = Progress::default();
        st.history.insert(0, rec);
        if st.history.len() > MAX_HISTORY {
            st.history.truncate(MAX_HISTORY);
        }
        persist(&st);
    }
    emit_state(app, runner);
}

// ---------------------------------------------------------------------------
// Public operations (called by the tauri commands in main.rs)
// ---------------------------------------------------------------------------

pub fn enqueue(app: &AppHandle, runner: &Arc<Runner>, opts: RunOptions) -> String {
    let id = format!("{:x}-{}", now_secs(), rand_suffix());
    {
        let mut st = runner.state.lock().unwrap();
        st.queue.push_back(QueueItem {
            id: id.clone(),
            opts,
            added: now_secs(),
        });
        persist(&st);
    }
    runner.wake.notify_all();
    emit_state(app, runner);
    id
}

pub fn cancel_current(app: &AppHandle, runner: &Arc<Runner>) -> bool {
    let pid = {
        let st = runner.state.lock().unwrap();
        st.child_pid
    };
    match pid {
        Some(p) => {
            runner.cancel.store(true, Ordering::Relaxed);
            kill_tree(p);
            emit_state(app, runner);
            true
        }
        None => false,
    }
}

pub fn remove_queued(app: &AppHandle, runner: &Arc<Runner>, id: &str) {
    {
        let mut st = runner.state.lock().unwrap();
        st.queue.retain(|q| q.id != id);
        persist(&st);
    }
    emit_state(app, runner);
}

pub fn set_paused(app: &AppHandle, runner: &Arc<Runner>, paused: bool) {
    {
        let mut st = runner.state.lock().unwrap();
        st.paused = paused;
    }
    runner.wake.notify_all();
    emit_state(app, runner);
}

pub fn clear_history(app: &AppHandle, runner: &Arc<Runner>) {
    {
        let mut st = runner.state.lock().unwrap();
        st.history.clear();
        persist(&st);
    }
    emit_state(app, runner);
}

pub fn snapshot(runner: &Runner) -> serde_json::Value {
    let st = runner.state.lock().unwrap();
    serde_json::json!({
        "queue": st.queue.iter().collect::<Vec<_>>(),
        "current": st.current,
        "history": st.history,
        "progress": st.progress,
        "paused": st.paused,
        "log": st.log,
    })
}

/// A short unique-enough suffix without pulling in a rand crate: the process
/// id plus a monotonic counter is sufficient for ids that only have to be
/// distinct within one history file.
fn rand_suffix() -> String {
    use std::sync::atomic::AtomicU64;
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{:x}{:x}", std::process::id(), n)
}
