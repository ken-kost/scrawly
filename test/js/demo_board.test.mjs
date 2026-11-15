// The home page's board (lib/scrawly_web/pages/demo_board.mjs) draws with
// the shared tool model (draw_tools.mjs), like the in-game canvas: the tool
// HomePage pushes is the one a stroke starts with, eraser included, the
// eraser erases at the slider's size, and so does a right-button or Ctrl
// stroke, without changing the selected tool.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, mock, after } from "node:test";
import assert from "node:assert/strict";

import { installFakeDom, FakeEl, tap } from "./support/fake_dom.mjs";

const { root } = installFakeDom();
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });

// What demo_board.mjs uses of Phoenix.Socket: the pushes it sends.
const pushes = [];
globalThis.Phoenix = {
  Socket: class {
    connect() {}
    disconnect() {}
    channel() {
      const reply = { receive: () => reply };
      return {
        on() {},
        join: () => reply,
        leave() {},
        push(event, payload) {
          pushes.push({ event, payload });
          return reply;
        },
      };
    }
  },
};

const board = await import("../../lib/scrawly_web/pages/demo_board.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");

// GameDemo's markup.
function renderBoard() {
  root.children = [];
  const svg = new FakeEl("svg", "demo-board-svg");
  svg.getScreenCTM = () => ({ inverse: () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }) });
  svg.setPointerCapture = () => {};
  svg.hasPointerCapture = () => false;
  svg.releasePointerCapture = () => {};
  svg.appendChild(new FakeEl("g", "demo-board-strokes"));
  svg.appendChild(new FakeEl("g", "demo-board-overlay"));
  svg.appendChild(new FakeEl("path", "demo-board-active-path"));
  root.appendChild(svg);
  return svg;
}

const completed = () => pushes.filter((p) => p.event === "stroke_complete").map((p) => p.payload);
const chunks = () => pushes.filter((p) => p.event === "stroke_chunk").map((p) => p.payload);

after(() => board.disconnectDemoBoard());

test("a stroke on the board starts with the tool the page pushed", () => {
  const svg = renderBoard();
  // HomePage :connect_lobby: its tool, then the board.
  tools.setDrawTool({ tool: "brush", color: "#d63838", size: 10 });
  board.connectDemoBoard();

  tap(svg, 40, 30);
  assert.deepEqual(
    [completed().at(-1).color, completed().at(-1).width, chunks().at(-1).color, chunks().at(-1).width],
    ["#d63838", 10, "#d63838", 10]
  );

  // The toolbar's eraser: white, at the brush's size.
  tools.setDrawTool({ tool: "eraser" });
  tap(svg, 60, 30);
  assert.equal(completed().at(-1).color, tools.ERASER.color);
  assert.equal(completed().at(-1).width, 10);

  // The slider while erasing: the eraser stays, at the new size.
  for (const size of [1, 40]) {
    tools.setDrawTool({ size });
    tap(svg, 70, 30);
    assert.deepEqual(
      [completed().at(-1).color, completed().at(-1).width, chunks().at(-1).width],
      [tools.ERASER.color, size, size]
    );
  }

  // Back to the brush: its colour was kept, the size is the shared one.
  tools.setDrawTool({ tool: "brush", size: 10 });
  tap(svg, 80, 30);
  assert.equal(completed().at(-1).color, "#d63838");
  assert.equal(completed().at(-1).width, 10);

  const drawn = document.getElementById("demo-board-strokes").children;
  assert.deepEqual(
    drawn.map((el) => [el.getAttribute("stroke"), el.getAttribute("stroke-width")]),
    [
      ["#d63838", "10"],
      ["#ffffff", "10"],
      ["#ffffff", "1"],
      ["#ffffff", "40"],
      ["#d63838", "10"],
    ]
  );
});

test("a right-button or Ctrl stroke on the board erases; the toolbar's brush stays", () => {
  const svg = renderBoard();
  tools.setDrawTool({ tool: "brush", color: "#1f9a4a", size: 8 });
  board.connectDemoBoard();

  tap(svg, 40, 40, 1, { button: 2, buttons: 2 });
  assert.deepEqual([completed().at(-1).color, completed().at(-1).width], [tools.ERASER.color, 8]);
  assert.deepEqual([chunks().at(-1).color, chunks().at(-1).width], [tools.ERASER.color, 8]);

  tap(svg, 50, 40, 1, { ctrlKey: true });
  assert.deepEqual([completed().at(-1).color, completed().at(-1).width], [tools.ERASER.color, 8]);

  tap(svg, 60, 40);
  assert.deepEqual([completed().at(-1).color, completed().at(-1).width], ["#1f9a4a", 8]);
  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#1f9a4a", size: 8 });
});
