/*
 * qwenvl_engine: Qwen2.5-VL-7B-Q4_0 CPU 多模态推理 NAPI 封装。
 *
 * 桥接 libqwen2vl_sdk.so（C SDK，引擎静态链接在内部）：
 * - start(modelDir, imagePath, prompt)：后台线程执行多模态 chat；
 *   首次调用时懒加载引擎（create+load，约数秒~数十秒），此后缓存复用，
 *   直到 release()/进程退出。
 * - 每个生成 token 经 callback 写入事件队列 {"event":"response","payload":文本}，
 *   ArkTS 侧轮询 takeEvents() 消费（与 llm 模块同契约）。
 * - cancel() 置 SDK 取消标志（下个 token 边界停止）；complete() 清理本轮。
 *
 * 门槛：引擎只在本模块被显式 start() 时才创建——ArkTS 侧 QwenVlCpuManager
 * 在 app 模型设置为 Qwen2.5-VL-7B-Q4_0 时才调用，因此其他模型下引擎不会启动。
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <dirent.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

#include "qwen2vl_sdk.h"

/* ---- SDK 内部导出符号（libqwen2vl_sdk.so 静态链接的引擎日志系统）----
 * 引擎 log.cpp 的 init_logger() 依赖 dlopen("libhilog.so") + dlsym("HiLogPrint")：
 * 任一失败即静默 return false，info_logger 保持 nullptr，引擎首次 LOG()
 * （如 ParamHeader::log_sec_info）即空指针崩溃。
 * 注意：SDK 编译于 BiSheng libc++（std::__h 命名空间），本模块编译于 NDK
 * libc++（std::__n1），同名 C++ 符号无法静态链接，故此处用 dlsym 按 mangled
 * 名字动态获取后调用；两套 libc++ 的 basic_string 布局一致，可安全透传。
 */

#include <dlfcn.h>

namespace {

constexpr unsigned int QWENVL_LOG_DOMAIN = 0x0004;
const char* QWENVL_LOG_TAG = "QwenVlEngine";

struct State {
    std::mutex mutex;
    std::condition_variable wake;
    uintptr_t generation = 0;
    bool started = false;
    bool active = false;
    bool cancelled = false;
    bool completed = false;
    std::vector<std::string> events;

    // cached engine (created+loaded on first request, kept until release)
    Qwen2vlEngine* engine = nullptr;
    std::string engineModelDir;
    bool engineFailed = false;
    std::string engineFailure;

    // 重复循环检测（M25）：贪心采样无上界，模型陷入局部循环（如
    // "相机、相机、…"）时永不自停（不产 im_end）。记录最近 token 片段，
    // OnToken 发现连续相同片段 >= REPEAT_CUTOFF 即拉 qwen2vl_cancel。
    std::vector<std::string> recentPieces;
    bool repetitionCut = false;
    int repeatGeneration = 0;
};

State& S()
{
    static auto* s = new State;
    return *s;
}

/* B 方案：抢先初始化 SDK 引擎日志系统。
 * 1) RTLD_GLOBAL 预加载打包的 libhilog.so（完整路径），使 SDK 之后的
 *    dlopen("libhilog.so") 按已加载 DSO 的 shortname 命中，init_logger 的
 *    dlopen 探测成功；
 * 2) 用 dlopen("libqwen2vl_sdk.so") 拿 SDK 句柄（MMG 以 RTLD_LOCAL 加载，
 *    RTLD_DEFAULT 查不到其导出符号），再从该句柄 dlsym
 *    llm::init_logger（BiSheng std::__h mangled 名），传 "sys" 只挂
 *    SysLogger(HiLogPrint)，不涉及任何 std::cout。
 * 3) 该调用先于 SDK BootstrapOnce 的 init_logger("-")，使 info_logger 以
 *    "sys" 就绪，其后 SDK 重复调用因已初始化直接返回。
 * 4) C++ 侧 OH_LOG 在此设备未观测到输出，故同时把关键结果落地诊断文件，
 *    便于 hdc 直接读取验证。
 */
/* ---- 诊断落盘（三候选路径，任一成功即止；全失败时 OH_LOG 兜底）---- */
void AppendDiag(const std::string& line)
{
    static const char* kDiagPaths[3] = {
        // 沙箱视角 App 可写（bundle 级 cache，20020230 属主；物理 =
        // /data/app/el2/100/base/com.jiuwen.registrychatui/cache/）
        "/data/storage/el2/base/cache/qwenvl_preflight.txt",
        "/data/storage/el2/base/haps/entry/files/qwenvl_preflight.txt",
        "/data/app/el2/100/base/com.jiuwen.registrychatui/cache/qwenvl_preflight.txt",
    };
    auto nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    for (int i = 0; i < 3; i++) {
        FILE* f = fopen(kDiagPaths[i], "a");
        if (f != nullptr) {
            fprintf(f, "[%lld] %s\n", (long long)nowMs, line.c_str());
            fclose(f);
            OH_LOG_ERROR(LOG_APP, "PREFLIGHT wrote[%{public}d] %{public}s", i, line.c_str());
            return;
        }
    }
    OH_LOG_ERROR(LOG_APP, "PREFLIGHT fopen all failed: %{public}s errno=%{public}d",
        line.c_str(), errno);
}

/* 读取 SDK 导出的 global_info_logger（ComposeLogger unique_ptr 内容）：
 * 非空证明 SDK bss 静态初始化已完成，且可验证我们访问的就是 SDK 实例
 * global_info_logger 位于 0x891f08；紧随其后（bss 连续）:
 *   0x891f18 = info_logger (unique_ptr<LoggerStream> 原始指针)
 *   0x891f20 = err_logger
 *   0x891f28 = HiLogPrint 函数指针
 * 这些偏移来自对 sdk_clean_patched.so 的反汇编（init_logger 存 info_logger 于
 * [x22,#3864]=0x891f18，存 err_logger 于 [x21,#3872]=0x891f20，
 * 存 HiLogPrint 于 [x8,#3880]=0x891f28；llm::LOG()/@0x3b4058
 * 读 [x8,#3864]=0x891f18）。直接读它们可判定 init_logger
 * 是否真的写入了 logger（而不只是返回 1）。
 * 返回 info_logger 原始指针值（0 = 未就绪）。
 */
uintptr_t DumpLoggerSnapshot(const char* tag)
{
    void* sdk = dlopen("libqwen2vl_sdk.so", RTLD_NOW | RTLD_LOCAL);
    if (sdk == nullptr) {
        AppendDiag(std::string(tag) + " dlopen-sdk-fail");
        return 0;
    }
    void* gInfoSym = dlsym(sdk, "_ZN3llm18global_info_loggerE");
    if (gInfoSym == nullptr) {
        AppendDiag(std::string(tag) + " dlsym-gInfo-fail");
        return 0;
    }
    unsigned char* base = reinterpret_cast<unsigned char*>(gInfoSym);
    void* gi = *reinterpret_cast<void**>(base);
    void* bi = *reinterpret_cast<void**>(base + 0x10);
    void* be = *reinterpret_cast<void**>(base + 0x18);
    void* bh = *reinterpret_cast<void**>(base + 0x20);
    char buf[192];
    snprintf(buf, sizeof(buf), "%s gInfo=%p info=%p err=%p hilog=%p",
        tag, gi, bi, be, bh);
    AppendDiag(buf);
    return reinterpret_cast<uintptr_t>(bi);
}

void EnginePreflightLogger()
{
    // 注意：不能依赖 static bool done 短路 —— MMG 可能在 appspawn 预加载了
    // 本 so（constructor 在预加载进程跑过，static 状态被 fork 继承置位），
    // 导致 app 进程内后续调用全部静默跳过。因此每次调用都执行并写盘。
    // 诊断：无论 fopen 成败都把进度用 OH_LOG 落地（faultlog PAST_LOG 可见）
    OH_LOG_ERROR(LOG_APP, "PREFLIGHT enter pid=%{public}d", (int)getpid());
    AppendDiag("preflight begin");

    void* hlog = dlopen("/data/storage/el1/bundle/libs/arm64/libhilog.so",
                        RTLD_NOW | RTLD_GLOBAL);
    if (hlog == nullptr) {
        hlog = dlopen("libhilog.so", RTLD_NOW | RTLD_GLOBAL);
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "preload libhilog handle=%p", hlog);
    AppendDiag(buf);

    void* sdk = dlopen("libqwen2vl_sdk.so", RTLD_NOW | RTLD_LOCAL);
    snprintf(buf, sizeof(buf), "dlopen sdk handle=%p", sdk);
    AppendDiag(buf);

    using InitLoggerFn = bool (*)(const std::string&);
    InitLoggerFn initLogger = nullptr;
    if (sdk != nullptr) {
        initLogger = reinterpret_cast<InitLoggerFn>(dlsym(
            sdk,
            "_ZN3llm11init_loggerERKNSt3__h12basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEE"));
    }
    snprintf(buf, sizeof(buf), "dlsym init_logger=%p", (void*)initLogger);
    AppendDiag(buf);
    if (initLogger == nullptr) {
        AppendDiag("dlsym llm::init_logger failed");
        return;
    }

    uintptr_t infoPtr = DumpLoggerSnapshot("BEFORE");

    bool ok = false;
    try {
        ok = initLogger(std::string("sys"));
    } catch (...) {
        ok = false;
    }
    snprintf(buf, sizeof(buf), "init_logger(\"sys\") ret=%d", ok ? 1 : 0);
    AppendDiag(buf);
    infoPtr = DumpLoggerSnapshot("AFTER-sys");

    // 若 "sys" 未能真正写入 info_logger，再试 "-"（ConsoleLogger/std::cout 不依赖
    // ENABLE_SYSLOGGER 宏；若 iostream 状态可用则更稳）
    if (infoPtr == 0) {
        ok = false;
        try {
            ok = initLogger(std::string("-"));
        } catch (...) {
            ok = false;
        }
        snprintf(buf, sizeof(buf), "init_logger(\"-\") ret=%d", ok ? 1 : 0);
        AppendDiag(buf);
        DumpLoggerSnapshot("AFTER-minus");
    }

    // ---- SDK 全局内存管理器初始化 ----
    // qwen2vl_create() 不初始化 llm::GlobalMemoryManager::gmm_（bss 0x891f38，
    // GOT 0x8837F0 GLOB_DAT），而 load → ParamManager::instant_load 直接
    // 解引用 gmm_（虚调用），gmm_ == NULL → SIGSEGV。实证：02:35 崩溃栈
    // #00 instant_load+136 = ldr x8,[x0]（x0=*gmm_=0）。
    // instant_load 入口先检查 gmm_init_flag_(0x891f30) == -1：
    //   - 是 → 直接用 gmm_（跳过初始化）；
    //   - 否 → call_once 初始化（回调位于 SDK 内部，同样走 make_cpu_gmm）。
    // 受限于双 libc++，无法静态链接 SDK 的 make_cpu_gmm，这里 dlsym 直调：
    //   make_cpu_gmm() 是 GLOBAL 导出、无参、仅 new(72B)+清零+vtable，无副作用；
    //   再把 gmm_ 写成实例并置 flag=-1，让 instant_load 的 call_once 短路。
    {
        void* makeCpuGmmSym = dlsym(sdk, "_ZN3llm12make_cpu_gmmEv");
        if (makeCpuGmmSym != nullptr) {
            // make_cpu_gmm 是 C++ 按值返回对象（AArch64 sret 约定：调用者用 x8
            // 传返回槽指针，函数把 new 出的对象指针存入 [x8]）。
            // 若按 C 惯例声明 void*(*)() 调用，x8 是未定义残留值 → 写任意地址
            // 崩溃（实证 03:07 make_cpu_gmm+36 str x0,[x19] SEGV_ACCERR）。
            // 因此声明一个 >16 字节返回结构，让编译器生成 sret 调用：
            struct GmmRet { void* obj; unsigned char pad[64]; };
            using MakeGmmFn = GmmRet (*)();
            GmmRet ret = reinterpret_cast<MakeGmmFn>(makeCpuGmmSym)();
            void* cpuGmm = ret.obj;
            snprintf(buf, sizeof(buf), "make_cpu_gmm=%p", cpuGmm);
            AppendDiag(buf);
            if (cpuGmm != nullptr) {
                void** gmmSlot = static_cast<void**>(dlsym(
                    sdk, "_ZN3llm19GlobalMemoryManager4gmm_E"));
                volatile long long* flagSlot = static_cast<volatile long long*>(
                    dlsym(sdk, "_ZN3llm19GlobalMemoryManager14gmm_init_flag_E"));
                if (gmmSlot != nullptr && flagSlot != nullptr) {
                    *gmmSlot = cpuGmm;
                    *flagSlot = -1LL;
                    AppendDiag("gmm_ set, gmm_init_flag_=-1");
                } else {
                    AppendDiag("dlsym gmm_/flag failed");
                }
            }
        } else {
            AppendDiag("dlsym make_cpu_gmm failed");
        }
    }
}

std::string Quote(const std::string& v)
{
    std::string out = "\"";
    for (unsigned char c : v) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += c;
        } else if (c < 32) {
            const char* hex = "0123456789abcdef";
            out += "\\u00";
            out += hex[c >> 4];
            out += hex[c & 15];
        } else {
            out += c;
        }
    }
    return out + "\"";
}

void EventLocked(State& s, const std::string& event, const std::string& payload = "")
{
    s.events.push_back("{\"event\":" + Quote(event) + ",\"payload\":" + Quote(payload) + "}");
}

void Event(const std::string& event, const std::string& payload = "")
{
    auto& s = S();
    std::lock_guard<std::mutex> lock(s.mutex);
    EventLocked(s, event, payload);
}

/* SDK streaming callback -> event queue（文本分片，可能切分 UTF-8 多字节字符）。 */
/* M25 重复循环掐断：贪心采样无上界，模型陷入局部循环时永不自停（不产
 * im_end）。累计最近 REPEAT_CUTOFF 个分片，若全部相同（或第 1 个与第
 * N 个一致且中间全相同）则判定重复循环，立即 qwen2vl_cancel 掐断，
 * 并隔离后续分片（只保留首个、记录标记，供上层得知被截断）。 */
void OnToken(void* userdata, const char* text)
{
    auto& s = *static_cast<State*>(userdata);
    std::lock_guard<std::mutex> lock(s.mutex);
    if (!s.active || reinterpret_cast<uintptr_t>(&s) != s.generation || text == nullptr) {
        return;
    }
    // Qwen2.5-VL 的结束符（im_end / endoftext）会经回调原样透传；这里过滤，
    // 使 answer 只含真实内容，空输出也能被上层正确判定为"无回应"并触发重试。
    if (strcmp(text, "<|im_end|>") == 0 || strcmp(text, "<|endoftext|>") == 0 ||
        (text[0] == '<' && strchr(text, '|') != nullptr && strstr(text, "im_end") != nullptr)) {
        // 已经陷入重复循环的结束符（如循环体恰为 "<|im_end|>"）不需要再回调
        if (s.repetitionCut) {
            return;
        }
    }
    // 重复循环检测：同一 generation 内连续相同分片 >= REPEAT_CUTOFF 次
    const size_t REPEAT_CUTOFF = 8;
    if (s.repeatGeneration != static_cast<int>(s.generation)) {
        s.repeatGeneration = static_cast<int>(s.generation);
        s.recentPieces.clear();
        s.repetitionCut = false;
    }
    if (!s.repetitionCut && s.active) {
        std::string piece(text);
        if (!s.recentPieces.empty() && s.recentPieces.back() == piece) {
            s.recentPieces.push_back(piece);
        } else {
            s.recentPieces.clear();
            s.recentPieces.push_back(piece);
        }
        if (s.recentPieces.size() >= REPEAT_CUTOFF && s.engine != nullptr) {
            // 连续 8+ 次同一分片 = 重复循环，立即掐断（后续分片丢弃）。
            // 前 7 次重复已各发出一次（UI 已见），不需要回放。
            s.repetitionCut = true;
            char db[160];
            snprintf(db, sizeof(db), "repeat-cut: repeated piece len=%zu (x%zu) -> cancel",
                piece.size(), s.recentPieces.size());
            AppendDiag(db);
            qwen2vl_cancel(s.engine);
            return;
        }
    }
    EventLocked(s, "response", text);
}

/* ---- IOManager 单例重建（B4 修复）----
 * 现象链：load 卡 IOCounter::wait_inflight_io_done（inflight>0 永不清零），
 * 进程 read_bytes≈4096（IO 线程从未 sync_read），线程列表中无 SDK io 线程。
 * 反汇编 sdk_clean_patched.so：IOManager::getInstance 用 __cxa_guard
 * (bss VMA 0x892028) 保护 static 单例（instance bss VMA 0x891F40）；
 * guard 一旦置位（appspawn 预加载 / fork 继承 / 历史构造过），getInstance
 * 直接返回旧实例（0x3b8858 路径），不会重建 io_thread_ → add_reqs 入队后
 * 无人消费 → wait_inflight_io_done 永等。
 * 修复：dlsym getInstance 拿运行时地址，反推 .so 基址（getInstance 自身
 * VMA=0x3b8828），清零 guard，再调 getInstance(0,"sync",0) 强制重建单例
 * （SYNC 后端，app 进程内真实创建 io_thread_）。
 * std::__h::basic_string 24B SSO：byte0 = len<<1，数据自 byte1 起。
 */
static void EnginePrimeIOManager()
{
    void* sdk = dlopen("libqwen2vl_sdk.so", RTLD_NOW | RTLD_LOCAL);
    if (sdk == nullptr) {
        AppendDiag("prime-io dlopen-sdk-fail");
        return;
    }
    typedef void* (*GetInstanceFn)(int, const void*, int);
    void* sym = dlsym(
        sdk,
        "_ZN3llm9IOManager11getInstanceEiRKNSt3__h12basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEi");
    if (sym == nullptr) {
        AppendDiag("prime-io dlsym-getInstance-fail");
        return;
    }
    uintptr_t base = reinterpret_cast<uintptr_t>(sym) - 0x3b8828ULL;
    volatile uint32_t* guard = reinterpret_cast<volatile uint32_t*>(base + 0x892028ULL);
    uint32_t oldGuard = *guard;
    *guard = 0; /* 清 guard → 下一次 getInstance 走 __cxa_guard_acquire 重建 */

    char sso[24];
    memset(sso, 0, sizeof(sso));
    sso[0] = static_cast<char>(4 << 1); /* SSO short 长度标志（4<<1=8） */
    memcpy(sso + 1, "sync", 4);         /* 数据（byte5=0 结尾已在 memset） */

    void* inst = (reinterpret_cast<GetInstanceFn>(sym))(0, sso, 0);
    char db[192];
    snprintf(db, sizeof(db), "prime-io oldGuard=%u inst=%p expect=%p", oldGuard, inst,
        reinterpret_cast<void*>(base + 0x891F40ULL));
    AppendDiag(db);
}

/* /proc/self/task 目录项数 = 进程线程数（诊断 IO 线程是否创建） */
static long CountProcThreads()
{
    long n = 0;
    DIR* d = opendir("/proc/self/task");
    if (d != nullptr) {
        struct dirent* e;
        while ((e = readdir(d)) != nullptr) {
            if (e->d_name[0] != '.') {
                n++;
            }
        }
        closedir(d);
    }
    return n;
}

/* 懒加载引擎（首次 start 时，加载约 5.3GB 权重，阻塞数十秒）。 */
bool EnsureEngine(State& s, const std::string& modelDir, std::string& failure)
{
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.engineFailed) {
        failure = s.engineFailure;
        return false;
    }
    if (s.engine != nullptr && s.engineModelDir == modelDir) {
        return true;
    }
    if (s.engine != nullptr) {
        qwen2vl_destroy(s.engine);
        s.engine = nullptr;
        s.engineModelDir.clear();
    }
    s.mutex.unlock();

    // 构建默认 CPU 配置（vl_params + tokenizer.json 位于 modelDir 下）
    auto t0 = std::chrono::steady_clock::now();
    const char* cfg = qwen2vl_default_config(modelDir.c_str());
    if (cfg == nullptr) {
        s.mutex.lock();
        s.engineFailed = true;
        s.engineFailure = "无效的模型目录";
        return false;
    }
    OH_LOG_INFO(LOG_APP, "modelDir=%{public}s config built, %lld ms", modelDir.c_str(),
        (long long)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count());

    // B 方案：抢先初始化引擎日志系统。SDK 的 BootstrapOnce 在 create 时调用
    // init_logger("-")，其内 dlopen("libhilog.so")/dlsym("HiLogPrint") 任一
    // 失败即静默 return false → info_logger 保持 nullptr → load 的
    // log_sec_info() 空指针崩溃；即便成功，"-" 挂 ConsoleLogger(std::cout)，
    // 而本进程三套 libc++ 并存，std::cout 状态不可靠。
    // EnginePreflightLogger()：预加载 libhilog.so + dlsym 调 init_logger("sys")
    //（只挂 SysLogger/HiLogPrint，不碰 std::cout），并先于 SDK 自身初始化。
    EnginePreflightLogger();

    // B4：重建 IOManager 单例（若 guard 已置位则强制重建，确保 app 进程内
    // 真实创建 SYNC io_thread_），并记录重建前后线程数。
    {
        char db[128];
        snprintf(db, sizeof(db), "prime-io threads-before=%ld", CountProcThreads());
        AppendDiag(db);
    }
    // A2（A 方案纯净验证）：新 SDK 的 BootstrapOnce 已改 static InitHelper，
    // create 内 llm_init 不再被 finalize，IOManager 实例存活、IO 线程在位。
    // B4 的 guard 清零重建会与活实例冲突（A1 实测 load 后权重未加载、
    // 全部线程 sleeping）。故 A2 起停用 create 前的 prime-io 重建。
    // EnginePrimeIOManager();
    {
        char db[128];
        snprintf(db, sizeof(db), "prime-io threads-after=%ld", CountProcThreads());
        AppendDiag(db);
    }

    Qwen2vlEngine* e = qwen2vl_create(cfg);
    {
        char db[128];
        snprintf(db, sizeof(db), "create ret=%p %lldms", (void*)e,
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count());
        AppendDiag(db);
    }
    if (e == nullptr) {
        AppendDiag("create failed");
        s.mutex.lock();
        s.engineFailed = true;
        s.engineFailure = "引擎创建失败";
        return false;
    }
    // 探针：create 成功后立刻再测全局 info_logger —— 若 SDK 在 create 内
    // 重置/清空了 logger，这里 info 会显示 0，而 load 的 log_sec_info 就会崩。
    // 实证（02:16 探针）：AFTER-sys info=0x5af9f80ef0 非空 →
    //                    AFTER-create info=0 err=0 → SDK create 清空了 logger！
    // 修复：create 之后重新 init_logger("sys")，把 info_logger 重新写回，
    // 确保 load 前 logger 就绪。
    DumpLoggerSnapshot("AFTER-create");
    EnginePreflightLogger();
    DumpLoggerSnapshot("AFTER-reinit");
    OH_LOG_INFO(LOG_APP, "engine create ok, %lld ms",
        (long long)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count());
    // A2：同上，create 后无需再重建 IO（新 SDK static InitHelper 已保活）。
    // 原 B5 重建在此（create 后、load 前），A2 起停用。
    // EnginePrimeIOManager();
    {
        char db[128];
        snprintf(db, sizeof(db), "prime-io threads-preload=%ld", CountProcThreads());
        AppendDiag(db);
    }
    int rc = qwen2vl_load(e);
    {
        char db[160];
        snprintf(db, sizeof(db), "load ret=%d %lldms", rc,
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count());
        AppendDiag(db);
    }
    OH_LOG_INFO(LOG_APP, "engine load ret=%{public}d, %lld ms", rc,
        (long long)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count());
    if (rc != QWEN2VL_OK) {
        std::string err = qwen2vl_last_error(e);
        qwen2vl_destroy(e);
        s.mutex.lock();
        s.engineFailed = true;
        s.engineFailure = "权重加载失败: " + err;
        return false;
    }

    s.mutex.lock();
    s.engine = e;
    s.engineModelDir = modelDir;
    s.engineFailed = false;
    s.engineFailure.clear();
    return true;
}

void Run(std::string modelDir, std::string imagePath, std::string prompt, uintptr_t generation)
{
    auto t0 = std::chrono::steady_clock::now();
    auto& s = S();
    {
        char db[320];
        snprintf(db, sizeof(db), "Run in: imageLen=%zu imageHead=%.40s promptHead=%.60s",
            imagePath.size(), imagePath.c_str(), prompt.c_str());
        AppendDiag(db);
    }
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.active && reinterpret_cast<uintptr_t>(&s) == generation) {
            EventLocked(s, "load", "loading");
        }
    }

    std::string failure;
    if (!EnsureEngine(s, modelDir, failure)) {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.active && reinterpret_cast<uintptr_t>(&s) == generation) {
            EventLocked(s, "error", failure);
            EventLocked(s, "end", "error");
            s.active = false;
            s.started = false;
        }
        return;
    }

    Qwen2vlEngine* e = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        e = s.engine;
    }
    int rc = qwen2vl_chat(e, imagePath.c_str(), prompt.c_str(), OnToken, &s);

    {
        char db[200];
        const std::string ler = qwen2vl_last_error(e);
        snprintf(db, sizeof(db), "chat rc=%d %lldms gen=%llu last_err=%s",
            rc,
            (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count(),
            (unsigned long long)generation, ler.c_str());
        AppendDiag(db);
    }

    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.active && reinterpret_cast<uintptr_t>(&s) == generation) {
        if (rc == QWEN2VL_ERR_CANCELLED) {
            // M25：重复循环被 OnToken 自动掐断视为正常结束（stop），
            // 上层不会显示"已停止生成"；用户主动取消仍是 cancelled。
            EventLocked(s, "end", s.repetitionCut ? "stop" : "cancelled");
        } else if (rc != QWEN2VL_OK) {
            EventLocked(s, "error", qwen2vl_last_error(e));
            EventLocked(s, "end", "error");
        } else {
            EventLocked(s, "end", "stop");
        }
        s.active = false;
        s.started = false;
    }
    s.wake.notify_all();
}

/* ---------------- NAPI ---------------- */

napi_value Start(napi_env env, napi_callback_info info)
{
    AppendDiag("NAPI-Start entered");
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string modelDir, imagePath, prompt;
    auto readStr = [&](napi_value v, std::string& out) {
        size_t len = 0;
        napi_get_value_string_utf8(env, v, nullptr, 0, &len);
        out.resize(len);
        napi_get_value_string_utf8(env, v, out.data(), len + 1, &len);
    };
    if (argc >= 1) {
        readStr(argv[0], modelDir);
    }
    if (argc >= 2) {
        readStr(argv[1], imagePath);
    }
    if (argc >= 3) {
        readStr(argv[2], prompt);
    }

    auto& s = S();
    uintptr_t gen = 0;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        if (s.started) {
            napi_value ret;
            napi_get_boolean(env, false, &ret);
            return ret;
        }
        s.started = true;
        s.active = true;
        s.cancelled = false;
        s.completed = false;
        s.events.clear();
        s.generation = reinterpret_cast<uintptr_t>(&s);
        gen = s.generation;
        EventLocked(s, "load", "loading");
    }

    std::thread([modelDir, imagePath, prompt, gen] {
        Run(modelDir, imagePath, prompt, gen);
    }).detach();

    napi_value ret;
    napi_get_boolean(env, true, &ret);
    return ret;
}

napi_value TakeEvents(napi_env env, napi_callback_info info)
{
    auto& s = S();
    std::lock_guard<std::mutex> lock(s.mutex);
    napi_value arr;
    napi_create_array_with_length(env, s.events.size(), &arr);
    for (size_t i = 0; i < s.events.size(); ++i) {
        napi_value v;
        napi_create_string_utf8(env, s.events[i].c_str(), s.events[i].size(), &v);
        napi_set_element(env, arr, i, v);
    }
    s.events.clear();
    return arr;
}

napi_value Complete(napi_env env, napi_callback_info info)
{
    auto& s = S();
    std::lock_guard<std::mutex> lock(s.mutex);
    s.completed = true;
    s.wake.notify_all();
    return nullptr;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    auto& s = S();
    Qwen2vlEngine* e = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        s.cancelled = true;
        e = s.engine;
    }
    if (e != nullptr) {
        qwen2vl_cancel(e);
    }
    return nullptr;
}

napi_value Release(napi_env env, napi_callback_info info)
{
    auto& s = S();
    Qwen2vlEngine* e = nullptr;
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        e = s.engine;
        s.engine = nullptr;
        s.engineModelDir.clear();
        s.engineFailed = false;
        s.engineFailure.clear();
    }
    if (e != nullptr) {
        qwen2vl_destroy(e);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeEvents", nullptr, TakeEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"complete", nullptr, Complete, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

} // namespace

static napi_module module = {1, 0, nullptr, Init, "qwenvl_engine", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterQwenVlEngine()
{
    // 无人值守循环：模块加载即执行日志预检（早于任何 SDK create/load），
    // 使 `aa start` 即可触发闭环验证，无需等待用户发图。
    EnginePreflightLogger();
    napi_module_register(&module);
}
