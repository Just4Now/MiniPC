#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const EXPECTED_SHA256 = '8f9bbb2b3d11b1cd1a79cfaf87f2086b41d276a7b089e88effba95159096825c';
// .text is loaded 0x1000 bytes above its file offset in this exact vendor build.
const SOCKET_PATCH_VIRTUAL_ADDRESS = 0xe28c;
const SOCKET_PATCH_OFFSET = SOCKET_PATCH_VIRTUAL_ADDRESS - 0x1000;
const EXPECTED_BYTES = Buffer.from([
  0x40, 0x00, 0x80, 0x52, // mov w0, #2   (AF_INET)
  0x41, 0x00, 0x80, 0x52, // mov w1, #2   (SOCK_DGRAM used by private MTP)
  0x02, 0x19, 0x80, 0x52, // mov w2, #200 (private MTP protocol)
]);
const TCP_FALLBACK_BYTES = Buffer.from([
  0x40, 0x00, 0x80, 0x52, // mov w0, #2 (AF_INET)
  0x21, 0x00, 0x80, 0x52, // mov w1, #1 (SOCK_STREAM)
  0x02, 0x00, 0x80, 0x52, // mov w2, #0 (default TCP protocol)
]);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  console.error('Usage: patch-tongtu-tcp-fallback.mjs <original.so> <patched.so>');
  process.exit(2);
}

const original = readFileSync(inputPath);
const originalHash = sha256(original);
if (originalHash !== EXPECTED_SHA256) {
  throw new Error(`Unsupported libtongtu_parallel.so SHA-256: ${originalHash}`);
}

const actualBytes = original.subarray(
  SOCKET_PATCH_OFFSET,
  SOCKET_PATCH_OFFSET + EXPECTED_BYTES.length,
);
if (!actualBytes.equals(EXPECTED_BYTES)) {
  throw new Error(`Unexpected socket setup bytes at file offset 0x${SOCKET_PATCH_OFFSET.toString(16)}`);
}

const patched = Buffer.from(original);
TCP_FALLBACK_BYTES.copy(patched, SOCKET_PATCH_OFFSET);
writeFileSync(outputPath, patched);

console.log(`input_sha256=${originalHash}`);
console.log(`output_sha256=${sha256(patched)}`);
console.log(`patched_virtual_address=0x${SOCKET_PATCH_VIRTUAL_ADDRESS.toString(16)}`);
console.log(`patched_file_offset=0x${SOCKET_PATCH_OFFSET.toString(16)}`);
console.log('transport=AF_INET/SOCK_STREAM/IPPROTO_DEFAULT');
