import {
  applyRemoteChunk,
  abandonRemoteStroke,
  gamePageGeneration,
  gamePagePresent
} from "./drawing_manager.mjs"

// The game socket (priv/static/game_socket.js) outlives Hologram page
// navigation, so everything it delivers is checked against the page that
// connected it: a GamePage marker must still be in the document, and no newer
// GamePage mount may have happened since. Otherwise the channel leaves instead
// of touching (or dispatching actions to) another page.
//
// Handlers are registered once per channel, outside the join push's "ok" hook:
// Phoenix keeps receive hooks across rejoins and calls them again on every
// reconnect, so the hook only reports the (re)connection.

function leaveStaleChannel(gs, ch) {
  if (gs._getChannel && gs._getChannel() === ch) {
    gs.disconnect()
  } else {
    ch.leave()
  }
}

export function connectGameChannel(token, roomCode) {
  const gs = window.gameSocket
  if (!gs) {
    console.error("gameSocket not available on window")
    return
  }

  const generation = gamePageGeneration()
  const isCurrentPage = () => generation === gamePageGeneration() && gamePagePresent()

  gs.connect(token)
  const join = gs.joinRoom(roomCode)
  const ch = gs._getChannel ? gs._getChannel() : null
  if (!ch) return

  const forPage = (handler) => (payload) => {
    if (!isCurrentPage()) {
      leaveStaleChannel(gs, ch)
      return
    }
    handler(payload)
  }

  ch.on("drawing_stroke_chunk", forPage((payload) => {
    applyRemoteChunk(payload.stroke_id, payload.seq, payload.delta, payload.color, payload.width)
  }))

  ch.on("drawing_stroke_abandon", forPage((payload) => {
    abandonRemoteStroke(payload.stroke_id)
  }))

  // The server closed the socket (the user's tokens were revoked somewhere):
  // the page asks for a fresh token, which a still-valid session gets.
  gs.onServerClose(() => {
    const current = isCurrentPage()
    leaveStaleChannel(gs, ch)
    if (current) globalThis.Hologram.dispatchAction("game_channel_refused", "page", {})
  })

  // A refused join (also what a socket that reconnected with an expired or
  // revoked socket token gets: it connects anonymously) closes the socket, so
  // Phoenix stops retrying with the same token, and lets the page fetch a
  // fresh token (GamePage :game_channel_refused).
  join
    .receive("ok", forPage(() => {
      globalThis.Hologram.dispatchAction("channel_connected", "page", {})
      console.log("Game channel connected for room:", roomCode)
    }))
    .receive("error", (resp) => {
      console.warn("Game channel join refused:", resp && resp.reason)
      const current = isCurrentPage()
      leaveStaleChannel(gs, ch)
      if (current) globalThis.Hologram.dispatchAction("game_channel_refused", "page", {})
    })
}

// A GamePage brought back by Back/Forward: joins the room's channel afresh.
// The restore started a new page generation (drawing_manager.mjs
// restoreCanvas), so the handlers of a channel still joined from before are
// stale (they leave on their next event); connect() replaces that socket.
export function ensureGameChannel(token, roomCode) {
  connectGameChannel(token, roomCode)
}

// GamePage calls this before it navigates away (put_page).
export function disconnectGameChannel() {
  const gs = window.gameSocket
  if (gs) gs.disconnect()
}
