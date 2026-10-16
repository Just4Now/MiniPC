export enum AgentEventKind {
  THOUGHT = 'THOUGHT',
  SKILL = 'SKILL',
  ACTION = 'ACTION',
  OBSERVATION = 'OBSERVATION',
  FINAL = 'FINAL',
  ERROR = 'ERROR'
}

export class AgentEvent {
  kind: AgentEventKind;
  text: string;
  callId?: string;
  toolName?: string;
  input?: string;
  status?: string;

  // The trailing arguments remain optional so existing event producers stay source-compatible.
  constructor(kind: AgentEventKind, text: string, callId?: string, toolName?: string, input?: string,
    status?: string) {
    this.kind = kind;
    this.text = text;
    this.callId = callId;
    this.toolName = toolName;
    this.input = input;
    this.status = status;
  }
}
