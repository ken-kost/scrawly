// Links to a room, made in the browser.
//
// The invite link is built from the page's own origin (window.location.origin),
// never on the server from the request's Host header: that header is
// client-supplied, so a link built from it could send friends to another site.
//
// Hologram 0.12 puts a copy of this module in every page bundle that can reach
// GamePage or HomePage. It keeps no state, so the copies don't matter.

const CLIPBOARD_TIMEOUT_MS = 2000;

export function inviteLink(code) {
  return window.location.origin + "/r/" + encodeURIComponent(String(code));
}

// The Clipboard API exists only in secure contexts (https, localhost), and can
// still be refused (permissions, a frame without clipboard-write). A promise
// that never settles counts as refused after CLIPBOARD_TIMEOUT_MS.
function copyWithClipboardApi(text) {
  if (!window.isSecureContext || !navigator.clipboard || !navigator.clipboard.writeText) {
    return Promise.resolve(false);
  }

  let write;

  try {
    write = navigator.clipboard.writeText(text).then(
      () => true,
      () => false,
    );
  } catch (_error) {
    return Promise.resolve(false);
  }

  const timeout = new Promise((resolve) => setTimeout(() => resolve(false), CLIPBOARD_TIMEOUT_MS));
  return Promise.race([write, timeout]);
}

// The older way, which also works on plain-http origins: select the text in a
// hidden textarea and ask the browser to copy the selection.
function copyWithSelection(text) {
  if (!document.body || typeof document.execCommand !== "function") return false;

  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.top = "0";
  area.style.left = "0";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();

  let copied = false;

  try {
    copied = document.execCommand("copy") === true;
  } catch (_error) {
    copied = false;
  }

  document.body.removeChild(area);
  return copied;
}

// GamePage :copy_invite_link. Answers with the page action
// :invite_link_copied %{copied: boolean, link: string}; when nothing could
// copy, the page shows the link to copy by hand.
export function copyInviteLink(code) {
  const link = inviteLink(code);

  copyWithClipboardApi(link)
    .then((copied) => copied || copyWithSelection(link))
    .catch(() => false)
    .then((copied) => {
      globalThis.Hologram.dispatchAction("invite_link_copied", "page", {
        copied: copied === true,
        link,
      });
    });
}

// Selects the text of the input with `id` (the hand-copy fallback). Hologram
// patches the DOM after the action that asks for it, so the lookup waits a
// frame and retries briefly while the input isn't there yet.
export function selectInviteLink(id) {
  let tries = 0;

  const attempt = () => {
    const el = document.getElementById(id);

    if (el) {
      el.focus();
      el.select();
    } else if (tries++ < 5) {
      setTimeout(attempt, 30);
    }
  };

  requestAnimationFrame(attempt);
}

// HomePage :open_room_as_guest: a full page load, because the guest sign-in
// (/guest) is a controller route, not a Hologram page. Same-origin paths only.
export function openPath(path) {
  if (
    typeof path === "string" &&
    path.startsWith("/") &&
    !path.startsWith("//") &&
    !path.startsWith("/\\")
  ) {
    window.location.assign(path);
  }
}
