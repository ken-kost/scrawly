// A stand-in for the browser's Path2D and 2D context, for the paint model
// (paint_model.mjs) under node: a path is the polyline through its numbers
// (taps, "M x y L x y", and straight strokes are exact), stroked with the
// context's lineWidth and round caps; a fill is that polygon's inside.
// Records what each hit test set and asked.

export function polyline(d) {
  const nums = (String(d).match(/-?\d+(?:\.\d+)?/g) || []).map(Number);
  const pts = [];
  for (let i = 0; i + 1 < nums.length; i += 2) pts.push([nums[i], nums[i + 1]]);
  return pts;
}

function segmentDistance([x, y], [ax, ay], [bx, by]) {
  const dx = bx - ax;
  const dy = by - ay;
  const len = dx * dx + dy * dy;
  const t = len === 0 ? 0 : Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / len));
  return Math.hypot(x - (ax + t * dx), y - (ay + t * dy));
}

export class FakePath2D {
  constructor(d) {
    this.d = d;
    FakePath2D.made += 1;
  }
}
FakePath2D.made = 0;

export function fakeContext() {
  const ctx = {
    lineWidth: 1,
    lineCap: "butt",
    lineJoin: "miter",
    asked: [],
    isPointInStroke(shape, x, y) {
      ctx.asked.push({ kind: "stroke", d: shape.d, width: ctx.lineWidth, cap: ctx.lineCap, join: ctx.lineJoin });
      const pts = polyline(shape.d);
      for (let i = 0; i < pts.length; i++) {
        if (segmentDistance([x, y], pts[i], pts[i + 1] || pts[i]) <= ctx.lineWidth / 2) return true;
      }
      return false;
    },
    isPointInPath(shape, x, y) {
      ctx.asked.push({ kind: "fill", d: shape.d });
      const pts = polyline(shape.d);
      let inside = false;
      for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
        const [xi, yi] = pts[i];
        const [xj, yj] = pts[j];
        if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
      }
      return inside;
    },
  };
  return ctx;
}

// Path2D and the paint model's shared context (its window slot) for every
// module in this process.
export function installFakePaint() {
  globalThis.Path2D = FakePath2D;
  const ctx = fakeContext();
  globalThis.__scrawlyPaintContext = ctx;
  return ctx;
}
