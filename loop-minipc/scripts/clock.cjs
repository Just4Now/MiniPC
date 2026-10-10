'use strict';

class ManualClock {
  constructor() {
    this.time = 0;
    this.seq = 1;
    this.timers = new Map();
  }

  now() {
    return this.time;
  }

  schedule(fn, ms) {
    const id = this.seq;
    this.seq += 1;
    this.timers.set(id, { at: this.time + ms, fn: fn });
    return id;
  }

  clear(id) {
    this.timers.delete(id);
  }

  advance(ms) {
    const target = this.time + ms;
    for (;;) {
      let next = null;
      for (const [id, timer] of this.timers) {
        if (timer.at > target) continue;
        if (next === null || timer.at < next.at || (timer.at === next.at && id < next.id)) {
          next = { id: id, at: timer.at, fn: timer.fn };
        }
      }
      if (next === null) break;
      this.timers.delete(next.id);
      this.time = next.at;
      next.fn();
    }
    this.time = target;
  }
}

module.exports = { ManualClock };
