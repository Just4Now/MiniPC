// c++ -std=c++17 -pthread gewu_probe_lifecycle.cpp -o /tmp/gewu-probe-test && /tmp/gewu-probe-test
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#define GEWU_PROBE_TEST
#define OH_LOG_Print(...) ((void)0)
constexpr int OH_QOS_GEWU_OK = 0;
struct Result { int error; int session; int request; };
static std::atomic<int> creates{0}, submits{0}, destroys{0}, aborts{0};
static std::atomic<bool> holdCreate{false}, inCreate{false};
static int mode = 0;
static void* savedContext;
static void (*savedCallback)(void*, const char*);
static void CompleteJob(uintptr_t);
static void Notify(bool);
static Result OH_QoS_GewuCreateSession(const char*) {
    ++creates;
    inCreate = true;
    while (holdCreate) std::this_thread::yield();
    return {mode == 1 ? 401 : 0, 1, 0};
}
static Result OH_QoS_GewuSubmitRequest(int, const char*, void (*cb)(void*, const char*), void* ctx) {
    ++submits;
    savedCallback = cb; savedContext = ctx;
    if (mode == 4) return {0, 1, 2};
    cb(ctx, "synchronous response");
    if (mode == 0) CompleteJob(reinterpret_cast<uintptr_t>(ctx));
    return {mode == 2 ? 401 : 0, 1, 2};
}
static int OH_QoS_GewuAbortRequest(int, int) { ++aborts; return 0; }
static int OH_QoS_GewuDestroySession(int) { ++destroys; return 0; }
void TestUtf8Carry();
#include "../gewu_probe.cpp"
static void WaitDone() {
    for (int i = 0; i < 5000; ++i) {
        { std::lock_guard<std::mutex> lock(State().mutex); if (!State().started) return; }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(false && "worker never completed");
}
int main() {
    TestUtf8Carry();
    const auto root = std::filesystem::temp_directory_path() / "gewu-probe-lifecycle";
    std::filesystem::create_directories(root);
    for (auto name : {"api_config.json", "tokenizer.json", "params"}) std::ofstream(root / name) << "x";
    auto start = [&] { return Begin(root.string(), "{}", (root / "events.jsonl").string()); };
    for (int i = 0; i < 20; ++i) { assert(start()); WaitDone(); }
    assert(creates == 20 && submits == 20 && destroys == 20);
    auto oldContext = savedContext;
    mode = 3; holdCreate = true; inCreate = false;
    assert(start()); assert(start()); assert(start());
    while (!inCreate) std::this_thread::yield();
    Notify(true); holdCreate = false; WaitDone();
    assert(submits == 20 && destroys == 23); // three jobs cancelled before submit
    mode = 1; assert(start()); WaitDone(); // create failure still allows retry
    mode = 2; assert(start()); WaitDone(); // submit failure destroys session
    const int submittedBefore = submits.load();
    mode = 3; assert(start());
    while (submits.load() == submittedBefore) std::this_thread::yield();
    savedCallback(oldContext, "STALE");
    { std::lock_guard<std::mutex> lock(State().mutex);
      for (const auto& e : State().events) assert(e.find("STALE") == std::string::npos); }
    Notify(true); WaitDone(); assert(aborts == 1);
    mode = 0; assert(start()); WaitDone();
    mode = 3;
    const uintptr_t a = start();
    const uintptr_t b = start();
    const uintptr_t c = start();
    assert(a && b && c && a != b && b != c && a != c);
    Notify(true); WaitDone();
    mode = 0;
    assert(Begin("/does-not-exist", "{}", (root / "events.jsonl").string())); WaitDone();
    assert(start()); WaitDone();
    mode = 3;
    const int abortsBeforeSingle = aborts.load();
    assert(Begin(root.string(), "{\"stream\":false}", (root / "events.jsonl").string())); WaitDone();
    assert(aborts == abortsBeforeSingle); // the one stream:false callback is terminal
    mode = 4;
    const int abortsBeforeDeadline = aborts.load();
    assert(Begin(root.string(), "{}", (root / "events.jsonl").string(), 1)); WaitDone();
    assert(aborts == abortsBeforeDeadline + 1); // requester deadline shortens the wait
    mode = 0;
    probeWaitSeconds = 1;
    mode = 4;
    const int createsBefore = creates.load();
    const int submitsBefore = submits.load();
    const int abortsBefore = aborts.load();
    const int destroysBefore = destroys.load();
    assert(start()); WaitDone();
    assert(creates == createsBefore + 1 && submits == submitsBefore + 1);
    assert(aborts == abortsBefore + 1 && destroys == destroysBefore + 1);
    {
        std::lock_guard<std::mutex> lock(State().mutex);
        State().log.close();
    }
    std::filesystem::remove_all(root);
    std::cout << "PASS repeated requests, concurrent jobs, pre-submit cancellation, synchronous callbacks, failures, late callbacks, retry, single-shot completion, requester deadline\n";
}
