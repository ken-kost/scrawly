// A minimal DOM / window for driving drawing_manager.mjs and stroke_engine.mjs
// under node (test/js/drawing_manager.test.mjs): only what those modules
// touch. Each test file runs in its own node process.

export class FakeEl {
  constructor(tag, id) {
    this.tagName = tag;
    this.attrs = {};
    this.children = [];
    this.parentNode = null;
    if (id) this.attrs.id = id;
  }
  get id() { return this.attrs.id; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  appendChild(c) {
    if (c.isFragment) {
      for (const x of c.children.slice()) this.appendChild(x);
      c.children = [];
      return c;
    }
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this;
    this.children.push(c);
    return c;
  }
  insertBefore(c, ref) {
    if (!ref) return this.appendChild(c);
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this;
    this.children.splice(this.children.indexOf(ref), 0, c);
    return c;
  }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.children;
    return s[s.indexOf(this) + 1] || null;
  }
  removeChild(c) {
    const i = this.children.indexOf(c);
    if (i >= 0) this.children.splice(i, 1);
    c.parentNode = null;
    return c;
  }
  replaceChildren(frag) {
    for (const c of this.children) c.parentNode = null;
    this.children = [];
    if (frag) this.appendChild(frag);
  }
  get lastElementChild() { return this.children[this.children.length - 1] || null; }
  get previousElementSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.children;
    const i = s.indexOf(this);
    return i > 0 ? s[i - 1] : null;
  }
  get isConnected() {
    let n = this;
    while (n.parentNode) n = n.parentNode;
    return n === globalThis.__fakeRoot;
  }
  querySelector(sel) {
    return find(this, sel.replace(/^#/, ""));
  }
  // Only the stroke engines' and the ring's "svg[id]"; nothing here matches
  // the colour panel's selectors (color_picker.mjs).
  closest(sel) {
    if (sel !== "svg[id]") return null;
    let n = this;
    while (n) {
      if (n.tagName === "svg" && n.attrs.id) return n;
      n = n.parentNode;
    }
    return null;
  }
}

function find(node, id) {
  for (const c of node.children) {
    if (c.attrs.id === id) return c;
    const r = find(c, id);
    if (r) return r;
  }
  return null;
}

export function installFakeDom() {
  const listeners = {};
  const root = new FakeEl("html");
  globalThis.__fakeRoot = root;
  globalThis.window = globalThis;
  globalThis.addEventListener = (t, f) => { (listeners[t] ||= new Set()).add(f); };
  globalThis.removeEventListener = (t, f) => { listeners[t] && listeners[t].delete(f); };
  globalThis.__fire = (t, e) => { for (const f of [...(listeners[t] || [])]) f(e); };
  globalThis.requestAnimationFrame = () => 1;
  globalThis.cancelAnimationFrame = () => {};
  globalThis.document = {
    getElementById: (id) => find(root, id),
    createElementNS: (_ns, tag) => new FakeEl(tag),
    createDocumentFragment() {
      const f = new FakeEl("#frag");
      f.isFragment = true;
      return f;
    },
  };
  const dispatched = [];
  globalThis.Hologram = {
    dispatchAction: (name, target, params) => dispatched.push({ name, target, params }),
  };
  return { root, dispatched };
}

// GamePage's markup: the marker (with the instance's mount id) and the svg,
// with the drawer's group for a drawer. Replaces whatever was rendered.
export function renderGamePage(root, { mount = 1, drawer = true } = {}) {
  root.children = [];
  const marker = new FakeEl("span", "game-page-marker");
  marker.setAttribute("data-mount", mount);
  const svg = new FakeEl("svg", "game-canvas-svg");
  svg.getScreenCTM = () => ({ inverse: () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }) });
  svg.setPointerCapture = () => {};
  svg.hasPointerCapture = () => false;
  svg.releasePointerCapture = () => {};
  svg.appendChild(new FakeEl("g", "game-canvas-strokes"));
  const drawerG = new FakeEl("g", "game-canvas-drawer");
  if (drawer) {
    drawerG.appendChild(new FakeEl("g", "game-canvas-drawer-strokes"));
    drawerG.appendChild(new FakeEl("path", "drawing-path"));
  }
  svg.appendChild(drawerG);
  svg.appendChild(new FakeEl("g", "game-canvas-overlay"));
  root.appendChild(marker);
  root.appendChild(svg);
  return svg;
}

// Another page (Home, a header link): no game page in the document.
export function renderOtherPage(root) {
  root.children = [new FakeEl("div", "home")];
  root.children[0].parentNode = root;
}

// One pointer press + release on the svg (a tap), through the engine's router.
// `press` overrides the pointerdown's fields (e.g. {button: 2}, {ctrlKey: true}).
export function tap(svg, x = 10, y = 10, pointerId = 1, press = {}) {
  const target = svg.children[0];
  globalThis.__fire("pointerdown", {
    target, pointerId, isPrimary: true, pointerType: "mouse", button: 0,
    clientX: x, clientY: y, preventDefault() {}, ...press,
  });
  globalThis.__fire("pointerup", { pointerId });
}

// The ids of the strokes drawn in the drawer's group.
export function drawnIds() {
  const group = document.getElementById("game-canvas-drawer-strokes");
  return group ? group.children.map((c) => c.getAttribute("data-stroke-id")) : [];
}

export function overlayIds() {
  const group = document.getElementById("game-canvas-overlay");
  return group ? group.children.map((c) => c.getAttribute("data-remote-in-progress")) : [];
}
