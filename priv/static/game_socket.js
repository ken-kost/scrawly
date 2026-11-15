// Minimal game socket setup for Hologram pages.
// Requires phoenix.min.js to be loaded first (provides global Phoenix object).
//
// The game channel carries only the drawer's live stroke chunks
// (sendDrawingStrokeChunk, ScrawlyWeb.GameChannel); completed strokes, undo,
// clear and the canvas snapshot go through Hologram commands and Realtime.
(function() {
  if (!window.Phoenix || !window.Phoenix.Socket) {
    console.error("Phoenix.Socket not available for game socket setup");
    return;
  }

  var socket = null;
  var channel = null;
  var currentRoomCode = null;
  var serverCloseHandler = null;

  window.gameSocket = {
    // `token` is a socket-only token (ScrawlyWeb.SocketToken), never the
    // session's sign-in token.
    connect: function(token) {
      if (socket) { this.disconnect(); }
      var s = new Phoenix.Socket("/socket", { params: { token: token } });
      socket = s;
      // The server closes a socket with code 1000 when the user's tokens were
      // revoked (a "disconnect" broadcast), and Phoenix never retries such a
      // close. Our own disconnect() drops `socket` first, so it doesn't count.
      s.onClose(function(event) {
        if (socket === s && event && event.code === 1000 && serverCloseHandler) {
          serverCloseHandler();
        }
      });
      s.connect();
    },

    // Called (once per close) when the server closed the socket for good.
    onServerClose: function(handler) { serverCloseHandler = handler; },

    joinRoom: function(roomCode) {
      if (!socket) { return { receive: function() { return this; } }; }
      if (channel) { this.leaveRoom(); }
      currentRoomCode = roomCode;
      channel = socket.channel("game:" + roomCode, {});
      return channel.join();
    },

    leaveRoom: function() {
      if (channel) { channel.leave(); channel = null; currentRoomCode = null; }
    },

    disconnect: function() {
      this.leaveRoom();
      if (socket) { var s = socket; socket = null; s.disconnect(); }
    },

    sendDrawingStrokeChunk: function(strokeId, seq, delta, color, width) {
      if (channel) channel.push("drawing_stroke_chunk", {
        stroke_id: strokeId,
        seq: seq,
        delta: delta,
        color: color,
        width: width
      });
    },

    isInRoom: function() { return !!channel && !!currentRoomCode; },

    // Expose the underlying Phoenix channel for direct event registration
    // (game_channel.mjs registers the handlers)
    _getChannel: function() { return channel; }
  };
})();
