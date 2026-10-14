/*
 * qwenvl_engine 空实现（stub）。
 *
 * 什么时候编这个文件：src/main/cpp/libs/<arch>/libqwen2vl_sdk.so 不存在，
 * 也就是那批私有预编译库没有放到本机。见 CMakeLists.txt 的前置判断。
 *
 * 为什么要有它：ArkTS 侧（llm/QwenVlManager.ets）对 'libqwenvl_engine.so' 是
 * 静态 import，模块必须存在。让两条分支产出同一个模块名、同一套导出面，
 * 就不需要条件编译，也不会有动态 import 的兼容问题：
 *   - 缺库 → 应用照常构建、照常运行，只跑纯文本（文字 GEWU 引擎不受影响）；
 *   - 带图请求 → start() 返回 false，VlLlmTransport/QwenVlManager 会把
 *     「引擎不可用」如实报给 UI，不会静默空转。
 *
 * 导出面必须与 napi_engine.cpp 完全一致：
 *   start(modelDir, imagePath, prompt) -> boolean
 *   takeEvents() -> string[]
 *   complete() / cancel() / release()
 * 模块名：qwenvl_engine
 */

#include <napi/native_api.h>
#include <hilog/log.h>

namespace {

constexpr const char* TAG = "QwenVlStub";

napi_value Start(napi_env env, napi_callback_info info)
{
    OH_LOG_WARN(LOG_APP,
                "[%{public}s] Qwen2.5-VL engine is not built into this HAP "
                "(private libraries missing); refusing to start",
                TAG);
    napi_value ret;
    napi_get_boolean(env, false, &ret);
    return ret;
}

napi_value TakeEvents(napi_env env, napi_callback_info info)
{
    napi_value arr;
    napi_create_array_with_length(env, 0, &arr);
    return arr;
}

napi_value Complete(napi_env env, napi_callback_info info)
{
    return nullptr;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    return nullptr;
}

napi_value Release(napi_env env, napi_callback_info info)
{
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    // available=false：告诉 ArkTS 侧「这个构建里没有真引擎」，而不是让它去猜。
    napi_value available;
    napi_get_boolean(env, false, &available);
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeEvents", nullptr, TakeEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"complete", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"available", nullptr, nullptr, nullptr, nullptr, available, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

} // namespace

static napi_module module = {1, 0, nullptr, Init, "qwenvl_engine", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterQwenVlEngineStub()
{
    napi_module_register(&module);
}
