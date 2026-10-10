import { common } from '@kit.AbilityKit';
import { SkillSnapshot } from '../skill/SkillSnapshot';
import { LocalModel } from './LocalModel';
import { LlmProvider } from './LlmProvider';
import { OpenAiCompatibleModel } from './OpenAiCompatibleModel';
import { ScriptedLocalModel } from './ScriptedLocalModel';
import { buildLocalSessionAttributes, LlmNativeBinding, SessionBackedModel } from './SessionBackedModel';

export interface LoopModelInfo {
  model: LocalModel;
  mode: 'llm' | 'scripted' | 'local';
  modelName: string;
}

export async function createLoopModel(context: common.UIAbilityContext, skillSnapshot?: SkillSnapshot): Promise<LocalModel> {
  return (await createLoopModelInfo(context, skillSnapshot)).model;
}

export async function createLoopModelInfo(
  context: common.UIAbilityContext,
  skillSnapshot?: SkillSnapshot,
  localLlmBinding?: LlmNativeBinding
): Promise<LoopModelInfo> {
  // 本地 LLM 分支
  if (localLlmBinding !== undefined) {
    const localConfig = await LlmProvider.readLocalLlmConfig(context);
    if (localConfig.enabled) {
      return {
        model: new SessionBackedModel(localLlmBinding, {
          attributes: buildLocalSessionAttributes(localConfig.modelPath, {
            backend: localConfig.backend,
            maxContext: localConfig.maxContext
          }),
          requestType: localConfig.requestType
        }),
        mode: 'local',
        modelName: 'Qwen2.5-7B-Instruct (Gewu)'
      };
    }
  }

  // 原有逻辑: 网络 LLM 或降级脚本
  const provider = await LlmProvider.fromContext(context);
  if (provider.isConfigured()) {
    return {
      model: new OpenAiCompatibleModel(provider, skillSnapshot),
      mode: 'llm',
      modelName: provider.model
    };
  }
  return {
    model: new ScriptedLocalModel(),
    mode: 'scripted',
    modelName: 'scripted-local'
  };
}
