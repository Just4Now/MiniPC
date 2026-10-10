import { LocalModel } from '../../model/LocalModel';
import { SkillSnapshot } from '../../skill/SkillSnapshot';
import { AgentEvent, AgentEventKind } from '../AgentEvent';
import { ChatMessage, ConversationContext } from '../ConversationContext';
import { AgentListener, PARTIAL_FINAL_STATUS, ReActAgentRunner } from '../ReActAgentRunner';
import { ToolRegistry } from '../ToolRegistry';
import { Subtask, shouldTrySplit, splitTask } from './SubtaskSplitter';
import { SubtaskOutcome, concatOutcomes, mergeOutcomes } from './SubtaskMerger';

const SUBTASK_TIMEOUT_MS = 240000;
const TOTAL_TIMEOUT_MS = 300000;
const SPLIT_TIMEOUT_MS = 60000;
const MERGE_TIMEOUT_MS = 120000;
const MAX_HISTORY_CHARS = 600;
const STOPPED_TEXT = '已停止生成';

export type SubtaskPhase = 'queued' | 'running' | 'done' | 'partial' | 'failed' | 'cancelled';

/** What the UI shows for one sub-task row. */
export interface SubtaskView {
  id: string;
  title: string;
  device: string;
  phase: SubtaskPhase;
  detail: string;
}

export interface ParallelObserver {
  /** Split accepted: show the rows. */
  onPlan: (views: SubtaskView[]) => void;
  onUpdate: (view: SubtaskView) => void;
  /** Coordinator-level phase text (splitting, merging). */
  onPhase: (text: string) => void;
  /** A sub-task's thought/action/observation/skill step, text already prefixed with its label. */
  onProcess?: (event: AgentEvent) => void;
}

/** Observers a sub-task's model forwards from the transport. */
export interface SubtaskModelHooks {
  /** Caption such as "子任务 2/3", shown on the compute device that runs it. */
  label: string;
  onAccepted: (device: string) => void;
}

export interface ParallelDeps {
  /** A model dedicated to one sub-task: cancel() must stop only that sub-task's requests. */
  modelFor: (subtaskId: string, hooks: SubtaskModelHooks) => LocalModel;
  /** Models for the coordinator steps; the merge model may stream into the answer bubble. */
  splitModel: () => LocalModel;
  mergeModel: () => LocalModel;
  tools: ToolRegistry;
  skills?: SkillSnapshot;
  maxSteps: number;
  maxPromptBytes: () => number;
  /** Idle/total modelled devices behind the compute hub. */
  load: () => ClusterSize;
}

export interface ClusterSize { idle: number; total: number; }

function guarded<T>(work: Promise<T>, ms: number, onTimeout: () => void, message: string): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (error: Error) => void): void => {
    let settled = false;
    const timer = setTimeout((): void => {
      if (settled) { return; }
      settled = true;
      try { onTimeout(); } catch (_error) { /* the timeout still wins */ }
      reject(new Error(message));
    }, ms);
    work.then((value: T): void => {
      if (settled) { return; }
      settled = true; clearTimeout(timer); resolve(value);
    }, (error: Error): void => {
      if (settled) { return; }
      settled = true; clearTimeout(timer); reject(error);
    });
  });
}

/**
 * Runs the independent parts of one request as separate ReAct runs, one lane per modelled
 * device, then merges their answers. `tryRun` returns false (having emitted nothing) whenever
 * the request should take the normal single-device path.
 */
export class ParallelTaskRunner {
  private deps: ParallelDeps;
  private stopped: boolean = false;
  private timedOut: boolean = false;
  private runners: Set<ReActAgentRunner> = new Set();
  private coordinatorModels: Set<LocalModel> = new Set();
  private serial: number = 0;

  constructor(deps: ParallelDeps) {
    this.deps = deps;
  }

  requestStop(): void {
    this.stopped = true;
    for (const runner of Array.from(this.runners)) {
      try { runner.requestStop(); } catch (_error) { /* best effort */ }
    }
    for (const model of Array.from(this.coordinatorModels)) {
      try { model.cancel?.(); } catch (_error) { /* best effort */ }
    }
  }

  async tryRun(task: string, conversation: ConversationContext, observer: ParallelObserver,
    listener: AgentListener): Promise<boolean> {
    const load = this.deps.load();
    if (load.idle < 2 || !shouldTrySplit(task)) {
      return false;
    }
    observer.onPhase('正在判断是否可以拆分…');
    let subtasks: Subtask[] | null = null;
    try {
      const model = this.deps.splitModel();
      this.coordinatorModels.add(model);
      try {
        subtasks = await guarded<Subtask[] | null>(splitTask(task, this.recentContext(conversation), model),
          SPLIT_TIMEOUT_MS, (): void => { model.cancel?.(); }, '拆分超时');
      } finally {
        this.coordinatorModels.delete(model);
      }
    } catch (_error) {
      subtasks = null;
    }
    if (this.stopped) {
      listener(new AgentEvent(AgentEventKind.ERROR, STOPPED_TEXT));
      return true;
    }
    if (subtasks === null) {
      return false;
    }
    await this.execute(task, subtasks, observer, listener);
    return true;
  }

  private recentContext(conversation: ConversationContext): string {
    const turns = conversation.toChatMessages();
    const tail = turns.slice(Math.max(0, turns.length - 2));
    return tail.map((turn: ChatMessage): string =>
      (turn.role === 'user' ? '用户：' : '助手：') + turn.content.substring(0, MAX_HISTORY_CHARS)).join('\n');
  }

  private async execute(task: string, subtasks: Subtask[], observer: ParallelObserver,
    listener: AgentListener): Promise<void> {
    const taskId = 'p' + Date.now().toString(36) + (++this.serial).toString();
    const views: SubtaskView[] = subtasks.map((item: Subtask): SubtaskView =>
      ({ id: item.id, title: item.title, device: '', phase: 'queued', detail: '排队中' }));
    const outcomes: SubtaskOutcome[] = subtasks.map((item: Subtask): SubtaskOutcome =>
      ({ id: item.id, title: item.title, device: '', status: 'failed', text: '未执行' }));
    observer.onPlan(views.map((view: SubtaskView): SubtaskView => this.copy(view)));
    const total = Math.max(1, Math.min(subtasks.length, this.deps.load().total));
    let next = 0;
    const lane = async (): Promise<void> => {
      while (!this.stopped && !this.timedOut) {
        const index = next++;
        if (index >= subtasks.length) { return; }
        outcomes[index] = await this.runOne(taskId, subtasks[index], views[index], observer,
          '子任务 ' + (index + 1).toString() + '/' + subtasks.length.toString());
      }
    };
    const deadline = setTimeout((): void => {
      this.timedOut = true;
      for (const runner of Array.from(this.runners)) {
        try { runner.requestStop(); } catch (_error) { /* best effort */ }
      }
    }, TOTAL_TIMEOUT_MS);
    try {
      const lanes: Promise<void>[] = [];
      for (let count = 0; count < total; count++) { lanes.push(lane()); }
      await Promise.all(lanes);
    } finally {
      clearTimeout(deadline);
    }
    if (this.stopped) {
      listener(new AgentEvent(AgentEventKind.ERROR, STOPPED_TEXT));
      return;
    }
    for (let index = 0; index < subtasks.length; index++) {
      if (outcomes[index].text === '未执行' && this.timedOut) {
        outcomes[index].text = '整体超时，未能执行';
      }
    }
    const usable = outcomes.filter((item: SubtaskOutcome): boolean => item.status === 'ok' || item.status === 'partial');
    let answer = '';
    let merged = false;
    if (usable.length > 0) {
      observer.onPhase('正在合并 ' + outcomes.length.toString() + ' 个子任务的结果…');
      const model = this.deps.mergeModel();
      this.coordinatorModels.add(model);
      try {
        answer = await guarded<string>(mergeOutcomes(task, outcomes, model), MERGE_TIMEOUT_MS,
          (): void => { model.cancel?.(); }, '合并超时');
        merged = true;
      } catch (_error) {
        merged = false;
      } finally {
        this.coordinatorModels.delete(model);
      }
      if (this.stopped) {
        listener(new AgentEvent(AgentEventKind.ERROR, STOPPED_TEXT));
        return;
      }
    }
    if (!merged) {
      answer = concatOutcomes(outcomes);
    }
    const complete = merged && outcomes.every((item: SubtaskOutcome): boolean => item.status === 'ok');
    listener(new AgentEvent(AgentEventKind.FINAL, answer, undefined, undefined, undefined,
      complete ? undefined : PARTIAL_FINAL_STATUS));
  }

  private copy(view: SubtaskView): SubtaskView {
    return { id: view.id, title: view.title, device: view.device, phase: view.phase, detail: view.detail };
  }

  private async runOne(taskId: string, subtask: Subtask, view: SubtaskView, observer: ParallelObserver,
    label: string): Promise<SubtaskOutcome> {
    const update = (phase: SubtaskPhase, detail: string): void => {
      view.phase = phase; view.detail = detail;
      observer.onUpdate(this.copy(view));
    };
    let model: LocalModel;
    try {
      model = this.deps.modelFor(subtask.id, { label: label, onAccepted: (device: string): void => {
        view.device = device;
        observer.onUpdate(this.copy(view));
      } });
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      update('failed', reason);
      return { id: subtask.id, title: subtask.title, device: '', status: 'failed', text: reason };
    }
    const runner = new ReActAgentRunner(model, this.deps.tools, this.deps.maxSteps, this.deps.skills, true, false, true,
      this.deps.maxPromptBytes, false, true);
    this.runners.add(runner);
    let text = '';
    // Assigned from the listener closure, so keep the declared union instead of a narrowed literal.
    let status: 'ok' | 'partial' | 'failed' = 'failed' as 'ok' | 'partial' | 'failed';
    let ended = false;
    update('running', '生成中');
    const timer = setTimeout((): void => {
      text = '子任务超时';
      try { runner.requestStop(); } catch (_error) { /* best effort */ }
    }, SUBTASK_TIMEOUT_MS);
    try {
      await runner.run(subtask.task, (event: AgentEvent): void => {
        if (ended) { return; }
        if (observer.onProcess !== undefined && (event.kind === AgentEventKind.THOUGHT ||
          event.kind === AgentEventKind.ACTION || event.kind === AgentEventKind.OBSERVATION ||
          event.kind === AgentEventKind.SKILL)) {
          observer.onProcess(new AgentEvent(event.kind, '[' + label + '] ' + event.text, event.callId,
            event.toolName, event.input, event.status));
        }
        if (event.kind === AgentEventKind.ACTION) {
          update('running', '正在调用工具：' + (event.toolName ?? '工具') + '…');
        } else if (event.kind === AgentEventKind.OBSERVATION) {
          update('running', '正在整理工具结果…');
        } else if (event.kind === AgentEventKind.FINAL) {
          ended = true;
          text = event.text;
          status = event.status === PARTIAL_FINAL_STATUS ? 'partial' : 'ok';
        } else if (event.kind === AgentEventKind.ERROR && !event.callId) {
          ended = true;
          if (text.length === 0) { text = event.text; }
          status = 'failed';
        }
      }, undefined, { namespace: taskId + '/' + subtask.id, goals: [], evidence: [] });
    } catch (error) {
      status = 'failed';
      text = error instanceof Error ? error.message : String(error);
    } finally {
      clearTimeout(timer);
      this.runners.delete(runner);
    }
    if (this.stopped) {
      update('cancelled', '已停止');
      return { id: subtask.id, title: subtask.title, device: view.device, status: 'cancelled', text: STOPPED_TEXT };
    }
    if (status === 'ok' && text.trim().length === 0) { status = 'failed'; text = '没有返回内容'; }
    if (this.timedOut && status === 'failed' && (text.length === 0 || text === STOPPED_TEXT)) { text = '整体超时'; }
    if (text.length === 0) { text = '没有得到结果'; }
    update(status === 'ok' ? 'done' : status, status === 'ok' ? '已完成' : (text.length > 40 ? text.substring(0, 40) + '…' : text));
    return { id: subtask.id, title: subtask.title, device: view.device, status: status, text: text };
  }
}
