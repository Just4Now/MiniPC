import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'LoopSkill';
const MAX_LOG_LENGTH = 800;

export function skillLogInfo(message: string): void {
  const safe = trimForLog(message);
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', safe);
}

export function skillLogWarn(message: string): void {
  const safe = trimForLog(message);
  hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', safe);
}

/** Print a complete long payload after one heading without visible chunk markers. */
export function skillLogInfoChunks(prefix: string, message: string): void {
  const firstChunkLength = Math.max(1, MAX_LOG_LENGTH - prefix.length);
  const firstChunk = message.substring(0, firstChunkLength);
  hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', prefix + firstChunk);
  for (let offset = firstChunkLength; offset < message.length; offset += MAX_LOG_LENGTH) {
    const chunk = message.substring(offset, Math.min(message.length, offset + MAX_LOG_LENGTH));
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', prefix + chunk);
  }
}

function trimForLog(message: string): string {
  if (message.length <= MAX_LOG_LENGTH) {
    return message;
  }
  return `${message.substring(0, MAX_LOG_LENGTH)}...`;
}
