import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, ClusterInfo, WireMessage } from '../protocol/ChatProtocol';
import { ComputeRouter, DispatchEntry } from '../cluster/ComputeRouter';
import { PoolNode, clusterLoad, meetsCapabilities, pickIdle, pickIdleFor } from '../cluster/DevicePool';
import { classifyFromMessages } from '../cluster/TaskRules';

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
    // 从请求本身推导能力需求（不改协议：infer.request 的白名单没变）。
    // 带图 ⇒ 执行节点必须具备 vision；否则按纯文本。
    const needs: string[] = message.image !== undefined && message.image.length > 0 ?
      ['vision'] : ['text'];
    const messages: ChatMessage[] = message.messages !== undefined ? message.messages :
      [{ role: 'user', content: message.prompt || '' }];
    // 档位与执行端同规则重算：消息经 forwardCopy 逐字转发，两侧输入一致、结果
    // 一致——hub 用它选设备，执行端用它选本机模型目录（预算不参与定档，见 TaskRules）。
    const profile = classifyFromMessages(messages, needs.indexOf('vision') >= 0);
    const pool = this.nodes();
    const target = pickIdleFor(pool, needs, profile.tier);
    if (target === null) {
      // 区分「没有具备该能力的节点」（重试无意义）与「有但都忙」（可重试）。
      const capable = pool.some((item: PoolNode): boolean => item.ready && meetsCapabilities(item, needs));
      hilog.info(0, 'NearbyChat', 'infer route miss request=%{public}s tier=%{public}d capable=%{public}s',
        id, profile.tier, String(capable));
      if (capable) {
        this.refuse(id, chatEpoch, 'BUSY', '算力繁忙，请稍后重试', true);
      } else {
        this.refuse(id, chatEpoch, 'MODEL_UNAVAILABLE', '没有可执行该任务的算力设备', false);
      }
      return;
    }
    if (target.isSelf) {
      hilog.info(0, 'NearbyChat', 'infer local request=%{public}s tier=%{public}d nodeTier=%{public}d',
        id, profile.tier, target.modelTier);
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
    this.events.begin(id, chatEpoch, target.epoch, messages, message.label !== undefined ? message.label : '');
    hilog.info(0, 'NearbyChat',
      'infer relay request=%{public}s forward=%{public}s worker=%{public}d tier=%{public}d nodeTier=%{public}d',
      id, dispatch.forwardId, target.epoch, profile.tier, target.modelTier);
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
    if (message.image !== undefined) copy.image = message.image;
    if (message.label !== undefined) copy.label = message.label;
    if (message.maxOutputTokens !== undefined) copy.maxOutputTokens = message.maxOutputTokens;
    if (typeof message.deadlineBudgetMs === 'number') {
      copy.deadlineBudgetMs = Math.max(MIN_FORWARD_BUDGET_MS, message.deadlineBudgetMs - RELAY_MARGIN_MS);
    }
    return copy;
  }
}
