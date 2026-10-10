import fs from '@ohos.file.fs';

export const SANDBOX_WORKSPACE_ROOT =
  '/data/storage/el2/base/haps/entry/files/workspace';

export function ensureSandboxWorkspace(): void {
  if (!workspacePathExists(SANDBOX_WORKSPACE_ROOT)) {
    fs.mkdirSync(SANDBOX_WORKSPACE_ROOT, true);
  }
}

export function normalizeWorkspaceRelativePath(path: string, allowEmpty: boolean): string {
  let normalized = path.trim().replace(/\\/g, '/');
  if (normalized.length === 0 || normalized === '.') {
    if (allowEmpty) {
      return '';
    }
    throw new Error('Missing relativePath.');
  }
  if (normalized.startsWith('/') || normalized.indexOf(':') >= 0) {
    throw new Error('relativePath must not be absolute.');
  }
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.length === 0) {
    if (allowEmpty) {
      return '';
    }
    throw new Error('Missing relativePath.');
  }
  const parts = normalized.split('/');
  for (const part of parts) {
    if (part.length === 0 || part === '.' || part === '..') {
      throw new Error('relativePath must not contain empty, . or .. segments.');
    }
  }
  return parts.join('/');
}

export function sandboxWorkspacePath(relativePath: string): string {
  return relativePath.length === 0
    ? SANDBOX_WORKSPACE_ROOT
    : `${SANDBOX_WORKSPACE_ROOT}/${relativePath}`;
}

function workspacePathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_error) {
    return false;
  }
}
