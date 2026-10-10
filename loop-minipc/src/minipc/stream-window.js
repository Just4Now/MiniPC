'use strict';

class StreamWindow {
  constructor(maxSeq, maxBytes) {
    this.maxSeq = maxSeq || 16;
    this.maxBytes = maxBytes || 16384;
    this.next = 1;
    this.bytes = 0;
    this.items = [];
  }

  push(byteLength) {
    if (this.items.length >= this.maxSeq || this.bytes + byteLength > this.maxBytes) return 0;
    const seq = this.next;
    this.next += 1;
    this.items.push({ seq: seq, byteLength: byteLength });
    this.bytes += byteLength;
    return seq;
  }

  ack(ackSeq) {
    while (this.items.length > 0 && this.items[0].seq <= ackSeq) {
      this.bytes -= this.items.shift().byteLength;
    }
  }
}

module.exports = { StreamWindow };
