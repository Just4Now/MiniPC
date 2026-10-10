/**
 * Idle-device selection for the compute hub. Pure logic: the caller supplies a
 * snapshot whose `inflight` already counts requests the hub has handed out but
 * the device has not yet reported, so two requests arriving in the same tick can
 * never both be given the same idle device.
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

/** More free memory wins; on a tie the hub itself runs the work (no forwarding hop). */
export function pickIdle(nodes: PoolNode[]): PoolNode | null {
  let best: PoolNode | null = null;
  for (const node of idleNodes(nodes)) {
    if (best === null || memOf(node) > memOf(best) || (memOf(node) === memOf(best) && node.isSelf && !best.isSelf)) {
      best = node;
    }
  }
  return best;
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
