export interface CollaborationWindow {
  setWindowKeepScreenOn(enabled: boolean): Promise<void>;
}

// A foreground service lease, independent of screen-off settings. Serialize
// window operations so a delayed enable cannot win over stop/background.
export class CollaborationScreen {
  private target: CollaborationWindow | null = null;
  private foreground: boolean = false;
  private wanted: boolean = false;
  private queue: Promise<void> = Promise.resolve();

  bind(target: CollaborationWindow): void {
    if (this.target !== null && this.target !== target) { this.release(this.target); }
    this.target = target;
    this.sync();
  }
  setForeground(foreground: boolean): void { this.foreground = foreground; this.sync(); }
  setWanted(wanted: boolean): void { this.wanted = wanted; this.sync(); }
  clear(): void {
    const old = this.target;
    this.foreground = false;
    this.wanted = false;
    this.target = null;
    if (old !== null) { this.release(old); }
  }
  settled(): Promise<void> { return this.queue; }

  private release(target: CollaborationWindow): void {
    this.queue = this.queue.then(async (): Promise<void> => { await target.setWindowKeepScreenOn(false); }).catch((): void => {});
  }
  private sync(): void {
    const target = this.target;
    if (target === null) { return; }
    this.queue = this.queue.then(async (): Promise<void> => {
      if (target !== this.target) { return; }
      await target.setWindowKeepScreenOn(this.foreground && this.wanted);
    }).catch((): void => {});
  }
}

export const collaborationScreen: CollaborationScreen = new CollaborationScreen();
