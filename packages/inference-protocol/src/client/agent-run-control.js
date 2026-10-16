'use strict';

const { LIMITS } = require('../protocol/inference-v2');

class AgentRunControl {
  constructor(options) {
    const settings = options || {};
    this.runGeneration = settings.runGeneration || 1;
    this.agentRunId = settings.agentRunId || 'run';
    this.deadlineMs = settings.deadlineMs || LIMITS.agentDeadlineMs;
    this.maxPromptBytes = settings.maxPromptBytes || 0;
    this.maxSteps = settings.maxSteps || LIMITS.maxAgentSteps;
    this.startedAt = settings.startedAt || 0;
    this.now = settings.now || (() => Date.now());
    this.cancelled = false;
    this.reason = '';
    this.historyTurnsOmitted = 0;
    this.checkpoints = [];
  }

  cancel(reason) {
    if (this.cancelled) return;
    this.cancelled = true;
    this.reason = reason || 'CANCELLED';
  }

  isCancelled() {
    return this.cancelled;
  }

  deadlineExceeded() {
    return this.now() - this.startedAt >= this.deadlineMs;
  }

  checkpoint(where) {
    this.checkpoints.push(where);
    if (this.cancelled) return false;
    if (this.deadlineExceeded()) {
      this.cancel('REQUEST_TIMEOUT');
      return false;
    }
    return true;
  }

  noteHistoryOmitted(count) {
    this.historyTurnsOmitted += count;
  }
}

module.exports = { AgentRunControl };
