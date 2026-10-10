'use strict';

class ComputeAdmission {
  constructor(limits) {
    const settings = limits || {};
    this.queueLimit = settings.queueLimit || 4;
    this.perClientQueue = settings.perClientQueue || 1;
    this.running = '';
    this.queue = [];
  }

  key(clientId, requestId) {
    return clientId + '\n' + requestId;
  }

  tryAcquire(clientId, requestId) {
    const key = this.key(clientId, requestId);
    if (this.running === key) return 'acquired';
    if (this.running.length === 0) {
      this.running = key;
      return 'acquired';
    }
    const queuedForClient = this.queue.filter((item) => item.clientId === clientId).length;
    if (queuedForClient >= this.perClientQueue || this.queue.length >= this.queueLimit) return 'busy';
    this.queue.push({ clientId: clientId, requestId: requestId, key: key });
    return 'queued';
  }

  release(clientId, requestId) {
    const key = this.key(clientId, requestId);
    this.queue = this.queue.filter((item) => item.key !== key);
    if (this.running !== key) return '';
    this.running = '';
    if (this.queue.length === 0) return '';
    let index = this.queue.findIndex((item) => item.clientId !== clientId);
    if (index < 0) index = 0;
    const next = this.queue.splice(index, 1)[0];
    this.running = next.key;
    return next.key;
  }

  holding() {
    return this.running;
  }
}

module.exports = { ComputeAdmission };
