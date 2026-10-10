import { schemaProperties } from '../ToolContract';
import { ValueSchema } from '../ToolContract';
import { ContractCall, ContractRequirement, ToolContract } from '../ToolContract';
import { clauses, cleanRequest, dates, normalizeDate, queryInput, queryOf, querySchema, requirement, scopeOf, scopedSections, sections, terminalIssues } from './TaskText';

function clockPattern(): RegExp {
    return /(?:凌晨|早上|上午|中午|下午|傍晚|晚上|夜间)?\s*(?:\d{1,2}|[零一二三四五六七八九十两]{1,3})(?:[点时](?:半|\d{1,2}分?)?|[:：]\d{2})(?:左右|前后|附近|大约|大概|上下|之前|以前|前|之后|以后|后|起)?/;
}
function clockKey(text: string): number {
    const parts = /(凌晨|早上|上午|中午|下午|傍晚|晚上|夜间)?\s*(\d{1,2}|[零一二三四五六七八九十两]{1,3})/.exec(text);
    if (parts === null) { return -1; }
    const token = parts[2], digits = '零一二三四五六七八九';
    let hour = Number(token);
    if (!Number.isFinite(hour)) {
        if (token === '两') { hour = 2; }
        else if (token.indexOf('十') >= 0) {
            const pair = token.split('十');
            hour = (pair[0].length ? digits.indexOf(pair[0]) : 1) * 10 + (pair[1].length ? digits.indexOf(pair[1]) : 0);
        } else { hour = digits.indexOf(token); }
    }
    if (/下午|晚上|傍晚/.test(parts[1] ?? '') && hour >= 1 && hour <= 11) { hour += 12; }
    if (parts[1] === '中午' && hour >= 1 && hour <= 10) { hour += 12; }
    const minutePart = /[:：](\d{2})|[点时](半|\d{1,2})/.exec(text);
    const minute = minutePart === null ? 0 : minutePart[2] === '半' ? 30 : Number(minutePart[1] ?? minutePart[2]);
    return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 ? hour * 60 + minute : -1;
}
export function trainContract(): ToolContract {
    return { version: '1', inputFormat: 'json', inputSchema: querySchema(), outputSchema: { type: 'string', minLength: 1 } as ValueSchema, finalization: 'synthesis', answerValidation: 'heuristic',
        recognize: (task: string, anchor: number): ContractRequirement[] => {
            const entries: ContractRequirement[] = [];
            for (const raw of clauses(task)) {
                const clause = cleanRequest(raw);
                const route = /^(今天|明天|后天|大后天|\d{4}-\d{2}-\d{2})?(?:(?:早上|上午|中午|下午|晚上|凌晨)?\s*\d{1,2}(?:[点时](?:半|\d{1,2}分?)?|[:：]\d{2})(?:左右|前后|附近|大约|大概|上下)?\s*)?从?([一-鿿]{2,8})到([一-鿿]{2,8}?)(?:的)?(?:高铁|动车|火车|车票|车次)(?:票)?$/.exec(clause);
                if (route === null) {
                    continue;
                }
                const window = /(?:早上|上午|中午|下午|晚上|凌晨)?\s*\d{1,2}(?:[点时](?:半|\d{1,2}分?)?|[:：]\d{2})(?:左右|前后|附近|大约|大概|上下)/.exec(clause);
                const entry = requirement('train_search', route[2] + '到' + route[3], route[1] ?? '', anchor, '车次', task, window === null ? '' : window[0].trim());
                scopeOf(entry).trainType = /高铁/.test(clause) ? '高铁' : /动车/.test(clause) ? '动车' : '';
                entries.push(entry);
            }
            return entries;
        },
        prepareInput: (call: ContractCall, entries: ContractRequirement[], task: string = ''): string => {
            const values = queryInput(call.input), key = typeof values.query === 'string' ? 'query' : 'prompt', query = queryOf(call.input), ds = dates(query);
            const candidates = entries.filter((entry: ContractRequirement): boolean => {
                const scope = scopeOf(entry), route = scope.entity.split('到');
                return (scope.timeWindow.length > 0 || (scope.trainType ?? '').length > 0) && query.indexOf(route[0]) >= 0 && query.indexOf(route[1]) > query.indexOf(route[0]) &&
                    (scope.date.length === 0 || ds.length === 1 && normalizeDate(ds[0], entry.anchorTime) === normalizeDate(scope.date, entry.anchorTime));
            });
            if (candidates.length > 1) {
                return call.input;
            }
            let window = candidates.length === 1 ? scopeOf(candidates[0]).timeWindow : '';
            const trainType = candidates.length === 1 ? scopeOf(candidates[0]).trainType ?? '' : '';
            // The model may shorten an operator even when the hour is correct.
            // Consult immutable caller context only for one unambiguous rail
            // clock matching the proposed clock; unrelated/multiple clocks do
            // not acquire authority over this call.
            if (!window.length && !entries.some((entry: ContractRequirement): boolean => entry.expectedInput !== undefined)) {
                const proposed = clockPattern().exec(query);
                const requested: string[] = [];
                for (const clause of clauses(task)) {
                    if (!/高铁|动车|列车|火车|车次|车票/.test(clause) || /不|勿|免|排除|避免|除外/.test(clause)) { continue; }
                    const found = clockPattern().exec(clause);
                    if (found !== null && /左右|前后|附近|大约|大概|上下|之前|以前|前|之后|以后|后|起/.test(found[0]) && requested.indexOf(found[0]) < 0) { requested.push(found[0]); }
                }
                const railKinds = task.match(/高铁|动车|列车|火车/g) ?? [];
                const sameClock = proposed !== null && clockKey(proposed[0]) >= 0 && clockKey(proposed[0]) === clockKey(requested[0] ?? '');
                if (requested.length === 1 && (sameClock || proposed === null && railKinds.length === 1)) { window = requested[0]; }
            }
            if (!window.length && !trainType.length) { return call.input; }
            let prepared = query;
            if (trainType.length > 0 && !/高铁|动车|普快|普通列车/.test(prepared)) { prepared += ' ' + trainType; }
            const clock = clockPattern();
            if (window.length > 0 && prepared.indexOf(window) < 0) { prepared = clock.test(prepared) ? prepared.replace(clock, window) : prepared + ' ' + window; }
            values[key] = prepared;
            return JSON.stringify(values);
        },
        matches: (entry: ContractRequirement, call: ContractCall): boolean => {
            const values = queryInput(call.input), query = queryOf(call.input), scope = scopeOf(entry), route = scope.entity.split('到');
            const context = typeof values.context === 'string' ? values.context as string : '';
            const ds = (dates(query).length > 0 ? dates(query) : dates(context)).map((date: string): string => normalizeDate(date, entry.anchorTime));
            return query.indexOf(route[0]) >= 0 && query.indexOf(route[1]) > query.indexOf(route[0]) &&
                (scope.date.length === 0 || ds.length === 1 && ds[0] === normalizeDate(scope.date, entry.anchorTime)) &&
                (!(scope.trainType ?? '').length || query.indexOf(scope.trainType ?? '') >= 0) &&
                (!scope.timeWindow.length || query.indexOf(scope.timeWindow) >= 0);
        },
        validateAnswer: (entry: ContractRequirement, answer: string): string[] => {
            const selected = scopedSections(entry, answer, undefined, true), terminal = terminalIssues(entry, selected);
            if (terminal.length > 0 || entry.status !== 'success') {
                return terminal;
            }
            const all = sections(answer), claims = selected.slice();
            for (let cursor = 0; cursor < all.length; cursor++) {
                if (selected.indexOf(all[cursor]) < 0) {
                    continue;
                }
                for (let next = cursor + 1; next < all.length; next++) {
                    if (!/^\s*(?:\d+[.)、]\s*)?[GDCZTK]\d{1,4}\b/i.test(all[next])) {
                        break;
                    }
                    claims.push(all[next]);
                }
            }
            const evidence = (entry.output.match(/[GDCZTK]\d{1,4}/gi) ?? []).map((value: string): string => value.toLowerCase());
            const text = claims.join('\n');
            if (scopeOf(entry).timeWindow.length > 0 && /(?:没有|无|未找到|未查到)[^。\n]*车次/.test(entry.output) && /最接近|最近/.test(entry.output)) {
                if (!/没有|无出发|无车次|未找到|未查到/.test(text) || /[GDCZTK]\d{1,4}/i.test(text) && !/最接近|最近|替代|参考|窗口外|较早|提前/.test(text)) { return [entry.label + ': 时间窗内没有车次，返回的车次仅为最近替代']; }
            }
            return (text.match(/[GDCZTK]\d{1,4}/gi) ?? []).some((value: string): boolean => evidence.indexOf(value.toLowerCase()) < 0) ? [entry.label] : [];
        },
        legacyStatus: (text: string): 'success' | 'failed' | 'empty' | 'unavailable' => {
            const value = text.trim();
            if (!value.length || value === '12306 没有返回可展示车次。') {
                return 'empty';
            }
            if (value.startsWith('12306 查询失败：')) {
                return 'failed';
            }
            return value.startsWith('需要出发地、目的地和日期。') ? 'unavailable' : 'success';
        } };
}
