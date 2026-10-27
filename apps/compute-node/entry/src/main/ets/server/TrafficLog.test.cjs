// node TrafficLog.test.cjs [path/to/typescript/lib/typescript.js]
// 调试流量落盘：假 fileIo 验证追加写、换行补齐、大小轮转（.old 一代）与 IO 失败静默。
const assert = require('node:assert/strict');
const vm = require('node:vm');
const path = require('node:path');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');

// 假文件系统：内存 Map 模拟 openSync/writeSync/closeSync/statSync/unlinkSync/renameSync。
// 刻意镜像 POSIX 访问模式语义：open 不带 WRITE_ONLY/READ_ONLY 位 = 只读 fd，
// writeSync 抛 EBADF——锁死「APPEND|CREATE 不含访问位导致 0 字节文件」的回归。
function fakeFileIo() {
  const files = new Map();      // path -> string content
  const handles = new Map();    // fd -> { path, writable }
  let nextFd = 3;
  const OpenMode = { READ_ONLY: 0, WRITE_ONLY: 0o1, READ_WRITE: 0o2, CREATE: 0o100, TRUNC: 0o1000, APPEND: 0o2000 };
  let failWrites = false;
  return {
    files,
    io: {
      OpenMode,
      setWriteFailure(on) { failWrites = on; },
      statSync(p) {
        if (!files.has(p)) throw new Error('ENOENT ' + p);
        return { size: files.get(p).length };
      },
      openSync(p, mode) {
        if (!files.has(p)) {
          if ((mode & OpenMode.CREATE) === 0) throw new Error('ENOENT ' + p);
          files.set(p, '');
        }
        const fd = nextFd++;
        handles.set(fd, { path: p, writable: (mode & 0o3) !== 0 });
        return { fd };
      },
      writeSync(fd, text) {
        if (failWrites) throw new Error('EIO');
        const handle = handles.get(fd);
        if (handle === undefined) throw new Error('EBADF');
        if (!handle.writable) throw new Error('EBADF: read-only fd');
        files.set(handle.path, files.get(handle.path) + text);
        return text.length;
      },
      closeSync(file) { handles.delete(file.fd); },
      unlinkSync(p) {
        if (!files.has(p)) throw new Error('ENOENT ' + p);
        files.delete(p);
      },
      renameSync(from, to) {
        if (!files.has(from)) throw new Error('ENOENT ' + from);
        files.set(to, files.get(from));
        files.delete(from);
      }
    }
  };
}

function loadTrafficLog(io) {
  const mod = { exports: {} };
  const context = { module: mod, exports: mod.exports, Error, Object, String,
    require: (name) => (name === '@kit.CoreFileKit' ? { fileIo: io }
      : name === '@kit.PerformanceAnalysisKit' ? { hilog: { info() {}, warn() {}, error() {} } } : {}) };
  vm.runInNewContext(transpile(path.join(__dirname, 'TrafficLog.ets')), context);
  return mod.exports;
}

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test('appends JSONL lines with newline; file auto-created', () => {
  const fs = fakeFileIo();
  const { TrafficLog } = loadTrafficLog(fs.io);
  const log = new TrafficLog('/data/files/openai-traffic.jsonl', 1024);
  assert.equal(log.filePath(), '/data/files/openai-traffic.jsonl');
  log.append('{"kind":"request"}');
  log.append('{"kind":"reply"}\n');
  assert.equal(fs.files.get('/data/files/openai-traffic.jsonl'), '{"kind":"request"}\n{"kind":"reply"}\n');
});

test('rotates to .old (one generation) once the file reaches maxBytes', () => {
  const fs = fakeFileIo();
  const { TrafficLog } = loadTrafficLog(fs.io);
  const file = '/data/files/openai-traffic.jsonl';
  const log = new TrafficLog(file, 20);
  log.append('0123456789');          // 10 字节 < 20，继续写
  log.append('0123456789');          // 写完 20 字节
  log.append('new-gen');             // 追加前 size>=20 → 轮转
  assert.equal(fs.files.get(file), 'new-gen\n');
  assert.equal(fs.files.get(file + '.old'), '0123456789\n0123456789\n');
});

test('second rotation overwrites the previous .old', () => {
  const fs = fakeFileIo();
  const { TrafficLog } = loadTrafficLog(fs.io);
  const file = '/data/files/openai-traffic.jsonl';
  const log = new TrafficLog(file, 5);
  log.append('aaaaa');
  log.append('bbbbb');
  log.append('ccccc');
  assert.equal(fs.files.get(file), 'ccccc\n');
  assert.equal(fs.files.get(file + '.old'), 'bbbbb\n');
});

test('write failure is swallowed; append never throws', () => {
  const fs = fakeFileIo();
  const { TrafficLog } = loadTrafficLog(fs.io);
  const log = new TrafficLog('/data/files/openai-traffic.jsonl', 1024);
  fs.io.setWriteFailure(true);
  log.append('{"kind":"request"}');
  fs.io.setWriteFailure(false);
  log.append('{"kind":"reply"}');
  assert.equal(fs.files.get('/data/files/openai-traffic.jsonl'), '{"kind":"reply"}\n');
});

(async () => {
  let pass = 0;
  for (const [name, fn] of tests) {
    try { await fn(); pass++; console.log('PASS ' + name); } catch (error) { console.error('FAIL ' + name, error); process.exitCode = 1; }
  }
  console.log(pass + '/' + tests.length + ' traffic log tests passed');
})();
