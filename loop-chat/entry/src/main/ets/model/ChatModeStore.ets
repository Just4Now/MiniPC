import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const CHAT_SETTINGS = 'loop_chat_settings';
const AGENT_ENABLED = 'agent_enabled';

// Prefer ordinary chat until the user explicitly enables the Agent.
export function loadAgentEnabled(context: common.Context): boolean {
  try {
    const store = preferences.getPreferencesSync(context, { name: CHAT_SETTINGS });
    return store.getSync(AGENT_ENABLED, false) === true;
  } catch (_error) {
    return false;
  }
}

export async function saveAgentEnabled(context: common.Context, enabled: boolean): Promise<void> {
  const store = preferences.getPreferencesSync(context, { name: CHAT_SETTINGS });
  store.putSync(AGENT_ENABLED, enabled);
  await store.flush();
}
