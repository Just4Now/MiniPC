// node ChatProtocol.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
let now = 0;
const context = { exports: {}, Uint8Array, Date: { now: () => now }, require: name => {
  assert.equal(name, '@kit.ArkTS');
  return { util: {
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: { create: (encoding, options) => ({ decodeToString: bytes => new TextDecoder(encoding, options).decode(bytes) }) },
    Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
      decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); }
    }
  } };
} };
vm.runInNewContext(transpile(__dirname + '/ChatProtocol.ets'), context);
const { encodeMessage, MessageAssembler, validMessage, MAX_IMAGE_BASE64 } = context.exports;
const request = { type: 'request', requestId: 'r', needs: [], messages: [{ role: 'user', content: '中文😀'.repeat(400) }] };
const frames = encodeMessage(request, 'message_1');
assert(frames.length > 1);
assert(frames.every(frame => Buffer.byteLength(frame) < 1024));
const assembler = new MessageAssembler();
assert.equal(assembler.receive(frames.at(-1)), null);
assert.equal(assembler.receive(frames.at(-1)), null);
let result;
for (const frame of frames.slice(0, -1).reverse()) result = assembler.receive(frame);
assert.equal(JSON.stringify(result), JSON.stringify(request));
for (const frame of frames) assert.equal(assembler.receive(frame), null);
assembler.clear();
assert.equal(assembler.receive(frames[0]), null);
const altered = JSON.parse(frames[0]);
altered.data = Buffer.alloc(480, 65).toString('base64');
assert.throws(() => assembler.receive(JSON.stringify(altered)), /Conflicting duplicate/);
const changedCount = { ...JSON.parse(frames[0]), count: frames.length + 1 };
assert.throws(() => assembler.receive(JSON.stringify(changedCount)), /Conflicting fragment count/);
assert.throws(() => assembler.receive('x'.repeat(1024)));
assert.throws(() => assembler.receive('null'));
assert.throws(() => assembler.receive('{'));
for (const patch of [{ index: -1 }, { count: 138 }, { data: '!!!!' }, { data: 'AB==' }, { id: 'bad id' }, { index: 0.5 }]) {
  assert.throws(() => new MessageAssembler().receive(JSON.stringify({ ...JSON.parse(frames[0]), ...patch })));
}
assert.throws(() => encodeMessage({ type: 'request', requestId: 'r', messages: [{ role: 'system', content: 'bad' }] }, 'a'));
assert.throws(() => encodeMessage({ type: 'delta', requestId: 'r', text: '\u0000'.repeat(16000) }, 'a'), /64 KiB/);
assert.throws(() => encodeMessage({ type: 'hello' }, 'x'.repeat(65)));
assert(!validMessage(null));
assert(!validMessage({ ...request, messages: [{ role: 'user', content: 'x'.repeat(1801) }] }));
assert(!validMessage({ ...request, messages: Array(8).fill(request.messages[0]) }));
assert(validMessage({ ...request, sched: true, origin: '聊天设备2' }));
assert(!validMessage({ ...request, sched: true, origin: 'x'.repeat(129) }));
const bounded = new MessageAssembler();
for (let i = 0; i < 8; i++) bounded.receive(encodeMessage(request, 'id' + i)[0]);
assert.throws(() => bounded.receive(encodeMessage(request, 'id8')[0]), /Too many/);
now = 15000;
assert.throws(() => bounded.receive(frames[0]), /timed out/);
assert.equal(bounded.receive(frames[0]), null);
bounded.clear();
now += 100000;
const hello = encodeMessage({ type: 'hello' }, 'hello');
assert.equal(bounded.receive(hello[0]).type, 'hello');
const malformedUtf8 = JSON.stringify({ version: 1, id: 'utf8', count: 1, index: 0, data: '/w==' });
assert.throws(() => new MessageAssembler().receive(malformedUtf8));
const invalidMessage = JSON.stringify({ version: 1, id: 'schema', count: 1, index: 0, data: Buffer.from('{}').toString('base64') });
assert.throws(() => new MessageAssembler().receive(invalidMessage), /Invalid chat message/);
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'heartbeat' }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'heartbeat_ack' }));
const expiry = new MessageAssembler();
expiry.receive(frames[0]);
now += 15000;
assert.throws(() => expiry.checkExpiry(), /timed out/);
assert.doesNotThrow(() => expiry.checkExpiry(), 'expired pending messages are cleared');
assert.equal(expiry.receive(encodeMessage({ type: 'hello' }, 'idle')[0]).type, 'hello');
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'hello' }));
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'hello', peerRole: 'chat' }));
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'hello_ack', peerRole: 'compute' }));
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'hello_ack', peerRole: 'compute', slot: 2 }));
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'hello', peerRole: 'compute', deviceUid: 'install-1234' }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'hello', deviceUid: 'x'.repeat(65) }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'hello_ack', slot: 0 }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'hello_ack', slot: 2.5 }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'deviceInfoSync', requestId: 'fractional',
  devices: [{ id: 'worker', role: 'compute', capabilities: [], slot: 2.5 }] }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'deviceInfoSync', requestId: 'bad-ready',
  devices: [{ id: 'worker', role: 'compute', capabilities: [], slot: 2, ready: 'false' }] }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'hello', peerRole: 'other' }));
now += 1000000000;
assert.doesNotThrow(() => expiry.checkExpiry(), 'completed message never creates an inference timeout');
assert.equal(expiry.receive(encodeMessage({ type: 'done', requestId: 'r' }, 'after_idle')[0]).type, 'done');
const info = {
  protocol: 'nearby-chat-v2', type: 'deviceInfo', requestId: 'info-1', name: '算力', model: 'Qwen',
  memUsage: 40, memAvail: 1000, memTotal: 2000, thermalLevel: 2, batteryTemp: 42, cpuUsage: 18,
  modelRequests: 1, capabilities: ['text', 'vision'], peerRole: 'compute'
};
assert(validMessage(info));
assert(!validMessage({ ...info, peerRole: 'other' }));
assert(!validMessage({ ...info, thermalLevel: 'hot' }));
assert(validMessage({ ...info, capabilities: [] }));
assert(!validMessage({ ...info, capabilities: undefined }), 'capabilities is required');
assert(!validMessage({ ...info, capabilities: 'vision' }));
assert(!validMessage({ ...info, capabilities: ['fly'] }));
assert(!validMessage({ ...info, capabilities: Array(9).fill('text') }));
// The compute↔compute info poll frame carries only this shape; it must stay valid
// or encodeMessage throws in LinkEnhanceChannel.write and tears the link down.
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'deviceInfo', requestId: 'info-2', capabilities: [] }));
assert.equal(new MessageAssembler().receive(encodeMessage({
  type: 'deviceInfo', requestId: 'info-1', name: '算力', model: 'Qwen', memUsage: 40,
  thermalLevel: 2, batteryTemp: 42, cpuUsage: 18, capabilities: ['text'], peerRole: 'compute'
}, 'info')[0]).batteryTemp, 42);
const sync = {
  protocol: 'nearby-chat-v2', type: 'deviceInfoSync', requestId: 'sync-1',
  devices: [{ id: 'self', name: '本机', role: 'self', model: 'Qwen', memUsage: 10, modelRequests: 0, capabilities: ['text'] }]
};
assert(validMessage(sync));
assert(validMessage({ ...sync, devices: [{ id: 'temporary-link', deviceUid: 'stable-install', role: 'compute', capabilities: [] }] }));
assert(!validMessage({ ...sync, devices: [{ id: 'temporary-link', deviceUid: 'x'.repeat(65), role: 'compute', capabilities: [] }] }));
assert(!validMessage({ ...sync, devices: [{ id: 'worker', role: 'compute' }] }), 'roster entries must declare capabilities');
assert(!validMessage({ ...sync, devices: null }));
assert(validMessage({
  protocol: 'nearby-chat-v2', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], needs: [], sched: true
}));
assert(!validMessage({
  protocol: 'nearby-chat-v2', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }], sched: 'yes'
}));
assert(!validMessage({
  protocol: 'nearby-chat-v2', type: 'request', requestId: 'r',
  messages: [{ role: 'user', content: 'hi' }]
}), 'needs is required on request');
assert(validMessage({ ...request, needs: ['vision'] }));
assert(!validMessage({ ...request, needs: ['fly'] }));
assert(!validMessage({ ...request, needs: Array(5).fill('vision') }));
// 图片：裸 base64，带图必须需要 vision，且受 MAX_IMAGE_BASE64 约束
assert(validMessage({ ...request, needs: ['vision'], image: 'QUJD' }));
assert(!validMessage({ ...request, needs: [], image: 'QUJD' }), 'an image request must need vision');
assert(!validMessage({ ...request, needs: ['vision'], image: 'data:image/jpeg;base64,QUJD' }), 'no data-url prefix');
assert(!validMessage({ ...request, needs: ['vision'], image: 'QU JD!' }), 'base64 alphabet only');
assert(!validMessage({ ...request, needs: ['vision'], image: '' }), 'empty payload rejected');
assert(!validMessage({ ...request, needs: ['vision'], image: 'A'.repeat(MAX_IMAGE_BASE64 + 1) }), 'over budget rejected');
const withImage = { ...request, needs: ['vision'], image: 'A'.repeat(20000) };
assert(validMessage(withImage));
{
  // 大图走分片装配：20000 字符 base64 拆成四十多片后必须完整还原
  const parts = encodeMessage(withImage, 'big-image');
  assert(parts.length > 40, 'a 20k-char image spans dozens of fragments');
  const assembler = new MessageAssembler();
  let decoded = null;
  for (let i = parts.length - 1; i >= 0; i--) decoded = assembler.receive(parts[i]);
  assert.equal(decoded.image, withImage.image, 'image survives out-of-order fragment assembly');
  assert.equal(decoded.needs.join(','), 'vision');
}
assert(validMessage({ protocol: 'nearby-chat-v2', type: 'done', requestId: 'r', source: '来自本机 Qwen' }));
assert(!validMessage({ protocol: 'nearby-chat-v2', type: 'done', requestId: 'r', source: 'x'.repeat(257) }));
console.log('PASS: UTF-8 roundtrip, <1KiB envelopes, out-of-order/replay, conflicting duplicates/counts, schema/base64/byte/count/pending limits, incomplete-only timeout, clear, malformed UTF-8, deviceInfo/sched/source, image payload');
for (const type of ['prepare', 'prepared']) {
  const message = { protocol: 'nearby-chat-v2', type, requestId: 'prepare-1' };
  assert(validMessage(message));
  for (const requestId of [undefined, '', 1, 'x'.repeat(129)]) {
    assert(!validMessage({ ...message, requestId }));
  }
  assert.equal(new MessageAssembler().receive(encodeMessage(message, type)[0]).type, type);
}
const prepared = { protocol: 'nearby-chat-v2', type: 'prepared', requestId: 'r' };
assert(validMessage({ ...prepared, error: 'x'.repeat(2048) }));
for (const error of [null, 1, {}, 'x'.repeat(2049)]) assert(!validMessage({ ...prepared, error }));
console.log('PASS: prepare/prepared schema and roundtrip, required bounded requestId, optional bounded error');
