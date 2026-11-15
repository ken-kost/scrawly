// lib/scrawly_web/pages/room_links.mjs: the lobby's invite link (built from
// the page's origin, copied with the Clipboard API, else with a selection,
// else handed back to show) and Home's full page load for signed-out visitors.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

const dispatched = [];
const assigned = [];
let clipboardWrites = [];
let clipboardResult = "ok";
let execResult = true;
let execCalls = 0;
let byId = {};

const body = {
  children: [],
  appendChild(el) {
    this.children.push(el);
  },
  removeChild(el) {
    this.children = this.children.filter((c) => c !== el);
  },
};

globalThis.window = globalThis;
globalThis.location = {
  origin: "https://scrawly.example",
  assign: (path) => assigned.push(path),
};
globalThis.isSecureContext = true;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  writable: true,
  value: {
    clipboard: {
      writeText(text) {
        clipboardWrites.push(text);
        if (clipboardResult === "ok") return Promise.resolve();
        if (clipboardResult === "never") return new Promise(() => {});
        return Promise.reject(new Error("NotAllowedError"));
      },
    },
  },
});
globalThis.document = {
  body,
  getElementById: (id) => byId[id] || null,
  createElement: (tag) => ({
    tag,
    style: {},
    attrs: {},
    setAttribute(k, v) {
      this.attrs[k] = v;
    },
    select() {
      this.selected = true;
    },
  }),
  execCommand(command) {
    execCalls++;
    assert.equal(command, "copy");
    if (execResult === "throw") throw new Error("not allowed");
    return execResult;
  },
};
globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0);
globalThis.Hologram = {
  dispatchAction: (name, target, params) => dispatched.push({ name, target, params }),
};

const links = await import("../../lib/scrawly_web/pages/room_links.mjs");

// Lets the module's promise chain (and its 0 ms timers) run.
const settle = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

beforeEach(() => {
  dispatched.length = 0;
  assigned.length = 0;
  clipboardWrites = [];
  clipboardResult = "ok";
  execResult = true;
  execCalls = 0;
  globalThis.isSecureContext = true;
  body.children = [];
  byId = {};
});

test("the invite link is the page's own origin + /r/<code>", () => {
  assert.equal(links.inviteLink("45CVX7"), "https://scrawly.example/r/45CVX7");
  // Never anything but a path segment.
  assert.equal(links.inviteLink("a/b?c"), "https://scrawly.example/r/a%2Fb%3Fc");
});

test("copies with the Clipboard API and tells the page", async () => {
  links.copyInviteLink("45CVX7");
  await settle();

  assert.deepEqual(clipboardWrites, ["https://scrawly.example/r/45CVX7"]);
  assert.equal(execCalls, 0);
  assert.deepEqual(dispatched, [
    {
      name: "invite_link_copied",
      target: "page",
      params: { copied: true, link: "https://scrawly.example/r/45CVX7" },
    },
  ]);
});

test("a refused Clipboard API falls back to copying a selection", async () => {
  clipboardResult = "reject";
  links.copyInviteLink("45CVX7");
  await settle();

  assert.equal(execCalls, 1);
  assert.equal(body.children.length, 0, "the helper textarea is removed");
  assert.equal(dispatched[0].params.copied, true);
});

test("plain http (no secure context) goes straight to the selection", async () => {
  globalThis.isSecureContext = false;
  links.copyInviteLink("45CVX7");
  await settle();

  assert.deepEqual(clipboardWrites, []);
  assert.equal(execCalls, 1);
  assert.equal(dispatched[0].params.copied, true);
});

test("when nothing copies, the page gets the link to show", async () => {
  globalThis.isSecureContext = false;
  execResult = false;
  links.copyInviteLink("45CVX7");
  await settle();

  assert.deepEqual(dispatched[0].params, {
    copied: false,
    link: "https://scrawly.example/r/45CVX7",
  });

  dispatched.length = 0;
  execResult = "throw";
  links.copyInviteLink("45CVX7");
  await settle();
  assert.equal(dispatched[0].params.copied, false);
  assert.equal(body.children.length, 0);
});

test("a clipboard promise that never settles counts as refused", async () => {
  clipboardResult = "never";
  execResult = false;
  links.copyInviteLink("45CVX7");
  await settle(10);
  assert.equal(dispatched.length, 0, "still waiting");

  await settle(2100);
  assert.equal(execCalls, 1);
  assert.equal(dispatched[0].params.copied, false);
});

test("selectInviteLink focuses and selects the input once it exists", async () => {
  const input = { focus() { this.focused = true; }, select() { this.selected = true; } };
  links.selectInviteLink("invite-link");
  await settle();
  byId["invite-link"] = input;
  await settle(80);

  assert.equal(input.focused, true);
  assert.equal(input.selected, true);
});

test("openPath loads same-origin paths only", () => {
  links.openPath("/guest?return_to=%2Fgame%2Fabc");
  links.openPath("//evil.example/x");
  links.openPath("/\\evil.example");
  links.openPath("https://evil.example");
  links.openPath(42);

  assert.deepEqual(assigned, ["/guest?return_to=%2Fgame%2Fabc"]);
});
