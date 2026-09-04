// The archive index.
//
// A native reimplementation of what archive-viewer.py's Index/VideoEntry do,
// and it has to stay behaviourally equivalent to them, because both read the
// same on-disk layout produced by postprocess.ps1:
//
//   Complete Archive/<Uploader>/<Uploader> - <date> - <id> - <title>/
//       Final files/  Pre-merge streams/  Subtitles/  Images/  URLs/  Logs/
//       Video metadata/{Info.info.json, manifest.json, checksums.sha256, ...}
//
// THE DIRECTORY DEPTH IS LOAD-BEARING. Changing an -o template in
// yt-dlp.conf breaks discovery here exactly as it breaks postprocess.ps1's
// path derivation and the Python viewer's discovery.
//
// Three states a real run actually produces, all of which are tolerated:
// a missing or unparseable info.json (fall back to parsing the folder name),
// a folder with no video file at all, and Pre-merge streams/ -- which is
// skipped when choosing the video, since --keep-video leaves video-only and
// audio-only files that would otherwise be mistaken for the real one.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::paths;

pub const VIDEO_EXTS: &[&str] = &[".mkv", ".mp4", ".webm", ".m4v", ".mov", ".avi", ".flv", ".ts"];
pub const IMAGE_EXTS: &[&str] = &[".png", ".webp", ".jpg", ".jpeg", ".gif", ".avif"];
pub const SUB_EXTS: &[&str] = &[
    ".vtt", ".srt", ".ass", ".ssa", ".lrc", ".json3", ".srv1", ".srv2", ".srv3", ".ttml",
];

/// info.json keys that are enormous and useless in a metadata panel. Dropped
/// from the cached copy; the UI says which were dropped rather than pretending
/// the field never existed.
const HEAVY_INFO_KEYS: &[&str] = &[
    "comments",
    "formats",
    "automatic_captions",
    "heatmap",
    "thumbnails",
    "subtitles",
];

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FileRec {
    pub rel: String,
    pub size: u64,
    pub ext: String,
    pub folder: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Light {
    #[serde(default)]
    pub sig: String,
    pub key: String,
    pub rel: String,
    pub folder_name: String,
    pub channel_folder: String,
    pub id: Option<String>,
    pub title: String,
    pub uploader: String,
    pub channel_url: Option<String>,
    pub upload_date: Option<String>,
    pub timestamp: Option<i64>,
    pub duration: Option<f64>,
    pub view_count: Option<i64>,
    pub like_count: Option<i64>,
    pub comment_count: Option<i64>,
    pub comments_cached: usize,
    pub description: String,
    pub categories: Vec<String>,
    pub tags: Vec<String>,
    pub chapters: Value,
    pub webpage_url: Option<String>,
    pub resolution: Option<String>,
    pub fps: Option<f64>,
    pub vcodec: Option<String>,
    pub acodec: Option<String>,
    pub live_status: Option<String>,
    pub age_limit: Option<i64>,
    pub language: Option<String>,
    pub has_info_json: bool,
    pub dropped_keys: Vec<String>,
    pub files: Vec<FileRec>,
}

#[derive(Clone, Debug)]
pub struct Entry {
    pub key: String,
    pub dir: PathBuf,
    pub rel: String,
    pub channel: String,
    pub cache_dir: PathBuf,
    pub light: Light,
}

impl Entry {
    /// Resolve a client-supplied file index to a real path. The index came
    /// from our own list, but the resolved path is re-checked against the
    /// video folder anyway -- a symlink inside the archive could otherwise
    /// point anywhere.
    pub fn path_for_index(&self, idx: usize) -> Option<PathBuf> {
        let rec = self.light.files.get(idx)?;
        let candidate = self.dir.join(rec.rel.replace('/', std::path::MAIN_SEPARATOR_STR));
        let resolved = candidate.canonicalize().ok()?;
        let base = self.dir.canonicalize().ok()?;
        if !resolved.starts_with(&base) {
            return None;
        }
        if resolved.is_file() {
            Some(resolved)
        } else {
            None
        }
    }

    pub fn find<F: Fn(&FileRec) -> bool>(&self, pred: F) -> Option<(usize, &FileRec)> {
        self.light.files.iter().enumerate().find(|(_, f)| pred(f))
    }

    /// The playable video, skipping Pre-merge streams/ -- see the module note.
    pub fn video_index(&self) -> Option<usize> {
        self.find(|f| {
            VIDEO_EXTS.contains(&f.ext.as_str()) && !f.folder.to_lowercase().contains("pre-merge")
        })
        .map(|(i, _)| i)
    }

    pub fn thumbnail_index(&self) -> Option<usize> {
        self.find(|f| IMAGE_EXTS.contains(&f.ext.as_str()) && f.rel.to_lowercase().contains("thumbnail"))
            .or_else(|| self.find(|f| IMAGE_EXTS.contains(&f.ext.as_str())))
            .map(|(i, _)| i)
    }
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct ChannelInfo {
    pub name: String,
    pub count: usize,
    pub url: Option<String>,
    pub avatar_key: Option<String>,
    pub avatar_idx: Option<usize>,
    pub description: Option<String>,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct LibraryItem {
    pub key: String,
    pub id: Option<String>,
    pub title: String,
    pub uploader: String,
    pub channel_folder: String,
    pub upload_date: Option<String>,
    pub duration: Option<f64>,
    pub view_count: Option<i64>,
    pub comment_count: Option<i64>,
    pub comments_cached: usize,
    pub thumb_idx: Option<usize>,
    pub video_idx: Option<usize>,
    pub subtitle_count: usize,
    pub file_count: usize,
    pub total_bytes: u64,
    pub has_info_json: bool,
    pub folder_name: String,
}

#[derive(Default)]
pub struct Index {
    pub root: Option<PathBuf>,
    pub cache_dir: PathBuf,
    pub entries: HashMap<String, Entry>,
    pub order: Vec<String>,
    pub channels: Vec<ChannelInfo>,
    pub last_error: Option<String>,
}

fn ext_of(p: &Path) -> String {
    p.extension()
        .map(|e| format!(".{}", e.to_string_lossy().to_lowercase()))
        .unwrap_or_default()
}

fn walk_files(base: &Path, dir: &Path, out: &mut Vec<FileRec>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut children: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
    children.sort();
    for path in children {
        if path.is_dir() {
            walk_files(base, &path, out);
        } else if path.is_file() {
            let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            let rel = path
                .strip_prefix(base)
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .unwrap_or_default();
            let folder = path
                .parent()
                .and_then(|p| p.strip_prefix(base).ok())
                .map(|p| {
                    let s = p.to_string_lossy().replace('\\', "/");
                    if s.is_empty() {
                        ".".to_string()
                    } else {
                        s
                    }
                })
                .unwrap_or_else(|| ".".into());
            out.push(FileRec {
                rel,
                size,
                ext: ext_of(&path),
                folder,
            });
        }
    }
}

/// Cheap change-detector for a video folder: name+size+mtime of the files the
/// cache is derived from, so a 40 MB info.json is not re-parsed on every start
/// while a re-download that replaced it is still noticed.
fn signature(info_path: Option<&Path>, dir: &Path, file_count: usize) -> String {
    let mut parts: Vec<String> = Vec::new();
    for p in [info_path, Some(dir)].into_iter().flatten() {
        if let Ok(md) = fs::metadata(p) {
            let mtime = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            parts.push(format!(
                "{}:{}:{}",
                p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
                md.len(),
                mtime
            ));
        }
    }
    parts.push(format!("n={}", file_count));
    paths::key_for(&parts.join("|"))
}

fn read_text_limited(path: &Path, limit: usize) -> String {
    let Ok(mut fh) = fs::File::open(path) else {
        return String::new();
    };
    let mut buf = Vec::new();
    let _ = fh.by_ref().take(limit as u64).read_to_end(&mut buf);
    String::from_utf8_lossy(&buf).to_string()
}

fn json_str(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(|s| s.to_string())
}

fn json_i64(v: &Value, key: &str) -> Option<i64> {
    v.get(key).and_then(|x| x.as_i64())
}

fn json_f64(v: &Value, key: &str) -> Option<f64> {
    v.get(key).and_then(|x| x.as_f64())
}

fn json_str_vec(v: &Value, key: &str) -> Vec<String> {
    v.get(key)
        .and_then(|x| x.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|e| e.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// '<uploader> - <yyyymmdd> - <id> - <title>'. A documented, stable part of
/// this pipeline's layout, so parsing it is a genuine fallback source of
/// truth rather than a guess -- it is what a folder whose info.json was lost
/// still knows about itself.
fn parse_folder_name(name: &str) -> Option<(String, String, String, String)> {
    let parts: Vec<&str> = name.splitn(4, " - ").collect();
    if parts.len() != 4 {
        return None;
    }
    let date = parts[1];
    if date.len() != 8 || !date.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    if parts[2].contains(' ') {
        return None;
    }
    Some((
        parts[0].to_string(),
        date.to_string(),
        parts[2].to_string(),
        parts[3].to_string(),
    ))
}

impl Index {
    pub fn new(cache_dir: PathBuf) -> Self {
        Index {
            root: None,
            cache_dir,
            ..Default::default()
        }
    }

    fn discover_dirs(root: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        let Ok(rd) = fs::read_dir(root) else {
            return out;
        };
        let mut channels: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
        channels.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default());
        for channel in channels {
            let Ok(rd) = fs::read_dir(&channel) else { continue };
            let mut vids: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
            vids.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default());
            for vd in vids {
                if vd.file_name().map(|n| n == "Channel Info").unwrap_or(false) {
                    continue;
                }
                if vd.join("Video metadata").is_dir() || vd.join("Final files").is_dir() {
                    out.push(vd);
                    continue;
                }
                // Tolerate a flatter layout (an older pipeline version, or
                // someone reorganised): any folder directly holding a video
                // file counts.
                if let Ok(inner) = fs::read_dir(&vd) {
                    let has_video = inner.flatten().any(|e| {
                        let p = e.path();
                        p.is_file() && VIDEO_EXTS.contains(&ext_of(&p).as_str())
                    });
                    if has_video {
                        out.push(vd);
                    }
                }
            }
        }
        out
    }

    /// Full rescan. `force` ignores the cached light.json for every video and
    /// re-reads its info.json, which is the expensive path -- it exists for
    /// "the index looks wrong", not for routine refreshes, where the
    /// signature check already catches anything that changed.
    pub fn scan<F: FnMut(usize, usize, &str)>(
        &mut self,
        root: PathBuf,
        force: bool,
        mut progress: F,
    ) -> Result<(), String> {
        let dirs = Self::discover_dirs(&root);
        let total = dirs.len();
        let mut entries = HashMap::new();
        let mut order = Vec::new();
        for (i, vd) in dirs.iter().enumerate() {
            let name = vd.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            progress(i, total, &name);
            match self.build_entry(&root, vd, force) {
                Ok(entry) => {
                    order.push(entry.key.clone());
                    entries.insert(entry.key.clone(), entry);
                }
                Err(e) => eprintln!("[index] skipping {}: {}", name, e),
            }
        }
        progress(total, total, "");
        self.root = Some(root);
        self.entries = entries;
        self.order = order;
        self.channels = self.build_channels();
        self.last_error = None;
        Ok(())
    }

    fn build_channels(&self) -> Vec<ChannelInfo> {
        let mut map: HashMap<String, ChannelInfo> = HashMap::new();
        let mut names: Vec<String> = Vec::new();
        for key in &self.order {
            let Some(e) = self.entries.get(key) else { continue };
            let c = map.entry(e.channel.clone()).or_insert_with(|| {
                names.push(e.channel.clone());
                ChannelInfo {
                    name: e.channel.clone(),
                    ..Default::default()
                }
            });
            c.count += 1;
            if c.url.is_none() {
                c.url = e.light.channel_url.clone();
            }
            // The avatar is addressed the same way every other file is: an
            // existing video's key plus an index into its file list. Channel
            // Info/ is not a video folder and has no key of its own, so the
            // alternative would have been a second addressing scheme.
            if c.avatar_key.is_none() {
                if let Some(root) = &self.root {
                    let cdir = root.join(&e.channel).join("Channel Info");
                    if let Some((k, idx, desc)) = channel_assets(&cdir, e) {
                        c.avatar_key = k;
                        c.avatar_idx = idx;
                        if c.description.is_none() {
                            c.description = desc;
                        }
                    }
                }
            }
        }
        let mut out: Vec<ChannelInfo> = names.into_iter().filter_map(|n| map.remove(&n)).collect();
        out.sort_by_key(|c| c.name.to_lowercase());
        out
    }

    fn build_entry(&self, root: &Path, video_dir: &Path, force: bool) -> Result<Entry, String> {
        let rel = video_dir
            .strip_prefix(root)
            .map_err(|_| "outside archive root".to_string())?
            .to_string_lossy()
            .replace('\\', "/");
        let key = paths::key_for(&rel);
        let channel = video_dir
            .parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();

        let mut files = Vec::new();
        walk_files(video_dir, video_dir, &mut files);

        let info_rel = files
            .iter()
            .find(|f| f.rel.ends_with(".info.json"))
            .map(|f| f.rel.clone());
        let info_path = info_rel
            .as_ref()
            .map(|r| video_dir.join(r.replace('/', std::path::MAIN_SEPARATOR_STR)));

        let sig = signature(info_path.as_deref(), video_dir, files.len());
        let cache_dir = self.cache_dir.join("videos").join(&key);

        let light_path = cache_dir.join("light.json");
        let cached: Option<Light> = if force {
            None
        } else {
            fs::read_to_string(&light_path)
                .ok()
                .and_then(|s| serde_json::from_str::<Light>(&s).ok())
                .filter(|l| l.sig == sig)
        };

        let light = match cached {
            Some(l) => l,
            None => Self::rebuild_cache(
                &cache_dir, &key, &rel, video_dir, &channel, info_path.as_deref(), files, sig,
            )?,
        };

        Ok(Entry {
            key,
            dir: video_dir.to_path_buf(),
            rel,
            channel,
            cache_dir,
            light,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn rebuild_cache(
        cache_dir: &Path,
        key: &str,
        rel: &str,
        dir: &Path,
        channel: &str,
        info_path: Option<&Path>,
        files: Vec<FileRec>,
        sig: String,
    ) -> Result<Light, String> {
        fs::create_dir_all(cache_dir).map_err(|e| e.to_string())?;

        let info: Value = info_path
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .unwrap_or_else(|| json!({}));

        // Comments go to their own file so a 40 MB info.json is never re-read
        // to answer a comments request.
        let comments = info
            .get("comments")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default();
        let comments_cached = comments.len();
        if let Err(e) = fs::write(
            cache_dir.join("comments.json"),
            serde_json::to_vec(&comments).unwrap_or_else(|_| b"[]".to_vec()),
        ) {
            eprintln!("[index] could not cache comments for {}: {}", rel, e);
        }

        let mut stripped = Map::new();
        let mut dropped = Vec::new();
        if let Some(obj) = info.as_object() {
            for (k, v) in obj {
                if HEAVY_INFO_KEYS.contains(&k.as_str()) {
                    let non_empty = match v {
                        Value::Null => false,
                        Value::Array(a) => !a.is_empty(),
                        Value::Object(o) => !o.is_empty(),
                        Value::String(s) => !s.is_empty(),
                        _ => true,
                    };
                    if non_empty {
                        dropped.push(k.clone());
                    }
                    continue;
                }
                stripped.insert(k.clone(), v.clone());
            }
        }
        if let Err(e) = fs::write(
            cache_dir.join("info.json"),
            serde_json::to_vec(&json!({ "info": Value::Object(stripped), "dropped": dropped }))
                .unwrap_or_else(|_| b"{}".to_vec()),
        ) {
            eprintln!("[index] could not cache metadata for {}: {}", rel, e);
        }

        let folder_name = dir
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();

        let mut title = json_str(&info, "title");
        let mut upload_date = json_str(&info, "upload_date");
        let mut video_id = json_str(&info, "id");
        let mut uploader = json_str(&info, "uploader").or_else(|| json_str(&info, "channel"));
        if title.is_none() || upload_date.is_none() || video_id.is_none() {
            if let Some((u, d, i, t)) = parse_folder_name(&folder_name) {
                uploader = uploader.or(Some(u));
                upload_date = upload_date.or(Some(d));
                video_id = video_id.or(Some(i));
                title = title.or(Some(t));
            }
        }

        let mut description = json_str(&info, "description").unwrap_or_default();
        if description.is_empty() {
            // A run that lost its info.json still has the .description file,
            // and it is the same text.
            if let Some(f) = files.iter().find(|f| f.rel.ends_with(".description")) {
                description = read_text_limited(
                    &dir.join(f.rel.replace('/', std::path::MAIN_SEPARATOR_STR)),
                    200_000,
                );
            }
        }

        let light = Light {
            sig,
            key: key.to_string(),
            rel: rel.to_string(),
            folder_name: folder_name.clone(),
            channel_folder: channel.to_string(),
            id: video_id,
            title: title.unwrap_or(folder_name),
            uploader: uploader.unwrap_or_else(|| channel.to_string()),
            channel_url: json_str(&info, "channel_url").or_else(|| json_str(&info, "uploader_url")),
            upload_date,
            timestamp: json_i64(&info, "timestamp").or_else(|| json_i64(&info, "release_timestamp")),
            duration: json_f64(&info, "duration"),
            view_count: json_i64(&info, "view_count"),
            like_count: json_i64(&info, "like_count"),
            comment_count: json_i64(&info, "comment_count").or(Some(comments_cached as i64)),
            comments_cached,
            description,
            categories: json_str_vec(&info, "categories"),
            tags: json_str_vec(&info, "tags"),
            chapters: info.get("chapters").cloned().unwrap_or(Value::Null),
            webpage_url: json_str(&info, "webpage_url").or_else(|| json_str(&info, "original_url")),
            resolution: json_str(&info, "resolution"),
            fps: json_f64(&info, "fps"),
            vcodec: json_str(&info, "vcodec"),
            acodec: json_str(&info, "acodec"),
            live_status: json_str(&info, "live_status"),
            age_limit: json_i64(&info, "age_limit"),
            language: json_str(&info, "language"),
            has_info_json: info_path.is_some(),
            dropped_keys: dropped,
            files,
        };

        if let Err(e) = fs::write(
            cache_dir.join("light.json"),
            serde_json::to_vec(&light).unwrap_or_else(|_| b"{}".to_vec()),
        ) {
            eprintln!("[index] could not write index cache for {}: {}", rel, e);
        }
        Ok(light)
    }

    pub fn get(&self, key: &str) -> Option<&Entry> {
        self.entries.get(key)
    }

    pub fn library(&self) -> Vec<LibraryItem> {
        self.order
            .iter()
            .filter_map(|k| self.entries.get(k))
            .map(|e| LibraryItem {
                key: e.key.clone(),
                id: e.light.id.clone(),
                title: e.light.title.clone(),
                uploader: e.light.uploader.clone(),
                channel_folder: e.channel.clone(),
                upload_date: e.light.upload_date.clone(),
                duration: e.light.duration,
                view_count: e.light.view_count,
                comment_count: e.light.comment_count,
                comments_cached: e.light.comments_cached,
                thumb_idx: e.thumbnail_index(),
                video_idx: e.video_index(),
                subtitle_count: e
                    .light
                    .files
                    .iter()
                    .filter(|f| SUB_EXTS.contains(&f.ext.as_str()))
                    .count(),
                file_count: e.light.files.len(),
                total_bytes: e.light.files.iter().map(|f| f.size).sum(),
                has_info_json: e.light.has_info_json,
                folder_name: e.light.folder_name.clone(),
            })
            .collect()
    }
}

/// Channel Info/ holds avatar/banner/description, refreshed by
/// postprocess.ps1 on a 6h throttle. It is not a video folder, so its files
/// are surfaced through a neighbouring video's key rather than getting an
/// addressing scheme of their own -- see build_channels.
fn channel_assets(cdir: &Path, _entry: &Entry) -> Option<(Option<String>, Option<usize>, Option<String>)> {
    if !cdir.is_dir() {
        return None;
    }
    let mut description = None;
    let rd = fs::read_dir(cdir).ok()?;
    for e in rd.flatten() {
        let p = e.path();
        let name = p.file_name()?.to_string_lossy().to_lowercase();
        if (name.ends_with(".description") || name.ends_with(".txt")) && description.is_none() {
            description = Some(read_text_limited(&p, 20_000));
        }
    }
    Some((None, None, description))
}

// ---------------------------------------------------------------------------
// Comments
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone, Debug)]
pub struct Comment {
    pub id: String,
    pub text: String,
    pub author: String,
    pub author_id: Option<String>,
    pub author_thumbnail: Option<String>,
    pub timestamp: Option<i64>,
    pub time_text: Option<String>,
    pub like_count: Option<i64>,
    pub is_favorited: bool,
    pub author_is_uploader: bool,
    pub is_pinned: bool,
    pub replies: Vec<Comment>,
}

fn comment_from(v: &Value) -> Comment {
    Comment {
        id: json_str(v, "id").unwrap_or_default(),
        text: json_str(v, "text").unwrap_or_default(),
        author: json_str(v, "author").unwrap_or_else(|| "(unknown)".into()),
        author_id: json_str(v, "author_id"),
        author_thumbnail: json_str(v, "author_thumbnail"),
        timestamp: json_i64(v, "timestamp"),
        time_text: json_str(v, "_time_text"),
        like_count: json_i64(v, "like_count"),
        is_favorited: v.get("is_favorited").and_then(|x| x.as_bool()).unwrap_or(false),
        author_is_uploader: v
            .get("author_is_uploader")
            .and_then(|x| x.as_bool())
            .unwrap_or(false),
        is_pinned: v.get("is_pinned").and_then(|x| x.as_bool()).unwrap_or(false),
        replies: Vec::new(),
    }
}

/// yt-dlp writes comments as a FLAT list with a `parent` field that is either
/// "root" or the parent comment's id, in no guaranteed order -- so a reply can
/// appear before its parent, and re-threading is a two-pass job, not a fold.
pub fn thread_comments(raw: &[Value]) -> Vec<Comment> {
    let mut tops: Vec<Comment> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut orphan_replies: Vec<(String, Comment)> = Vec::new();

    for v in raw {
        let parent = json_str(v, "parent").unwrap_or_else(|| "root".into());
        let c = comment_from(v);
        if parent == "root" || parent.is_empty() {
            index.insert(c.id.clone(), tops.len());
            tops.push(c);
        } else {
            orphan_replies.push((parent, c));
        }
    }
    for (parent, c) in orphan_replies {
        // yt-dlp's reply ids are "<parent>.<reply>", so the parent id is
        // recoverable even when the parent field itself is unhelpful.
        let target = index.get(&parent).copied().or_else(|| {
            parent
                .split('.')
                .next()
                .and_then(|p| index.get(p))
                .copied()
        });
        match target {
            Some(i) => tops[i].replies.push(c),
            // A reply whose parent is genuinely absent (a deleted comment,
            // or a truncated fetch) is shown at top level rather than
            // dropped -- silently losing archived text would be worse.
            None => tops.push(c),
        }
    }
    for t in tops.iter_mut() {
        t.replies.sort_by_key(|r| r.timestamp.unwrap_or(0));
    }
    tops.sort_by(|a, b| {
        b.is_pinned
            .cmp(&a.is_pinned)
            .then(b.like_count.unwrap_or(0).cmp(&a.like_count.unwrap_or(0)))
    });
    tops
}

pub fn load_comments(entry: &Entry) -> Vec<Comment> {
    let path = entry.cache_dir.join("comments.json");
    let raw: Vec<Value> = fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    thread_comments(&raw)
}

pub fn load_full_info(entry: &Entry) -> Value {
    fs::read_to_string(entry.cache_dir.join("info.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({"info": {}, "dropped": []}))
}

// ---------------------------------------------------------------------------
// Subtitles / transcript
// ---------------------------------------------------------------------------

#[derive(Serialize, Clone, Debug)]
pub struct Cue {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

fn parse_ts(text: &str) -> Option<f64> {
    // [hh:]mm:ss[.,]mmm
    let t = text.trim();
    let mut end = 0;
    for (i, ch) in t.char_indices() {
        if ch.is_ascii_digit() || ch == ':' || ch == '.' || ch == ',' {
            end = i + ch.len_utf8();
        } else {
            break;
        }
    }
    let t = &t[..end];
    let (clock, frac) = match t.find(['.', ',']) {
        Some(i) => (&t[..i], &t[i + 1..]),
        None => (t, ""),
    };
    let parts: Vec<&str> = clock.split(':').collect();
    let (h, m, s) = match parts.len() {
        3 => (parts[0].parse::<f64>().ok()?, parts[1].parse::<f64>().ok()?, parts[2].parse::<f64>().ok()?),
        2 => (0.0, parts[0].parse::<f64>().ok()?, parts[1].parse::<f64>().ok()?),
        _ => return None,
    };
    let ms = if frac.is_empty() {
        0.0
    } else {
        let padded = format!("{:0<3}", &frac[..frac.len().min(3)]);
        padded.parse::<f64>().unwrap_or(0.0)
    };
    Some(h * 3600.0 + m * 60.0 + s + ms / 1000.0)
}

fn strip_inline_tags(s: &str) -> String {
    // Removes <c>, </c>, <v Name>, and the per-word <00:00:01.234> karaoke
    // timestamps YouTube's ASR emits. A hand-rolled scanner rather than a
    // regex dependency: the grammar is "everything between < and >".
    let mut out = String::with_capacity(s.len());
    let mut depth = 0usize;
    for ch in s.chars() {
        match ch {
            '<' => depth += 1,
            '>' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(ch),
            _ => {}
        }
    }
    out
}

fn unescape_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn collapse_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// YouTube's auto-generated VTT is a rolling two-line display: nearly every
/// cue repeats the previous cue's last line, and words carry inline karaoke
/// timestamps. Read as-is it is unusable as a transcript, so tags are stripped
/// and the repetition is collapsed.
pub fn parse_subtitle_cues(path: &Path) -> Vec<Cue> {
    let raw = fs::read_to_string(path).unwrap_or_default();
    if raw.is_empty() {
        return Vec::new();
    }
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");
    let mut cues: Vec<Cue> = Vec::new();

    for block in normalized.split("\n\n") {
        let lines: Vec<&str> = block.lines().filter(|l| !l.trim().is_empty()).collect();
        if lines.is_empty() {
            continue;
        }
        let Some(time_idx) = lines.iter().position(|l| l.contains("-->")) else {
            continue;
        };
        let (left, right) = lines[time_idx].split_once("-->").unwrap_or((lines[time_idx], ""));
        let Some(start) = parse_ts(left) else { continue };
        let end = right
            .trim()
            .split(' ')
            .next()
            .and_then(parse_ts)
            .unwrap_or(start + 3.0);
        let body = lines[time_idx + 1..].join(" ");
        let body = collapse_ws(&unescape_entities(&strip_inline_tags(&body)));
        if body.is_empty() {
            continue;
        }
        cues.push(Cue { start, end, text: body });
    }

    let mut cleaned: Vec<Cue> = Vec::new();
    for cue in cues {
        if let Some(prev) = cleaned.last_mut() {
            if cue.text == prev.text {
                prev.end = prev.end.max(cue.end);
                continue;
            }
            // The auto-caption case: this cue is the previous one plus a tail.
            if cue.text.starts_with(&prev.text) && prev.text.chars().count() > 12 {
                let tail = cue.text[prev.text.len()..].trim().to_string();
                if tail.is_empty() {
                    prev.end = prev.end.max(cue.end);
                } else {
                    cleaned.push(Cue { start: cue.start, end: cue.end, text: tail });
                }
                continue;
            }
        }
        cleaned.push(cue);
    }
    cleaned
}

/// The filenames cannot tell an auto-generated track from a human-written one
/// -- --write-subs and --write-auto-subs both land in Subtitles/ under the
/// same base name. The contents can: ASR output carries per-word <c> karaoke
/// tags and cue-positioning directives that uploaded tracks do not.
pub fn subtitle_is_auto(path: &Path) -> bool {
    let head = read_text_limited(path, 8000);
    head.contains("<c.") || head.contains("<c>") || head.contains("align:start position:")
}
