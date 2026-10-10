import { schemaProperties } from '../ToolContract';
import { ValueSchema } from '../ToolContract';
import { ContractCall, ContractRequirement, ToolContract } from '../ToolContract';
import { clauses, cleanRequest, cleanEntity, dates, normalizeDate, requirement, queryInput, queryOf, scopeOf, scopedSections, terminalIssues, metricToken } from './TaskText';
import { querySchema } from './TaskText';
export function weatherContract(kind: 'weather' | 'air'): ToolContract {
    const name = kind === 'weather' ? 'weather_search' : 'air_quality';
    return { version: '1', inputFormat: 'json', inputSchema: querySchema(), outputSchema: { type: 'string', minLength: 1 } as ValueSchema, finalization: 'synthesis', answerValidation: 'heuristic',
        recognize: (task: string, anchor: number): ContractRequirement[] => {
            const entries: ContractRequirement[] = [];
            const scopedTask = task.replace(/(天气|空气质量|空气|AQI|PM2\.5)(?:和|与|及)(?=[^和与及，。；;]{2,30}(?:天气|空气质量|空气|AQI|PM2\.5))/gi, '$1；');
            for (const raw of clauses(scopedTask)) {
                const match = /^(.*?)(天气|空气质量|空气|AQI|PM2\.5)((?:和|与|及)?(?:天气|空气质量|空气|AQI|PM2\.5))?(?:怎么样|如何|情况)?(?:要穿.*|穿什么.*|怎么穿.*|需要穿.*|适合穿.*)?$/i.exec(cleanRequest(raw));
                if (match === null) {
                    continue;
                }
                const categories = match[2] + (match[3] ?? '');
                if (!(kind === 'weather' ? categories.indexOf('天气') >= 0 : /空气|AQI|PM2\.5/i.test(categories))) {
                    continue;
                }
                const prefix = match[1].replace(/的$/, '');
                let pairs = prefix.split(/和|与|、|及/);
                const entities = pairs.map((pair: string): string => cleanEntity(pair.replace(/\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天/g, ''))).filter((entity: string): boolean => entity.length > 0);
                if (entities.length === 1 && pairs.length > 1) {
                    pairs = pairs.map((pair: string): string => dates(pair).length > 0 && cleanEntity(pair.replace(/\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天/g, '')).length === 0 ? entities[0] + pair : pair);
                }
                const leadingDate = /^(\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天)/.exec(prefix);
                for (const pair of pairs) {
                    const ds = dates(pair);
                    const entity = cleanEntity(pair.replace(/\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天/g, ''));
                    if (!/^[一-鿿]{2,8}(?:市)?$/.test(entity) || /天气|空气|怎么|喜欢|觉得|心情|如果|聊|什么|哪里/.test(entity)) {
                        continue;
                    }
                    for (const date of ds.length > 0 ? ds : [leadingDate === null ? '' : leadingDate[1]]) {
                        const entry = requirement(name, entity, date, anchor, kind === 'weather' ? '天气' : '空气质量', task);
                        entries.push(entry);
                    }
                }
            }
            return entries;
        },
        prepareInput: (call: ContractCall, entries: ContractRequirement[]): string => {
            const values = queryInput(call.input), query = queryOf(call.input);
            const context = typeof values.context === 'string' ? values.context as string : '';
            const city = cleanEntity(query.replace(/\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天|天气|空气质量|空气|AQI|PM2\.5|怎么样|如何/gi, '')).replace(/市$/, '');
            const candidates = entries.filter((entry: ContractRequirement): boolean => entry.expectedInput === undefined && scopeOf(entry).date.length > 0 && scopeOf(entry).entity.replace(/市$/, '') === city);
            if (candidates.length !== 1 || dates(query).length > 0 || dates(context).length > 0) { return call.input; }
            values.context = (context.length > 0 ? context + ' ' : '') + scopeOf(candidates[0]).date;
            return JSON.stringify(values);
        },
        matches: (entry: ContractRequirement, call: ContractCall): boolean => {
            const values = queryInput(call.input), query = queryOf(call.input), scope = scopeOf(entry);
            const context = typeof values.context === 'string' ? values.context as string : '';
            const ds = (dates(query).length > 0 ? dates(query) : dates(context)).map((date: string): string => normalizeDate(date, entry.anchorTime));
            const city = cleanEntity(query.replace(/\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天|天气|空气质量|空气|AQI|PM2\.5|怎么样|如何/gi, ''));
            return city.replace(/市$/, '') === scope.entity.replace(/市$/, '') && ds.length <= 1 &&
                (scope.date.length === 0 || ds.length === 1 && ds[0] === normalizeDate(scope.date, entry.anchorTime));
        },
        validateAnswer: (entry: ContractRequirement, answer: string): string[] => {
            const marker = kind === 'weather' ? /天气|晴|雨|阴|云|雪|温|°C|℃|穿衣|衣服|建议|体感|出行|注意|适合|怎么样|如何/ : /空气|AQI|PM2\.5/i;
            const selected = scopedSections(entry, answer, marker), terminal = terminalIssues(entry, selected);
            if (terminal.length > 0 || entry.status !== 'success') {
                return terminal;
            }
            const pattern = kind === 'weather' ? /-?\d+(?:\.\d+)?\s*(?:°C|℃)/gi : /(?:AQI|PM2\.5)\s*[:：]?\s*\d+(?:\.\d+)?/gi;
            const evidence = (entry.output.match(pattern) ?? []).map((value: string): string => metricToken(value));
            return (selected.join('\n').match(pattern) ?? []).some((value: string): boolean => evidence.indexOf(metricToken(value)) < 0) ? [entry.label] : [];
        },
        legacyStatus: (text: string): 'success' | 'failed' | 'empty' | 'unavailable' => {
            const value = text.trim(), header = kind === 'weather' ? '天气结果\n' : '空气结果\n';
            if (!value.length) {
                return 'empty';
            }
            if (!value.startsWith(header)) {
                return 'success';
            }
            const body = value.substring(header.length);
            if (/^(天气|空气质量)查询失败：/.test(body)) {
                return 'failed';
            }
            if (body.startsWith('没有查到「')) {
                return 'empty';
            }
            return /^(需要一个城市|空气质量工具仅支持当前值)/.test(body) ? 'unavailable' : 'success';
        } };
}
