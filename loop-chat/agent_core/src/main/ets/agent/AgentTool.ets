import { ToolContract } from './ToolContract';
export type ToolResultStatus = 'success' | 'failed' | 'empty' | 'unavailable';

export interface ToolExecutionPolicy {
  readOnly: boolean;
  supportsParallel: boolean;
  cacheable: boolean;
  risk: 'low' | 'medium' | 'high';
  timeoutMs?: number;
}

export interface ToolMetadata {
  name: string;
  description: string;
  version?: string;
  readOnly?: boolean;
  supportsParallel?: boolean;
  cacheable?: boolean;
  risk?: 'low' | 'medium' | 'high';
  timeoutMs?: number;
}

export interface ToolExecutionContext {
  callId: string;
  invocationId: string;
  deadlineAt: number;
  isCancelled: () => boolean;
}

export interface ToolResult {
  // Dispatch owns this ID; a tool can return an empty ID before dispatch.
  callId: string;
  status: ToolResultStatus;
  raw: string;
  displayText: string;
  data?: Object;
  // Optional presentation hint from a validated legacy A2UI envelope.
  finalText?: string;
  metadata?: ToolMetadata;
  // A caught dispatch exception is Control, not returned tool evidence.
  returned?: boolean;
  stop?: boolean;
}

export interface AgentTool {
  name(): string;
  description(): string;
  contract?(): ToolContract;
  // String tools remain source-compatible during incremental migration.
  run(input: string, context?: ToolExecutionContext): Promise<string | ToolResult>;
  cancel?(context: ToolExecutionContext): void;
}

export function normalizeToolResult(value: string | ToolResult, callId: string, metadata?: ToolMetadata, legacyStatus?: (text: string) => ToolResultStatus): ToolResult {
  if (typeof value === 'string') {
    return { callId: callId, status: legacyStatus?.(value) ?? (value.trim().length ? 'success' : 'empty'),
      raw: value, displayText: value, metadata: metadata, returned: true, stop: false };
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    ['success', 'failed', 'empty', 'unavailable'].indexOf(value.status) < 0 || typeof value.raw !== 'string' || typeof value.displayText !== 'string' ||
    value.returned !== undefined && typeof value.returned !== 'boolean' || value.stop !== undefined && typeof value.stop !== 'boolean' ||
    value.status === 'success' && value.returned === false) {
    return { callId: callId, status: 'failed', raw: '', displayText: 'Tool returned an invalid result envelope.', metadata: metadata, returned: true, stop: metadata?.readOnly !== true };
  }
  // Rebind tool-local/cached IDs at the trusted dispatch boundary. Do not mutate
  // objects that a tool may share between concurrent calls.
  return { callId: callId, status: value.status, raw: value.raw,
    displayText: value.displayText, data: value.data, finalText: value.finalText, metadata: metadata ?? value.metadata,
    returned: value.returned ?? true, stop: value.stop ?? false };
}
