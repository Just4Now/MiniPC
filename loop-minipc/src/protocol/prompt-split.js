'use strict';

const MARKER = '\nUser task:\n';

function splitLoopReactPrompt(prompt) {
  const index = prompt.indexOf(MARKER);
  if (index < 0) return [{ role: 'user', content: prompt }];
  return [
    { role: 'developer', content: prompt.slice(0, index + 1).trim() },
    { role: 'user', content: prompt.slice(index + MARKER.length).trim() }
  ];
}

function buildNativeRequest(prompt, maxOutputTokens) {
  return {
    type: 'qwen2',
    messages: splitLoopReactPrompt(prompt),
    stream: true,
    max_tokens: maxOutputTokens
  };
}

module.exports = {
  MARKER,
  splitLoopReactPrompt,
  buildNativeRequest
};
