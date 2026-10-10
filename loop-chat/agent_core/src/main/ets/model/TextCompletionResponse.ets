interface TextMessage {
  content?: string | null;
  tool_calls?: Object;
  function_call?: Object;
}

interface TextChoice {
  index?: number;
  delta?: TextMessage;
  message?: TextMessage;
  finish_reason?: string | null;
}

interface TextEnvelope {
  choices?: TextChoice[];
  error?: Object | string;
  usage?: Object;
}

function invalid(message: string): Error {
  return new Error('Invalid LLM response: ' + message);
}

export function requireTextCompletion(reason: string | null | undefined): void {
  if (reason !== 'stop') {
    throw invalid(reason === 'tool_calls' || reason === 'function_call'
      ? 'unsupported tool_calls/function_call; this app requires text ReAct.'
      : 'incomplete completion (finish_reason=' + String(reason) + ').');
  }
}

function envelope(payload: string): TextEnvelope {
  let value: TextEnvelope;
  try {
    value = JSON.parse(payload) as TextEnvelope;
  } catch (_error) {
    throw invalid('malformed JSON.');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw invalid('expected a JSON object.');
  }
  if (value.error !== undefined && value.error !== null) {
    throw invalid('provider error: ' + JSON.stringify(value.error));
  }
  if (value.choices !== undefined && !Array.isArray(value.choices)) {
    throw invalid('choices must be an array.');
  }
  return value;
}

function textOf(message: TextMessage | undefined): string {
  if (message === undefined) return '';
  if (message === null || typeof message !== 'object' || Array.isArray(message)) {
    throw invalid('invalid message/delta.');
  }
  if (message.tool_calls !== undefined || message.function_call !== undefined) {
    throw invalid('unsupported tool_calls/function_call; this app requires text ReAct.');
  }
  if (message.content === undefined || message.content === null) return '';
  if (typeof message.content !== 'string') throw invalid('content must be text.');
  return message.content;
}

function firstChoice(value: TextEnvelope): TextChoice | undefined {
  if (value.choices === undefined || value.choices.length === 0) return undefined;
  const choice = value.choices[0];
  if (choice === null || typeof choice !== 'object' || Array.isArray(choice)) {
    throw invalid('invalid choice.');
  }
  if (value.choices.length !== 1 || (choice.index !== undefined && choice.index !== 0)) {
    throw invalid('expected exactly one choice at index zero.');
  }
  return choice;
}

export function parseTextCompletion(body: string): string {
  const trimmed = body.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const choice = firstChoice(envelope(trimmed));
    if (choice === undefined) throw invalid('no choices returned.');
    const text = textOf(choice.message).trim();
    requireTextCompletion(choice.finish_reason);
    if (text.length === 0) throw invalid('no message content returned.');
    return text;
  }

  let content = '';
  let finished = false;
  let done = false;
  let eventName = '';
  let data: string[] = [];
  const lines = body.replace(/^﻿/, '').replace(/\r\n|\r/g, '\n').split('\n');
  // A frame is dispatched only by an actual blank line, never by EOF.
  for (let index = 0; index < lines.length - 1; index++) {
    const line = lines[index];
    if (line.length === 0) {
      const payload = data.join('\n');
      if (eventName === 'error') throw invalid('provider error: ' + payload);
      if (payload.trim().length > 0) {
        if (done) throw invalid('data received after [DONE].');
        if (payload.trim() === '[DONE]') {
          if (!finished) throw invalid('truncated stream: [DONE] before finish_reason.');
          done = true;
        } else {
          const value = envelope(payload);
          const choice = firstChoice(value);
          if (choice !== undefined) {
            if (finished) throw invalid('choice received after completion.');
            content += textOf(choice.delta);
            if (choice.finish_reason !== undefined && choice.finish_reason !== null) {
              requireTextCompletion(choice.finish_reason);
              finished = true;
            }
          }
        }
      }
      data = [];
      eventName = '';
      continue;
    }
    if (line.startsWith(':')) continue;
    const colon = line.indexOf(':');
    const field = colon < 0 ? line : line.substring(0, colon);
    let value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field === 'data') data.push(value);
    if (field === 'event') eventName = value;
    // id, retry, comments, and unknown fields are SSE metadata.
  }
  if (data.length > 0 || eventName === 'error' || lines[lines.length - 1].length > 0) {
    throw invalid('truncated SSE frame.');
  }
  if (!finished || !done) throw invalid('truncated stream: missing finish_reason or [DONE].');
  if (content.trim().length === 0) throw invalid('no streaming message content returned.');
  return content.trim();
}
