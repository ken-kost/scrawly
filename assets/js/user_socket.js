// Game Socket for Scrawly multiplayer drawing game
import { Socket, Presence } from "phoenix"

class GameSocket {
  constructor() {
    this.socket = null
    this.channel = null
    this.presence = null
    this.currentRoomCode = null
    this.isConnected = false
    this.callbacks = {
      onDrawingStart: [],
      onDrawingMove: [],
      onDrawingStop: [],
      onChatMessage: [],
      onPresenceUpdate: [],
      onJoinSuccess: [],
      onJoinError: [],
      onGameStarted: [],
      onGameEnded: [],
      onRoundStarted: [],
      onRoundEnded: [],
      onTurnChanged: []
    }
  }

  // Initialize socket connection with authentication token
  connect(token) {
    if (this.socket) {
      this.disconnect()
    }

    this.socket = new Socket("/socket", {
      params: { token: token }
    })

    this.socket.connect()
    this.isConnected = true
    console.log("Game socket connected")
    return this.socket
  }

  // Join a game room
  joinRoom(roomCode) {
    if (!this.socket || !this.isConnected) {
      console.error("Socket not connected. Call connect() first.")
      return Promise.reject("Socket not connected")
    }

    if (this.channel) {
      this.leaveRoom()
    }

    this.currentRoomCode = roomCode
    this.channel = this.socket.channel(`game:${roomCode}`, {})

    // Set up presence tracking
    this.presence = new Presence(this.channel)
    this.setupPresenceHandlers()
    this.setupChannelHandlers()

    return this.channel.join()
      .receive("ok", (resp) => {
        console.log(`Joined room ${roomCode} successfully`, resp)
        this.callbacks.onJoinSuccess.forEach(cb => cb(resp))
      })
      .receive("error", (resp) => {
        console.error(`Unable to join room ${roomCode}`, resp)
        this.callbacks.onJoinError.forEach(cb => cb(resp))
      })
  }

  // Leave current room
  leaveRoom() {
    if (this.channel) {
      this.channel.leave()
      this.channel = null
      this.presence = null
      this.currentRoomCode = null
      console.log("Left room")
    }
  }

  // Disconnect socket
  disconnect() {
    if (this.channel) {
      this.leaveRoom()
    }
    if (this.socket) {
      this.socket.disconnect()
      this.socket = null
      this.isConnected = false
      console.log("Game socket disconnected")
    }
  }

  // Drawing events
  sendDrawingStart(x, y) {
    this.pushEvent("drawing_start", { x, y })
  }

  sendDrawingMove(x, y) {
    this.pushEvent("drawing_move", { x, y })
  }

  sendDrawingStop() {
    this.pushEvent("drawing_stop", {})
  }

  // Chat events
  sendChatMessage(message) {
    this.pushEvent("chat_message", { message })
  }

  // Game state events
  startGame() {
    this.pushEvent("start_game", {})
  }

  endGame() {
    this.pushEvent("end_game", {})
  }

  startRound(roundNumber) {
    this.pushEvent("round_start", { round_number: roundNumber })
  }

  endRound(roundNumber) {
    this.pushEvent("round_end", { round_number: roundNumber })
  }

  changeTurn(drawerId) {
    this.pushEvent("turn_change", { drawer_id: drawerId })
  }

  // Event callbacks
  onDrawingStart(callback) {
    this.callbacks.onDrawingStart.push(callback)
  }

  onDrawingMove(callback) {
    this.callbacks.onDrawingMove.push(callback)
  }

  onDrawingStop(callback) {
    this.callbacks.onDrawingStop.push(callback)
  }

  onChatMessage(callback) {
    this.callbacks.onChatMessage.push(callback)
  }

  onPresenceUpdate(callback) {
    this.callbacks.onPresenceUpdate.push(callback)
  }

  onJoinSuccess(callback) {
    this.callbacks.onJoinSuccess.push(callback)
  }

  onJoinError(callback) {
    this.callbacks.onJoinError.push(callback)
  }

  onGameStarted(callback) {
    this.callbacks.onGameStarted.push(callback)
  }

  onGameEnded(callback) {
    this.callbacks.onGameEnded.push(callback)
  }

  onRoundStarted(callback) {
    this.callbacks.onRoundStarted.push(callback)
  }

  onRoundEnded(callback) {
    this.callbacks.onRoundEnded.push(callback)
  }

  onTurnChanged(callback) {
    this.callbacks.onTurnChanged.push(callback)
  }

  // Private methods
  pushEvent(event, payload) {
    if (!this.channel) {
      console.error("Not connected to a room")
      return
    }

    this.channel.push(event, payload)
      .receive("ok", (resp) => {
        console.log(`${event} sent successfully`, resp)
      })
      .receive("error", (resp) => {
        console.error(`Failed to send ${event}`, resp)
      })
  }

  setupChannelHandlers() {
    // Drawing events
    this.channel.on("drawing_start", (payload) => {
      this.callbacks.onDrawingStart.forEach(cb => cb(payload))
    })

    this.channel.on("drawing_move", (payload) => {
      this.callbacks.onDrawingMove.forEach(cb => cb(payload))
    })

    this.channel.on("drawing_stop", (payload) => {
      this.callbacks.onDrawingStop.forEach(cb => cb(payload))
    })

    // Chat events
    this.channel.on("chat_message", (payload) => {
      this.callbacks.onChatMessage.forEach(cb => cb(payload))
    })

    // Game state events
    this.channel.on("game_started", (payload) => {
      this.callbacks.onGameStarted.forEach(cb => cb(payload))
    })

    this.channel.on("game_ended", (payload) => {
      this.callbacks.onGameEnded.forEach(cb => cb(payload))
    })

    this.channel.on("round_started", (payload) => {
      this.callbacks.onRoundStarted.forEach(cb => cb(payload))
    })

    this.channel.on("round_ended", (payload) => {
      this.callbacks.onRoundEnded.forEach(cb => cb(payload))
    })

    this.channel.on("turn_changed", (payload) => {
      this.callbacks.onTurnChanged.forEach(cb => cb(payload))
    })
  }

  setupPresenceHandlers() {
    this.presence.onSync(() => {
      const presenceData = this.presence.list()
      this.callbacks.onPresenceUpdate.forEach(cb => cb(presenceData))
    })
  }

  // Get current presence data
  getPresence() {
    return this.presence ? this.presence.list() : {}
  }

  // Get current room code
  getRoomCode() {
    return this.currentRoomCode
  }

  // Check if connected to a room
  isInRoom() {
    return this.channel && this.currentRoomCode
  }
}

// Create singleton instance
const gameSocket = new GameSocket()

// Export for use in other modules
export default gameSocket
