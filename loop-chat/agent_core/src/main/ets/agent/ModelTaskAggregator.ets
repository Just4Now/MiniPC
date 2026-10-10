import { LocalModel } from '../model/LocalModel';
import { TaskGraph, WorkerResult, TaskAggregator } from './TaskCoordinator';
import { TaskEvidence, TASK_CONTRACT_PROMPT } from './TaskContract';
import { extractCompatibleFinalAnswer } from './ReActResponseCompatibility';
// One aggregation call after worker states become terminal; no tool execution.
export class ModelTaskAggregator implements TaskAggregator {
  private activeTask: string = '';
  private model: LocalModel;
  constructor(model: LocalModel) { this.model = model; }
  cancel(taskId: string): void { if (this.activeTask === taskId) { this.model.cancel?.(); } }
  async complete(taskId: string, graph: TaskGraph, results: WorkerResult[], evidence: TaskEvidence[]): Promise<string> {
    if (this.activeTask.length) { throw new Error('Aggregator already running'); }
    this.activeTask = taskId;
    try {
      const response = await this.model.complete(TASK_CONTRACT_PROMPT + '\nAggregation phase ONLY: output Final answers JSON for all frozen goals. No Plan or Action. ' +
        'Use worker failures only as unavailable evidence, never returned facts. Preserve real facts and clearly label inferred advice.\nFrozen goals:\n' + JSON.stringify(graph.goals) +
        '\nWorker results:\n' + JSON.stringify(results) + '\nCurrent task evidence:\n' + JSON.stringify(evidence));
      const final = extractCompatibleFinalAnswer(response);
      if (final === null) { throw new Error('Aggregator did not return Final'); }
      return final;
    } finally { this.activeTask = ''; }
  }
}
