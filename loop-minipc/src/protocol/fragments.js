'use strict';

const { utf8Bytes, encodeBase64, decodeBase64, bytesToUtf8 } = require('./text');

const CHUNK_BYTES = 480;
const MAX_FRAME = 65536;
const MAX_PARTS = Math.ceil(MAX_FRAME / CHUNK_BYTES);
const MAX_PENDING = 8;
const FRAGMENT_IDLE_MS = 15000;
const FRAGMENT_ABSOLUTE_MS = 60000;

function validFragmentId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(id);
}

function encodeFrames(message, id) {
  if (!validFragmentId(id)) throw new Error('Invalid fragment ID');
  const bytes = utf8Bytes(JSON.stringify(message));
  if (bytes.length > MAX_FRAME) throw new Error('Chat message exceeds 64 KiB');
  const count = Math.max(1, Math.ceil(bytes.length / CHUNK_BYTES));
  const frames = [];
  for (let index = 0; index < count; index += 1) {
    const slice = bytes.subarray(index * CHUNK_BYTES, Math.min(bytes.length, (index + 1) * CHUNK_BYTES));
    frames.push(JSON.stringify({
      version: 1,
      id: id,
      index: index,
      count: count,
      data: encodeBase64(slice)
    }));
  }
  return frames;
}

class MessageAssembler {
  constructor(now) {
    this.now = now || (() => Date.now());
    this.pending = new Map();
    this.completed = [];
  }

  clear() {
    this.pending.clear();
    this.completed = [];
  }

  checkExpiry() {
    const time = this.now();
    for (const entry of this.pending.values()) {
      if (time - entry.created >= FRAGMENT_ABSOLUTE_MS || time - entry.progress >= FRAGMENT_IDLE_MS) {
        this.pending.clear();
        throw new Error('Incomplete chat fragments timed out');
      }
    }
  }

  receive(text) {
    this.checkExpiry();
    if (typeof text !== 'string' || utf8Bytes(text).length >= 1024) throw new Error('Fragment exceeds limit');
    const fragment = JSON.parse(text);
    if (fragment === null || typeof fragment !== 'object' || fragment.version !== 1 || !validFragmentId(fragment.id) ||
      !Number.isInteger(fragment.count) || fragment.count < 1 || fragment.count > MAX_PARTS ||
      !Number.isInteger(fragment.index) || fragment.index < 0 || fragment.index >= fragment.count ||
      typeof fragment.data !== 'string' || fragment.data.length === 0 || fragment.data.length > 640) {
      throw new Error('Malformed chat fragment');
    }
    const bytes = decodeBase64(fragment.data);
    if (bytes === null || encodeBase64(bytes) !== fragment.data || bytes.length === 0 || bytes.length > CHUNK_BYTES) {
      throw new Error('Invalid fragment payload');
    }
    if (fragment.index < fragment.count - 1 && bytes.length !== CHUNK_BYTES) throw new Error('Invalid fragment payload');
    if (this.completed.includes(fragment.id)) return null;
    let pending = this.pending.get(fragment.id);
    if (pending === undefined) {
      if (this.pending.size >= MAX_PENDING) throw new Error('Too many incomplete chat messages');
      pending = { created: this.now(), progress: this.now(), count: fragment.count, bytes: 0, parts: new Map() };
      this.pending.set(fragment.id, pending);
    }
    if (pending.count !== fragment.count) throw new Error('Conflicting fragment count');
    const previous = pending.parts.get(fragment.index);
    if (previous !== undefined) {
      if (encodeBase64(previous) !== fragment.data) throw new Error('Conflicting duplicate fragment');
      return null;
    }
    pending.parts.set(fragment.index, bytes);
    pending.bytes += bytes.length;
    pending.progress = this.now();
    if (pending.bytes > MAX_FRAME) throw new Error('Chat message exceeds 64 KiB');
    if (pending.parts.size !== pending.count) return null;
    const joined = new Uint8Array(pending.bytes);
    let offset = 0;
    for (let index = 0; index < pending.count; index += 1) {
      const part = pending.parts.get(index);
      joined.set(part, offset);
      offset += part.length;
    }
    const decoded = bytesToUtf8(joined);
    if (decoded === null) throw new Error('Malformed chat fragment');
    const message = JSON.parse(decoded);
    this.pending.delete(fragment.id);
    this.completed.push(fragment.id);
    if (this.completed.length > 128) this.completed.shift();
    return message;
  }
}

module.exports = {
  CHUNK_BYTES,
  MAX_FRAME,
  FRAGMENT_IDLE_MS,
  FRAGMENT_ABSOLUTE_MS,
  encodeFrames,
  MessageAssembler
};
