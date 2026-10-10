// Platform-free contracts. The executor has no domain/tool-name switches.
export type ContractStatus = 'pending' | 'success' | 'failed' | 'empty' | 'unavailable';
export interface ContractCall { name: string; input: string; callId?: string; goalIds?: string[]; }
export interface ContractRequirement {
  id?: string;
  position?: number;
  tool: string;
  label: string;
  scope: Object;
  anchorTime: number;
  expectedInput?: string;
  status: ContractStatus;
  output: string;
  displayText?: string;
  resultCallId?: string;
  input?: string;
  data?: Object;
}
export interface ContractOutcome {
  callId: string;
  tool: string;
  status: ContractStatus;
  raw: string;
  displayText: string;
  data?: Object;
}
export interface ValueSchema {
  type?: 'object' | 'array' | 'string' | 'number' | 'integer' | 'boolean' | 'null';
  description?: string;
  title?: string;
  default?: Object;
  $schema?: string;
  properties?: Record<string, ValueSchema>;
  required?: string[];
  additionalProperties?: boolean;
  items?: ValueSchema;
  enum?: Object[];
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
  minItems?: number;
  maxItems?: number;
  anyOf?: ValueSchema[];
}
export interface EvidenceField { path: string; kind: 'number' | 'literal'; required?: boolean; answerLabels?: string[]; tolerance?: number; }
interface ExplicitUseScope { intent: string; }
export function schemaProperties(names: string[], definitions: ValueSchema[]): Record<string, ValueSchema> {
  const properties: Record<string, ValueSchema> = {};
  for (let index = 0; index < names.length; index++) { properties[names[index]] = definitions[index]; }
  return properties;
}
export interface ToolContract {
  version: string;
  inputFormat: 'json' | 'text' | 'none';
  inputSchema?: ValueSchema;
  outputSchema?: ValueSchema;
  evidenceFields?: EvidenceField[];
  answerScopeFields?: string[];
  operandFields?: string[];
  restrictNumericClaims?: boolean;
  finalization?: 'result' | 'synthesis';
  answerValidation?: 'strict' | 'heuristic';
  recognize?: (task: string, anchorTime: number) => ContractRequirement[];
  prepareInput?: (call: ContractCall, requirements: ContractRequirement[], task?: string) => string;
  matches?: (requirement: ContractRequirement, call: ContractCall) => boolean;
  validateInput?: (input: string) => string[];
  validateAnswer?: (requirement: ContractRequirement, answer: string) => string[];
  legacyStatus?: (text: string) => 'success' | 'failed' | 'empty' | 'unavailable';
  legacyData?: (text: string) => Object | undefined;
}

export function canonicalValue(value: Object | undefined | null, depth: number = 0): string {
  if (depth > 24) { throw new Error('Canonical value size/depth limit exceeded'); }
  if (value === undefined) { return 'undefined'; }
  if (value === null || typeof value !== 'object') { return JSON.stringify(value); }
  if (Array.isArray(value)) {
    return '[' + (value as Object[]).map((item: Object): string => canonicalValue(item, depth + 1)).join(',') + ']';
  }
  const object = value as Record<string, Object>;
  return '{' + Object.keys(object).sort().map((key: string): string => JSON.stringify(key) + ':' + canonicalValue(object[key], depth + 1)).join(',') + '}';
}

function checkDefinition(schema: ValueSchema, depth: number = 0): void {
  if (depth > 24 || schema === null || typeof schema !== 'object' || Array.isArray(schema)) { throw new Error('Invalid/cyclic schema definition'); }
  const supported = ['type', 'properties', 'required', 'additionalProperties', 'items', 'enum', 'minLength', 'maxLength', 'minimum', 'maximum', 'minItems', 'maxItems', 'anyOf', 'description', 'title', 'default', '$schema'];
  for (const key of Object.keys(schema)) { if (supported.indexOf(key) < 0) { throw new Error('Unsupported schema keyword: ' + key); } }
  if (schema.type === undefined && schema.anyOf === undefined || schema.type !== undefined && ['object', 'array', 'string', 'number', 'integer', 'boolean', 'null'].indexOf(schema.type) < 0) { throw new Error('Invalid schema type'); }
  const record = schema as Object as Record<string, Object>;
  for (const key of ['minLength', 'maxLength', 'minItems', 'maxItems']) {
    const value = record[key]; if (value !== undefined && (typeof value !== 'number' || !Number.isInteger(value as number) || (value as number) < 0)) { throw new Error('Invalid schema bound: ' + key); }
  }
  for (const key of ['minimum', 'maximum']) {
    const value = record[key]; if (value !== undefined && (typeof value !== 'number' || !Number.isFinite(value as number))) { throw new Error('Invalid schema bound: ' + key); }
  }
  if (schema.minLength !== undefined && schema.maxLength !== undefined && schema.minLength > schema.maxLength || schema.minimum !== undefined && schema.maximum !== undefined && schema.minimum > schema.maximum ||
    schema.minItems !== undefined && schema.maxItems !== undefined && schema.minItems > schema.maxItems) { throw new Error('Contradictory schema bounds'); }
  if (schema.additionalProperties !== undefined && typeof schema.additionalProperties !== 'boolean') { throw new Error('Invalid additionalProperties declaration'); }
  if (schema.required !== undefined && (!Array.isArray(schema.required) || schema.required.some((key: string): boolean => typeof key !== 'string' || !key.length))) { throw new Error('Invalid required declaration'); }
  if (schema.properties !== undefined) {
    if (schema.properties === null || typeof schema.properties !== 'object' || Array.isArray(schema.properties)) { throw new Error('Invalid properties declaration'); }
    for (const key of Object.keys(schema.properties)) { checkDefinition(schema.properties[key], depth + 1); }
  }
  if (schema.items !== undefined) { checkDefinition(schema.items, depth + 1); }
  if (schema.anyOf !== undefined) {
    if (!Array.isArray(schema.anyOf) || !schema.anyOf.length || schema.anyOf.length > 64) { throw new Error('Invalid anyOf declaration'); }
    for (const alternative of schema.anyOf) { checkDefinition(alternative, depth + 1); }
  }
  if (schema.enum !== undefined) {
    if (!Array.isArray(schema.enum) || !schema.enum.length || schema.enum.length > 256) { throw new Error('Invalid enum declaration'); }
    for (const value of schema.enum) { canonicalValue(value); }
  }
}

function requirementView(entry: ContractRequirement): ContractRequirement {
  return { id: entry.id, position: entry.position, tool: entry.tool, label: entry.label, anchorTime: entry.anchorTime,
    scope: JSON.parse(JSON.stringify(entry.scope)) as Object, expectedInput: entry.expectedInput, status: entry.status,
    output: entry.output, displayText: entry.displayText, resultCallId: entry.resultCallId, input: entry.input,
    data: entry.data === undefined ? undefined : JSON.parse(JSON.stringify(entry.data)) as Object };
}
function literalPresent(text: string, value: Object): boolean {
  const literal = String(value);
  const escaped = literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const start = /^[A-Za-z0-9_.-]/.test(literal) ? '(^|[^A-Za-z0-9_.-])' : '';
  const end = /[A-Za-z0-9_.-]$/.test(literal) ? '($|[^A-Za-z0-9_.-])' : '';
  return new RegExp(start + escaped + end).test(text);
}

export function inputKey(format: 'json' | 'text' | 'none', input: string): string {
  if (format === 'text') { return input.trim(); }
  if (format === 'none') { return '{}'; }
  try { return canonicalValue(JSON.parse(input) as Object); } catch (_error) { return input; }
}

interface SchemaBudget { remaining: number; }
function checkValue(value: Object | undefined | null, schema: ValueSchema, path: string, depth: number, budget: SchemaBudget): string[] {
  if (depth > 24 || --budget.remaining < 0) { return [path + ': validation size/depth limit exceeded']; }
  if (schema.anyOf !== undefined) {
    if (!schema.anyOf.some((choice: ValueSchema): boolean => checkValue(value, choice, path, depth + 1, budget).length === 0)) {
      return [path + ': no declared schema alternative matches'];
    }
  }
  const kind = schema.type;
  if (kind === undefined && schema.anyOf !== undefined) { return []; }
  const valid = kind === 'null' ? value === null : kind === 'array' ? Array.isArray(value) :
    kind === 'object' ? value !== null && typeof value === 'object' && !Array.isArray(value) :
    kind === 'number' || kind === 'integer' ? typeof value === 'number' && Number.isFinite(value as number) && (kind !== 'integer' || Number.isInteger(value as number)) :
    typeof value === kind;
  if (!valid) { return [path + ': expected ' + kind]; }
  if (schema.enum !== undefined && !schema.enum.some((item: Object): boolean => canonicalValue(item) === canonicalValue(value))) {
    return [path + ': value is not in the declared enum'];
  }
  const issues: string[] = [];
  if (kind === 'string') {
    const text = value as string;
    if (schema.minLength !== undefined && text.trim().length < schema.minLength) { issues.push(path + ': string is too short'); }
    if (schema.maxLength !== undefined && text.length > schema.maxLength) { issues.push(path + ': string is too long'); }
  } else if (kind === 'number' || kind === 'integer') {
    if (schema.minimum !== undefined && (value as number) < schema.minimum) { issues.push(path + ': below minimum'); }
    if (schema.maximum !== undefined && (value as number) > schema.maximum) { issues.push(path + ': above maximum'); }
  } else if (kind === 'array') {
    const array = value as Object[];
    if (schema.minItems !== undefined && array.length < schema.minItems) { issues.push(path + ': too few items'); }
    if (schema.maxItems !== undefined && array.length > schema.maxItems) { issues.push(path + ': too many items'); }
    if (array.length > 10000) { return [path + ': too many values to validate']; }
    if (schema.items !== undefined) {
      const itemSchema = schema.items;
      for (let index = 0; index < array.length; index++) { issues.push(...checkValue(array[index], itemSchema, path + '[' + index.toString() + ']', depth + 1, budget)); }
    }
  } else if (kind === 'object') {
    const object = value as Record<string, Object>;
    const keys = Object.keys(object);
    if (keys.length > 10000) { return [path + ': too many properties']; }
    for (const key of schema.required ?? []) {
      if (Object.keys(object).indexOf(key) < 0) { issues.push(path + '.' + key + ': required'); }
    }
    for (const key of keys) {
      const property = schema.properties !== undefined && Object.keys(schema.properties).indexOf(key) >= 0 ? schema.properties[key] : undefined;
      if (property !== undefined) { issues.push(...checkValue(object[key], property, path + '.' + key, depth + 1, budget)); }
      else if (schema.additionalProperties === false) { issues.push(path + '.' + key + ': undeclared property'); }
    }
  }
  return issues;
}

export function validateSchema(value: Object | undefined | null, schema: ValueSchema): string[] {
  return checkValue(value, schema, '$', 0, { remaining: 10000 });
}

export function valueAt(data: Object | undefined, path: string): Object | undefined {
  if (path === '' || path === '$') { return data; }
  let value = data;
  for (const key of path.replace(/^\$\./, '').split('.')) {
    if (value === undefined || value === null || typeof value !== 'object') { return undefined; }
    if (Array.isArray(value)) {
      if (!/^\d+$/.test(key)) { return undefined; }
      value = (value as Object[])[Number(key)]; continue;
    }
    if (Object.keys(value).indexOf(key) < 0) { return undefined; }
    value = (value as Record<string, Object>)[key];
  }
  return value;
}

export class ToolContractCatalog {
  private declarations: Map<string, ToolContract> = new Map();
  register(name: string, contract?: ToolContract): void {
    if (contract !== undefined) {
      if (!contract.version || ['json', 'text', 'none'].indexOf(contract.inputFormat) < 0) { throw new Error('Invalid tool contract declaration'); }
      if (contract.inputSchema !== undefined) { checkDefinition(contract.inputSchema); }
      if (contract.outputSchema !== undefined) { checkDefinition(contract.outputSchema); }
      for (const fact of contract.evidenceFields ?? []) {
        if (typeof fact.path !== 'string' || fact.path.length > 256 || ['number', 'literal'].indexOf(fact.kind) < 0 || fact.required !== undefined && typeof fact.required !== 'boolean') { throw new Error('Invalid evidence declaration'); }
        if (fact.tolerance !== undefined && (!Number.isFinite(fact.tolerance) || fact.tolerance < 0) || fact.answerLabels !== undefined && (!Array.isArray(fact.answerLabels) || fact.answerLabels.some((label: string): boolean => typeof label !== 'string' || !label.length))) { throw new Error('Invalid evidence matching declaration'); }
      }
    }
    this.declarations.delete(name);
    if (contract !== undefined) { this.declarations.set(name, contract); }
  }
  get(name: string): ToolContract | undefined { return this.declarations.get(name); }
  inputFormat(name: string): 'json' | 'text' | 'none' { return this.get(name)?.inputFormat ?? 'json'; }
  cacheKey(call: ContractCall): string { return call.name + '\n' + inputKey(this.inputFormat(call.name), call.input); }
  validateOutput(name: string, data: Object | undefined): string[] {
    const contract = this.get(name);
    const issues = contract?.outputSchema === undefined ? [] : validateSchema(data, contract.outputSchema);
    for (const fact of contract?.evidenceFields ?? []) {
      const value = valueAt(data, fact.path);
      if (value === undefined && !fact.required) { continue; }
      const valid = fact.kind === 'number' ? typeof value === 'number' && Number.isFinite(value as number) :
        typeof value === 'string' || typeof value === 'number' && Number.isFinite(value as number) || typeof value === 'boolean';
      if (!valid) { issues.push('$.' + fact.path + ': missing/invalid declared evidence'); }
    }
    return issues;
  }
  evidenceText(name: string, data: Object | undefined): string {
    const facts: Record<string, Object> = {};
    for (const field of this.get(name)?.evidenceFields ?? []) {
      const value = valueAt(data, field.path);
      if (value !== undefined) { facts[field.path] = value; }
    }
    return Object.keys(facts).length > 0 ? JSON.stringify(facts) : '';
  }
  validateInput(call: ContractCall): string[] {
    const contract = this.get(call.name);
    if (contract === undefined) { return []; }
    let value: Object;
    if (this.inputFormat(call.name) === 'text') { value = call.input; }
    else {
      try { value = this.inputFormat(call.name) === 'none' && !call.input.trim().length ? ({} as Record<string, Object>) : JSON.parse(call.input) as Object; } catch (_error) { return ['input must be complete JSON']; }
      if (value === null || typeof value !== 'object' || Array.isArray(value)) { return ['input must be a JSON object']; }
    }
    const issues: string[] = contract.inputSchema === undefined ? [] : validateSchema(value, contract.inputSchema);
    if (contract?.validateInput !== undefined) {
      try { const custom = contract.validateInput(call.input); if (!Array.isArray(custom) || custom.some((issue: string): boolean => typeof issue !== 'string')) { issues.push('invalid input validator response'); } else { issues.push(...custom); } }
      catch (_error) { issues.push('contract input validation failed'); }
    }
    return issues;
  }
  recognize(task: string, anchorTime: number): ContractRequirement[] {
    const requirements: ContractRequirement[] = [];
    this.declarations.forEach((contract: ToolContract, name: string): void => {
      const discovered = contract.recognize?.(task, anchorTime) ?? [];
      const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const mention = new RegExp('(?:使用|调用|用)\\s*' + escaped + '(?![A-Za-z0-9_.-])|\\b(?:use|call|invoke)\\s+' + escaped + '(?![A-Za-z0-9_.-])', 'i');
      const explanation = /(?:如何|怎么)\s*(?:使用|调用|用)|\bhow\s+(?:to\s+)?(?:use|call|invoke)\b/i.test(task);
      if (!discovered.length && mention.test(task) && !explanation) {
        discovered.push({ tool: name, label: name, scope: { intent: 'explicit-use' } as ExplicitUseScope, anchorTime: anchorTime,
          position: Math.max(0, task.indexOf(name)), status: 'pending', output: '' });
      }
      for (const entry of discovered) {
        // Declaration ownership is authoritative, never a model/result payload.
        entry.tool = name;
        entry.status = 'pending'; entry.output = ''; entry.input = undefined; entry.data = undefined; entry.resultCallId = undefined;
        const key = name + ':' + canonicalValue(entry.scope);
        if (requirements.some((old: ContractRequirement): boolean => old.id === key)) { continue; }
        entry.id = key;
        requirements.push(entry);
      }
    });
    return requirements.sort((left: ContractRequirement, right: ContractRequirement): number => (left.position ?? 0) - (right.position ?? 0));
  }
  prepare(call: ContractCall, requirements: ContractRequirement[], task: string = ''): void {
    const prepare = this.get(call.name)?.prepareInput;
    if (prepare !== undefined) {
      const input = prepare({ name: call.name, input: call.input, callId: call.callId }, requirements.filter((entry: ContractRequirement): boolean => entry.tool === call.name && entry.expectedInput === undefined).map((entry: ContractRequirement): ContractRequirement => requirementView(entry)), task);
      if (typeof input !== 'string') { throw new Error('Invalid contract preparation response'); }
      call.input = input;
    }
  }
  matches(entry: ContractRequirement, call: ContractCall): boolean {
    if (entry.tool !== call.name) { return false; }
    if (entry.expectedInput !== undefined) { return inputKey(this.inputFormat(call.name), entry.expectedInput) === inputKey(this.inputFormat(call.name), call.input); }
    if ((entry.scope as Record<string, Object>).intent === 'explicit-use') { return true; }
    try { return this.get(call.name)?.matches?.(requirementView(entry), { name: call.name, input: call.input, callId: call.callId }) === true; } catch (_error) { return false; }
  }
  canReportDirectly(entries: ContractRequirement[]): boolean {
    return entries.length > 0 && entries.every((entry: ContractRequirement): boolean => entry.status === 'success' && this.get(entry.tool)?.finalization === 'result');
  }
  validateAnswer(entries: ContractRequirement[], answer: string, semanticReviewed: boolean = false): string[] {
    const issues: string[] = [];
    for (const entry of entries) {
      if (entry.status === 'pending') { issues.push(entry.label); continue; }
      const verify = this.get(entry.tool)?.validateAnswer;
      const reviewedHeuristic = semanticReviewed && entry.status === 'success' && this.get(entry.tool)?.answerValidation === 'heuristic';
      const scopedVerifier = verify !== undefined && entry.expectedInput === undefined && (entry.scope as Record<string, Object>).intent !== 'explicit-use';
      if (scopedVerifier && verify !== undefined && !reviewedHeuristic) {
        try { const custom = verify(requirementView(entry), answer); if (!Array.isArray(custom) || custom.some((issue: string): boolean => typeof issue !== 'string')) { issues.push(entry.label + ': invalid answer validator response'); } else { issues.push(...custom); } }
        catch (_error) { issues.push(entry.label + ': contract answer validation failed'); }
      } else if (entry.status !== 'success') { issues.push(entry.label); }
      if (entry.status === 'success') {
        let data: Object | undefined = entry.data;
        try { data = data ?? this.get(entry.tool)?.legacyData?.(entry.output); } catch (_error) { /* Typed data is handled at dispatch. */ }
        let scopedAnswer = answer;
        const scopeFields = this.get(entry.tool)?.answerScopeFields ?? [];
        if (scopeFields.length > 0) {
          const matches = (text: string, source: Object | undefined): boolean => scopeFields.every((path: string): boolean => {
            const value = valueAt(source, path); return value !== undefined && literalPresent(text, value);
          });
          scopedAnswer = answer.split(/[\n。；;，,]/).filter((text: string): boolean => matches(text, data) && !entries.some((other: ContractRequirement): boolean =>
            other.tool === entry.tool && other.resultCallId !== entry.resultCallId && canonicalValue(other.data) !== canonicalValue(data) && matches(text, other.data))).join('\n');
        }
        const numericText = scopedAnswer.replace(/(^|\n)\s*\d+(?:[.)]\s+|、\s*)/g, '$1');
        const numeric = (numericText.match(/[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?/gi) ?? []).map((value: string): number => Number(value));
        for (const fact of this.get(entry.tool)?.evidenceFields ?? []) {
          const value = valueAt(data, fact.path);
          if (fact.kind === 'number' && (fact.answerLabels ?? []).length > 0) {
            const claims: number[] = [];
            for (const label of fact.answerLabels ?? []) {
              const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
              const pattern = new RegExp(escaped + '\\s*[:：=]?\\s*([-+]?\\d+(?:\\.\\d+)?(?:e[-+]?\\d+)?)', 'gi');
              let match: RegExpExecArray | null;
              while ((match = pattern.exec(scopedAnswer)) !== null) { claims.push(Number(match[1])); }
            }
            if (fact.required && !claims.length || claims.some((claim: number): boolean => value === undefined || Math.abs(claim - Number(value)) > (fact.tolerance ?? 0))) { issues.push(entry.label); }
          } else if (fact.required && (value === undefined || !(fact.kind === 'number' ? numeric.some((claim: number): boolean => Math.abs(claim - Number(value)) <= (fact.tolerance ?? 0)) : literalPresent(scopedAnswer, value)))) { issues.push(entry.label); }
        }
      }
    }
    if (entries.length > 0 && entries.every((entry: ContractRequirement): boolean => entry.status === 'success' && this.get(entry.tool)?.restrictNumericClaims === true)) {
      const allowed: number[] = [];
      const pattern = /[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?/gi;
      for (const entry of entries) {
        for (const number of entry.output.match(pattern) ?? []) { allowed.push(Number(number)); }
        try {
          const input = JSON.parse(entry.input ?? '{}') as Object;
          for (const field of this.get(entry.tool)?.operandFields ?? []) {
            for (const number of String(valueAt(input, field) ?? '').match(pattern) ?? []) { allowed.push(Number(number)); }
          }
        } catch (_error) {
        }
      }
      const claims = answer.replace(/(^|\n)\s*\d+(?:[.)]\s+|、\s*)/g, '$1');
      if ((claims.match(pattern) ?? []).some((value: string): boolean => allowed.indexOf(Number(value)) < 0)) { issues.push('Answer contains values absent from the current inputs and returned evidence.'); }
    }
    return issues;
  }
}
