export function repairUtf8FromSource(output: string, source: string): string {
  if (output.indexOf('\uFFFD') < 0 || source.length === 0) {
    return output;
  }
  const chars = Array.from(output);
  const result: string[] = [];
  let index = 0;
  while (index < chars.length) {
    if (chars[index] !== '\uFFFD') {
      result.push(chars[index]);
      index += 1;
      continue;
    }
    let end = index;
    while (end < chars.length && chars[end] === '\uFFFD') {
      end += 1;
    }
    const run = end - index;
    const following = chars.slice(end, Math.min(chars.length, end + 24));
    let replacement = '';
    if (run >= 1 && run <= 6) {
      for (let length = following.length; length >= 2; length--) {
        const anchor = following.slice(0, length).join('');
        const previous = sharedPrevious(source, anchor);
        if (previous.length > 0) {
          replacement = previous;
          break;
        }
      }
    }
    if (replacement.length > 0) {
      result.push(replacement);
    } else {
      for (let cursor = index; cursor < end; cursor++) {
        result.push(chars[cursor]);
      }
    }
    index = end;
  }
  return result.join('');
}

function sharedPrevious(source: string, anchor: string): string {
  let agreed = '';
  let from = 0;
  let hits = 0;
  while (from < source.length) {
    const at = source.indexOf(anchor, from);
    if (at < 0) {
      break;
    }
    hits += 1;
    if (at <= 0) {
      return '';
    }
    const previous = codePointBefore(source, at);
    if (previous.length === 0 || previous === '\uFFFD' || previous.charCodeAt(0) <= 127) {
      return '';
    }
    if (agreed.length === 0) {
      agreed = previous;
    } else if (agreed !== previous) {
      return '';
    }
    from = at + anchor.length;
  }
  return hits > 0 ? agreed : '';
}

function codePointBefore(text: string, index: number): string {
  const head = Array.from(text.substring(0, index));
  if (head.length === 0) {
    return '';
  }
  return head[head.length - 1];
}
