// The fill tool's area (#43), worked out off the main thread: a module Web
// Worker, served as a static file (ScrawlyWeb.static_paths/0), so none of
// this is in a page bundle. fill_tool.mjs (the page side) starts it with
// `new Worker("/fill_worker.mjs?v=" + VERSION, {type: "module"})`.
//
// A fill is computed once, on the filling client, and sent as a closed
// shape: one more entry of the stroke list, `{path, color, fill: true}`,
// painted with fill-rule evenodd. Everyone renders that same shape, so no
// pixel ever travels and no other client floods anything. Here, for a
// click at (x, y) (viewBox units, the canvases are 800 x 450):
//
//   1. raster: the stroke list drawn into an OffscreenCanvas at SCALE (2)
//      pixels per unit, 1600 x 900, white, entries in list order (lines
//      stroked with round caps and joins, earlier fills filled), as the svg
//      shows them. Kept between fills: when the next list starts with the
//      entries already drawn, only the new ones are drawn on top.
//   2. floodFill: the 4-connected pixels whose colour is within TOLERANCE
//      (on each channel) of the colour under the click (`ref`, the paint
//      model's answer), so the area reaches into the anti-aliased edges of
//      the lines around it; the canvas's edge bounds it too.
//   3. dilate: grown by one pixel (half a unit) in every direction, so no
//      light seam shows between the fill and the lines around it.
//   4. traceOutlines: the area's outline and its holes as closed polygons
//      along pixel edges (every boundary edge exactly once, so the evenodd
//      rule paints exactly the area, however loops meet at a corner); holes
//      under MIN_HOLE_AREA (one square unit) are dropped (filled over),
//      every other hole is kept: a dot inside the area stays visible.
//   5. simplifyLoop (Douglas-Peucker): at EPSILONS[0] (0.35 units), doubled
//      until the path fits MAX_PATH_BYTES (StrokeRules.max_path_bytes/0),
//      up to 2.8 units; past that the area is "too detailed".
//   6. formatPath: "M x y L x y ... Z" sub-paths, one decimal at most (every
//      vertex is on the half-unit pixel grid), only the characters
//      StrokeRules lets a fill's path use.
//
// Everything but the worker glue at the bottom is pure and exported, for
// node --test (test/js/fill_worker.test.mjs). The glue runs only inside a
// worker (WorkerGlobalScope).
//
// Messages (fill_tool.mjs):
//   in:  {type: "prepare", canvas, strokes}   raster ahead (the fill tool
//                                              was chosen), no reply
//        {type: "fill", id, canvas, strokes, x, y, ref}
//   out: {type: "ready", version, raster}     once, at start (raster: false
//                                              when this browser's workers
//                                              have no OffscreenCanvas or
//                                              Path2D: every fill then
//                                              answers "unsupported")
//        {type: "fill", id, path, epsilon, ms} | {type: "fill", id, error,
//        ms}, error "nothing" | "too_detailed" | "unsupported" | "failed"
// `strokes` are plain entries {id, path, color, width, fill}, oldest first;
// `canvas` names the canvas ("game", "board"), whose raster is kept.
//
// Bump VERSION with any change here: it is in the worker's URL (so a
// browser never keeps an older copy) and fill_tool.mjs has the same
// number (a test keeps them equal).

export const VERSION = 1;

export const VIEW_WIDTH = 800;
export const VIEW_HEIGHT = 450;
export const SCALE = 2;
export const WIDTH = VIEW_WIDTH * SCALE;
export const HEIGHT = VIEW_HEIGHT * SCALE;
// Two colours within this of each other on every channel are one area:
// enough to take in the faint edge of a line, and less than the step
// between any two of DrawingToolbar's presets (light grey on white, the
// faintest outline, differs by 43), so every preset outline holds.
export const TOLERANCE = 32;
// How far from the clicked pixel (in pixels) the area's colour is looked
// for, when the click lands on an anti-aliased edge.
export const SEED_RADIUS = 2;
// In square units.
export const MIN_HOLE_AREA = 1;
// Douglas-Peucker tolerances tried in turn, in units.
export const EPSILONS = Object.freeze([0.35, 0.7, 1.4, 2.8]);
// StrokeRules.max_path_bytes/0.
export const MAX_PATH_BYTES = 8000;
export const CANVAS_COLOR = "#ffffff";

// ── Colours ──────────────────────────────────────────────────────────

const HEX = /^#[0-9a-fA-F]{6}$/;
// Byte 0 of a 32-bit word is its low byte (every browser's machine): RGBA
// pixels and 0/1 masks can be read four bytes at a time.
const LITTLE_ENDIAN = new Uint8Array(new Uint32Array([1]).buffer)[0] === 1;

// [r, g, b] of a "#rrggbb" colour, or null.
export function hexToRgb(hex) {
  if (typeof hex !== "string" || !HEX.test(hex)) return null;
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function near(px, i, r, g, b, tol) {
  const o = i << 2;
  return Math.abs(px[o] - r) <= tol && Math.abs(px[o + 1] - g) <= tol && Math.abs(px[o + 2] - b) <= tol;
}

// ── Flood fill ───────────────────────────────────────────────────────

// The pixel nearest to (sx, sy) within `radius` (rings outward) whose colour
// is within `tol` of `rgb`, as [x, y]; null when there is none. `px` is
// RGBA, `w` x `h`.
export function findSeed(px, w, h, sx, sy, rgb, tol, radius = SEED_RADIUS) {
  const x0 = Math.min(w - 1, Math.max(0, sx | 0));
  const y0 = Math.min(h - 1, Math.max(0, sy | 0));
  for (let d = 0; d <= radius; d++) {
    let best = null;
    let bestDist = Infinity;
    for (let y = y0 - d; y <= y0 + d; y++) {
      if (y < 0 || y >= h) continue;
      for (let x = x0 - d; x <= x0 + d; x++) {
        if (x < 0 || x >= w) continue;
        if (Math.max(Math.abs(x - x0), Math.abs(y - y0)) !== d) continue;
        if (!near(px, y * w + x, rgb[0], rgb[1], rgb[2], tol)) continue;
        const dist = (x - x0) * (x - x0) + (y - y0) * (y - y0);
        if (dist < bestDist) {
          bestDist = dist;
          best = [x, y];
        }
      }
    }
    if (best) return best;
  }
  return null;
}

// The 4-connected area around (sx, sy) of pixels within `tol` of `rgb` on
// every channel: {mask (Uint8Array, 1 = in), count, minX, minY, maxX, maxY}
// (the box inclusive), or null when (sx, sy) itself isn't such a pixel.
export function floodFill(px, w, h, sx, sy, rgb, tol) {
  if (!(sx >= 0 && sy >= 0 && sx < w && sy < h)) return null;
  const r = rgb[0];
  const g = rgb[1];
  const b = rgb[2];
  if (!near(px, sy * w + sx, r, g, b, tol)) return null;
  const mask = new Uint8Array(w * h);
  let stack = new Int32Array(4096);
  let top = 0;
  let count = 0;
  let minX = sx;
  let maxX = sx;
  let minY = sy;
  let maxY = sy;

  function push(x, y) {
    if (top + 2 > stack.length) {
      const bigger = new Int32Array(stack.length * 2);
      bigger.set(stack);
      stack = bigger;
    }
    stack[top++] = x;
    stack[top++] = y;
  }

  // One seed per run of fillable pixels of row `y` between lx and rx.
  function scan(lx, rx, y) {
    const row = y * w;
    let run = false;
    for (let x = lx; x <= rx; x++) {
      const i = row + x;
      if (mask[i] === 0 && near(px, i, r, g, b, tol)) {
        if (!run) {
          push(x, y);
          run = true;
        }
      } else {
        run = false;
      }
    }
  }

  push(sx, sy);
  while (top > 0) {
    const y = stack[--top];
    const x = stack[--top];
    const row = y * w;
    if (mask[row + x] !== 0) continue;
    let lx = x;
    while (lx > 0 && mask[row + lx - 1] === 0 && near(px, row + lx - 1, r, g, b, tol)) lx--;
    let rx = x;
    while (rx < w - 1 && mask[row + rx + 1] === 0 && near(px, row + rx + 1, r, g, b, tol)) rx++;
    mask.fill(1, row + lx, row + rx + 1);
    count += rx - lx + 1;
    if (lx < minX) minX = lx;
    if (rx > maxX) maxX = rx;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    if (y > 0) scan(lx, rx, y - 1);
    if (y < h - 1) scan(lx, rx, y + 1);
  }
  return { mask: mask, count: count, minX: minX, minY: minY, maxX: maxX, maxY: maxY };
}

// ── Growing ──────────────────────────────────────────────────────────

// `area` (floodFill's) grown by one pixel in all eight directions, clipped
// to the canvas: {mask, minX, minY, maxX, maxY}. (`bytes`: never four
// pixels at once, for the tests that compare both ways.)
export function dilate(area, w, h, bytes = false) {
  const src = area.mask;
  const x0 = Math.max(0, area.minX - 1);
  const x1 = Math.min(w - 1, area.maxX + 1);
  const y0 = Math.max(0, area.minY - 1);
  const y1 = Math.min(h - 1, area.maxY + 1);
  if (!bytes && wordsFit(w)) return dilateWords(src, w, h, area, x0, x1, y0, y1);
  // Rows first (only the area's rows hold pixels), then columns; the
  // canvas's first and last column and row apart, so the inner loops test
  // no bounds.
  const across = new Uint8Array(w * h);
  const xa = Math.max(x0, 1);
  const xb = Math.min(x1, w - 2);
  for (let y = area.minY; y <= area.maxY; y++) {
    const row = y * w;
    if (x0 === 0) across[row] = src[row] | src[row + 1];
    for (let i = row + xa, end = row + xb; i <= end; i++) across[i] = src[i - 1] | src[i] | src[i + 1];
    if (x1 === w - 1) across[row + w - 1] = src[row + w - 2] | src[row + w - 1];
  }
  const out = new Uint8Array(w * h);
  for (let y = y0; y <= y1; y++) {
    const row = y * w;
    const up = y > 0 ? -w : 0;
    const down = y < h - 1 ? w : 0;
    for (let i = row + x0, end = row + x1; i <= end; i++) out[i] = across[i + up] | across[i] | across[i + down];
  }
  return { mask: out, minX: x0, minY: y0, maxX: x1, maxY: y1 };
}

// Masks are bytes of 0 or 1. Where a row is a whole number of 32-bit words
// and the machine is little-endian (LITTLE_ENDIAN), four pixels go at once.

export function wordsFit(w) {
  return LITTLE_ENDIAN && w % 4 === 0;
}

// dilate's words: the same result. Within a word, pixel x+1 is the next
// byte: v << 8 brings each pixel's left neighbour, v >>> 8 its right one,
// and the words beside bring theirs across the word's edge. Words cover
// whole groups of four pixels around the box: pixels there beyond the box
// come out 0, as they should.
function dilateWords(src, w, h, area, x0, x1, y0, y1) {
  const W = w >> 2;
  const s32 = new Uint32Array(src.buffer, src.byteOffset, W * h);
  const across = new Uint8Array(w * h);
  const a32 = new Uint32Array(across.buffer);
  const k0 = x0 >> 2;
  const k1 = x1 >> 2;
  for (let y = area.minY; y <= area.maxY; y++) {
    const row = y * W;
    for (let k = k0; k <= k1; k++) {
      const i = row + k;
      const v = s32[i];
      const prev = k > 0 ? s32[i - 1] : 0;
      const next = k < W - 1 ? s32[i + 1] : 0;
      a32[i] = v | (v << 8) | (prev >>> 24) | (v >>> 8) | (next << 24);
    }
  }
  const out = new Uint8Array(w * h);
  const o32 = new Uint32Array(out.buffer);
  for (let y = y0; y <= y1; y++) {
    const row = y * W;
    const up = y > 0 ? -W : 0;
    const down = y < h - 1 ? W : 0;
    for (let k = k0; k <= k1; k++) {
      const i = row + k;
      o32[i] = a32[i + up] | a32[i] | a32[i + down];
    }
  }
  return { mask: out, minX: x0, minY: y0, maxX: x1, maxY: y1 };
}

// ── Outlines ─────────────────────────────────────────────────────────

// Directions along pixel edges (y down): +x, +y, -x, -y. Turning right is
// the next one, left the one before.
const DX = [1, 0, -1, 0];
const DY = [0, 1, 0, -1];

// The closed outlines of the pixels set in `area.mask` (within its box):
// an array of loops, each a flat array [x0, y0, x1, y1, ...] of pixel
// corners (integers), one per change of direction. The area is on the
// right of each loop's direction, so outer outlines run clockwise on the
// screen (positive loopArea) and holes counter-clockwise (negative).
//
// Every boundary edge is in exactly one loop. Where the area touches
// itself only at a corner (two pixels diagonal to each other, the two
// others not in it) the walk turns right, around the pixel it came along:
// the area counts as 4-connected, like the flood fill, so diagonal pixels
// are outlined apart. Either way the evenodd rule paints exactly the area.
export function traceOutlines(area, w, h, bytes = false) {
  const mask = area.mask;
  const bx = area.minX;
  const by = area.minY;
  const vw = area.maxX - bx + 2;
  const vh = area.maxY - by + 2;
  // Per vertex, the outgoing edges already walked (one bit per direction).
  const used = new Uint8Array(vw * vh);
  const loops = [];

  function isIn(x, y) {
    return x >= 0 && y >= 0 && x < w && y < h && mask[y * w + x] === 1;
  }

  // Whether the vertex (x, y) has an outgoing boundary edge `d`.
  function edge(x, y, d) {
    switch (d) {
      case 0:
        return isIn(x, y) && !isIn(x, y - 1);
      case 1:
        return isIn(x - 1, y) && !isIn(x, y);
      case 2:
        return isIn(x - 1, y - 1) && !isIn(x - 1, y);
      default:
        return isIn(x, y - 1) && !isIn(x - 1, y - 1);
    }
  }

  function vertex(x, y) {
    return (y - by) * vw + (x - bx);
  }

  function walk(sx, sy) {
    const pts = [sx, sy];
    let x = sx;
    let y = sy;
    let dir = 0;
    used[vertex(x, y)] |= 1;
    for (;;) {
      x += DX[dir];
      y += DY[dir];
      const v = vertex(x, y);
      let next = -1;
      const right = (dir + 1) & 3;
      const left = (dir + 3) & 3;
      if ((used[v] & (1 << right)) === 0 && edge(x, y, right)) next = right;
      else if ((used[v] & (1 << dir)) === 0 && edge(x, y, dir)) next = dir;
      else if ((used[v] & (1 << left)) === 0 && edge(x, y, left)) next = left;
      if (next < 0) break;
      if (next !== dir) pts.push(x, y);
      used[v] |= 1 << next;
      dir = next;
    }
    // Back at the start: it is a corner unless the walk arrived along the
    // start edge's own direction.
    if (dir === 0) pts.splice(0, 2);
    return pts;
  }

  function start(x, y) {
    if ((used[vertex(x, y)] & 1) !== 0) return;
    const loop = walk(x, y);
    if (loop.length >= 6) loops.push(loop);
  }

  // Every loop has an edge along a pixel's top (the topmost edges of an
  // outline, the bottom edges of a hole): start each walk at one, in
  // reading order. With words, four pixels are looked at at once (the
  // bytes are 0 or 1, so m & ~up keeps the pixels whose top is an edge).
  if (!bytes && wordsFit(w)) {
    const W = w >> 2;
    const m32 = new Uint32Array(mask.buffer, mask.byteOffset, W * h);
    const k0 = area.minX >> 2;
    const k1 = area.maxX >> 2;
    for (let y = area.minY; y <= area.maxY; y++) {
      const row = y * W;
      for (let k = k0; k <= k1; k++) {
        const m = m32[row + k];
        if (m === 0) continue;
        const tops = y > 0 ? m & ~m32[row + k - W] : m;
        if (tops === 0) continue;
        for (let j = 0; j < 4; j++) {
          if (((tops >>> (j << 3)) & 255) === 0) continue;
          const x = (k << 2) + j;
          if (x >= area.minX && x <= area.maxX) start(x, y);
        }
      }
    }
    return loops;
  }
  for (let y = area.minY; y <= area.maxY; y++) {
    const row = y * w;
    const up = y > 0 ? w : 0;
    for (let x = area.minX; x <= area.maxX; x++) {
      const i = row + x;
      if (mask[i] !== 1 || (up !== 0 && mask[i - up] === 1)) continue;
      start(x, y);
    }
  }
  return loops;
}

// The signed area of a loop (flat [x, y, ...]): positive for an outer
// outline, negative for a hole (traceOutlines' orientation).
export function loopArea(loop) {
  const n = loop.length;
  let sum = 0;
  for (let i = 0; i < n; i += 2) {
    const j = (i + 2) % n;
    sum += loop[i] * loop[j + 1] - loop[j] * loop[i + 1];
  }
  return sum / 2;
}

// The loops without the holes smaller than `minArea` (in the loops' units
// squared).
export function dropSmallHoles(loops, minArea) {
  return loops.filter((loop) => {
    const a = loopArea(loop);
    return a > 0 || -a >= minArea;
  });
}

// ── Simplifying ──────────────────────────────────────────────────────

// Squared distance from point p to segment ab.
function segmentDistance2(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const len = dx * dx + dy * dy;
  let t = len === 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / len;
  if (t < 0) t = 0;
  else if (t > 1) t = 1;
  const ex = px - (ax + t * dx);
  const ey = py - (ay + t * dy);
  return ex * ex + ey * ey;
}

// A closed loop (flat [x, y, ...]) simplified with Douglas-Peucker: every
// dropped vertex within `epsilon` of the kept outline. Anchored at its first
// vertex and the vertex farthest from it. Null when fewer than three
// vertices are left (nothing to paint).
export function simplifyLoop(loop, epsilon) {
  const n = loop.length / 2;
  if (n < 3) return null;
  let far = 0;
  let farDist = -1;
  for (let i = 1; i < n; i++) {
    const dx = loop[2 * i] - loop[0];
    const dy = loop[2 * i + 1] - loop[1];
    const d = dx * dx + dy * dy;
    if (d > farDist) {
      farDist = d;
      far = i;
    }
  }
  const keep = new Uint8Array(n);
  keep[0] = 1;
  keep[far] = 1;
  const eps2 = epsilon * epsilon;
  // Ranges [a, b] of vertex indices (b may be n: vertex 0 again).
  const stack = [0, far, far, n];
  while (stack.length > 0) {
    const b = stack.pop();
    const a = stack.pop();
    if (b - a < 2) continue;
    const ax = loop[2 * a];
    const ay = loop[2 * a + 1];
    const bi = b % n;
    const bx = loop[2 * bi];
    const by = loop[2 * bi + 1];
    let worst = -1;
    let worstDist = eps2;
    for (let i = a + 1; i < b; i++) {
      const d = segmentDistance2(loop[2 * i], loop[2 * i + 1], ax, ay, bx, by);
      if (d > worstDist) {
        worstDist = d;
        worst = i;
      }
    }
    if (worst >= 0) {
      keep[worst] = 1;
      stack.push(a, worst, worst, b);
    }
  }
  const out = [];
  for (let i = 0; i < n; i++) if (keep[i]) out.push(loop[2 * i], loop[2 * i + 1]);
  return out.length >= 6 ? out : null;
}

// ── The path ─────────────────────────────────────────────────────────

// A coordinate in pixels as units: at most one decimal (pixel corners are
// on the half-unit grid), no "-0".
function unit(v, scale) {
  const u = Math.round((v / scale) * 10) / 10;
  return u === 0 ? "0" : String(u);
}

// The loops (pixel corners) as one path in units: "M x y L x y ... Z" per
// loop, separated by spaces.
export function formatPath(loops, scale = SCALE) {
  const parts = [];
  for (let k = 0; k < loops.length; k++) {
    const loop = loops[k];
    let d = "M " + unit(loop[0], scale) + " " + unit(loop[1], scale);
    for (let i = 2; i < loop.length; i += 2) d += " L " + unit(loop[i], scale) + " " + unit(loop[i + 1], scale);
    parts.push(d + " Z");
  }
  return parts.join(" ");
}

// The loops simplified at each of `epsilons` (units) in turn until their
// path fits `maxBytes`: {path, epsilon}, {error: "nothing"} when the outer
// outline itself is too small to paint, or {error: "too_detailed"}.
export function fitPath(loops, opts = {}) {
  const scale = opts.scale || SCALE;
  const epsilons = opts.epsilons || EPSILONS;
  const maxBytes = opts.maxBytes || MAX_PATH_BYTES;
  for (let k = 0; k < epsilons.length; k++) {
    const kept = [];
    let outer = false;
    for (let i = 0; i < loops.length; i++) {
      const s = simplifyLoop(loops[i], epsilons[k] * scale);
      if (!s) continue;
      if (loopArea(loops[i]) > 0) outer = true;
      kept.push(s);
    }
    // Holes without the outline around them would paint as shapes.
    if (!outer) return { error: "nothing" };
    const path = formatPath(kept, scale);
    if (path.length <= maxBytes) return { path: path, epsilon: epsilons[k] };
  }
  return { error: "too_detailed" };
}

// The fill's path for a click at viewBox point (x, y) on `px` (RGBA, w x h
// at `scale` pixels per unit) over an area of colour `ref` ("#rrggbb"):
// {path, epsilon} or {error}. `opts`: tolerance, minHoleArea (square
// units), epsilons, maxBytes, scale.
export function areaPath(px, w, h, x, y, ref, opts = {}) {
  const scale = opts.scale || SCALE;
  const tol = opts.tolerance === undefined ? TOLERANCE : opts.tolerance;
  const minHole = opts.minHoleArea === undefined ? MIN_HOLE_AREA : opts.minHoleArea;
  if (!Number.isFinite(x) || !Number.isFinite(y)) return { error: "nothing" };
  const sx = Math.floor(x * scale);
  const sy = Math.floor(y * scale);
  const rgb = hexToRgb(ref) || pixelColor(px, w, h, sx, sy);
  const seed = findSeed(px, w, h, sx, sy, rgb, tol);
  if (!seed) return { error: "nothing" };
  const area = floodFill(px, w, h, seed[0], seed[1], rgb, tol);
  if (!area) return { error: "nothing" };
  const loops = dropSmallHoles(traceOutlines(dilate(area, w, h), w, h), minHole * scale * scale);
  return fitPath(loops, { scale: scale, epsilons: opts.epsilons, maxBytes: opts.maxBytes });
}

function pixelColor(px, w, h, x, y) {
  const o = ((Math.min(h - 1, Math.max(0, y)) * w + Math.min(w - 1, Math.max(0, x))) << 2) >>> 0;
  return [px[o], px[o + 1], px[o + 2]];
}

// ── Raster ───────────────────────────────────────────────────────────

// Whether two entries paint the same.
export function sameEntry(a, b) {
  return (
    a.id === b.id && a.path === b.path && a.color === b.color && a.width === b.width && (a.fill === true) === (b.fill === true)
  );
}

// How many entries `drawn` (already on the canvas) and `list` share from
// the start.
export function sharedPrefix(drawn, list) {
  const n = Math.min(drawn.length, list.length);
  let i = 0;
  while (i < n && sameEntry(drawn[i], list[i])) i++;
  return i;
}

// One entry onto `ctx` (its transform at SCALE): a line stroked with round
// caps and joins at its width, a fill filled evenodd.
export function drawEntry(ctx, entry, shape) {
  if (entry.fill === true) {
    ctx.fillStyle = entry.color;
    ctx.fill(shape, "evenodd");
  } else {
    ctx.strokeStyle = entry.color;
    ctx.lineWidth = entry.width;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.stroke(shape);
  }
}

// The stroke lists' pixels, one canvas at a time (`makeCanvas()` -> an
// OffscreenCanvas of WIDTH x HEIGHT, `makeShape(path)` -> a Path2D).
// pixels(name, list) draws only what `list` adds to what is drawn when it
// starts with that (same canvas name), else everything again; returns the
// RGBA pixels (read again only when something was drawn).
export function createRaster(makeCanvas, makeShape) {
  let ctx = null;
  let name = null;
  let drawn = [];
  let image = null;
  const shapes = new Map();

  function shapeOf(entry) {
    const held = shapes.get(entry.id);
    if (held && held.path === entry.path) return held.shape;
    const shape = makeShape(entry.path);
    if (entry.id !== undefined && entry.id !== null) shapes.set(entry.id, { path: entry.path, shape: shape });
    return shape;
  }

  function reset() {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = CANVAS_COLOR;
    ctx.fillRect(0, 0, WIDTH, HEIGHT);
    ctx.setTransform(SCALE, 0, 0, SCALE, 0, 0);
    drawn = [];
    image = null;
  }

  return {
    pixels(canvasName, list) {
      if (!ctx) ctx = makeCanvas().getContext("2d", { willReadFrequently: true });
      const entries = Array.isArray(list) ? list.filter((e) => e && typeof e.path === "string" && e.path !== "") : [];
      let from = canvasName === name ? sharedPrefix(drawn, entries) : 0;
      if (from < drawn.length || canvasName !== name) {
        name = canvasName;
        reset();
        from = 0;
      }
      for (let i = from; i < entries.length; i++) drawEntry(ctx, entries[i], shapeOf(entries[i]));
      if (image === null || from < entries.length) image = ctx.getImageData(0, 0, WIDTH, HEIGHT).data;
      drawn = entries;
      // Shapes of entries no longer listed go.
      if (shapes.size > entries.length) {
        const ids = new Set(entries.map((e) => e.id));
        for (const id of shapes.keys()) if (!ids.has(id)) shapes.delete(id);
      }
      return image;
    },
    drawnCount: () => drawn.length,
  };
}

// ── Worker glue ──────────────────────────────────────────────────────

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

// Whether this worker has worked out an area yet.
let warmed = false;

// Handles one message with `raster` (createRaster's, null when this
// worker can't draw) and returns the reply, or null for none. The first
// "prepare" also works out one area nobody asked for (the canvas's corner),
// so the engine has compiled the hot loops before the first click: a cold
// first fill takes about half again as long.
export function handleMessage(raster, msg) {
  if (!msg || typeof msg !== "object") return null;
  if (msg.type === "prepare") {
    if (!raster) return null;
    const px = raster.pixels(msg.canvas, msg.strokes);
    if (!warmed) {
      warmed = true;
      areaPath(px, WIDTH, HEIGHT, 0, 0, null);
    }
    return null;
  }
  if (msg.type !== "fill") return null;
  if (!raster) return { type: "fill", id: msg.id, error: "unsupported" };
  const t0 = now();
  try {
    const px = raster.pixels(msg.canvas, msg.strokes);
    const t1 = now();
    const result = areaPath(px, WIDTH, HEIGHT, msg.x, msg.y, msg.ref);
    warmed = true;
    const t2 = now();
    return { type: "fill", id: msg.id, ...result, ms: { raster: t1 - t0, area: t2 - t1 } };
  } catch (e) {
    return { type: "fill", id: msg.id, error: "failed", message: String((e && e.message) || e) };
  }
}

if (typeof WorkerGlobalScope !== "undefined" && typeof self !== "undefined" && self instanceof WorkerGlobalScope) {
  const capable = typeof OffscreenCanvas === "function" && typeof Path2D === "function";
  const raster = capable
    ? createRaster(
        () => new OffscreenCanvas(WIDTH, HEIGHT),
        (d) => new Path2D(d),
      )
    : null;
  self.onmessage = (e) => {
    const reply = handleMessage(raster, e.data);
    if (reply) self.postMessage(reply);
  };
  self.postMessage({ type: "ready", version: VERSION, raster: capable });
}
