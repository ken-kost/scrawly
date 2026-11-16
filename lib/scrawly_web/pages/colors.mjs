// Colour math for the drawing toolbar's colour picker (color_picker.mjs),
// all pure (test/js/colors.test.mjs):
//
// * hex parsing: what the hex field accepts;
// * HSV <-> #rrggbb, the wheel's model: hue and saturation on the wheel,
//   brightness (`v`) on the slider beside it;
// * the wheel's geometry: a point on it <-> hue and saturation;
// * the saved colours ("my colours"): the list's rules, and reading it back
//   from localStorage, where anything may have been left.
//
// A colour is always "#rrggbb", lowercase, the form strokes carry
// (Scrawly.Games.StrokeRules.valid_color?/1 accepts either case).
// h is in degrees [0, 360), s and v in [0, 1]; channels are 0..255.

// localStorage: one key, a JSON array of "#rrggbb", newest first.
export const SAVED_KEY = "scrawly:saved-colors";
export const MAX_SAVED = 12;

const HEX = /^#?([0-9a-fA-F]{6})$/;
const SAVED_HEX = /^#[0-9a-fA-F]{6}$/;

// "#rrggbb" from "#rrggbb" or "rrggbb", in either case; null for anything
// else (no shorthand, no names, no spaces: the caller trims a typed value).
export function parseHex(text) {
  const m = typeof text === "string" ? HEX.exec(text) : null;
  return m ? "#" + m[1].toLowerCase() : null;
}

// {r, g, b} of a "#rrggbb" (either case, with or without "#"), or null.
export function hexToRgb(text) {
  const hex = parseHex(text);
  if (!hex) return null;
  const n = parseInt(hex.slice(1), 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

function channel(x) {
  const c = Math.round(Math.min(255, Math.max(0, Number(x) || 0)));
  return (c < 16 ? "0" : "") + c.toString(16);
}

// "#rrggbb" of {r, g, b} (rounded, clamped to 0..255).
export function rgbToHex(rgb) {
  return "#" + channel(rgb.r) + channel(rgb.g) + channel(rgb.b);
}

function unit(x) {
  const n = Number(x);
  return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0;
}

function hue(h) {
  const n = Number(h);
  if (!Number.isFinite(n)) return 0;
  // + 0: no -0 (atan2 gives it on the axis).
  return n >= 0 && n < 360 ? n + 0 : ((n % 360) + 360) % 360;
}

// {r, g, b} (0..255, unrounded) of an HSV colour.
export function hsvToRgb(hsv) {
  const h = hue(hsv.h) / 60;
  const s = unit(hsv.s);
  const v = unit(hsv.v) * 255;
  const i = Math.floor(h) % 6;
  const f = h - Math.floor(h);
  const p = v * (1 - s);
  const q = v * (1 - s * f);
  const t = v * (1 - s * (1 - f));
  switch (i) {
    case 0:
      return { r: v, g: t, b: p };
    case 1:
      return { r: q, g: v, b: p };
    case 2:
      return { r: p, g: v, b: t };
    case 3:
      return { r: p, g: q, b: v };
    case 4:
      return { r: t, g: p, b: v };
    default:
      return { r: v, g: p, b: q };
  }
}

// {h, s, v} of {r, g, b}. A grey has no hue (h 0) and black no saturation
// (s 0); hsvFromHex keeps the wheel's own there.
export function rgbToHsv(rgb) {
  const r = rgb.r / 255;
  const g = rgb.g / 255;
  const b = rgb.b / 255;
  const max = Math.max(r, g, b);
  const d = max - Math.min(r, g, b);
  let h = 0;
  if (d > 0) {
    if (max === r) h = 60 * (((g - b) / d) % 6);
    else if (max === g) h = 60 * ((b - r) / d + 2);
    else h = 60 * ((r - g) / d + 4);
  }
  return { h: hue(h), s: max === 0 ? 0 : d / max, v: max };
}

export function hsvToHex(hsv) {
  return rgbToHex(hsvToRgb(hsv));
}

// The HSV the wheel shows for `hex`, or null for a non-colour. Where `hex`
// says nothing about a component (the hue of a grey, the hue and saturation
// of black), the wheel's previous `prev` one stays: picking black and
// brightening it again brings back the colour it was.
export function hsvFromHex(hex, prev) {
  const rgb = hexToRgb(hex);
  if (!rgb) return null;
  const hsv = rgbToHsv(rgb);
  const p = prev || { h: 0, s: 0, v: 1 };
  if (hsv.v === 0) return { h: hue(p.h), s: unit(p.s), v: 0 };
  if (hsv.s === 0) return { h: hue(p.h), s: 0, v: hsv.v };
  // Keep the wheel's own HSV when it is already this colour (it is finer
  // than the 8-bit channels).
  if (prev && hsvToHex(prev) === parseHex(hex)) return { h: hue(p.h), s: unit(p.s), v: unit(p.v) };
  return hsv;
}

// The wheel: hue is the angle (0 = red, at the right, counter-clockwise, as
// on paper), saturation the distance from the centre over the radius. (x, y)
// is relative to the centre, in screen orientation (y down). Points beyond
// the rim pick the rim.
export function wheelHsv(x, y, radius) {
  const d = Math.hypot(x, y);
  const h = d === 0 ? 0 : (Math.atan2(-y, x) * 180) / Math.PI;
  return { h: hue(h), s: radius > 0 ? Math.min(1, d / radius) : 0 };
}

// The point (relative to the centre, y down) where the wheel shows hue `h`
// at saturation `s`.
export function wheelPoint(h, s, radius) {
  const a = (hue(h) * Math.PI) / 180;
  const d = unit(s) * radius;
  return { x: d * Math.cos(a), y: -d * Math.sin(a) };
}

function sameColor(a, b) {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

// `color` (as parseHex reads it) at the front of `list`, once (case doesn't
// matter), at most MAX_SAVED kept: saving a 13th drops the oldest, saving
// one already there moves it to the front. A non-colour leaves the list as
// it is.
export function addSavedColor(list, color) {
  const hex = parseHex(color);
  const rest = Array.isArray(list) ? list : [];
  if (!hex) return rest.slice(0, MAX_SAVED);
  return [hex, ...rest.filter((c) => !sameColor(c, hex))].slice(0, MAX_SAVED);
}

// `list` without `color` (in any case).
export function removeSavedColor(list, color) {
  return (Array.isArray(list) ? list : []).filter((c) => !sameColor(c, color));
}

// The saved colours from what localStorage holds under SAVED_KEY: nothing
// (null), junk, a non-array, or an array with anything in it. Only
// "#rrggbb" entries count (lowercased, first occurrence kept), at most
// MAX_SAVED; anything else means none.
export function savedColorsFrom(raw) {
  let value;
  try {
    value = typeof raw === "string" ? JSON.parse(raw) : null;
  } catch (_e) {
    return [];
  }
  if (!Array.isArray(value)) return [];
  const out = [];
  for (const c of value) {
    if (typeof c !== "string" || !SAVED_HEX.test(c)) continue;
    const hex = c.toLowerCase();
    if (!out.includes(hex)) out.push(hex);
    if (out.length === MAX_SAVED) break;
  }
  return out;
}
