'use strict';

function pickInferenceNode(nodes, need) {
  let best = null;
  for (const node of nodes) {
    if (!node.connected || node.isolated || !node.inferenceV2 || !node.ready || !node.freeSlot) continue;
    if (node.promptFormat !== need.promptFormat) continue;
    if (node.modelId !== need.modelId || node.modelRevision !== need.modelRevision) continue;
    if (node.maxContextTokens < need.contextTokens || node.maxOutputTokens < need.maxOutputTokens) continue;
    if (best === null || node.load < best.load || (node.load === best.load && node.memAvail > best.memAvail)) {
      best = node;
    }
  }
  return best;
}

module.exports = { pickInferenceNode };
