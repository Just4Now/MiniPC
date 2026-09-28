import { LocalModel } from '@loop/agent-core';
import { inferenceClient } from './InferenceClient';

export class RemoteComputeModel implements LocalModel {
  complete(prompt: string): Promise<string> {
    return inferenceClient.complete(prompt);
  }
}
