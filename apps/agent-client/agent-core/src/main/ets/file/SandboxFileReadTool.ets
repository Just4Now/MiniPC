import { ToolContract } from '../agent/ToolContract';
import { fileContract } from '../agent/contracts/FileContracts';
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { AgentTool } from '../agent/AgentTool';
import {
  normalizeWorkspaceRelativePath,
  sandboxWorkspacePath
} from './SandboxWorkspace';
import { ensureBundledWorkspaceFiles } from './SandboxWorkspaceStore';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'SandboxFile';
const MAX_READ_BYTES = 512 * 1024;

interface SandboxFileReadRequest {
  relativePath?: string;
  path?: string;
}

export class SandboxFileReadTool implements AgentTool {
  contract(): ToolContract { return fileContract(this.name(), 'read'); }

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  name(): string {
    return 'read_sandbox_file';
  }

  description(): string {
    return 'Reads one UTF-8 CSV, TXT, MD, or JSON file from the workspace. All paths are relative to ' +
      'the workspace root. Input JSON: {"relativePath":"folder/file.csv"}. ' +
      'Absolute paths and .. are rejected.';
  }

  async run(input: string): Promise<string> {
    try {
      await ensureBundledWorkspaceFiles(this.context);
      const relativePath = this.validateRelativePath(this.parsePath(input));
      const absolutePath = sandboxWorkspacePath(relativePath);
      const stat = fs.statSync(absolutePath);
      if (stat.isDirectory()) {
        throw new Error('The requested path is a directory.');
      }
      if (stat.size > MAX_READ_BYTES) {
        throw new Error(`File is too large. Limit is ${MAX_READ_BYTES} bytes.`);
      }
      const content = fs.readTextSync(absolutePath, { encoding: 'utf-8' });
      this.logInfo(`read relativePath=${relativePath} bytes=${stat.size}`);
      return `# Sandbox File: ${relativePath}\n\n${content}`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      this.logWarn(`read failed; ${message}`);
      return `Failed to read sandbox file: ${message}`;
    }
  }

  private parsePath(input: string): string {
    const trimmed = input.trim();
    if (trimmed.startsWith('{')) {
      const request = JSON.parse(trimmed) as SandboxFileReadRequest;
      return `${request.relativePath ?? request.path ?? ''}`;
    }
    if (trimmed.length >= 2) {
      const first = trimmed.substring(0, 1);
      const last = trimmed.substring(trimmed.length - 1);
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    return trimmed;
  }

  private validateRelativePath(path: string): string {
    const normalized = normalizeWorkspaceRelativePath(path, false);
    const parts = normalized.split('/');
    const lower = parts[parts.length - 1].toLowerCase();
    if (!lower.endsWith('.csv') && !lower.endsWith('.txt') &&
      !lower.endsWith('.md') && !lower.endsWith('.json')) {
      throw new Error('Only CSV, TXT, MD, and JSON text files are supported.');
    }
    return normalized;
  }

  private logInfo(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  private logWarn(message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }
}
