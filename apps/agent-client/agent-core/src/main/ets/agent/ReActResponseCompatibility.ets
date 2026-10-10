const FINAL_PREFIXES: string[] = [
  'Final:',
  'Final Answer:',
  'Answer:',
  '最终答案:',
  '最终答案：',
  '答案:',
  '答案：'
];

const CONTROL_PREFIXES: string[] = [
  'Thought:',
  'Execution:',
  'Action:',
  'Action Input:',
  'Observation:'
];

function normalizeProtocolLine(line: string): string {
  let value = line.trim();
  while (value.startsWith('#')) {
    value = value.substring(1).trim();
  }
  return value.replace(/\*\*/g, '');
}

function startsWithIgnoreCase(value: string, prefix: string): boolean {
  return value.toLowerCase().startsWith(prefix.toLowerCase());
}

function matchingPrefix(value: string, prefixes: string[]): string | null {
  for (const prefix of prefixes) {
    if (startsWithIgnoreCase(value, prefix)) {
      return prefix;
    }
  }
  return null;
}

function isControlLine(value: string): boolean {
  return matchingPrefix(value, CONTROL_PREFIXES) !== null ||
    matchingPrefix(value, FINAL_PREFIXES) !== null;
}

/**
 * Accept the final-answer labels commonly emitted by Qwen and other chat models.
 */
export function extractCompatibleFinalAnswer(response: string): string | null {
  const lines = response.split(/\r?\n/);
  for (let index = 0; index < lines.length; index++) {
    const normalized = normalizeProtocolLine(lines[index]);
    const prefix = matchingPrefix(normalized, FINAL_PREFIXES);
    if (prefix === null) {
      continue;
    }

    const answerLines: string[] = [];
    const inlineValue = normalized.substring(prefix.length).trim();
    if (matchingPrefix(inlineValue, CONTROL_PREFIXES) !== null) {
      return null;
    }
    if (inlineValue.length > 0) {
      answerLines.push(inlineValue);
    }
    for (let tailIndex = index + 1; tailIndex < lines.length; tailIndex++) {
      const tail = normalizeProtocolLine(lines[tailIndex]);
      if (tail.length > 0 && isControlLine(tail)) {
        break;
      }
      if (tail.length > 0 && tail !== '```') {
        answerLines.push(tail);
      }
    }
    const answer = answerLines.join('\n').trim();
    return answer.length > 0 ? answer : null;
  }
  return null;
}

/**
 * Treat untagged natural-language output as a final chat answer. Responses that
 * still contain an Action are deliberately excluded so tool calls are never
 * mistaken for user-visible text.
 */
export function extractCompatiblePlainAnswer(response: string): string | null {
  const taggedFinal = extractCompatibleFinalAnswer(response);
  if (taggedFinal !== null) {
    return taggedFinal;
  }

  const lines = response.split(/\r?\n/);
  const answerLines: string[] = [];
  for (const line of lines) {
    const normalized = normalizeProtocolLine(line);
    if (normalized.length === 0 || normalized === '```') {
      continue;
    }
    if (startsWithIgnoreCase(normalized, 'Action:') ||
      startsWithIgnoreCase(normalized, 'Action Input:')) {
      return null;
    }
    if (matchingPrefix(normalized, CONTROL_PREFIXES) !== null) {
      continue;
    }
    answerLines.push(normalized);
  }

  const answer = answerLines.join('\n').trim();
  return answer.length > 0 ? answer : null;
}
