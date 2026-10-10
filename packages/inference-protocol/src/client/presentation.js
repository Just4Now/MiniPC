'use strict';

const CONNECTION_LABELS = {
  STOPPED: '发现算力',
  DISCOVERING: '发现算力',
  CONNECTING: '正在连接',
  NEGOTIATING: '正在检查模型能力',
  READY: '就绪',
  DISCONNECTED: '尚未发现可用算力设备',
  INCOMPATIBLE: '算力端版本不支持'
};

const RUN_LABELS = {
  IDLE: '就绪',
  WAITING_FOR_COMPUTE: '排队',
  RUNNING_MODEL: '推理',
  RUNNING_TOOL: '执行工具',
  SUCCEEDED: '就绪',
  FAILED: '请求失败',
  CANCELLED: '已停止'
};

function connectionLabel(state) {
  return CONNECTION_LABELS[state] || CONNECTION_LABELS.STOPPED;
}

function runLabel(state) {
  return RUN_LABELS[state] || RUN_LABELS.IDLE;
}

module.exports = { connectionLabel, runLabel };
