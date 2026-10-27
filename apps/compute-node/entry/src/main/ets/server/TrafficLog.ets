import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0301;
const TAG = 'TrafficLog';

/**
 * 调试用流量落盘：JSONL 逐行追加写，文件超过 maxBytes 时轮转（当前文件
 * 改名 .old，只保留一代）。IO 失败只记 hilog、绝不向上抛——落盘是旁路，
 * 不能影响请求处理；写失败最多丢一行日志，轮转失败最多超限一个请求的量。
 */
export class TrafficLog {
  private readonly path: string;
  private readonly maxBytes: number;

  constructor(path: string, maxBytes: number) {
    this.path = path;
    this.maxBytes = maxBytes;
  }

  filePath(): string {
    return this.path;
  }

  append(line: string): void {
    const payload = line.endsWith('\n') ? line : line + '\n';
    try {
      if (fileIo.statSync(this.path).size >= this.maxBytes) this.rotate();
    } catch (_error) {
      // 文件尚不存在：直接走创建分支。
    }
    try {
      // 注意必须带 READ_WRITE：POSIX 语义下仅 APPEND|CREATE 不含访问模式位，
      // 等于只读 fd，writeSync 直接抛错（实测文件建成 0 字节）。
      const file = fileIo.openSync(this.path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(file.fd, payload);
      fileIo.closeSync(file);
    } catch (error) {
      // 写失败只能放弃本行（磁盘满/权限等），不向上抛，但要让日志可见。
      hilog.warn(DOMAIN, TAG, 'append failed: %{public}s',
        error instanceof Error ? error.message : String(error));
    }
  }

  private rotate(): void {
    try {
      fileIo.unlinkSync(this.path + '.old');
    } catch (_error) {
      // 上一代不存在。
    }
    try {
      fileIo.renameSync(this.path, this.path + '.old');
    } catch (_error) {
      // 轮转失败继续写原文件。
    }
  }
}
