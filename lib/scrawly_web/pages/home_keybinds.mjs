// Global keyboard shortcuts for the home page.
// 'N' opens the create-room modal (or the login modal for unauthenticated users).

// The installed handler lives on window, not in this module: every page
// bundle that can reach HomePage carries its own copy of this module
// (Hologram 0.12), and install/uninstall may run through different copies.

export function installHomeKeybinds(authenticated) {
  uninstallHomeKeybinds();

  var handler = function(event) {
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

  window.__scrawlyHomeKeybinds = handler;
  window.addEventListener("keydown", handler);
}

export function uninstallHomeKeybinds() {
  var handler = window.__scrawlyHomeKeybinds;
  if (handler) {
    window.removeEventListener("keydown", handler);
    window.__scrawlyHomeKeybinds = null;
  }
}
