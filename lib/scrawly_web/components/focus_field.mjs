// Moves the keyboard focus to the element with `id`. Hologram patches the DOM
// after the action that asks for it, so the lookup waits a frame and retries
// briefly while the element isn't there yet. Hologram has no autofocus helper,
// and the `autofocus` attribute only works for the first element a document
// ever autofocuses.
export function focusField(id) {
  let tries = 0;

  const attempt = () => {
    const el = document.getElementById(id);

    if (el) {
      if (document.activeElement !== el) el.focus();
    } else if (tries++ < 5) {
      setTimeout(attempt, 30);
    }
  };

  requestAnimationFrame(attempt);
}
