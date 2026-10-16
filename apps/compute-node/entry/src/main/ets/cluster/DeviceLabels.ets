export interface NamedPeer {
  epoch: number;
  name: string;
}

export function publicLabel(role: string, slot: number): string {
  const kind = role === 'chat' ? '聊天设备' : '算力设备';
  return slot >= 1 ? kind + String(slot) : kind;
}

export function hidePhoneName(name: string, role: string): string {
  if (name === '本机' || name.indexOf('算力设备') === 0 || name.indexOf('聊天设备') === 0) return name;
  return publicLabel(role, 0);
}

export function computeLabel(workerEpoch: number, peers: NamedPeer[], selfName: string = '算力设备'): string {
  if (workerEpoch <= 0) return hidePhoneName(selfName.length > 0 ? selfName : '算力设备', 'compute');
  for (const info of peers) {
    if (info.epoch === workerEpoch) return hidePhoneName(info.name || '算力设备', 'compute');
  }
  return '算力设备';
}

export function chatLabel(epoch: number, peers: NamedPeer[]): string {
  for (const info of peers) {
    if (info.epoch === epoch) return hidePhoneName(info.name, 'chat');
  }
  return '聊天设备';
}

export function workerTail(workerEpoch: number, peers: NamedPeer[], selfName: string = '算力设备'): string {
  return '由' + computeLabel(workerEpoch, peers, selfName) + '推理';
}

/** 能力标签的中文名；未知标签原样返回，便于排查清单写错的情况。 */
export function capabilityLabel(capability: string): string {
  return capability === 'vision' ? '图片理解' : capability;
}

/** 需求列表转为中文并列短语，如 ['vision'] → "图片理解"。 */
export function needsLabel(needs: string[]): string {
  const parts: string[] = [];
  for (const need of needs) {
    if (need.length === 0 || parts.indexOf(need) >= 0) continue;
    parts.push(need);
  }
  return parts.map((need: string): string => capabilityLabel(need)).join('、');
}
