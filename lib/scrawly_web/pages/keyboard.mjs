// Keyboard shortcuts via JS interop.
//
// Hologram v0.9.2 has NO native keyboard events — the runtime supports only
// click / pointer / mouse / input / change / select / submit / focus /
// transition (see usage-rules/events.md), so there is no `$key_down` to bind in
// a template. Until Hologram ships key events, these shortcuts ride a single
// document `keydown` listener that dispatches the page's existing Hologram
// actions (`undo_drawing`, `toggle_eraser`, `clear_message`).
//
// Gating:
//   * Drawer-only canvas shortcuts are active only when `#drawing-path` is in the
//     DOM — that element renders exclusively for `is_drawer` (see DrawingCanvas),
//     so it is a reliable "am I the drawer right now?" signal.
//   * They are suppressed while typing in a field, so pressing "e" in chat types
//     an "e" instead of toggling the eraser.
//   * Escape clears the chat input and is allowed *while* focused in it.

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
  // Escape clears the chat input — allowed while focused in it.
  if (e.key === "Escape") {
    const el = document.activeElement;
    if (el && el.tagName === "INPUT" && el.name === "message") {
      e.preventDefault();
      dispatch("clear_message");
    }
    return;
  }

  if (isTyping() || !isDrawer()) return;

  // Ctrl/Cmd+Z → undo last completed stroke.
  if ((e.ctrlKey || e.metaKey) && !e.shiftKey && (e.key === "z" || e.key === "Z")) {
    e.preventDefault();
    dispatch("undo_drawing");
    return;
  }

  // E → toggle the eraser (no modifiers).
  if (!e.ctrlKey && !e.metaKey && !e.altKey && (e.key === "e" || e.key === "E")) {
    e.preventDefault();
    dispatch("toggle_eraser");
  }
}

// Idempotent: at most one document listener for the app's lifetime. When the
// player isn't the drawer (or has navigated away), the gates above make it a
// no-op, so it is safe to leave installed across SPA navigation.
export function installCanvasShortcuts() {
  if (installed) return;
  installed = true;
  document.addEventListener("keydown", onKeyDown);
}
