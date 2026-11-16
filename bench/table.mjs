// Prints the client benchmark's headline figures side by side, one column
// per result file (bench/README.md "Reading two runs"), as Markdown tables:
//
//   node bench/table.mjs A.json B.json [C.json ...]
//
// Medians unless a figure says p95; ms, except bytes, % and node counts. A
// figure a run doesn't have (an older run, a group not run) shows "-".

import fs from "node:fs";
import path from "node:path";

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("usage: node bench/table.mjs A.json [B.json ...]");
  process.exit(2);
}
const runs = files.map((f) => JSON.parse(fs.readFileSync(f, "utf8")));
const names = files.map((f) => path.basename(f, ".json"));

const get = (obj, keys) => keys.reduce((o, k) => (o === null || o === undefined ? undefined : o[k]), obj);
const fmt = (v) => {
  if (v === null || v === undefined || Number.isNaN(v)) return "-";
  if (typeof v !== "number") return String(v);
  if (Math.abs(v) >= 10000) return Math.round(v).toLocaleString("en-US");
  if (Math.abs(v) >= 100) return String(Math.round(v));
  return String(Math.round(v * 100) / 100);
};

function table(title, rows) {
  console.log(`\n### ${title}\n`);
  console.log(`| figure | ${names.join(" | ")} |`);
  console.log(`|---|${names.map(() => "---").join("|")}|`);
  for (const [label, pick] of rows) {
    const cells = runs.map((r) => fmt(pick(r)));
    if (cells.every((c) => c === "-")) continue;
    console.log(`| ${label} | ${cells.join(" | ")} |`);
  }
}

const RATES = ["1x", "4x"];
const SIZES = ["0", "100", "300", "500"];
const run = (r, rate, n) => get(r, ["runs", rate, n]);

for (const [canvas, key] of [
  ["drawer", "drawer_draw"],
  ["demo board", "demo_draw"],
]) {
  const rows = [];
  for (const rate of RATES)
    for (const n of SIZES) {
      const p = (r, ...k) => get(run(r, rate, n), [key, ...k]);
      rows.push([`${rate} ${n}: main thread / frame`, (r) => p(r, "main_thread_ms_per_frame", "median")]);
      rows.push([`${rate} ${n}: raster / frame`, (r) => p(r, "raster_ms_per_frame", "median")]);
      rows.push([`${rate} ${n}: frame work p95`, (r) => p(r, "frame_aligned", "frame_work_ms", "p95")]);
      rows.push([`${rate} ${n}: frame interval p95`, (r) => p(r, "frame_aligned", "frame_ms", "p95")]);
      rows.push([`${rate} ${n}: frames over 16.7 % (idle)`, (r) => {
        const a = p(r, "frame_aligned", "frames_over_16_7_pct");
        const b = p(r, "frame_aligned", "idle", "frames_over_16_7_pct");
        return a === undefined ? undefined : `${fmt(a)} (${fmt(b)})`;
      }]);
    }
  table(`Drawing, ${canvas}: a 300-move gesture`, rows);
}

{
  const rows = [];
  for (const rate of RATES)
    for (const n of SIZES) {
      const p = (r, ...k) => get(run(r, rate, n), k);
      rows.push([`${rate} ${n}: viewer apply to DOM (p95)`, (r) => {
        const m = p(r, "viewer_apply", "dom_ms", "median");
        return m === undefined ? undefined : `${fmt(m)} (${fmt(p(r, "viewer_apply", "dom_ms", "p95"))})`;
      }]);
      rows.push([`${rate} ${n}: viewer apply painted`, (r) => p(r, "viewer_apply", "paint_ms", "median")]);
      rows.push([`${rate} ${n}: viewer undo painted`, (r) => p(r, "viewer_undo", "paint_ms", "median")]);
      rows.push([`${rate} ${n}: drawer undo painted`, (r) => p(r, "drawer_undo", "paint_ms", "median")]);
      rows.push([`${rate} ${n}: idle viewer busy ms/s`, (r) => p(r, "viewer_idle_busy_ms_per_s")]);
      rows.push([`${rate} ${n}: Hologram logs per apply`, (r) => p(r, "viewer_apply", "hologram_logs_per_apply")]);
    }
  table("Viewer apply / undo, drawer undo", rows);
}

{
  const rows = [];
  for (const rate of RATES)
    for (const n of SIZES) {
      const p = (r, ...k) => get(run(r, rate, n), k);
      rows.push([`${rate} ${n}: viewer painted`, (r) => p(r, "viewer_load", "painted_ms", "median")]);
      rows.push([`${rate} ${n}: viewer data to paint`, (r) => p(r, "viewer_load", "data_to_paint_ms", "median")]);
      rows.push([`${rate} ${n}: viewer busy until`, (r) => p(r, "viewer_load", "thresholded", "busy_until_ms", "median")]);
      rows.push([`${rate} ${n}: drawer painted`, (r) => p(r, "drawer_load", "painted_ms")]);
      rows.push([`${rate} ${n}: demo painted`, (r) => p(r, "demo_load", "painted_ms", "median")]);
      rows.push([`${rate} ${n}: demo snapshot painted (idle page)`, (r) => p(r, "demo_snapshot", "paint_ms", "median")]);
      if (rate === "1x") {
        rows.push([`${n}: viewer HTML bytes (gzip)`, (r) => {
          const b = p(r, "viewer_load", "html_bytes");
          return b === undefined ? undefined : `${fmt(b)} (${fmt(p(r, "viewer_load", "html_transfer_bytes"))})`;
        }]);
        rows.push([`${n}: demo snapshot bytes`, (r) => p(r, "demo_load", "snapshot_bytes")]);
      }
    }
  table("Loads", rows);
}

{
  const rows = [];
  for (const n of SIZES) {
    for (const page of ["viewer", "drawer", "demo"]) {
      const p = (r, ...k) => get(run(r, "1x", n), [`${page}_memory`, ...k]);
      rows.push([`${n}: ${page} heap MB / live nodes / document nodes`, (r) => {
        const h = p(r, "js_heap_bytes");
        return h === undefined ? undefined : `${fmt(h / 1e6)} / ${fmt(p(r, "dom_nodes"))} / ${fmt(p(r, "document_nodes"))}`;
      }]);
    }
  }
  table("Memory (1x, fresh context, after GC)", rows);
}

{
  const rows = [];
  for (const rate of RATES)
    for (const n of SIZES) {
      const p = (r, ...k) => get(run(r, rate, n), k);
      rows.push([`${rate} ${n}: ring hover main / raster per frame`, (r) => {
        const m = p(r, "drawer_hover", "main_thread_ms_per_frame", "median");
        return m === undefined ? undefined : `${fmt(m)} / ${fmt(p(r, "drawer_hover", "raster_ms_per_frame", "median"))}`;
      }]);
      rows.push([`${rate} ${n}: pick handler (p95) / painted`, (r) => {
        const m = p(r, "drawer_pick", "handler_ms", "median");
        return m === undefined ? undefined : `${fmt(m)} (${fmt(p(r, "drawer_pick", "handler_ms", "p95"))}) / ${fmt(p(r, "drawer_pick", "paint_ms", "median"))}`;
      }]);
      for (const where of ["background", "centre"]) {
        rows.push([`${rate} ${n}: fill ${where}: total / main thread / worker`, (r) => {
          const m = p(r, "drawer_fill", where, "total_ms", "median");
          return m === undefined
            ? undefined
            : `${fmt(m)} / ${fmt(p(r, "drawer_fill", where, "main_thread_ms", "median"))} / ${fmt(p(r, "drawer_fill", where, "worker_ms", "median"))}`;
        }]);
      }
      for (const [label, key] of [
        ["slider drag", "drawer_slider_drag"],
        ["wheel drag", "drawer_wheel_drag"],
      ]) {
        rows.push([`${rate} ${n}: ${label}: main / frame, over 16.7 %, frame work p95`, (r) => {
          const m = p(r, key, "main_thread_ms_per_frame", "median");
          return m === undefined
            ? undefined
            : `${fmt(m)}, ${fmt(p(r, key, "frame_aligned", "frames_over_16_7_pct"))}%, ${fmt(p(r, key, "frame_aligned", "frame_work_ms", "p95"))}`;
        }]);
      }
    }
  table("Tools (drawer's canvas)", rows);
}

{
  const rows = [];
  for (const rate of RATES) {
    const p = (r, ...k) => get(r, ["runs_fills", rate, "500", ...k]);
    rows.push([`${rate}: drawer raster / main per frame`, (r) => {
      const m = p(r, "drawer_draw", "raster_ms_per_frame", "median");
      return m === undefined ? undefined : `${fmt(m)} / ${fmt(p(r, "drawer_draw", "main_thread_ms_per_frame", "median"))}`;
    }]);
    rows.push([`${rate}: demo raster / main per frame`, (r) => {
      const m = p(r, "demo_draw", "raster_ms_per_frame", "median");
      return m === undefined ? undefined : `${fmt(m)} / ${fmt(p(r, "demo_draw", "main_thread_ms_per_frame", "median"))}`;
    }]);
    rows.push([`${rate}: viewer apply to DOM / undo painted`, (r) => {
      const m = p(r, "viewer_apply", "dom_ms", "median");
      return m === undefined ? undefined : `${fmt(m)} / ${fmt(p(r, "viewer_undo", "paint_ms", "median"))}`;
    }]);
    rows.push([`${rate}: viewer painted / data to paint / busy until`, (r) => {
      const m = p(r, "viewer_load", "painted_ms", "median");
      return m === undefined
        ? undefined
        : `${fmt(m)} / ${fmt(p(r, "viewer_load", "data_to_paint_ms", "median"))} / ${fmt(p(r, "viewer_load", "thresholded", "busy_until_ms", "median"))}`;
    }]);
    rows.push([`${rate}: drawer painted / demo painted`, (r) => {
      const m = p(r, "drawer_load", "painted_ms");
      return m === undefined ? undefined : `${fmt(m)} / ${fmt(p(r, "demo_load", "painted_ms", "median"))}`;
    }]);
    if (rate === "1x") {
      rows.push([`viewer HTML (gzip) / demo snapshot bytes`, (r) => {
        const b = p(r, "viewer_load", "html_bytes");
        return b === undefined
          ? undefined
          : `${fmt(b)} (${fmt(p(r, "viewer_load", "html_transfer_bytes"))}) / ${fmt(p(r, "demo_load", "snapshot_bytes"))}`;
      }]);
      for (const page of ["viewer", "drawer", "demo"]) {
        rows.push([`${page} heap MB / live / document nodes`, (r) => {
          const h = p(r, `${page}_memory`, "js_heap_bytes");
          return h === undefined
            ? undefined
            : `${fmt(h / 1e6)} / ${fmt(p(r, `${page}_memory`, "dom_nodes"))} / ${fmt(p(r, `${page}_memory`, "document_nodes"))}`;
        }]);
      }
    }
  }
  table("500 strokes with 50 fills (fixtures *-fills-500)", rows);
}

for (const [title, key] of [
  ["Leak check: load-and-clear cycles (heap MB after 1 / 11 / 21; second half growth KB; nodes)", "leak"],
  ["Leak check: rounds with every tool (heap MB after 1 / 11 / 21; second half growth KB; nodes)", "leak_tools"],
]) {
  const rows = [];
  for (const page of ["viewer", "drawer", "demo"]) {
    rows.push([page, (r) => {
      const l = r[key];
      if (!l) return undefined;
      const h = (s) => fmt(s[page].js_heap_bytes / 1e6);
      const g = l[`${page}_growth`];
      return `${h(l.before)} / ${h(l.half)} / ${h(l.after)}; ${fmt(g.second_half.js_heap_bytes / 1000)} KB; ${l.before[page].dom_nodes} -> ${l.after[page].dom_nodes}`;
    }]);
  }
  table(title, rows);
}

{
  const rows = [];
  for (const b of ["runtime", "GamePage", "HomePage", "GameScorePage"]) {
    rows.push([b, (r) => {
      const entry = Object.entries(r.bundles || {}).find(([k]) => k.includes(b === "runtime" ? "runtime-" : `.${b}-`));
      return entry ? `${fmt(entry[1].bytes)} (${fmt(entry[1].gzip)})` : undefined;
    }]);
  }
  table("Bundles (prod release; bytes (gzip))", rows);
}
