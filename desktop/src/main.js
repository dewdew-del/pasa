const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);

function fmt(b) {
  if (b < 1024) return b + " B";
  const u = ["KB", "MB", "GB", "TB"];
  let i = -1;
  do { b /= 1024; i++; } while (b >= 1024 && i < 3);
  return b.toFixed(1) + " " + u[i];
}
const fmtTime = (s) => { s = Math.ceil(s); return s < 60 ? s + " s" : Math.floor(s / 60) + " min " + (s % 60) + " s"; };
const live = (t) => t.status === "queued" || t.status === "active";

// ---------- pairing / QR (refreshed so a newly joined hotspot shows up) ----------
let lastSvg = "";
async function refreshPairing() {
  const p = await invoke("get_pairing");
  if (p.qr_svg !== lastSvg) { $("qr").innerHTML = p.qr_svg; lastSvg = p.qr_svg; }
  $("noNet").hidden = p.urls.length > 0;
}
refreshPairing();
setInterval(refreshPairing, 5000);

// ---------- transfer list: rows keyed by id, built once, patched in place ----------
const rows = new Map();
function makeRow(t) {
  const li = document.createElement("li");
  li.className = "row";
  li.innerHTML = `<svg class="i ic"><use href="${t.direction === "to_laptop" ? "#i-down" : "#i-up"}"/></svg><div class="meta"><div class="name"></div><div class="sub num"></div></div><div class="act"></div><div class="bar"><i></i></div>`;
  li.querySelector(".name").textContent = t.name;
  li._status = "";
  return li;
}
function subText(t) {
  switch (t.status) {
    case "queued": return fmt(t.size);
    case "active": return (t.size ? Math.floor(t.bytes / t.size * 100) : 0) + "% · " + fmt(t.speed) + "/s";
    case "done": return (t.direction === "to_laptop" ? "Saved · " : "Sent · ") + fmt(t.size);
    case "cancelled": return "Cancelled";
    default: return "Failed";
  }
}
function patch(li, t) {
  const sub = li.querySelector(".sub");
  sub.textContent = subText(t);
  li.querySelector(".bar i").style.transform = `scaleX(${t.size ? t.bytes / t.size : 0})`;
  if (li._status === t.status) return; // buttons only change with the status
  li._status = t.status;
  sub.classList.toggle("bad", t.status === "failed");
  li.classList.toggle("idle", !live(t));
  const act = li.querySelector(".act");
  act.textContent = "";
  if (live(t)) {
    const b = document.createElement("button");
    b.className = "icon-btn";
    b.setAttribute("aria-label", "Cancel " + t.name);
    b.innerHTML = `<svg class="i"><use href="#i-x"/></svg>`;
    b.onclick = () => invoke("cancel_transfer", { id: t.id });
    act.append(b);
  } else if (t.status === "done" && t.path) {
    const b = document.createElement("button");
    b.className = "link";
    b.textContent = "Show";
    b.onclick = () => invoke("reveal", { path: t.path });
    act.append(b);
  }
}
function render(list) {
  const ul = $("list");
  list.forEach((t, i) => {
    let li = rows.get(t.id);
    if (!li) { li = makeRow(t); rows.set(t.id, li); }
    patch(li, t);
    if (ul.children[i] !== li) ul.insertBefore(li, ul.children[i] || null); // moves only rows whose place changed
  });
  $("empty").hidden = list.length > 0;
  $("listHead").hidden = list.length === 0;
  const left = list.filter(live);
  const active = left.find((t) => t.status === "active");
  const remaining = left.reduce((a, t) => a + t.size - t.bytes, 0);
  $("sum").textContent = !left.length ? "" : left.length + " left" + (active && active.speed ? " · " + fmtTime(remaining / active.speed) : "");
}
listen("transfers", (e) => render(e.payload));
listen("connection", (e) => {
  $("dot").classList.toggle("on", e.payload);
  $("status").textContent = e.payload ? "Connected" : "Not connected";
});

// ---------- actions ----------
$("send").onclick = () => invoke("pick_files");
$("folder").onclick = () => invoke("open_receive_folder");
$("forget").onclick = async () => {
  if (!confirm("Forget phones? They will need to scan the QR again.")) return;
  const p = await invoke("forget_phones");
  $("qr").innerHTML = lastSvg = p.qr_svg;
};

// ---------- drag and drop ----------
window.__TAURI__.webview.getCurrentWebview().onDragDropEvent((e) => {
  const t = e.payload.type;
  document.body.classList.toggle("dragging", t === "enter" || t === "over");
  if (t === "drop") invoke("send_files", { paths: e.payload.paths });
});
