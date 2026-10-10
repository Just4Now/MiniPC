import { ConversationContext } from '../agent/ConversationContext';

export interface LocalModel {
  complete(prompt: string, conversation?: ConversationContext): Promise<string>;
  // Optional for legacy/local models; cancelling must settle pending completion.
  cancel?(): void;
}
