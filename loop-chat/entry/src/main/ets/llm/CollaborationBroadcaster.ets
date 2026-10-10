import socket from '@ohos.net.socket';
import util from '@ohos.util';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { utf8Bytes } from '@loop/agent-core';

const DOMAIN = 0x0000;
const TAG = 'CollabBroadcaster';
const BROADCAST_ADDRESS = '255.255.255.255';

interface CollabBroadcastMessage {
  protocol: 'loopy-gewu-v1';
  type: 'hello' | 'session_start' | 'session_end';
  caller?: number;
  generation?: number;
  isProbe?: boolean;
}

export interface CollabRemoteMessage {
  type: 'hello' | 'session_start' | 'session_end';
  remoteIp: string;
  caller?: number;
  generation?: number;
  isProbe?: boolean;
}

export type CollabMessageListener = (message: CollabRemoteMessage) => void;

/** UDP carries lifecycle signals only; Gewu owns the inference connection. */
export class CollaborationBroadcaster {
  private udp: socket.UDPSocket | null = null;
  private broadcastPort: number;
  private started = false;
  private listener: CollabMessageListener | null = null;
  private peerAddresses: string[] = [];

  constructor(broadcastPort: number) {
    this.broadcastPort = broadcastPort;
  }

  setMessageListener(listener: CollabMessageListener): void {
    this.listener = listener;
  }

  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    const udp: socket.UDPSocket = socket.constructUDPSocketInstance();
    try {
      await udp.bind({ address: '0.0.0.0', port: this.broadcastPort });
      await udp.setExtraOptions({ broadcast: true, reuseAddress: true });
      udp.on('message', (info: socket.SocketMessageInfo): void => {
        this.handleMessage(info);
      });
      this.udp = udp;
      this.started = true;
      hilog.info(DOMAIN, TAG, `started on udp/${this.broadcastPort}`);
    } catch (error) {
      try {
        await udp.close();
      } catch (_closeError) {
        // best-effort cleanup
      }
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }

  async broadcastHello(): Promise<void> {
    await this.sendLifecycle('hello');
  }

  async broadcastSessionStart(caller: number, generation: number, isProbe: boolean): Promise<void> {
    await this.sendLifecycle('session_start', caller, generation, isProbe);
  }

  async broadcastSessionEnd(caller: number, generation: number): Promise<void> {
    await this.sendLifecycle('session_end', caller, generation);
  }

  async stop(): Promise<void> {
    const udp = this.udp;
    this.udp = null;
    this.started = false;
    if (udp === null) {
      return;
    }
    try {
      udp.off('message');
      await udp.close();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'stop failed: %{public}s',
        error instanceof Error ? error.message : String(error));
    }
  }

  private async sendLifecycle(
    type: 'hello' | 'session_start' | 'session_end',
    caller?: number,
    generation?: number,
    isProbe?: boolean
  ): Promise<void> {
    if (!this.started || this.udp === null) {
      return;
    }
    const message: CollabBroadcastMessage = {
      protocol: 'loopy-gewu-v1',
      type: type
    };
    if (caller !== undefined) {
      message.caller = caller;
    }
    if (generation !== undefined) {
      message.generation = generation;
    }
    if (isProbe !== undefined) {
      message.isProbe = isProbe;
    }
    const targets: string[] = [BROADCAST_ADDRESS];
    for (const peer of this.peerAddresses) {
      if (targets.indexOf(peer) < 0) {
        targets.push(peer);
      }
    }
    for (const target of targets) {
      await this.sendTo(target, message);
    }
  }

  private async sendTo(target: string, message: CollabBroadcastMessage): Promise<void> {
    if (this.udp === null) {
      return;
    }
    const payload = utf8Bytes(JSON.stringify(message));
    const data = payload.buffer.slice(
      payload.byteOffset,
      payload.byteOffset + payload.byteLength
    ) as ArrayBuffer;
    try {
      await this.udp.send({
        data: data,
        address: {
          address: target,
          port: this.broadcastPort
        }
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'send to %{public}s failed: %{public}s', target,
        error instanceof Error ? error.message : String(error));
    }
  }

  private handleMessage(info: socket.SocketMessageInfo): void {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeToString(new Uint8Array(info.message));
      const message = JSON.parse(text) as CollabBroadcastMessage;
      if (message.protocol !== 'loopy-gewu-v1' ||
        (message.type !== 'hello' && message.type !== 'session_start' && message.type !== 'session_end')) {
        return;
      }
      const remoteIp = info.remoteInfo.address;
      if (remoteIp.length > 0 && this.peerAddresses.indexOf(remoteIp) < 0) {
        this.peerAddresses.push(remoteIp);
      }
      this.listener?.({
        type: message.type,
        remoteIp: remoteIp,
        caller: message.caller,
        generation: message.generation,
        isProbe: message.isProbe
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'invalid message: %{public}s',
        error instanceof Error ? error.message : String(error));
    }
  }
}
