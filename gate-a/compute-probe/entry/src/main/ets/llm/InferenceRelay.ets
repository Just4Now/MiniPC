import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, ClusterInfo, WireMessage } from '../protocol/ChatProtocol';
import { ComputeRouter, DispatchEntry } from '../cluster/ComputeRouter';
import { PoolNode, clusterLoad, pickIdle } from '../cluster/DevicePool';

/** Time the hub keeps for relaying; the worker gets the requester's budget minus this. */
const RELAY_MARGIN_MS = 5000;
const MIN_FORWARD_BUDGET_MS = 10000;

/** The hub's own inference host, as seen by the relay. */
export interface RelayLocal {
  handle(message: WireMessage, epoch: number): void;
}

/** Task-card observers for requests that run on another device. */
export class RelayEvents {
  begin: (requestId: string, chatEpoch: number, workerEpoch: number, messages: ChatMessage[], label: string) => void =
    (_requestId: string, _chatEpoch: number, _workerEpoch: number, _messages: ChatMessage[], _label: string): void => {};
  delta: (requestId: string, chatEpoch: number, answer: string) => void =
    (_requestId: string, _chatEpoch: number, _answer: string): void => {};
  end: (requestId: string, chatEpoch: number, answer: string, failed: boolean) => void =
    (_requestId: string, _chatEpoch: number, _answer: string, _failed: boolean): void => {};
  forward: (requestId: string, chatEpoch: number, workerEpoch: number, request: WireMessage) => void =
    (_requestId: string, _chatEpoch: number, _workerEpoch: number, _request: WireMessage): void => {};
}

/**
 * Compute-hub router for agent `infer.*` traffic.
 *
 * One chat request goes to exactly one idle device: the hub itself (handled by
 * its own host) or another compute device (forwarded under a hub-generated
 * forwardId). Replies are matched on forwardId, the worker is identified by its
 * link epoch, and the payload is passed through unchanged except for requestId,
 * so the requester's seq/length/sha256 checks keep covering the real output.
 *
 * A request that was never accepted is safe to re-issue (BUSY / WORKER_LOST are
 * retryable); once the worker has answered infer.accepted it is not.
 */
export class InferenceRelay {
  private router: ComputeRouter;
  private nodes: () => PoolNode[];
  private chats: () => number[];
  private local: RelayLocal;
  private sender: (message: WireMessage, epoch: number) => Promise<boolean>;
  private events: RelayEvents;
  private lastPublished: string = '';

  constructor(router: ComputeRouter, nodes: () => PoolNode[], chats: () => number[], local: RelayLocal,
    sender: (message: WireMessage, epoch: number) => Promise<boolean>, events: RelayEvents) {
    this.router = router;
    this.nodes = nodes;
    this.chats = chats;
    this.local = local;
    this.sender = sender;
    this.events = events;
  }

  load(): ClusterInfo {
    const load = clusterLoad(this.nodes());
    return { idle: load.idle, total: load.total };
  }

  /** Message from a chat phone: infer.request, infer.cancel, infer.capabilities.get. */
  handleFromChat(message: WireMessage, chatEpoch: number): void {
    if (message.type === 'infer.request') {
      this.route(message, chatEpoch);
      return;
    }
    if (message.type === 'infer.cancel') {
      this.cancel(message, chatEpoch);
      return;
    }
    this.local.handle(message, chatEpoch);
  }

  /** Reply from a compute device that was handed a forwarded request. */
  handleFromWorker(message: WireMessage, workerEpoch: number): void {
    const forwardId = message.requestId || '';
    const entry = this.router.getByForwardId(forwardId);
    if (entry === undefined || !entry.infer || entry.workerEpoch !== workerEpoch) {
      return;
    }
    const origin = entry.originRequestId;
    if (message.type === 'infer.accepted') {
      entry.accepted = true;
      this.toChat({ type: 'infer.accepted', version: 2, requestId: origin, state: message.state,
        device: entry.workerName }, entry);
      return;
    }
    if (message.type === 'infer.delta') {
      const text = message.text || '';
      entry.answer += text;
      this.toChat({ type: 'infer.delta', version: 2, requestId: origin, seq: message.seq, text: text }, entry);
      this.events.delta(origin, entry.originEpoch, entry.answer);
      return;
    }
    if (message.type === 'infer.done') {
      this.router.finishForward(forwardId);
      this.sendToChat({ type: 'infer.done', version: 2, requestId: origin, lastSeq: message.lastSeq,
        outputUtf8Bytes: message.outputUtf8Bytes, outputSha256: message.outputSha256,
        finishReason: message.finishReason, source: message.source }, entry.originEpoch, null);
      this.events.end(origin, entry.originEpoch, entry.answer, false);
      this.publishLoad();
      return;
    }
    if (message.type === 'infer.error') {
      this.router.finishForward(forwardId);
      this.sendToChat({ type: 'infer.error', version: 2, requestId: origin, code: message.code,
        message: message.message, retryable: message.retryable }, entry.originEpoch, null);
      this.events.end(origin, entry.originEpoch, entry.answer, true);
      this.publishLoad();
    }
  }

  /** The chat phone is gone: nothing can be delivered, so stop the remote work. */
  chatDropped(chatEpoch: number): void {
    for (const entry of this.router.dispatchesFromOrigin(chatEpoch)) {
      if (!entry.infer) continue;
      this.router.finishForward(entry.forwardId);
      this.sender({ type: 'infer.cancel', version: 2, requestId: entry.forwardId }, entry.workerEpoch)
        .catch((_error: Error): void => {});
      this.events.end(entry.originRequestId, entry.originEpoch, entry.answer, true);
    }
    this.publishLoad();
  }

  /** A compute device disappeared: fail what ran on it, retryable only if never accepted. */
  workerDropped(workerEpoch: number): void {
    for (const entry of this.router.dispatchesFor(workerEpoch)) {
      if (!entry.infer) continue;
      this.router.finishForward(entry.forwardId);
      this.sendToChat({ type: 'infer.error', version: 2, requestId: entry.originRequestId, code: 'WORKER_LOST',
        message: '执行设备 ' + entry.workerName + ' 已断开', retryable: !entry.accepted }, entry.originEpoch, null);
      this.events.end(entry.originRequestId, entry.originEpoch, entry.answer, true);
    }
    this.publishLoad();
  }

  /** Pushes infer.status to every chat phone, only when the numbers changed. */
  publishLoad(): void {
    const load = this.load();
    const key = String(load.idle) + '/' + String(load.total);
    if (key === this.lastPublished) return;
    this.lastPublished = key;
    for (const epoch of this.chats()) {
      this.sender({ type: 'infer.status', version: 2, requestId: 'cluster', cluster: load }, epoch)
        .catch((_error: Error): void => {});
    }
  }

  private route(message: WireMessage, chatEpoch: number): void {
    const id = message.requestId || '';
    if (this.router.getDispatch(id, chatEpoch) !== undefined) {
      this.refuse(id, chatEpoch, 'DUPLICATE_REQUEST', '请求编号重复', false);
      return;
    }
    const target = pickIdle(this.nodes());
    if (target === null) {
      this.refuse(id, chatEpoch, 'BUSY', '算力繁忙，请稍后重试', true);
      return;
    }
    if (target.isSelf) {
      this.local.handle(message, chatEpoch);
      this.publishLoad();
      return;
    }
    const entry = new DispatchEntry();
    entry.originEpoch = chatEpoch;
    entry.originRequestId = id;
    entry.workerEpoch = target.epoch;
    entry.workerName = target.label;
    entry.infer = true;
    // Counted before the send below, so the next request in this tick sees the device as busy.
    const dispatch = this.router.beginDispatch(id, entry);
    const forwarded = this.forwardCopy(message, dispatch.forwardId);
    const messages: ChatMessage[] = message.messages !== undefined ? message.messages :
      [{ role: 'user', content: message.prompt || '' }];
    this.events.begin(id, chatEpoch, target.epoch, messages, message.label !== undefined ? message.label : '');
    this.events.forward(id, chatEpoch, target.epoch, forwarded);
    hilog.info(0, 'NearbyChat', 'infer relay request=%{public}s forward=%{public}s worker=%{public}d',
      id, dispatch.forwardId, target.epoch);
    this.sender(forwarded, target.epoch).then((sent: boolean): void => {
      if (!sent) this.forwardFailed(dispatch);
    }).catch((_error: Error): void => this.forwardFailed(dispatch));
    this.publishLoad();
  }

  /** The send to the worker failed: the request never started there, so it is retryable. */
  private forwardFailed(dispatch: DispatchEntry): void {
    if (this.router.finishForward(dispatch.forwardId) === undefined) return;
    this.sendToChat({ type: 'infer.error', version: 2, requestId: dispatch.originRequestId, code: 'WORKER_LOST',
      message: '无法联系执行设备 ' + dispatch.workerName, retryable: !dispatch.accepted }, dispatch.originEpoch, null);
    this.events.end(dispatch.originRequestId, dispatch.originEpoch, dispatch.answer, true);
    this.publishLoad();
  }

  private cancel(message: WireMessage, chatEpoch: number): void {
    const entry = this.router.getDispatch(message.requestId || '', chatEpoch);
    if (entry === undefined || !entry.infer) {
      this.local.handle(message, chatEpoch);
      return;
    }
    // The worker answers with infer.error CANCELLED, which flows back through handleFromWorker.
    this.sender({ type: 'infer.cancel', version: 2, requestId: entry.forwardId }, entry.workerEpoch)
      .then((sent: boolean): void => {
        if (!sent) this.forwardFailed(entry);
      }).catch((_error: Error): void => this.forwardFailed(entry));
  }

  private refuse(requestId: string, chatEpoch: number, code: string, text: string, retryable: boolean): void {
    this.sender({ type: 'infer.error', version: 2, requestId: requestId, code: code, message: text,
      retryable: retryable }, chatEpoch).catch((_error: Error): void => {});
  }

  private toChat(message: WireMessage, entry: DispatchEntry): void {
    this.sendToChat(message, entry.originEpoch, entry);
  }

  /** A lost reply makes the stream undeliverable, so stop the worker instead of letting it run on. */
  private sendToChat(message: WireMessage, chatEpoch: number, live: DispatchEntry | null): void {
    const failed = (): void => {
      if (live === null) return;
      if (this.router.finishForward(live.forwardId) === undefined) return;
      this.sender({ type: 'infer.cancel', version: 2, requestId: live.forwardId }, live.workerEpoch)
        .catch((_error: Error): void => {});
      this.events.end(live.originRequestId, live.originEpoch, live.answer, true);
      this.publishLoad();
    };
    let pending: Promise<boolean>;
    try {
      pending = this.sender(message, chatEpoch);
    } catch (_error) {
      failed();
      return;
    }
    pending.then((sent: boolean): void => {
      if (!sent) failed();
    }).catch((_error: Error): void => failed());
  }

  private forwardCopy(message: WireMessage, forwardId: string): WireMessage {
    const copy: WireMessage = { type: 'infer.request', version: 2, requestId: forwardId };
    if (message.clientInstanceId !== undefined) copy.clientInstanceId = message.clientInstanceId;
    if (message.agentRunId !== undefined) copy.agentRunId = message.agentRunId;
    if (message.modelId !== undefined) copy.modelId = message.modelId;
    if (message.modelRevision !== undefined) copy.modelRevision = message.modelRevision;
    if (message.promptFormat !== undefined) copy.promptFormat = message.promptFormat;
    if (message.prompt !== undefined) copy.prompt = message.prompt;
    if (message.messages !== undefined) copy.messages = message.messages;
    if (message.label !== undefined) copy.label = message.label;
    if (message.taskId !== undefined) copy.taskId = message.taskId;
    if (message.subtaskId !== undefined) copy.subtaskId = message.subtaskId;
    if (message.origin !== undefined) copy.origin = message.origin;
    if (message.maxOutputTokens !== undefined) copy.maxOutputTokens = message.maxOutputTokens;
    if (typeof message.deadlineBudgetMs === 'number') {
      copy.deadlineBudgetMs = Math.max(MIN_FORWARD_BUDGET_MS, message.deadlineBudgetMs - RELAY_MARGIN_MS);
    }
    return copy;
  }
}
