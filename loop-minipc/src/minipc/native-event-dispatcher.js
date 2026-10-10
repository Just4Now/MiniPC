'use strict';

class NativeEventDispatcher {
  constructor(takeEvents) {
    this.takeEvents = takeEvents;
    this.handlers = new Map();
    this.buffer = new Map();
    this.polling = false;
  }

  subscribe(nativeId, handler) {
    this.handlers.set(nativeId, handler);
    const waiting = this.buffer.get(nativeId) || [];
    this.buffer.delete(nativeId);
    for (const event of waiting) handler(event);
  }

  unsubscribe(nativeId) {
    this.handlers.delete(nativeId);
  }

  poll() {
    if (this.polling) return;
    this.polling = true;
    try {
      const lines = this.takeEvents() || [];
      for (const line of lines) this.dispatch(line);
    } finally {
      this.polling = false;
    }
  }

  dispatch(line) {
    let event;
    try {
      event = JSON.parse(line);
    } catch (_error) {
      return;
    }
    const nativeId = Number(event.id);
    if (!nativeId) return;
    const handler = this.handlers.get(nativeId);
    if (handler) {
      handler(event);
      return;
    }
    const waiting = this.buffer.get(nativeId) || [];
    if (waiting.length < 32) waiting.push(event);
    this.buffer.set(nativeId, waiting);
  }
}

module.exports = { NativeEventDispatcher };
