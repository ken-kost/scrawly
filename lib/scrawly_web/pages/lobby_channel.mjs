// Bridge between Hologram JS interop and the Phoenix LobbyChannel for real-time room list updates
// and a global guest/user chat that lives at the bottom of the home page.
// Uses window.Phoenix.Socket (loaded by phoenix.min.js).

var lobbySocket = null;
var lobbyChannel = null;

var GUEST_KEY = "scrawly:guest_nickname";

function getOrCreateGuestNickname() {
  try {
    var existing = localStorage.getItem(GUEST_KEY);
    if (existing && /^guest_\d+$/.test(existing)) return existing;
  } catch (_e) {
    // localStorage may be unavailable (private mode); fall through to ephemeral.
  }
  var n = Math.floor(1000 + Math.random() * 9000);
  var nick = "guest_" + n;
  try { localStorage.setItem(GUEST_KEY, nick); } catch (_e) {}
  return nick;
}

export function connectLobbyChannel(token) {
  if (lobbyChannel) return;

  if (!window.Phoenix || !window.Phoenix.Socket) {
    console.error("Phoenix.Socket not available for lobby channel");
    return;
  }

  var guestNickname = getOrCreateGuestNickname();
  var params = token
    ? { token: token, guest_nickname: guestNickname }
    : { lobby: "true", guest_nickname: guestNickname };

  lobbySocket = new window.Phoenix.Socket("/socket", { params: params });
  lobbySocket.connect();

  lobbyChannel = lobbySocket.channel("lobby:rooms", { guest_nickname: guestNickname });
  lobbyChannel.join()
    .receive("ok", function() {
      lobbyChannel.on("rooms_updated", function() {
        if (globalThis.Hologram && globalThis.Hologram.dispatchAction) {
          globalThis.Hologram.dispatchAction("refresh_rooms", "page", {});
        }
      });

      lobbyChannel.on("chat_message", function(payload) {
        if (globalThis.Hologram && globalThis.Hologram.dispatchAction) {
          globalThis.Hologram.dispatchAction("lobby_chat_received", "page", {
            username: payload.username,
            message: payload.message,
            is_guest: payload.is_guest,
            timestamp: payload.timestamp
          });
        }
      });

      lobbyChannel.on("chat_history", function(payload) {
        if (globalThis.Hologram && globalThis.Hologram.dispatchAction) {
          globalThis.Hologram.dispatchAction("lobby_chat_history_loaded", "page", {
            messages: payload.messages || []
          });
        }
      });

      lobbyChannel.on("chat_cleared", function() {
        if (globalThis.Hologram && globalThis.Hologram.dispatchAction) {
          globalThis.Hologram.dispatchAction("lobby_chat_cleared", "page", {});
        }
      });
    })
    .receive("error", function(resp) {
      console.error("Failed to join lobby channel:", resp);
      lobbyChannel = null;
    });
}

export function disconnectLobbyChannel() {
  if (lobbyChannel) {
    lobbyChannel.leave();
    lobbyChannel = null;
  }
  if (lobbySocket) {
    lobbySocket.disconnect();
    lobbySocket = null;
  }
}

export function sendLobbyChat(message) {
  if (!lobbyChannel) return;
  if (typeof message !== "string" || message.trim() === "") return;
  lobbyChannel.push("chat_message", { message: message });
}
