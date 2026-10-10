'use strict';

const { MARKER } = require('../protocol/prompt-split');
const { ComputeError } = require('../protocol/inference-v2');
const { fitHistory } = require('./prompt-budget');

function parseModelText(text) {
  const finalAt = text.indexOf('Final:');
  const actionAt = text.indexOf('Action:');
  if (finalAt >= 0 && (actionAt < 0 || finalAt < actionAt)) {
    return { kind: 'final', text: text.slice(finalAt + 'Final:'.length).trim() };
  }
  if (actionAt < 0) return { kind: 'invalid' };
  const line = text.slice(actionAt + 'Action:'.length).trim().split('\n')[0].trim();
  const bracket = line.indexOf('[');
  if (bracket <= 0 || !line.endsWith(']')) return { kind: 'invalid' };
  return { kind: 'action', name: line.slice(0, bracket).trim(), input: line.slice(bracket) };
}

function buildPrompt(task, toolsText, skillsText, scratchpad, historyText) {
  let prompt = 'You are Loop, a HarmonyOS ReAct agent with tools.\n';
  prompt += 'Use only listed tools. Do not invent observations.\n';
  if (skillsText) prompt += skillsText + '\n';
  prompt += 'Tools:\n' + toolsText + '\n';
  prompt += historyText;
  prompt += MARKER.slice(1);
  prompt += task + '\n\n';
  for (const item of scratchpad) prompt += item + '\n';
  return prompt;
}

async function runGuarded(options) {
  const control = options.control;
  const executed = [];
  const scratchpad = [];
  let history = (options.history || []).slice();
  const toolsText = options.toolsText || 'list_sandbox_files[{}]\nread_sandbox_file[{"path":"string"}]\n';
  const prefix = buildPrompt(options.task, toolsText, options.skillsText || '', [], '');
  const suffixStart = prefix.indexOf(MARKER) + 1;
  const prefixOnly = prefix.slice(0, suffixStart - 1);
  const suffix = prefix.slice(suffixStart - 1);
  for (let step = 0; step < control.maxSteps; step += 1) {
    if (!control.checkpoint('before-model')) {
      return { status: 'cancelled', executed: executed, historyTurnsOmitted: control.historyTurnsOmitted };
    }
    const fitted = fitHistory(prefixOnly, history, suffix + scratchpad.join('\n'), control.maxPromptBytes);
    if (!fitted.fits) throw new ComputeError('PAYLOAD_TOO_LARGE');
    if (fitted.historyTurnsOmitted > 0) control.noteHistoryOmitted(fitted.historyTurnsOmitted);
    history = fitted.turns;
    let response;
    try {
      response = await options.model.complete(fitted.prompt);
    } catch (error) {
      return {
        status: 'failed',
        executed: executed,
        error: error,
        historyTurnsOmitted: control.historyTurnsOmitted
      };
    }
    if (!control.checkpoint('after-model')) {
      return { status: 'cancelled', executed: executed, historyTurnsOmitted: control.historyTurnsOmitted };
    }
    const outcome = parseModelText(response);
    if (outcome.kind === 'final') {
      if (!control.checkpoint('before-final')) {
        return { status: 'cancelled', executed: executed, historyTurnsOmitted: control.historyTurnsOmitted };
      }
      return {
        status: 'succeeded',
        finalText: outcome.text,
        executed: executed,
        historyTurnsOmitted: control.historyTurnsOmitted
      };
    }
    if (outcome.kind !== 'action') {
      return {
        status: 'failed',
        executed: executed,
        error: new ComputeError('MODEL_EXECUTION_FAILED', 'Model did not return an Action or Final answer.', false),
        historyTurnsOmitted: control.historyTurnsOmitted
      };
    }
    if (!control.checkpoint('before-tool')) {
      return { status: 'cancelled', executed: executed, historyTurnsOmitted: control.historyTurnsOmitted };
    }
    const output = await options.tools(outcome.name, outcome.input);
    executed.push({ name: outcome.name, input: outcome.input, output: output });
    if (!control.checkpoint('after-tool')) {
      return { status: 'cancelled', executed: executed, historyTurnsOmitted: control.historyTurnsOmitted };
    }
    scratchpad.push(response);
    scratchpad.push('Observation: ' + output);
  }
  return {
    status: 'failed',
    executed: executed,
    error: new ComputeError('REQUEST_TIMEOUT', 'Stopped after the step limit.', false),
    historyTurnsOmitted: control.historyTurnsOmitted
  };
}

module.exports = { parseModelText, buildPrompt, runGuarded };
