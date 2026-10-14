/** Short display text only. The original model input is kept separately. */
export function inferenceTaskText(prompt: string): string {
  let normalized = prompt.replace(/\r\n/g, '\n');
  const userTurn = normalized.lastIndexOf('[user]\n');
  const historyEnd = normalized.indexOf('End of earlier conversation.\n');
  if (userTurn >= 0) normalized = normalized.substring(userTurn + 7);
  else if (historyEnd >= 0) normalized = normalized.substring(historyEnd + 'End of earlier conversation.\n'.length);
  let text = '';
  const markers = ['User task:\n', '用户请求：\n', '原始问题：\n'];
  for (const marker of markers) {
    const at = normalized.indexOf(marker);
    if (at >= 0) { text = normalized.substring(at + marker.length); break; }
  }
  if (text.length > 0) {
    text = text.split(/\n(?:Call \S+ tool=|Control:|Action:|Observation:|Execution:|Plan:|Thought:|Rejected Final|Actual evidence:|Current evidence:|For:|【子任务|Earlier conversation|请只输出|只输出)/)[0].trim();
  }
  return text;
}

export function inferenceSummary(prompt: string, label: string = ''): string {
  let text = inferenceTaskText(prompt);
  text = text.split('\n')[0].replace(/\s+/g, ' ').trim();
  if (text.length === 0) text = label === '任务拆分' ? '正在分析任务分工' : (label === '合并结果' ? '汇总子任务结果' : '推理请求');
  if (text.length > 80) text = text.substring(0, 80) + '…';
  return label.length > 0 ? '【' + label + '】' + text : text;
}
