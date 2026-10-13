/**
 * libqwenvl_engine native bridge (Qwen2.5-VL-7B-Q4_0 CPU engine / qwen2vl_sdk).
 *
 * - start(modelDir, imagePath, prompt): starts ONE background worker that
 *   lazily creates+loads the engine (first call only, tens of seconds), then
 *   runs the multimodal chat. Streaming text arrives as events; consume with
 *   takeEvents().
 * - Cached engine: subsequent start() calls reuse the loaded weights until
 *   release() is called.
 */
export const start: (modelDir: string, imagePath: string, prompt: string) => boolean;
export const takeEvents: () => string[];
export const complete: () => void;
export const cancel: () => void;
export const release: () => void;
