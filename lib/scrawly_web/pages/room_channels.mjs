// The rooms whose Realtime channels this tab (one Hologram instance) may
// still be subscribed to on the server: GamePage and GameScorePage note
// their room when they subscribe. A page restored by Back/Forward takes the
// list and has its restore command delete the ones it doesn't want
// (ScrawlyWeb.RoomSubscriptions): the server still holds the subscriptions
// of the page shown before the restore.
//
// Kept on window: Hologram 0.12 copies this module into several page
// bundles.

const SLOT = "__scrawlyRoomChannels";
const MAX_ROOMS = 20;

function roomIds() {
  const ids = window[SLOT];
  return Array.isArray(ids) ? ids : [];
}

export function noteRoomChannel(roomId) {
  if (typeof roomId !== "string" || roomId === "") return;
  const ids = roomIds().filter((id) => id !== roomId);
  ids.push(roomId);
  window[SLOT] = ids.slice(-MAX_ROOMS);
}

// Every noted room but `keepId` (the restoring page's own room, if any),
// which stays the only one noted.
export function takeStaleRoomChannels(keepId) {
  const keep = typeof keepId === "string" && keepId !== "" ? keepId : null;
  const stale = roomIds().filter((id) => id !== keep);
  window[SLOT] = keep ? [keep] : [];
  return stale;
}
