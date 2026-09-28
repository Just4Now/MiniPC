'use strict';

const { ComputeError, userText } = require('./protocol/inference-v2');
const { RemoteComputeModel, createLoopModelInfo } = require('./loop/remote-compute-model');
const { ComputeClient } = require('./loop/compute-client');
const { AgentRunControl } = require('./loop/agent-run-control');
const { NearbySession, LOOP_BUNDLE, SERVICE, MANUFACTURE_ID } = require('./loop/nearby-session');
const { connectionLabel, runLabel } = require('./loop/presentation');
const { createProfile } = require('./minipc/model-profiles');
const { ComputeAdmission } = require('./minipc/compute-admission');
const { NativeInferenceService } = require('./minipc/native-inference-service');
const { InferenceGateway } = require('./minipc/inference-gateway');
const { pickInferenceNode } = require('./minipc/pick-inference-node');

module.exports = {
  ComputeError,
  userText,
  RemoteComputeModel,
  createLoopModelInfo,
  ComputeClient,
  AgentRunControl,
  NearbySession,
  LOOP_BUNDLE,
  SERVICE,
  MANUFACTURE_ID,
  connectionLabel,
  runLabel,
  createProfile,
  ComputeAdmission,
  NativeInferenceService,
  InferenceGateway,
  pickInferenceNode
};
