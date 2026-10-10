import { LocalModel } from '../../model/LocalModel';

export interface Subtask { id: string; title: string; task: string; }

const MIN_SUBTASKS = 2;
const MAX_SUBTASKS = 4;
const MAX_TASK_CHARS = 500;
const MAX_TITLE_CHARS = 20;
const MAX_CONTEXT_CHARS = 1500;

// Cheap signals that a request bundles several jobs. Without one, splitting would only add two inferences.
const BUNDLE_SIGNAL = /分别|并且|同时|另外|还有|以及|顺便|；|;|然后再|再帮|再查|再算|再写|再翻译|\balso\b|\bas well\b|\band then\b/i;
const NUMBERED_ITEM = /(?:^|\n)\s*(?:\d{1,2}[.、)）]|[①②③④⑤]|[-*•]\s)/g;
// A sub-task that leans on another one cannot run in parallel.
const DEPENDENCY_WORDS = /上一步|上一个任务|上述|以上结果|前一个任务|根据(?:子)?任务|第[一二三四1234]个(?:子)?任务|子任务\s*\d|结果(?:再|来)/;

/** Rule screen run before any model call: true when the request looks like several independent jobs. */
export function shouldTrySplit(task: string): boolean {
  const text = task.trim();
  if (text.length < 12) {
    return false;
  }
  const questions = text.match(/[？?]/g);
  if (questions !== null && questions.length >= 2) {
    return true;
  }
  const items = text.match(NUMBERED_ITEM);
  if (items !== null && items.length >= 2) {
    return true;
  }
  return BUNDLE_SIGNAL.test(text);
}

function clip(text: string, max: number): string {
  const value = text.trim();
  return value.length <= max ? value : value.substring(0, max);
}

export function buildSplitPrompt(task: string, context: string): string {
  return '把用户请求拆成互相独立、可以同时进行的子任务。\n' +
    '规则：\n' +
    '1. 每个子任务必须自成一句完整的话，把“这个/那个/上面/它”等指代替换成具体内容。\n' +
    '2. 子任务之间不能互相依赖，也不能引用其他子任务的结果。\n' +
    '3. 请求只有一件事、或子任务之间有先后依赖时，输出 []。\n' +
    '4. 最多 ' + MAX_SUBTASKS.toString() + ' 个，不要遗漏用户要求的任何一项，也不要添加用户没有要求的事。\n' +
    '只输出一个 JSON 数组，不要任何解释：[{"title":"简短标题","task":"完整的子任务"}]\n' +
    (context.length > 0 ? '最近的对话（仅用于展开指代）：\n' + clip(context, MAX_CONTEXT_CHARS) + '\n' : '') +
    '用户请求：\n' + task.trim();
}

/** Strict parse: anything doubtful returns null so the caller keeps the single-device path. */
export function parseSubtasks(response: string, original: string): Subtask[] | null {
  const start = response.indexOf('[');
  const end = response.lastIndexOf(']');
  if (start < 0 || end <= start) {
    return null;
  }
  let parsed: object;
  try {
    parsed = JSON.parse(response.substring(start, end + 1)) as object;
  } catch (_error) {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length < MIN_SUBTASKS || parsed.length > MAX_SUBTASKS) {
    return null;
  }
  const result: Subtask[] = [];
  const seen: string[] = [];
  for (let index = 0; index < parsed.length; index++) {
    const item = parsed[index] as Record<string, Object>;
    if (item === null || typeof item !== 'object' || typeof item['task'] !== 'string') {
      return null;
    }
    const task = (item['task'] as string).trim();
    if (task.length === 0 || task.length > MAX_TASK_CHARS || task === original.trim() ||
      DEPENDENCY_WORDS.test(task) || seen.indexOf(task) >= 0) {
      return null;
    }
    seen.push(task);
    const rawTitle = typeof item['title'] === 'string' ? (item['title'] as string).trim() : '';
    result.push({ id: 's' + (index + 1).toString(),
      title: clip(rawTitle.length > 0 ? rawTitle : '子任务' + (index + 1).toString(), MAX_TITLE_CHARS), task: task });
  }
  return result;
}

/** One model call. Returns null when the request should not be split (or the call failed). */
export async function splitTask(task: string, context: string, model: LocalModel): Promise<Subtask[] | null> {
  const response = await model.complete(buildSplitPrompt(task, context));
  return parseSubtasks(response, task);
}
