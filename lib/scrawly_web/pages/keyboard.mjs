
let installed = false;

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

export function installCanvasShortcuts() {
  if (installed) return;
  installed = true;
  document.addEventListener("keydown", onKeyDown);
}
