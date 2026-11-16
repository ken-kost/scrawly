// The paint model: what a canvas shows at a point, worked out from its
// stroke list alone, never from pixels. Both canvases are SVG, and how they
// render may change (notes/files/drawing-benchmarks.md, "Rendering
// decision"); the stroke list is what they show either way. The colour
// picker (eyedropper.mjs) asks it; the fill tool (#43) reuses its parts.
//
// A stroke list is an array of entries {id, path, color, width}, oldest
// first: the drawer's history (drawing_manager.mjs) or the board's store,
// confirmed then pending (demo_board.mjs). The newest entry is painted on
// top, so the walk goes newest to oldest:
//
//   topIndexAt(strokes, x, y, hits) -> the index of the newest entry that
//                                      paints (x, y), or -1
//   colorAt(strokes, x, y, hits)    -> that entry's exact colour, or
//                                      CANVAS_COLOR (white, the canvas)
//
// `hits(entry, x, y)` is the hit test, injected: node --test runs the walk
// with a plain function (node has no Path2D). In the browser it is
// createCanvasHitTest(context, cache): the entry's Path2D, stroked with
// its width and round caps and joins (strokeGeometry, as the svg paths are
// drawn), tested with isPointInStroke on a 2D context of its own; a filled
// shape (isFill, for #43) with isPointInPath. Coordinates are viewBox
// units (both canvases are 800 x 450); the caller maps the pointer through
// the svg's screen CTM, as the stroke engine does. A point on a stroke's
// anti-aliased edge is in or out of the stroke's outline: the answer is
// always one stroke's colour or the canvas, never a blend.
//
// Per stroke id the model keeps a record (createShapeCache): the box
// around its path's coordinates (pathBounds), made on its first test, and
// its Path2D, made only when a test gets past the box (a point near the
// stroke): most strokes of a canvas never need one. A record is made again
// when its id comes back with another path. Nothing is made while drawing:
// adding a stroke costs nothing, the first pick pays. The canvas owner keeps
// the records in step with its list: forget(id) when one stroke leaves it
// (undo, rollback, trim), retain(strokes) when the list is replaced (a room
// rebase or resync, a snapshot), clear() when it empties (clear, a new
// turn, a new page). While the model holds records it checks every
// WATCH_MS that its canvas is still in the document, and drops them all
// once it isn't (the page was left).
//
//   paintModel(name, opts) -> the model of canvas `name` ("game", "board"):
//                             {colorAt, strokeAt, shape, has, forget,
//                             retain, clear, size, shapes, watching}
//
// For #43 (fill): draw the same list into an offscreen canvas with
// model.shape(entry) and strokeGeometry(ctx, entry.width), and give a fill
// entry `fill: true` (or change isFill): topIndexAt/colorAt then test its
// inside, in list order with the strokes.
//
// Hologram 0.12 copies this module into every page bundle that can reach
// the importing page: the models (by canvas name) and the hit-test context
// live in window slots shared by every copy. Everything but those slots and
// the default context is pure (test/js/paint_model.test.mjs).

// The canvas: white in both themes (`--canvas` in app.css), as the eraser.
export const CANVAS_COLOR = "#ffffff";
// How often a model holding shapes checks that its canvas is still shown.
export const WATCH_MS = 3000;

const MODELS_SLOT = "__scrawlyPaintModels";
const CONTEXT_SLOT = "__scrawlyPaintContext";

// ── The walk (pure) ──────────────────────────────────────────────────

// Index of the newest entry of `strokes` that paints (x, y), or -1.
export function topIndexAt(strokes, x, y, hits) {
  if (!Array.isArray(strokes) || !Number.isFinite(x) || !Number.isFinite(y)) return -1;
  for (let i = strokes.length - 1; i >= 0; i--) {
    const entry = strokes[i];
    if (entry && typeof entry.path === "string" && entry.path !== "" && hits(entry, x, y)) return i;
  }
  return -1;
}

// The colour the canvas shows at (x, y): the newest painting entry's, as it
// is stored, or CANVAS_COLOR.
export function colorAt(strokes, x, y, hits) {
  const i = topIndexAt(strokes, x, y, hits);
  return i < 0 ? CANVAS_COLOR : strokes[i].color;
}

// Whether an entry is a filled shape (#43) rather than a stroke.
export function isFill(entry) {
  return entry.fill === true;
}

// ── Shapes ───────────────────────────────────────────────────────────

// The box around every coordinate of an absolute path ("M L Q C Z", as the
// stroke engine writes them; a curve stays inside its control points), as
// {minX, minY, maxX, maxY}; null when that can't be read off the numbers
// (relative commands, an odd count, no number at all), and the entry is
// then always tested. Hand-rolled: ~1.5 ms for the 620 KB of a 500-stroke
// canvas, where splitting and parseFloat take three times that.
export function pathBounds(d) {
  if (typeof d !== "string") return null;
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  let y = false;
  const n = d.length;
  let i = 0;
  while (i < n) {
    let c = d.charCodeAt(i);
    if ((c >= 48 && c <= 57) || c === 45 || c === 46) {
      const start = i;
      const neg = c === 45;
      if (neg) i++;
      let v = 0;
      let digits = 0;
      while (i < n && (c = d.charCodeAt(i)) >= 48 && c <= 57) {
        v = v * 10 + (c - 48);
        digits++;
        i++;
      }
      if (i < n && c === 46) {
        let scale = 0.1;
        i++;
        while (i < n && (c = d.charCodeAt(i)) >= 48 && c <= 57) {
          v += (c - 48) * scale;
          scale /= 10;
          digits++;
          i++;
        }
      }
      if (digits === 0) return null;
      if (i < n && (c === 101 || c === 69)) {
        i++;
        c = d.charCodeAt(i);
        if (c === 45 || c === 43) i++;
        while (i < n && (c = d.charCodeAt(i)) >= 48 && c <= 57) i++;
        v = Math.abs(Number(d.slice(start, i)));
        if (!Number.isFinite(v)) return null;
      }
      if (neg) v = -v;
      if (y) {
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      } else {
        if (v < minX) minX = v;
        if (v > maxX) maxX = v;
      }
      y = !y;
    } else if (c >= 97 && c <= 122) {
      return null;
    } else {
      i++;
    }
  }
  return !y && minX <= maxX ? { minX: minX, minY: minY, maxX: maxX, maxY: maxY } : null;
}

// Whether (x, y) is within `margin` of `box`. The margin also takes in the
// decimals the hand-rolled parse may have rounded.
export function nearBounds(box, x, y, margin) {
  const m = margin + 0.5;
  return x >= box.minX - m && x <= box.maxX + m && y >= box.minY - m && y <= box.maxY + m;
}

// One record per stroke id, {path, box, shape}: the box (pathBounds) made
// on first use, the shape (`makeShape(entry)`, a Path2D) only when a test
// gets past the box. Made again when an entry comes with another path than
// the record's.
export function createShapeCache(makeShape) {
  const records = new Map();

  function record(entry) {
    if (entry.id === undefined || entry.id === null) {
      return { path: entry.path, box: pathBounds(entry.path), shape: null };
    }
    const held = records.get(entry.id);
    if (held && held.path === entry.path) {
      // Equal text in another string (a server's echo): keep the entry's,
      // so the next comparison is by reference.
      held.path = entry.path;
      return held;
    }
    const made = { path: entry.path, box: pathBounds(entry.path), shape: null };
    records.set(entry.id, made);
    return made;
  }

  return {
    bounds: (entry) => record(entry).box,
    shape(entry) {
      const r = record(entry);
      if (r.shape === null) r.shape = makeShape(entry);
      return r.shape;
    },
    has: (id) => records.has(id),
    forget: (id) => records.delete(id),
    // Drops every record whose id is not in `strokes`.
    retain(strokes) {
      if (records.size === 0) return;
      const list = Array.isArray(strokes) ? strokes : [];
      const keep = new Set();
      for (let i = 0; i < list.length; i++) if (list[i]) keep.add(list[i].id);
      for (const id of records.keys()) if (!keep.has(id)) records.delete(id);
    },
    clear: () => records.clear(),
    size: () => records.size,
    // How many records hold a made shape.
    shapes() {
      let k = 0;
      for (const r of records.values()) if (r.shape !== null) k++;
      return k;
    },
  };
}

// The svg paths' stroke geometry (round caps and joins, DrawingCanvas and
// the JS-built paths) on a 2D context, at `width` viewBox units.
export function strokeGeometry(ctx, width) {
  ctx.lineWidth = width;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
}

// The browser's hit test: `ctx` a 2D context with the identity transform
// (its units are viewBox units), `cache` a createShapeCache. A point off an
// entry's box (grown by half the width) is a miss without a Path2D.
export function createCanvasHitTest(ctx, cache) {
  return function (entry, x, y) {
    const fill = isFill(entry);
    const box = cache.bounds(entry);
    if (box && !nearBounds(box, x, y, fill ? 0 : entry.width / 2)) return false;
    const shape = cache.shape(entry);
    if (fill) return ctx.isPointInPath(shape, x, y);
    strokeGeometry(ctx, entry.width);
    return ctx.isPointInStroke(shape, x, y);
  };
}

// The context every model tests on (one per tab). No pixels are ever drawn
// on it, so 1 x 1 is enough: the hit tests use the paths' geometry only.
export function paintContext() {
  if (!window[CONTEXT_SLOT]) {
    const canvas =
      typeof OffscreenCanvas === "function" ? new OffscreenCanvas(1, 1) : document.createElement("canvas");
    window[CONTEXT_SLOT] = canvas.getContext("2d");
  }
  return window[CONTEXT_SLOT];
}

const CLOCK = {
  every: (fn, ms) => setInterval(fn, ms),
  stop: (id) => clearInterval(id),
};

// ── A canvas's model ─────────────────────────────────────────────────

// opts (all optional):
//   present()            whether the canvas is still in the document; while
//                        the model holds shapes it is asked every WATCH_MS,
//                        and the shapes go once it says false
//   hitTest(entry, x, y) instead of the canvas hit test (tests)
//   context()            the 2D context to test on (paintContext)
//   makeShape(entry)     the entry's shape (a Path2D of its path)
//   clock                {every(fn, ms), stop(id)}
export function createPaintModel(opts = {}) {
  const cache = createShapeCache(opts.makeShape || ((entry) => new Path2D(entry.path)));
  const present = typeof opts.present === "function" ? opts.present : null;
  const clock = opts.clock || CLOCK;
  let hits = typeof opts.hitTest === "function" ? opts.hitTest : null;
  let watch = null;

  function hitTest() {
    if (!hits) hits = createCanvasHitTest((opts.context || paintContext)(), cache);
    return hits;
  }

  function stopWatch() {
    if (watch === null) return;
    clock.stop(watch);
    watch = null;
  }

  // Only while there are shapes to drop.
  function settle() {
    if (cache.size() === 0) stopWatch();
    else if (watch === null && present) {
      watch = clock.every(function () {
        if (!present()) clear();
      }, WATCH_MS);
    }
  }

  function clear() {
    cache.clear();
    stopWatch();
  }

  function strokeAt(strokes, x, y) {
    const i = topIndexAt(strokes, x, y, hitTest());
    settle();
    return i < 0 ? null : strokes[i];
  }

  return {
    // The colour shown at (x, y) (viewBox units) on a canvas showing
    // `strokes`.
    colorAt(strokes, x, y) {
      const entry = strokeAt(strokes, x, y);
      return entry ? entry.color : CANVAS_COLOR;
    },
    // The entry painted on top at (x, y), or null.
    strokeAt: strokeAt,
    // The entry's cached shape (made now if needed).
    shape(entry) {
      const s = cache.shape(entry);
      settle();
      return s;
    },
    has: (id) => cache.has(id),
    forget(id) {
      cache.forget(id);
      settle();
    },
    retain(strokes) {
      cache.retain(strokes);
      settle();
    },
    clear: clear,
    // Records held, and how many of them have made their Path2D.
    size: () => cache.size(),
    shapes: () => cache.shapes(),
    watching: () => watch !== null,
  };
}

// The model of canvas `name`, made with `opts` the first time it is asked
// for (by whichever bundle's copy of this module asks first).
export function paintModel(name, opts) {
  if (!window[MODELS_SLOT]) window[MODELS_SLOT] = new Map();
  const models = window[MODELS_SLOT];
  let model = models.get(name);
  if (!model) {
    model = createPaintModel(opts);
    models.set(name, model);
  }
  return model;
}
