import { TaskChildSnapshot, TaskSnapshot, WireMessage } from '../protocol/ChatProtocol';
import { TaskGroupView } from './TaskBoard';

interface DisplayTarget { epoch: number; signature: string; pending: boolean; }
interface DisplayRoute {
  id: string;
  revision: number;
  signature: string;
  targets: DisplayTarget[];
  published: boolean;
  message?: WireMessage;
}

/** Display state follows a task only to devices that actually received its calls. */
export class TaskDisplayRelay {
  private serial: number = 0;
  private routes: Map<string, DisplayRoute> = new Map();
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;

  constructor(sender: (message: WireMessage, epoch: number) => Promise<boolean>) { this.sender = sender; }

  bind(key: string, childId: string, request: WireMessage, workerEpoch: number): void {
    let route = this.routes.get(key);
    if (route === undefined) {
      if (this.routes.size >= 64) return;
      route = { id: 'd' + Date.now().toString(36) + (++this.serial).toString(36), revision: 0,
        signature: '', targets: [], published: false };
      this.routes.set(key, route);
    }
    if (!route.targets.some((target: DisplayTarget): boolean => target.epoch === workerEpoch)) {
      route.targets.push({ epoch: workerEpoch, signature: '', pending: false });
    }
    // The worker sees the hub's session, so namespace otherwise identical chat IDs.
    request.taskId = route.id;
    request.subtaskId = childId;
  }

  publish(groups: TaskGroupView[], readyWorkers: number[], retainedKeys: string[]): void {
    for (const entry of this.routes) {
      const route = entry[1];
      const group = groups.find((item: TaskGroupView): boolean => item.key === entry[0]);
      if (group === undefined) {
        if (route.published || !retainedKeys.includes(entry[0])) this.routes.delete(entry[0]);
        continue;
      }
      route.published = true;
      const signature = JSON.stringify(group);
      if (route.signature !== signature) { route.signature = signature; route.revision++; }
      const task: TaskSnapshot = { id: route.id, title: group.title, phase: group.phase, revision: route.revision,
        startedAt: group.startedAt, endedAt: group.endedAt, answer: group.answer,
        subtasks: group.subtasks.map((child: TaskChildSnapshot): TaskChildSnapshot => ({ id: child.id, title: child.title, device: child.device,
          phase: child.phase, detail: child.detail, result: child.result, resultTruncated: child.resultTruncated,
          startedAt: child.startedAt, endedAt: child.endedAt })) };
      const message: WireMessage = { type: 'infer.task', version: 2, requestId: task.id,
        task: task, origin: group.origin, source: group.executor };
      route.message = message;
      for (const target of route.targets) {
        if (!readyWorkers.includes(target.epoch) || target.pending || target.signature === signature) continue;
        this.deliver(route, target, message, signature);
      }
    }
  }

  private async deliver(route: DisplayRoute, target: DisplayTarget, message: WireMessage, signature: string): Promise<void> {
    target.pending = true;
    try { if (await this.sender(message, target.epoch)) target.signature = signature; }
    catch (_error) { /* Display delivery cannot fail inference or trigger a model retry. */ }
    finally {
      target.pending = false;
      // A newer state may have arrived while the previous snapshot was sending.
      if (route.signature !== signature && route.message !== undefined && Array.from(this.routes.values()).includes(route)) {
        this.deliver(route, target, route.message, route.signature);
      }
    }
  }
}
