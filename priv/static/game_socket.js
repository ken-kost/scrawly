// Minimal game socket setup for Hologram pages.
// Requires phoenix.min.js to be loaded first (provides global Phoenix object).
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

    sendDrawingSegment: function(segment) {
      if (channel) channel.push("drawing_segment", { segment: segment });
    },

    sendDrawingStroke: function(path, color, width) {
      if (channel) channel.push("drawing_stroke", { segment: path, color: color, width: width });
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

    sendDrawingStrokeComplete: function(strokeId, path, color, width) {
      if (channel) channel.push("drawing_stroke_complete", {
        stroke_id: strokeId,
        path: path,
        color: color,
        width: width
      });
    },

    sendDrawingClear: function() {
      if (channel) channel.push("drawing_clear", {});
    },

    sendDrawingUndo: function() {
      return channel ? channel.push("drawing_undo", {}) : null;
    },

    requestDrawingPath: function() {
      return channel ? channel.push("get_drawing_path", {}) : null;
    },

    isInRoom: function() { return !!channel && !!currentRoomCode; },

    // Expose the underlying Phoenix channel for direct event registration
    _getChannel: function() { return channel; },

    // Callback registration stubs — actual handlers are set up in game_channel.mjs
    onDrawingSegment: function() {},
    onDrawingClear: function() {}
  };
})();
