// Global keyboard shortcuts for the home page.
// 'N' opens the create-room modal (or the login modal for unauthenticated users).

var handler = null;

export function installHomeKeybinds(authenticated) {
  uninstallHomeKeybinds();

  handler = function(event) {
    if (event.key !== "n" && event.key !== "N") return;
    if (event.metaKey || event.ctrlKey || event.altKey) return;

    var t = event.target;
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;

    if (!globalThis.Hologram || !globalThis.Hologram.dispatchAction) return;

    event.preventDefault();
    if (authenticated) {
      globalThis.Hologram.dispatchAction("show_create_room", "page", {});
    } else {
      globalThis.Hologram.dispatchAction("show_login", "layout", {});
    }
  };

  window.addEventListener("keydown", handler);
}

export function uninstallHomeKeybinds() {
  if (handler) {
    window.removeEventListener("keydown", handler);
    handler = null;
  }
}
