// node ModelRegistry.test.cjs [path/to/typescript/lib/typescript.js]
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');
// 单一 files 映射模拟文件系统：键为完整路径，值为内容；'' 表示空文件。
const files = {};
let now = 0;
function markReady(base) {
  for (const name of ['api_config.json', 'params', 'tokenizer.json']) files[base + '/' + name] = 'x';
}
/** VL 布局：vl_params + tokenizer.json（旧版 Qwen2.5-VL-3B-NPU 部署形态）。 */
function markVlReady(base) {
  for (const name of ['vl_params', 'tokenizer.json']) files[base + '/' + name] = 'x';
}
const context = {
  exports: {}, ArrayBuffer, Date: { now: () => (now += 2000) }, require(name) {
    if (name === '@kit.CoreFileKit') {
      return { fileIo: {
        OpenMode: { READ_ONLY: 0 },
        listFileSync(path) {
          if (path !== '/app/models') throw new Error('missing');
          const names = [];
          for (const key of Object.keys(files)) {
            if (key.indexOf(path + '/') !== 0) continue;
            const rest = key.slice(path.length + 1);
            const name = rest.slice(0, rest.indexOf('/'));
            if (name.length > 0 && names.indexOf(name) < 0) names.push(name);
          }
          return names;
        },
        openSync(path) {
          if (!Object.prototype.hasOwnProperty.call(files, path)) throw new Error('missing');
          return { fd: path };
        },
        readSync(fd) {
          return files[fd].length > 0 ? 1 : 0;
        },
        closeSync() {},
        readTextSync(path) {
          if (!Object.prototype.hasOwnProperty.call(files, path)) throw new Error('missing');
          return files[path];
        }
      } };
    }
    if (name === '../protocol/ChatProtocol') return { CAPABILITY_TAGS: ['text', 'vision'] };
    return {};
  }
};
vm.runInNewContext(transpile(__dirname + '/ModelRegistry.ets'), context);
const { readyModelDirs, manifestCapabilities, deviceCapabilities, selectModelDir, modelRequestType,
  readinessOf, isVlLayout } = context.exports;
// 空仓：没有 models 目录
assert.equal(readyModelDirs('/app').join(','), '', 'no models dir yields no dirs');
assert.equal(deviceCapabilities('/app').join(','), '', 'no models means no capabilities');
assert.equal(selectModelDir('/app', []).length, 0, 'no ready dir fails closed');
assert.equal(selectModelDir('/app', ['vision']).length, 0, 'no ready dir fails closed for needs too');
assert.equal(modelRequestType('/app', 'Any'), 'qwen2', 'unreadable api_config falls back to qwen2');
// 两个就绪模型（文本 + 多模态）与一个残缺目录
const TEXT_DIR = 'Qwen2.5-7B-Instruct-Q4_N_0';
const VL_DIR = 'Qwen2.5-VL-7B-Q4_N_0';
const VL_LAYOUT_DIR = 'Z-VL3B-NPU';
const BROKEN_DIR = 'A-broken-model';
markReady('/app/models/' + TEXT_DIR);
markReady('/app/models/' + VL_DIR);
markVlReady('/app/models/' + VL_LAYOUT_DIR);
files['/app/models/' + BROKEN_DIR + '/api_config.json'] = 'x';
files['/app/models/' + BROKEN_DIR + '/params'] = 'x';
assert.equal(readyModelDirs('/app').join(','), [TEXT_DIR, VL_DIR, VL_LAYOUT_DIR].join(','),
  'only ready dirs are listed, sorted by name; both layouts qualify');
assert.equal(readinessOf('/app/models/' + BROKEN_DIR).indexOf('tokenizer.json') >= 0, true,
  'readiness names the first missing file');
assert.equal(isVlLayout('/app/models/' + VL_LAYOUT_DIR), true, 'vl_params marks the VL layout');
assert.equal(isVlLayout('/app/models/' + TEXT_DIR), false, 'text layout has no vl_params');
// manifest 能力：缺省、未知标签、去重、损坏
assert.equal(manifestCapabilities('/app', TEXT_DIR).join(','), 'text', 'missing manifest is text-only');
assert.equal(manifestCapabilities('/app', VL_LAYOUT_DIR).join(','), 'text,vision',
  'VL layout without manifest honestly defaults to text+vision');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":["text","vision"]}';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'text,vision');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":["vision","fly","vision"]}';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'vision', 'unknown tags drop and dupes dedupe');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":[]}';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'text', 'empty declaration falls back to text');
files['/app/models/' + VL_DIR + '/manifest.json'] = 'not json';
assert.equal(manifestCapabilities('/app', VL_DIR).join(','), 'text', 'broken manifest falls back to text');
files['/app/models/' + VL_DIR + '/manifest.json'] = '{"capabilities":["text","vision"]}';
// 设备能力 = 并集（VL 布局缺省也贡献 vision）
assert.equal(deviceCapabilities('/app').join(','), 'text,vision', 'device capability is the union');
// 按需选模：vision → 首个覆盖目录（VL_DIR 排序靠前）；空需求 → 首个文本布局目录（绝不落到 VL 权重目录）
assert.equal(selectModelDir('/app', []), TEXT_DIR, 'text request prefers the GEWU text dir');
assert.equal(selectModelDir('/app', ['text']), TEXT_DIR);
assert.equal(selectModelDir('/app', ['vision']), VL_DIR, 'vision needs pick the multimodal dir');
delete files['/app/models/' + VL_DIR + '/manifest.json'];
files['/app/models/' + VL_DIR + '/api_config.json'] = '{"name":"qwen2vl"}';
assert.equal(selectModelDir('/app', ['vision']), VL_LAYOUT_DIR,
  'VL layout dir covers vision even without a manifest');
// 请求类型跟随 api_config
assert.equal(modelRequestType('/app', VL_DIR), 'qwen2vl', 'api_config name drives the request type');
files['/app/models/' + VL_DIR + '/api_config.json'] = '{"type":"llama"}';
assert.equal(modelRequestType('/app', VL_DIR), 'llama', 'type is used when name is absent');
console.log('PASS: model discovery, manifest capabilities, VL layout, per-need model selection, request type');
