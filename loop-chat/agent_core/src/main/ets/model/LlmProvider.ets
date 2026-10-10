import util from '@ohos.util';
import { common } from '@kit.AbilityKit';
import {
  LocalLlmBackend,
  normalizeLocalLlmBackend,
  normalizeLocalLlmMaxContext
} from './SessionBackedModel';

interface LlmConfigJson {
  providerName?: string;
  apiKey?: string;
  baseUrl?: string;
  model?: string;
  customParametersJson?: string;
  useLocalLlm?: boolean;
  localModelPath?: string;
  localModelBackend?: string;
  localModelMaxContext?: number;
  localModelRequestType?: string;
  localBenchmarkDirect?: boolean;
  deterministicSkillRouting?: boolean;
  localCollaboration?: LocalLlmCollaborationConfigJson;
}

interface LocalLlmCollaborationConfigJson {
  enabled?: boolean;
  isMaster?: boolean;
  masterIP?: string;
  masterPort?: number;
  broadcastPort?: number;
  controlPort?: number;
}

export interface LocalLlmCollaborationConfig {
  enabled: boolean;
  isMaster: boolean;
  masterIP: string;
  masterPort: number;
  broadcastPort: number;
  controlPort: number;
}

export interface LocalLlmConfig {
  enabled: boolean;
  modelPath: string;
  backend: LocalLlmBackend;
  maxContext: number;
  requestType: string;
  benchmarkDirect: boolean;
  deterministicSkillRouting: boolean;
  collaboration: LocalLlmCollaborationConfig;
}

const DEFAULT_COLLABORATION_MASTER_PORT = 19090;
const DEFAULT_COLLABORATION_BROADCAST_PORT = 7790;
const DEFAULT_COLLABORATION_CONTROL_PORT = 19091;

export class LlmProvider {
  readonly name: string;
  readonly apiKey: string;
  readonly baseUrl: string;
  readonly model: string;
  readonly customParametersJson: string;

  constructor(name: string, apiKey: string, baseUrl: string, model: string, customParametersJson: string = '') {
    this.name = name;
    this.apiKey = apiKey;
    this.baseUrl = LlmProvider.trimTrailingSlash(baseUrl);
    this.model = model;
    this.customParametersJson = customParametersJson.trim();
  }

  isConfigured(): boolean {
    return this.apiKey.trim().length > 0
      && this.baseUrl.trim().length > 0
      && this.model.trim().length > 0;
  }

  chatCompletionsUrl(): string {
    if (this.baseUrl.endsWith('/v1/chat/completions') || this.baseUrl.endsWith('/chat/completions')) {
      return this.baseUrl;
    }
    if (this.baseUrl.endsWith('/v1')) {
      return `${this.baseUrl}/chat/completions`;
    }
    return `${this.baseUrl}/v1/chat/completions`;
  }

  static async fromContext(context: common.UIAbilityContext): Promise<LlmProvider> {
    try {
      const json = await LlmProvider.readConfigJson(context);
      return new LlmProvider(
        json?.providerName ?? '',
        json?.apiKey ?? '',
        json?.baseUrl ?? '',
        json?.model ?? '',
        json?.customParametersJson ?? ''
      );
    } catch (_error) {
      return new LlmProvider('', '', '', '');
    }
  }


  static async readUseLocalLlm(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const json = await LlmProvider.readConfigJson(context);
      return json?.useLocalLlm ?? false;
    } catch (_error) {
      return false;
    }
  }

  static async readLocalLlmConfig(context: common.UIAbilityContext): Promise<LocalLlmConfig> {
    try {
      const json = await LlmProvider.readConfigJson(context);
      return {
        enabled: json?.useLocalLlm ?? false,
        modelPath: json?.localModelPath?.trim() ?? '',
        backend: normalizeLocalLlmBackend(json?.localModelBackend),
        maxContext: normalizeLocalLlmMaxContext(json?.localModelMaxContext),
        requestType: LlmProvider.normalizeLocalRequestType(json?.localModelRequestType),
        benchmarkDirect: json?.localBenchmarkDirect ?? false,
        deterministicSkillRouting: json?.deterministicSkillRouting ?? false,
        collaboration: LlmProvider.normalizeCollaborationConfig(json?.localCollaboration)
      };
    } catch (_error) {
      return {
        enabled: false,
        modelPath: '',
        backend: normalizeLocalLlmBackend(),
        maxContext: normalizeLocalLlmMaxContext(),
        requestType: 'qwen2',
        benchmarkDirect: false,
        deterministicSkillRouting: false,
        collaboration: LlmProvider.normalizeCollaborationConfig()
      };
    }
  }

  static async readLocalModelPath(context: common.UIAbilityContext): Promise<string> {
    try {
      const json = await LlmProvider.readConfigJson(context);
      return json?.localModelPath?.trim() ?? '';
    } catch (_error) {
      return '';
    }
  }

  private static trimTrailingSlash(value: string): string {
    let trimmed = value.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  private static normalizeLocalRequestType(value?: string): string {
    const trimmed = value?.trim() ?? '';
    return trimmed.length > 0 ? trimmed : 'qwen2';
  }

  private static normalizeCollaborationConfig(
    value?: LocalLlmCollaborationConfigJson
  ): LocalLlmCollaborationConfig {
    return {
      enabled: value?.enabled ?? false,
      isMaster: value?.isMaster ?? false,
      masterIP: value?.masterIP?.trim() ?? '',
      masterPort: LlmProvider.normalizePort(value?.masterPort, DEFAULT_COLLABORATION_MASTER_PORT),
      broadcastPort: LlmProvider.normalizePort(value?.broadcastPort, DEFAULT_COLLABORATION_BROADCAST_PORT),
      controlPort: LlmProvider.normalizePort(value?.controlPort, DEFAULT_COLLABORATION_CONTROL_PORT)
    };
  }

  private static normalizePort(value: number | undefined, fallback: number): number {
    if (value === undefined || !Number.isFinite(value) || value < 1 || value > 65535) {
      return fallback;
    }
    return Math.floor(value);
  }

  private static async readConfigJson(context: common.UIAbilityContext): Promise<LlmConfigJson | null> {
    const raw = await context.resourceManager.getRawFileContent('llm_config.json');
    const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    const bytes = raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw.buffer);
    const text = decoder.decodeToString(bytes);
    return JSON.parse(text) as LlmConfigJson;
  }
}
