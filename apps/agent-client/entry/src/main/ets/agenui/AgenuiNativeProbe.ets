/** Dynamically probes whether the AGenUI native engine can load (not available in Preview). */
export async function probeAgenuiNative(): Promise<boolean> {
  try {
    await import('liba2ui-capi.so');
    return true;
  } catch (_error) {
    return false;
  }
}

export const GENUI_PREVIEW_MESSAGE =
  'Native AGenUI rendering is unavailable here (Preview / simulator without arm64 native libs). ' +
  'You can still generate A2UI protocol JSON below. For live UI, use Run on an ARM64 emulator or device.';
