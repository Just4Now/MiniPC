import { fileIo } from '@kit.CoreFileKit';
import { CAPABILITY_TAGS } from '../protocol/ChatProtocol';

/**
 * 模型目录登记表：filesDir/models 下所有就绪模型的发现、能力声明与按需选择。
 * 能力来自每个目录的 manifest.json（如 {"capabilities":["text","vision"]}）；
 * 请求类型来自 api_config.json 的 name/type。DeviceInfo 的设备级能力是全部
 * 就绪模型的并集；LocalChat 按单次请求的需求选择具体目录。
 */

export interface ModelManifest {
  capabilities?: string[];
}

interface ApiConfig {
  name?: string;
  type?: string;
}

const DEFAULT_CAPABILITIES: string[] = ['text'];
/** 文本 GEWU 部署的权重文件集（api_config/params/tokenizer）。 */
const MODEL_FILES: string[] = ['api_config.json', 'params', 'tokenizer.json'];
/** VL 引擎（Qwen2.5-VL-3B-NPU）部署的权重文件集：vl_params + tokenizer.json。 */
const VL_MODEL_FILES: string[] = ['vl_params', 'tokenizer.json'];
/** VL 布局标记文件：存在即按多模态目录处理。 */
const VL_MARK_FILE: string = 'vl_params';
const SCAN_CACHE_MS: number = 1500;

class ScanCache {
  at: number = 0;
  filesDir: string = '';
  dirs: string[] = [];
}

const scanCache: ScanCache = new ScanCache();

/** 目录是否为 VL 布局：存在 vl_params 标记文件即按多模态目录处理。 */
export function isVlLayout(modelDir: string): boolean {
  try {
    const f = fileIo.openSync(modelDir + '/' + VL_MARK_FILE, fileIo.OpenMode.READ_ONLY);
    fileIo.closeSync(f);
    return true;
  } catch (_) { return false; }
}

/** 就绪检查：目录内关键文件均可读且非空；通过返回空串。文件集按布局区分。 */
export function readinessOf(modelDir: string): string {
  const files = isVlLayout(modelDir) ? VL_MODEL_FILES : MODEL_FILES;
  for (const name of files) {
    try {
      const file = fileIo.openSync(modelDir + '/' + name, fileIo.OpenMode.READ_ONLY);
      try {
        if (fileIo.readSync(file.fd, new ArrayBuffer(1)) !== 1) return '模型文件为空：' + name;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_) { return '模型文件缺失或无法读取：' + name; }
  }
  return '';
}

/**
 * filesDir/models 下所有就绪目录，按名称排序保证确定性。设备信息每 2 秒轮询一次，
 * 结果按 filesDir 短缓存，避免重复探测多个模型目录的文件句柄。
 */
export function readyModelDirs(filesDir: string): string[] {
  if (filesDir.length === 0) return [];
  const now = Date.now();
  if (scanCache.at > 0 && now - scanCache.at < SCAN_CACHE_MS && scanCache.filesDir === filesDir) {
    return scanCache.dirs.slice();
  }
  const dirs: string[] = [];
  try {
    const names = fileIo.listFileSync(filesDir + '/models') as string[];
    for (const name of names) {
      if (typeof name !== 'string' || name.length === 0 || name === '.' || name === '..') continue;
      if (readinessOf(filesDir + '/models/' + name) === '') dirs.push(name);
    }
  } catch (_) {
    return [];
  }
  dirs.sort();
  scanCache.at = now;
  scanCache.filesDir = filesDir;
  scanCache.dirs = dirs.slice();
  return dirs;
}

/** 单个就绪目录声明的能力：清单缺失/损坏 → 缺省（文本布局 ['text']；VL 布局 ['text','vision']，vl_params 本身就是多模态权重标志）；未知标签丢弃、去重。 */
export function manifestCapabilities(filesDir: string, modelDir: string): string[] {
  try {
    const manifest = JSON.parse(fileIo.readTextSync(filesDir + '/models/' + modelDir + '/manifest.json')) as ModelManifest;
    const declared: string[] = manifest.capabilities === undefined ? [] : manifest.capabilities;
    const caps: string[] = [];
    for (const tag of declared) {
      if (typeof tag === 'string' && CAPABILITY_TAGS.indexOf(tag) >= 0 && caps.indexOf(tag) < 0) caps.push(tag);
    }
    return caps.length > 0 ? caps : DEFAULT_CAPABILITIES.slice();
  } catch (_) {
    return isVlLayout(filesDir + '/models/' + modelDir) ? ['text', 'vision'] : DEFAULT_CAPABILITIES.slice();
  }
}

/** 设备级能力：所有就绪模型能力的并集；无就绪模型 → []（无模型即无能力）。 */
export function deviceCapabilities(filesDir: string): string[] {
  const caps: string[] = [];
  for (const dir of readyModelDirs(filesDir)) {
    for (const tag of manifestCapabilities(filesDir, dir)) {
      if (caps.indexOf(tag) < 0) caps.push(tag);
    }
  }
  return caps;
}

function covers(caps: string[], needs: string[]): boolean {
  for (const need of needs) {
    if (caps.indexOf(need) < 0) return false;
  }
  return true;
}

/**
 * 为单次请求选择模型目录：首个能力覆盖 needs 的就绪目录；needs 为空取首个文本布局
 * 目录（VL 目录只服务带图请求，纯文本交给 GEWU probe，绝不发到 VL 权重目录）；
 * 有需求却没有目录能满足时返回空串（fail closed，绝不把请求交给不具备能力的模型）。
 */
export function selectModelDir(filesDir: string, needs: string[]): string {
  const dirs = readyModelDirs(filesDir);
  if (dirs.length === 0) return '';
  if (needs.length === 0) {
    for (const dir of dirs) {
      if (!isVlLayout(filesDir + '/models/' + dir)) return dir;
    }
    return dirs[0];
  }
  for (const dir of dirs) {
    if (covers(manifestCapabilities(filesDir, dir), needs)) return dir;
  }
  return needs.length === 0 ? dirs[0] : '';
}

/** 请求类型：api_config.json 的 name（缺省 type）；读不到回落 'qwen2'。 */
export function modelRequestType(filesDir: string, modelDir: string): string {
  try {
    const config = JSON.parse(fileIo.readTextSync(filesDir + '/models/' + modelDir + '/api_config.json')) as ApiConfig;
    const name = config.name !== undefined ? config.name : config.type;
    return typeof name === 'string' && name.length > 0 ? name : 'qwen2';
  } catch (_) {
    return 'qwen2';
  }
}
