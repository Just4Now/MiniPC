'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { utf8Bytes, sha256Text, cutUtf8 } = require('../src/protocol/text');
const {
  validateInferMessage,
  validateHelloExtensions,
  supportsInferenceV2,
  StreamAssembler,
  redactPrompt,
  contextAdmission,
  ComputeError,
  wireMessage
} = require('../src/protocol/inference-v2');
const { encodeFrames, MessageAssembler } = require('../src/protocol/fragments');
const { splitLoopReactPrompt } = require('../src/protocol/prompt-split');
const { AgentRunControl } = require('../src/client/agent-run-control');
const { ComputeClient } = require('../src/client/compute-client');
const { createLoopModelInfo, RemoteComputeModel } = require('../src/client/remote-compute-model');
const { runGuarded } = require('../src/client/react-guard');
const { NearbySession, LOOP_BUNDLE } = require('../src/client/nearby-session');
const { connectionLabel, runLabel } = require('../src/client/presentation');
const { createProfile } = require('../src/compute/model-profiles');
const { ComputeAdmission } = require('../src/compute/compute-admission');
const { NativeEventDispatcher } = require('../src/compute/native-event-dispatcher');
const { NativeInferenceService } = require('../src/compute/native-inference-service');
const { InferenceGateway } = require('../src/compute/inference-gateway');
const { pickInferenceNode } = require('../src/compute/pick-inference-node');
const { ManualClock } = require('./clock.cjs');

const root = path.join(__dirname, '..');
let failures = 0;

async function test(name, fn) {
  try {
    await fn();
    console.log('PASS ' + name);
  } catch (error) {
    failures += 1;
    console.error('FAIL ' + name);
    console.error(error);
  }
}

function sha(text) {
  return crypto.createHash('sha256').update(Buffer.from(utf8Bytes(text))).digest('hex');
}

function request(fields) {
  return wireMessage('infer.request', Object.assign({
    clientInstanceId: 'boot-a',
    agentRunId: 'run-a',
    requestId: 'req-a',
    modelId: 'qwen25-7b-instruct-q4',
    modelRevision: 'conservative-2048',
    promptFormat: 'loop-react-split-v1',
    prompt: 'You are Loop.\nUser task:\nhi\n',
    maxOutputTokens: 128,
    deadlineBudgetMs: 180000
  }, fields));
}

class ScriptedProbe {
  constructor(script) {
    this.script = script.slice();
    this.events = [];
    this.starts = [];
    this.cancels = [];
    this.nextId = 1;
    this.holdEnd = false;
  }

  startInference(modelPath, requestJson, logPath, maxCtx) {
    const id = this.nextId;
    this.nextId += 1;
    const item = this.script.shift();
    this.starts.push({ id: id, modelPath: modelPath, request: requestJson, logPath: logPath, maxCtx: maxCtx });
    if (item === undefined) return id;
    this.emit(id, item);
    return id;
  }

  emit(id, item) {
    const text = typeof item === 'string' ? item : item.text;
    const finish = typeof item === 'string' ? 'stop' : item.finish;
    const shape = typeof item === 'string' ? 'message' : (item.shape || 'message');
    if (text) {
      const payload = shape === 'top' ? { content: text } : { message: { content: text } };
      this.events.push(JSON.stringify({ event: 'response', id: String(id), payload: JSON.stringify(payload) }));
    }
    if (finish) {
      this.events.push(JSON.stringify({
        event: 'response',
        id: String(id),
        payload: JSON.stringify({ finish_reason: finish })
      }));
    }
    if (!this.holdEnd) this.events.push(JSON.stringify({ event: 'end', id: String(id), payload: 'closed' }));
  }

  pushEnd(id) {
    this.events.push(JSON.stringify({ event: 'end', id: String(id), payload: 'closed' }));
  }

  takeEvents() {
    const lines = this.events;
    this.events = [];
    return lines;
  }

  cancel(id) {
    this.cancels.push(id);
  }

  complete() {}
}

function attach(clock, probe, options) {
  const settings = options || {};
  const profile = createProfile(settings.profile);
  const logs = [];
  const service = new NativeInferenceService(probe, { profile: profile, logger: (entry) => logs.push(entry) });
  const mailbox = new Map();
  const gateway = new InferenceGateway({
    profile: profile,
    executor: service,
    peers: settings.peers || [],
    maxUnackedSeq: settings.maxUnackedSeq || 16,
    now: () => clock.now(),
    schedule: (fn, ms) => clock.schedule(fn, ms),
    clear: (id) => clock.clear(id),
    logger: (entry) => logs.push(entry),
    send: (epoch, message) => {
      const list = mailbox.get(epoch) || [];
      list.push(message);
      mailbox.set(epoch, list);
      if (settings.deliver) settings.deliver(epoch, message);
    }
  });
  return { profile: profile, logs: logs, service: service, gateway: gateway, mailbox: mailbox };
}

async function main() {
  await test('sha256 matches the platform hash for empty, ascii, and long text', () => {
    for (const text of ['', 'abc', '中文😀', 'x'.repeat(40000)]) {
      assert.equal(sha256Text(text), sha(text));
    }
  });

  await test('contract fixtures match the checked protocol', () => {
    const spec = JSON.parse(fs.readFileSync(path.join(root, 'contracts/compute-inference-v2/protocol.json'), 'utf8'));
    assert.equal(spec.protocol, 'nearby-chat-v1');
    assert.equal(spec.version, 2);
    const hello = JSON.parse(fs.readFileSync(path.join(root, 'contracts/compute-inference-v2/fixtures/hello-v2.json'), 'utf8'));
    const sample = JSON.parse(fs.readFileSync(path.join(root, 'contracts/compute-inference-v2/fixtures/infer-request.json'), 'utf8'));
    const sampleImage = JSON.parse(
      fs.readFileSync(path.join(root, 'contracts/compute-inference-v2/fixtures/infer-request-image.json'), 'utf8'));
    assert.equal(validateHelloExtensions(hello).ok, true);
    assert.equal(supportsInferenceV2(hello), true);
    assert.equal(validateInferMessage(sample).ok, true);
    assert.equal(validateInferMessage(sampleImage).ok, true);
    assert.equal(spec.limits.maxWireBytes, 65536);
    assert.equal(spec.limits.maxPromptBytes, 32768);
    assert.equal(spec.limits.maxImageBase64, 24000);
  });

  await test('inference messages reject bad fields and keep v1 prompts off this path', () => {
    assert.equal(validateInferMessage(null).ok, false);
    assert.equal(validateInferMessage({ protocol: 'nearby-chat-v1', type: 'request', requestId: 'r' }).ok, false);
    assert.equal(validateInferMessage(request({ requestId: '' })).ok, false);
    assert.equal(validateInferMessage(request({ requestId: 'bad id' })).ok, false);
    assert.equal(validateInferMessage(request({ maxOutputTokens: Number.NaN })).ok, false);
    assert.equal(validateInferMessage(request({ extra: true })).ok, false);
    assert.equal(validateInferMessage(request({ prompt: 'x'.repeat(32769) })).code, 'PAYLOAD_TOO_LARGE');
    // 可选附图：裸 base64，规范编码且不超限才通过。
    const IMAGE_B64 = '/9j/4AAQSkZJRg==';
    assert.equal(validateInferMessage(request({ image: IMAGE_B64 })).ok, true);
    assert.equal(validateInferMessage(request({ image: '' })).ok, false);
    assert.equal(validateInferMessage(request({ image: 12345 })).ok, false);
    assert.equal(validateInferMessage(request({ image: 'not*base64' })).ok, false);
    assert.equal(validateInferMessage(request({ image: 'data:image/jpeg;base64,' + IMAGE_B64 })).ok, false);
    assert.equal(validateInferMessage(request({ image: IMAGE_B64.slice(0, 4) + '\n' + IMAGE_B64.slice(4) })).ok, false);
    assert.equal(validateInferMessage(request({ image: 'A'.repeat(24001) })).code, 'PAYLOAD_TOO_LARGE');
    // 上限组合必须仍装得进一条报文：32768(prompt) + 24000(image) + 字段开销 ≈ 57 KB < 65536。
    // 这条断言把"带图时无需裁剪 prompt"钉住 —— 若将来调高任一上限，这里会先失败。
    assert.equal(
      validateInferMessage(request({ prompt: 'y'.repeat(32768), image: 'A'.repeat(24000) })).ok, true);
    // 不带 image 的请求保持与旧实现完全一致（纯文本路径不受影响）
    assert.equal(validateInferMessage(request({})).ok, true);
    assert.equal(validateHelloExtensions({ inferenceVersions: [2, 1.5] }).ok, false);
    assert.equal(validateHelloExtensions({}).ok, true);
    const done = wireMessage('infer.done', {
      requestId: 'req-a', lastSeq: 1, outputUtf8Bytes: 2, outputSha256: sha('OK'),
      finishReason: 'stop', source: 'model'
    });
    assert.equal(validateInferMessage(done).ok, true);
    assert.equal(validateInferMessage(Object.assign({}, done, { finishReason: 'nope' })).ok, false);
  });

  await test('stream assembly accepts duplicates and rejects gaps, conflicts, and bad hashes', () => {
    const stream = new StreamAssembler();
    assert.equal(stream.push(2, 'B').ok, true);
    assert.equal(stream.push(1, 'A').ok, true);
    assert.equal(stream.push(1, 'A').ok, true);
    assert.equal(stream.push(1, 'Z').code, 'STREAM_CORRUPTED');
    const whole = new StreamAssembler();
    whole.push(1, 'OK');
    const finished = whole.finish(1, 2, sha256Text('OK'), 'stop');
    assert.equal(finished.text, 'OK');
    const gap = new StreamAssembler();
    gap.push(1, 'A');
    assert.equal(gap.finish(2, 1, sha256Text('A'), 'stop').code, 'STREAM_CORRUPTED');
    const early = new StreamAssembler();
    assert.equal(early.finish(1, 0, sha(''), 'stop').ok, false);
    const truncated = new StreamAssembler();
    truncated.push(1, 'Action:');
    assert.equal(truncated.finish(1, 7, sha256Text('Action:'), 'length').code, 'MODEL_OUTPUT_TRUNCATED');
  });

  await test('fragments round-trip chinese, emoji, and a 32 KiB payload', () => {
    const payload = {
      protocol: 'nearby-chat-v1',
      type: 'infer.request',
      text: ('中文😀\n"\\').repeat(50) + 'Z'.repeat(32000)
    };
    const frames = encodeFrames(payload, 'payload_1');
    assert.ok(frames.length > 1);
    assert.ok(frames.every((frame) => utf8Bytes(frame).length < 1024));
    const assembler = new MessageAssembler(() => 0);
    let message = null;
    for (const frame of frames.slice().reverse()) message = assembler.receive(frame) || message;
    assert.equal(JSON.stringify(message), JSON.stringify(payload));
    assert.equal(sha256Text(JSON.stringify(message)), sha(JSON.stringify(payload)));
    const altered = JSON.parse(frames[0]);
    altered.data = encodeFrames({ protocol: 'nearby-chat-v1', type: 'hello' }, 'other_1')[0];
    const conflict = new MessageAssembler(() => 0);
    conflict.receive(frames[0]);
    assert.throws(() => conflict.receive(JSON.stringify(Object.assign(JSON.parse(frames[0]), {
      data: JSON.parse(frames[1]).data
    }))), /Conflicting duplicate/);
  });

  await test('fragment idle and absolute deadlines are separate', () => {
    let now = 0;
    const idle = new MessageAssembler(() => now);
    const frames = encodeFrames({ protocol: 'nearby-chat-v1', kind: 'x'.repeat(1200) }, 'idle_1');
    idle.receive(frames[0]);
    now = 14999;
    assert.doesNotThrow(() => idle.checkExpiry());
    now = 15000;
    assert.throws(() => idle.checkExpiry(), /timed out/);
    const absolute = new MessageAssembler(() => now);
    const many = encodeFrames({ protocol: 'nearby-chat-v1', kind: 'y'.repeat(3000) }, 'abs_1');
    now = 0;
    absolute.receive(many[0]);
    for (let index = 1; index < many.length - 1; index += 1) {
      now += 10000;
      absolute.receive(many[index]);
    }
    now += 10000;
    assert.ok(now >= 60000);
    assert.throws(() => absolute.checkExpiry(), /timed out/);
  });

  await test('prompt split follows the Loop User task marker', () => {
    const messages = splitLoopReactPrompt('rules\n\nUser task:\nsummarize\n');
    assert.equal(messages[0].role, 'developer');
    assert.equal(messages[1].role, 'user');
    assert.equal(messages[1].content, 'summarize');
    assert.equal(splitLoopReactPrompt('plain').length, 1);
  });

  await test('utf8 cuts do not split an emoji', () => {
    const cut = cutUtf8('a'.repeat(1023) + '😀', 1024);
    assert.equal(cut.bytes <= 1024, true);
    assert.equal(cut.text.includes('😀'), false);
    const fitted = cutUtf8('a'.repeat(1020) + '😀', 1024);
    assert.equal(fitted.text.endsWith('😀'), true);
  });

  await test('nearby session uses the shared bundle and does not treat prepared as ready', async () => {
    const frames = [];
    let connection = null;
    const bundles = [];
    const platform = {
      createDeviceManager(bundle) { bundles.push(bundle); },
      scan(options) { options.onHit({ deviceId: 'compute-phone' }); },
      connect(deviceId, service) {
        assert.equal(deviceId, 'compute-phone');
        assert.equal(service, 'nearby-compute');
        connection = {
          send(frame) { frames.push(frame); },
          onData(fn) { connection.deliver = fn; },
          onDisconnect(fn) { connection.disconnect = fn; },
          close() {}
        };
        return connection;
      }
    };
    const events = [];
    const session = new NearbySession(platform);
    session.setLinkHandler((event) => events.push(event.type));
    session.start();
    assert.deepEqual(bundles, ['com.jiuwen.registrychatui']);
    assert.equal(session.bundleName, LOOP_BUNDLE);
    const helloAssembler = new MessageAssembler(() => 0);
    let hello = null;
    for (const frame of frames) hello = helloAssembler.receive(frame) || hello;
    assert.equal(hello.peerRole, 'chat');
    assert.deepEqual(hello.inferenceVersions, [2]);
    for (const frame of encodeFrames({
      protocol: 'nearby-chat-v1', type: 'prepared', requestId: 'prep'
    }, 'prepared1')) connection.deliver(frame);
    assert.equal(events.includes('negotiated'), false);
    for (const frame of encodeFrames({
      protocol: 'nearby-chat-v1', type: 'hello_ack', peerRole: 'compute', inferenceVersions: [2]
    }, 'ack_1')) connection.deliver(frame);
    assert.equal(events.at(-1), 'negotiated');
    const body = '中文😀' + 'Q'.repeat(32000);
    frames.length = 0;
    assert.equal(await session.send({ protocol: 'nearby-chat-v1', type: 'infer.request', prompt: body }), true);
    assert.equal(await session.send({ type: 'request', requestId: 'old' }), false);
    const back = new MessageAssembler(() => 0);
    let echoed = null;
    for (const frame of frames) echoed = back.receive(frame) || echoed;
    assert.equal(sha256Text(echoed.prompt), sha(body));
  });

  await test('remote mode never falls back to cloud or scripted models', () => {
    assert.throws(() => createLoopModelInfo({
      inferenceMode: 'remote_required',
      useLocalLlm: true
    }, { providerConfigured: true, localBinding: {}, scriptedModel: { scripted: true } }), (error) => {
      assert.equal(error instanceof ComputeError, true);
      assert.equal(error.code, 'NO_COMPUTE');
      assert.equal(error.fallbackForbidden, true);
      return true;
    });
    const incompatible = { state: 'INCOMPATIBLE', isReady: () => false };
    assert.throws(() => createLoopModelInfo({ inferenceMode: 'remote_required' }, { remote: incompatible }), (error) => {
      assert.equal(error.code, 'PROTOCOL_UNSUPPORTED');
      return true;
    });
    assert.equal(createLoopModelInfo({ useLocalLlm: false }, { providerConfigured: false }).mode, 'scripted');
    assert.equal(connectionLabel('NEGOTIATING'), '正在检查模型能力');
    assert.equal(connectionLabel('INCOMPATIBLE'), '算力端版本不支持');
    assert.equal(runLabel('RUNNING_TOOL'), '执行工具');
  });

  await test('client resolves only a complete hashed stream and does not retry', async () => {
    const clock = new ManualClock();
    const seen = [];
    let deliver = () => {};
    const transport = {
      setHandler(fn) { deliver = fn; },
      setLinkHandler(fn) { this.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        seen.push(message);
        if (message.type === 'infer.capabilities.get') {
          deliver(wireMessage('infer.capabilities', {
            requestId: message.requestId,
            profiles: [createProfile()]
          }));
        }
        if (message.type === 'infer.request') {
          deliver(wireMessage('infer.accepted', { requestId: message.requestId, state: 'preparing' }));
          deliver(wireMessage('infer.delta', { requestId: message.requestId, seq: 1, text: 'O' }));
          deliver(wireMessage('infer.delta', { requestId: message.requestId, seq: 1, text: 'O' }));
          deliver(wireMessage('infer.delta', { requestId: message.requestId, seq: 2, text: 'K' }));
          deliver(wireMessage('infer.done', {
            requestId: message.requestId,
            lastSeq: 2,
            outputUtf8Bytes: 2,
            outputSha256: sha256Text('OK'),
            finishReason: 'stop',
            source: 'qwen25-7b-instruct-q4'
          }));
        }
        return true;
      }
    };
    const client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id),
      clientInstanceId: 'boot-a'
    });
    transport.link({ type: 'negotiated', epoch: 3 });
    const model = new RemoteComputeModel(client);
    const text = await model.complete('请只回复 OK', { content: 'DO-NOT-SEND' });
    assert.equal(text, 'OK');
    assert.equal(model.lastMeta.source, 'qwen25-7b-instruct-q4');
    assert.equal(text.includes('算力'), false);
    const sent = seen.find((message) => message.type === 'infer.request');
    assert.equal(sent.prompt, '请只回复 OK');
    assert.equal(JSON.stringify(sent).includes('DO-NOT-SEND'), false);
    assert.equal(seen.filter((message) => message.type === 'infer.request').length, 1);
  });

  await test('secrets in the prompt are redacted before they leave the phone', async () => {
    const seen = [];
    const transport = {
      setHandler(fn) { this.handler = fn; },
      setLinkHandler(fn) { this.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        seen.push(message);
        if (message.type === 'infer.capabilities.get') {
          this.handler(wireMessage('infer.capabilities', { requestId: message.requestId, profiles: [createProfile()] }));
        }
        return true;
      }
    };
    const client = new ComputeClient(transport, { clientInstanceId: 'boot-a' });
    transport.link({ type: 'negotiated', epoch: 1 });
    const prompt = 'Authorization: Bearer secret\n"apiKey":"abc"\nsk-supersecretkey\nUser task:\nhi';
    const pending = client.infer(prompt);
    const sent = seen.find((message) => message.type === 'infer.request');
    assert.equal(sent.prompt.includes('supersecretkey'), false);
    assert.equal(sent.prompt.includes('Bearer secret'), false);
    assert.equal(redactPrompt(prompt).includes('sk-***'), true);
    client.cancelAll('CANCELLED');
    await assert.rejects(pending, (error) => error.code === 'CANCELLED');
  });

  await test('hard inference deadline is not extended by status heartbeats', async () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe([]);
    probe.holdEnd = true;
    let client;
    const stack = attach(clock, probe, {
      deliver: (_epoch, message) => client.onMessage(message)
    });
    const transport = {
      setHandler() {},
      setLinkHandler(fn) { transport.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        stack.gateway.handle(message, { epoch: 1, role: 'chat', inferenceV2: true });
        return true;
      }
    };
    client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id),
      clientInstanceId: 'boot-a'
    });
    transport.link({ type: 'negotiated', epoch: 4 });
    const pending = client.infer('请只回复 OK');
    clock.advance(179000);
    assert.equal(probe.starts.length, 1);
    clock.advance(1000);
    await assert.rejects(pending, (error) => error.code === 'REQUEST_TIMEOUT');
    assert.equal(probe.starts.length, 1);
  });

  await test('tool loop stays on the phone and a later disconnect does not repeat a write', async () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe([
      'Action: write_sandbox_file[{"path":"out.txt","content":"v1"}]',
      'Final: done'
    ]);
    const logs = [];
    let client;
    let phase = 0;
    const stack = attach(clock, probe, {
      deliver: (_epoch, message) => client.onMessage(message)
    });
    stack.logs = logs;
    const transport = {
      setHandler() {},
      setLinkHandler(fn) { transport.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        if (message.type === 'infer.request') phase += 1;
        if (phase === 2) {
          client.onLink({ type: 'down', epoch: client.connectionEpoch });
          return false;
        }
        stack.gateway.handle(message, { epoch: 1, role: 'chat', inferenceV2: true });
        return true;
      }
    };
    client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id),
      clientInstanceId: 'boot-a'
    });
    transport.link({ type: 'negotiated', epoch: 9 });
    const calls = [];
    const control = new AgentRunControl({
      agentRunId: 'run-tools',
      now: () => clock.now(),
      maxPromptBytes: 100000,
      startedAt: 0
    });
    const model = new RemoteComputeModel(client).bind(control);
    const result = await runGuarded({
      model: model,
      control: control,
      task: '写入然后总结',
      skillsText: 'SKILL-TOKEN',
      tools: async (name) => {
        calls.push(name);
        return 'wrote out.txt';
      }
    });
    assert.equal(result.status, 'failed');
    assert.deepEqual(calls, ['write_sandbox_file']);
    assert.equal(probe.starts.length, 1);
    const native = JSON.parse(probe.starts[0].request);
    assert.equal(native.messages[0].role, 'developer');
    assert.equal(native.messages[0].content.includes('SKILL-TOKEN'), true);
    assert.equal(native.messages[0].content.split('SKILL-TOKEN').length, 2);
    assert.equal(native.max_tokens <= 512, true);
    assert.equal(probe.starts[0].maxCtx, 2048);
    assert.equal(JSON.stringify(logs).includes('写入然后总结'), false);
    assert.equal(JSON.stringify(logs).includes('SKILL-TOKEN'), false);
  });

  await test('truncated and cancelled model output does not run tools', async () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe([{ text: 'Action: list_sandbox_files[{', finish: 'length' }]);
    let client;
    const stack = attach(clock, probe, { deliver: (_epoch, message) => client.onMessage(message) });
    const transport = {
      setHandler() {},
      setLinkHandler(fn) { transport.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        stack.gateway.handle(message, { epoch: 1, role: 'chat', inferenceV2: true });
        return true;
      }
    };
    client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id)
    });
    transport.link({ type: 'negotiated', epoch: 2 });
    const calls = [];
    const control = new AgentRunControl({ now: () => clock.now(), startedAt: 0, maxPromptBytes: 100000 });
    const result = await runGuarded({
      model: new RemoteComputeModel(client).bind(control),
      control: control,
      task: '列出文件',
      tools: async (name) => { calls.push(name); return 'nope'; }
    });
    assert.equal(result.status, 'failed');
    assert.equal(result.error.code, 'MODEL_OUTPUT_TRUNCATED');
    assert.deepEqual(calls, []);
  });

  await test('cancel after the model returns and before the tool skips the tool', async () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe(['Action: list_sandbox_files[{}]']);
    let client;
    const stack = attach(clock, probe, { deliver: (_epoch, message) => client.onMessage(message) });
    const transport = {
      setHandler() {},
      setLinkHandler(fn) { transport.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        stack.gateway.handle(message, { epoch: 1, role: 'chat', inferenceV2: true });
        return true;
      }
    };
    client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id)
    });
    transport.link({ type: 'negotiated', epoch: 2 });
    const control = new AgentRunControl({ now: () => clock.now(), startedAt: 0, maxPromptBytes: 100000 });
    const model = new RemoteComputeModel(client).bind(control);
    const inner = model.complete.bind(model);
    model.complete = async (prompt) => {
      const text = await inner(prompt);
      control.cancel('CANCELLED');
      return text;
    };
    const calls = [];
    const result = await runGuarded({
      model: model,
      control: control,
      task: '列出文件',
      tools: async (name) => { calls.push(name); return 'a.txt'; }
    });
    assert.equal(result.status, 'cancelled');
    assert.deepEqual(calls, []);
  });

  await test('history trims oldest turns and keeps the tool rules', async () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe(['Final: 好']);
    let client;
    const stack = attach(clock, probe, { deliver: (_epoch, message) => client.onMessage(message) });
    const transport = {
      setHandler() {},
      setLinkHandler(fn) { transport.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        stack.gateway.handle(message, { epoch: 1, role: 'chat', inferenceV2: true });
        return true;
      }
    };
    client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id)
    });
    transport.link({ type: 'negotiated', epoch: 2 });
    const history = [];
    for (let index = 0; index < 6; index += 1) {
      history.push({ role: 'user', content: '旧问题' + index + 'x'.repeat(80) });
      history.push({ role: 'assistant', content: '旧回答' + index + 'y'.repeat(80) });
    }
    const control = new AgentRunControl({ now: () => clock.now(), startedAt: 0, maxPromptBytes: 700 });
    const result = await runGuarded({
      model: new RemoteComputeModel(client).bind(control),
      control: control,
      task: '当前问题',
      history: history,
      tools: async () => 'unused'
    });
    assert.equal(result.status, 'succeeded');
    assert.equal(result.finalText, '好');
    assert.ok(result.historyTurnsOmitted > 0);
    const prompt = JSON.parse(probe.starts[0].request).messages.map((item) => item.content).join('\n');
    assert.equal(prompt.includes('Use only listed tools'), true);
    assert.equal(prompt.includes('当前问题'), true);
    assert.equal(prompt.includes('旧问题0'), false);
  });

  await test('one dispatcher feeds local and remote jobs without stealing events', () => {
    const lines = [];
    const dispatcher = new NativeEventDispatcher(() => lines.splice(0, lines.length));
    const seen = { a: 0, b: [] };
    lines.push(JSON.stringify({ event: 'response', id: '2', payload: 'early' }));
    dispatcher.poll();
    dispatcher.subscribe(1, () => { seen.a += 1; });
    dispatcher.subscribe(2, (event) => { seen.b.push(event.payload); });
    lines.push(JSON.stringify({ event: 'response', id: '1', payload: 'late' }));
    lines.push(JSON.stringify({ event: 'response', id: '2', payload: 'next' }));
    dispatcher.poll();
    assert.equal(seen.a, 1);
    assert.deepEqual(seen.b, ['early', 'next']);
  });

  await test('admission is one slot, fair across clients, and shared', () => {
    const admission = new ComputeAdmission();
    assert.equal(admission.tryAcquire('a', '1'), 'acquired');
    assert.equal(admission.tryAcquire('a', '2'), 'queued');
    assert.equal(admission.tryAcquire('b', '1'), 'queued');
    assert.equal(admission.tryAcquire('a', '3'), 'busy');
    assert.equal(admission.release('a', '1'), 'b\n1');
    assert.equal(admission.release('b', '1'), 'a\n2');
  });

  await test('gateway isolates clients that reuse a request id and rejects forged sched', () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe(['from-a', 'from-b']);
    const stack = attach(clock, probe);
    const chat = { role: 'chat', inferenceV2: true };
    stack.gateway.handle(request({ clientInstanceId: 'client-a', requestId: 'same', prompt: 'alpha' }), Object.assign({ epoch: 1 }, chat));
    stack.gateway.handle(request({ clientInstanceId: 'client-b', requestId: 'same', prompt: 'beta' }), Object.assign({ epoch: 2 }, chat));
    assert.equal(stack.mailbox.get(1).some((message) => message.type === 'infer.done' && message.text === undefined), true);
    const doneA = stack.mailbox.get(1).find((message) => message.type === 'infer.done');
    const doneB = stack.mailbox.get(2).find((message) => message.type === 'infer.done');
    assert.equal(doneA.outputSha256, sha256Text('from-a'));
    assert.equal(doneB.outputSha256, sha256Text('from-b'));
    assert.equal(probe.starts.length, 2);
    stack.gateway.handle(request({ sched: true, requestId: 'forged' }), Object.assign({ epoch: 3 }, chat));
    assert.equal(stack.mailbox.get(3)[0].code, 'REJECTED');
    assert.equal(probe.starts.length, 2);
  });

  await test('cancel tombstone prevents a late request, and cleanup timeout isolates the node', () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe([]);
    probe.holdEnd = true;
    const stack = attach(clock, probe);
    const ingress = { epoch: 5, role: 'chat', inferenceV2: true };
    stack.gateway.handle(wireMessage('infer.cancel', { requestId: 'late' }), ingress);
    stack.gateway.handle(request({ requestId: 'late', clientInstanceId: 'boot-a' }), ingress);
    assert.equal(probe.starts.length, 0);
    assert.equal(stack.mailbox.get(5).some((message) => message.code === 'CANCELLED'), true);
    stack.gateway.handle(request({ requestId: 'live', prompt: 'hold' }), ingress);
    assert.equal(probe.starts.length, 1);
    stack.gateway.handle(wireMessage('infer.cancel', { requestId: 'live' }), ingress);
    assert.equal(probe.cancels.length, 1);
    assert.equal(stack.gateway.isolated, false);
    clock.advance(10000);
    assert.equal(stack.gateway.isolated, true);
    stack.gateway.handle(request({ requestId: 'next' }), ingress);
    assert.equal(stack.mailbox.get(5).at(-1).code, 'MODEL_UNAVAILABLE');
    assert.equal(probe.starts.length, 1);
  });

  await test('full backpressure cancels instead of returning a partial success', () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe(['A'.repeat(2500)]);
    const stack = attach(clock, probe, { maxUnackedSeq: 1 });
    stack.gateway.handle(request({ prompt: 'long' }), { epoch: 1, role: 'chat', inferenceV2: true });
    const messages = stack.mailbox.get(1);
    assert.equal(messages.some((message) => message.type === 'infer.done'), false);
    assert.equal(messages.some((message) => message.code === 'BACKPRESSURE_OVERFLOW'), true);
    assert.equal(probe.cancels.length, 1);
  });

  await test('context and payload failures never start the native session', () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe(['OK']);
    const stack = attach(clock, probe);
    const profile = createProfile();
    assert.equal(contextAdmission(profile, 'x'.repeat(2000), 512).code, 'CONTEXT_TOO_LARGE');
    stack.gateway.handle(request({ prompt: 'x'.repeat(2000), maxOutputTokens: 512 }), { epoch: 1, role: 'chat', inferenceV2: true });
    stack.gateway.handle(request({ requestId: 'big', prompt: 'y'.repeat(40000) }), { epoch: 1, role: 'chat', inferenceV2: true });
    assert.equal(probe.starts.length, 0);
    assert.equal(stack.mailbox.get(1).some((message) => message.code === 'CONTEXT_TOO_LARGE'), true);
    assert.equal(stack.mailbox.get(1).some((message) => message.code === 'PAYLOAD_TOO_LARGE'), true);
  });

  await test('worker hash is forwarded unchanged and an old node is not selected', () => {
    const workerProbe = new ScriptedProbe(['worker-ok']);
    const profile = createProfile();
    const workerService = new NativeInferenceService(workerProbe, { profile: profile, logger: () => {} });
    const hubMessages = [];
    let workerGateway = null;
    const peer = {
      connected: true,
      isolated: false,
      inferenceV2: true,
      ready: true,
      freeSlot: true,
      isSelf: false,
      promptFormat: 'loop-react-split-v1',
      modelId: 'qwen25-7b-instruct-q4',
      modelRevision: 'conservative-2048',
      maxContextTokens: 2048,
      maxOutputTokens: 512,
      load: 0,
      memAvail: 1000,
      epoch: 8,
      name: 'compute-2'
    };
    const hub = new InferenceGateway({
      profile: profile,
      executor: { submit() { throw new Error('hub must not execute'); }, cancel() {} },
      peers: [peer],
      now: () => 0,
      schedule: () => 0,
      clear: () => {},
      send: (epoch, message) => {
        if (epoch === 8) {
          workerGateway.handle(message, { epoch: 4, role: 'compute', inferenceV2: true });
          return;
        }
        hubMessages.push(message);
      }
    });
    workerGateway = new InferenceGateway({
      profile: profile,
      executor: workerService,
      now: () => 0,
      schedule: () => 0,
      clear: () => {},
      send: (_epoch, message) => hub.handle(message, { epoch: 8, role: 'compute', inferenceV2: true })
    });
    hub.handle(request({ prompt: 'ping' }), { epoch: 3, role: 'chat', inferenceV2: true });
    const done = hubMessages.find((message) => message.type === 'infer.done');
    assert.equal(done.outputSha256, sha256Text('worker-ok'));
    assert.equal(done.requestId, 'req-a');
    assert.equal(workerProbe.starts.length, 1);
    const skipped = pickInferenceNode([{
      connected: true, isolated: false, inferenceV2: false, ready: true, freeSlot: true,
      promptFormat: 'loop-react-split-v1', modelId: 'qwen25-7b-instruct-q4', modelRevision: 'conservative-2048',
      maxContextTokens: 2048, maxOutputTokens: 512, load: 0, memAvail: 9
    }], {
      promptFormat: 'loop-react-split-v1', modelId: 'qwen25-7b-instruct-q4', modelRevision: 'conservative-2048',
      contextTokens: 100, maxOutputTokens: 128
    });
    assert.equal(skipped, null);
  });

  await test('top-level native content is accepted and unknown payloads fail closed', () => {
    const probe = new ScriptedProbe([
      { text: 'OK', finish: 'stop', shape: 'top' },
      { text: '', finish: '', shape: 'bad' }
    ]);
    const profile = createProfile();
    const service = new NativeInferenceService(probe, { profile: profile, logger: () => {} });
    let first = null;
    service.submit({
      forwardId: 'job-1', prompt: 'You are Loop.\nUser task:\nhi\n', maxOutputTokens: 64, maxCtx: 2048
    }, {
      onDelta: () => true,
      onCleaned: (kind) => { first = kind; }
    });
    assert.equal(first, 'done');
    probe.events = [];
    probe.script = [];
    const id = probe.startInference(profile.modelId, '{}', 'log', 2048);
    probe.events = [JSON.stringify({ event: 'response', id: String(id), payload: JSON.stringify({ foo: 1 }) })];
    probe.events.push(JSON.stringify({ event: 'end', id: String(id), payload: 'closed' }));
    let second = null;
    const unknown = {
      forwardId: 'job-2',
      nativeId: id,
      pending: '',
      failed: '',
      cancelled: false,
      cleaned: false,
      finishReason: '',
      callbacks: { onDelta: () => true, onCleaned: (kind, code) => { second = code || kind; } }
    };
    service.dispatcher.subscribe(id, (event) => service.onEvent(unknown, event));
    service.dispatcher.poll();
    assert.equal(second, 'MODEL_EXECUTION_FAILED');
  });

  await test('list read summarize closes the loop without a second native session per tool', async () => {
    const clock = new ManualClock();
    const probe = new ScriptedProbe([
      'Action: list_sandbox_files[{}]',
      'Action: read_sandbox_file[{"path":"note.txt"}]',
      'Final: 文章讲的是测试。'
    ]);
    let client;
    const stack = attach(clock, probe, { deliver: (_epoch, message) => client.onMessage(message) });
    const transport = {
      setHandler() {},
      setLinkHandler(fn) { transport.link = fn; },
      start() {},
      stop() {},
      async send(message) {
        stack.gateway.handle(message, { epoch: 1, role: 'chat', inferenceV2: true });
        return true;
      }
    };
    client = new ComputeClient(transport, {
      now: () => clock.now(),
      schedule: (fn, ms) => clock.schedule(fn, ms),
      clear: (id) => clock.clear(id)
    });
    transport.link({ type: 'negotiated', epoch: 6 });
    const calls = [];
    const control = new AgentRunControl({ now: () => clock.now(), startedAt: 0, maxPromptBytes: 100000, agentRunId: 'run-article' });
    const result = await runGuarded({
      model: new RemoteComputeModel(client).bind(control),
      control: control,
      task: '总结文章',
      tools: async (name, input) => {
        calls.push(name + input);
        if (name === 'list_sandbox_files') return 'note.txt';
        return '这是一篇测试文章，数字是 3。';
      }
    });
    assert.equal(result.status, 'succeeded');
    assert.equal(result.finalText, '文章讲的是测试。');
    assert.equal(calls.length, 2);
    assert.equal(probe.starts.length, 3);
    const second = JSON.parse(probe.starts[1].request).messages.map((item) => item.content).join('\n');
    assert.equal(second.includes('note.txt'), true);
    assert.equal(second.includes('总结文章'), true);
    for (let round = 0; round < 20; round += 1) {
      probe.script.push('Final: ' + round);
      const again = await client.infer('round ' + round);
      assert.equal(again.text, 'Final: ' + round);
    }
  });

  if (failures > 0) {
    console.error(failures + ' failed');
    process.exit(1);
  }
  console.log('All packages/inference-protocol tests passed');
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
