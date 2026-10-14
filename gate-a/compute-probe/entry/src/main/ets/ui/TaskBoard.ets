import { TaskChildSnapshot, TaskSnapshot, validTaskSnapshot } from '../protocol/ChatProtocol';

export interface TaskGroupView extends TaskSnapshot {
  key: string;
  origin: string;
  executor: string;
  originEpoch: number;
}

/** A session-scoped display ledger, independent of model admission and routing. */
export class TaskBoard {
  private tasks: Map<string, TaskGroupView> = new Map();
  private cleared: string[] = [];

  accept(task: TaskSnapshot, epoch: number, origin: string, executor: string): boolean {
    if (!validTaskSnapshot(task)) return false;
    const key = String(epoch) + ':' + task.id;
    if (this.cleared.includes(key)) return false;
    const previous = this.tasks.get(key);
    if (previous !== undefined && (previous.endedAt > 0 || task.revision <= previous.revision ||
      previous.startedAt !== task.startedAt || previous.title !== task.title ||
      previous.subtasks.length !== task.subtasks.length || previous.subtasks.some((child, index) =>
        child.id !== task.subtasks[index].id || child.title !== task.subtasks[index].title))) return false;
    if (previous === undefined && this.tasks.size >= 64) {
      const finished = Array.from(this.tasks.values()).filter((item: TaskGroupView): boolean => item.endedAt > 0)
        .sort((a: TaskGroupView, b: TaskGroupView): number => a.endedAt - b.endedAt);
      if (finished.length === 0) return false;
      this.forget(finished[0].key);
    }
    const subtasks: TaskChildSnapshot[] = [];
    for (const child of task.subtasks) {
      const copy: TaskChildSnapshot = {
        id: child.id, title: child.title, device: child.device, phase: child.phase,
        detail: child.detail, result: child.result, resultTruncated: child.resultTruncated,
        startedAt: child.startedAt, endedAt: child.endedAt
      };
      subtasks.push(copy);
    }
    const view: TaskGroupView = {
      id: task.id, title: task.title, phase: task.phase, revision: task.revision,
      startedAt: task.startedAt, endedAt: task.endedAt, answer: task.answer, subtasks: subtasks,
      key: key, originEpoch: epoch, origin: origin, executor: executor
    };
    this.tasks.set(key, view);
    return true;
  }

  views(): TaskGroupView[] {
    return Array.from(this.tasks.values()).sort((a: TaskGroupView, b: TaskGroupView): number => b.startedAt - a.startedAt);
  }

  clearFinished(): void {
    for (const task of this.views()) if (task.endedAt > 0) this.forget(task.key);
  }

  disconnect(epoch: number): void {
    for (const task of this.tasks.values()) {
      if (task.originEpoch !== epoch || task.endedAt > 0) continue;
      task.phase = 'cancelled'; task.endedAt = Date.now(); task.revision++;
      for (const child of task.subtasks) {
        if (child.phase === 'running' || child.phase === 'queued') { child.phase = 'cancelled'; child.detail = '发起设备已断开'; }
      }
    }
  }

  private forget(key: string): void {
    this.tasks.delete(key); this.cleared.push(key);
    if (this.cleared.length > 128) this.cleared.shift();
  }
}
