/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef QOS_H
#define QOS_H
/**
 * @addtogroup QoS
 * @{
 *
 * @brief QoS provides APIs.
 *
 * @since 12
 */

/**
 * @file qos.h
 *
 * @brief Declares the QoS interfaces in C.
 *
 * Quality-of-service (QoS) refers to the priority scheduling attribute of tasks
 * in OpenHarmony. Developers can use QoS to categorize tasks to be executed to
 * indicate the degree of their relevance to user interactions, the system can
 * schedule the time and running order of tasks according to the QoS set by the tasks.
 *
 * @library libqos.so
 * @kit KernelEnhanceKit
 * @syscap SystemCapability.Resourceschedule.QoS.Core
 * @since 12
 */
#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Describes the level of QoS.
 *
 * @since 12
 */
typedef enum QoS_Level {
    /**
     * @brief Means the QoS level is background.
     */
    QOS_BACKGROUND = 0,

    /**
     * @brief Means the QoS level is utility.
     */
    QOS_UTILITY,

    /**
     * @brief Means the QoS level is default.
     */
    QOS_DEFAULT,

    /**
     * @brief Means the QoS level is user-initiated.
     */
    QOS_USER_INITIATED,

    /**
     * @brief Means the QoS level is user-request.
     */
    QOS_DEADLINE_REQUEST,

    /**
     * @brief Means the QoS level is user-interactive.
     */
    QOS_USER_INTERACTIVE,
} QoS_Level;

/**
 * @brief Set the QoS level of the current thread.
 *
 * @param level Indicates the level to set. Specific level can be referenced {@link QoS_Level}.
 * @return Returns int32_t, return value == 0, success, otherwise value == -1, failed.
 * @see QoS_Level
 * @since 12
 */
int OH_QoS_SetThreadQoS(QoS_Level level);

/**
 * @brief Cancel the QoS level of the current thread.
 *
 * @return Returns int32_t, return value == 0, success, otherwise value == -1, failed.
 * @see QoS_Level
 * @since 12
 */
int OH_QoS_ResetThreadQoS();

/**
 * @brief Obtains the QoS level of the current thread.
 *
 * @param level This parameter is the output parameter,
 * and the QoS level of the thread as a {@link QoS_Level} is written to this variable.
 * @return Returns int32_t, return value == 0, success, otherwise value == -1, failed.
 * @see QoS_Level
 * @since 12
 */
int OH_QoS_GetThreadQoS(QoS_Level *level);

/**
 * @brief Session id
 *
 * @since 20
 */
typedef unsigned int OH_QoS_GewuSession;

/**
 * @brief Invalid session id for return.
 *
 * @since 20
 */
#define OH_QOS_GEWU_INVALID_SESSION_ID (static_cast<OH_QoS_GewuSession>(0xffffffffU))
/**
 * @brief Request id
 *
 * @since 20
 */
typedef unsigned int OH_QoS_GewuRequest;

/**
 * @brief Invalid request id for return.
 *
 * @since 20
 */
#define OH_QOS_GEWU_INVALID_REQUEST_ID (static_cast<OH_QoS_GewuRequest>(0xffffffffU))


/**
 * @brief Gewu error codes.
 *
 * @since 20
 */
typedef enum {
    /**
     * @brief Success
     */
    OH_QOS_GEWU_OK     = 0,

    /**
     * @brief No permission
     */
    OH_QOS_GEWU_NOPERM = 201,

    /**
     * @brief No memory
     */
    OH_QOS_GEWU_NOMEM  = 203,

    /**
     * @brief Invalid argument
     */
    OH_QOS_GEWU_INVAL  = 401,

    /**
     * @brief Duplicate id
     */
    OH_QOS_GEWU_EXIST  = 501,

    /**
     * @brief No entry found  
     */
    OH_QOS_GEWU_NOENT  = 502,

    /**
     * @brief Function not implemented
     */
    OH_QOS_GEWU_NOSYS  = 801,

    /**  
     * @brief Other fault
     */
    OH_QOS_GEWU_FAULT  = 901,
} OH_QoS_GewuErrorCode;

/**
 * @brief The result of GewuCreateSession
 *
 * @since 20
 */
typedef struct {
    /**
     * @brief The created session id
     */
    OH_QoS_GewuSession session;
    /**
     * @brief Error code of CreateSession
     *
     *        - OH_QOS_GEWU_OK will be returned if the session is created successfully.
     *
     *        - OH_QOS_GEWU_NOMEM will be returned if the system does not have sufficient memory to
     *          create the session.
     */
    OH_QoS_GewuErrorCode error;
} OH_QoS_GewuCreateSessionResult;

/**
 * @brief The result of GewuSubmitRequest
 *
 * @since 20
 */
typedef struct {
    /**
     * @brief The created request id
     */
    OH_QoS_GewuRequest request;

    /**
     * @brief Error code of request submission
     *
     *        - OH_QOS_GEWU_OK will be returned if the session is created successfully.
     *
     *        - OH_QOS_GEWU_NOMEM will be returned if the system does not have sufficient memory to
     *          create the session.
     */
    OH_QoS_GewuErrorCode error;
} OH_QoS_GewuSubmitRequestResult;


/**
 * @brief Callback to receive response of the request.
 *
 * @param context The user context specified when submitting the request.
 * @param reponse The json string of the response, including the following parameters:
 *        - message: A message that contains the following fields.
 *            - role: string. Must be "assistant".
 *            - content: string. The message generated by the model in response to user messages.
 *        - finish_reason: string or null. The reason the inference stopped. Possible values:
 *            - null: Not finished yet, only present in streaming mode.
 *            - "stop": The model stopped natually.
 *            - "abort": The inference request was aborted.
 *            - "length": The generated tokens reached the limit.
 *
 * @since 20
 */
typedef void (*OH_QoS_GewuOnResponse)(void* context, const char* response);

/**
 * @brief Create a gewu session for inference.
 * The lifecycle of the returned session object spans from the return of CreateSession
 * to the call to DestroySession.
 *
 * json string of session attributes.
 *
 * The json string of session attributes include the following parameters
 *     - model: string. The directory of the model of the session.
 *
 * An example of json string of session attributes:
 * @code{.json}
 * {
 *     "model": "/data/storage/el2/base/files/qwen2/"
 * }
 * @endcode
 *
 * @param attributes The json string of session attributes.
 *
 * @return Result of CreateSession.
 *
 * @since 20
 */
OH_QoS_GewuCreateSessionResult OH_QoS_GewuCreateSession(const char* attributes);

/**
 * @brief Destroy the specified session.
 * It is recommended that the client shall wait until all ongoing requests are done before calling
 * this interface to destroy the session. If there are remaining requests in the session when this
 * interface is called, those requests will be aborted and no further responses for those requests
 * will be sent to the client.
 * Note that after calling this function successfully, the session cannot be used by the user code
 * any more.
 *
 * @param session The session that will be destroyed.
 *
 * @return Error code.
 *         - OH_QOS_GEWU_OK will be returned if the session is destroyed successfully.
 *         - OH_QOS_GEWU_NOENT will be returned if the session is not found.
 *
 * @since 20
 */
OH_QoS_GewuErrorCode OH_QoS_GewuDestroySession(OH_QoS_GewuSession session);

/**
 * @brief Abort the specified request.
 * Note that after calling this function successfully, the client will not receive further responses
 * for this request, and the request object cannot be used by the user code any more.
 *
 * @param session The session that the request was submitted through.
 * @param request The request object.
 *
 * @return Error code.
 *         - OH_QOS_GEWU_OK will be returned if the request is aborted successfully.
 *         - OH_QOS_GEWU_NOENT will be returned if the request is not found.
 *
 * @since 20
 */
OH_QoS_GewuErrorCode OH_QoS_GewuAbortRequest(OH_QoS_GewuSession session, OH_QoS_GewuRequest request);

/**
 * @brief Submit a request.
 *
 * json string of completion request.
 * Completion request is a json string that specifies the following parameters:
 *     - messages: array. A list of messages. Each message contains the following fields:
 *         - role: string. The message type, which could be one of the following:
 *             - "developer": Developer-provided instructions.
 *             - "user": User-provided instructions.
 *             - "assistant": Message generated by the model in response to user messages.
 *         - content: string. The message content.
 *     - stream: boolean or null; optional. Enable streaming mode or not. If set to true, partial
 *       responses will be sent. If null or not set, defaults to nonstreaming mode.
 *
 * An example of completion request:
 * @code{.json}
 * {
 *      "messages": [
 *          {
 *              "role": "developer",
 *              "content": "You are a helpful assistant."
 *          },
 *          {
 *              "role": "user",
 *              "content": "What is OpenHarmony"
 *          }
 *      ],
 *      "stream": true
 * }
 * @endcode
 *
 * @param session The session object that the request should be submitted through.
 * @param request The json string of request.
 * @param callback The callback to receive response.
 * @param context The user context that should be passed to the response callback.
 *
 * @return Gewu request submission result.
 *         - OH_QOS_GEWU_OK will be returned if the request is accepted.
 *         - OH_QOS_GEWU_NOMEM will be returned if the system does not have sufficient memory
 *           to accept the request.
 *
 * @since 20
 */
OH_QoS_GewuSubmitRequestResult OH_QoS_GewuSubmitRequest(OH_QoS_GewuSession session, const char* request,
    OH_QoS_GewuOnResponse callback, void* context);

/**
 * @brief xxx
 *
 * @param coInfo xxx
 *
 * @return Error code.
 *
 * @since 20
 */
OH_QoS_GewuErrorCode OH_QoS_GewuEnableCollaboration(const char* coInfo);

/**
 * @brief xxx
 *
 *
 * @return Error code.
 *
 * @since 20
 */
OH_QoS_GewuErrorCode OH_QoS_GewuDisableCollaboration();
#ifdef __cplusplus
};
#endif
#endif //QOS_H
