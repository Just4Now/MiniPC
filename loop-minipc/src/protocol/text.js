'use strict';

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]);

function rotr(value, bits) {
  return (value >>> bits) | (value << (32 - bits));
}

function utf8Bytes(text) {
  const bytes = [];
  for (let index = 0; index < text.length; index += 1) {
    let code = text.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code & 0x3ff) << 10) + (next & 0x3ff);
        index += 1;
        bytes.push(
          0xf0 | (code >>> 18),
          0x80 | ((code >>> 12) & 0x3f),
          0x80 | ((code >>> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
        continue;
      }
    }
    if (code < 0x80) bytes.push(code);
    else if (code < 0x800) bytes.push(0xc0 | (code >>> 6), 0x80 | (code & 0x3f));
    else bytes.push(0xe0 | (code >>> 12), 0x80 | ((code >>> 6) & 0x3f), 0x80 | (code & 0x3f));
  }
  return Uint8Array.from(bytes);
}

function utf8ByteLength(text) {
  return utf8Bytes(text).length;
}

function sha256(bytes) {
  const bitLength = bytes.length * 8;
  const withPad = bytes.length + 1 + 8;
  const blocks = Math.ceil(withPad / 64);
  const data = new Uint8Array(blocks * 64);
  data.set(bytes);
  data[bytes.length] = 0x80;
  const view = new DataView(data.buffer);
  view.setUint32(data.length - 4, bitLength >>> 0);
  const hash = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ]);
  const words = new Uint32Array(64);
  for (let block = 0; block < data.length; block += 64) {
    for (let word = 0; word < 16; word += 1) words[word] = view.getUint32(block + word * 4);
    for (let word = 16; word < 64; word += 1) {
      const s0 = rotr(words[word - 15], 7) ^ rotr(words[word - 15], 18) ^ (words[word - 15] >>> 3);
      const s1 = rotr(words[word - 2], 17) ^ rotr(words[word - 2], 19) ^ (words[word - 2] >>> 10);
      words[word] = (words[word - 16] + s0 + words[word - 7] + s1) >>> 0;
    }
    let a = hash[0];
    let b = hash[1];
    let c = hash[2];
    let d = hash[3];
    let e = hash[4];
    let f = hash[5];
    let g = hash[6];
    let h = hash[7];
    for (let word = 0; word < 64; word += 1) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + s1 + ch + SHA256_K[word] + words[word]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + maj) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }
    hash[0] = (hash[0] + a) >>> 0;
    hash[1] = (hash[1] + b) >>> 0;
    hash[2] = (hash[2] + c) >>> 0;
    hash[3] = (hash[3] + d) >>> 0;
    hash[4] = (hash[4] + e) >>> 0;
    hash[5] = (hash[5] + f) >>> 0;
    hash[6] = (hash[6] + g) >>> 0;
    hash[7] = (hash[7] + h) >>> 0;
  }
  let hex = '';
  for (let index = 0; index < hash.length; index += 1) hex += hash[index].toString(16).padStart(8, '0');
  return hex;
}

function sha256Text(text) {
  return sha256(utf8Bytes(text));
}

function cutUtf8(text, maxBytes) {
  let used = 0;
  let end = 0;
  while (end < text.length) {
    const unit = text.charCodeAt(end);
    let size = 1;
    let step = 1;
    if (unit < 0x80) size = 1;
    else if (unit < 0x800) size = 2;
    else if (unit >= 0xd800 && unit <= 0xdbff) {
      size = 4;
      step = 2;
    } else size = 3;
    if (used + size > maxBytes) break;
    used += size;
    end += step;
  }
  return { text: text.slice(0, end), bytes: used };
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function encodeBase64(bytes) {
  let out = '';
  for (let index = 0; index < bytes.length; index += 3) {
    const a = bytes[index];
    const b = index + 1 < bytes.length ? bytes[index + 1] : 0;
    const c = index + 2 < bytes.length ? bytes[index + 2] : 0;
    const triple = (a << 16) | (b << 8) | c;
    out += B64[(triple >>> 18) & 63];
    out += B64[(triple >>> 12) & 63];
    out += index + 1 < bytes.length ? B64[(triple >>> 6) & 63] : '=';
    out += index + 2 < bytes.length ? B64[triple & 63] : '=';
  }
  return out;
}

function decodeBase64(text) {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) return null;
  const bytes = [];
  for (let index = 0; index < text.length; index += 4) {
    const a = B64.indexOf(text[index]);
    const b = B64.indexOf(text[index + 1]);
    const c = text[index + 2] === '=' ? -1 : B64.indexOf(text[index + 2]);
    const d = text[index + 3] === '=' ? -1 : B64.indexOf(text[index + 3]);
    if (a < 0 || b < 0 || c === -2 || d === -2) return null;
    bytes.push((a << 2) | (b >>> 4));
    if (c >= 0) bytes.push(((b & 15) << 4) | (c >>> 2));
    if (d >= 0) bytes.push(((c & 3) << 6) | d);
  }
  return Uint8Array.from(bytes);
}

function bytesToUtf8(bytes) {
  let out = '';
  for (let index = 0; index < bytes.length; index += 1) {
    const byte = bytes[index];
    if (byte < 0x80) out += String.fromCharCode(byte);
    else if ((byte & 0xe0) === 0xc0 && index + 1 < bytes.length) {
      out += String.fromCharCode(((byte & 0x1f) << 6) | (bytes[index + 1] & 0x3f));
      index += 1;
    } else if ((byte & 0xf0) === 0xe0 && index + 2 < bytes.length) {
      out += String.fromCharCode(((byte & 0x0f) << 12) | ((bytes[index + 1] & 0x3f) << 6) | (bytes[index + 2] & 0x3f));
      index += 2;
    } else if ((byte & 0xf8) === 0xf0 && index + 3 < bytes.length) {
      const code = ((byte & 0x07) << 18) | ((bytes[index + 1] & 0x3f) << 12) |
        ((bytes[index + 2] & 0x3f) << 6) | (bytes[index + 3] & 0x3f);
      const shifted = code - 0x10000;
      out += String.fromCharCode(0xd800 + (shifted >>> 10), 0xdc00 + (shifted & 0x3ff));
      index += 3;
    } else return null;
  }
  return out;
}

module.exports = {
  utf8Bytes,
  utf8ByteLength,
  sha256,
  sha256Text,
  cutUtf8,
  encodeBase64,
  decodeBase64,
  bytesToUtf8
};
