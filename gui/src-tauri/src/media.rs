// Playback.
//
// The rule this file exists to enforce: NOTHING IS RE-ENCODED WITHOUT BEING
// ASKED, and nothing derived is ever written into the archive.
//
// .mkv cannot be played by any browser engine. But VP8/VP9/AV1 + Opus/Vorbis
// inside Matroska is byte-compatible with WebM, so the overwhelmingly common
// output of this pipeline's `-f bv*+ba/b` is served straight from the archive
// with a WebM content type and costs nothing. Anything MP4-copyable gets an
// on-demand `ffmpeg -c copy` remux into the cache. A real transcode is only
// ever offered explicitly, and is the only mode the UI makes you click.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter};

const WEBM_VIDEO: &[&str] = &["vp8", "vp9", "av1"];
const WEBM_AUDIO: &[&str] = &["opus", "vorbis"];
const MP4_VIDEO: &[&str] = &["h264", "hevc", "av1", "mpeg4"];
const MP4_AUDIO: &[&str] = &["aac", "mp3", "ac3", "alac"];

#[derive(Serialize, Clone, Debug, Default)]
pub struct StreamInfo {
    pub kind: String,
    pub codec: Option<String>,
    pub index: Option<i64>,
    pub lang: Option<String>,
    pub title: Option<String>,
    pub filename: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub channels: Option<i64>,
    pub attached_pic: bool,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct ProbeResult {
    pub ok: bool,
    pub video: Option<String>,
    pub audio: Option<String>,
    pub vindex: usize,
    pub aindex: usize,
    pub duration: Option<f64>,
    pub container: String,
    pub streams: Vec<StreamInfo>,
}

#[derive(Serialize, Clone, Debug)]
pub struct Plan {
    /// direct | remux | transcode | unsupported
    pub mode: String,
    pub mime: String,
    pub reason: String,
    #[serde(default)]
    pub uncertain: bool,
    pub profile: Option<String>,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct JobState {
    /// idle | running | ready | error
    pub state: String,
    pub progress: f64,
    pub error: Option<String>,
}

#[derive(Clone)]
pub struct TranscodeProfile {
    pub name: &'static str,
    pub ext: &'static str,
    pub mime: &'static str,
    pub vcodec: &'static str,
    pub acodec: &'static str,
}

pub struct Media {
    pub cache_dir: PathBuf,
    pub ffmpeg: Option<PathBuf>,
    pub ffprobe: Option<PathBuf>,
    pub allow_transcode: bool,
    probes: Mutex<HashMap<String, ProbeResult>>,
    encoders: Mutex<Option<Vec<String>>>,
    jobs: Mutex<HashMap<String, JobState>>,
}

impl Media {
    pub fn new(cache_dir: PathBuf, allow_transcode: bool) -> Self {
        Media {
            cache_dir,
            ffmpeg: crate::paths::which("ffmpeg"),
            ffprobe: crate::paths::which("ffprobe"),
            allow_transcode,
            probes: Mutex::new(HashMap::new()),
            encoders: Mutex::new(None),
            jobs: Mutex::new(HashMap::new()),
        }
    }

    fn stat_key(path: &Path) -> Option<String> {
        let md = std::fs::metadata(path).ok()?;
        let mtime = md
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Some(format!("{}:{}:{}", path.display(), md.len(), mtime))
    }

    pub fn probe(&self, path: &Path) -> ProbeResult {
        let Some(key) = Self::stat_key(path) else {
            return ProbeResult::default();
        };
        if let Some(hit) = self.probes.lock().unwrap().get(&key) {
            return hit.clone();
        }
        let mut result = ProbeResult::default();
        if let Some(ffprobe) = &self.ffprobe {
            let out = Command::new(ffprobe)
                .args(["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format"])
                .arg(path)
                .stderr(Stdio::null())
                .output();
            if let Ok(out) = out {
                if let Ok(data) = serde_json::from_slice::<Value>(&out.stdout) {
                    result.container = data
                        .get("format")
                        .and_then(|f| f.get("format_name"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    result.duration = data
                        .get("format")
                        .and_then(|f| f.get("duration"))
                        .and_then(|v| v.as_str())
                        .and_then(|s| s.parse::<f64>().ok());
                    let mut vcount = 0usize;
                    let mut acount = 0usize;
                    if let Some(streams) = data.get("streams").and_then(|s| s.as_array()) {
                        for s in streams {
                            let kind = s.get("codec_type").and_then(|v| v.as_str()).unwrap_or("");
                            let tags = s.get("tags");
                            let mut info = StreamInfo {
                                kind: kind.to_string(),
                                codec: s.get("codec_name").and_then(|v| v.as_str()).map(String::from),
                                index: s.get("index").and_then(|v| v.as_i64()),
                                lang: tags
                                    .and_then(|t| t.get("language"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                title: tags
                                    .and_then(|t| t.get("title"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                filename: tags
                                    .and_then(|t| t.get("filename"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                ..Default::default()
                            };
                            if kind == "video" {
                                // --embed-thumbnail leaves a cover image behind
                                // as a video stream on some containers. Picking
                                // it as "the" video stream would remux a still.
                                let attached = s
                                    .get("disposition")
                                    .and_then(|d| d.get("attached_pic"))
                                    .and_then(|v| v.as_i64())
                                    .unwrap_or(0)
                                    != 0;
                                info.attached_pic = attached;
                                info.width = s.get("width").and_then(|v| v.as_i64());
                                info.height = s.get("height").and_then(|v| v.as_i64());
                                if !attached {
                                    if result.video.is_none() {
                                        result.video =
                                            info.codec.clone().map(|c| c.to_lowercase());
                                        result.vindex = vcount;
                                    }
                                    vcount += 1;
                                }
                            } else if kind == "audio" {
                                info.channels = s.get("channels").and_then(|v| v.as_i64());
                                if result.audio.is_none() {
                                    result.audio = info.codec.clone().map(|c| c.to_lowercase());
                                    result.aindex = acount;
                                }
                                acount += 1;
                            }
                            result.streams.push(info);
                        }
                    }
                    result.ok = true;
                }
            }
        }
        self.probes.lock().unwrap().insert(key, result.clone());
        result
    }

    fn encoder_list(&self) -> Vec<String> {
        let mut guard = self.encoders.lock().unwrap();
        if let Some(list) = guard.as_ref() {
            return list.clone();
        }
        let mut list = Vec::new();
        if let Some(ffmpeg) = &self.ffmpeg {
            if let Ok(out) = Command::new(ffmpeg)
                .args(["-hide_banner", "-encoders"])
                .stderr(Stdio::null())
                .output()
            {
                let text = String::from_utf8_lossy(&out.stdout);
                for line in text.lines() {
                    if let Some(name) = line.split_whitespace().nth(1) {
                        list.push(name.to_string());
                    }
                }
            }
        }
        *guard = Some(list.clone());
        list
    }

    pub fn transcode_profile(&self) -> Option<TranscodeProfile> {
        let enc = self.encoder_list();
        let has = |n: &str| enc.iter().any(|e| e == n);
        if has("libx264") {
            return Some(TranscodeProfile {
                name: "H.264 / AAC (MP4)",
                ext: "mp4",
                mime: "video/mp4",
                vcodec: "libx264",
                acodec: "aac",
            });
        }
        if has("libopenh264") {
            return Some(TranscodeProfile {
                name: "H.264 (OpenH264) / AAC (MP4)",
                ext: "mp4",
                mime: "video/mp4",
                vcodec: "libopenh264",
                acodec: "aac",
            });
        }
        if has("libvpx-vp9") {
            return Some(TranscodeProfile {
                name: "VP9 / Opus (WebM)",
                ext: "webm",
                mime: "video/webm",
                vcodec: "libvpx-vp9",
                acodec: "libopus",
            });
        }
        None
    }

    pub fn plan(&self, path: &Path) -> Plan {
        let ext = path
            .extension()
            .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
            .unwrap_or_default();
        if [".mp4", ".m4v", ".webm"].contains(&ext.as_str()) {
            return Plan {
                mode: "direct".into(),
                mime: if ext == ".webm" { "video/webm".into() } else { "video/mp4".into() },
                reason: "Container is natively supported.".into(),
                uncertain: false,
                profile: None,
            };
        }
        let probe = self.probe(path);
        let v = probe.video.clone().unwrap_or_default();
        let a = probe.audio.clone().unwrap_or_default();
        if !probe.ok {
            // No ffprobe. .mkv out of this pipeline is very often VP9/Opus, so
            // offering the WebM gamble beats refusing to play anything -- but
            // say so honestly rather than letting it fail silently.
            return Plan {
                mode: "direct".into(),
                mime: "video/webm".into(),
                reason: "ffprobe unavailable -- serving the .mkv as WebM. This works if the \
                         streams are VP9/AV1 + Opus and silently fails otherwise."
                    .into(),
                uncertain: true,
                profile: None,
            };
        }
        if WEBM_VIDEO.contains(&v.as_str()) && WEBM_AUDIO.contains(&a.as_str()) {
            return Plan {
                mode: "direct".into(),
                mime: "video/webm".into(),
                reason: format!(
                    "{} + {} in Matroska is byte-compatible with WebM, so it streams straight \
                     from the archive.",
                    v, a
                ),
                uncertain: false,
                profile: None,
            };
        }
        if MP4_VIDEO.contains(&v.as_str()) && MP4_AUDIO.contains(&a.as_str()) {
            return Plan {
                mode: "remux".into(),
                mime: "video/mp4".into(),
                reason: format!(
                    "{} + {} can be copied into MP4 without re-encoding.",
                    if v.is_empty() { "?" } else { &v },
                    if a.is_empty() { "?" } else { &a }
                ),
                uncertain: false,
                profile: None,
            };
        }
        let why = format!(
            "{} + {} cannot be copied into a browser-playable container; playing it here needs a \
             real re-encode.",
            if v.is_empty() { "?" } else { &v },
            if a.is_empty() { "?" } else { &a }
        );
        if !self.allow_transcode {
            return Plan {
                mode: "unsupported".into(),
                mime: "video/mp4".into(),
                reason: why,
                uncertain: false,
                profile: None,
            };
        }
        match self.transcode_profile() {
            Some(p) => Plan {
                mode: "transcode".into(),
                mime: p.mime.into(),
                reason: format!("{} Re-encoding as {}.", why, p.name),
                uncertain: false,
                profile: Some(p.name.into()),
            },
            // Better to say this than to offer a button that fails on click.
            None => Plan {
                mode: "unsupported".into(),
                mime: "video/mp4".into(),
                reason: format!(
                    "{} This ffmpeg build has no encoder this app can use -- on Fedora and \
                     similar, install the full ffmpeg (RPM Fusion) or a build with libx264, \
                     libopenh264 or libvpx.",
                    why
                ),
                uncertain: false,
                profile: None,
            },
        }
    }

    pub fn output_path(&self, key: &str, mode: &str) -> PathBuf {
        // Remux is only ever chosen for MP4-copyable streams, so it is always
        // .mp4. Transcode follows whichever profile this build resolved to,
        // which may be WebM -- the extension has to match or the file gets
        // served with the wrong type.
        let mut ext = "mp4";
        if mode == "webm" {
            ext = "webm";
        } else if mode == "transcode" {
            if let Some(p) = self.transcode_profile() {
                ext = p.ext;
            }
        }
        self.cache_dir.join("media").join(format!("{}.{}.{}", key, mode, ext))
    }

    /// True when this file's streams are WebM-compatible but its CONTAINER
    /// says otherwise, which is the single most common playback failure this
    /// archive produces.
    ///
    /// `--merge-output-format mkv` writes an EBML header whose DocType is
    /// "matroska". VP9 + Opus inside it is byte-identical to what a .webm
    /// would hold, so the STREAMS need nothing done to them -- but a strict
    /// demuxer reads DocType before it reads codecs and refuses the file. A
    /// `-c copy` into .webm rewrites that header and copies every packet
    /// untouched: no re-encode, no quality loss, seconds rather than minutes.
    ///
    /// Found by a real player refusing a real file: the webview asked for
    /// exactly one 1446-byte range, read the header, and never asked again.
    pub fn needs_webm_container(&self, path: &Path) -> bool {
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        if ext != "mkv" {
            return false;
        }
        let probe = self.probe(path);
        if !probe.ok {
            return false;
        }
        let v = probe.video.unwrap_or_default();
        let a = probe.audio.unwrap_or_default();
        WEBM_VIDEO.contains(&v.as_str()) && WEBM_AUDIO.contains(&a.as_str())
    }

    pub fn status(&self, key: &str, src: &Path, mode: &str) -> JobState {
        let out = self.output_path(key, mode);
        if let (Ok(om), Ok(sm)) = (std::fs::metadata(&out), std::fs::metadata(src)) {
            let (Ok(ot), Ok(st)) = (om.modified(), sm.modified()) else {
                return JobState { state: "idle".into(), ..Default::default() };
            };
            if om.len() > 0 && ot >= st {
                return JobState { state: "ready".into(), progress: 1.0, error: None };
            }
        }
        self.jobs
            .lock()
            .unwrap()
            .get(&format!("{}|{}", key, mode))
            .cloned()
            .unwrap_or(JobState { state: "idle".into(), ..Default::default() })
    }

    pub fn start(
        self: &Arc<Self>,
        app: AppHandle,
        key: String,
        src: PathBuf,
        mode: String,
        duration: Option<f64>,
    ) -> JobState {
        let job_key = format!("{}|{}", key, mode);
        {
            let mut jobs = self.jobs.lock().unwrap();
            if let Some(j) = jobs.get(&job_key) {
                if j.state == "running" {
                    return j.clone();
                }
            }
            jobs.insert(
                job_key.clone(),
                JobState { state: "running".into(), progress: 0.0, error: None },
            );
        }
        let me = self.clone();
        std::thread::spawn(move || {
            let result = me.run_ffmpeg(&app, &key, &src, &mode, duration);
            let state = match result {
                Ok(()) => JobState { state: "ready".into(), progress: 1.0, error: None },
                Err(e) => JobState { state: "error".into(), progress: 0.0, error: Some(e) },
            };
            me.jobs.lock().unwrap().insert(job_key.clone(), state.clone());
            let _ = app.emit(
                "media-progress",
                serde_json::json!({ "key": key, "mode": mode, "status": state }),
            );
        });
        JobState { state: "running".into(), progress: 0.0, error: None }
    }

    fn run_ffmpeg(
        &self,
        app: &AppHandle,
        key: &str,
        src: &Path,
        mode: &str,
        duration: Option<f64>,
    ) -> Result<(), String> {
        let ffmpeg = self.ffmpeg.as_ref().ok_or("ffmpeg is not installed")?;
        let out = self.output_path(key, mode);
        std::fs::create_dir_all(out.parent().ok_or("bad cache path")?)
            .map_err(|e| e.to_string())?;
        // The temp file KEEPS the real extension: "<key>.webm.part.webm",
        // not "<key>.webm.part". ffmpeg picks its muxer from the output
        // file's extension, so a bare ".part" makes it fail with "Error
        // opening output files: Invalid argument" -- which is what it does,
        // rather than saying it could not determine a format. Written to a
        // temp name and renamed only on success, so a half-written file is
        // never served.
        let ext = out
            .extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_else(|| "mp4".into());
        let tmp = out.with_extension(format!("part.{}", ext));
        let probe = self.probe(src);

        let mut cmd = Command::new(ffmpeg);
        cmd.args(["-y", "-nostdin", "-loglevel", "error", "-progress", "pipe:1"]);
        cmd.arg("-i").arg(src);
        // Explicit stream selection: the archive's .mkv routinely carries an
        // attached thumbnail and several subtitle tracks, and ffmpeg's default
        // mapping would drag them into a container that cannot hold them.
        cmd.args(["-map", &format!("0:v:{}", probe.vindex)]);
        cmd.args(["-map", &format!("0:a:{}?", probe.aindex)]);
        if mode == "webm" {
            // Container rewrite only. Every packet is copied verbatim; the
            // only thing that changes is the EBML DocType.
            cmd.args(["-c", "copy"]);
        } else if mode == "remux" {
            cmd.args(["-c", "copy", "-movflags", "+faststart"]);
        } else {
            let p = self.transcode_profile().ok_or("no usable encoder in this ffmpeg build")?;
            cmd.args(["-c:v", p.vcodec, "-c:a", p.acodec]);
            if p.ext == "mp4" {
                cmd.args(["-preset", "veryfast", "-crf", "23", "-movflags", "+faststart"]);
            } else {
                cmd.args(["-b:v", "0", "-crf", "34", "-row-mt", "1"]);
            }
        }
        cmd.arg(&tmp);
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(Stdio::null());

        let mut child = cmd.spawn().map_err(|e| format!("could not start ffmpeg: {}", e))?;
        if let Some(stdout) = child.stdout.take() {
            use std::io::{BufRead, BufReader};
            let total = duration.or(probe.duration).unwrap_or(0.0);
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                if let Some(v) = line.strip_prefix("out_time_ms=") {
                    if total > 0.0 {
                        if let Ok(us) = v.trim().parse::<f64>() {
                            let frac = ((us / 1_000_000.0) / total).clamp(0.0, 0.999);
                            self.jobs.lock().unwrap().insert(
                                format!("{}|{}", key, mode),
                                JobState { state: "running".into(), progress: frac, error: None },
                            );
                            let _ = app.emit(
                                "media-progress",
                                serde_json::json!({
                                    "key": key, "mode": mode,
                                    "status": { "state": "running", "progress": frac }
                                }),
                            );
                        }
                    }
                }
            }
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        if !status.success() {
            let mut err = String::new();
            if let Some(mut se) = child.stderr.take() {
                use std::io::Read;
                let _ = se.read_to_string(&mut err);
            }
            let _ = std::fs::remove_file(&tmp);
            return Err(if err.trim().is_empty() {
                format!("ffmpeg exited with {}", status)
            } else {
                err.lines().last().unwrap_or("ffmpeg failed").to_string()
            });
        }
        // Swapped in only on success, so a half-written file is never served.
        std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
        Ok(())
    }
}

pub fn guess_mime(path: &Path) -> &'static str {
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "mkv" => "video/webm",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "avif" => "image/avif",
        "vtt" => "text/vtt",
        "srt" => "text/plain",
        "json" | "info" => "application/json",
        "txt" | "description" => "text/plain",
        "m4a" | "mp3" => "audio/mpeg",
        "opus" | "ogg" => "audio/ogg",
        _ => "application/octet-stream",
    }
}
