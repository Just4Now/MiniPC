import { schemaProperties } from '../ToolContract';
import { ValueSchema } from '../ToolContract';
import { ContractCall, ContractRequirement, ToolContract } from '../ToolContract';
import { clauses, cleanRequest, cleanEntity, requirement, queryOf, querySchema, scopeOf, scopedSections, terminalIssues } from './TaskText';
export function mapContract(): ToolContract {
    return { version: '1', inputFormat: 'json', inputSchema: querySchema(), outputSchema: { type: 'string', minLength: 1 } as ValueSchema, finalization: 'synthesis', answerValidation: 'heuristic',
        recognize: (task: string, anchor: number): ContractRequirement[] => {
            const entries: ContractRequirement[] = [];
            for (const raw of clauses(task)) {
                const place = /^(.{2,30}?)(?:在哪里|在哪|的位置|的地址)$/.exec(cleanRequest(raw));
                if (place !== null && !/天气|穿|查询|查一下/.test(place[1])) {
                    entries.push(requirement('map_search', place[1], '', anchor, '地点', task));
                }
            }
            return entries;
        },
        matches: (entry: ContractRequirement, call: ContractCall): boolean => cleanEntity(queryOf(call.input).replace(/在哪里|在哪|的位置|的地址/g, '')) === scopeOf(entry).entity,
        validateAnswer: (entry: ContractRequirement, answer: string): string[] => terminalIssues(entry, scopedSections(entry, answer)),
        legacyStatus: (text: string): 'success' | 'failed' | 'empty' | 'unavailable' => {
            const value = text.trim();
            if (!value.length) {
                return 'empty';
            }
            if (!value.startsWith('地图结果\n')) {
                return 'success';
            }
            const body = value.substring('地图结果\n'.length);
            if (body.startsWith('地图查询失败：')) {
                return 'failed';
            }
            if (body.startsWith('没有查到「')) {
                return 'empty';
            }
            return /^(需要一个地点|没有手机位置|还没有配置高德 Key)/.test(body) ? 'unavailable' : 'success';
        } };
}
