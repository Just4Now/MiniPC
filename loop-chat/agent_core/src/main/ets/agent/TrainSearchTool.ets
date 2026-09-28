import { AgentTool } from './AgentTool';
import { runAiphoneTool } from '../aiphone/AiphoneToolExecutor';

interface TrainRow {
  trainCode?: string;
  from?: string;
  to?: string;
  depart?: string;
  arrive?: string;
  duration?: string;
  seats?: string;
  status?: string;
}

interface SummaryValue {
  text?: string;
}

interface DataModelUpdate {
  path?: string;
  value?: Object;
}

interface ComponentNode {
  title?: string;
  body?: string;
}

interface ComponentUpdate {
  components?: ComponentNode[];
}

interface TrainEnvelope {
  updateDataModel?: DataModelUpdate;
  updateComponents?: ComponentUpdate;
}

interface QueryRequest {
  query?: string;
  prompt?: string;
}

export class TrainSearchTool implements AgentTool {
  name(): string {
    return 'train_search';
  }

  description(): string {
    return 'Queries public 12306 remaining tickets. No user login. ' +
      'Input JSON: {"query":"明天北京南到上海虹桥高铁"}. ' +
      'The query must include origin, destination, and a date.';
  }

  async run(input: string): Promise<string> {
    const query = parseQuery(input);
    if (query.length === 0) {
      return '需要出发地、目的地和日期。例如：明天北京南到上海虹桥。';
    }
    try {
      const raw = await runAiphoneTool('train.search', query, 'loop-train', 'search');
      return formatTrainResult(raw);
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      return `12306 查询失败：${message}`;
    }
  }
}

function parseQuery(input: string): string {
  const trimmed = input.trim();
  if (trimmed.startsWith('{')) {
    try {
      const request = JSON.parse(trimmed) as QueryRequest;
      const query = `${request.query ?? request.prompt ?? ''}`.trim();
      if (query.length > 0) {
        return query;
      }
    } catch (_error) {
      return trimmed;
    }
  }
  return trimmed;
}

function formatTrainResult(raw: string): string {
  const rows: TrainRow[] = [];
  let summary = '';
  let title = '';
  let body = '';
  const lines = raw.split('\n');
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index].trim();
    if (line.length === 0 || !line.startsWith('{')) {
      continue;
    }
    let envelope: TrainEnvelope;
    try {
      envelope = JSON.parse(line) as TrainEnvelope;
    } catch (_error) {
      continue;
    }
    const data = envelope.updateDataModel;
    if (data !== undefined && data.path === '/trains' && Array.isArray(data.value)) {
      const list = data.value as TrainRow[];
      for (let rowIndex = 0; rowIndex < list.length; rowIndex++) {
        rows.push(list[rowIndex]);
      }
    }
    if (data !== undefined && data.path === '/summary' && data.value !== undefined && !Array.isArray(data.value)) {
      const value = data.value as SummaryValue;
      if (typeof value.text === 'string') {
        summary = value.text;
      }
    }
    const components = envelope.updateComponents === undefined ? undefined : envelope.updateComponents.components;
    if (components !== undefined) {
      for (let componentIndex = 0; componentIndex < components.length; componentIndex++) {
        const component = components[componentIndex];
        if (typeof component.title === 'string' && component.title.length > 0) {
          title = component.title;
        }
        if (typeof component.body === 'string' && component.body.length > 0) {
          body = component.body;
        }
      }
    }
  }
  if (rows.length === 0) {
    const message = summary.length > 0 ? summary : (body.length > 0 ? body : title);
    return message.length > 0 ? message : '12306 没有返回可展示车次。';
  }
  const linesOut: string[] = [];
  if (summary.length > 0) {
    linesOut.push(summary);
  }
  for (let index = 0; index < rows.length; index++) {
    linesOut.push(formatRow(rows[index]));
  }
  return linesOut.join('\n');
}

function formatRow(row: TrainRow): string {
  const code = textOf(row.trainCode);
  const from = textOf(row.from);
  const to = textOf(row.to);
  const depart = textOf(row.depart);
  const arrive = textOf(row.arrive);
  const duration = textOf(row.duration);
  const seats = textOf(row.seats);
  const status = textOf(row.status);
  let line = `${code} ${from} ${depart} → ${to} ${arrive}`;
  if (duration.length > 0) {
    line += ` ${duration}`;
  }
  if (seats.length > 0) {
    line += ` ${seats}`;
  }
  if (status.length > 0) {
    line += ` ${status}`;
  }
  return line.trim();
}

function textOf(value: string | undefined): string {
  return value === undefined ? '' : value.trim();
}
