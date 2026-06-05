
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
      const ch = gs._getChannel ? gs._getChannel() : null

      if (ch) {
        ch.on("drawing_stroke_chunk", (payload) => {
          applyRemoteChunk(payload.stroke_id, payload.delta, payload.color, payload.width)
        })

        ch.on("drawing_stroke_abandon", (payload) => {
          abandonRemoteStroke(payload.stroke_id)
        })
      }

      globalThis.Hologram.dispatchAction("channel_connected", "page", {})

      console.log("Game channel connected for room:", roomCode)
    })
    .receive("error", (resp) => {
      console.error("Failed to join game channel:", resp)
    })
}
