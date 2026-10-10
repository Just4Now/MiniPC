import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'CollabControl';
const RETRY_DELAY_MS = 1000;
const HEARTBEAT_INTERVAL_MS = 3000;
const HEARTBEAT_TIMEOUT_MS = 9000;

export type CollaborationConnectionState = 'disconnected' | 'connecting' | 'connected';
export type CollaborationLifecycleType = 'runtime_prepare' | 'runtime_ready' |
  'session_start' | 'session_end' | 'session_ready' | 'session_ended';

type ControlMessageType = CollaborationLifecycleType | 'hello' | 'hello_ack' | 'heartbeat' | 'heartbeat_ack';

interface ControlMessage {
  protocol: 'loopy-gewu-v1';
  type: ControlMessageType;
  caller?: number;
  generation?: number;
  resetRuntime?: boolean;
  masterPort?: number;
  isProbe?: boolean;
}

export interface CollaborationControlOptions {
  isMaster: boolean;
  masterIP: string;
  controlPort: number;
}

export type CollaborationControlListener = (
  type: CollaborationLifecycleType,
  caller?: number,
  generation?: number,
  resetRuntime?: boolean,
  masterPort?: number,
  isProbe?: boolean
) => void;
export type CollaborationConnectionStateListener = (state: CollaborationConnectionState) => void;

/**
 * Reliable lifecycle channel for hotspot topologies.
 *
 * The collaborator always opens the TCP connection. A hello/hello_ack handshake,
 * application heartbeat and session_ready acknowledgement prevent a stale socket
 * or a master-only inference from being reported as active collaboration.
 */
export class CollaborationControlChannel {
  private options: CollaborationControlOptions;
  private listener: CollaborationControlListener | null = null;
  private stateListener: CollaborationConnectionStateListener | null = null;
  private state: CollaborationConnectionState = 'disconnected';
  private server: socket.TCPSocketServer | null = null;
  private serverConnections: socket.TCPSocketConnection[] = [];
  private serverReceiveBuffers: Map<number, string> = new Map<number, string>();
  private client: socket.TCPSocket | null = null;
  private retryTimer = -1;
  private heartbeatTimer = -1;
  private stopped = true;
  private connecting = false;
  private receiveBuffer = '';
  private lastPeerMessageAt = 0;
  private currentMessage: ControlMessage | null = null;

  constructor(options: CollaborationControlOptions) {
    this.options = options;
  }

  setMessageListener(listener: CollaborationControlListener): void {
    this.listener = listener;
  }

  setConnectionStateListener(listener: CollaborationConnectionStateListener): void {
    this.stateListener = listener;
    listener(this.state);
  }

  isConnected(): boolean {
    return this.state === 'connected';
  }

  async start(): Promise<void> {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    this.setState('connecting');
    this.startHeartbeatMonitor();
    if (this.options.isMaster) {
      await this.startServer();
      return;
    }
    await this.connectClient();
  }

  async reconnect(): Promise<void> {
    await this.stop();
    await this.start();
  }

  async sendSessionStart(caller: number, generation: number, isProbe: boolean): Promise<boolean> {
    const message: ControlMessage = {
      protocol: 'loopy-gewu-v1',
      type: 'session_start',
      caller: caller,
      generation: generation,
      isProbe: isProbe
    };
    this.currentMessage = message;
    return await this.sendToConnections(message) > 0;
  }

  async sendRuntimePrepare(
    caller: number,
    generation: number,
    resetRuntime: boolean,
    masterPort: number
  ): Promise<boolean> {
    if (!this.options.isMaster || this.state !== 'connected') {
      return false;
    }
    const message: ControlMessage = {
      protocol: 'loopy-gewu-v1',
      type: 'runtime_prepare',
      caller: caller,
      generation: generation,
      resetRuntime: resetRuntime,
      masterPort: masterPort
    };
    // Re-send the active lifecycle message after a short TCP reconnect. This
    // keeps the PR lifecycle intact while making runtime preparation idempotent.
    this.currentMessage = message;
    return await this.sendToConnections(message) > 0;
  }

  async sendRuntimeReady(caller: number, generation: number): Promise<boolean> {
    if (this.options.isMaster || this.state !== 'connected') {
      return false;
    }
    return await this.sendFromClient({
      protocol: 'loopy-gewu-v1',
      type: 'runtime_ready',
      caller: caller,
      generation: generation
    });
  }

  async sendSessionEnd(caller: number, generation: number): Promise<boolean> {
    const message: ControlMessage = {
      protocol: 'loopy-gewu-v1',
      type: 'session_end',
      caller: caller,
      generation: generation
    };
    this.currentMessage = message;
    return await this.sendToConnections(message) > 0;
  }

  async sendSessionReady(caller: number, generation: number): Promise<boolean> {
    if (this.options.isMaster || this.state !== 'connected') {
      return false;
    }
    return await this.sendFromClient({
      protocol: 'loopy-gewu-v1',
      type: 'session_ready',
      caller: caller,
      generation: generation
    });
  }

  async sendSessionEnded(caller: number, generation: number): Promise<boolean> {
    if (this.options.isMaster || this.state !== 'connected') {
      return false;
    }
    return await this.sendFromClient({
      protocol: 'loopy-gewu-v1',
      type: 'session_ended',
      caller: caller,
      generation: generation
    });
  }

  clearCurrentSessionMessage(generation: number): void {
    if (this.currentMessage?.generation === generation) {
      this.currentMessage = null;
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.connecting = false;
    this.currentMessage = null;
    this.receiveBuffer = '';
    this.lastPeerMessageAt = 0;
    this.clearRetryTimer();
    this.clearHeartbeatTimer();
    await this.closeClient(false);

    const connections = this.serverConnections.slice();
    this.serverConnections = [];
    this.serverReceiveBuffers.clear();
    for (const connection of connections) {
      connection.off('message');
      connection.off('close');
      connection.off('error');
      try {
        await connection.close();
      } catch (_error) {
        // best-effort cleanup
      }
    }

    const server = this.server;
    this.server = null;
    if (server !== null) {
      server.off('connect');
      server.off('error');
      try {
        await server.close();
      } catch (_error) {
        // API 17 devices may close the listener when the ability process exits.
      }
    }
    this.setState('disconnected');
  }

  private async startServer(): Promise<void> {
    const server = socket.constructTCPSocketServerInstance();
    server.on('connect', (connection: socket.TCPSocketConnection): void => {
      this.handleServerConnection(connection);
    });
    server.on('error', (error: Error): void => {
      hilog.warn(DOMAIN, TAG, 'server error: %{public}s', error.message);
      this.setState('disconnected');
    });
    try {
      await server.listen({ address: '0.0.0.0', port: this.options.controlPort });
      this.server = server;
      hilog.info(DOMAIN, TAG, `master listening tcp/${this.options.controlPort}`);
    } catch (error) {
      this.stopped = true;
      this.clearHeartbeatTimer();
      this.setState('disconnected');
      server.off('connect');
      server.off('error');
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }

  private handleServerConnection(connection: socket.TCPSocketConnection): void {
    this.serverConnections.push(connection);
    this.serverReceiveBuffers.set(connection.clientId, '');
    this.lastPeerMessageAt = Date.now();
    this.setState('connecting');
    connection.on('message', (info: socket.SocketMessageInfo): void => {
      this.handleServerMessage(connection, info);
    });
    connection.on('close', (): void => {
      this.removeServerConnection(connection);
    });
    connection.on('error', (_error: Error): void => {
      this.removeServerConnection(connection);
    });
    hilog.info(DOMAIN, TAG, `collaborator socket accepted client=${connection.clientId}`);
  }

  private removeServerConnection(connection: socket.TCPSocketConnection): void {
    const index = this.serverConnections.indexOf(connection);
    if (index >= 0) {
      this.serverConnections.splice(index, 1);
    }
    this.serverReceiveBuffers.delete(connection.clientId);
    if (this.serverConnections.length === 0) {
      this.setState(this.stopped ? 'disconnected' : 'connecting');
    }
  }

  private async connectClient(): Promise<void> {
    if (this.stopped || this.connecting || this.client !== null) {
      return;
    }
    this.connecting = true;
    this.setState('connecting');
    const client = socket.constructTCPSocketInstance();
    client.on('message', (info: socket.SocketMessageInfo): void => {
      this.handleClientMessage(info);
    });
    client.on('close', (): void => {
      this.handleClientDisconnected(client);
    });
    client.on('error', (_error: Error): void => {
      this.handleClientDisconnected(client);
    });
    try {
      await client.bind({ address: '0.0.0.0', port: 0 });
      await client.setExtraOptions({ keepAlive: true, TCPNoDelay: true });
      await client.connect({
        address: { address: this.options.masterIP, port: this.options.controlPort },
        timeout: 1500
      });
      if (this.stopped) {
        await client.close();
        return;
      }
      this.client = client;
      this.connecting = false;
      this.lastPeerMessageAt = Date.now();
      hilog.info(DOMAIN, TAG,
        `socket connected to ${this.options.masterIP}:${this.options.controlPort}; waiting for handshake`);
      const sent = await this.sendFromClient({ protocol: 'loopy-gewu-v1', type: 'hello' });
      if (!sent) {
        await this.closeClient(true);
      }
    } catch (_error) {
      this.connecting = false;
      client.off('message');
      client.off('close');
      client.off('error');
      try {
        await client.close();
      } catch (_closeError) {
        // best-effort cleanup
      }
      this.setState('connecting');
      this.scheduleReconnect();
    }
  }

  private handleClientDisconnected(client: socket.TCPSocket): void {
    if (this.client !== client) {
      return;
    }
    this.client = null;
    this.receiveBuffer = '';
    this.setState(this.stopped ? 'disconnected' : 'connecting');
    this.scheduleReconnect();
  }

  private async closeClient(reconnect: boolean): Promise<void> {
    const client = this.client;
    this.client = null;
    this.receiveBuffer = '';
    if (client !== null) {
      client.off('message');
      client.off('close');
      client.off('error');
      try {
        await client.close();
      } catch (_error) {
        // best-effort cleanup
      }
    }
    if (reconnect && !this.stopped) {
      this.setState('connecting');
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.options.isMaster || this.retryTimer !== -1) {
      return;
    }
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      this.connectClient().catch((_error: Error): void => {
        this.scheduleReconnect();
      });
    }, RETRY_DELAY_MS);
  }

  private clearRetryTimer(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private startHeartbeatMonitor(): void {
    this.clearHeartbeatTimer();
    this.heartbeatTimer = setInterval((): void => {
      this.checkConnectionHealth();
    }, HEARTBEAT_INTERVAL_MS);
  }

  private clearHeartbeatTimer(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private checkConnectionHealth(): void {
    if (this.stopped) {
      return;
    }
    const now = Date.now();
    if (this.options.isMaster) {
      if (this.serverConnections.length > 0 && now - this.lastPeerMessageAt > HEARTBEAT_TIMEOUT_MS) {
        const stale = this.serverConnections.slice();
        for (const connection of stale) {
          this.removeServerConnection(connection);
          connection.close().catch((_error: Error): void => {});
        }
        hilog.warn(DOMAIN, TAG, 'collaborator heartbeat timed out');
      }
      return;
    }
    if (this.client === null) {
      this.scheduleReconnect();
      return;
    }
    if (now - this.lastPeerMessageAt > HEARTBEAT_TIMEOUT_MS) {
      hilog.warn(DOMAIN, TAG, 'master heartbeat acknowledgement timed out');
      this.closeClient(true).catch((_error: Error): void => {});
      return;
    }
    this.sendFromClient({ protocol: 'loopy-gewu-v1', type: 'heartbeat' }).then((sent: boolean): void => {
      if (!sent) {
        this.closeClient(true).catch((_error: Error): void => {});
      }
    }).catch((_error: Error): void => {
      this.closeClient(true).catch((_closeError: Error): void => {});
    });
  }

  private async sendToConnections(message: ControlMessage): Promise<number> {
    let sentCount = 0;
    const connections = this.serverConnections.slice();
    for (const connection of connections) {
      try {
        await this.sendToConnection(connection, message);
        sentCount += 1;
      } catch (_error) {
        this.removeServerConnection(connection);
      }
    }
    if (sentCount === 0 && message.type !== 'heartbeat_ack' && message.type !== 'hello_ack') {
      hilog.warn(DOMAIN, TAG, `no connected collaborator for ${message.type}`);
    }
    return sentCount;
  }

  private async sendToConnection(connection: socket.TCPSocketConnection, message: ControlMessage): Promise<void> {
    await connection.send({ data: `${JSON.stringify(message)}\n`, encoding: 'UTF-8' });
  }

  private async sendFromClient(message: ControlMessage): Promise<boolean> {
    const client = this.client;
    if (client === null) {
      return false;
    }
    try {
      await client.send({ data: `${JSON.stringify(message)}\n`, encoding: 'UTF-8' });
      return true;
    } catch (_error) {
      return false;
    }
  }

  private handleServerMessage(connection: socket.TCPSocketConnection, info: socket.SocketMessageInfo): void {
    const decoder = util.TextDecoder.create('utf-8');
    const previous = this.serverReceiveBuffers.get(connection.clientId) ?? '';
    const next = previous + decoder.decodeToString(new Uint8Array(info.message));
    this.serverReceiveBuffers.set(connection.clientId, this.consumeLines(next,
      (message: ControlMessage): void => this.handleServerControlMessage(connection, message)));
  }

  private handleClientMessage(info: socket.SocketMessageInfo): void {
    const decoder = util.TextDecoder.create('utf-8');
    this.receiveBuffer += decoder.decodeToString(new Uint8Array(info.message));
    this.receiveBuffer = this.consumeLines(this.receiveBuffer,
      (message: ControlMessage): void => this.handleClientControlMessage(message));
  }

  private consumeLines(buffer: string, handler: (message: ControlMessage) => void): string {
    let remaining = buffer;
    let newline = remaining.indexOf('\n');
    while (newline >= 0) {
      const line = remaining.substring(0, newline).trim();
      remaining = remaining.substring(newline + 1);
      if (line.length > 0) {
        try {
          const message = JSON.parse(line) as ControlMessage;
          if (message.protocol === 'loopy-gewu-v1') {
            handler(message);
          }
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'invalid control message: %{public}s',
            error instanceof Error ? error.message : String(error));
        }
      }
      newline = remaining.indexOf('\n');
    }
    return remaining;
  }

  private handleServerControlMessage(connection: socket.TCPSocketConnection, message: ControlMessage): void {
    this.lastPeerMessageAt = Date.now();
    if (message.type === 'hello') {
      this.sendToConnection(connection, { protocol: 'loopy-gewu-v1', type: 'hello_ack' })
        .then((): void => {
          this.keepOnlyServerConnection(connection);
          this.setState('connected');
          hilog.info(DOMAIN, TAG, `collaborator handshake ready client=${connection.clientId}`);
          if (this.currentMessage !== null) {
            this.sendToConnection(connection, this.currentMessage).catch((_error: Error): void => {});
          }
        }).catch((_error: Error): void => {
          this.removeServerConnection(connection);
        });
      return;
    }
    if (message.type === 'heartbeat') {
      this.sendToConnection(connection, { protocol: 'loopy-gewu-v1', type: 'heartbeat_ack' })
        .catch((_error: Error): void => this.removeServerConnection(connection));
      return;
    }
    if (message.type === 'runtime_ready' || message.type === 'session_ready' ||
      message.type === 'session_ended') {
      this.listener?.(
        message.type,
        message.caller,
        message.generation,
        message.resetRuntime,
        message.masterPort,
        message.isProbe
      );
    }
  }

  private handleClientControlMessage(message: ControlMessage): void {
    this.lastPeerMessageAt = Date.now();
    if (message.type === 'hello_ack') {
      this.setState('connected');
      hilog.info(DOMAIN, TAG, 'application handshake ready');
      return;
    }
    if (message.type === 'heartbeat_ack') {
      return;
    }
    if (message.type === 'runtime_prepare' || message.type === 'session_start' || message.type === 'session_end') {
      this.listener?.(
        message.type,
        message.caller,
        message.generation,
        message.resetRuntime,
        message.masterPort,
        message.isProbe
      );
    }
  }

  private keepOnlyServerConnection(active: socket.TCPSocketConnection): void {
    const stale = this.serverConnections.filter((connection: socket.TCPSocketConnection): boolean =>
      connection.clientId !== active.clientId);
    this.serverConnections = [active];
    const activeBuffer = this.serverReceiveBuffers.get(active.clientId) ?? '';
    this.serverReceiveBuffers.clear();
    this.serverReceiveBuffers.set(active.clientId, activeBuffer);
    for (const connection of stale) {
      connection.off('message');
      connection.off('close');
      connection.off('error');
      connection.close().catch((_error: Error): void => {});
    }
  }

  private setState(state: CollaborationConnectionState): void {
    if (this.state === state) {
      return;
    }
    this.state = state;
    this.stateListener?.(state);
  }
}
