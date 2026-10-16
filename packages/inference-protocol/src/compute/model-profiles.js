'use strict';

const CTX_TIERS = [2048, 4096, 8192];

function createProfile(options) {
  const settings = options || {};
  const filesReady = settings.filesReady !== false;
  return {
    modelId: 'qwen25-7b-instruct-q4',
    modelRevision: 'conservative-2048',
    promptFormat: 'loop-react-split-v1',
    maxContextTokens: 2048,
    maxOutputTokens: 512,
    maxPromptBytes: 32768,
    maxWireBytes: 65536,
    tokenBudgetMode: 'certified-conservative',
    streaming: true,
    cancellation: true,
    ready: filesReady,
    readinessReason: filesReady ? '上下文按 2048 保守估算，Gate B 尚未认证' : '模型文件缺失或无法读取',
    maxCtx: 2048,
    gateBPassed: false
  };
}

function ctxAllowed(maxCtx, profile) {
  return CTX_TIERS.includes(maxCtx) && maxCtx <= profile.maxCtx;
}

module.exports = { CTX_TIERS, createProfile, ctxAllowed };
