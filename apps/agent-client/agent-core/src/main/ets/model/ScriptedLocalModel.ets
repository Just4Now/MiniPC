import { ConversationContext } from '../agent/ConversationContext';
import { LocalModel } from './LocalModel';

export class ScriptedLocalModel implements LocalModel {
  async complete(prompt: string, _conversation?: ConversationContext): Promise<string> {
    if (!prompt.toLowerCase().includes('observation:')) {
      const task = this.extractTask(prompt);
      const lower = task.toLowerCase();
      const wantsTime = lower.includes('time') || lower.includes('date');
      if (wantsTime) {
        return 'Execution: serial\nAction: time[]';
      }
      return `Final: ${task}`;
    }

    return 'Final: I ran the local ReAct loop and used the available device tool result.';
  }

  private extractTask(prompt: string): string {
    const marker = 'User task:';
    const start = prompt.indexOf(marker);
    if (start === -1) {
      return 'No task found';
    }

    let task = prompt.substring(start + marker.length).trim();
    const nextSection = task.indexOf('\n\n');
    if (nextSection >= 0) {
      task = task.substring(0, nextSection).trim();
    }
    return task.replace(/\[/g, '(').replace(/\]/g, ')');
  }
}
