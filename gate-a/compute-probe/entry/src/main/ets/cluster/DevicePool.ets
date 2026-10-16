/**
 * Idle-device selection for the compute hub. Pure logic: the caller supplies a
 * snapshot whose `inflight` already counts requests the hub has handed out but
 * the device has not yet reported, so two requests arriving in the same tick can
 * prefer different idle devices. Gewu can also run concurrent sessions on a busy device.
 */

export class PoolNode {
  epoch: number = 0;
  label: string = '';
  isSelf: boolean = false;
  /** Has a deployed model and is able to accept work. */
  ready: boolean = false;
  inflight: number = 0;
  memAvail: number = -1;
}

export class ClusterLoad {
  idle: number = 0;
  total: number = 0;
}

function memOf(node: PoolNode): number {
  return node.memAvail < 0 ? 0 : node.memAvail;
}

export function idleNodes(nodes: PoolNode[]): PoolNode[] {
  return nodes.filter((node: PoolNode): boolean => node.ready && node.inflight <= 0);
}

/**
 * More free memory wins; on a tie the hub itself runs the work (no forwarding hop).
 * A preferred epoch (the device that already holds this run's session) wins whenever it
 * is idle; when it is busy the request goes to any other idle device, never waits for it.
 */
export function pickIdle(nodes: PoolNode[], preferEpoch: number = -1,
  cost: (epoch: number) => number = (_epoch: number): number => -1): PoolNode | null {
  if (preferEpoch >= 0) {
    for (const node of idleNodes(nodes)) {
      if (node.epoch === preferEpoch) return node;
    }
  }
  let best: PoolNode | null = null;
  for (const node of idleNodes(nodes)) {
    if (best === null || better(node, best, cost)) best = node;
  }
  return best;
}

/** Prefer idle devices, then admit another session on the least-loaded ready device. */
export function pickAvailable(nodes: PoolNode[], preferEpoch: number = -1,
  cost: (epoch: number) => number = (_epoch: number): number => -1): PoolNode | null {
  const idle = pickIdle(nodes, preferEpoch, cost);
  if (idle !== null) return idle;
  let best: PoolNode | null = null;
  for (const node of nodes) {
    if (!node.ready) continue;
    if (best === null || node.inflight < best.inflight ||
      (node.inflight === best.inflight && (node.epoch === preferEpoch ||
        (best.epoch !== preferEpoch && better(node, best, cost))))) {
      best = node;
    }
  }
  return best;
}

/**
 * Measured speed decides among idle devices (lower cost = faster). A device with no measurement yet
 * is tried first so it gets measured. Speeds within SPEED_TOLERANCE of each other count as equal and
 * fall back to free memory, then to the hub itself.
 */
export const SPEED_TOLERANCE = 0.15;

function better(a: PoolNode, b: PoolNode, cost: (epoch: number) => number): boolean {
  const ca = cost(a.epoch);
  const cb = cost(b.epoch);
  if ((ca < 0) !== (cb < 0)) return ca < 0;
  if (ca >= 0 && cb >= 0 && Math.abs(ca - cb) > SPEED_TOLERANCE * Math.min(ca, cb)) return ca < cb;
  if (memOf(a) !== memOf(b)) return memOf(a) > memOf(b);
  return a.isSelf && !b.isSelf;
}

export function clusterLoad(nodes: PoolNode[]): ClusterLoad {
  const load = new ClusterLoad();
  for (const node of nodes) {
    if (!node.ready) continue;
    load.total++;
    if (node.inflight <= 0) load.idle++;
  }
  return load;
}
