import { schemaProperties } from '../ToolContract';
import { ContractCall, ContractRequirement, ToolContract, ValueSchema } from '../ToolContract';
import { clauses, cleanRequest, requirement, queryInput, scopeOf, scopedSections, terminalIssues } from './TaskText';
export function fileContract(name: string, kind: 'read' | 'list' | 'write' | 'search' | 'skill'): ToolContract {
    const schema: ValueSchema = kind === 'skill' ? { type: 'string', minLength: 1, maxLength: 1024 } as ValueSchema : kind === 'read' ? { type: 'object', properties: schemaProperties(["relativePath", "path"], [{ type: 'string', minLength: 1 } as ValueSchema, { type: 'string', minLength: 1 } as ValueSchema]) as Record<string, ValueSchema>, anyOf: [{ type: 'object', required: ['relativePath'] } as ValueSchema, { type: 'object', required: ['path'] } as ValueSchema] } as ValueSchema :
        kind === 'write' ? { type: 'object', required: ['relativePath', 'content'], properties: schemaProperties(["relativePath", "content"], [{ type: 'string', minLength: 1 } as ValueSchema, { type: 'string', minLength: 1, maxLength: 102400 } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema :
            kind === 'search' ? { type: 'object', required: ['query'], properties: schemaProperties(["query"], [{ type: 'string', minLength: 1 } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema : { type: 'object', properties: schemaProperties(["relativePath"], [{ type: 'string' } as ValueSchema]) as Record<string, ValueSchema> } as ValueSchema;
    return { version: '1', inputFormat: kind === 'skill' ? 'text' : 'json', inputSchema: schema, outputSchema: { type: 'string' } as ValueSchema, finalization: 'synthesis',
        recognize: (task: string, anchor: number): ContractRequirement[] => {
            const entries: ContractRequirement[] = [];
            for (const raw of clauses(task)) {
                const clause = cleanRequest(raw);
                if (kind === 'list' && /^(?:列出|列一下|查看)?(?:沙盒|工作空间|文件空间)(?:里|中|里面)?(?:的)?(?:有什么|有哪些|所有)?文件$/.test(clause)) {
                    const entry = requirement(name, '', '', anchor, '文件', task);
                    entry.position = Math.max(0, task.indexOf(clause));
                    entries.push(entry);
                }
                if (kind === 'read') {
                    const file = /^(?:读取|读一下|总结|摘要|概括)\s*(?:文件\s*)?([A-Za-z0-9_./\-一-鿿]+\.(?:md|txt|csv|json))$/.exec(clause);
                    if (file !== null) {
                        entries.push(requirement(name, file[1], '', anchor, '文件', task));
                    }
                }
            }
            return entries;
        },
        matches: (entry: ContractRequirement, call: ContractCall): boolean => {
            const values = queryInput(call.input);
            return kind === 'list' ? values.relativePath === '' || values.relativePath === undefined : kind === 'read' ? values.relativePath === scopeOf(entry).entity || values.path === scopeOf(entry).entity : false;
        },
        validateAnswer: (entry: ContractRequirement, answer: string): string[] => terminalIssues(entry, scopedSections(entry, answer)),
        legacyStatus: (text: string): 'success' | 'failed' | 'empty' | 'unavailable' => {
            const value = text.trim();
            if (!value.length) {
                return 'empty';
            }
            if (kind === 'skill') {
                return /^(Unknown skill:|No skill name provided\.)/.test(value) ? 'unavailable' : 'success';
            }
            const prefix = kind === 'read' ? 'Failed to read sandbox file:' : kind === 'write' ? 'Failed to write sandbox file:' : kind === 'list' ? 'Failed to list file space:' : '文件搜索失败：';
            if (value.startsWith(prefix)) {
                return 'failed';
            }
            return kind === 'list' && /^(No files|目录为空|Directory is empty:|The workspace is empty\.)/.test(value) ? 'empty' : 'success';
        } };
}
