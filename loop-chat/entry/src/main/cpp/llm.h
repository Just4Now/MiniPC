#ifndef LLM_H
#define LLM_H

/*
 * ============================================================================
 *  PRODUCTION TODO: 此文件为占位头文件，仅用于本地编译验证。
 *  生产环境请整体替换为真实的 LLM 引擎头文件（函数签名、类型名可能不同）。
 *  替换时需同步检查 llm_bridge.cpp 中所有 PRODUCTION_REPLACE 标记处。
 * ============================================================================
 *
 * 以下标记 PRODUCTION_REPLACE 的地方，接入真实引擎时必须逐个核对：
 *   - 类型名 XXXXX_Session / XXXXX_Request / XXXXX_ErrorCode
 *   - 函数名 XXXXX_CreateSession / XXXX_SubmitRequest / XXXXX_AbortRequest 等
 *   - 回调签名 XXXXX_OnResponse
 *   - 返回结构体字段名 (session/request/error)
 */

/* PRODUCTION_REPLACE: 以下类型定义应替换为真实引擎的头文件 */
typedef unsigned int XXXXX_Session;
typedef unsigned int XXXXX_Request;
typedef void (*XXXXX_OnResponse)(void* context, const char* response);

typedef enum {
    XXXXX_OK = 0,
    XXXXX_Others = 1,
} XXXXX_ErrorCode;

/* PRODUCTION_REPLACE: 返回结构体字段名可能与真实引擎不同 */
typedef struct {
    XXXXX_Session session;
    XXXXX_ErrorCode error;
} XXXXX_CreateSessionResult;

typedef struct {
    XXXXX_Request request;
    XXXXX_ErrorCode error;
} XXXXX_SubmitRequestResult;

/* PRODUCTION_REPLACE: attributes 格式预留，后续自定义。当前传空 JSON "{}"。 */
XXXXX_CreateSessionResult XXXXX_CreateSession(const char* attributes);

XXXXX_ErrorCode XXXXX_DestroySession(XXXXX_Session session);

/*
 * PRODUCTION_REPLACE: request 格式预留，后续自定义。
 * 当前按 OpenAI messages 格式:
 *   {"messages":[{"role":"developer","content":"..."},{"role":"user","content":"..."}],"stream":true}
 *
 * PRODUCTION_REPLACE: 回调 response 格式预留，当前假设为 JSON:
 *   {"content":"增量文本","finish_reason":null}   // null=进行中
 *   {"content":"","finish_reason":"stop"}         // 非空=结束
 *   字段名 (content/finish_reason) 在 SessionBackedModel.parseResponseChunk 中解析，
 *   生产环境如字段名不同，只需改那一个方法。
 */
XXXXX_SubmitRequestResult XXXX_SubmitRequest(XXXXX_Session session,
    const char* request, XXXXX_OnResponse callback, void* context);

XXXXX_ErrorCode XXXXX_AbortRequest(XXXXX_Session session, XXXXX_Request request);

#endif /* LLM_H */
