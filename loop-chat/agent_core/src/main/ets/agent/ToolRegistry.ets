import { common } from '@kit.AbilityKit';
import { ComposioConfig } from '../composio/ComposioConfig';
import { ComposioSessionClient } from '../composio/ComposioSessionClient';
import { ComposioTool } from '../composio/ComposioTool';
import { SandboxFileWriteTool } from '../file/SandboxFileWriteTool';
import { SandboxFileReadTool } from '../file/SandboxFileReadTool';
import { SandboxListTool } from '../file/SandboxDirectoryTools';
import { ModelScopeConfig } from '../modelscope/ModelScopeConfig';
import { ModelScopeDirectClient } from '../modelscope/ModelScopeDirectClient';
import { ModelScopeTool } from '../modelscope/ModelScopeTool';
import { SkillReadTool } from '../skill/SkillReadTool';
import { SkillSnapshot } from '../skill/SkillSnapshot';
import { AgentTool } from './AgentTool';
import { TrainSearchTool } from './TrainSearchTool';

export type ToolRegistryCloseHandler = () => Promise<void>;

function briefToolLine(tool: AgentTool): string {
  if (tool.name() === 'list_sandbox_files') {
    return 'List workspace files. Input {"relativePath":""} for the root.';
  }
  if (tool.name() === 'read_sandbox_file') {
    return 'Read one workspace md, txt, json, or csv. Input {"relativePath":"name.md"}.';
  }
  if (tool.name() === 'train_search') {
    return 'Query 12306 tickets. Input {"query":"明天北京南到上海虹桥高铁"}. Needs origin, destination, and date.';
  }
  const text = tool.description().replace(/\s+/g, ' ').trim();
  return text.length > 72 ? text.substring(0, 72) : text;
}

class TimeTool implements AgentTool {
  name(): string {
    return 'time';
  }

  description(): string {
    return 'Returns the device\'s local date and time.';
  }

  async run(_input: string): Promise<string> {
    return new Date().toLocaleString();
  }
}

export class ToolRegistry {
  private tools: Map<string, AgentTool> = new Map();
  private closeHandlers: ToolRegistryCloseHandler[] = [];

  constructor() {
    this.register(new TimeTool());
  }

  register(tool: AgentTool): void {
    this.tools.set(tool.name(), tool);
  }

  has(name: string): boolean {
    return this.tools.has(name);
  }

  registerCloseHandler(handler: ToolRegistryCloseHandler): void {
    this.closeHandlers.push(handler);
  }

  describeToolsBrief(): string {
    let description = '';
    this.tools.forEach((tool: AgentTool) => {
      description += `- ${tool.name()}: ${briefToolLine(tool)}\n`;
    });
    return description;
  }

  describeTools(): string {
    let description = 'Tool-call format (required):\n';
    description += 'Execution: serial\n';
    description += 'Action: exact_tool_name[<input>]\n';
    description += 'Execution must contain only serial or parallel; put every tool call on an Action line. ';
    description += 'When a tool requires Input JSON, place exactly one JSON object inside the Action brackets, ';
    description += 'without an extra array or an input: label. Required string fields must not be empty.\n';
    description += 'Available tools:\n';
    this.tools.forEach((tool: AgentTool) => {
      description += `- ${tool.name()}: ${tool.description()}\n`;
    });
    return description;
  }

  async run(name: string, input: string): Promise<string> {
    const tool = this.tools.get(name);
    if (tool === undefined) {
      return `Unknown tool: ${name}`;
    }
    return await tool.run(input ?? '');
  }

  async close(): Promise<void> {
    for (let index = 0; index < this.closeHandlers.length; index++) {
      try {
        await this.closeHandlers[index]();
      } catch (_error) {
      }
    }
  }
}

export async function createConfiguredLoopToolRegistry(
  context: common.UIAbilityContext,
  skillSnapshot?: SkillSnapshot | null
): Promise<ToolRegistry> {
  const registry = createLoopToolRegistry(skillSnapshot);
  registry.register(new SandboxFileReadTool(context));
  registry.register(new SandboxListTool(context));
  registry.register(new TrainSearchTool());
  if (skillSnapshot !== undefined && skillSnapshot !== null && !skillSnapshot.isEmpty()) {
    registry.register(new SandboxFileWriteTool(context));
  }
  const client = new ComposioSessionClient(await ComposioConfig.fromContext(context));
  await client.initialize();
  registry.register(new ComposioTool(client));
  registry.registerCloseHandler(async (): Promise<void> => client.close());
  const modelScopeConfig = await ModelScopeConfig.fromContext(context);
  const modelScopeClient = new ModelScopeDirectClient(modelScopeConfig);
  await modelScopeClient.initialize();
  registry.register(new ModelScopeTool(modelScopeClient));
  return registry;
}

export function createLoopToolRegistry(skillSnapshot?: SkillSnapshot | null): ToolRegistry {
  const registry = new ToolRegistry();
  if (skillSnapshot !== undefined && skillSnapshot !== null && !skillSnapshot.isEmpty()) {
    registry.register(new SkillReadTool(skillSnapshot));
  }
  return registry;
}
