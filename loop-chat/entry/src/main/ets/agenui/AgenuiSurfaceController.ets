import { ISurfaceManagerListener, Surface, SurfaceManager } from '@agenui/agenui';
import { common } from '@kit.AbilityKit';

const ENGINE_UNAVAILABLE_MSG =
  'AGenUI native engine is unavailable. Run on an ARM64 emulator or physical device (not ArkTS Preview).';

class AgenuiSurfaceListener implements ISurfaceManagerListener {
  private onCreate: (surface: Surface) => void;
  private onDelete: (surface: Surface) => void;
  private onAction: (event: string) => void;

  constructor(
    onCreate: (surface: Surface) => void,
    onDelete: (surface: Surface) => void,
    onAction: (event: string) => void
  ) {
    this.onCreate = onCreate;
    this.onDelete = onDelete;
    this.onAction = onAction;
  }

  onCreateSurface(surface: Surface): void {
    this.onCreate(surface);
  }

  onDeleteSurface(surface: Surface): void {
    this.onDelete(surface);
  }

  onReceiveActionEvent(event: string): void {
    this.onAction(event);
  }
}

export class AgenuiSurfaceController {
  private surfaceManager: SurfaceManager | null = null;
  private listener: AgenuiSurfaceListener | null = null;
  private activeSurfaceId: string = '';
  private ready: boolean = false;
  private lastError: string = '';

  init(
    context: common.UIAbilityContext,
    onSurfaceId: (surfaceId: string) => void,
    onAction: (event: string) => void
  ): boolean {
    this.destroy();
    this.lastError = '';

    try {
      this.surfaceManager = new SurfaceManager(context);
      this.listener = new AgenuiSurfaceListener(
        (surface: Surface) => {
          this.activeSurfaceId = surface.surfaceId;
          onSurfaceId(surface.surfaceId);
        },
        (_surface: Surface) => {
          this.activeSurfaceId = '';
          onSurfaceId('');
        },
        onAction
      );
      this.surfaceManager.addListener(this.listener);
      this.ready = true;
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      this.lastError = `${ENGINE_UNAVAILABLE_MSG} (${message})`;
      this.ready = false;
      this.surfaceManager = null;
      this.listener = null;
      return false;
    }
  }

  isReady(): boolean {
    return this.ready && this.surfaceManager !== null;
  }

  getLastError(): string {
    return this.lastError.length > 0 ? this.lastError : ENGINE_UNAVAILABLE_MSG;
  }

  getActiveSurfaceId(): string {
    return this.activeSurfaceId;
  }

  beginStream(): boolean {
    if (!this.isReady()) {
      this.lastError = ENGINE_UNAVAILABLE_MSG;
      return false;
    }
    this.surfaceManager?.beginTextStream();
    return true;
  }

  feedLine(line: string): boolean {
    if (!this.isReady()) {
      this.lastError = ENGINE_UNAVAILABLE_MSG;
      return false;
    }
    this.surfaceManager?.receiveTextChunk(line);
    return true;
  }

  endStream(): boolean {
    if (!this.isReady()) {
      this.lastError = ENGINE_UNAVAILABLE_MSG;
      return false;
    }
    this.surfaceManager?.endTextStream();
    return true;
  }

  feedJsonl(jsonlLines: string[]): boolean {
    if (!this.isReady() || jsonlLines.length === 0) {
      this.lastError = ENGINE_UNAVAILABLE_MSG;
      return false;
    }
    if (!this.beginStream()) {
      return false;
    }
    for (const line of jsonlLines) {
      this.feedLine(line);
    }
    return this.endStream();
  }

  destroy(): void {
    if (this.surfaceManager !== null && this.listener !== null) {
      this.surfaceManager.removeListener(this.listener);
    }
    this.surfaceManager?.destroy();
    this.surfaceManager = null;
    this.listener = null;
    this.activeSurfaceId = '';
    this.ready = false;
  }
}
