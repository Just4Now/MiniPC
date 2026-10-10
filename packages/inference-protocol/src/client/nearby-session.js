'use strict';

const { PROTOCOL, INFERENCE_VERSION, supportsInferenceV2 } = require('../protocol/inference-v2');
const { encodeFrames, MessageAssembler } = require('../protocol/fragments');

const LOOP_BUNDLE = 'com.jiuwen.registrychatui';
const SERVICE = 'nearby-compute';
const MANUFACTURE_ID = 0x6e77;

class NearbySession {
  constructor(platform, options) {
    const settings = options || {};
    this.platform = platform;
    this.bundleName = settings.bundleName || LOOP_BUNDLE;
    this.service = SERVICE;
    this.manufactureId = MANUFACTURE_ID;
    this.name = settings.name || 'Loop';
    this.deviceUid = settings.deviceUid || 'loop-install';
    this.state = 'STOPPED';
    this.epoch = 0;
    this.connection = null;
    this.assembler = new MessageAssembler(settings.now);
    this.fragmentSeq = 0;
    this.linkHandler = () => {};
    this.messageHandler = () => {};
    this.inferenceV2 = false;
  }

  setLinkHandler(handler) {
    this.linkHandler = handler;
  }

  setHandler(handler) {
    this.messageHandler = handler;
  }

  start() {
    this.state = 'DISCOVERING';
    this.linkHandler({ type: 'discovering', epoch: this.epoch });
    this.platform.createDeviceManager(this.bundleName);
    this.platform.scan({
      manufactureId: this.manufactureId,
      onHit: (hit) => this.connect(hit.deviceId)
    });
  }

  stop() {
    this.drop('stopped');
    this.state = 'STOPPED';
  }

  connect(deviceId) {
    if (this.connection) return;
    this.state = 'CONNECTING';
    this.linkHandler({ type: 'connecting', epoch: this.epoch });
    const connection = this.platform.connect(deviceId, this.service);
    this.connection = connection;
    connection.onData((frame) => this.onFrame(frame));
    connection.onDisconnect(() => this.drop('disconnect'));
    this.sendWire({
      protocol: PROTOCOL,
      type: 'hello',
      peerRole: 'chat',
      name: this.name,
      deviceUid: this.deviceUid,
      inferenceVersions: [INFERENCE_VERSION]
    });
  }

  onFrame(frame) {
    let message;
    try {
      message = this.assembler.receive(frame);
    } catch (_error) {
      this.drop('bad-frame');
      return;
    }
    if (message === null) return;
    if (!this.inferenceV2) {
      if (message.type === 'prepared') return;
      if (message.type === 'hello_ack') {
        if (!supportsInferenceV2(message)) {
          this.state = 'INCOMPATIBLE';
          this.linkHandler({ type: 'incompatible', epoch: this.epoch });
          return;
        }
        this.inferenceV2 = true;
        this.epoch += 1;
        this.state = 'NEGOTIATING';
        this.linkHandler({ type: 'negotiated', epoch: this.epoch });
        return;
      }
    }
    this.messageHandler(message);
  }

  async send(message) {
    if (!this.connection || !this.inferenceV2) return false;
    if (message.type === 'request') return false;
    this.sendWire(message);
    return true;
  }

  sendWire(message) {
    this.fragmentSeq += 1;
    const frames = encodeFrames(message, 'l' + String(this.epoch) + 'm' + String(this.fragmentSeq));
    for (const frame of frames) this.connection.send(frame);
  }

  drop(reason) {
    const epoch = this.epoch;
    if (this.connection) {
      try { this.connection.close(); } catch (_error) { /* already closed */ }
    }
    this.connection = null;
    this.inferenceV2 = false;
    this.assembler.clear();
    if (this.state !== 'STOPPED') {
      this.state = 'DISCONNECTED';
      this.linkHandler({ type: 'down', epoch: epoch, reason: reason });
    }
  }
}

module.exports = { NearbySession, LOOP_BUNDLE, SERVICE, MANUFACTURE_ID };
