/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2025-2025. All rights reserved.
 *
 * qwen2vl_sdk.h - Pure C SDK for on-device Qwen2.5-VL (CPU) inference.
 *
 * This is the "CDK" surface produced from the qwen2_5vl_cli launcher: the whole
 * engine (llm-main: REF/CPU-ARM backends + qwen2vl model + hf tokenizer) is
 * statically linked into one shared library (libqwen2vl_sdk.so) that exposes
 * only this C API. A DevEco Studio module wraps it with NAPI in its own .so.
 *
 * Usage:
 *   const char* cfg = qwen2vl_default_config(model_dir);   // model_dir contains
 *                                                          // vl_params + tokenizer.json
 *   Qwen2vlEngine* e = qwen2vl_create(cfg);
 *   qwen2vl_load(e);                                       // loads ~5.3GB weights
 *   qwen2vl_chat(e, image_path, prompt, on_token, ctx);    // streaming (blocking)
 *   qwen2vl_cancel(e);                                     // from another thread
 *   qwen2vl_destroy(e);
 */
#ifndef QWEN2VL_SDK_H
#define QWEN2VL_SDK_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(__GNUC__)
#define QWEN2VL_API __declspec(dllexport)
#else
#define QWEN2VL_API __attribute__((visibility("default")))
#endif

/* Error codes returned by qwen2vl_* functions. */
#define QWEN2VL_OK             0  /* success */
#define QWEN2VL_ERR_INVAL     -1  /* null/empty argument or bad config JSON */
#define QWEN2VL_ERR_BUSY      -2  /* another chat request is still running */
#define QWEN2VL_ERR_LOAD      -3  /* model/tokenizer load failed */
#define QWEN2VL_ERR_IMAGE     -4  /* image open / preprocess failed */
#define QWEN2VL_ERR_RUNTIME   -5  /* engine runtime failure */
#define QWEN2VL_ERR_CANCELLED -6  /* stopped by qwen2vl_cancel() */

typedef struct Qwen2vlEngine Qwen2vlEngine;

/* Streaming callback: `text` is the detokenized piece for one generated token
 * (single-byte UTF-8 may split multi-byte characters across calls; concatenate
 * the pieces to reconstruct the full reply). Valid during qwen2vl_chat(). */
typedef void (*Qwen2vlTokenCb)(void* userdata, const char* text);

/* Build a default CPU config JSON for `model_dir` which must contain the two
 * engine weight files: `vl_params` and `tokenizer.json`.
 * Returns a pointer to a thread-local buffer; valid until the next call on the
 * same thread. Returns NULL if model_dir is null/empty. */
QWEN2VL_API const char* qwen2vl_default_config(const char* model_dir);

/* Create an engine from a full config JSON string (the qwen2_5vl_cli schema:
 * tokenizer / vl_params_path / llm_hparams / vision_hparams / esets / lora /
 * text). qwen2vl_default_config() produces a valid default. */
QWEN2VL_API Qwen2vlEngine* qwen2vl_create(const char* config_json);

/* Load weights (blocking, tens of seconds for 7B Q4_0). 0 = OK. */
QWEN2VL_API int qwen2vl_load(Qwen2vlEngine* e);

/* Run one multimodal request.
 *   image_path - readable image (jpg/png). Required (multimodal flow).
 *   prompt     - user text.
 *   cb/userdata- optional streaming callback per generated token.
 * Blocking; returns QWEN2VL_OK on natural end (stop token reached), a negative
 * error code otherwise. Only one chat may run at a time. */
QWEN2VL_API int qwen2vl_chat(
    Qwen2vlEngine* e, const char* image_path, const char* prompt, Qwen2vlTokenCb cb, void* userdata);

/* Thread-safe: ask the running chat to stop at the next token boundary. */
QWEN2VL_API void qwen2vl_cancel(Qwen2vlEngine* e);

/* Last error description (thread-local buffer). */
QWEN2VL_API const char* qwen2vl_last_error(Qwen2vlEngine* e);

/* Destroy engine and free all resources (weights, caches). */
QWEN2VL_API void qwen2vl_destroy(Qwen2vlEngine* e);

#ifdef __cplusplus
}
#endif

#endif /* QWEN2VL_SDK_H */
