import { fileIo } from '@kit.CoreFileKit';

/**
 * Cumulative work this device actually finished. Stored under the app files
 * directory, which an overlay update keeps and only an uninstall clears.
 * Money is frozen at completion time in micro-yuan (1 yuan = 1_000_000).
 * The default rate is the DeepSeek Flash cache-miss list price: a local run
 * replaces an uncached API call. Peak is Beijing time Monday–Friday
 * 09:00–12:00 and 14:00–18:00. Statutory holidays are not subtracted.
 * A custom input/output price is yuan per million tokens, stored as micro-yuan
 * per million, and applies only to completions after it is saved.
 */
export interface UsageLedger {
  completedTasks: number;
  promptTokens: number;
  completionTokens: number;
  savedMicroYuan: number;
  servedTasks: string[];
  countedTasks: string[];
  priceMode: string;
  inputPerMillion: number;
  outputPerMillion: number;
}

interface UsageFile {
  completedTasks?: number;
  promptTokens?: number;
  completionTokens?: number;
  savedMicroYuan?: number;
  servedTasks?: string[];
  countedTasks?: string[];
  priceMode?: string;
  inputPerMillion?: number;
  outputPerMillion?: number;
}

interface UsagePatch {
  tasks?: string;
  tokens?: string;
  yuan?: string;
  priceMode?: string;
  inputYuan?: string;
  outputYuan?: string;
  reset?: boolean;
}

const LEDGER_FILE: string = '/usage-ledger.json';
const KEY_LIMIT: number = 256;
const KEY_CHARS: number = 280;
const INPUT_OFF_PEAK: number = 1;
const INPUT_PEAK: number = 2;
const OUTPUT_OFF_PEAK: number = 4;
const OUTPUT_PEAK: number = 8;
const DEFAULT_INPUT_PER_MILLION: number = 1000000;
const DEFAULT_OUTPUT_PER_MILLION: number = 4000000;

export function emptyUsage(): UsageLedger {
  return {
    completedTasks: 0, promptTokens: 0, completionTokens: 0, savedMicroYuan: 0,
    servedTasks: [], countedTasks: [],
    priceMode: 'flash', inputPerMillion: DEFAULT_INPUT_PER_MILLION, outputPerMillion: DEFAULT_OUTPUT_PER_MILLION
  };
}

function nonNegative(value: number | undefined): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function rateOr(value: number | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value : fallback;
}

function addCount(current: number, delta: number): number {
  if (!Number.isSafeInteger(delta) || delta <= 0) return current;
  const next = current + delta;
  return Number.isSafeInteger(next) ? next : Number.MAX_SAFE_INTEGER;
}

function scale(tokens: number, rate: number): number {
  const product = tokens * rate;
  return Number.isSafeInteger(product) ? product : Number.MAX_SAFE_INTEGER;
}

function stringList(value: Object | undefined): string[] {
  if (!Array.isArray(value)) return [];
  const items = value as string[];
  const out: string[] = [];
  for (let i = 0; i < items.length && out.length < KEY_LIMIT; i++) {
    const item = items[i];
    if (typeof item === 'string' && item.length > 0 && item.length <= KEY_CHARS) out.push(item);
  }
  return out;
}

/** Beijing weekday windows. Weekends are off-peak; public holidays stay at the weekday rate. */
export function flashPeak(atMs: number): boolean {
  if (!Number.isFinite(atMs)) return false;
  const beijing = new Date(atMs + 8 * 3600000);
  const day = beijing.getUTCDay();
  if (day === 0 || day === 6) return false;
  const minutes = beijing.getUTCHours() * 60 + beijing.getUTCMinutes();
  return (minutes >= 9 * 60 && minutes < 12 * 60) || (minutes >= 14 * 60 && minutes < 18 * 60);
}

/** Cache-miss micro-yuan for one local completion. Input ¥1/¥2 and output ¥4/¥8 per million tokens. */
export function flashMicroYuan(prompt: number, completion: number, atMs: number): number {
  const peak = flashPeak(atMs);
  return addCount(
    scale(nonNegative(prompt), peak ? INPUT_PEAK : INPUT_OFF_PEAK),
    scale(nonNegative(completion), peak ? OUTPUT_PEAK : OUTPUT_OFF_PEAK));
}

export function savedTokens(ledger: UsageLedger): number {
  return addCount(ledger.promptTokens, ledger.completionTokens);
}

/** Plain yuan text for an editable field. One yuan is 1_000_000 micro-yuan. */
export function formatMicroYuan(micro: number): string {
  const value = nonNegative(micro);
  const whole = Math.floor(value / 1000000);
  const frac = value % 1000000;
  if (frac === 0) return String(whole);
  let digits = 2;
  if (whole === 0 && frac < 100) digits = 6;
  else if (whole === 0 && frac < 10000) digits = 4;
  let text = String(frac);
  while (text.length < 6) text = '0' + text;
  text = String(whole) + '.' + text.substring(0, digits);
  while (text.charAt(text.length - 1) === '0') text = text.substring(0, text.length - 1);
  if (text.charAt(text.length - 1) === '.') text = text.substring(0, text.length - 1);
  return text;
}

export function usageSettingsJson(ledger: UsageLedger): string {
  return JSON.stringify({
    tasks: String(nonNegative(ledger.completedTasks)),
    tokens: String(savedTokens(ledger)),
    yuan: formatMicroYuan(ledger.savedMicroYuan),
    priceMode: ledger.priceMode === 'custom' ? 'custom' : 'flash',
    inputYuan: formatMicroYuan(ledger.inputPerMillion),
    outputYuan: formatMicroYuan(ledger.outputPerMillion)
  });
}

function parseCount(text: string): number {
  const trimmed = text.trim();
  if (trimmed.length === 0 || trimmed.length > 16) return -1;
  for (let i = 0; i < trimmed.length; i++) {
    const code = trimmed.charCodeAt(i);
    if (code < 48 || code > 57) return -1;
  }
  const value = Number(trimmed);
  return Number.isSafeInteger(value) ? value : -1;
}

/** Yuan text to micro-yuan. Returns -1 when the text is not a bounded decimal. */
function parseYuan(text: string, maxDecimals: number, maxWhole: number): number {
  const trimmed = text.trim();
  if (trimmed.length === 0 || trimmed.length > 24) return -1;
  let dot = -1;
  for (let i = 0; i < trimmed.length; i++) {
    const code = trimmed.charCodeAt(i);
    if (code === 46) {
      if (dot >= 0 || i === 0) return -1;
      dot = i;
      continue;
    }
    if (code < 48 || code > 57) return -1;
  }
  const wholeText = dot < 0 ? trimmed : trimmed.substring(0, dot);
  const fracText = dot < 0 ? '' : trimmed.substring(dot + 1);
  if (dot >= 0 && (fracText.length === 0 || fracText.length > maxDecimals)) return -1;
  if (wholeText.length === 0 || wholeText.length > 12) return -1;
  const whole = Number(wholeText);
  if (!Number.isSafeInteger(whole) || whole > maxWhole) return -1;
  const head = whole * 1000000;
  if (!Number.isSafeInteger(head)) return -1;
  if (fracText.length === 0) return head;
  const frac = Number(fracText);
  const scale = Math.pow(10, fracText.length);
  if (!Number.isSafeInteger(frac) || !Number.isSafeInteger(scale)) return -1;
  const tail = Math.round(frac * 1000000 / scale);
  const micro = head + tail;
  return Number.isSafeInteger(micro) ? micro : -1;
}

function resetCounters(ledger: UsageLedger): void {
  ledger.completedTasks = 0;
  ledger.promptTokens = 0;
  ledger.completionTokens = 0;
  ledger.savedMicroYuan = 0;
}

/** Replace the visible totals and the price used for later completions. Reset keeps dedup keys and the price. */
export function applyUsageSettings(ledger: UsageLedger, raw: string): string {
  let patch: UsagePatch;
  try { patch = JSON.parse(raw) as UsagePatch; }
  catch (_) { return '设置无法读取。'; }
  if (patch.reset === true) {
    resetCounters(ledger);
    return '';
  }
  const tasks = parseCount(typeof patch.tasks === 'string' ? patch.tasks : '');
  const tokens = parseCount(typeof patch.tokens === 'string' ? patch.tokens : '');
  const yuan = parseYuan(typeof patch.yuan === 'string' ? patch.yuan : '', 6, 1000000000);
  if (tasks < 0) return '累计完成请填写非负整数。';
  if (tokens < 0) return '节省 token 请填写非负整数。';
  if (yuan < 0) return '节省金额请填写非负数字，最多 6 位小数。';
  const mode = patch.priceMode === 'custom' ? 'custom' : (patch.priceMode === 'flash' ? 'flash' : '');
  if (mode.length === 0) return '请选择计价方式。';
  const input = parseYuan(typeof patch.inputYuan === 'string' ? patch.inputYuan : '', 4, 100000);
  const output = parseYuan(typeof patch.outputYuan === 'string' ? patch.outputYuan : '', 4, 100000);
  if (input < 0 || output < 0) return '单价请填写非负数字，最多 4 位小数。';
  ledger.completedTasks = tasks;
  ledger.promptTokens = tokens;
  ledger.completionTokens = 0;
  ledger.savedMicroYuan = yuan;
  ledger.priceMode = mode;
  ledger.inputPerMillion = input;
  ledger.outputPerMillion = output;
  return '';
}

function portion(tokens: number, perMillion: number): number {
  const count = nonNegative(tokens);
  const rate = nonNegative(perMillion);
  if (count === 0 || rate === 0) return 0;
  const whole = Math.floor(count / 1000000);
  const rest = count % 1000000;
  const head = whole === 0 ? 0 : scale(whole, rate);
  const product = rest * rate;
  const tail = Number.isSafeInteger(product) ? Math.floor(product / 1000000) : Number.MAX_SAFE_INTEGER;
  return addCount(head, tail);
}

function usageCharge(ledger: UsageLedger, prompt: number, completion: number, atMs: number): number {
  if (ledger.priceMode === 'custom') {
    return addCount(portion(prompt, ledger.inputPerMillion), portion(completion, ledger.outputPerMillion));
  }
  return flashMicroYuan(prompt, completion, atMs);
}

function remember(keys: string[], key: string): boolean {
  if (key.length === 0 || key.length > KEY_CHARS || keys.indexOf(key) >= 0) return false;
  keys.push(key);
  if (keys.length > KEY_LIMIT) keys.shift();
  return true;
}

function rememberServed(ledger: UsageLedger, taskKey: string): void {
  if (taskKey.length === 0 || taskKey.length > KEY_CHARS || ledger.servedTasks.indexOf(taskKey) >= 0) return;
  ledger.servedTasks.push(taskKey);
  while (ledger.servedTasks.length > KEY_LIMIT) {
    let drop = 0;
    for (let i = 0; i < ledger.servedTasks.length; i++) {
      if (ledger.countedTasks.indexOf('task:' + ledger.servedTasks[i]) >= 0) { drop = i; break; }
    }
    ledger.servedTasks.splice(drop, 1);
  }
}

/**
 * One successful local model call. A call without a parent task counts as one
 * completed task. Calls that share a task id only contribute tokens until that
 * parent is recorded finished.
 */
export function recordLocalCall(ledger: UsageLedger, key: string, taskKey: string,
  prompt: number | undefined, completion: number | undefined, atMs: number): boolean {
  if (key.length === 0 || key.length > 256) return false;
  const mark = 'call:' + key;
  if (ledger.countedTasks.indexOf(mark) >= 0) return false;
  remember(ledger.countedTasks, mark);
  const promptTokens = nonNegative(prompt);
  const completionTokens = nonNegative(completion);
  ledger.promptTokens = addCount(ledger.promptTokens, promptTokens);
  ledger.completionTokens = addCount(ledger.completionTokens, completionTokens);
  ledger.savedMicroYuan = addCount(ledger.savedMicroYuan, usageCharge(ledger, promptTokens, completionTokens, atMs));
  if (taskKey.length > 0) rememberServed(ledger, taskKey);
  else ledger.completedTasks = addCount(ledger.completedTasks, 1);
  return true;
}

/** Count a parent task once, and only after this device successfully ran part of it. */
export function recordFinishedTask(ledger: UsageLedger, taskKey: string): boolean {
  if (ledger.servedTasks.indexOf(taskKey) < 0) return false;
  const mark = 'task:' + taskKey;
  if (ledger.countedTasks.indexOf(mark) >= 0) return false;
  remember(ledger.countedTasks, mark);
  ledger.completedTasks = addCount(ledger.completedTasks, 1);
  return true;
}

export function loadUsage(filesDir: string): UsageLedger {
  if (filesDir.length === 0) return emptyUsage();
  try {
    const saved = JSON.parse(fileIo.readTextSync(filesDir + LEDGER_FILE)) as UsageFile;
    return {
      completedTasks: nonNegative(saved.completedTasks),
      promptTokens: nonNegative(saved.promptTokens),
      completionTokens: nonNegative(saved.completionTokens),
      savedMicroYuan: nonNegative(saved.savedMicroYuan),
      servedTasks: stringList(saved.servedTasks),
      countedTasks: stringList(saved.countedTasks),
      priceMode: saved.priceMode === 'custom' ? 'custom' : 'flash',
      inputPerMillion: rateOr(saved.inputPerMillion, DEFAULT_INPUT_PER_MILLION),
      outputPerMillion: rateOr(saved.outputPerMillion, DEFAULT_OUTPUT_PER_MILLION)
    };
  } catch (_) { return emptyUsage(); }
}

export function saveUsage(filesDir: string, ledger: UsageLedger): void {
  if (filesDir.length === 0) return;
  try {
    const temp = filesDir + LEDGER_FILE + '.tmp';
    const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, JSON.stringify(ledger)); }
    finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, filesDir + LEDGER_FILE);
  } catch (_) { /* the next completion retries the write */ }
}
