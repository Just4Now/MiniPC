import { A2uiComponentDef } from '@loop/agent-core';

interface UpdateComponentsMessage {
  updateComponents?: UpdateComponentsPayload;
}

interface UpdateComponentsPayload {
  components?: RawComponent[];
}

interface CreateSurfaceMessage {
  createSurface?: CreateSurfacePayload;
}

interface CreateSurfacePayload {
  surfaceId?: string;
}

interface RawComponent {
  id?: string;
  component?: string;
  child?: string;
  children?: string[];
  text?: string;
  variant?: string;
  align?: string;
  justify?: string;
}

function toComponentDef(raw: RawComponent): A2uiComponentDef | null {
  if (raw.id === undefined || raw.component === undefined) {
    return null;
  }
  const def: A2uiComponentDef = {
    id: raw.id,
    component: raw.component
  };
  if (raw.child !== undefined) {
    def.child = raw.child;
  }
  if (raw.children !== undefined) {
    def.children = raw.children;
  }
  if (raw.text !== undefined) {
    def.text = raw.text;
  }
  if (raw.variant !== undefined) {
    def.variant = raw.variant;
  }
  if (raw.align !== undefined) {
    def.align = raw.align;
  }
  if (raw.justify !== undefined) {
    def.justify = raw.justify;
  }
  return def;
}

export function parseComponentsFromJsonl(lines: string[]): A2uiComponentDef[] {
  const merged: A2uiComponentDef[] = [];
  for (const line of lines) {
    try {
      const message = JSON.parse(line) as UpdateComponentsMessage;
      const rawComponents = message.updateComponents?.components;
      if (rawComponents === undefined) {
        continue;
      }
      for (const raw of rawComponents) {
        const def = toComponentDef(raw);
        if (def !== null) {
          merged.push(def);
        }
      }
    } catch (_error) {
      // skip malformed line
    }
  }
  return merged;
}

export function parseSurfaceIdFromJsonl(lines: string[]): string {
  for (const line of lines) {
    try {
      const message = JSON.parse(line) as CreateSurfaceMessage;
      const surfaceId = message.createSurface?.surfaceId;
      if (surfaceId !== undefined && surfaceId.length > 0) {
        return surfaceId;
      }
    } catch (_error) {
      // skip
    }
  }
  return '';
}

export function hasRenderableRoot(components: A2uiComponentDef[]): boolean {
  for (const component of components) {
    if (component.id === 'root') {
      return true;
    }
  }
  return false;
}
