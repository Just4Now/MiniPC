import { fileContract } from './contracts/FileContracts';
import { ToolContract } from './ToolContract';
import { utilityContract } from './contracts/UtilityContracts';
import { common } from '@kit.AbilityKit';
import { AgentTool } from './AgentTool';


import { searchWorkspace } from '../file/BoundedWorkspaceSearch';


export class CalculatorTool implements AgentTool {
  contract(): ToolContract { return utilityContract(this.name(), 'arithmetic'); }

  name(): string { return 'calculator'; }

  description(): string {
    return 'Calculates a safe arithmetic expression locally. No network or login. Input JSON: {"expression":"(12+3)*4"}. Supports numbers, parentheses, + - * / %. Use for exact arithmetic.';
  }

  async run(input: string): Promise<string> {
    const expression = jsonString(input, 'expression');
    if (expression.length === 0) {
      return '计算失败：expression 不能为空。';
    }
    try {
      const value = new ArithmeticParser(expression).parse();
      if (!Number.isFinite(value)) {
        return '计算失败：结果不是有限数字。';
      }
      return `计算结果：${value.toString()}`;
    } catch (error) {
      return `计算失败：${error instanceof Error ? error.message : '表达式无效'}`;
    }
  }
}

export class DateCalculatorTool implements AgentTool {
  contract(): ToolContract { return utilityContract(this.name(), 'date'); }

  name(): string { return 'date_calculator'; }

  description(): string {
    return 'Calculates local dates without network. Input JSON: {"query":"30天后"} or {"query":"2026-10-01到2026-10-08相差几天"}. Supports today, tomorrow, day-after-tomorrow, offsets, and date differences.';
  }

  async run(input: string): Promise<string> {
    const query = jsonString(input, 'query');
    if (query.length === 0) {
      return '日期计算失败：query 不能为空。';
    }
    const difference = /(\d{4}-\d{1,2}-\d{1,2}).*(?:到|至|和).*(\d{4}-\d{1,2}-\d{1,2})/.exec(query);
    if (difference !== null) {
      const first = parseDate(difference[1]);
      const second = parseDate(difference[2]);
      if (first === null || second === null) {
        return '日期计算失败：日期格式无效。';
      }
      const days = (second.getTime() - first.getTime()) / 86400000;
      return `相差 ${Math.abs(days).toString()} 天`;
    }
    const offset = /([+-]?[\d.]+)\s*天后/.exec(query);
    if (offset !== null && !/^\d+$/.test(offset[1])) return '日期计算失败：天数必须是非负整数。';
    const date = new Date();
    if (query.indexOf('大后天') >= 0) {
      date.setDate(date.getDate() + 3);
    } else if (query.indexOf('后天') >= 0) {
      date.setDate(date.getDate() + 2);
    } else if (query.indexOf('明天') >= 0) {
      date.setDate(date.getDate() + 1);
    } else if (offset !== null) {
      const days = Number(offset[1]);
      if (!Number.isSafeInteger(days) || days > 3652058) return '日期计算失败：天数超出支持范围。';
      date.setDate(date.getDate() + days);
    } else if (query.indexOf('今天') >= 0 || query.indexOf('现在') >= 0) {
      // Keep today.
    } else {
      return '日期计算失败：请使用今天、明天、后天、大后天、N天后或 YYYY-MM-DD 到 YYYY-MM-DD。';
    }
    if (!Number.isFinite(date.getTime()) || date.getFullYear() < 1 || date.getFullYear() > 9999) {
      return '日期计算失败：结果超出 0001-9999 年范围。';
    }
    return formatDate(date);
  }
}

export class UnitConvertTool implements AgentTool {
  contract(): ToolContract { return utilityContract(this.name(), 'conversion'); }

  name(): string { return 'unit_convert'; }

  description(): string {
    return 'Converts common units locally. Input JSON: {"value":5,"from":"km","to":"m"}. Supports km/m, km/mi, m/ft, kg/jin, C/F, and bytes/KB/MB/GB.';
  }

  async run(input: string): Promise<string> {
    let request: Record<string, Object>;
    try {
      request = JSON.parse(input) as Record<string, Object>;
    } catch (_error) {
      return '单位换算失败：输入必须是 JSON。';
    }
    if (request === null || typeof request !== 'object' || Array.isArray(request) ||
      typeof request.value !== 'number' || !Number.isFinite(request.value) ||
      typeof request.from !== 'string' || typeof request.to !== 'string') {
      return '单位换算失败：value 必须是有限数字，from、to 必须是字符串。';
    }
    const value = request.value as number;
    const from = (request.from as string).trim().toLowerCase();
    const to = (request.to as string).trim().toLowerCase();
    if (from.length === 0 || to.length === 0) return '单位换算失败：from、to 不能为空。';
    try {
      const result = convertUnit(value, from, to);
      if (!Number.isFinite(result)) return '单位换算失败：结果超出有限数字范围。';
      return value.toString() + ' ' + from + ' = ' + trimNumber(result) + ' ' + to;
    } catch (error) {
      return '单位换算失败：' + (error instanceof Error ? error.message : '不支持该换算');
    }
  }
}

export class SandboxSearchTool implements AgentTool {
  contract(): ToolContract { return fileContract(this.name(), 'search'); }

  constructor(_context: common.UIAbilityContext) {}
  name(): string { return 'search_sandbox_files'; }

  description(): string {
    return 'Searches workspace text files locally. Input JSON: {"query":"预算"}. Returns matching file names and snippets; no network or login.';
  }

  async run(input: string): Promise<string> {
    const query = jsonString(input, 'query');
    if (query.length === 0) return '文件搜索失败：query 不能为空。';
    try {
      // Search is read-only: initialization belongs to the workspace owner.
      // Seeding here could follow links and perform unbounded reads/writes.
      return searchWorkspace(query);
    } catch (error) {
      return `文件搜索失败：${error instanceof Error ? error.message : '未知错误'}`;
    }
  }
}

function jsonString(input: string, key: string): string {
  try {
    const parsed = JSON.parse(input) as Record<string, Object>;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return '';
    return typeof parsed[key] === 'string' ? (parsed[key] as string).trim() : '';
  } catch (_error) {
    return input.trim();
  }
}

function parseDate(text: string): Date | null {
  const parts = text.split('-');
  if (parts.length !== 3) return null;
  const year = Number(parts[0]);
  const month = Number(parts[1]);
  const day = Number(parts[2]);
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day) || month < 1 || month > 12 || day < 1) {
    return null;
  }
  // UTC is only a civil-day coordinate, not the device local instant.
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  if (year < 1 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) {
    return null;
  }
  return date;
}

function formatDate(date: Date): string {
  const month = date.getMonth() + 1;
  return `${date.getFullYear()}-${month < 10 ? '0' : ''}${month}-${date.getDate() < 10 ? '0' : ''}${date.getDate()}`;
}

function trimNumber(value: number): string {
  return Number(value.toPrecision(12)).toString();
}

function convertUnit(value: number, from: string, to: string): number {
  const known = ['km', 'mi', 'm', 'ft', 'kg', 'jin', 'c', '℃', 'f', '℉', 'bytes', 'b', 'kb', 'mb', 'gb'];
  if (known.indexOf(from) < 0 || known.indexOf(to) < 0) throw new Error('不支持的单位');
  if (from === to) return value;
  if (from === 'km' && to === 'm') return value * 1000;
  if (from === 'm' && to === 'km') return value / 1000;
  if (from === 'km' && to === 'mi') return value * 0.621371;
  if (from === 'mi' && to === 'km') return value / 0.621371;
  if (from === 'm' && to === 'ft') return value * 3.280839895;
  if (from === 'ft' && to === 'm') return value / 3.280839895;
  if (from === 'kg' && to === 'jin') return value * 2;
  if (from === 'jin' && to === 'kg') return value / 2;
  if ((from === 'c' || from === '℃') && (to === 'f' || to === '℉')) return value * 9 / 5 + 32;
  if ((from === 'f' || from === '℉') && (to === 'c' || to === '℃')) return (value - 32) * 5 / 9;
  const fromBytes = byteUnitSize(from);
  const toBytes = byteUnitSize(to);
  if (fromBytes > 0 && toBytes > 0) {
    return value * fromBytes / toBytes;
  }
  throw new Error(`不支持 ${from} 到 ${to} 的换算`);
}

function byteUnitSize(unit: string): number {
  if (unit === 'bytes' || unit === 'b') {
    return 1;
  }
  if (unit === 'kb') {
    return 1024;
  }
  if (unit === 'mb') {
    return 1048576;
  }
  if (unit === 'gb') {
    return 1073741824;
  }
  return 0;
}

class ArithmeticParser {
  private text: string;
  private index: number = 0;
  constructor(text: string) { this.text = text.replace(/\s/g, ''); }
  parse(): number {
    const value = this.parseExpression();
    if (this.index !== this.text.length) throw new Error('包含不支持的字符');
    return value;
  }
  private parseExpression(): number {
    let value = this.parseTerm();
    while (this.index < this.text.length) {
      const op = this.text.charAt(this.index);
      if (op !== '+' && op !== '-') break;
      this.index++;
      const right = this.parseTerm();
      value = op === '+' ? value + right : value - right;
    }
    return value;
  }
  private parseTerm(): number {
    let value = this.parseFactor();
    while (this.index < this.text.length) {
      const op = this.text.charAt(this.index);
      if (op !== '*' && op !== '/' && op !== '%') break;
      this.index++;
      const right = this.parseFactor();
      if ((op === '/' || op === '%') && right === 0) throw new Error('不能除以零');
      value = op === '*' ? value * right : (op === '/' ? value / right : value % right);
    }
    return value;
  }
  private parseFactor(): number {
    if (this.text.charAt(this.index) === '+') { this.index++; return this.parseFactor(); }
    if (this.text.charAt(this.index) === '-') { this.index++; return -this.parseFactor(); }
    if (this.text.charAt(this.index) === '(') {
      this.index++;
      const value = this.parseExpression();
      if (this.text.charAt(this.index) !== ')') throw new Error('括号不匹配');
      this.index++;
      return value;
    }
    const start = this.index;
    while (this.index < this.text.length && /[0-9.]/.test(this.text.charAt(this.index))) this.index++;
    if (start === this.index) throw new Error('需要数字');
    const value = Number(this.text.substring(start, this.index));
    if (!Number.isFinite(value)) throw new Error('数字无效');
    return value;
  }
}
