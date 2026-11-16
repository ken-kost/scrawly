// Client-side drawing benchmark (bench/README.md): headless Chromium against
// the local production build (bench/prod_server.sh), with and without 4x CPU
// throttling.
//
//   node bench/drawing_client.mjs [--base http://localhost:4100] [--out FILE] [--quick]
//
// Environment: PLAYWRIGHT (path to Playwright's index.mjs, default the
// "playwright" package), CHROME (Chromium executable, default Playwright's
// own), BENCH_* as for bench/prod_server.sh (setup goes through its `rpc`).
//
// One BENCH room in :drawing (a drawer and a viewer, both real signed-in
// pages) and the home page's demo board (an anonymous visitor). For each
// canvas size (0, 100, 300, 500 strokes, loaded through RoomServer and
// DemoBoardServer) and each CPU rate (1x, 4x):
//   drawer:  page load, a 300-move gesture (frames), local undo
//   demo:    page load, a 300-move gesture (frames)
//   viewer:  page load, idle cost, :stroke_completed applied, :drawing_undone
//            applied (strokes committed by the drawer page through its op
//            queue, replayed from fixture strokes)
// then the leak check (20 load-and-clear cycles) at 1x.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CANVASES, strokePlan } from "./lib/fixture_gen.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const QUICK = args.includes("--quick");
const BASE = opt("--base", `http://localhost:${process.env.BENCH_PORT || 4100}`);
const OUT = opt("--out", path.join(HERE, "results", `client-${new Date().toISOString().slice(0, 10)}.json`));
const list = (name) => (opt(name, null) === null ? null : opt(name).split(",").filter(Boolean));
// --only drawer,tools,demo,viewer,fills,leak,leak_tools: those groups only.
const ONLY = list("--only") ? new Set(list("--only")) : null;
const want = (group) => !ONLY || ONLY.has(group);
const SIZES = list("--sizes") ? list("--sizes").map(Number) : QUICK ? [0, 300] : [0, 100, 300, 500];
const RATES = list("--rates") ? list("--rates").map(Number) : [1, 4];
const JOINS = QUICK ? 2 : 4;
const GESTURES = QUICK ? 1 : 4;
const SAMPLES = QUICK ? 4 : 20;
const SNAPSHOTS = QUICK ? 2 : 5;
const MOVES = 300;
const MOVE_MS = 8;
const LEAK_CYCLES = QUICK ? 4 : 20;
// Tools (#38-#43): picks per size, fills per point, the fill points
// (viewBox units; the corner is the white around the drawing) and colours.
const PICKS = QUICK ? 4 : 10;
const FILLS = QUICK ? 2 : 4;
const FILL_POINTS = [
  ["background", 3, 3],
  ["centre", 400, 225],
];
// Not in the fixtures' palette, so never the colour already under the point.
const FILL_COLORS = ["#123456", "#7a3e10", "#0f7f6f", "#6f0f7f"];
// The sets with fills are measured at this size.
const FILLS_SIZE = 500;
// Rounds that use every tool, for the second leak check.
const TOOL_ROUNDS = QUICK ? 4 : 20;
const LEAK_ROOM = 100;
const LEAK_DEMO = 500;
const PASSWORD = "bench-password-36";
const t0 = Date.now();

const pwPath = process.env.PLAYWRIGHT || "playwright";
const { chromium } = await import(pwPath.startsWith("/") ? pathToFileURL(pwPath).href : pwPath);

const log = (...a) => console.error(`[${((Date.now() - t0) / 1000).toFixed(0)}s]`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── Server side (through the release's rpc) ─────────────────────────────
const RPC_FILE = path.join(HERE, "lib", "bench_rpc.exs");
const FIXTURES = path.join(HERE, "fixtures");
function rpc(call) {
  const expr = `Code.compile_file(${JSON.stringify(RPC_FILE)}); ${call}`;
  const out = execFileSync(path.join(HERE, "prod_server.sh"), ["rpc", expr], { encoding: "utf8" });
  const line = out.trim().split("\n").filter((l) => l.startsWith("{")).pop();
  if (!line) throw new Error("rpc printed no JSON: " + out);
  return JSON.parse(line);
}

// ── Stats ────────────────────────────────────────────────────────────────
function pct(xs, p) {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))];
}
const r2 = (x) => (x === null || x === undefined ? null : Math.round(x * 100) / 100);
function summary(xs) {
  return { n: xs.length, median: r2(pct(xs, 50)), p95: r2(pct(xs, 95)), max: r2(xs.length ? Math.max(...xs) : null) };
}

// ── Browser ──────────────────────────────────────────────────────────────
// One browser process per page: pages of one headless browser share its
// frame production, and three of them halve every page's frame rate.
const browsers = [];
async function launch() {
  const b = await chromium.launch({
    executablePath: process.env.CHROME || undefined,
    headless: true,
    args: [
      "--disable-renderer-backgrounding",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      // A page left for the next load stays alive in the back/forward
      // cache and would be counted in the memory figures.
      "--disable-features=BackForwardCache",
    ],
  });
  browsers.push(b);
  return b;
}
const PROBE = fs.readFileSync(path.join(HERE, "lib", "page_probe.js"), "utf8");

async function newPage(viewport = { width: 1280, height: 900 }) {
  const browser = await launch();
  const ctx = await browser.newContext({ viewport });
  await ctx.addInitScript({ content: PROBE });
  const page = await ctx.newPage();
  page.on("pageerror", (e) => log("PAGEERROR", e.message.slice(0, 200)));
  page.on("console", (m) => {
    if (m.type() === "error") log("CONSOLE", m.text().slice(0, 200));
  });
  const cdp = await ctx.newCDPSession(page);
  await cdp.send("Performance.enable");
  return { browser, ctx, page, cdp, rate: 1 };
}

async function setRate(p, rate) {
  await p.cdp.send("Emulation.setCPUThrottlingRate", { rate });
  p.rate = rate;
}

async function login(p, email) {
  await p.page.goto(BASE + "/");
  await p.page.getByRole("button", { name: "log in" }).first().click();
  await p.page.fill('form.app-modal input[name="email"]', email);
  await p.page.fill('form.app-modal input[name="password"]', PASSWORD);
  await p.page.click('form.app-modal button[type="submit"]');
  await p.page.waitForSelector('a[href="/profile"]', { timeout: 20000 });
}

async function blank(p) {
  await p.page.goto("about:blank");
}

// JS heap and DOM nodes after a full GC.
async function memory(p) {
  await p.cdp.send("HeapProfiler.collectGarbage");
  await sleep(200);
  await p.cdp.send("HeapProfiler.collectGarbage");
  const { metrics } = await p.cdp.send("Performance.getMetrics");
  const m = Object.fromEntries(metrics.map((x) => [x.name, x.value]));
  // dom_nodes: every live node of the renderer (detached ones included);
  // document_nodes: the nodes in the document's tree.
  const documentNodes = await p.page.evaluate(() => {
    let n = 0;
    const w = document.createTreeWalker(document, NodeFilter.SHOW_ALL);
    while (w.nextNode()) n++;
    return n;
  });
  return { js_heap_bytes: m.JSHeapUsedSize, dom_nodes: m.Nodes, document_nodes: documentNodes, listeners: m.JSEventListeners };
}

// Memory of the page at `url` showing `expected` strokes in `group`, loaded
// in a new browser context (the same sign-in), so in a renderer process of
// its own: pages loaded one after another in one tab can share a V8 isolate
// with what earlier documents left behind, which then counts in the heap.
async function freshMemory(p, url, group, expected, ready) {
  const ctx = await p.browser.newContext({
    viewport: { width: 1280, height: 900 },
    storageState: await p.ctx.storageState(),
  });
  try {
    await ctx.addInitScript({ content: PROBE });
    const page = await ctx.newPage();
    const cdp = await ctx.newCDPSession(page);
    await cdp.send("Performance.enable");
    const q = { browser: p.browser, ctx, page, cdp, rate: 1 };
    await page.goto(url, { waitUntil: "load" });
    await page.waitForFunction(([g, n]) => window.__bench && window.__bench.counts()[g] === n, [group, expected], {
      timeout: 30000,
    });
    if (ready) await page.waitForFunction(ready, null, { timeout: 30000 });
    await sleep(1000);
    await hideGlow(q);
    return await memory(q);
  } finally {
    await ctx.close();
  }
}

// Main-thread busy ms per second while the page sits idle.
async function idleCost(p, ms) {
  const read = async () => {
    const { metrics } = await p.cdp.send("Performance.getMetrics");
    return metrics.find((x) => x.name === "TaskDuration").value;
  };
  const a = await read();
  await sleep(ms);
  const b = await read();
  return r2(((b - a) * 1000) / (ms / 1000));
}

// Hides the layout's glows (see page_probe.js) and checks it held.
async function hideGlow(p) {
  const hidden = await p.page.evaluate(() => {
    window.__bench.hideGlow();
    const el = document.querySelector(".footer-glow");
    return !el || getComputedStyle(el).display === "none";
  });
  if (!hidden) throw new Error("glow still shown");
}

// Navigates and waits until canvas group `group` shows `expected` strokes;
// returns the load timeline numbers (ms from navigation start).
async function join(p, url, group, expected, ready) {
  await p.page.goto(url, { waitUntil: "load" });
  await p.page.waitForFunction(
    ([g, n]) => window.__bench && window.__bench.counts()[g] === n,
    [group, expected],
    { timeout: 30000 * p.rate }
  );
  if (ready) await p.page.waitForFunction(ready, null, { timeout: 30000 * p.rate });
  await sleep(300 * p.rate);
  // After Hologram has mounted: its first patch would undo it before.
  await hideGlow(p);
  return p.page.evaluate(
    ([g, n]) => {
      const B = window.__bench;
      B.stopTimeline = true;
      const nav = performance.getEntriesByType("navigation")[0];
      const snapshot = B.ws.find((w) => w.kind === "snapshot");
      const dataAt = g === "demo" ? (snapshot ? snapshot.t : null) : nav.responseEnd;
      // The first frame showing all n strokes; on the demo board, one after
      // the snapshot came (an empty board shows 0 before it does: no paint
      // to time then).
      const hit = B.timeline.find((r) => r.counts[g] === n && (g !== "demo" || (dataAt !== null && r.raf >= dataAt)));
      const lt = B.longtasks.filter(([s]) => s < 15000);
      const painted = hit ? hit.painted : null;
      const frameWork = hit && hit.painted !== null ? hit.painted - hit.raf : null;
      return {
        painted_ms: painted,
        data_ms: dataAt,
        data_to_paint_ms: painted !== null && dataAt !== null ? painted - dataAt : null,
        // Demo board: Phoenix's handling of the snapshot frame (decode,
        // store, building the canvas), and the rendering of the first frame
        // showing it.
        snapshot_handler_ms: snapshot ? snapshot.handler : null,
        first_frame_work_ms: frameWork,
        html_bytes: nav.decodedBodySize,
        html_transfer_bytes: nav.encodedBodySize,
        snapshot_bytes: snapshot ? snapshot.bytes : null,
        long_tasks_ms: lt.reduce((a, [, d]) => a + d, 0),
        busy_until_ms: lt.length ? Math.max(...lt.map(([s, d]) => s + d)) : 0,
      };
    },
    [group, expected]
  );
}

function scribble(canvas) {
  const { w, h } = CANVASES[canvas];
  const pts = [];
  for (let k = 0; k <= MOVES; k++) {
    const t = k / MOVES;
    pts.push([
      Math.round(w * (0.5 + 0.42 * Math.sin(2 * Math.PI * 2 * t)) * 10) / 10,
      Math.round(h * (0.5 + 0.4 * Math.sin(2 * Math.PI * 3 * t + 0.5)) * 10) / 10,
    ]);
  }
  return pts;
}

// One 300-move gesture with frame timing: every frame from the first move
// to the release.
// Frames of the same page with nothing happening (headless Chromium misses
// some frames even then): the baseline for frames_over_16_7.
async function idleFrames(p, ms) {
  const iv = await p.page.evaluate(async (ms) => {
    const B = window.__bench;
    B.startFrames();
    await new Promise((r) => setTimeout(r, ms));
    const f = B.stopFrames();
    const out = [];
    for (let i = 1; i < f.raf.length; i++) out.push(f.raf[i] - f.raf[i - 1]);
    return out;
  }, ms);
  return { frames: iv.length, frames_over_16_7_pct: r2((100 * iv.filter((x) => x > 17.7).length) / Math.max(1, iv.length)) };
}

// A Chromium trace around `fn` (categories cc, viz) for the time spent off
// the main thread, which the frame work figure doesn't see: raster tasks
// (all raster workers) and the display compositor's draws, in ms.
async function traced(p, fn) {
  await p.cdp.send("Tracing.start", { categories: "cc,viz", transferMode: "ReturnAsStream" });
  const result = await fn();
  const done = new Promise((r) => p.cdp.once("Tracing.tracingComplete", r));
  await p.cdp.send("Tracing.end");
  const { stream } = await done;
  let data = "";
  for (;;) {
    const chunk = await p.cdp.send("IO.read", { handle: stream });
    data += chunk.data;
    if (chunk.eof) break;
  }
  await p.cdp.send("IO.close", { handle: stream });
  let raster = 0;
  let viz = 0;
  let main = 0;
  for (const e of JSON.parse(data).traceEvents || []) {
    if (e.ph !== "X") continue;
    if (e.name === "RasterTask") raster += e.dur || 0;
    else if (e.name === "Display::DrawAndSwap") viz += e.dur || 0;
    // The renderer main thread's frame: rAF callbacks, style, layout,
    // paint, commit.
    else if (e.name === "ProxyMain::BeginMainFrame") main += e.dur || 0;
  }
  return { ...result, raster_ms: raster / 1000, viz_ms: viz / 1000, main_ms: main / 1000 };
}

// One 300-move gesture with frame timing: every frame from the first move
// to the release.
async function drawGesture(p, svgId, canvas) {
  return traced(p, () =>
    p.page.evaluate(
      async ([svgId, pts, ms]) => {
        const B = window.__bench;
        B.startFrames();
        await new Promise((r) => requestAnimationFrame(() => r()));
        const g = await B.gesture(svgId, pts, ms);
        const f = B.stopFrames();
        const intervals = [];
        for (let i = 1; i < f.raf.length; i++) intervals.push(f.raf[i] - f.raf[i - 1]);
        return { gesture_ms: g.ms, intervals, work: f.work };
      },
      [svgId, scribble(canvas), MOVE_MS]
    )
  );
}

function frameStats(gestures) {
  const intervals = gestures.flatMap((g) => g.intervals);
  const work = gestures.flatMap((g) => g.work);
  return {
    frames: intervals.length,
    // Tied to the 60 Hz frame clock (multiples of 16.7 ms), so their medians
    // jump between runs: not part of the agreement check.
    frame_aligned: {
      frame_ms: summary(intervals),
      // A frame that missed its 16.7 ms slot shows up as a longer interval;
      // the 1 ms slack absorbs timer jitter.
      frames_over_16_7: intervals.filter((x) => x > 17.7).length,
      frames_over_16_7_pct: r2((100 * intervals.filter((x) => x > 17.7).length) / Math.max(1, intervals.length)),
      // Each frame from its first rAF callback to the end of its rendering,
      // as the page sees it: tasks queued in between (the gesture's own
      // input) land in it too, so its median wanders between runs; the
      // trace's main_thread_ms_per_frame is the compared figure.
      frame_work_ms: summary(work),
    },
    // Per frame produced (each gesture's total over its frames): the main
    // thread's frame work (rAF callbacks, style, layout, paint, commit), and
    // off the main thread raster (all workers) and the display compositor.
    main_thread_ms_per_frame: summary(gestures.map((g) => g.main_ms / Math.max(1, g.intervals.length))),
    raster_ms_per_frame: summary(gestures.map((g) => g.raster_ms / Math.max(1, g.intervals.length))),
    compositor_ms_per_frame: summary(gestures.map((g) => g.viz_ms / Math.max(1, g.intervals.length))),
    gesture_ms: summary(gestures.map((g) => g.gesture_ms)),
  };
}

const queueIdle = () => {
  const s = window.__scrawlyGameCanvas;
  return !!s && s.queue.length === 0;
};

async function drawerHistory(p) {
  return p.page.evaluate(() => (window.__scrawlyGameCanvas ? window.__scrawlyGameCanvas.history.length : -1));
}

async function waitQueue(p) {
  await p.page.waitForFunction(queueIdle, null, { timeout: 20000 * p.rate });
}

// The drawer's Ctrl+Z (draw_controls.mjs -> :undo_drawing -> undoStroke):
// keydown to the stroke's node gone, and to the next frame.
async function drawerUndo(p, expected) {
  const wait = p.page.evaluate((n) => window.__bench.waitCount("game-canvas-drawer-strokes", n, 10000), expected);
  await p.page.keyboard.press("Control+z");
  const r = await wait;
  const key = await p.page.evaluate(() => window.__bench.lastKey);
  await waitQueue(p);
  return r ? { dom: r.tDom - key, frame: r.tPaint - r.tRaf, wall: r.tPaint - key } : null;
}

// Medium fixture strokes, replayed as drawer gestures for the viewer runs.
const MEDIUM = [];
for (let i = 0; MEDIUM.length < 40 && i < 500; i++) {
  const s = strokePlan("game", i);
  if (s.kind === "medium") MEDIUM.push(s.points);
}

async function viewerApply(viewer, drawer, expectedAfter, strokeIndex) {
  const wait = viewer.page.evaluate(
    (n) => window.__bench.waitCount("game-canvas-strokes", n, 15000),
    expectedAfter
  );
  const logs0 = await viewer.page.evaluate(() => window.__bench.silenced);
  await drawer.page.evaluate(([pts]) => window.__bench.gesture("game-canvas-svg", pts, 0), [MEDIUM[strokeIndex % MEDIUM.length]]);
  const r = await wait;
  await sleep(150);
  return viewer.page.evaluate(
    ([r, kind, logs0]) => {
      if (!r) return null;
      const B = window.__bench;
      const ev = B.lastSse(kind, r.tDom);
      if (!ev) return null;
      return {
        handler: ev.handler,
        dom: r.tDom - ev.t,
        frame: r.tPaint - r.tRaf,
        wall: r.tPaint - ev.t,
        long_tasks: B.longtasksBetween(ev.t, r.tPaint),
        hologram_logs: B.silenced - logs0,
      };
    },
    [r, "stroke_completed", logs0]
  );
}

async function viewerUndo(viewer, drawer, expectedAfter) {
  const wait = viewer.page.evaluate(
    (n) => window.__bench.waitCount("game-canvas-strokes", n, 15000),
    expectedAfter
  );
  const drawerCount = await drawerHistory(drawer);
  const local = await drawerUndo(drawer, drawerCount - 1);
  const r = await wait;
  await sleep(100);
  const remote = await viewer.page.evaluate(
    ([r]) => {
      if (!r) return null;
      const B = window.__bench;
      const ev = B.lastSse("drawing_undone", r.tDom);
      return ev
        ? { dom: r.tDom - ev.t, frame: r.tPaint - r.tRaf, wall: r.tPaint - ev.t, long_tasks: B.longtasksBetween(ev.t, r.tPaint) }
        : null;
    },
    [r]
  );
  return { local, remote };
}

function applyStats(rows) {
  rows = rows.filter(Boolean);
  const lt = rows.flatMap((r) => r.long_tasks || []);
  const out = {
    samples: rows.length,
    // From the push (or keydown) to the change in the DOM.
    dom_ms: summary(rows.map((r) => r.dom)),
    // That plus the rendering of the frame that shows it: the main-thread
    // cost of getting it on screen, without the wait for that frame.
    paint_ms: summary(rows.map((r) => r.dom + r.frame)),
    frame_aligned: {
      // Wall clock to the end of that frame, wait included.
      wall_paint_ms: summary(rows.map((r) => r.wall)),
    },
    thresholded: {
      long_tasks: lt.length,
      long_task_max_ms: r2(lt.length ? Math.max(...lt) : 0),
    },
  };
  if (rows.length && rows[0].handler !== undefined) out.sse_handler_ms = summary(rows.map((r) => r.handler));
  if (rows.length && rows[0].hologram_logs !== undefined) out.hologram_logs_per_apply = pct(rows.map((r) => r.hologram_logs), 50);
  return out;
}

// ── Tools on the drawer's canvas (since #38-#43) ────────────────────────

// The size ring following a mouse over the canvas, no button held (300
// moves, the gesture's path): ms per frame from a trace, as for a gesture.
async function hoverGesture(p, svgId, canvas) {
  return traced(p, () =>
    p.page.evaluate(
      async ([svgId, pts, ms]) => {
        const B = window.__bench;
        B.startFrames();
        await new Promise((r) => requestAnimationFrame(() => r()));
        const g = await B.gesture(svgId, pts, ms, null, true);
        const f = B.stopFrames();
        const intervals = [];
        for (let i = 1; i < f.raf.length; i++) intervals.push(f.raf[i] - f.raf[i - 1]);
        return { gesture_ms: g.ms, intervals, work: f.work };
      },
      [svgId, scribble(canvas), MOVE_MS]
    )
  );
}

// Eyedropper picks (Alt + click with the brush, eyedropper.mjs) at points
// spread over the canvas: the pointerdown handler (the canvas's colour at
// the point, the tool model, the queued :color_picked) and that plus the
// next frame's rendering.
async function picks(p, svgId) {
  const rows = [];
  for (let i = 0; i < PICKS; i++) {
    const x = 40 + ((i * 97) % 720);
    const y = 30 + ((i * 53) % 390);
    rows.push(await p.page.evaluate(([svgId, x, y]) => window.__bench.press(svgId, x, y, { altKey: true }), [svgId, x, y]));
    await sleep(150 * p.rate);
  }
  return {
    samples: rows.length,
    handler_ms: summary(rows.map((r) => r.handler)),
    paint_ms: summary(rows.map((r) => r.handler + r.frame)),
  };
}

// Main-thread and fill-worker busy time between two performance marks, from
// a trace (top-level tasks of the renderer's main thread and of the
// dedicated worker).
async function tracedTasks(p, fn) {
  await p.cdp.send("Tracing.start", {
    categories: "toplevel,blink.user_timing,__metadata",
    transferMode: "ReturnAsStream",
  });
  const result = await fn();
  const done = new Promise((r) => p.cdp.once("Tracing.tracingComplete", r));
  await p.cdp.send("Tracing.end");
  const { stream } = await done;
  let data = "";
  for (;;) {
    const chunk = await p.cdp.send("IO.read", { handle: stream });
    data += chunk.data;
    if (chunk.eof) break;
  }
  await p.cdp.send("IO.close", { handle: stream });
  const events = JSON.parse(data).traceEvents || [];
  const names = {};
  for (const e of events) if (e.ph === "M" && e.name === "thread_name") names[e.pid + ":" + e.tid] = e.args.name;
  const marks = {};
  for (const e of events) if (e.name === "bench-start" || e.name === "bench-end") marks[e.name] = e.ts;
  let main = 0;
  let worker = 0;
  let longest = 0;
  if (marks["bench-start"] && marks["bench-end"]) {
    const a = marks["bench-start"];
    const b = marks["bench-end"];
    for (const e of events) {
      if (e.ph !== "X" || e.name !== "ThreadControllerImpl::RunTask") continue;
      const s = Math.max(a, e.ts);
      const t = Math.min(b, e.ts + (e.dur || 0));
      if (t <= s) continue;
      const n = names[e.pid + ":" + e.tid] || "";
      if (n === "CrRendererMain") {
        main += t - s;
        longest = Math.max(longest, e.dur || 0);
      } else if (/DedicatedWorker/.test(n)) worker += t - s;
    }
  }
  return { ...result, main_ms: main / 1000, worker_ms: worker / 1000, longest_task_ms: longest / 1000 };
}

// Fills (the fill tool, F) at a point: from the pointerdown to the frame
// after the shape's node was added (worker round trip included), with the
// main thread's and the worker's busy time in that window; each fill is
// then undone. "background" is the white around the drawing (the corner):
// the biggest area, around every stroke.
async function fills(p, n) {
  await p.page.keyboard.press("f");
  await p.page.waitForFunction(() => window.__scrawlyDrawTool && window.__scrawlyDrawTool.tool === "fill", null, {
    timeout: 10000 * p.rate,
  });
  // The worker starts and rasters the canvas ahead ("prepare").
  await sleep(1500 * p.rate);
  const out = {};
  for (const [name, x, y] of FILL_POINTS) {
    const rows = [];
    for (let k = 0; k < FILLS; k++) {
      const before = await drawerHistory(p);
      const r = await tracedTasks(p, () =>
        p.page.evaluate(
          async ([x, y, color, before, timeout]) => {
            const B = window.__bench;
            window.__scrawlyDrawTool.color = color;
            const wait = B.waitCount("game-canvas-drawer-strokes", before + 1, timeout);
            performance.mark("bench-start");
            const press = await B.press("game-canvas-svg", x, y);
            const hit = await wait;
            performance.mark("bench-end");
            return hit ? { press: press.handler, total: hit.tPaint - press.t0, dom: hit.tDom - press.t0 } : null;
          },
          [x, y, FILL_COLORS[k % FILL_COLORS.length], before, 15000 * p.rate]
        )
      );
      if (r.press === undefined) {
        log(`  fill ${name} at ${n}: no shape came`);
        continue;
      }
      rows.push(r);
      await waitQueue(p);
      await drawerUndo(p, before);
      await sleep(200 * p.rate);
    }
    out[name] = {
      samples: rows.length,
      press_ms: summary(rows.map((r) => r.press)),
      total_ms: summary(rows.map((r) => r.total)),
      main_thread_ms: summary(rows.map((r) => r.main_ms)),
      worker_ms: summary(rows.map((r) => r.worker_ms)),
      longest_task_ms: summary(rows.map((r) => r.longest_task_ms)),
    };
  }
  await p.page.keyboard.press("b");
  await p.page.waitForFunction(() => window.__scrawlyDrawTool.tool === "brush", null, { timeout: 10000 * p.rate });
  return out;
}

// A one-second mouse drag (60 moves, real input through CDP) along `pointAt`
// (f in [0, 1] -> client {x, y}).
async function mouseDrag(p, pointAt) {
  const steps = 60;
  const p0 = pointAt(0);
  await p.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: p0.x, y: p0.y, button: "none", buttons: 0 });
  await p.cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x: p0.x, y: p0.y, button: "left", buttons: 1, clickCount: 1 });
  const start = Date.now();
  for (let i = 1; i <= steps; i++) {
    const wait = start + (1000 * i) / steps - Date.now();
    if (wait > 0) await sleep(wait);
    const q = pointAt(i / steps);
    await p.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: q.x, y: q.y, button: "left", buttons: 1 });
  }
  const p1 = pointAt(1);
  await p.cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: p1.x, y: p1.y, button: "left", buttons: 0, clickCount: 1 });
}

// A control drag (the size slider, the colour wheel) traced like a
// gesture, with the Hologram actions it ran.
async function controlDrag(p, pointAt) {
  const r = await traced(p, async () => {
    await p.page.evaluate(() => {
      window.__bench.actions = {};
      window.__bench.startFrames();
    });
    await mouseDrag(p, pointAt);
    await sleep(150);
    return p.page.evaluate(() => {
      const f = window.__bench.stopFrames();
      const intervals = [];
      for (let i = 1; i < f.raf.length; i++) intervals.push(f.raf[i] - f.raf[i - 1]);
      return { intervals, work: f.work, actions: window.__bench.actions };
    });
  });
  const stats = frameStats([r]);
  delete stats.gesture_ms;
  // The page's own timers (countdown, presence) aren't the drag's.
  const { countdown_tick: _c, presence_ping: _p, ...actions } = r.actions || {};
  stats.actions = actions;
  return stats;
}

async function sliderDrag(p, shell) {
  const box = await p.page.locator(`${shell} input[data-draw-size]`).boundingBox();
  const out = await controlDrag(p, (f) => ({ x: box.x + 4 + (box.width - 8) * (0.1 + 0.8 * Math.sin(Math.PI * f)), y: box.y + box.height / 2 }));
  // Back to the default size (the page's action pushes it to the model).
  await p.page.evaluate(() => globalThis.Hologram.dispatchAction("select_size", "page", { size: 4 }));
  await sleep(300 * p.rate);
  return out;
}

async function wheelDrag(p, shell) {
  await p.page.click(`${shell} .color-chip`);
  await p.page.waitForSelector(`${shell} [data-color-wheel]`, { state: "visible", timeout: 10000 * p.rate });
  await sleep(400 * p.rate);
  const wb = await p.page.locator(`${shell} [data-color-wheel]`).boundingBox();
  const out = await controlDrag(p, (f) => ({
    x: wb.x + wb.width / 2 + 0.8 * (wb.width / 2) * Math.cos(2 * Math.PI * f),
    y: wb.y + wb.height / 2 - 0.8 * (wb.height / 2) * Math.sin(2 * Math.PI * f),
  }));
  await p.page.keyboard.press("Escape");
  await sleep(200 * p.rate);
  await p.page.evaluate(() => globalThis.Hologram.dispatchAction("select_color", "page", { color: "#0a0a0a" }));
  await sleep(300 * p.rate);
  return out;
}

// ── Run ──────────────────────────────────────────────────────────────────
const bundles = JSON.parse(execFileSync(path.join(HERE, "prod_server.sh"), ["bundles"], { encoding: "utf8" }));
log("setup: room, users");
const setup = rpc(`BenchRpc.setup(${JSON.stringify(PASSWORD)})`);
const roomUrl = `${BASE}/game/${setup.room_id}`;
const drawer = await newPage();
const viewer = await newPage();
const visitor = await newPage();
await login(drawer, setup.drawer.email);
await login(viewer, setup.viewer.email);
await blank(drawer);
await blank(viewer);

// Two unmeasured loads of each page first: the first navigations of a fresh
// browser (cold HTTP cache and code caches) are slower than the rest.
const warmUp = async (p, url) => {
  for (let i = 0; i < 2; i++) {
    await p.page.goto(url, { waitUntil: "load" });
    await sleep(1000);
  }
  await blank(p);
};
await warmUp(drawer, `${BASE}/game/${setup.room_id}`);
await warmUp(viewer, `${BASE}/game/${setup.room_id}`);
await warmUp(visitor, BASE + "/");

const drawerReady = () => {
  const e = window.__scrawlyGameStrokeEngine;
  return !!e && e.isEnabled() && !!document.getElementById("game-page-marker");
};
const viewerReady = () => !!document.getElementById("game-page-marker") && window.__bench.sseOpen();
const demoReady = () => !!window.__scrawlyDemoStrokeEngine && window.__scrawlyDemoStrokeEngine.isEnabled();

const results = {
  meta: {
    date: new Date().toISOString(),
    base: BASE,
    quick: QUICK,
    only: ONLY ? [...ONLY] : null,
    browser: browsers[0].version(),
    moves: MOVES,
    move_interval_ms: MOVE_MS,
    joins: JOINS,
    gestures: GESTURES,
    samples: SAMPLES,
  },
  bundles,
  runs: {},
};

// A phase that fails is logged and recorded (results.errors), and the run
// goes on with the next one: a late failure never loses the figures
// already taken. The results file is written after every phase.
async function phase(name, fn) {
  try {
    await fn();
  } catch (e) {
    log(`PHASE ${name} FAILED: ${(e && e.message) || e}`);
    (results.errors ||= []).push({ phase: name, error: String((e && e.stack) || e).slice(0, 2000) });
  }
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(results, null, 2) + "\n");
}

// One canvas size `n` of fixture set `set` ("game"/"demo" or
// "game-fills"/"demo-fills"), at every rate, into `target`. `extras`: the
// glow and tool scenarios (the main sizes only); `on(group)`: the groups
// to run ("drawer", "tools", "demo", "viewer").
async function runSize(n, set, target, extras, on) {
  log(`== ${n} strokes (${set})`);
  await blank(drawer);
  await blank(viewer);
  await blank(visitor);
  const loaded = rpc(
    `BenchRpc.load_room(${JSON.stringify(FIXTURES)}, ${JSON.stringify(setup.room_id)}, ${JSON.stringify(setup.drawer.id)}, ${n}, ${JSON.stringify(set)})`
  );
  if (loaded.room_strokes !== n) throw new Error("room holds " + loaded.room_strokes);
  const demoSet = set.replace(/^game/, "demo");

  for (const rate of RATES) {
    const key = `${rate}x`;
    const row = (target[key] ||= {})[n] = {};
    await setRate(drawer, rate);
    await setRate(viewer, rate);
    await setRate(visitor, rate);
    // What the board holds: since #44 its byte cap keeps fewer than 500 of
    // the fixture strokes.
    const demoHeld = rpc(`BenchRpc.load_demo(${JSON.stringify(FIXTURES)}, ${n}, ${JSON.stringify(demoSet)})`).demo_strokes;

    // Drawer: load (restoreStrokes), gestures, back to n strokes. The page
    // is loaded whenever the viewer runs too (it draws the viewer's strokes).
    if (on("drawer") || on("tools") || on("viewer")) {
      const drawerJoin = await join(drawer, roomUrl, "drawer", n, drawerReady);
      if (on("drawer")) {
        row.drawer_load = drawerJoin;
        if (rate === 1) row.drawer_memory = await freshMemory(drawer, roomUrl, "drawer", n, drawerReady);
        const drawerIdle = await idleFrames(drawer, 1000);
        const gestures = [];
        for (let g = 0; g < GESTURES; g++) {
          gestures.push(await drawGesture(drawer, "game-canvas-svg", "game"));
          await waitQueue(drawer);
          // A full room (500) rejects the commit and resets the canvas itself.
          while ((await drawerHistory(drawer)) > n) await drawerUndo(drawer, (await drawerHistory(drawer)) - 1);
          await sleep(200);
        }
        row.drawer_draw = frameStats(gestures);
        row.drawer_draw.frame_aligned.idle = drawerIdle;

        // The same gesture with the layout's glows shown (see page_probe.js).
        if (extras && rate === 1 && (n === SIZES[0] || n === SIZES[SIZES.length - 1])) {
          await drawer.page.evaluate(() =>
            document.querySelectorAll(".nav-glow, .footer-glow").forEach((el) => (el.style.display = ""))
          );
          await sleep(500);
          const glowIdle = await idleFrames(drawer, 1000);
          const glowGesture = await drawGesture(drawer, "game-canvas-svg", "game");
          await waitQueue(drawer);
          while ((await drawerHistory(drawer)) > n) await drawerUndo(drawer, (await drawerHistory(drawer)) - 1);
          await hideGlow(drawer);
          row.drawer_draw_with_glow = frameStats([glowGesture]);
          row.drawer_draw_with_glow.frame_aligned.idle = glowIdle;
        }
        log(
          `  ${key} drawer draw p95 ${row.drawer_draw.frame_aligned.frame_ms.p95} ms, main/frame ${row.drawer_draw.main_thread_ms_per_frame.median}, ` +
            `raster/frame ${row.drawer_draw.raster_ms_per_frame.median}`
        );
      }

      // The tools of #38-#43 on the drawer's canvas.
      if (extras && on("tools")) {
        const hovers = [];
        for (let g = 0; g < Math.max(1, GESTURES / 2); g++) hovers.push(await hoverGesture(drawer, "game-canvas-svg", "game"));
        row.drawer_hover = frameStats(hovers);
        row.drawer_pick = await picks(drawer, "game-canvas-svg");
        await drawer.page.evaluate(() => globalThis.Hologram.dispatchAction("select_color", "page", { color: "#0a0a0a" }));
        // A full canvas takes no fill: make room for it, and put the stroke
        // back after.
        if (n >= 500) await drawerUndo(drawer, n - 1);
        row.drawer_fill = await fills(drawer, n);
        if (n >= 500) {
          await drawer.page.evaluate(([pts]) => window.__bench.gesture("game-canvas-svg", pts, 0), [MEDIUM[0]]);
          await waitQueue(drawer);
        }
        row.drawer_slider_drag = await sliderDrag(drawer, ".canvas-shell");
        row.drawer_wheel_drag = await wheelDrag(drawer, ".canvas-shell");
        log(
          `  ${key} tools: hover main/frame ${row.drawer_hover.main_thread_ms_per_frame.median}, pick ${row.drawer_pick.handler_ms.median} ms, ` +
            `fill bg ${row.drawer_fill.background && row.drawer_fill.background.total_ms.median} ms, ` +
            `slider over 16.7 ${row.drawer_slider_drag.frame_aligned.frames_over_16_7_pct}%, wheel ${row.drawer_wheel_drag.frame_aligned.frames_over_16_7_pct}%`
        );
      }
    }

    // Demo board: loads, gestures.
    if (on("demo")) {
      const demoJoins = [];
      for (let j = 0; j < JOINS; j++) demoJoins.push(await join(visitor, BASE + "/", "demo", demoHeld, demoReady));
      row.demo_load = loadStats(demoJoins);
      row.demo_load.strokes_held = demoHeld;
      if (rate === 1) row.demo_memory = await freshMemory(visitor, BASE + "/", "demo", demoHeld, demoReady);
      const resnaps = [];
      // An empty board's snapshot has nothing to render.
      for (let j = 0; j < (n > 0 ? SNAPSHOTS : 0); j++) {
        resnaps.push(await visitor.page.evaluate((ms) => window.__bench.resnapshot(ms), 15000 * rate));
        await sleep(300);
      }
      row.demo_snapshot = {
        samples: resnaps.filter(Boolean).length,
        handler_ms: summary(resnaps.filter(Boolean).map((r) => r.handler)),
        // The snapshot handled and on screen: handler plus the next frame's
        // rendering, without the wait for that frame.
        paint_ms: summary(resnaps.filter(Boolean).map((r) => r.handler + r.frame)),
        frame_aligned: { wall_paint_ms: summary(resnaps.filter(Boolean).map((r) => r.wall)) },
      };
      const demoIdle = await idleFrames(visitor, 1000);
      const demoGestures = [];
      for (let g = 0; g < GESTURES; g++) {
        demoGestures.push(await drawGesture(visitor, "demo-board-svg", "demo"));
        await sleep(400);
      }
      row.demo_draw = frameStats(demoGestures);
      row.demo_draw.frame_aligned.idle = demoIdle;
      log(
        `  ${key} demo draw p95 ${row.demo_draw.frame_aligned.frame_ms.p95} ms, raster/frame ${row.demo_draw.raster_ms_per_frame.median}; ` +
          `load paint ${row.demo_load.painted_ms.median} ms`
      );
      await blank(visitor);
    }

    // Viewer: loads, idle cost, applied strokes and undos.
    if (on("viewer")) {
      const viewerJoins = [];
      for (let j = 0; j < JOINS; j++) viewerJoins.push(await join(viewer, roomUrl, "viewer", n, viewerReady));
      row.viewer_load = loadStats(viewerJoins);
      if (rate === 1) row.viewer_memory = await freshMemory(viewer, roomUrl, "viewer", n, viewerReady);
      row.viewer_idle_busy_ms_per_s = await idleCost(viewer, 2000);

      // The room is full at 500: make room for the strokes the samples add.
      let held = n;
      if (n >= 500) {
        await drawerUndo(drawer, 499);
        await viewer.page.waitForFunction(() => window.__bench.counts().viewer === 499, null, { timeout: 20000 });
        held = 499;
      }
      const applies = [];
      const undos = [];
      for (let s = 0; s < SAMPLES; s++) {
        applies.push(await viewerApply(viewer, drawer, held + 1, s));
        await waitQueue(drawer);
        undos.push(await viewerUndo(viewer, drawer, held));
        await sleep(150);
      }
      row.viewer_apply = applyStats(applies);
      row.viewer_undo = applyStats(undos.map((u) => u.remote));
      row.drawer_undo = applyStats(undos.map((u) => u.local));

      // What the console logging costs when it is not dropped (1x, 300).
      if (extras && rate === 1 && n === 300 && !QUICK) {
        await viewer.page.evaluate(() => (window.__bench.passLogs = true));
        const logged = [];
        for (let s = 0; s < 8; s++) {
          logged.push(await viewerApply(viewer, drawer, held + 1, s));
          await waitQueue(drawer);
          await viewerUndo(viewer, drawer, held);
        }
        await viewer.page.evaluate(() => (window.__bench.passLogs = false));
        row.viewer_apply_with_console_logs = applyStats(logged);
      }

      if (n >= 500) {
        // Back to 500 for the next pass.
        await viewerApply(viewer, drawer, 500, 0);
        await waitQueue(drawer);
      }
      log(
        `  ${key} viewer apply dom ${row.viewer_apply.dom_ms.median}/${row.viewer_apply.dom_ms.p95} ms, ` +
          `paint ${row.viewer_apply.paint_ms.median}; load paint ${row.viewer_load.painted_ms.median} ms`
      );
      await blank(viewer);
    }
  }
}

if (["drawer", "tools", "demo", "viewer"].some(want)) {
  for (const n of SIZES) await phase(`size ${n}`, () => runSize(n, "game", results.runs, true, want));
}
// The sets with fills (every tenth stroke a fill), at 500.
if (want("fills")) {
  results.runs_fills = {};
  await phase("fills", () => runSize(FILLS_SIZE, "game-fills", results.runs_fills, false, (g) => g !== "tools"));
}

function loadStats(rows) {
  const pick = (k) => rows.map((r) => r[k]).filter((x) => x !== null && x !== undefined);
  const demo = rows[0].snapshot_bytes !== null;
  const cost = rows
    .filter((r) => r.snapshot_handler_ms !== null && r.first_frame_work_ms !== null && r.painted_ms !== null)
    .map((r) => r.snapshot_handler_ms + r.first_frame_work_ms);
  return {
    loads: rows.length,
    painted_ms: summary(pick("painted_ms")),
    ...(demo
      ? {
          // The snapshot's handling plus the first frame showing it, without
          // the wait for that frame (wall clock in frame_aligned).
          // During the load the snapshot's handling and the next frame
          // share the main thread with the page's boot, so these move
          // between runs; the snapshot's cost is taken on an idle page
          // instead (demo_snapshot).
          during_load: {
            snapshot_handler_ms: summary(pick("snapshot_handler_ms")),
            data_to_paint_ms: summary(cost),
            data_to_paint_wall_ms: summary(pick("data_to_paint_ms")),
          },
        }
      : { data_to_paint_ms: summary(pick("data_to_paint_ms")) }),
    // Sums of tasks over 50 ms: a task just under or over the line moves
    // them by its whole length, so they are not part of the agreement check.
    thresholded: {
      long_tasks_ms: summary(pick("long_tasks_ms")),
      busy_until_ms: summary(pick("busy_until_ms")),
    },
    html_bytes: rows[0].html_bytes,
    html_transfer_bytes: rows[0].html_transfer_bytes,
    snapshot_bytes: rows[0].snapshot_bytes,
  };
}

// ── Leak check (1x) ──────────────────────────────────────────────────────
const loadRoomCall = (k, set = "game") =>
  rpc(
    `BenchRpc.load_room(${JSON.stringify(FIXTURES)}, ${JSON.stringify(setup.room_id)}, ${JSON.stringify(setup.drawer.id)}, ${k}, ${JSON.stringify(set)})`
  );
const loadDemoCall = (k, set = "demo") => rpc(`BenchRpc.load_demo(${JSON.stringify(FIXTURES)}, ${k}, ${JSON.stringify(set)})`);
const snap = async () => ({ drawer: await memory(drawer), viewer: await memory(viewer), demo: await memory(visitor) });
const diff = (a, b) => ({
  js_heap_bytes: b.js_heap_bytes - a.js_heap_bytes,
  dom_nodes: b.dom_nodes - a.dom_nodes,
  listeners: b.listeners - a.listeners,
});
function growth(out, before, half, after) {
  for (const k of ["drawer", "viewer", "demo"]) {
    out[k + "_growth"] = { first_half: diff(before[k], half[k]), second_half: diff(half[k], after[k]) };
    log(
      `  ${k}: heap ${before[k].js_heap_bytes} -> ${half[k].js_heap_bytes} -> ${after[k].js_heap_bytes}, ` +
        `nodes ${before[k].dom_nodes} -> ${half[k].dom_nodes} -> ${after[k].dom_nodes}`
    );
  }
}
async function settle(roomCount, demoCount) {
  await drawer.page.waitForFunction((n) => window.__bench.counts().drawer === n, roomCount, { timeout: 120000 });
  await viewer.page.waitForFunction((n) => window.__bench.counts().viewer === n, roomCount, { timeout: 120000 });
  await visitor.page.waitForFunction((n) => window.__bench.counts().demo === n, demoCount, { timeout: 120000 });
  await sleep(1500);
}

if (want("leak")) await phase("leak", async () => {
  log("== leak check");
  for (const p of [drawer, viewer, visitor]) await setRate(p, 1);
  loadRoomCall(LEAK_ROOM);
  // The board's byte cap keeps fewer than LEAK_DEMO fixture strokes.
  const demoHeld = loadDemoCall(LEAK_DEMO).demo_strokes;
  await join(drawer, roomUrl, "drawer", LEAK_ROOM, drawerReady);
  await join(viewer, roomUrl, "viewer", LEAK_ROOM, viewerReady);
  await join(visitor, BASE + "/", "demo", demoHeld, demoReady);

  const cyclesCall = (k) =>
    rpc(
      `BenchRpc.cycles(${JSON.stringify(FIXTURES)}, ${JSON.stringify(setup.room_id)}, ${JSON.stringify(setup.drawer.id)}, ${LEAK_ROOM}, ${LEAK_DEMO}, ${k}, 800)`
    );
  // One cycle first (warms the code paths), then the cycles in two halves:
  // growth that goes on in the second half is a leak, growth that stops is
  // warm-up.
  cyclesCall(1);
  await settle(LEAK_ROOM, demoHeld);
  const before = await snap();
  cyclesCall(LEAK_CYCLES / 2);
  await settle(LEAK_ROOM, demoHeld);
  const half = await snap();
  cyclesCall(LEAK_CYCLES / 2);
  await settle(LEAK_ROOM, demoHeld);
  const after = await snap();
  results.leak = { cycles: LEAK_CYCLES, room_strokes: LEAK_ROOM, demo_strokes: LEAK_DEMO, demo_strokes_held: demoHeld, before, half, after };
  growth(results.leak, before, half, after);
});

// ── Leak check with every tool (1x) ──────────────────────────────────────
// Rounds in which the drawer (game) and the visitor (home board) each use
// every tool: three brush strokes, a Ctrl stroke and a right-button stroke
// (erasing), an Alt+click pick, the size keys, a pick on the colour wheel,
// a fill, an undo (the fill), then the toolbar's clear; the viewer follows
// the game canvas. Heap and nodes after a first round, 10 more and 10 more.
async function toolRound(p, svgId, group, shell, isGame) {
  const count = () => p.page.evaluate((g) => window.__bench.counts()[g], group);
  const settled = async (n) => {
    try {
      await p.page.waitForFunction(([g, n]) => window.__bench.counts()[g] === n, [group, n], { timeout: 30000 });
    } catch (e) {
      const why = await p.page.evaluate((g) => {
        const f = window.__scrawlyFill;
        return {
          count: window.__bench.counts()[g],
          tool: window.__scrawlyDrawTool,
          fill: f && { ready: f.ready, pending: !!f.pending, canvases: [...f.canvases.keys()] },
          notice: [...document.querySelectorAll(".canvas-notice")].map((el) => el.textContent),
          active: document.activeElement && document.activeElement.outerHTML.slice(0, 120),
        };
      }, group);
      throw new Error(`tool round on ${group}: ${n} expected, ${JSON.stringify(why)}`);
    }
    if (isGame) await waitQueue(p);
  };
  const gesture = async (pts, mods) => {
    const n = await count();
    await p.page.evaluate(([svgId, pts, mods]) => window.__bench.gesture(svgId, pts, 0, mods), [svgId, pts, mods]);
    await settled(n + 1);
  };
  for (let k = 0; k < 3; k++) await gesture(MEDIUM[k], null);
  await gesture(MEDIUM[3], { ctrlKey: true });
  await gesture(MEDIUM[4], { button: 2 });
  await p.page.evaluate((svgId) => window.__bench.press(svgId, 300, 200, { altKey: true }), svgId);
  for (const key of ["]", "]", "]", "[", "[", "["]) await p.page.keyboard.press(key);
  await p.page.click(`${shell} .color-chip`);
  await p.page.waitForSelector(`${shell} [data-color-wheel]`, { state: "visible", timeout: 10000 });
  const wb = await p.page.locator(`${shell} [data-color-wheel]`).boundingBox();
  await p.page.mouse.click(wb.x + wb.width * 0.7, wb.y + wb.height * 0.4);
  await p.page.keyboard.press("Escape");
  await p.page.keyboard.press("f");
  await p.page.waitForFunction(() => window.__scrawlyDrawTool.tool === "fill", null, { timeout: 10000 });
  const n = await count();
  await p.page.evaluate((svgId) => window.__bench.press(svgId, 3, 3), svgId);
  await settled(n + 1);
  await p.page.keyboard.press("b");
  await p.page.keyboard.press("Control+z");
  await settled(n);
  // DemoBoardChannel takes one clear per socket every 5 s (and drops it
  // silently), so a clear that didn't take is tried again after that.
  for (let attempt = 1; ; attempt++) {
    const wait = (p.lastClear || 0) + 5500 - Date.now();
    if (wait > 0) await sleep(wait);
    await p.page.locator(`${shell} .toolbar button`, { hasText: /^clear$/ }).click();
    p.lastClear = Date.now();
    try {
      await p.page.waitForFunction((g) => window.__bench.counts()[g] === 0, group, { timeout: 4000 });
      break;
    } catch (e) {
      if (attempt >= 3) {
        const board = await p.page.evaluate(() => {
          const b = window.__scrawlyDemoBoard;
          return b && { canDraw: b.canDraw, token: !!b.usedToken, strokes: b.strokes.length };
        });
        throw new Error(`clear didn't take on ${group}: ${JSON.stringify(board)}`);
      }
    }
  }
  await settled(0);
}

if (want("leak_tools")) await phase("leak_tools", async () => {
  log("== leak check, every tool");
  for (const p of [drawer, viewer, visitor]) await setRate(p, 1);
  loadRoomCall(0);
  loadDemoCall(0);
  await join(drawer, roomUrl, "drawer", 0, drawerReady);
  await join(viewer, roomUrl, "viewer", 0, viewerReady);
  await join(visitor, BASE + "/", "demo", 0, demoReady);
  const rounds = async (k) => {
    for (let i = 0; i < k; i++) {
      await toolRound(drawer, "game-canvas-svg", "drawer", ".canvas-shell", true);
      await toolRound(visitor, "demo-board-svg", "demo", ".surface:has(#demo-board-svg)", false);
    }
    await settle(0, 0);
  };
  await rounds(1);
  const before = await snap();
  await rounds(TOOL_ROUNDS / 2);
  const half = await snap();
  await rounds(TOOL_ROUNDS / 2);
  const after = await snap();
  results.leak_tools = { rounds: TOOL_ROUNDS, before, half, after };
  growth(results.leak_tools, before, half, after);
});

await phase("teardown", async () => rpc(`BenchRpc.teardown(${JSON.stringify(setup.room_id)})`));
results.meta.duration_s = Math.round((Date.now() - t0) / 1000);
for (const b of browsers) await b.close();
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(results, null, 2) + "\n");
log(`wrote ${path.relative(ROOT, OUT)} (${results.meta.duration_s} s)`);
