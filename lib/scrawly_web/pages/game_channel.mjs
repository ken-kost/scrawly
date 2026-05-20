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
      // Request current drawing strokes for late-joiner sync
      const ref = gs.requestDrawingPath()
      if (ref) {
        ref.receive("ok", (resp) => {
          if (resp.strokes && resp.strokes.length > 0) {
            globalThis.Hologram.dispatchAction("sync_full_drawing_path", "page", {
              strokes: resp.strokes
            })
          }
        })
      }

      // Get the underlying Phoenix channel for event handlers
      const ch = gs._getChannel ? gs._getChannel() : null

      if (ch) {
        // Stroke events from other players (new format with color/width)
        ch.on("drawing_stroke", (payload) => {
          globalThis.Hologram.dispatchAction("receive_drawing_stroke", "page", {
            path: payload.path,
            color: payload.color,
            width: payload.width
          })
        })

        // Live in-progress chunks — handled entirely in JS, no Hologram dispatch.
        // Stays off the 20Hz Hologram re-render path.
        ch.on("drawing_stroke_chunk", (payload) => {
          applyRemoteChunk(payload.stroke_id, payload.delta, payload.color, payload.width)
        })

        // Stroke completion — dispatch through Hologram so the overlay-remove
        // (via JS.call) and the state update that renders the canonical stroke
        // commit in the same render cycle. Avoids a flicker between the two.
        ch.on("drawing_stroke_complete", (payload) => {
          globalThis.Hologram.dispatchAction("receive_drawing_stroke_complete", "page", {
            stroke_id: payload.stroke_id,
            path: payload.path,
            color: payload.color,
            width: payload.width
          })
        })

        // Drawer disconnected mid-stroke — GC the overlay.
        ch.on("drawing_stroke_abandon", (payload) => {
          abandonRemoteStroke(payload.stroke_id)
        })

        // Legacy segment events (backward compat)
        ch.on("drawing_segment", (payload) => {
          globalThis.Hologram.dispatchAction("receive_drawing_segment", "page", {
            segment: payload.segment
          })
        })

        ch.on("drawing_clear", () => {
          globalThis.Hologram.dispatchAction("receive_drawing_clear", "page", {})
        })

        ch.on("drawing_undo", (payload) => {
          globalThis.Hologram.dispatchAction("receive_drawing_undo", "page", {
            strokes: payload.strokes
          })
        })

        // Room state changed — trigger a one-shot poll to fetch fresh state
        ch.on("room_state_changed", () => {
          globalThis.Hologram.dispatchAction("poll_room", "page", {})
        })

        // Presence events — player join/leave triggers an immediate state poll
        ch.on("presence_diff", () => {
          globalThis.Hologram.dispatchAction("poll_room", "page", {})
        })
      }

      // Tell Hologram the channel is actually connected now
      globalThis.Hologram.dispatchAction("channel_connected", "page", {})
      globalThis.Hologram.dispatchAction("poll_room", "page", {})

      console.log("Game channel connected for room:", roomCode)
    })
    .receive("error", (resp) => {
      console.error("Failed to join game channel:", resp)
    })
}

export function pushDrawingSegment(segment) {
  const gs = window.gameSocket
  if (gs && gs.isInRoom()) {
    gs.sendDrawingSegment(segment)
  }
}

export function pushDrawingClear() {
  const gs = window.gameSocket
  if (gs && gs.isInRoom()) {
    gs.sendDrawingClear()
  }
}
