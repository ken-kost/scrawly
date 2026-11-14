function isDrawer() {
  return document.getElementById("drawing-path") !== null;
}

function isTyping() {
  const el = document.activeElement;
  if (!el) return false;
  return el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable;
}

function dispatch(action) {
  if (globalThis.Hologram && globalThis.Hologram.dispatchAction) {
    globalThis.Hologram.dispatchAction(action, "page", {});
  }
}

function onKeyDown(e) {
  if (e.key === "Escape") {
    const el = document.activeElement;
    if (el && el.tagName === "INPUT" && el.name === "message") {
      e.preventDefault();
      dispatch("clear_message");
    }
    return;
  }

  if (isTyping() || !isDrawer()) return;

  if ((e.ctrlKey || e.metaKey) && !e.shiftKey && (e.key === "z" || e.key === "Z")) {
    e.preventDefault();
    dispatch("undo_drawing");
    return;
  }

  if (!e.ctrlKey && !e.metaKey && !e.altKey && (e.key === "e" || e.key === "E")) {
    e.preventDefault();
    dispatch("toggle_eraser");
  }
}

// Every page bundle that can reach GamePage carries its own copy of this
// module (Hologram 0.12), so a module-level flag would add one more listener
// per copy. The flag lives on window: one listener per tab. onKeyDown only
// reads the DOM and dispatches by name, so whichever copy installed it works.
export function installCanvasShortcuts() {
  if (window.__scrawlyCanvasShortcuts) return;
  window.__scrawlyCanvasShortcuts = true;
  document.addEventListener("keydown", onKeyDown);
}
