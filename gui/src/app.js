/* ytdl-gui frontend.
 *
 * Plain ES2020, no modules, no bundler, no dependencies. `withGlobalTauri` in
 * tauri.conf.json is what makes window.__TAURI__ exist, and it is the reason
 * this app has no package.json at all -- which matters, because the rest of
 * this repo deliberately has no build system and adding npm to it would have
 * been the largest change the GUI made.
 *
 * Everything privileged lives behind an invoke() call. There is no filesystem
 * plugin and no shell plugin in the capability set, so this file cannot read a
 * path or run a command even if something managed to inject script into it --
 * it can only ask main.rs for the specific things main.rs chose to offer.
 */

const { invoke, convertFileSrc } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const S = {
  view: "download",
  platform: "",
  settings: null,
  locations: null,
  library: [],
  channels: [],
  current: null,
  queue: [],
  history: [],
  console: [],
  live: "",
  video: null,
  cues: [],
  scanning: false,
};

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}

function fmtDuration(sec) {
  if (sec == null || !isFinite(sec)) return "";
  sec = Math.round(sec);
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`
           : `${m}:${String(s).padStart(2, "0")}`;
}

function fmtBytes(n) {
  if (!n) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${u[i]}`;
}

function fmtDate(yyyymmdd) {
  if (!yyyymmdd || yyyymmdd.length !== 8) return yyyymmdd || "";
  return `${yyyymmdd.slice(0, 4)}-${yyyymmdd.slice(4, 6)}-${yyyymmdd.slice(6, 8)}`;
}

function fmtWhen(unix) {
  if (!unix) return "";
  const d = new Date(unix * 1000);
  return d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function fmtCount(n) {
  return n == null ? "" : Number(n).toLocaleString();
}

/* The one place a file becomes a URL. Windows rewrites custom schemes to
 * http://<scheme>.localhost, every other platform keeps <scheme>://localhost,
 * and getting this wrong is a silently blank <video> rather than an error. */
function mediaUrl(key, idx, mode) {
  const q = mode && mode !== "direct" ? `?mode=${encodeURIComponent(mode)}` : "";
  const path = `${encodeURIComponent(key)}/${idx}${q}`;
  if (S.platform === "windows") return `http://media.localhost/${path}`;
  return `media://localhost/${path}`;
}

/* ------------------------------------------------------------------ views */

function show(view) {
  S.view = view;
  $$(".view").forEach((v) => v.classList.toggle("active", v.id === `view-${view}`));
  $$(".nav").forEach((b) => b.classList.toggle("active", b.dataset.view === view));
  if (view === "library" && !S.library.length && !S.scanning) refreshLibrary();
  if (view === "health") loadHealth();
}

$$(".nav").forEach((b) => b.addEventListener("click", () => show(b.dataset.view)));

/* --------------------------------------------------------------- download */

function readOptions() {
  const n = (el) => {
    const v = parseInt($(el).value, 10);
    return isNaN(v) ? null : v;
  };
  const t = (el) => {
    const v = $(el).value.trim();
    return v === "" ? null : v;
  };
  return {
    url: $("#url").value.trim(),
    data_root: t("#opt-path"),
    sync: $("#opt-sync").checked,
    items: t("#opt-items"),
    after: t("#opt-after"),
    lazy: $("#opt-lazy").checked,
    workers: n("#opt-workers"),
    no_pot: $("#opt-nopot").checked,
    skip_pot_update: $("#opt-skippot").checked,
    pot_port: n("#opt-potport"),
  };
}

let previewTimer = null;
function schedulePreview() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(updatePreview, 120);
}

/* The preview is rendered by the SAME Rust function that builds the real
 * argument list, not by a JS copy of it. A preview that could drift from the
 * command actually run would be worse than no preview. */
async function updatePreview() {
  const opts = readOptions();
  const workers = opts.workers || 1;
  $("#workers-warn").hidden = workers <= 2;
  const active = [];
  if (opts.sync) active.push("--sync");
  if (opts.lazy) active.push("--lazy");
  if (opts.items) active.push("--items");
  if (opts.after) active.push("--after");
  if (workers > 1) active.push(`--workers ${workers}`);
  if (opts.data_root) active.push("--path");
  if (opts.no_pot) active.push("--no-pot");
  $("#opt-summary").textContent = active.length ? active.join("  ") : "defaults";
  try {
    $("#cmd-preview").textContent = await invoke("command_preview", { opts });
  } catch (e) {
    $("#cmd-preview").textContent = "ytdl";
  }
}

["#url", "#opt-items", "#opt-after", "#opt-workers", "#opt-path", "#opt-potport"]
  .forEach((s) => $(s).addEventListener("input", schedulePreview));
["#opt-sync", "#opt-lazy", "#opt-nopot", "#opt-skippot"]
  .forEach((s) => $(s).addEventListener("change", schedulePreview));

$("#url").addEventListener("keydown", (e) => {
  if (e.key === "Enter") start();
});

async function start() {
  const err = $("#download-err");
  err.hidden = true;
  try {
    await invoke("run_enqueue", { opts: readOptions() });
    $("#url").value = "";
    schedulePreview();
  } catch (e) {
    err.textContent = String(e);
    err.hidden = false;
  }
}

$("#btn-start").addEventListener("click", start);
$("#btn-queue").addEventListener("click", start);
$("#btn-cancel").addEventListener("click", () => invoke("run_cancel"));

/* ---------------------------------------------------------------- console */

function lineClass(text) {
  const t = text.toLowerCase();
  if (t.includes("error") || t.startsWith("error")) return "l-err";
  if (t.includes("warning")) return "l-warn";
  if (text.startsWith("====") || text.startsWith("--")) return "l-mark";
  return "";
}

function renderConsole() {
  const box = $("#console");
  const stick = box.scrollTop + box.clientHeight >= box.scrollHeight - 40;
  const body = S.console.map((l) => `<span class="${lineClass(l)}">${esc(l)}</span>`).join("\n");
  box.innerHTML = body + (S.live ? `\n<span class="l-live">${esc(S.live)}</span>` : "");
  if (stick) box.scrollTop = box.scrollHeight;
}

function renderProgress(p) {
  const wrap = $("#progress-wrap");
  if (!S.current) { wrap.hidden = true; return; }
  wrap.hidden = false;
  const fill = $("#bar-fill");
  if (p && p.percent != null) {
    fill.classList.remove("indeterminate");
    fill.style.width = `${Math.max(0, Math.min(100, p.percent))}%`;
  } else {
    fill.classList.add("indeterminate");
    fill.style.width = "";
  }
  const bits = [];
  if (p && p.stage) bits.push(p.stage);
  if (p && p.video_id) bits.push(p.video_id);
  if (p && p.percent != null) bits.push(`${p.percent.toFixed(1)}%`);
  if (p && p.total) bits.push(`of ${p.total}`);
  if (p && p.speed) bits.push(`at ${p.speed}`);
  if (p && p.eta) bits.push(`ETA ${p.eta}`);
  $("#progress-meta").textContent = bits.join("  ");
}

function renderRunner() {
  const cur = S.current;
  $("#btn-cancel").hidden = !cur;
  $("#run-title").textContent = cur ? cur.opts.url : "Nothing running";
  $("#run-sub").textContent = cur
    ? cur.command
    : "Start a download and its output appears here.";

  const mini = $("#mini-status");
  mini.className = "mini " + (cur ? "running" : (S.history[0] ? S.history[0].state : "idle"));
  mini.textContent = cur ? "running" : (S.history[0] ? `last run: ${S.history[0].state}` : "idle");
  $("#mini-line").textContent = S.live || (cur ? cur.last_line : "");

  const badge = $("#queue-badge");
  badge.hidden = S.queue.length === 0;
  badge.textContent = S.queue.length;

  renderQueue();
  renderHistory();
}

function renderQueue() {
  const box = $("#queue-list");
  if (!S.queue.length) {
    box.innerHTML = `<div class="empty">Nothing queued.</div>`;
    return;
  }
  box.innerHTML = S.queue.map((q) => `
    <div class="row">
      <div class="row-main">
        <div class="row-title">${esc(q.opts.url)}</div>
        <div class="row-sub">added ${esc(fmtWhen(q.added))}</div>
      </div>
      <button class="quiet small" data-remove="${esc(q.id)}">Remove</button>
    </div>`).join("");
  box.querySelectorAll("[data-remove]").forEach((b) =>
    b.addEventListener("click", () => invoke("queue_remove", { id: b.dataset.remove })));
}

function renderHistory() {
  const box = $("#history-list");
  if (!S.history.length) {
    box.innerHTML = `<div class="empty">No runs yet.</div>`;
    return;
  }
  box.innerHTML = S.history.slice(0, 80).map((h) => {
    const bits = [];
    if (h.videos_touched != null) bits.push(`${h.videos_touched} touched`);
    if (h.archive_skipped != null) bits.push(`${h.archive_skipped} skipped`);
    if (h.errors) bits.push(`${h.errors} error(s)`);
    if (h.warnings) bits.push(`${h.warnings} warning(s)`);
    if (h.exit_code != null) bits.push(`exit ${h.exit_code}`);
    const dur = h.finished && h.started ? fmtDuration(h.finished - h.started) : "";
    return `
      <div class="row">
        <div class="row-main">
          <div class="row-title">${esc(h.opts.url)}</div>
          <div class="row-sub">${esc(fmtWhen(h.started))}${dur ? " &middot; " + dur : ""}${
            bits.length ? " &middot; " + esc(bits.join(", ")) : ""}</div>
          ${h.state === "failed" && h.last_line
            ? `<div class="row-sub" style="color:var(--bad)">${esc(h.last_line.slice(0, 200))}</div>` : ""}
        </div>
        <span class="pill ${esc(h.state)}">${esc(h.state)}</span>
      </div>`;
  }).join("");
}

$("#queue-pause").addEventListener("change", (e) =>
  invoke("queue_set_paused", { paused: e.target.checked }));
$("#btn-clear-history").addEventListener("click", () => invoke("history_clear"));

/* ----------------------------------------------------------------- events */

listen("run-line", (ev) => {
  const p = ev.payload;
  if (p.transient) {
    S.live = p.text;
  } else {
    S.live = "";
    S.console.push(p.text);
    if (S.console.length > 4000) S.console.splice(0, S.console.length - 4000);
  }
  if (p.progress) renderProgress(p.progress);
  $("#mini-line").textContent = p.text;
  renderConsole();
});

listen("runner-state", (ev) => {
  const p = ev.payload;
  S.queue = p.queue || [];
  S.current = p.current || null;
  S.history = p.history || [];
  if (!S.current) { S.live = ""; renderProgress(null); }
  renderRunner();
});

listen("scan-progress", (ev) => {
  S.scanning = true;
  const p = ev.payload;
  showLibStatus(`Indexing ${p.done} of ${p.total}… ${p.current || ""}`);
});

listen("scan-done", async (ev) => {
  S.scanning = false;
  if (!ev.payload.ok) {
    showLibStatus(ev.payload.error || "Scan failed.", true);
    return;
  }
  await loadLibrary();
});

listen("media-progress", (ev) => {
  const p = ev.payload;
  const el = $("#playback-status");
  if (!el || !S.video || S.video.key !== p.key) return;
  const st = p.status || {};
  if (st.state === "running") {
    el.textContent = `Preparing playback copy… ${Math.round((st.progress || 0) * 100)}%`;
  } else if (st.state === "ready") {
    el.textContent = "Ready.";
    attachPlayer(p.mode);
  } else if (st.state === "error") {
    el.textContent = `Could not prepare playback: ${st.error || "unknown error"}`;
  }
});

/* ---------------------------------------------------------------- library */

function showLibStatus(text, bad) {
  const el = $("#lib-status");
  el.hidden = false;
  el.className = "notice" + (bad ? " bad" : "");
  el.textContent = text;
}

async function refreshLibrary(force) {
  showLibStatus("Indexing the archive…");
  try {
    await invoke("archive_rescan", { force: !!force });
    S.scanning = true;
  } catch (e) {
    S.scanning = false;
    showLibStatus(String(e), true);
  }
}

async function loadLibrary() {
  const data = await invoke("archive_library");
  S.library = data.videos || [];
  S.channels = data.channels || [];
  const sel = $("#lib-channel");
  const keep = sel.value;
  sel.innerHTML = `<option value="">All channels (${S.library.length})</option>` +
    S.channels.map((c) => `<option value="${esc(c.name)}">${esc(c.name)} (${c.count})</option>`).join("");
  sel.value = keep;
  if (!S.library.length) {
    showLibStatus(`No videos found under ${data.root || "the archive root"}.`);
  } else {
    $("#lib-status").hidden = true;
  }
  renderLibrary();
}

function renderLibrary() {
  const q = $("#lib-search").value.trim().toLowerCase();
  const chan = $("#lib-channel").value;
  const sort = $("#lib-sort").value;

  let rows = S.library.filter((v) => {
    if (chan && v.channel_folder !== chan) return false;
    if (!q) return true;
    return (v.title + " " + v.uploader + " " + (v.id || "")).toLowerCase().includes(q);
  });

  rows.sort((a, b) => {
    if (sort === "title") return a.title.localeCompare(b.title);
    if (sort === "size") return b.total_bytes - a.total_bytes;
    const da = a.upload_date || "", db = b.upload_date || "";
    return sort === "date-asc" ? da.localeCompare(db) : db.localeCompare(da);
  });

  $("#lib-grid").innerHTML = rows.map((v) => {
    const thumb = v.thumb_idx != null
      ? `style="background-image:url('${mediaUrl(v.key, v.thumb_idx)}')"` : "";
    return `
      <button class="tile" data-key="${esc(v.key)}">
        <div class="tile-thumb" ${thumb}>${v.thumb_idx == null ? "no thumbnail" : ""}
          ${v.duration ? `<span class="tile-dur">${fmtDuration(v.duration)}</span>` : ""}</div>
        <div class="tile-body">
          <div class="tile-title">${esc(v.title)}</div>
          <div class="tile-meta">
            <span>${esc(v.uploader)}</span>
            <span>${esc(fmtDate(v.upload_date))}</span>
            ${v.comments_cached ? `<span>${fmtCount(v.comments_cached)} comments</span>` : ""}
            <span>${fmtBytes(v.total_bytes)}</span>
            ${v.has_info_json ? "" : `<span class="maybe">no info.json</span>`}
          </div>
        </div>
      </button>`;
  }).join("") || `<div class="empty">Nothing matches.</div>`;

  $("#lib-grid").querySelectorAll("[data-key]").forEach((el) =>
    el.addEventListener("click", () => openVideo(el.dataset.key)));
}

["#lib-search", "#lib-channel", "#lib-sort"].forEach((s) =>
  $(s).addEventListener("input", renderLibrary));
$("#btn-rescan").addEventListener("click", (e) => refreshLibrary(e.shiftKey));
$("#btn-back").addEventListener("click", () => show("library"));

/* ------------------------------------------------------------ video detail */

async function openVideo(key) {
  show("video");
  $("#video-body").innerHTML = `<div class="spinner">Loading…</div>`;
  let d;
  try {
    d = await invoke("archive_video", { key });
  } catch (e) {
    $("#video-body").innerHTML = `<div class="notice bad">${esc(e)}</div>`;
    return;
  }
  S.video = d;
  S.cues = [];
  S.triedWebm = false;
  renderVideo(d);
}

function renderVideo(d) {
  const m = d.meta;
  const plan = d.plan || { mode: "unsupported", reason: "No video file in this folder." };

  const subs = d.subtitles || [];
  const chapters = Array.isArray(m.chapters) ? m.chapters : [];

  $("#video-body").innerHTML = `
    <div class="detail-head">
      <div style="flex:1;min-width:0">
        <h1>${esc(m.title)}</h1>
        <div class="detail-meta">
          <span>${esc(m.uploader)}</span>
          <span>${esc(fmtDate(m.upload_date))}</span>
          ${m.duration ? `<span>${fmtDuration(m.duration)}</span>` : ""}
          ${m.view_count != null ? `<span>${fmtCount(m.view_count)} views</span>` : ""}
          ${m.id ? `<span class="mono">${esc(m.id)}</span>` : ""}
        </div>
      </div>
      <div style="display:flex;gap:8px;flex-wrap:wrap">
        <button class="quiet small" id="btn-player">Open in mpv/VLC</button>
        <button class="quiet small" id="btn-folder">Open folder</button>
        <button class="quiet small" id="btn-verify">Verify checksums</button>
      </div>
    </div>

    <div id="player-slot"></div>
    <div class="hint" id="playback-status" style="margin-top:8px">${esc(plan.reason || "")}</div>
    <div id="verify-out"></div>

    <div class="tabs">
      <button class="tab active" data-tab="about">Description</button>
      <button class="tab" data-tab="comments">Comments${
        m.comments_cached ? ` (${fmtCount(m.comments_cached)})` : ""}</button>
      <button class="tab" data-tab="transcript">Transcript${subs.length ? "" : " (none)"}</button>
      <button class="tab" data-tab="meta">Metadata</button>
      <button class="tab" data-tab="files">Files (${m.files.length})</button>
    </div>

    <div class="tabpane active" id="pane-about">
      ${chapters.length ? `<h2>Chapters</h2><div class="chapters">${chapters.map((c) => `
        <div class="chapter" data-seek="${Number(c.start_time) || 0}">
          <span class="cue-t">${fmtDuration(c.start_time)}</span>
          <span>${esc(c.title || "")}</span>
        </div>`).join("")}</div>` : ""}
      <h2 style="margin-top:${chapters.length ? "18px" : "0"}">Description</h2>
      <pre class="blob">${esc(m.description) || "<em>none</em>"}</pre>
    </div>

    <div class="tabpane" id="pane-comments"><div class="spinner">Not loaded yet.</div></div>

    <div class="tabpane" id="pane-transcript">
      ${subs.length ? `
        <label class="field inline" style="margin-bottom:12px">
          <span class="label">Track</span>
          <select id="sub-pick">${subs.map((s) => `
            <option value="${s.idx}">${esc(s.rel)}${s.auto ? " — auto-generated" : ""}</option>`).join("")}
          </select>
        </label>
        <div class="transcript" id="transcript"><div class="spinner">Loading…</div></div>`
        : `<div class="empty">No subtitle files in this folder.</div>`}
    </div>

    <div class="tabpane" id="pane-meta">
      ${m.dropped_keys && m.dropped_keys.length ? `<p class="hint">Not shown, because they are
        enormous and useless in a panel: <b>${esc(m.dropped_keys.join(", "))}</b>. They are still
        in the archived info.json.</p>` : ""}
      <div class="kv">${metaRows(m).map(([k, v]) =>
        `<div class="k">${esc(k)}</div><div class="v">${esc(v)}</div>`).join("")}</div>
      <h2 style="margin-top:18px">Full info.json (heavy keys removed)</h2>
      <pre class="blob">${esc(JSON.stringify(d.info, null, 2))}</pre>
    </div>

    <div class="tabpane" id="pane-files">
      <table><thead><tr><th>File</th><th>Folder</th><th style="text-align:right">Size</th><th></th></tr></thead>
      <tbody>${m.files.map((f, i) => `
        <tr><td class="mono">${esc(f.rel.split("/").pop())}</td>
            <td>${esc(f.folder === "." ? "" : f.folder)}</td>
            <td class="num">${fmtBytes(f.size)}</td>
            <td>${isTexty(f) ? `<button class="quiet small" data-text="${i}">view</button>` : ""}</td>
        </tr>`).join("")}</tbody></table>
      <pre class="blob" id="file-text" hidden></pre>
    </div>`;

  $$("#video-body .tab").forEach((t) => t.addEventListener("click", () => {
    $$("#video-body .tab").forEach((x) => x.classList.toggle("active", x === t));
    $$("#video-body .tabpane").forEach((p) =>
      p.classList.toggle("active", p.id === `pane-${t.dataset.tab}`));
    if (t.dataset.tab === "comments") loadComments();
    if (t.dataset.tab === "transcript" && subs.length) loadTranscript();
  }));

  $("#btn-player").addEventListener("click", async () => {
    try {
      const used = await invoke("open_in_player", { key: d.key, idx: d.video_idx });
      $("#playback-status").textContent = `Handed to ${used}.`;
    } catch (e) { $("#playback-status").textContent = String(e); }
  });
  $("#btn-folder").addEventListener("click", () => invoke("open_folder", { key: d.key }));
  $("#btn-verify").addEventListener("click", verify);
  $$("#video-body [data-seek]").forEach((el) => el.addEventListener("click", () => {
    const v = $("#player");
    if (v) { v.currentTime = Number(el.dataset.seek); v.play(); }
  }));
  $$("#video-body [data-text]").forEach((b) => b.addEventListener("click", async () => {
    const out = $("#file-text");
    out.hidden = false;
    out.textContent = "Loading…";
    try {
      out.textContent = await invoke("archive_file_text", { key: d.key, idx: Number(b.dataset.text) });
    } catch (e) { out.textContent = String(e); }
  }));
  const pick = $("#sub-pick");
  if (pick) pick.addEventListener("change", loadTranscript);

  preparePlayback(d, plan);
}

function isTexty(f) {
  return [".json", ".txt", ".description", ".vtt", ".srt", ".log", ".url", ".sha256", ".webloc", ".desktop"]
    .includes(f.ext) || f.rel.endsWith("checksums.sha256");
}

function metaRows(m) {
  return [
    ["Video id", m.id || "—"],
    ["Uploader", m.uploader],
    ["Upload date", fmtDate(m.upload_date)],
    ["Duration", fmtDuration(m.duration)],
    ["Resolution", m.resolution || "—"],
    ["Video codec", m.vcodec || "—"],
    ["Audio codec", m.acodec || "—"],
    ["FPS", m.fps == null ? "—" : m.fps],
    ["Views", fmtCount(m.view_count)],
    ["Likes", fmtCount(m.like_count)],
    ["Comments in info.json", fmtCount(m.comments_cached)],
    ["Language", m.language || "—"],
    ["Categories", (m.categories || []).join(", ") || "—"],
    ["Tags", (m.tags || []).slice(0, 20).join(", ") || "—"],
    ["Original URL", m.webpage_url || "—"],
    ["Archive folder", m.rel],
  ];
}

/* Playback follows media.rs's plan: direct streams straight from the archive,
 * remux is a lossless container copy, transcode is the only mode that costs a
 * re-encode and it is never started without this click. */
function preparePlayback(d, plan) {
  const slot = $("#player-slot");
  if (d.video_idx == null) {
    slot.innerHTML = `<div class="notice">This folder has no video file.</div>`;
    return;
  }
  if (plan.mode === "direct") { attachPlayer("direct"); return; }
  if (plan.mode === "unsupported") {
    slot.innerHTML = `<div class="notice bad">${esc(plan.reason)} Use “Open in mpv/VLC”.</div>`;
    return;
  }
  const label = plan.mode === "remux"
    ? "Prepare a lossless MP4 copy"
    : `Re-encode a playable copy (${plan.profile || "re-encode"})`;
  slot.innerHTML = `<div class="notice">${esc(plan.reason)}
    <div style="margin-top:10px"><button class="primary" id="btn-prep">${esc(label)}</button></div></div>`;
  $("#btn-prep").addEventListener("click", async () => {
    $("#btn-prep").disabled = true;
    $("#playback-status").textContent = "Starting…";
    try {
      const st = await invoke("media_start", { key: d.key, mode: plan.mode });
      if (st.state === "ready") attachPlayer(plan.mode);
    } catch (e) { $("#playback-status").textContent = String(e); }
  });
  invoke("media_status", { key: d.key, mode: plan.mode })
    .then((st) => { if (st.state === "ready") attachPlayer(plan.mode); })
    .catch(() => {});
}

function attachPlayer(mode) {
  const d = S.video;
  if (!d || d.video_idx == null) return;
  const src = mediaUrl(d.key, d.video_idx, mode);
  $("#player-slot").innerHTML =
    `<video id="player" controls preload="metadata" src="${src}"></video>`;
  const v = $("#player");
  v.addEventListener("timeupdate", syncTranscript);
  v.addEventListener("error", () => onPlaybackFailed(mode));
}

/* The archive is full of files whose STREAMS a webview can play and whose
 * CONTAINER it will not open: --merge-output-format mkv writes an EBML
 * DocType of "matroska", and a strict demuxer refuses that before it ever
 * looks at the codecs. The fix is a container rewrite, not a re-encode, so it
 * is done automatically rather than offered as a button -- there is nothing
 * for the user to weigh up. A real re-encode is still never automatic. */
async function onPlaybackFailed(mode) {
  const d = S.video;
  const status = $("#playback-status");
  if (mode === "direct" && d && d.webm_fallback && !S.triedWebm) {
    S.triedWebm = true;
    status.textContent =
      "The webview refused the Matroska container. Copying the same streams into a WebM " +
      "container — no re-encoding, so this is quick…";
    try {
      const st = await invoke("media_start", { key: d.key, mode: "webm" });
      if (st.state === "ready") attachPlayer("webm");
      return;
    } catch (e) {
      status.textContent = String(e);
      return;
    }
  }
  status.textContent =
    "This machine's webview will not play this file. Use “Open in mpv/VLC” — mpv plays every " +
    "codec combination this pipeline can produce, and reads the embedded subtitles and chapters.";
}

async function loadComments() {
  const pane = $("#pane-comments");
  if (pane.dataset.loaded) return;
  pane.dataset.loaded = "1";
  pane.innerHTML = `<div class="spinner">Loading comments…</div>`;
  try {
    const d = await invoke("archive_comments", { key: S.video.key });
    if (!d.threads.length) {
      pane.innerHTML = `<div class="empty">No comments were archived for this video.</div>`;
      return;
    }
    pane.innerHTML = `<p class="hint">${fmtCount(d.total)} archived comments,
      ${fmtCount(d.threads.length)} top-level.</p>` + d.threads.map(comment).join("");
  } catch (e) {
    pane.innerHTML = `<div class="notice bad">${esc(e)}</div>`;
  }
}

function comment(c) {
  const stats = [];
  if (c.like_count) stats.push(`${fmtCount(c.like_count)} likes`);
  if (c.is_pinned) stats.push("pinned");
  if (c.is_favorited) stats.push("hearted");
  if (c.timestamp) stats.push(fmtWhen(c.timestamp));
  return `<div class="comment">
    <div class="comment-head">
      <span class="comment-author${c.author_is_uploader ? " op" : ""}">${esc(c.author)}</span>
      <span class="comment-stat">${esc(stats.join(" · "))}</span>
    </div>
    <div class="comment-text">${esc(c.text)}</div>
    ${c.replies && c.replies.length
      ? `<div class="replies">${c.replies.map(comment).join("")}</div>` : ""}
  </div>`;
}

async function loadTranscript() {
  const box = $("#transcript");
  if (!box) return;
  const idx = Number($("#sub-pick").value);
  box.innerHTML = `<div class="spinner">Loading…</div>`;
  try {
    const d = await invoke("archive_transcript", { key: S.video.key, idx });
    S.cues = d.cues || [];
    if (!S.cues.length) {
      box.innerHTML = `<div class="empty">Nothing readable in that track.</div>`;
      return;
    }
    box.innerHTML = S.cues.map((c, i) =>
      `<div class="cue" data-i="${i}" data-seek="${c.start}">
         <span class="cue-t">${fmtDuration(c.start)}</span><span>${esc(c.text)}</span></div>`).join("");
    box.querySelectorAll(".cue").forEach((el) => el.addEventListener("click", () => {
      const v = $("#player");
      if (v) { v.currentTime = Number(el.dataset.seek); v.play(); }
    }));
  } catch (e) {
    box.innerHTML = `<div class="notice bad">${esc(e)}</div>`;
  }
}

let lastCue = -1;
function syncTranscript(e) {
  if (!S.cues.length) return;
  const t = e.target.currentTime;
  let i = S.cues.findIndex((c) => t >= c.start && t < c.end);
  if (i === lastCue) return;
  lastCue = i;
  const box = $("#transcript");
  if (!box) return;
  box.querySelectorAll(".cue.on").forEach((el) => el.classList.remove("on"));
  if (i < 0) return;
  const el = box.querySelector(`.cue[data-i="${i}"]`);
  if (el) {
    el.classList.add("on");
    const top = el.offsetTop - box.clientHeight / 2;
    box.scrollTo({ top, behavior: "smooth" });
  }
}

async function verify() {
  const out = $("#verify-out");
  out.innerHTML = `<div class="notice">Hashing every file in this folder…</div>`;
  try {
    const r = await invoke("verify_video", { key: S.video.key });
    if (!r.present) {
      out.innerHTML = `<div class="notice">This folder has no checksums.sha256.</div>`;
      return;
    }
    const bad = r.failed.length + r.missing.length;
    out.innerHTML = `<div class="notice${bad ? " bad" : ""}">
      ${r.ok} of ${r.checked} files verify.
      ${r.failed.length ? `<br>Changed: <b>${esc(r.failed.join(", "))}</b>` : ""}
      ${r.missing.length ? `<br>Missing: <b>${esc(r.missing.join(", "))}</b>` : ""}
      ${bad ? "" : " Nothing has changed since this video was archived."}
      </div>`;
  } catch (e) {
    out.innerHTML = `<div class="notice bad">${esc(e)}</div>`;
  }
}

/* ----------------------------------------------------------------- health */

async function loadHealth() {
  const body = $("#health-body");
  body.innerHTML = `<div class="spinner">Checking…</div>`;
  let h;
  try {
    h = await invoke("health_report");
  } catch (e) {
    body.innerHTML = `<div class="notice bad">${esc(e)}</div>`;
    return;
  }
  const dep = (d) => `
    <tr>
      <td class="mono">${esc(d.name)}</td>
      <td class="${d.found ? "ok" : (d.importance === "required" ? "no" : "maybe")}">
        ${d.found ? "found" : "missing"}</td>
      <td>${esc(d.version || "")}</td>
      <td class="mono" style="color:var(--dim)">${esc(d.path || "")}</td>
      <td style="color:var(--dim)">${esc(d.note)}</td>
    </tr>`;

  const inst = (f) => `
    <tr><td class="mono">${esc(f.name)}</td>
        <td class="${f.present ? "ok" : "no"}">${f.present ? "installed" : "missing"}</td>
        <td class="num">${f.present ? fmtBytes(f.size) : ""}</td>
        <td style="color:var(--dim)">${f.modified ? esc(fmtWhen(f.modified)) : ""}</td></tr>`;

  const s = h.stats;
  body.innerHTML = `
    <div class="card">
      <h2>Dependencies</h2>
      <table><thead><tr><th>Tool</th><th>State</th><th>Version</th><th>Path</th><th>Why it matters</th></tr></thead>
      <tbody>${h.dependencies.map(dep).join("")}</tbody></table>
    </div>

    <div class="card">
      <h2>Installed pipeline files</h2>
      <p class="hint">The repo holds the sources; the installer copies them here. Editing a file in a
        clone has no effect on this install until it is copied over.</p>
      <table><thead><tr><th>File</th><th>State</th><th style="text-align:right">Size</th><th>Modified</th></tr></thead>
      <tbody>${h.installed.map(inst).join("")}</tbody></table>
    </div>

    <div class="card">
      <h2>Archive</h2>
      <div class="kv">
        <div class="k">Data root</div><div class="v">${esc(s.data_root)}</div>
        <div class="k">Videos indexed</div><div class="v">${fmtCount(s.videos)}</div>
        <div class="k">Channels</div><div class="v">${fmtCount(s.channels)}</div>
        <div class="k">Archived bytes</div><div class="v">${fmtBytes(s.total_bytes)}</div>
        <div class="k">global_manifest.json</div><div class="v">${
          s.global_manifest_entries == null ? "not found" : fmtCount(s.global_manifest_entries) + " entries"}</div>
        <div class="k">archive.txt</div><div class="v">${
          s.archive_txt_ids == null ? "not found" : fmtCount(s.archive_txt_ids) + " ids"}</div>
        <div class="k">Archive History snapshots</div><div class="v">${fmtCount(s.history_snapshots)}</div>
      </div>
      <div style="margin-top:12px"><button class="quiet small" id="btn-open-logs">Open the log folder</button></div>
    </div>

    <div class="card">
      <h2>PO token provider</h2>
      <div class="kv">
        <div class="k">pot-provider.ps1</div><div class="v">${h.pot.script_present ? "installed" : "missing"}</div>
        <div class="k">Server build</div><div class="v">${h.pot.server_built ? "built" : "not built"}</div>
        <div class="k">PID file</div><div class="v">${h.pot.pid_file ? "present" : "none"}</div>
        <div class="k">Root</div><div class="v">${esc(h.pot.root)}</div>
      </div>
      ${h.pot.state ? `<pre class="blob" style="margin-top:12px">${
        esc(JSON.stringify(h.pot.state, null, 2))}</pre>` : ""}
      ${h.pot.log_tail ? `<h2 style="margin-top:16px">pot-server.log (tail)</h2>
        <pre class="blob">${esc(h.pot.log_tail)}</pre>` : ""}
    </div>

    <div class="card">
      <h2>yt-dlp.conf</h2>
      <div class="kv">
        <div class="k">CONFIG_VERSION</div><div class="v">${esc(h.config.config_version || "unknown")}</div>
        <div class="k">Options set</div><div class="v">${h.config.option_count}</div>
        <div class="k">Path</div><div class="v">${esc(h.config.path)}</div>
      </div>
      <p class="hint" style="margin-top:12px">Read-only here on purpose. This file is the pipeline's
        design record as much as its configuration — several comment blocks document options that
        were removed and must not be re-added — and CONFIG_VERSION has to be bumped by hand when it
        changes, because both scripts record it in manifest.json and download.log.</p>
      <pre class="blob">${esc(h.config.body || "(not installed)")}</pre>
    </div>

    <div class="card">
      <h2>download.log (tail)</h2>
      <pre class="blob" id="log-tail">Loading…</pre>
    </div>`;

  $("#btn-open-logs").addEventListener("click", () => invoke("open_path", { path: s.log_dir }));
  invoke("read_log", { which: "download", lines: 300 })
    .then((r) => { $("#log-tail").textContent = r.exists ? r.text : `${r.path} does not exist yet.`; })
    .catch((e) => { $("#log-tail").textContent = String(e); });
}

$("#btn-health-refresh").addEventListener("click", loadHealth);

/* --------------------------------------------------------------- settings */

function applyTheme(theme) {
  if (theme === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", theme);
}

async function loadSettings() {
  S.settings = await invoke("get_settings");
  $("#set-dataroot").value = S.settings.data_root || "";
  $("#set-archiveroot").value = S.settings.archive_root || "";
  $("#set-workers").value = S.settings.default_workers || 1;
  $("#set-transcode").checked = !!S.settings.allow_transcode;
  $("#set-theme").value = S.settings.theme || "system";
  $("#opt-workers").value = S.settings.default_workers || 1;
  applyTheme(S.settings.theme || "system");
}

$("#btn-save-settings").addEventListener("click", async () => {
  const settings = {
    data_root: $("#set-dataroot").value.trim() || null,
    archive_root: $("#set-archiveroot").value.trim() || null,
    allow_transcode: $("#set-transcode").checked,
    default_workers: parseInt($("#set-workers").value, 10) || 1,
    theme: $("#set-theme").value,
  };
  S.settings = await invoke("set_settings", { settings });
  applyTheme(settings.theme);
  const saved = $("#settings-saved");
  saved.hidden = false;
  setTimeout(() => { saved.hidden = true; }, 1600);
  await loadLocations();
  // The allow_transcode change only takes effect for playback decisions on the
  // next launch: media::Media reads it once at construction. Said plainly here
  // rather than pretending the toggle is live.
});

$("#set-theme").addEventListener("change", (e) => applyTheme(e.target.value));

async function loadLocations() {
  S.locations = await invoke("locations");
  S.platform = S.locations.platform;
  $("#brand-platform").textContent =
    `${S.locations.platform}${S.locations.pwsh ? "" : " · no pwsh"}`;
  $("#locations").innerHTML = Object.entries(S.locations).map(([k, v]) =>
    `<div class="k">${esc(k.replace(/_/g, " "))}</div><div class="v">${esc(v ?? "—")}</div>`).join("");
}

/* -------------------------------------------------------------------- init */

(async function init() {
  await loadSettings();
  await loadLocations();
  const snap = await invoke("runner_snapshot");
  S.queue = snap.queue || [];
  S.current = snap.current || null;
  S.history = snap.history || [];
  S.console = snap.log || [];
  $("#queue-pause").checked = !!snap.paused;
  renderRunner();
  renderConsole();
  renderProgress(snap.progress);
  schedulePreview();
  show("download");
  // The first index of a large archive reads every info.json, so it is kicked
  // off in the background at startup rather than when the Library tab is first
  // opened -- by which point the user is already waiting on it.
  refreshLibrary(false);
})();
