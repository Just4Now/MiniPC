import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { normalizeWorkspaceRelativePath, sandboxWorkspacePath } from './SandboxWorkspace';

const MAX_DEPTH = 8;
const MAX_ENTRIES = 500;
const MAX_FILE_BYTES = 256 * 1024;
const MAX_TOTAL_BYTES = 4 * 1024 * 1024;
const MAX_RESULTS = 20;

interface SearchState {
  matches: string[];
  entries: number;
  bytes: number;
  unreadable: number;
  skipped: number;
  limited: boolean;
  rootFailed: boolean;
}

export function searchWorkspace(query: string): string {
  const state: SearchState = { matches: [], entries: 0, bytes: 0, unreadable: 0, skipped: 0, limited: false, rootFailed: false };
  searchDirectory('', query.toLowerCase(), state, 0);
  if (state.rootFailed) return '文件搜索失败：工作区根目录无法读取或不是普通目录（拒绝符号链接）。';
  const partial = state.limited || state.unreadable > 0 || state.skipped > 0;
  const result = state.matches.length > 0 ? state.matches.join('\n') :
    (partial ? '已检查的文本中没有匹配；不能断言整个工作区无匹配。' : '没有找到包含「' + query + '」的文本文件。');
  return partial ? result + '\n[PARTIAL] 搜索不完整：无法读取=' + state.unreadable.toString() +
    '，跳过链接/超大文件/特殊文件=' + state.skipped.toString() +
    '，达到限制=' + state.limited.toString() +
    '；上限：深度8、条目500、单文件256KiB、总读取4MiB、结果20。' : result;
}

function stop(state: SearchState): boolean {
  return state.entries >= MAX_ENTRIES || state.bytes >= MAX_TOTAL_BYTES || state.matches.length >= MAX_RESULTS;
}

function searchDirectory(relativePath: string, query: string, state: SearchState, depth: number): void {
  if (depth > MAX_DEPTH || stop(state)) { state.limited = true; return; }
  let names: string[];
  try {
    const path = sandboxWorkspacePath(relativePath);
    const info = fs.lstatSync(path);
    if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('Not a regular directory');
    // Bounded listing avoids allocating an unbounded directory snapshot.
    const remaining = MAX_ENTRIES - state.entries;
    names = fs.listFileSync(path, { recursion: false, listNum: remaining + 1 });
    if (names.length > remaining) state.limited = true;
    names = names.slice(0, remaining);
  } catch (_error) {
    state.unreadable++;
    if (relativePath.length === 0) state.rootFailed = true;
    return;
  }
  names.sort();
  for (const name of names) {
    if (stop(state)) { state.limited = true; return; }
    state.entries++;
    try {
      if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) throw new Error('Invalid directory entry');
      const child = normalizeWorkspaceRelativePath(relativePath.length > 0 ? relativePath + '/' + name : name, false);
      const path = sandboxWorkspacePath(child);
      const info = fs.lstatSync(path);
      if (info.isSymbolicLink()) { state.skipped++; continue; }
      if (info.isDirectory()) { searchDirectory(child, query, state, depth + 1); continue; }
      if (!info.isFile()) { state.skipped++; continue; }
      if (!/\.(txt|md|json|csv)$/i.test(name)) continue;
      if (!Number.isSafeInteger(info.size) || info.size < 0 || info.size > MAX_FILE_BYTES) { state.skipped++; continue; }
      if (info.size > MAX_TOTAL_BYTES - state.bytes) { state.limited = true; continue; }
      // NOFOLLOW closes the final-component lstat/open race. No openat-style
      // directory handles exist in this API; concurrent ancestor replacement
      // is outside this walk's guarantees. All observed links are rejected.
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
      let content = '';
      try {
        const opened = fs.statSync(file.fd);
        if (!opened.isFile() || opened.size !== info.size) throw new Error('File changed during search');
        const buffer = new ArrayBuffer(info.size);
        let read = 0;
        const chunk = new ArrayBuffer(Math.min(16384, info.size));
        while (read < info.size) {
          const length = Math.min(chunk.byteLength, info.size - read);
          const count = fs.readSync(file.fd, chunk, { offset: read, length: length });
          if (count <= 0 || count > length) throw new Error('Short file read');
          state.bytes += count;
          new Uint8Array(buffer).set(new Uint8Array(chunk, 0, count), read);
          read += count;
        }
        if (fs.statSync(file.fd).size !== info.size) throw new Error('File changed during search');
        content = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(buffer));
      } finally {
        fs.closeSync(file);
      }
      const at = content.toLowerCase().indexOf(query);
      if (at >= 0) {
        const snippet = content.substring(Math.max(0, at - 40), Math.min(content.length, at + Math.min(query.length, 256) + 80));
        state.matches.push('[MATCH] ' + child + ': ' + snippet.replace(/\s+/g, ' '));
      }
    } catch (_error) {
      state.unreadable++;
    }
  }
}
