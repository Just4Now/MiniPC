import { LocalModel, splitReActPrompt } from '@loop/agent-core';
import { inferenceClient, InferHooks, InferSplit } from './InferenceClient';

/**
 * Model backed by the compute cluster. With an owner (one sub-task's model) cancel() stops only
 * this model's requests; without one it stops everything, as before.
 */
export class RemoteComputeModel implements LocalModel {
  private hooks: InferHooks;
  /**
   * 本轮附图（裸 base64，无 `data:` 前缀）。由页面在运行前用 setImage() 注入。
   *
   * 只在**首次**模型调用时带上，随后立即清空：一次 ReAct 运行会调用模型多步，
   * 图纸只有第一步需要（后续步骤处理的是工具观察结果），否则每一步都要重复上传
   * 约 24000 字符、拆成约 50 个近场分片。
   */
  private image: string = '';

  constructor(hooks: InferHooks = {}) { this.hooks = hooks; }

  /** 注入本轮附图；空串表示纯文本请求。 */
  setImage(image: string): void { this.image = image; }

  cancel(): void {
    const owner = this.hooks.owner;
    if (owner !== undefined && owner.length > 0) { inferenceClient.cancelOwner(owner); return; }
    inferenceClient.cancel();
  }

  complete(prompt: string): Promise<string> {
    const split = splitReActPrompt(prompt);
    const image = this.image;
    this.image = '';
    if (split === null) {
      return inferenceClient.complete(prompt, this.hooks, null, image);
    }
    const request: InferSplit = { system: split.system, user: split.user };
    return inferenceClient.complete(prompt, this.hooks, request, image);
  }
}
