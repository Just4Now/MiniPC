'use strict';

const { ComputeError } = require('../protocol/inference-v2');

class RemoteComputeModel {
  constructor(client) {
    this.client = client;
    this.lastMeta = null;
  }

  async complete(prompt, _conversation) {
    try {
      const result = await this.client.infer(prompt, this.control);
      this.lastMeta = { source: result.source, hash: result.hash };
      return result.text;
    } catch (error) {
      if (error instanceof ComputeError) throw error;
      throw new ComputeError('MODEL_EXECUTION_FAILED', error instanceof Error ? error.message : String(error), false);
    }
  }

  bind(control) {
    this.control = control;
    return this;
  }
}

function createLoopModelInfo(config, deps) {
  const settings = config || {};
  const parts = deps || {};
  if (settings.inferenceMode === 'remote_required') {
    if (!parts.remote) throw new ComputeError('NO_COMPUTE');
    if (parts.remote.state === 'INCOMPATIBLE') throw new ComputeError('PROTOCOL_UNSUPPORTED');
    if (!parts.remote.isReady()) throw new ComputeError('NO_COMPUTE');
    return {
      mode: 'remote',
      modelName: parts.remote.modelLabel(),
      model: new RemoteComputeModel(parts.remote)
    };
  }
  if (settings.useLocalLlm && parts.localBinding) {
    return { mode: 'local', modelName: 'Qwen2.5-7B-Instruct (Gewu)', model: parts.localBinding };
  }
  if (parts.providerConfigured) {
    return { mode: 'llm', modelName: parts.modelName || 'cloud', model: parts.cloudModel || null };
  }
  return { mode: 'scripted', modelName: 'scripted-local', model: parts.scriptedModel || null };
}

module.exports = { RemoteComputeModel, createLoopModelInfo };
