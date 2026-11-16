// A fake window.Phoenix for demo_board.mjs: sockets (their params read on
// every connect, as Phoenix does; onClose; disconnect with a callback), one
// channel per socket with its handlers, its join reply and its pushes,
// whose replies the tests answer.

class Reply {
  constructor() {
    this.hooks = {};
  }
  receive(status, fn) {
    (this.hooks[status] ||= []).push(fn);
    return this;
  }
  // The server's answer (or the push's timeout).
  answer(status, response) {
    for (const fn of this.hooks[status] || []) fn(response);
  }
}

class FakeChannel {
  constructor(socket, topic) {
    this.socket = socket;
    this.topic = topic;
    this.handlers = {};
    this.pushes = [];
    this.joinReply = new Reply();
  }
  on(event, fn) {
    this.handlers[event] = fn;
  }
  join() {
    return this.joinReply;
  }
  leave() {}
  push(event, payload) {
    const reply = new Reply();
    this.pushes.push({ event, payload, reply });
    return reply;
  }
  // A message from the server.
  emit(event, payload) {
    if (this.handlers[event]) this.handlers[event](payload);
  }
}

export function installFakePhoenix() {
  const sockets = [];

  globalThis.Phoenix = {
    Socket: class {
      constructor(endPoint, opts) {
        this.endPoint = endPoint;
        this.opts = opts || {};
        this.connects = [];
        this.closeHandlers = [];
        this.channels = [];
        this.connected = false;
        sockets.push(this);
      }
      connect() {
        const p = this.opts.params;
        this.connects.push(typeof p === "function" ? p() : p || {});
        this.connected = true;
      }
      disconnect(callback) {
        this.connected = false;
        for (const fn of this.closeHandlers) fn({ code: 1000 });
        if (callback) callback();
      }
      onClose(fn) {
        this.closeHandlers.push(fn);
      }
      // The server closed the socket (a "disconnect" broadcast).
      serverClose() {
        this.connected = false;
        for (const fn of this.closeHandlers) fn({ code: 1000 });
      }
      channel(topic) {
        const ch = new FakeChannel(this, topic);
        this.channels.push(ch);
        return ch;
      }
    },
  };

  return {
    sockets,
    socket: () => sockets.at(-1),
    channel: () => sockets.at(-1).channels.at(-1),
  };
}
