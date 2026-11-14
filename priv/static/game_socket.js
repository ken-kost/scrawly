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

  window.gameSocket = {
    connect: function(token) {
      if (socket) { this.disconnect(); }
      socket = new Phoenix.Socket("/socket", { params: { token: token } });
      socket.connect();
    },

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
      if (socket) { socket.disconnect(); socket = null; }
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
