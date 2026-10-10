import { A2uiComponentDef, buildTaskCardComponents, parseJsonl } from '@loop/agent-core';
import { hasRenderableRoot, parseComponentsFromJsonl } from './A2uiFallbackParser';

export function componentsFromUiEvent(jsonlPayload: string, fallbackTask: string): A2uiComponentDef[] {
  const lines = parseJsonl(jsonlPayload);
  const components = parseComponentsFromJsonl(lines);
  if (hasRenderableRoot(components)) {
    return copyComponents(components);
  }
  return copyComponents(buildTaskCardComponents(fallbackTask, false));
}

function copyComponents(components: A2uiComponentDef[]): A2uiComponentDef[] {
  const copy: A2uiComponentDef[] = [];
  for (const component of components) {
    copy.push(component);
  }
  return copy;
}
