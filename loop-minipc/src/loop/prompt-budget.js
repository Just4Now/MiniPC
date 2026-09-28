'use strict';

const { utf8ByteLength } = require('../protocol/text');

function formatHistory(turns) {
  if (turns.length === 0) return '';
  let block = 'Previous conversation:\n';
  for (const turn of turns) {
    const label = turn.role === 'user' ? 'User' : 'Assistant';
    block += label + ': ' + turn.content + '\n';
  }
  return block.trim() + '\n\n';
}

function dropOldestExchange(turns) {
  if (turns.length === 0) return 0;
  const next = turns.slice();
  next.shift();
  let removed = 1;
  if (next.length > 0 && next[0].role === 'assistant') {
    next.shift();
    removed += 1;
  }
  return { turns: next, removed: removed };
}

function fitHistory(prefix, turns, suffix, maxBytes) {
  let kept = turns.slice();
  let omitted = 0;
  let prompt = prefix + formatHistory(kept) + suffix;
  while (maxBytes > 0 && utf8ByteLength(prompt) > maxBytes && kept.length > 0) {
    const dropped = dropOldestExchange(kept);
    kept = dropped.turns;
    omitted += dropped.removed >= 2 ? 1 : 1;
    prompt = prefix + formatHistory(kept) + suffix;
  }
  return {
    prompt: prompt,
    turns: kept,
    historyTurnsOmitted: omitted,
    fits: maxBytes <= 0 || utf8ByteLength(prompt) <= maxBytes
  };
}

module.exports = { formatHistory, fitHistory };
