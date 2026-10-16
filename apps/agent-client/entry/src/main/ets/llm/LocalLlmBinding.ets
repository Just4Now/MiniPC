import type { LlmNativeBinding } from '@loop/agent-core';

/**
 * 本地 LLM 原生绑定 wrapper。
 *
 * PRODUCTION TODO: 当 libllm.so 编译好后, 此文件自动加载它。
 * 若 .so 不存在 (开发环境/Preview), 返回 null, 工厂自动回退到网络 LLM 或脚本模式。
 *
 * 生产环境替换 llm.h 后, 如果函数名变化, 修改此文件中的映射即可。
 */
let cachedBinding: LlmNativeBinding | null = null;
let probeAttempted = false;

interface SessionResultInterface {
  session: number;
  error: number;
}

interface RequestResultInterface {
  request: number;
  error: number;
}

interface LibLlmModule {
  llmCreateSession(attributes: string): SessionResultInterface;
  llmDestroySession(session: number): number;
  llmSubmitRequest(
    session: number,
    request: string,
    callback: (response: string) => void
  ): RequestResultInterface;
  llmAbortRequest(session: number, request: number): number;
  llmEnableCollaboration(info: string): number;
  llmDisableCollaboration(): number;
  llmIsCollaborationSupported(): boolean;
}

interface LibLlmImport {
  default: LibLlmModule;
}

class LocalSessionBinding implements LlmNativeBinding {
  private libLlm: LibLlmModule;

  constructor(libLlm: LibLlmModule) {
    this.libLlm = libLlm;
  }

  createSession(attributes: string): SessionResultInterface {
    return this.libLlm.llmCreateSession(attributes);
  }

  destroySession(session: number): number {
    return this.libLlm.llmDestroySession(session);
  }

  submitRequest(
    session: number,
    request: string,
    callback: (response: string) => void
  ): RequestResultInterface {
    return this.libLlm.llmSubmitRequest(session, request, callback);
  }

  abortRequest(session: number, request: number): number {
    return this.libLlm.llmAbortRequest(session, request);
  }

  enableCollaboration(info: string): number {
    return this.libLlm.llmEnableCollaboration(info);
  }

  disableCollaboration(): number {
    return this.libLlm.llmDisableCollaboration();
  }

  isCollaborationSupported(): boolean {
    return this.libLlm.llmIsCollaborationSupported();
  }
}

export async function getLocalLlmBinding(): Promise<LlmNativeBinding | null> {
  if (probeAttempted) return cachedBinding;
  probeAttempted = true;

  try {
    // AKI addons are exposed as the default export of the native module.
    const imported = await import('libllm.so') as LibLlmImport;
    cachedBinding = new LocalSessionBinding(imported.default);
    return cachedBinding;
  } catch (_error) {
    // libllm.so 不可用 (未编译/Preview 环境), 返回 null
    return null;
  }
}
