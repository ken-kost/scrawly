// priv/static/chat_scroll.js: keeps a chat list's newest line in view. On a
// phone the game chat lists the newest line first (`flex-direction:
// column-reverse`, scroll offsets from 0 at the bottom to negative at the
// top), so "newest" is the top there and the bottom everywhere else.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const source = readFileSync(
  fileURLToPath(new URL("../../priv/static/chat_scroll.js", import.meta.url)),
  "utf8",
);

// A scrollable list: the browser clamps scrollTop to its range, which is
// [0, max] normally and [-max, 0] in a column-reverse flex box.
class FakeList {
  constructor(id, { reversed = false, scrollHeight = 500, clientHeight = 200 } = {}) {
    this.id = id;
    this.reversed = reversed;
    this.scrollHeight = scrollHeight;
    this.clientHeight = clientHeight;
    this._top = 0;
  }
  get max() { return Math.max(0, this.scrollHeight - this.clientHeight); }
  get scrollTop() { return this._top; }
  set scrollTop(v) {
    this._top = this.reversed ? Math.min(0, Math.max(-this.max, v)) : Math.max(0, Math.min(this.max, v));
  }
}

let elements;
let mutationObservers;
let resizeObservers;
let frames;
let body;

// Runs the script in a fresh window, as a page load does.
function load({ resizeObserver = true } = {}) {
  mutationObservers = [];
  resizeObservers = [];
  frames = [];

  class MutationObserver {
    constructor(cb) { this.cb = cb; this.target = null; this.connected = true; mutationObservers.push(this); }
    observe(target) { this.target = target; }
    disconnect() { this.connected = false; }
  }

  class ResizeObserver {
    constructor(cb) { this.cb = cb; this.target = null; this.connected = true; resizeObservers.push(this); }
    observe(target) { this.target = target; }
    disconnect() { this.connected = false; }
  }

  body = {};
  const window = {
    MutationObserver,
    requestAnimationFrame: (fn) => frames.push(fn),
    getComputedStyle: (el) => ({ flexDirection: el.reversed ? "column-reverse" : "column" }),
    document: {
      readyState: "complete",
      body,
      getElementById: (id) => elements[id] || null,
    },
  };
  if (resizeObserver) window.ResizeObserver = ResizeObserver;
  window.window = window;

  vm.runInNewContext(source, window);
  flush();
  return window;
}

function flush() {
  while (frames.length) frames.shift()();
}

const listObserver = (el) => mutationObservers.find((o) => o.target === el && o.connected);
const sizeObserver = (el) => resizeObservers.find((o) => o.target === el && o.connected);
// The script's own watcher for lists coming and going.
const pageObserver = () => mutationObservers.find((o) => o.target === body);

function newLine(el) {
  el.scrollHeight += 40;
  listObserver(el).cb([]);
  flush();
}

beforeEach(() => {
  elements = {};
});

test("a list shows its newest line, at the bottom, when the page loads", () => {
  const list = (elements["chat-messages"] = new FakeList("chat-messages"));
  load();
  assert.equal(list.scrollTop, 300);
});

test("a newest-first list (a phone) shows its newest line at the top", () => {
  const list = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  load();
  assert.equal(list.scrollTop, -300);
});

test("a new line scrolls to it, in either direction", () => {
  const plain = (elements["lobby-chat-messages"] = new FakeList("lobby-chat-messages"));
  const reversed = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  load();

  plain.scrollTop = 0;
  reversed.scrollTop = 0;
  newLine(plain);
  newLine(reversed);

  assert.equal(plain.scrollTop, 340);
  assert.equal(reversed.scrollTop, -340);
});

test("a newest-first list that changes size shows its newest line again", () => {
  const list = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  load();

  // A note shows under the input: the list is shorter, and its old offset
  // (counted from the oldest line) no longer reaches the newest.
  list.clientHeight = 160;
  assert.equal(list.scrollTop, -300);
  sizeObserver(list).cb([]);
  flush();

  assert.equal(list.scrollTop, -340);
});

test("a list that is not reversed keeps its place when it changes size", () => {
  const list = (elements["chat-messages"] = new FakeList("chat-messages"));
  load();

  list.scrollTop = 120; // the reader scrolled up
  list.clientHeight = 260;
  sizeObserver(list).cb([]);
  flush();

  assert.equal(list.scrollTop, 120);
});

test("crossing the phone breakpoint shows the newest line in the new direction", () => {
  const list = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  load();
  assert.equal(list.scrollTop, -300);

  // Wider than 720 px: the list runs oldest first again; the offset clamps
  // to 0, which is now the oldest line.
  list.reversed = false;
  list.scrollTop = list.scrollTop;
  assert.equal(list.scrollTop, 0);
  sizeObserver(list).cb([]);
  flush();
  assert.equal(list.scrollTop, 300);

  // And back.
  list.reversed = true;
  list.scrollTop = list.scrollTop;
  sizeObserver(list).cb([]);
  flush();
  assert.equal(list.scrollTop, -300);
});

test("without ResizeObserver the lists still follow new lines", () => {
  const list = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  load({ resizeObserver: false });
  assert.equal(resizeObservers.length, 0);

  list.scrollTop = 0;
  newLine(list);
  assert.equal(list.scrollTop, -340);
});

test("a list that leaves the page is let go, and a new one is picked up", () => {
  const first = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  load();
  const watcher = pageObserver();

  delete elements["chat-messages"];
  watcher.cb([]);
  assert.equal(listObserver(first), undefined);
  assert.equal(sizeObserver(first), undefined);

  const second = (elements["chat-messages"] = new FakeList("chat-messages", { reversed: true }));
  watcher.cb([]);
  flush();
  assert.equal(second.scrollTop, -300);
  assert.ok(sizeObserver(second));
});
