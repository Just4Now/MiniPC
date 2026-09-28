import { AgentEvent, AgentEventKind } from './AgentEvent';
import { summarizeA2uiObservation } from './A2uiObservationDigest';
import { ConversationContext } from './ConversationContext';
import { ToolRegistry } from './ToolRegistry';
import { LocalModel } from '../model/LocalModel';
import { skillLogInfo, skillLogWarn } from '../skill/SkillLog';
import { buildSkillsSection, SkillSnapshot } from '../skill/SkillSnapshot';
import { AgentSkill } from '../skill/AgentSkill';
import {
  extractCompatibleFinalAnswer,
  extractCompatiblePlainAnswer
} from './ReActResponseCompatibility';

export type AgentListener = (event: AgentEvent) => void;

const READ_TOOL_NAME = 'read';
const DOC_SUFFIXES: string[] = ['.md', '.txt', '.json', '.csv'];

function looksLikeTrainQuery(task: string): boolean {
  return /高铁|动车|火车票|列车|车次|12306|车票/.test(task);
}

function splitUserTasks(task: string): string[] {
  const separators: string[] = [
    '与此同时', '同时', '并且', '而且', '另外', '以及', '还要', '顺便', '然后', '接着', '再帮我', '；', ';'
  ];
  let parts: string[] = [task];
  for (const separator of separators) {
    const next: string[] = [];
    for (const part of parts) {
      const pieces = part.split(separator);
      for (const piece of pieces) {
        next.push(piece);
      }
    }
    parts = next;
  }
  const expanded: string[] = [];
  for (const part of parts) {
    const pieces = part.split(/[，,]\s*再/);
    for (const piece of pieces) {
      expanded.push(piece);
    }
  }
  const cleaned: string[] = [];
  for (const part of expanded) {
    const trimmed = part.trim().replace(/^[，,、。\s]+|[，,、。\s]+$/g, '');
    if (trimmed.length >= 2) {
      cleaned.push(trimmed);
    }
  }
  if (cleaned.length <= 1) {
    const only = task.trim();
    return only.length > 0 ? [only] : cleaned;
  }
  const ordered: string[] = [];
  for (const part of cleaned) {
    const normalized = part.startsWith('再') && part.length > 2 ? part.substring(1).trim() : part;
    if (normalized.length >= 2) {
      ordered.push(normalized);
    }
  }
  return ordered.length > 0 ? ordered : cleaned;
}

function scratchpadHas(scratchpad: string[], needle: string): boolean {
  for (const item of scratchpad) {
    if (item.indexOf(needle) >= 0) {
      return true;
    }
  }
  return false;
}

function documentPathOnly(answer: string): string | null {
  const trimmed = answer.trim();
  const fromJson = pathFromJson(trimmed);
  if (fromJson !== null) {
    return fromJson;
  }
  const labeled = pathFromLabel(trimmed);
  if (labeled !== null) {
    return labeled;
  }
  const lines = trimmed.split(/\r?\n/).filter((line: string): boolean => line.trim().length > 0);
  if (lines.length !== 1) {
    return null;
  }
  return asDocumentPath(lines[0].trim());
}

function pathFromJson(text: string): string | null {
  if (!text.startsWith('{') || !text.endsWith('}')) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as Record<string, Object>;
    const filePath = parsed['file_path'];
    const relativePath = parsed['relativePath'];
    const value = typeof filePath === 'string' ? filePath : (typeof relativePath === 'string' ? relativePath : '');
    return asDocumentPath(value);
  } catch (_error) {
    return null;
  }
}

function pathFromLabel(text: string): string | null {
  const lower = text.toLowerCase();
  const markers: string[] = ['file_path:', 'file_path：', 'filepath:', 'relativepath:', 'relativepath：'];
  for (const marker of markers) {
    if (!lower.startsWith(marker)) {
      continue;
    }
    return asDocumentPath(text.substring(marker.length).trim());
  }
  return null;
}

function asDocumentPath(value: string): string | null {
  const path = value.trim().replace(/^["'`]+|["'`]+$/g, '');
  if (path.length === 0 || path.length > 180 || path.indexOf(' ') >= 0) {
    return null;
  }
  const lower = path.toLowerCase();
  for (const suffix of DOC_SUFFIXES) {
    if (lower.endsWith(suffix)) {
      return path;
    }
  }
  return null;
}
const REACT_TAGS: string[] = ['Thought:', 'Execution:', 'Action:', 'Observation:', 'Final:'];
const COMMON_FOLDER_SYSTEM_CONTEXT = 'Loopy file space (文件空间) is one workspace directory shared by the sandbox ls, read, and write tools. ' +
  'Treat every displayed path as relative to the workspace root. Never add a workspace/ prefix or use an absolute device path in tool parameters. ' +
  'Do not claim that a file was read or is missing unless a registered file-reading tool actually checked it.\n';
const ARTICLE_ANALYSIS_MEMORY = '<memory>\n' +
  '当用户需要分析、总结或提炼文章时，严格按以下顺序执行：\n' +
  '第一步：调用 list_sandbox_files 列出工作空间文件，从文件名和路径中选择最符合用户需求的一篇；找不到时直接说明。\n' +
  '第二步：调用 read_sandbox_file 读取所选文件，一次只读取一篇，不得虚构未读取的内容。\n' +
  '第三步：读取成功后停止调用工具，直接根据读取到的文章输出 Final 总结；保留核心事件、关键数字、原因或影响，尽量不超过200个汉字。\n' +
  '</memory>\n';

type ExecutionMode = 'parallel' | 'serial';

function padDatePart(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

function currentLocalDateTime(now: Date = new Date()): string {
  const offsetMinutes = -now.getTimezoneOffset();
  const sign = offsetMinutes >= 0 ? '+' : '-';
  const absoluteOffset = Math.abs(offsetMinutes);
  return now.getFullYear().toString() + '-' + padDatePart(now.getMonth() + 1) + '-' + padDatePart(now.getDate()) +
    'T' + padDatePart(now.getHours()) + ':' + padDatePart(now.getMinutes()) + ':' + padDatePart(now.getSeconds()) +
    sign + padDatePart(Math.floor(absoluteOffset / 60)) + ':' + padDatePart(absoluteOffset % 60);
}

class ToolCall {
  name: string;
  input: string;

  constructor(name: string, input: string) {
    this.name = name;
    this.input = input;
  }
}

class ActionPlan {
  mode: ExecutionMode;
  calls: ToolCall[];

  constructor(mode: ExecutionMode, calls: ToolCall[]) {
    this.mode = mode;
    this.calls = calls;
  }
}

class ProcessedObservation {
  text: string;
  shouldStop: boolean;
  failureKey: string;
  finalText: string;

  constructor(text: string, shouldStop: boolean, failureKey: string, finalText: string) {
    this.text = text;
    this.shouldStop = shouldStop;
    this.failureKey = failureKey;
    this.finalText = finalText;
  }
}

export class ReActAgentRunner {
  private model: LocalModel;
  private tools: ToolRegistry;
  private skillSnapshot: SkillSnapshot | null;
  private skillsInSystemPrompt: boolean;
  private deterministicSkillRouting: boolean;
  private compactPrompt: boolean;
  private maxSteps: number;
  private aborting: boolean = false;

  constructor(
    model: LocalModel,
    tools: ToolRegistry,
    maxSteps: number,
    skillSnapshot?: SkillSnapshot,
    skillsInSystemPrompt: boolean = false,
    deterministicSkillRouting: boolean = false,
    compactPrompt: boolean = false
  ) {
    this.model = model;
    this.tools = tools;
    this.skillSnapshot = skillSnapshot ?? null;
    this.skillsInSystemPrompt = skillsInSystemPrompt;
    this.deterministicSkillRouting = deterministicSkillRouting;
    this.compactPrompt = compactPrompt;
    this.maxSteps = maxSteps;
  }

  requestStop(): void {
    this.aborting = true;
  }

  private emitStopped(listener: AgentListener): void {
    listener(new AgentEvent(AgentEventKind.ERROR, '已停止生成'));
  }

  async run(task: string, listener: AgentListener, conversation?: ConversationContext): Promise<void> {
    const parts = splitUserTasks(task);
    const answers: string[] = [];
    for (const part of parts) {
      if (this.aborting) {
        this.emitStopped(listener);
        return;
      }
      const answer = await this.runTask(part, listener, conversation);
      if (answer === null) {
        return;
      }
      answers.push(answer);
    }
    if (answers.length > 0) {
      listener(new AgentEvent(AgentEventKind.FINAL, answers.join('\n\n')));
    }
  }

  private async runTask(
    task: string,
    listener: AgentListener,
    conversation?: ConversationContext
  ): Promise<string | null> {
    const scratchpad: string[] = [];
    const routedSkill = this.deterministicSkillRouting
      ? this.skillSnapshot?.findByNaturalLanguageTask(task) ?? null
      : null;
    if (routedSkill !== null) {
      skillLogInfo(`ReActAgentRunner: natural-language skill selected name=${routedSkill.name}`);
      listener(new AgentEvent(AgentEventKind.SKILL, routedSkill.name));
    }

    if (this.aborting) {
      this.emitStopped(listener);
      return null;
    }
    if (await this.prefetchTrainSearch(task, scratchpad, listener)) {
      skillLogInfo('ReActAgentRunner: train_search finished, waiting for inference');
    }
    if (this.aborting) {
      this.emitStopped(listener);
      return null;
    }

    for (let step = 0; step < this.maxSteps; step++) {
      if (this.aborting) {
        this.emitStopped(listener);
        return null;
      }
      let response: string;
      try {
        response = await this.model.complete(
          this.buildPrompt(task, scratchpad, conversation, routedSkill),
          conversation
        );
      } catch (error) {
        const message = error instanceof Error ? error.message : `${error}`;
        listener(new AgentEvent(AgentEventKind.ERROR, message));
        return null;
      }

      this.emitResponse(response);

      const finalAnswer = extractCompatibleFinalAnswer(response);
      if (finalAnswer !== null) {
        if (await this.continueAfterPathOnly(finalAnswer, response, scratchpad, listener)) {
          continue;
        }
        const trainAnswer = this.trainAnswerOrContinue(finalAnswer, response, scratchpad);
        if (trainAnswer === null) {
          continue;
        }
        return trainAnswer;
      }

      const plan = this.parseActionPlan(response);
      if (plan === null) {
        const plainAnswer = extractCompatiblePlainAnswer(response);
        if (plainAnswer !== null) {
          if (await this.continueAfterPathOnly(plainAnswer, response, scratchpad, listener)) {
            continue;
          }
          const trainAnswer = this.trainAnswerOrContinue(plainAnswer, response, scratchpad);
          if (trainAnswer === null) {
            continue;
          }
          skillLogWarn('ReActAgentRunner: accepted untagged model output as Final');
          return trainAnswer;
        }
        listener(new AgentEvent(AgentEventKind.ERROR, 'Model did not return an Action or Final answer.'));
        return null;
      }

      skillLogInfo(`ReActAgentRunner: execution=${plan.mode} toolCount=${plan.calls.length}`);
      const observationsForModel: string[] = [];
      try {
        if (plan.mode === 'parallel' && plan.calls.length > 1) {
          const parallelObservations = await this.executeParallelToolCalls(plan.calls, listener);
          if (parallelObservations === null) {
            return null;
          }
          for (const observation of parallelObservations) {
            observationsForModel.push(observation);
          }
        } else {
          for (const call of plan.calls) {
            listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));
            const observation = await this.executeToolCall(call, listener);
            if (observation === null) {
              return null;
            }
            const processed = this.processObservation(observation, listener);
            observationsForModel.push(processed.text);
            if (processed.shouldStop) {
              this.emitDigestFinal(processed, listener);
              return null;
            }
          }
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : `${error}`;
        listener(new AgentEvent(AgentEventKind.ERROR, message));
        return null;
      }

      scratchpad.push(response);
      for (const observation of observationsForModel) {
        scratchpad.push(observation);
      }
    }

    listener(new AgentEvent(AgentEventKind.ERROR, `Stopped after ${this.maxSteps} steps without a final answer.`));
    return null;
  }

  private async executeParallelToolCalls(
    calls: ToolCall[],
    listener: AgentListener
  ): Promise<string[] | null> {
    for (const call of calls) {
      listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));
    }
    const observations = await Promise.all(calls.map(async (call: ToolCall): Promise<string | null> => {
      return await this.executeToolCall(call, listener);
    }));
    const result: string[] = [];
    for (const observation of observations) {
      if (observation === null) {
        return null;
      }
      const processed = this.processObservation(observation, listener);
      result.push(processed.text);
      if (processed.shouldStop) {
        this.emitDigestFinal(processed, listener);
        return null;
      }
    }
    return result;
  }

  private async executeToolCall(call: ToolCall, listener: AgentListener): Promise<string | null> {
    if (call.name === READ_TOOL_NAME) {
      skillLogInfo(`ReActAgentRunner: executing skill read input=${call.input}`);
    }
    let observation: string;
    try {
      observation = await this.tools.run(call.name, call.input);
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      throw new Error(`Tool ${call.name} failed: ${message}`);
    }
    if (call.name === READ_TOOL_NAME) {
      this.emitSkillRead(call.input, observation, listener);
    }
    return observation;
  }

  private processObservation(observation: string, listener: AgentListener): ProcessedObservation {
    const digest = summarizeA2uiObservation(observation);
    const text = digest.isA2ui ? digest.text : `Observation: ${observation}`;
    listener(new AgentEvent(AgentEventKind.OBSERVATION, text));
    return new ProcessedObservation(
      text,
      digest.isA2ui && digest.shouldStop,
      digest.failureKey,
      digest.finalText
    );
  }

  private emitDigestFinal(processed: ProcessedObservation, listener: AgentListener): void {
    if (processed.failureKey.indexOf(':error') >= 0) {
      listener(new AgentEvent(AgentEventKind.FINAL, '工具执行失败，结果已更新到主页。'));
      return;
    }
    if (processed.failureKey.length > 0) {
      listener(new AgentEvent(AgentEventKind.FINAL, '需要用户确认或授权，工具结果已更新到主页。'));
      return;
    }
    listener(new AgentEvent(AgentEventKind.FINAL,
      processed.finalText.length > 0 ? processed.finalText : '工具结果已更新到主页。'));
  }

  private emitSkillRead(input: string, observation: string, listener: AgentListener): void {
    if (this.skillSnapshot === null || !observation.startsWith('# Skill:')) {
      skillLogWarn(`ReActAgentRunner: skill read did not return skill content input=${input}`);
      return;
    }
    const skill = this.skillSnapshot.findByName(input.trim());
    if (skill !== null) {
      skillLogInfo(`ReActAgentRunner: skill selected name=${skill.name}`);
      listener(new AgentEvent(AgentEventKind.SKILL, skill.name));
    } else {
      skillLogWarn(`ReActAgentRunner: skill content returned but snapshot lookup failed input=${input}`);
    }
  }

  private async prefetchTrainSearch(task: string, scratchpad: string[], listener: AgentListener): Promise<boolean> {
    if (!this.compactPrompt || !this.tools.has('train_search') || !looksLikeTrainQuery(task)) {
      return false;
    }
    const input = `{"query":${JSON.stringify(task)}}`;
    const call = new ToolCall('train_search', input);
    listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));
    let observation: string;
    try {
      const read = await this.executeToolCall(call, listener);
      observation = read === null ? '12306 没有返回结果。' : read;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      observation = `12306 查询失败：${message}`;
    }
    const processed = this.processObservation(observation, listener);
    scratchpad.push(`Execution: serial\nAction: train_search[${input}]`);
    scratchpad.push(processed.text);
    return true;
  }

  private trainFinalIgnoresResult(answer: string, scratchpad: string[]): boolean {
    const denies = /没找到|未找到|暂无|没有相关|无相关|没有查询到|没有车/.test(answer);
    if (!denies) {
      return false;
    }
    if (scratchpadHas(scratchpad, ' → ')) {
      return true;
    }
    return scratchpadHas(scratchpad, '最接近的是') && answer.indexOf('最接近') < 0;
  }

  private trainObservationText(scratchpad: string[]): string {
    for (let index = 0; index < scratchpad.length; index++) {
      const item = scratchpad[index];
      if (item.indexOf(' → ') < 0 && item.indexOf('最接近的是') < 0) {
        continue;
      }
      const marker = 'Observation:';
      const at = item.indexOf(marker);
      return at >= 0 ? item.substring(at + marker.length).trim() : item;
    }
    return '';
  }

  private trainAnswerOrContinue(answer: string, response: string, scratchpad: string[]): string | null {
    const listed = this.trainObservationText(scratchpad);
    if (listed.length > 0) {
      return listed;
    }
    if (!this.trainFinalIgnoresResult(answer, scratchpad)) {
      return answer;
    }
    if (!scratchpadHas(scratchpad, 'must list the trains')) {
      scratchpad.push(response);
      scratchpad.push('Observation: The train list is already above. Final must list those trains in Chinese with train code and departure time. Do not say none were found.');
      return null;
    }
    return answer;
  }

  private async continueAfterPathOnly(
    answer: string,
    response: string,
    scratchpad: string[],
    listener: AgentListener
  ): Promise<boolean> {
    if (!this.compactPrompt) {
      return false;
    }
    const path = documentPathOnly(answer);
    if (path === null) {
      return false;
    }
    if (scratchpadHas(scratchpad, '# Sandbox File:')) {
      if (scratchpadHas(scratchpad, 'must summarize it in Chinese')) {
        return false;
      }
      scratchpad.push(response);
      scratchpad.push('Observation: The file text is already above. Final must summarize it in Chinese and must not be only a file path.');
      return true;
    }
    const input = `{"relativePath":${JSON.stringify(path)}}`;
    const call = new ToolCall('read_sandbox_file', input);
    listener(new AgentEvent(AgentEventKind.ACTION, `${call.name}(${call.input})`));
    let observation: string;
    try {
      const read = await this.executeToolCall(call, listener);
      if (read === null) {
        return true;
      }
      observation = read;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      observation = `Failed to read sandbox file: ${message}`;
    }
    const processed = this.processObservation(observation, listener);
    scratchpad.push(`Execution: serial\nAction: read_sandbox_file[${input}]`);
    scratchpad.push(processed.text);
    return true;
  }

  private buildPrompt(
    task: string,
    scratchpad: string[],
    conversation?: ConversationContext,
    routedSkill: AgentSkill | null = null
  ): string {
    if (this.compactPrompt) {
      return this.buildCompactPrompt(task, scratchpad, conversation, routedSkill);
    }
    if (routedSkill !== null) {
      let routedPrompt = 'You are Loop, a HarmonyOS local agent.\n';
      routedPrompt += COMMON_FOLDER_SYSTEM_CONTEXT;
      routedPrompt += 'Return exactly Final: <answer>. Do not output Thought, reasoning, or analysis. Do not call tools.\n';
      if (conversation !== undefined && !conversation.isEmpty()) {
        routedPrompt += conversation.formatPriorConversation();
      }
      routedPrompt += `## Loaded Skill: ${routedSkill.name}\n`;
      routedPrompt += `${routedSkill.instructions()}\n\n`;
      routedPrompt += 'User task:\n';
      routedPrompt += task;
      routedPrompt += '\n';
      return routedPrompt;
    }

    let prompt = 'You are Loop, a HarmonyOS ReAct agent with tools.\n';
    prompt += COMMON_FOLDER_SYSTEM_CONTEXT;
    prompt += ARTICLE_ANALYSIS_MEMORY;
    prompt += 'Current device local datetime: ' + currentLocalDateTime() + '. Resolve relative dates yourself before calling tools.\n';
    prompt += 'Output only tagged ReAct text, never Markdown fences. Answer directly with either Final:, or Execution: serial/parallel plus Action: tool[JSON].\n';
    prompt += 'Do not output Thought:, chain-of-thought, reasoning, or analysis.\n';
    prompt += 'For one tool, output exactly two control lines: Execution: serial, then Action: tool_name[{"key":"value"}]. Do not put a tool call on the Execution line and do not write the literal label input: inside brackets.\n';
    prompt += 'After each Observation, return the next Action or Final; never stop with untagged prose. Use JSON objects for tool parameters.\n';
    prompt += 'Use parallel only for independent safe calls. Never parallelize read, composio, or modelscope. Stop before confirmation, payment, sending, blocked, or irreversible actions.\n';
    prompt += 'Use only listed tools.\n';
    if (this.tools.has('modelscope')) {
      prompt += 'Call modelscope only for an activated ModelScope MCP. First call modelscope with operation=search and the full task; then execute one returned qualifiedName whose risk is read.\n';
      prompt += 'Never invent a ModelScope qualifiedName. If ModelScope blocks an unsafe or unannotated tool, stop and explain that a real confirmation flow is required.\n';
    }
    prompt += 'Use Final directly for plain text answers.\n\n';

    if (conversation !== undefined && !conversation.isEmpty()) {
      prompt += conversation.formatPriorConversation();
    }

    if (!this.skillsInSystemPrompt) {
      const skillsSection = buildSkillsSection(this.skillSnapshot);
      if (skillsSection.length > 0) {
        prompt += `${skillsSection}\n\n`;
      }
    }

    prompt += 'Tools:\n';
    prompt += this.tools.describeTools();
    prompt += '\nUser task:\n';
    prompt += task;
    prompt += '\n\n';

    for (const item of scratchpad) {
      prompt += `${item}\n`;
    }
    return prompt;
  }

  private buildCompactPrompt(
    task: string,
    scratchpad: string[],
    conversation?: ConversationContext,
    routedSkill: AgentSkill | null = null
  ): string {
    let prompt = 'You are Loop. Reply with Final: answer, or Execution: serial and Action: tool[{json}]. No Thought or markdown.\n';
    prompt += 'Workspace documents use relative paths. Find one with Execution: serial and Action: list_sandbox_files[{"relativePath":""}], then Action: read_sandbox_file[{"relativePath":"exact-name.md"}]. Do not prefix workspace/ and do not use read for these files. Do not say a file is missing until a list or read observation says so.\n';
    prompt += 'After the Observation contains the file text, Final must be a Chinese summary of that text. Never finish with only a file name or file_path.\n';
    if (scratchpadHas(scratchpad, 'Action: train_search')) {
      prompt += 'Train results are already in the Observation and are already limited to the requested departure window. Final must be Chinese and mention only those trains, with train code and departure time. Do not call train_search again. Do not say no trains were found when train codes are listed.\n';
    } else if (looksLikeTrainQuery(task)) {
      prompt += 'Train tickets: put the call on its own line, Action: train_search[{"query":"出发地到目的地加日期"}]. Do not put Execution text in the tool name. Use the observation. Do not invent trains.\n';
    }
    if (routedSkill !== null) {
      prompt += `Skill ${routedSkill.name}: ${routedSkill.instructions()}\n`;
    }
    prompt += 'Tools:\n';
    prompt += this.tools.describeToolsBrief();
    if (conversation !== undefined && !conversation.isEmpty()) {
      prompt += conversation.formatPriorConversation();
    }
    prompt += 'User task:\n';
    prompt += task;
    prompt += '\n';
    for (const item of scratchpad) {
      prompt += `${item}\n`;
    }
    return prompt;
  }

  private emitResponse(response: string): void {
    const execution = this.readLineValue(response, 'Execution:');
    if (execution !== null) {
      skillLogInfo(`ReActAgentRunner: model chose execution=${execution.trim().toLowerCase()}`);
    }
  }

  private readLineValue(text: string, prefix: string): string | null {
    const start = this.findTagStart(text, prefix);
    if (start < 0) {
      return null;
    }
    const valueStart = start + prefix.length;
    const tail = text.substring(valueStart);
    const next = this.findNextTagStart(tail, prefix);
    const value = next < 0 ? tail : tail.substring(0, next);
    return value.trim();
  }

  private findTagStart(text: string, prefix: string): number {
    let searchFrom = 0;
    while (searchFrom < text.length) {
      const index = text.indexOf(prefix, searchFrom);
      if (index < 0) {
        return -1;
      }
      if (this.isTagBoundary(text, index)) {
        return index;
      }
      searchFrom = index + prefix.length;
    }
    return -1;
  }

  private findNextTagStart(text: string, currentPrefix: string): number {
    let result = -1;
    for (let index = 0; index < REACT_TAGS.length; index++) {
      const prefix = REACT_TAGS[index];
      if (prefix === currentPrefix) {
        continue;
      }
      const start = this.findTagStart(text, prefix);
      if (start >= 0 && (result < 0 || start < result)) {
        result = start;
      }
    }
    return result;
  }

  private isTagBoundary(text: string, index: number): boolean {
    if (index === 0) {
      return true;
    }
    const previous = text.charAt(index - 1);
    return previous === '\n' || previous === '\r' || previous === ' ' || previous === '\t';
  }

  private parseActionPlan(response: string): ActionPlan | null {
    const actionTexts = this.extractActionTexts(response);
    if (actionTexts.length === 0) {
      return null;
    }

    const calls: ToolCall[] = [];
    for (const action of actionTexts) {
      const call = this.parseActionText(action);
      if (call !== null) {
        calls.push(call);
      }
    }
    return calls.length === 0 ? null : new ActionPlan(this.parseExecutionMode(response, calls), calls);
  }

  private extractActionTexts(text: string): string[] {
    const values: string[] = [];
    const lines = text.split(/\r?\n/);
    for (let index = 0; index < lines.length; index++) {
      const trimmed = lines[index].trim();
      const marker = this.findActionMarker(trimmed);
      if (marker < 0) {
        continue;
      }
      let value = trimmed.substring(marker + 'Action:'.length).trim();
      const nextIndex = index + 1;
      if (value.indexOf('[') < 0 && value.indexOf('(') < 0 && nextIndex < lines.length) {
        const next = lines[nextIndex].trim();
        if (next.startsWith('Action Input:')) {
          value += '[' + next.substring('Action Input:'.length).trim() + ']';
          index = nextIndex;
        }
      }
      values.push(value);
    }
    if (values.length === 0) {
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith('Execution:')) {
          continue;
        }
        const compactAction = trimmed.substring('Execution:'.length).trim();
        const actionMarker = compactAction.indexOf('Action:');
        const compactCall = actionMarker >= 0 ? compactAction.substring(actionMarker + 'Action:'.length).trim() : compactAction;
        const normalized = compactCall.toLowerCase();
        if (normalized === 'serial' || normalized === 'parallel' ||
          (compactCall.indexOf('[') < 0 && compactCall.indexOf('(') < 0)) {
          continue;
        }
        skillLogWarn('ReActAgentRunner: accepted compact tool call from Execution line');
        values.push(compactCall);
      }
    }
    return values;
  }

  private findActionMarker(line: string): number {
    if (line.startsWith('Action:')) {
      return 0;
    }
    const wrappers: string[] = ['Final:', 'Final Answer:', 'Answer:'];
    for (const wrapper of wrappers) {
      if (!line.startsWith(wrapper)) {
        continue;
      }
      const marker = line.indexOf('Action:', wrapper.length);
      if (marker >= 0) {
        return marker;
      }
    }
    return -1;
  }

  private parseExecutionMode(response: string, calls: ToolCall[]): ExecutionMode {
    const raw = this.readLineValue(response, 'Execution:');
    if (raw === null) {
      return 'serial';
    }
    const mode = raw.trim().toLowerCase();
    if (mode === 'parallel' && calls.length > 1 && !this.hasParallelUnsafeTools(calls)) {
      return 'parallel';
    }
    return 'serial';
  }

  private hasParallelUnsafeTools(calls: ToolCall[]): boolean {
    return calls.some((call: ToolCall): boolean => {
      return call.name === READ_TOOL_NAME ||
        call.name === 'composio' ||
        call.name === 'modelscope';
    });
  }

  private extractTaggedLines(text: string, prefix: string): string[] {
    const values: string[] = [];
    for (const line of text.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed.startsWith(prefix)) {
        values.push(trimmed.substring(prefix.length).trim());
      }
    }
    return values;
  }

  private parseActionText(action: string): ToolCall | null {
    const bracketCall = this.parseDelimitedAction(action, '[', ']');
    const delimitedCall = bracketCall ?? this.parseDelimitedAction(action, '(', ')');
    if (delimitedCall !== null) {
      return delimitedCall;
    }
    const bareName = action.trim();
    return bareName.length > 0 && bareName.indexOf(' ') < 0 ? new ToolCall(bareName, '') : null;
  }

  private parseDelimitedAction(action: string, openToken: string, closeToken: string): ToolCall | null {
    const open = action.indexOf(openToken);
    const close = action.lastIndexOf(closeToken);
    if (open <= 0 || close < open) {
      return null;
    }

    const name = this.toolNameBeforeDelimiter(action.substring(0, open));
    if (name.length === 0) {
      return null;
    }
    const input = this.normalizeActionInput(action.substring(open + 1, close).trim());
    return new ToolCall(name, input);
  }

  private toolNameBeforeDelimiter(prefix: string): string {
    const matched = /([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(prefix);
    return matched === null ? '' : matched[1];
  }

  private normalizeActionInput(input: string): string {
    const prefixes: string[] = ['input:', 'input：', 'input='];
    const lower = input.toLowerCase();
    for (const prefix of prefixes) {
      if (lower.startsWith(prefix)) {
        return input.substring(prefix.length).trim();
      }
    }
    return input;
  }
}
