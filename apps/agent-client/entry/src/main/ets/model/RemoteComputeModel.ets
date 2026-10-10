import { LocalModel, splitReActPrompt } from '@loop/agent-core';
import { inferenceClient, InferHooks, InferSplit } from './InferenceClient';

/**
 * Model backed by the compute cluster. With an owner (one sub-task's model) cancel()
 * stops only this model's requests; without one it stops everything, as before.
 */
export class RemoteComputeModel implements LocalModel {
  private hooks: InferHooks;
  constructor(hooks: InferHooks = {}) { this.hooks = hooks; }
  cancel(): void {
    const owner = this.hooks.owner;
    if (owner !== undefined && owner.length > 0) { inferenceClient.cancelOwner(owner); return; }
    inferenceClient.cancel();
  }
  complete(prompt: string): Promise<string> {
    const split = splitReActPrompt(prompt);
    if (split === null) {
      return inferenceClient.complete(prompt, this.hooks, null);
    }
    const request: InferSplit = { system: split.system, user: split.user };
    return inferenceClient.complete(prompt, this.hooks, request);
  }
}
