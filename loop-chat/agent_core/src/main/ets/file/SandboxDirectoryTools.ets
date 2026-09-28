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
interface SandboxListRequest {
  relativePath?: string;
}

function normalizedDirectoryPath(path: string): string {
  return normalizeWorkspaceRelativePath(path, true);
}

function parseListPath(input: string): string {
  const trimmed = input.trim();
  if (trimmed.startsWith('{')) {
    const request = JSON.parse(trimmed) as SandboxListRequest;
    return `${request.relativePath ?? ''}`;
  }
  return trimmed;
}

function displayEntry(relativePath: string, directory: boolean, size: number): string {
  if (directory) {
    return `[DIR] ${relativePath}/`;
  }
  return `[FILE] ${relativePath} (${size} bytes)`;
}

abstract class SandboxDirectoryToolBase {
  protected context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  protected absolutePath(relativePath: string): string {
    return sandboxWorkspacePath(relativePath);
  }

  protected logInfo(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  protected logWarn(message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }
}

export class SandboxListTool extends SandboxDirectoryToolBase implements AgentTool {
  name(): string {
    return 'list_sandbox_files';
  }

  description(): string {
    return 'Lists the direct children of one directory in the file space. Use this tool when the user asks ' +
      'what files/folders exist, wants to browse a directory, or wants to list the workspace/file-space root. ' +
      'All paths are relative to the workspace root. Input JSON: {"relativePath":"folder"}. ' +
      'Use an empty relativePath for the workspace root. ' +
      'Root example: Action: list_sandbox_files[{"relativePath":""}]. ' +
      'Absolute paths and .. are rejected.';
  }

  async run(input: string): Promise<string> {
    try {
      await ensureBundledWorkspaceFiles(this.context);
      const relativePath = normalizedDirectoryPath(parseListPath(input));
      const directoryPath = this.absolutePath(relativePath);
      const directoryStat = fs.statSync(directoryPath);
      if (!directoryStat.isDirectory()) {
        throw new Error('The requested path is not a directory.');
      }
      const names = fs.listFileSync(directoryPath);
      names.sort();
      const lines: string[] = [];
      for (const name of names) {
        const childRelativePath = relativePath.length > 0 ? `${relativePath}/${name}` : name;
        const stat = fs.statSync(this.absolutePath(childRelativePath));
        lines.push(displayEntry(childRelativePath, stat.isDirectory(), stat.size));
      }
      this.logInfo(`list relativePath=${relativePath} entries=${lines.length}`);
      return lines.length > 0 ? lines.join('\n') :
        (relativePath.length > 0 ? `Directory is empty: ${relativePath}` : 'The workspace is empty.');
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      this.logWarn(`list failed; ${message}`);
      return `Failed to list file space: ${message}`;
    }
  }
}
