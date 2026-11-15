// The experiment behind the rendering decision (notes/files/drawing-benchmarks.md):
// the demo board holding N strokes, one gesture traced (a) as the page is,
// and (b) after moving the committed strokes into a second svg stacked
// under the canvas with its own compositor layer (`will-change: transform`),
// so the stroke in progress no longer shares their layer. Prints the raster
// time per frame, the main-thread time per frame, and the raster a single
// commit causes. It changes the page only in its own browser.
//
//   N=500 node bench/own_layer.mjs
//
// Needs the bench release running (bench/prod_server.sh start) and nothing
// else using it: it reloads the demo board through `prod_server.sh rpc`.
// Environment as for drawing_client.mjs (PLAYWRIGHT, CHROME, BENCH_PORT).

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const pwPath = process.env.PLAYWRIGHT || "playwright";
const { chromium } = await import(pwPath.startsWith("/") ? pathToFileURL(pwPath).href : pwPath);
const N = Number(process.env.N || 500);
const BASE = `http://localhost:${process.env.BENCH_PORT || 4100}`;

execFileSync(path.join(HERE, "prod_server.sh"), [
  "rpc",
  `Code.compile_file(${JSON.stringify(path.join(HERE, "lib", "bench_rpc.exs"))}); ` +
    `BenchRpc.load_demo(${JSON.stringify(path.join(HERE, "fixtures"))}, ${N})`,
]);

const browser = await chromium.launch({
  executablePath: process.env.CHROME || undefined,
  headless: true,
  args: ["--disable-renderer-backgrounding", "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows"],
});
const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
await ctx.addInitScript({ content: fs.readFileSync(path.join(HERE, "lib", "page_probe.js"), "utf8") });
const page = await ctx.newPage();
const cdp = await ctx.newCDPSession(page);
await page.goto(BASE + "/");
await page.waitForFunction((n) => window.__bench.counts().demo === n, N, { timeout: 30000 });
await page.waitForTimeout(1500);
await page.evaluate(() => window.__bench.hideGlow());

const pts = [];
for (let k = 0; k <= 280; k++) {
  const t = k / 300;
  pts.push([
    Math.round(400 * (0.5 + 0.42 * Math.sin(4 * Math.PI * t)) * 10) / 10,
    Math.round(225 * (0.5 + 0.4 * Math.sin(6 * Math.PI * t + 0.5)) * 10) / 10,
  ]);
}

async function traced(fn) {
  await cdp.send("Tracing.start", { categories: "cc,viz", transferMode: "ReturnAsStream" });
  const result = await fn();
  const done = new Promise((r) => cdp.once("Tracing.tracingComplete", r));
  await cdp.send("Tracing.end");
  const { stream } = await done;
  let data = "";
  for (;;) {
    const chunk = await cdp.send("IO.read", { handle: stream });
    data += chunk.data;
    if (chunk.eof) break;
  }
  let raster = 0;
  for (const e of JSON.parse(data).traceEvents) if (e.ph === "X" && e.name === "RasterTask") raster += e.dur;
  return { ...result, raster_ms: raster / 1000 };
}

const gesture = () =>
  traced(() =>
    page.evaluate(async (pts) => {
      const B = window.__bench;
      B.startFrames();
      await new Promise((r) => requestAnimationFrame(r));
      await B.gesture("demo-board-svg", pts, 8);
      const f = B.stopFrames();
      return { frames: f.raf.length, work: f.work.reduce((a, b) => a + b, 0) / f.work.length };
    }, pts)
  );

// One short stroke added to the committed strokes: the raster it causes.
const commit = (target) =>
  traced(() =>
    page.evaluate(async (target) => {
      const g = document.querySelector(target);
      const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
      p.setAttribute("d", "M 100 100 Q 110 105 120 112 Q 130 116 140 118 L 140 118");
      p.setAttribute("stroke", "#000000");
      p.setAttribute("stroke-width", "4");
      p.setAttribute("fill", "none");
      g.appendChild(p);
      await window.__bench.afterPaint();
      await window.__bench.afterPaint();
      return {};
    }, target)
  );

const report = (label, g, c) =>
  console.log(
    label.padEnd(10),
    JSON.stringify({
      strokes: N,
      frames: g.frames,
      raster_ms_per_frame: +(g.raster_ms / g.frames).toFixed(2),
      main_thread_ms_per_frame: +g.work.toFixed(2),
      raster_ms_per_commit: +c.raster_ms.toFixed(1),
    })
  );

const a = await gesture();
await page.waitForTimeout(800);
const ca = await commit("#demo-board-strokes");
await page.waitForTimeout(800);
report("as is", a, ca);

await page.evaluate(() => {
  const svg = document.getElementById("demo-board-svg");
  const group = document.getElementById("demo-board-strokes");
  const under = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  under.setAttribute("viewBox", svg.getAttribute("viewBox"));
  under.setAttribute("preserveAspectRatio", svg.getAttribute("preserveAspectRatio"));
  under.setAttribute("style", "position:absolute; inset:0; width:100%; height:100%; will-change:transform; pointer-events:none;");
  const moved = document.createElementNS("http://www.w3.org/2000/svg", "g");
  moved.id = "bench-moved-strokes";
  while (group.firstChild) moved.appendChild(group.firstChild);
  under.appendChild(moved);
  svg.parentNode.insertBefore(under, svg);
  svg.style.position = "relative";
  svg.style.willChange = "transform";
});
await page.waitForTimeout(800);
const b = await gesture();
await page.waitForTimeout(800);
const cb = await commit("#bench-moved-strokes");
report("own layer", b, cb);
await browser.close();
