import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import url from '@ohos.url';

const MODELSCOPE_CONFIG_RAWFILE: string = 'modelscope_config.json';

interface ModelScopeConfigJson {
  mode?: string;
  modelscopeToken?: string;
  modelScopeToken?: string;
  token?: string;
  modelscopeApiBaseUrl?: string;
  modelScopeApiBaseUrl?: string;
}

export class ModelScopeConfig {
  readonly mode: string;
  readonly modelscopeToken: string;
  readonly modelscopeApiBaseUrl: string;

  constructor(
    mode: string,
    modelscopeToken: string,
    modelscopeApiBaseUrl: string
  ) {
    this.mode = mode.trim().toLowerCase();
    this.modelscopeToken = modelscopeToken.trim();
    this.modelscopeApiBaseUrl = ModelScopeConfig.trimTrailingSlash(modelscopeApiBaseUrl.length > 0 ? modelscopeApiBaseUrl : 'https://modelscope.cn');
  }

  isConfigured(): boolean {
    return this.modelscopeToken.length > 0 && ModelScopeConfig.isValidBaseUrl(this.modelscopeApiBaseUrl);
  }

  isDirectMode(): boolean {
    return true;
  }

  missingConfiguration(): string {
    const missing: string[] = [];
    if (this.modelscopeToken.length === 0) {
      missing.push('modelscopeToken');
    }
    if (!ModelScopeConfig.isValidBaseUrl(this.modelscopeApiBaseUrl)) {
      missing.push('modelscopeApiBaseUrl');
    }
    return missing.join(', ');
  }

  private static isValidBaseUrl(value: string): boolean {
    const trimmed = value.trim();
    if (!/^https?:\/\/[^/?#]+/i.test(trimmed) || /[\s\\]/.test(trimmed)) return false;
    try {
      const parsed = new url.URL(trimmed);
      return (parsed.protocol === 'http:' || parsed.protocol === 'https:') &&
        parsed.hostname.length > 0 && parsed.username.length === 0 &&
        parsed.password.length === 0 && trimmed.indexOf('?') < 0 && trimmed.indexOf('#') < 0;
    } catch (_error) {
      return false;
    }
  }

  static async fromContext(context: common.UIAbilityContext): Promise<ModelScopeConfig> {
    try {
      const raw = await context.resourceManager.getRawFileContent(MODELSCOPE_CONFIG_RAWFILE);
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const bytes = raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw.buffer);
      const parsed = JSON.parse(decoder.decodeToString(bytes)) as ModelScopeConfigJson;
      return new ModelScopeConfig(
        parsed.mode ?? '',
        parsed.modelscopeToken ?? parsed.modelScopeToken ?? parsed.token ?? '',
        parsed.modelscopeApiBaseUrl ?? parsed.modelScopeApiBaseUrl ?? 'https://modelscope.cn'
      );
    } catch (_error) {
      return new ModelScopeConfig('', '', 'https://modelscope.cn');
    }
  }

  private static trimTrailingSlash(value: string): string {
    let result = value.trim();
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
