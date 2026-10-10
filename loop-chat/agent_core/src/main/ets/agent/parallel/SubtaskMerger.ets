import { LocalModel } from '../../model/LocalModel';

export type OutcomeStatus = 'ok' | 'partial' | 'failed' | 'cancelled';

export interface SubtaskOutcome {
  id: string;
  title: string;
  /** Device that ran the sub-task's last request; empty when unknown. */
  device: string;
  status: OutcomeStatus;
  text: string;
}

export function outcomeComplete(outcome: SubtaskOutcome): boolean {
  return outcome.status === 'ok';
}

function statusLabel(outcome: SubtaskOutcome): string {
  return outcome.status === 'ok' ? '已完成' : (outcome.status === 'partial' ? '部分完成' : '未完成');
}

/** Section-per-sub-task fallback used when merging fails; never invents content. */
export function concatOutcomes(outcomes: SubtaskOutcome[]): string {
  return outcomes.map((outcome: SubtaskOutcome, index: number): string => {
    const heading = (index + 1).toString() + '. ' + outcome.title + (outcome.status === 'ok' ? '' : '（' + statusLabel(outcome) + '）');
    return heading + '\n' + (outcome.text.trim().length > 0 ? outcome.text.trim() : '该部分没有得到结果。');
  }).join('\n\n');
}

const MAX_SECTION_CHARS = 3000;

function bounded(text: string): string {
  const value = text.trim();
  return value.length <= MAX_SECTION_CHARS ? value : value.substring(0, MAX_SECTION_CHARS) + '…';
}

export function buildMergePrompt(task: string, outcomes: SubtaskOutcome[]): string {
  let sections = '';
  for (let index = 0; index < outcomes.length; index++) {
    const outcome = outcomes[index];
    sections += '【子任务' + (index + 1).toString() + '：' + outcome.title + '｜' + statusLabel(outcome) + '】\n';
    sections += outcome.status === 'ok' ? bounded(outcome.text) :
      (outcome.status === 'partial' ? '（以下为不完整的结果）\n' + bounded(outcome.text) : '该部分未能完成：' + bounded(outcome.text));
    sections += '\n\n';
  }
  return '下面是同一个用户请求被拆成的几个子任务及各自的结果。请把它们合并成一份完整、通顺的中文回答，按用户请求的顺序逐项回答。\n' +
    '要求：只使用子任务结果中已有的事实，不要补充没有出现的数据；' +
    '标记为“未完成”或“部分完成”的部分，要明确告诉用户这一项没有完成，不能当作已得到的结果；不要提到“子任务”这个词。\n' +
    '用户请求：\n' + task.trim() + '\n\n' + sections.trim();
}

export async function mergeOutcomes(task: string, outcomes: SubtaskOutcome[], model: LocalModel): Promise<string> {
  const answer = (await model.complete(buildMergePrompt(task, outcomes))).trim();
  if (answer.length === 0) {
    throw new Error('合并没有返回内容');
  }
  return answer;
}
