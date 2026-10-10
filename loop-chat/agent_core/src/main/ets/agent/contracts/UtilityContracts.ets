import { schemaProperties } from '../ToolContract';
import { ContractCall, ContractRequirement, ToolContract, ValueSchema } from '../ToolContract';
import { clauses, cleanRequest, requirement, scopedSections, terminalIssues } from './TaskText';
interface NumericOutput { value: number; }
export function utilityContract(name: string, kind: 'arithmetic' | 'conversion' | 'date'): ToolContract {
    const schema: ValueSchema = kind === 'arithmetic' ? { type: 'object', required: ['expression'], properties: schemaProperties(["expression"], [{ type: 'string', minLength: 1 } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema :
        kind === 'conversion' ? { type: 'object', required: ['value', 'from', 'to'], properties: schemaProperties(["value", "from", "to"], [{ type: 'number' } as ValueSchema, { type: 'string', minLength: 1 } as ValueSchema, { type: 'string', minLength: 1 } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema : { type: 'object', required: ['query'], properties: schemaProperties(["query"], [{ type: 'string', minLength: 1 } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema;
    const failurePrefix = kind === 'arithmetic' ? '计算失败：' : kind === 'conversion' ? '单位换算失败：' : '日期计算失败：';
    const numeric = kind !== 'date';
    return { version: '1', inputFormat: 'json', inputSchema: schema,
        outputSchema: numeric ? { type: 'object', required: ['value'], properties: schemaProperties(["value"], [{ type: 'number' } as ValueSchema]) as Record<string, ValueSchema>, additionalProperties: false } as ValueSchema : { type: 'string', minLength: 1 } as ValueSchema,
        evidenceFields: numeric ? [{ path: 'value', kind: 'number', required: true }] : [],
        operandFields: [kind === 'arithmetic' ? 'expression' : kind === 'conversion' ? 'value' : 'query'],
        restrictNumericClaims: numeric, finalization: numeric ? 'result' : 'synthesis',
        recognize: (task: string, anchor: number): ContractRequirement[] => {
            const entries: ContractRequirement[] = [];
            for (const raw of clauses(task)) {
                const clause = cleanRequest(raw), utility = /^(?:使用|调用|用)\s*([A-Za-z_][A-Za-z0-9_.-]*)(?![A-Za-z0-9_])/.exec(clause);
                if (utility !== null && utility[1] === name) {
                    entries.push(requirement(name, '', '', anchor, name, task));
                }
            }
            return entries;
        },
        matches: (_entry: ContractRequirement, _call: ContractCall): boolean => true,
        validateAnswer: (entry: ContractRequirement, answer: string): string[] => terminalIssues(entry, scopedSections(entry, answer)),
        legacyStatus: (text: string): 'success' | 'failed' | 'empty' => !text.trim().length ? 'empty' : text.startsWith(failurePrefix) ? 'failed' : 'success',
        legacyData: (text: string): Object | undefined => {
            if (!numeric) {
                return text;
            }
            const value = kind === 'conversion' ? /=[\s]*([-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?)/i.exec(text)?.[1] : (text.match(/[-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?/gi) ?? []).slice(-1)[0];
            return value === undefined ? undefined : ({ value: Number(value) } as NumericOutput);
        } };
}
