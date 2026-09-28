import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { common } from '@kit.AbilityKit';
import { skillLogInfo } from '../skill/SkillLog';
import { ensureSandboxWorkspace, sandboxWorkspacePath } from './SandboxWorkspace';

const BUNDLED_WORKSPACE_ROOT = 'workspace';
const FINANCIAL_ARTICLE_PATH = '华辰新能源2025年度经营观察.md';
const FINANCIAL_ARTICLE_VERSION_MARKER = '董事会在年度简报中把自由现金流转正列为2026年的优先目标。';
const BUNDLED_WORKSPACE_FILES: string[] = [
  'temp.txt',
  FINANCIAL_ARTICLE_PATH,
  '滕王阁序.md'
];

export async function ensureBundledWorkspaceFiles(context: common.UIAbilityContext): Promise<void> {
  ensureSandboxWorkspace();
  for (const relativePath of BUNDLED_WORKSPACE_FILES) {
    const targetPath = sandboxWorkspacePath(relativePath);
    if (pathExists(targetPath) && !needsBundledRefresh(relativePath, targetPath)) {
      continue;
    }
    const rawPath = `${BUNDLED_WORKSPACE_ROOT}/${relativePath}`;
    const raw = await context.resourceManager.getRawFileContent(rawPath);
    writeTextFile(targetPath, decodeRawFile(raw));
    skillLogInfo(`SandboxWorkspace: copied bundled file raw=${rawPath} target=${targetPath}`);
  }
}

/** Refresh the bundled sample once when an older packaged version is present. */
function needsBundledRefresh(relativePath: string, targetPath: string): boolean {
  if (relativePath !== FINANCIAL_ARTICLE_PATH) {
    return false;
  }
  try {
    return fs.readTextSync(targetPath, { encoding: 'utf-8' }).indexOf(FINANCIAL_ARTICLE_VERSION_MARKER) < 0;
  } catch (_error) {
    return true;
  }
}

function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_error) {
    return false;
  }
}

function writeTextFile(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, text);
  } finally {
    fs.closeSync(file);
  }
}

function decodeRawFile(raw: Uint8Array | ArrayBuffer): string {
  const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  const bytes = raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw.buffer);
  return decoder.decodeToString(bytes);
}
