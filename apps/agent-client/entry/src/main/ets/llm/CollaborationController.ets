import { hilog } from '@kit.PerformanceAnalysisKit';
import process from '@ohos.process';
import { LlmNativeBinding, SessionBackedModel } from '@loop/agent-core';
import { CollaborationBroadcaster, CollabMessageListener } from './CollaborationBroadcaster';
import {
  CollaborationConnectionState,
  CollaborationControlChannel,
  CollaborationControlListener
} from './CollaborationControlChannel';

const DOMAIN = 0x0000;
const TAG = 'CollabController';
const GEWU_OK = 0;
const GEWU_ALREADY_ACTIVE = 401;
const CONTROL_CONNECTION_READY_TIMEOUT_MS = 60000;
const SESSION_READY_TIMEOUT_MS = 45000;
const RUNTIME_READY_TIMEOUT_MS = 15000;
const GEWU_SESSION_STABILIZE_MS = 1500;
const MASTER_NATIVE_LISTENER_STABILIZE_MS = 3000;
// A cold one-token probe still performs a full Prefill. The locked Mate 70
// pair has measured 21-23 s cold Prefill, so a 20 s health deadline aborts a
// healthy exchange just before completion. This deadline applies only to the
// readiness probe; user Prefill/Decode remain unbounded.
const COLLABORATION_PROBE_TIMEOUT_MS = 60000;
const COLLABORATION_PAIR_ATTEMPTS = 3;
const COLLABORATION_PROBE_DRAIN_MS = 2000;
const COLLABORATION_REQUEST_DRAIN_MS = 2000;
// A cold probe pair needs the longest guard while Gewu wires its co-session
// transport. The formal pair reuses the already-loaded model/data plane and
// only needs a short confirmation guard.
const PROBE_CO_SESSION_CONFIRM_DELAY_MS = 6000;
const FORMAL_CO_SESSION_CONFIRM_DELAY_MS = 1000;
const COLLABORATOR_SESSION_ATTEMPTS = 3;
const COLLABORATOR_SESSION_RETRY_MS = 750;
const SESSION_END_ACK_TIMEOUT_MS = 6000;
const SESSION_DRAIN_DELAY_MS = 1500;
const SESSION_RESTART_GUARD_MS = 2000;

export type CollaborationStatus = 'disabled' | 'connecting' | 'connected' | 'preparing' | 'ready' |
  'disconnected' | 'error';
export type CollaborationStatusListener = (status: CollaborationStatus, detail: string) => void;

export interface CollaborationControllerOptions {
  collaborationInfo: string;
  sessionAttributes: string;
  collaboratorSessionAttributes: (caller: number) => string | undefined;
  requestType: string;
  broadcastPort: number;
  masterIP: string;
  masterPort: number;
  controlPort: number;
  isMaster: boolean;
  inferenceResponseListener?: (response: string, requestId: number) => void;
}

/** Aligns the PR #1 lifecycle with the real Gewu collaboration API. */
export class CollaborationController {
  private binding: LlmNativeBinding;
  private model: SessionBackedModel;
  private broadcaster: CollaborationBroadcaster;
  private controlChannel: CollaborationControlChannel;
  private collaborationInfo: string;
  private sessionAttributes: string;
  private collaboratorSessionAttributes: (caller: number) => string | undefined;
  private requestType: string;
  private isMaster: boolean;
  private inferenceResponseListener: ((response: string, requestId: number) => void) | null;
  private currentMasterPort: number;
  private collaborationEnabled = false;
  private nativeCollaborationEnabled = false;
  private nativeEnablePromise: Promise<boolean> | null = null;
  private sessionPrepared = false;
  private sessionProbeVerified = false;
  private collaboratorReady = false;
  private collaboratorCaller: number | null = null;
  private connectionState: CollaborationConnectionState = 'disconnected';
  private status: CollaborationStatus = 'disabled';
  private statusDetail = '协同未启用';
  private statusListener: CollaborationStatusListener | null = null;
  private readyResolver: ((ready: boolean) => void) | null = null;
  private readyTimer = -1;
  private runtimeReadyResolver: ((ready: boolean) => void) | null = null;
  private runtimeReadyTimer = -1;
  private sessionRequested = false;
  private readinessPromise: Promise<boolean> | null = null;
  private masterSessionPromise: Promise<boolean> | null = null;
  private clearRestartPromise: Promise<void> | null = null;
  private collaboratorRuntimePreparationCaller: number | null = null;
  private collaboratorRuntimePreparationGeneration = 0;
  private collaboratorRuntimeReadyGeneration = 0;
  private collaboratorPreparationCaller: number | null = null;
  private collaboratorPreparationGeneration = 0;
  private collaboratorEndingGeneration = 0;
  private lifecycleGeneration = 0;
  private activeSessionGeneration = 0;
  private resourceTableReady = false;
  private sessionTeardownPromise: Promise<void> | null = null;
  private sessionEndedResolver: ((ended: boolean) => void) | null = null;
  private sessionEndedTimer = -1;
  private pendingSessionEndGeneration = 0;

  constructor(binding: LlmNativeBinding, options: CollaborationControllerOptions) {
    this.binding = binding;
    this.currentMasterPort = options.masterPort;
    this.collaborationInfo = options.collaborationInfo;
    this.sessionAttributes = options.sessionAttributes;
    this.collaboratorSessionAttributes = options.collaboratorSessionAttributes;
    this.requestType = options.requestType;
    this.isMaster = options.isMaster;
    this.inferenceResponseListener = options.inferenceResponseListener ?? null;
    this.model = this.createModel(this.sessionAttributes);
    this.broadcaster = new CollaborationBroadcaster(options.broadcastPort);
    this.broadcaster.setMessageListener(this.onRemoteMessage);
    this.controlChannel = new CollaborationControlChannel({
      isMaster: options.isMaster,
      masterIP: options.masterIP,
      controlPort: options.controlPort
    });
    this.controlChannel.setMessageListener(this.onControlMessage);
    this.controlChannel.setConnectionStateListener(this.onConnectionStateChanged);
  }

  getModel(): SessionBackedModel {
    return this.model;
  }

  isActive(): boolean {
    return this.collaborationEnabled;
  }

  isMasterDevice(): boolean {
    return this.isMaster;
  }

  setStatusListener(listener: CollaborationStatusListener): void {
    this.statusListener = listener;
    listener(this.status, this.statusDetail);
  }

  async reconnect(): Promise<void> {
    if (!this.collaborationEnabled) {
      this.setStatus('error', 'Gewu 协同尚未启用');
      return;
    }
    this.resolveReady(false);
    this.resourceTableReady = false;
    this.beginSessionTeardown();
    await this.waitForSessionTeardown();
    this.setStatus('connecting', this.isMaster ? '正在等待协作者连接' : '正在连接主机');
    try {
      await this.controlChannel.stop();
      await this.controlChannel.start();
      await this.broadcaster.broadcastHello();
    } catch (error) {
      this.setStatus('error', `重连失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  async init(): Promise<boolean> {
    if (this.collaborationEnabled) {
      return true;
    }
    if (!this.binding.isCollaborationSupported()) {
      hilog.warn(DOMAIN, TAG, 'Gewu collaboration symbols are unavailable');
      this.setStatus('error', '当前系统缺少 Gewu 协同接口');
      return false;
    }
    try {
      this.setStatus('connecting', '正在初始化 Gewu 协同');
      // The master owns the native listener and must bring it up first. A
      // collaborator may be opened earlier, but it must not start Gewu's
      // native client against an absent master: that connection can look
      // recovered later while its first tensor transfer remains stuck. Keep
      // the app control channel retrying, then activate the collaborator's
      // native data plane only after the master is actually reachable.
      if (this.isMaster) {
        await this.ensureNativeCollaborationEnabled();
        // Do not expose the application control listener until Gewu's master
        // listener has had time to enter its receive loop. Otherwise a
        // collaborator opened first can observe an application handshake and
        // start its native client while the master data plane is still coming
        // up, leaving the first tensor transfer permanently stalled.
        await this.delay(MASTER_NATIVE_LISTENER_STABILIZE_MS);
      }
      await this.broadcaster.start();
      this.collaborationEnabled = true;
      await this.controlChannel.start();
      if (!this.isMaster && this.controlChannel.isConnected()) {
        await this.ensureNativeCollaborationEnabled();
      }
      hilog.info(DOMAIN, TAG, `control enabled role=${this.isMaster ? 'master' : 'collaborator'}`);
      await this.broadcaster.broadcastHello();
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'init failed: %{public}s',
        error instanceof Error ? error.message : String(error));
      await this.controlChannel.stop();
      await this.broadcaster.stop();
      this.collaborationEnabled = false;
      this.setStatus('error', `协同初始化失败：${error instanceof Error ? error.message : String(error)}`);
      return false;
    }
  }

  async ensureReadyForInference(timeoutMs: number = SESSION_READY_TIMEOUT_MS): Promise<boolean> {
    if (!this.collaborationEnabled || !this.isMaster) {
      return false;
    }
    this.sessionRequested = true;
    const clearRestart = this.clearRestartPromise;
    if (clearRestart !== null) {
      await clearRestart;
    }
    if (this.controlChannel.isConnected() && this.sessionPrepared && this.collaboratorReady && this.sessionProbeVerified &&
      this.sessionTeardownPromise === null) {
      return true;
    }
    if (this.readinessPromise !== null) {
      return await this.readinessPromise;
    }
    const pending = this.ensureReadyForInferenceInternal(timeoutMs);
    this.readinessPromise = pending;
    try {
      return await pending;
    } finally {
      if (this.readinessPromise === pending) {
        this.readinessPromise = null;
      }
    }
  }

  /**
   * Prepare and verify the next paired session without blocking the UI.
   * Calls are coalesced with send-time readiness so only one pair is created.
   */
  prewarmSession(): void {
    if (!this.collaborationEnabled || !this.isMaster) {
      return;
    }
    this.sessionRequested = true;
    this.ensureReadyForInference().then((ready: boolean): void => {
      if (ready) {
        hilog.info(DOMAIN, TAG, 'paired session prewarm completed');
      }
    }).catch((error: Error): void => {
      hilog.warn(DOMAIN, TAG, 'paired session prewarm failed: %{public}s', error.message);
    });
  }

  private async ensureReadyForInferenceInternal(timeoutMs: number): Promise<boolean> {
    await this.waitForSessionTeardown();
    if (!this.collaborationEnabled || !this.isMaster) {
      return false;
    }
    if (!this.controlChannel.isConnected()) {
      this.setStatus('connecting', '正在自动等待协作者连接');
      if (!await this.waitForAutomaticConnection(CONTROL_CONNECTION_READY_TIMEOUT_MS)) {
        this.setStatus('disconnected', '自动连接尚未完成，已阻止单机冒充协同');
        return false;
      }
    }
    for (let attempt = 1; attempt <= COLLABORATION_PAIR_ATTEMPTS; attempt += 1) {
      if (!await this.preparePairedSession(timeoutMs, true)) {
        return false;
      }
      if (this.sessionProbeVerified) {
        return true;
      }
      this.setStatus('preparing', `正在验证协同数据面（${attempt}/${COLLABORATION_PAIR_ATTEMPTS}）`);
      if (await this.model.probeSession(COLLABORATION_PROBE_TIMEOUT_MS)) {
        // Gewu reports finish_reason before all native request/callback cleanup
        // has left the session thread. Submitting the real request immediately
        // can block inside session teardown even though the probe was healthy,
        // so drain that completed probe first.
        await this.delay(COLLABORATION_PROBE_DRAIN_MS);
        // The health probe writes "ping" into the native Session KV cache.
        // Retire the proven pair on both devices without destroying its native
        // Sessions, then create an unprobed pair for the real conversation.
        // resourceTableReady remains true after the successful session_ready,
        // so the formal pair reuses the verified Gewu resource mapping.
        this.setStatus('preparing', '协同探针通过，正在创建正式会话');
        this.beginSessionTeardown();
        await this.waitForSessionTeardown();
        if (!this.controlChannel.isConnected()) {
          this.setStatus('disconnected', '探针通过，但正式会话创建前连接已断开');
          return false;
        }
        if (!await this.preparePairedSession(timeoutMs, false)) {
          this.setStatus('error', '探针通过，但正式协同会话创建失败');
          return false;
        }
        this.sessionProbeVerified = true;
        this.setStatus('ready', '协同会话已验证，可以发送');
        hilog.info(DOMAIN, TAG, `paired health probe passed; formal pair ready attempt=${attempt}`);
        return true;
      }
      hilog.warn(DOMAIN, TAG, `paired health probe stalled attempt=${attempt}; rebuilding session pair`);
      this.resourceTableReady = false;
      this.beginSessionTeardown();
      await this.waitForSessionTeardown();
      if (!this.controlChannel.isConnected()) {
        this.setStatus('disconnected', '协同探针失败且连接已断开');
        return false;
      }
    }
    this.setStatus('error', '协同数据面自动恢复失败，本次没有提交用户请求');
    return false;
  }

  onSendFinished(): void {
    // Keep the verified native/co-session pair and its distributed KV cache
    // alive across normal conversation turns. Only the ReAct prompt-diff state
    // is per-run; the next send reuses this same prepared session immediately.
    this.model.resetRunState();
  }

  onClear(): void {
    this.sessionRequested = true;
    this.model.resetRunState();
    // Clear is the only normal conversation boundary that replaces the native
    // session. Cancel an unfinished preparation, drain the old pair, and only
    // then create the replacement so generations cannot overlap.
    this.beginSessionTeardown();
    this.restartSessionAfterClear();
  }

  private restartSessionAfterClear(): void {
    if (this.clearRestartPromise !== null) {
      return;
    }
    const staleReadiness = this.readinessPromise;
    const staleMasterPreparation = this.masterSessionPromise;
    // Any preparation that has not yet produced sessionPrepared must observe
    // a stale generation and leave without publishing session_ready.
    this.lifecycleGeneration += 1;
    this.resolveReady(false);
    this.resolveRuntimeReady(false);
    const pending = this.restartSessionAfterClearInternal(staleReadiness, staleMasterPreparation);
    this.clearRestartPromise = pending;
    pending.then((): void => {
      this.completeClearRestart(pending);
    }).catch((error: Error): void => {
      hilog.warn(DOMAIN, TAG, 'clear session restart failed: %{public}s', error.message);
      this.completeClearRestart(pending);
    });
  }

  private async restartSessionAfterClearInternal(
    staleReadiness: Promise<boolean> | null,
    staleMasterPreparation: Promise<boolean> | null
  ): Promise<void> {
    if (staleReadiness !== null) {
      try {
        await staleReadiness;
      } catch (_error) {
        // The generation barrier below is authoritative.
      }
    }
    if (staleMasterPreparation !== null) {
      try {
        await staleMasterPreparation;
      } catch (_error) {
        // Continue with deterministic teardown of any partially-created pair.
      }
    }
    if (this.sessionPrepared) {
      this.beginSessionTeardown();
      await this.waitForSessionTeardown();
    } else {
      this.resetSession();
    }
  }

  private completeClearRestart(pending: Promise<void>): void {
    if (this.clearRestartPromise !== pending) {
      return;
    }
    this.clearRestartPromise = null;
    if (this.sessionRequested && this.collaborationEnabled && this.isMaster) {
      this.prewarmSession();
    }
  }

  /** Mark the verified Gewu resource table dirty after a model/data-plane error. */
  onInferenceFailed(detail: string): void {
    this.resourceTableReady = false;
    this.beginSessionTeardown();
    this.setStatus('error', `协同推理失败：${detail}`);
  }

  async dispose(): Promise<void> {
    this.resolveReady(false);
    this.resolveRuntimeReady(false);
    this.beginSessionTeardown();
    await this.waitForSessionTeardown();
    this.model.dispose();
    await this.controlChannel.stop();
    await this.broadcaster.stop();
    // Same NAPI callback chain fix as init(): socket stop() resolves from
    // AsyncAfterWorkCallback where napi_env is NULL.
    await this.delay(0);
    if (this.nativeCollaborationEnabled) {
      try {
        const error = this.binding.disableCollaboration();
        if (error !== GEWU_OK) {
          hilog.warn(DOMAIN, TAG, `disableCollaboration failed: ${error}`);
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'disableCollaboration exception: %{public}s',
          error instanceof Error ? error.message : String(error));
      }
    }
    this.collaborationEnabled = false;
    this.nativeCollaborationEnabled = false;
    this.nativeEnablePromise = null;
    this.sessionRequested = false;
    this.readinessPromise = null;
    this.clearRestartPromise = null;
    this.sessionPrepared = false;
    this.collaboratorReady = false;
    this.collaboratorCaller = null;
    this.activeSessionGeneration = 0;
    this.resourceTableReady = false;
    this.setStatus('disabled', '协同未启用');
  }

  private resetSession(): void {
    this.lifecycleGeneration += 1;
    this.resolveRuntimeReady(false);
    this.collaboratorRuntimePreparationCaller = null;
    this.collaboratorRuntimePreparationGeneration = 0;
    this.collaboratorPreparationCaller = null;
    this.collaboratorPreparationGeneration = 0;
    this.model.closeSession();
    this.sessionPrepared = false;
    this.sessionProbeVerified = false;
    this.collaboratorReady = false;
    this.activeSessionGeneration = 0;
  }

  /**
   * Keep Clear and fault recovery cooperative. A fresh preparation waits for
   * this barrier instead of racing a new Gewu session against callbacks from
   * the previous one.
   */
  private beginSessionTeardown(): void {
    if (this.sessionTeardownPromise !== null) {
      return;
    }
    if (!this.sessionPrepared) {
      this.refreshConnectedStatus();
      return;
    }
    const generation = this.activeSessionGeneration;
    this.collaboratorReady = false;
    this.setStatus('preparing', '正在安全结束协同会话');
    const pending = this.teardownSession(generation);
    this.sessionTeardownPromise = pending;
    pending.then((): void => {
      this.completeSessionTeardown(pending);
    }).catch((error: Error): void => {
      hilog.warn(DOMAIN, TAG, 'session teardown failed: %{public}s', error.message);
      this.completeSessionTeardown(pending);
    });
  }

  private async teardownSession(generation: number): Promise<void> {
    if (this.isMaster && generation > 0 && this.controlChannel.isConnected()) {
      const ended = this.waitForCollaboratorSessionEnded(generation);
      const caller = process.pid;
      try {
        const sent = await this.controlChannel.sendSessionEnd(caller, generation);
        if (!sent) {
          this.resolveSessionEnded(false);
        }
      } catch (_error) {
        this.resolveSessionEnded(false);
      }
      this.broadcaster.broadcastSessionEnd(caller, generation).catch((_error: Error): void => {});
      await ended;
      this.controlChannel.clearCurrentSessionMessage(generation);
    } else {
      await this.delay(SESSION_DRAIN_DELAY_MS);
    }
    this.resetSession();
    await this.delay(SESSION_RESTART_GUARD_MS);
  }

  private completeSessionTeardown(pending: Promise<void>): void {
    if (this.sessionTeardownPromise !== pending) {
      return;
    }
    this.sessionTeardownPromise = null;
    this.refreshConnectedStatus();
  }

  private async waitForSessionTeardown(): Promise<void> {
    const pending = this.sessionTeardownPromise;
    if (pending !== null) {
      await pending;
    }
  }

  private waitForCollaboratorSessionEnded(generation: number): Promise<boolean> {
    this.resolveSessionEnded(false);
    this.pendingSessionEndGeneration = generation;
    return new Promise<boolean>((resolve) => {
      this.sessionEndedResolver = resolve;
      this.sessionEndedTimer = setTimeout((): void => {
        this.sessionEndedTimer = -1;
        this.sessionEndedResolver = null;
        this.pendingSessionEndGeneration = 0;
        hilog.warn(DOMAIN, TAG, `session_ended timeout generation=${generation}`);
        resolve(false);
      }, SESSION_END_ACK_TIMEOUT_MS);
    });
  }

  private resolveSessionEnded(ended: boolean): void {
    if (this.sessionEndedTimer !== -1) {
      clearTimeout(this.sessionEndedTimer);
      this.sessionEndedTimer = -1;
    }
    const resolver = this.sessionEndedResolver;
    this.sessionEndedResolver = null;
    this.pendingSessionEndGeneration = 0;
    resolver?.(ended);
  }

  private async requestCollaboratorRuntimeReady(
    caller: number,
    generation: number,
    resetRuntime: boolean,
    masterPort: number
  ): Promise<boolean> {
    this.resolveRuntimeReady(false);
    const pending = new Promise<boolean>((resolve) => {
      this.runtimeReadyResolver = resolve;
      this.runtimeReadyTimer = setTimeout((): void => {
        this.runtimeReadyTimer = -1;
        this.runtimeReadyResolver = null;
        resolve(false);
      }, RUNTIME_READY_TIMEOUT_MS);
    });
    try {
      const sent = await this.controlChannel.sendRuntimePrepare(caller, generation, resetRuntime, masterPort);
      if (!sent) {
        this.resolveRuntimeReady(false);
      }
    } catch (_error) {
      this.resolveRuntimeReady(false);
    }
    return await pending;
  }

  /** Create one Gewu session pair for the current agent run. */
  private async prepareMasterSession(isProbe: boolean): Promise<boolean> {
    await this.waitForSessionTeardown();
    if (this.sessionPrepared) {
      return true;
    }
    if (this.masterSessionPromise !== null) {
      return await this.masterSessionPromise;
    }
    const pending = this.prepareMasterSessionInternal(isProbe);
    this.masterSessionPromise = pending;
    try {
      return await pending;
    } finally {
      if (this.masterSessionPromise === pending) {
        this.masterSessionPromise = null;
      }
    }
  }

  private async preparePairedSession(timeoutMs: number, isProbe: boolean): Promise<boolean> {
    if (!this.sessionPrepared) {
      const prepared = await this.prepareMasterSession(isProbe);
      if (!prepared) {
        return false;
      }
    }
    if (this.collaboratorReady) {
      return true;
    }
    return await new Promise<boolean>((resolve) => {
      this.resolveReady(false);
      this.readyResolver = resolve;
      this.readyTimer = setTimeout((): void => {
        this.readyTimer = -1;
        this.readyResolver = null;
        this.abortPendingSession('等待协作者准备超时');
        resolve(false);
      }, timeoutMs);
    });
  }

  private async prepareMasterSessionInternal(isProbe: boolean): Promise<boolean> {
    if (!this.collaborationEnabled || !this.isMaster || !this.controlChannel.isConnected()) {
      return false;
    }
    const generation = this.lifecycleGeneration + 1;
    this.lifecycleGeneration = generation;
    this.activeSessionGeneration = generation;
    this.collaboratorReady = false;
    this.setStatus('preparing', '正在准备主机 Gewu 会话');
    await this.delay(GEWU_SESSION_STABILIZE_MS);
    if (generation !== this.lifecycleGeneration || !this.controlChannel.isConnected()) {
      return false;
    }
    this.setStatus('preparing', '正在确认协作者 Gewu 数据面');
    const runtimeReady = await this.requestCollaboratorRuntimeReady(
      process.pid,
      generation,
      false,
      this.currentMasterPort
    );
    if (!runtimeReady || generation !== this.lifecycleGeneration || !this.controlChannel.isConnected()) {
      if (generation === this.lifecycleGeneration) {
        this.setStatus('error', '协作者 Gewu 数据面准备超时');
      }
      return false;
    }
    if (!this.resourceTableReady) {
      this.setStatus('preparing', '正在创建主机 Gewu 会话');
    } else {
      this.setStatus('preparing', '正在复用已验证的 Gewu 协同资源表');
      await this.delay(GEWU_SESSION_STABILIZE_MS);
    }
    if (generation !== this.lifecycleGeneration || !this.controlChannel.isConnected()) {
      return false;
    }
    if (!this.model.prepareSession()) {
      this.resourceTableReady = false;
      this.setStatus('error', '主机会话创建失败');
      return false;
    }
    if (generation !== this.lifecycleGeneration) {
      this.model.closeSession();
      return false;
    }
    this.sessionPrepared = true;
    this.setStatus('preparing', isProbe ? '正在等待协作者准备探针模型' : '正在等待协作者准备正式模型');
    try {
      const sent = await this.controlChannel.sendSessionStart(process.pid, generation, isProbe);
      if (!sent) {
        this.abortPendingSession('协作者控制通道不可用');
        return false;
      }
      this.broadcaster.broadcastSessionStart(process.pid, generation, isProbe).catch((_error: Error): void => {});
      return true;
    } catch (_error) {
      this.abortPendingSession('协作者控制消息发送失败');
      return false;
    }
  }

  private async delay(timeoutMs: number): Promise<void> {
    await new Promise<void>((resolve) => {
      setTimeout(resolve, timeoutMs);
    });
  }

  /** Wait for the always-on control channel; this does not limit Decode. */
  private async waitForAutomaticConnection(timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (this.collaborationEnabled && !this.controlChannel.isConnected() && Date.now() < deadline) {
      await this.delay(250);
    }
    return this.collaborationEnabled && this.controlChannel.isConnected();
  }

  private onRemoteMessage: CollabMessageListener = (message): void => {
    if (!this.collaborationEnabled) {
      return;
    }
    if (message.type === 'hello') {
      hilog.info(DOMAIN, TAG, `remote hello ip=${message.remoteIp}`);
      return;
    }
    if (this.isMaster) {
      return;
    }
    this.handleCollaboratorLifecycle(
      message.type,
      message.caller,
      message.generation,
      `udp/${message.remoteIp}`,
      message.isProbe
    );
  };

  private onControlMessage: CollaborationControlListener = (
    type,
    caller,
    generation,
    resetRuntime,
    masterPort,
    isProbe
  ): void => {
    if (type === 'runtime_ready') {
      if (this.isMaster && caller === process.pid && generation === this.activeSessionGeneration) {
        this.resolveRuntimeReady(true);
        hilog.info(DOMAIN, TAG, `collaborator runtime_ready caller=${caller} generation=${generation}`);
      }
      return;
    }
    if (type === 'runtime_prepare') {
      if (!this.isMaster && caller !== undefined && Number.isFinite(caller) && caller > 0 &&
        generation !== undefined && Number.isFinite(generation) && generation > 0) {
        this.prepareCollaboratorRuntime(
          Math.floor(caller),
          Math.floor(generation),
          resetRuntime === true,
          masterPort
        ).catch((error: Error): void => {
          this.setStatus('error', `协作者 Gewu 数据面准备失败：${error.message}`);
        });
      }
      return;
    }
    if (type === 'session_ready') {
      if (this.isMaster && this.sessionPrepared && this.sessionTeardownPromise === null && caller === process.pid &&
        generation === this.activeSessionGeneration) {
        this.collaboratorReady = true;
        this.resourceTableReady = true;
        this.setStatus('preparing', '协同会话已建立，正在验证数据面');
        this.resolveReady(true);
        hilog.info(DOMAIN, TAG, `collaborator session_ready caller=${caller} generation=${generation}`);
      }
      return;
    }
    if (type === 'session_ended') {
      if (this.isMaster && caller === process.pid && generation === this.pendingSessionEndGeneration) {
        hilog.info(DOMAIN, TAG, `collaborator session_ended caller=${caller} generation=${generation}`);
        this.resolveSessionEnded(true);
      }
      return;
    }
    this.handleCollaboratorLifecycle(type, caller, generation, 'tcp-control', isProbe);
  };

  private async prepareCollaboratorRuntime(
    caller: number,
    generation: number,
    resetRuntime: boolean,
    masterPort: number | undefined
  ): Promise<void> {
    if (this.collaboratorRuntimeReadyGeneration === generation) {
      await this.controlChannel.sendRuntimeReady(caller, generation);
      return;
    }
    if (this.collaboratorRuntimePreparationCaller === caller &&
      this.collaboratorRuntimePreparationGeneration === generation) {
      return;
    }
    this.collaboratorRuntimePreparationCaller = caller;
    this.collaboratorRuntimePreparationGeneration = generation;
    this.setStatus('preparing', '正在确认协作者 Gewu 数据面');
    try {
      await this.ensureNativeCollaborationEnabled();
      if (resetRuntime) {
        hilog.warn(DOMAIN, TAG, 'runtime reset request ignored; fixed GewuDemo data plane is active');
      }
      if (masterPort === undefined || !Number.isFinite(masterPort) ||
        Math.floor(masterPort) !== this.currentMasterPort) {
        throw new Error(`主从 Gewu 端口不一致：${String(masterPort)} != ${this.currentMasterPort}`);
      }
      await this.delay(GEWU_SESSION_STABILIZE_MS);
      if (this.collaboratorRuntimePreparationCaller !== caller ||
        this.collaboratorRuntimePreparationGeneration !== generation || !this.controlChannel.isConnected()) {
        return;
      }
      const sent = await this.controlChannel.sendRuntimeReady(caller, generation);
      if (sent) {
        this.collaboratorRuntimeReadyGeneration = generation;
        this.setStatus('preparing', 'Gewu 数据面已就绪，等待主机会话');
      } else {
        this.setStatus('disconnected', 'Gewu 已就绪，但主机确认失败');
      }
    } finally {
      if (this.collaboratorRuntimePreparationCaller === caller &&
        this.collaboratorRuntimePreparationGeneration === generation) {
        this.collaboratorRuntimePreparationCaller = null;
        this.collaboratorRuntimePreparationGeneration = 0;
      }
    }
  }

  private handleCollaboratorLifecycle(
    type: 'session_start' | 'session_end',
    caller: number | undefined,
    generation: number | undefined,
    remote: string,
    isProbe: boolean | undefined
  ): void {
    if (!this.collaborationEnabled || this.isMaster) {
      return;
    }
    if (type === 'session_end') {
      if (caller === undefined || generation === undefined || generation !== this.activeSessionGeneration ||
        this.collaboratorEndingGeneration === generation) {
        return;
      }
      this.collaboratorEndingGeneration = generation;
      this.finishCollaboratorSession(caller, generation, remote).catch((error: Error): void => {
        this.setStatus('error', `协作者会话结束失败：${error.message}`);
      });
      return;
    }
    if (caller === undefined || !Number.isFinite(caller) || caller < 1 || generation === undefined ||
      !Number.isFinite(generation) || generation < 1) {
      hilog.warn(DOMAIN, TAG, `remote session_start missing caller/generation via ${remote}`);
      return;
    }
    const normalizedCaller = Math.floor(caller);
    const normalizedGeneration = Math.floor(generation);
    if (this.sessionPrepared && this.collaboratorCaller === normalizedCaller &&
      this.activeSessionGeneration === normalizedGeneration) {
      return;
    }
    if (this.collaboratorPreparationCaller === normalizedCaller &&
      this.collaboratorPreparationGeneration === normalizedGeneration) {
      return;
    }
    const operationGeneration = this.lifecycleGeneration + 1;
    this.lifecycleGeneration = operationGeneration;
    this.activeSessionGeneration = normalizedGeneration;
    this.collaboratorPreparationCaller = normalizedCaller;
    this.collaboratorPreparationGeneration = normalizedGeneration;
    this.prepareCollaboratorSession(
      normalizedCaller,
      normalizedGeneration,
      remote,
      operationGeneration,
      isProbe !== false
    ).catch((error: Error): void => {
      if (operationGeneration === this.lifecycleGeneration) {
        this.setStatus('error', `协作者会话创建失败：${error.message}`);
      }
    });
  }

  private async prepareCollaboratorSession(
    caller: number,
    sessionGeneration: number,
    remote: string,
    operationGeneration: number,
    isProbe: boolean
  ): Promise<void> {
    const attributes = this.collaboratorSessionAttributes(caller);
    if (attributes === undefined) {
      this.collaboratorPreparationCaller = null;
      this.setStatus('error', '协作者会话参数无效');
      return;
    }
    this.setStatus('preparing', '正在同步 Gewu 协同状态');
    this.model.dispose();
    this.model = this.createModel(attributes);
    try {
      await this.delay(GEWU_SESSION_STABILIZE_MS);
      for (let attempt = 1; attempt <= COLLABORATOR_SESSION_ATTEMPTS; attempt += 1) {
        if (operationGeneration !== this.lifecycleGeneration ||
          sessionGeneration !== this.activeSessionGeneration) {
          return;
        }
        this.setStatus('preparing', `正在创建协作者会话（${attempt}/${COLLABORATOR_SESSION_ATTEMPTS}）`);
        if (this.model.prepareSession()) {
          const confirmDelayMs = isProbe
            ? PROBE_CO_SESSION_CONFIRM_DELAY_MS
            : FORMAL_CO_SESSION_CONFIRM_DELAY_MS;
          hilog.info(DOMAIN, TAG,
            `collaborator session confirmation phase=${isProbe ? 'probe' : 'formal'} delayMs=${confirmDelayMs}`);
          this.setStatus('preparing', isProbe ? '正在确认探针协作者模型' : '正在确认正式协作者模型');
          await this.delay(confirmDelayMs);
          if (operationGeneration !== this.lifecycleGeneration ||
            sessionGeneration !== this.activeSessionGeneration) {
            this.model.closeSession();
            return;
          }
          this.sessionPrepared = true;
          this.collaboratorCaller = caller;
          hilog.info(DOMAIN, TAG,
            `remote session_start via ${remote} caller=${caller} generation=${sessionGeneration} attempt=${attempt}`);
          const sent = await this.controlChannel.sendSessionReady(caller, sessionGeneration);
          if (sent) {
            this.setStatus('ready', '协作者会话已就绪');
          } else {
            this.setStatus('disconnected', '会话已创建，但主机确认失败');
          }
          return;
        }
        hilog.warn(DOMAIN, TAG, `collaborator prepareSession attempt=${attempt} failed caller=${caller}`);
        if (attempt < COLLABORATOR_SESSION_ATTEMPTS) {
          await this.delay(COLLABORATOR_SESSION_RETRY_MS);
        }
      }
      if (operationGeneration === this.lifecycleGeneration) {
        this.setStatus('error', '协作者会话创建失败（Gewu 401），请重连后重试');
      }
    } finally {
      if (this.collaboratorPreparationCaller === caller &&
        this.collaboratorPreparationGeneration === sessionGeneration) {
        this.collaboratorPreparationCaller = null;
        this.collaboratorPreparationGeneration = 0;
      }
    }
  }

  private async finishCollaboratorSession(caller: number, generation: number, remote: string): Promise<void> {
    try {
      this.setStatus('preparing', '正在安全结束协作者会话');
      await this.delay(SESSION_DRAIN_DELAY_MS);
      if (generation !== this.activeSessionGeneration) {
        return;
      }
      this.resetSession();
      this.collaboratorCaller = null;
      const sent = await this.controlChannel.sendSessionEnded(caller, generation);
      hilog.info(DOMAIN, TAG,
        `remote session_end via ${remote} caller=${caller} generation=${generation} ack=${sent}`);
      this.refreshConnectedStatus();
    } finally {
      this.collaboratorEndingGeneration = 0;
    }
  }

  private onConnectionStateChanged = (state: CollaborationConnectionState): void => {
    this.connectionState = state;
    if (!this.collaborationEnabled) {
      return;
    }
    if (state === 'connected') {
      if (!this.isMaster) {
        this.ensureNativeCollaborationEnabled().then((enabled: boolean): void => {
          if (enabled) {
            hilog.info(DOMAIN, TAG, 'collaborator native data plane enabled after control connection');
            this.refreshConnectedStatus();
          }
        }).catch((error: Error): void => {
          this.setStatus('error', `协作者 Gewu 自动连接失败：${error.message}`);
        });
      }
      this.refreshConnectedStatus();
      if (this.isMaster && this.sessionRequested) {
        this.prewarmSession();
      }
      return;
    }
    this.resolveReady(false);
    this.resolveRuntimeReady(false);
    this.resolveSessionEnded(false);
    this.resourceTableReady = false;
    if (this.sessionPrepared) {
      this.beginSessionTeardown();
    } else {
      // Cancel a half-built generation as soon as the control peer disappears.
      // The always-on control channel keeps reconnecting independently; once
      // connected, a previously requested session is rebuilt exactly once.
      this.resetSession();
    }
    if (state === 'connecting') {
      this.setStatus('connecting', this.isMaster ? '正在等待协作者连接' : '正在连接主机');
    } else {
      this.setStatus('disconnected', this.isMaster ? '协作者未连接' : '与主机连接已断开');
    }
  };

  private refreshConnectedStatus(): void {
    if (this.connectionState !== 'connected') {
      this.setStatus('disconnected', this.isMaster ? '协作者未连接' : '与主机连接已断开');
      return;
    }
    if (this.sessionPrepared && this.collaboratorReady) {
      if (this.isMaster && !this.sessionProbeVerified) {
        this.setStatus('preparing', '协同会话已建立，正在验证数据面');
      } else {
        this.setStatus('ready', this.isMaster ? '协同会话已验证，可以发送' : '协作者会话已就绪');
      }
      return;
    }
    this.setStatus('connected', this.isMaster
      ? (this.sessionRequested ? '协作者已连接，点击此处重试模型准备' : '协作者已连接，点击此处准备模型')
      : '已连接主机，等待任务');
  }

  private abortPendingSession(detail: string): void {
    this.resourceTableReady = false;
    if (this.sessionPrepared) {
      this.beginSessionTeardown();
    } else {
      this.resetSession();
    }
    this.setStatus(this.controlChannel.isConnected() ? 'error' : 'disconnected', detail);
    this.resolveReady(false);
  }

  private resolveReady(ready: boolean): void {
    if (this.readyTimer !== -1) {
      clearTimeout(this.readyTimer);
      this.readyTimer = -1;
    }
    const resolver = this.readyResolver;
    this.readyResolver = null;
    resolver?.(ready);
  }

  private resolveRuntimeReady(ready: boolean): void {
    if (this.runtimeReadyTimer !== -1) {
      clearTimeout(this.runtimeReadyTimer);
      this.runtimeReadyTimer = -1;
    }
    const resolver = this.runtimeReadyResolver;
    this.runtimeReadyResolver = null;
    resolver?.(ready);
  }

  private async ensureNativeCollaborationEnabled(): Promise<boolean> {
    if (this.nativeCollaborationEnabled) {
      return true;
    }
    if (this.nativeEnablePromise !== null) {
      return await this.nativeEnablePromise;
    }
    const pending = this.enableNativeCollaboration();
    this.nativeEnablePromise = pending;
    try {
      return await pending;
    } finally {
      if (this.nativeEnablePromise === pending) {
        this.nativeEnablePromise = null;
      }
    }
  }

  private async enableNativeCollaboration(): Promise<boolean> {
    const enableError = this.binding.enableCollaboration(this.collaborationInfo);
    if (enableError !== GEWU_OK && enableError !== GEWU_ALREADY_ACTIVE) {
      throw new Error(`Gewu 协同启用失败：${enableError}`);
    }
    if (enableError === GEWU_ALREADY_ACTIVE) {
      hilog.info(DOMAIN, TAG, 'Gewu collaboration already enabled; reusing fixed data plane');
    }
    this.nativeCollaborationEnabled = true;
    hilog.info(DOMAIN, TAG, `native enabled role=${this.isMaster ? 'master' : 'collaborator'}`);
    return true;
  }

  private setStatus(status: CollaborationStatus, detail: string): void {
    if (this.status === status && this.statusDetail === detail) {
      return;
    }
    this.status = status;
    this.statusDetail = detail;
    this.statusListener?.(status, detail);
  }

  private createModel(attributes: string): SessionBackedModel {
    return new SessionBackedModel(this.binding, {
      attributes: attributes,
      requestType: this.requestType,
      stream: true,
      // Gewu owns retired collaboration Sessions. A generation switch only
      // drops the app-side handle; the next pair receives fresh Session IDs.
      retainNativeSessionOnClose: true,
      requestDrainMs: COLLABORATION_REQUEST_DRAIN_MS,
      responseListener: this.isMaster ? this.logMasterInferenceResponse : undefined
    });
  }

  private logMasterInferenceResponse = (response: string, requestId: number): void => {
    let formatted = response;
    try {
      const parsed = JSON.parse(response) as Object;
      formatted = JSON.stringify(parsed, null, 2);
    } catch (_error) {
      // Keep the original payload visible if the native callback returns text.
    }
    hilog.info(DOMAIN, TAG, 'master inference response:\n%{public}s', formatted);
    this.inferenceResponseListener?.(response, requestId);
  };
}
