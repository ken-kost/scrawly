// Bridge between Hologram JS interop and the Phoenix Channel for real-time game sync.
// Uses window.gameSocket (set up by game_socket.js which loads phoenix.min.js).
// Hologram actions are dispatched via globalThis.Hologram.dispatchAction().

import {
  applyRemoteChunk,
  abandonRemoteStroke
} from "./drawing_manager.mjs"

export function connectGameChannel(token, roomCode) {
  const gs = window.gameSocket
  if (!gs) {
    console.error("gameSocket not available on window")
    return
  }

  gs.connect(token)

  gs.joinRoom(roomCode)
    .receive("ok", () => {
      // The channel now carries ONLY live in-progress stroke chunks (+ abandon).
      // Completed strokes / clear / undo arrive via Hologram realtime, and the
      // full-canvas late-join sync comes from the page's init state (@strokes),
      // so there is no get_drawing_path fetch here anymore.
      const ch = gs._getChannel ? gs._getChannel() : null

      if (ch) {
        // Live in-progress chunks — handled entirely in JS, no Hologram dispatch.
        // Stays off the 20Hz Hologram re-render path.
        ch.on("drawing_stroke_chunk", (payload) => {
          applyRemoteChunk(payload.stroke_id, payload.delta, payload.color, payload.width)
        })

        // Drawer disconnected mid-stroke — GC the overlay.
        ch.on("drawing_stroke_abandon", (payload) => {
          abandonRemoteStroke(payload.stroke_id)
        })
      }

      // Tell Hologram the channel is connected — restores the drawer's local
      // stroke history and does a one-shot state resync.
      globalThis.Hologram.dispatchAction("channel_connected", "page", {})

      console.log("Game channel connected for room:", roomCode)
    })
    .receive("error", (resp) => {
      console.error("Failed to join game channel:", resp)
    })
}
