#include "timeline_buffer.hpp"
#include "keyword_service.hpp"
#include "health_monitor.hpp"
#include "routing_graph.hpp"
#include "meter_window.hpp"
#include "../capture/capture_adapter.hpp"
#include "../dsp/stream_resampler.hpp"
#include "../transport/pcm_transport.hpp"
#include "../../native/router_core.hpp"
#import <Foundation/Foundation.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread/qos.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <charconv>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace {
namespace cap = audio_router::macos;
namespace tx = audio_router::transport;
using audio_router::host::kFrames;
using audio_router::host::kBlockNs;
constexpr std::uint64_t kControllerLeaseNs = 1000000000;
volatile std::sig_atomic_t interrupted = 0;
void interrupt(int) { interrupted = 1; }

std::uint64_t host_ns(std::uint64_t ticks = mach_absolute_time()) noexcept {
    static const mach_timebase_info_data_t scale = [] { mach_timebase_info_data_t value{}; mach_timebase_info(&value); return value; }();
    return ticks / scale.denom * scale.numer + (ticks % scale.denom) * scale.numer / scale.denom;
}

// Scope the public latency hint and scheduler QoS to an explicitly running
// engine. This does not prevent system/display sleep or promise a hard deadline.
class SchedulerActivity {
public:
    SchedulerActivity() {
        token_ = [NSProcessInfo.processInfo beginActivityWithOptions:
            NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical
            reason:@"Continuous user-selected audio routing"];
        restore_ = pthread_get_qos_class_np(pthread_self(), &previous_, &relative_) == 0 && previous_ != QOS_CLASS_UNSPECIFIED;
        qos_error_ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
    ~SchedulerActivity() {
        if (qos_error_ == 0 && restore_) pthread_set_qos_class_self_np(previous_, relative_);
        if (token_) [NSProcessInfo.processInfo endActivity:token_];
    }
    bool active() const { return token_ != nil; }
    int qos_error() const { return qos_error_; }
private:
    id<NSObject> token_;
    qos_class_t previous_ = QOS_CLASS_UNSPECIFIED;
    int relative_ = 0, qos_error_ = 0;
    bool restore_ = false;
};

void usage() {
    std::cout << "Audio Router native host. Default: help only, no capture.\n"
      "  --synthetic --runtime-dir PRIVATE_PATH [--transport-path FILE] [--duration 1..60]\n"
      "  --live --allow-capture --runtime-dir PRIVATE_PATH --mic-uid EXACT_UID\n"
      "    --discord-pid PID [repeat] --dot-pid PID [repeat]\n"
      "Graph mode: --graph-json RESOLVED_JSON replaces --discord-pid; up to 8 exact apps.\n"
      "Optional --jitter-ms 10..100 (default25). Float inputs8..192k are converted to48k.\n"
      "Optional paired --keyword-worker EXECUTABLE --model-dir DIRECTORY enables local phrases.\n"
      "Synthetic only: --fixture-f32 FILE supplies bounded48k mono float PCM; no playback.\n"
      "One user-only UNIX socket: PRIVATE_PATH/control.sock. No TCP listener.\n";
}

bool number(const std::string& text, int& output) {
    const auto value = std::from_chars(text.data(), text.data() + text.size(), output);
    return value.ec == std::errc{} && value.ptr == text.data() + text.size();
}

struct Options {
    bool synthetic = false, live = false, allow = false;
    std::string runtime, transport, mic_uid, keyword_worker, model_dir, fixture;
    std::vector<pid_t> discord, dot;
    audio_router::host::RoutingGraph graph;
    int duration = 0, jitter_ms = 25;
};

bool options(int argc, char** argv, Options& out) {
    for (int i = 1; i < argc; ++i) {
        const std::string key = argv[i];
        if (key == "--synthetic" && !out.synthetic) { out.synthetic = true; continue; }
        if (key == "--live" && !out.live) { out.live = true; continue; }
        if (key == "--allow-capture" && !out.allow) { out.allow = true; continue; }
        if (i + 1 >= argc) return false;
        const std::string value = argv[++i];
        if (key == "--runtime-dir" && out.runtime.empty()) out.runtime = value;
        else if (key == "--transport-path" && out.transport.empty()) out.transport = value;
        else if (key == "--mic-uid" && out.mic_uid.empty() && value.size() <= 1024) out.mic_uid = value;
        else if (key == "--keyword-worker" && out.keyword_worker.empty()) out.keyword_worker = value;
        else if (key == "--model-dir" && out.model_dir.empty()) out.model_dir = value;
        else if (key == "--fixture-f32" && out.fixture.empty()) out.fixture = value;
        else if (key == "--graph-json" && !out.graph.enabled && audio_router::host::parse_graph(value, out.graph)) {}
        else if (key == "--duration" && number(value, out.duration) && out.duration >= 1 && out.duration <= 60) {}
        else if (key == "--jitter-ms" && number(value, out.jitter_ms) && out.jitter_ms >= 10 && out.jitter_ms <= 100) {}
        else if (key == "--discord-pid" || key == "--dot-pid") {
            int pid = 0;
            auto& list = key == "--discord-pid" ? out.discord : out.dot;
            if (!number(value, pid) || pid <= 0 || list.size() >= cap::kMaxProcesses ||
                std::find(list.begin(), list.end(), pid) != list.end()) return false;
            list.push_back(static_cast<pid_t>(pid));
        } else return false;
    }
    if (out.synthetic == out.live || out.runtime.empty() || out.runtime[0] != '/') return false;
    if (out.keyword_worker.empty() != out.model_dir.empty()) return false;
    if (!out.keyword_worker.empty() && (out.keyword_worker[0] != '/' || out.model_dir[0] != '/')) return false;
    if (!out.fixture.empty() && (!out.synthetic || out.fixture[0] != '/')) return false;
    if (out.synthetic && (out.allow || !out.mic_uid.empty() || !out.discord.empty() || !out.dot.empty())) return false;
    if (out.live && (!out.allow || out.mic_uid.empty() || (!out.graph.enabled && out.discord.empty()) || out.dot.empty() || out.duration)) return false;
    if (out.graph.enabled && !out.discord.empty()) return false;
    for (const auto& app : out.graph.apps) for (const auto pid : app.pids)
        if (std::find(out.dot.begin(), out.dot.end(), pid) != out.dot.end()) return false;
    for (const auto pid : out.discord) if (std::find(out.dot.begin(), out.dot.end(), pid) != out.dot.end()) return false;
    if (out.transport.empty()) out.transport = out.synthetic ? out.runtime + "/transport/pcm-v1.bin" : tx::default_path(getuid());
    return true;
}

std::string json_text(NSDictionary* value) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nullptr];
    if (!data) return "{\"ok\":false,\"error\":{\"code\":\"serialization\",\"message\":\"Status unavailable\"}}\n";
    return std::string(static_cast<const char*>(data.bytes), data.length) + "\n";
}

NSDictionary* error_json(NSString* code, NSString* message) {
    return @{ @"ok": @NO, @"error": @{ @"code": code, @"message": message } };
}

NSString* text(const std::string& value) { return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding]; }

// Nonblocking one-request-per-connection server. Slow clients cannot block PCM.
class Control {
public:
    ~Control() { if (client_ >= 0) close(client_); if (fd_ >= 0) close(fd_); if (owns_socket_) unlink(path_.c_str()); if (lock_ >= 0) close(lock_); }
    bool open_private(const std::string& directory) {
        struct stat info{};
        if (lstat(directory.c_str(), &info) != 0) {
            if (errno != ENOENT || mkdir(directory.c_str(), 0700) != 0 || lstat(directory.c_str(), &info) != 0) return false;
        }
        if (!S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 0077) != 0) return false;
        const auto lock_path = directory + "/host.lock";
        lock_ = ::open(lock_path.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (lock_ < 0 || fstat(lock_, &info) != 0 || info.st_uid != getuid() ||
            !S_ISREG(info.st_mode) || (info.st_mode & 0077) || flock(lock_, LOCK_EX | LOCK_NB) != 0) return false;
        path_ = directory + "/control.sock";
        sockaddr_un address{};
        if (path_.size() >= sizeof(address.sun_path)) return false;
        if (lstat(path_.c_str(), &info) == 0) {
            if (!S_ISSOCK(info.st_mode) || info.st_uid != getuid() || unlink(path_.c_str()) != 0) return false;
        } else if (errno != ENOENT) return false;
        fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd_ < 0 || fcntl(fd_, F_SETFL, O_NONBLOCK) != 0 || fcntl(fd_, F_SETFD, FD_CLOEXEC) != 0) return false;
        address.sun_family = AF_UNIX;
        std::memcpy(address.sun_path, path_.c_str(), path_.size() + 1);
        if (bind(fd_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) return false;
        owns_socket_ = true;
        if (chmod(path_.c_str(), 0600) != 0 || listen(fd_, 4) != 0) return false;
        return true;
    }
    NSDictionary* receive(std::uint64_t now) {
        flush();
        if (client_ < 0) {
            client_ = accept(fd_, nullptr, nullptr);
            if (client_ < 0) return nil;
            uid_t uid = 0; gid_t gid = 0;
            if (getpeereid(client_, &uid, &gid) != 0 || uid != getuid() || fcntl(client_, F_SETFL, O_NONBLOCK) != 0 || fcntl(client_, F_SETFD, FD_CLOEXEC) != 0) { reset(); return nil; }
            accepted_ns_ = now;
        }
        if (now - accepted_ns_ > 500000000) { reset(); return nil; }
        if (!outgoing_.empty() || waiting_) return nil;
        std::array<char, 4096> bytes{};
        for (unsigned turn = 0; turn < 2; ++turn) {
            const auto count = recv(client_, bytes.data(), bytes.size(), 0);
            if (count == 0) { reset(); return nil; }
            if (count < 0) { if (errno != EAGAIN && errno != EWOULDBLOCK) reset(); break; }
            incoming_.append(bytes.data(), static_cast<std::size_t>(count));
            if (incoming_.size() > 8192) { respond(error_json(@"request_size", @"Request exceeds 8 KiB.")); return nil; }
            const auto newline = incoming_.find('\n');
            if (newline == std::string::npos) continue;
            if (newline + 1 != incoming_.size()) { respond(error_json(@"framing", @"Send one JSON line per connection.")); return nil; }
            NSData* data = [NSData dataWithBytes:incoming_.data() length:newline];
            id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
            if (![value isKindOfClass:[NSDictionary class]]) { respond(error_json(@"json", @"Supply a JSON object.")); return nil; }
            waiting_ = true;
            return value;
        }
        return nil;
    }
    void respond(NSDictionary* value) { outgoing_ = json_text(value); sent_ = 0; waiting_ = false; flush(); }
    void flush() {
        if (client_ < 0 || outgoing_.empty()) return;
        const auto count = send(client_, outgoing_.data() + sent_, outgoing_.size() - sent_, 0);
        if (count > 0) { sent_ += static_cast<std::size_t>(count); if (sent_ == outgoing_.size()) reset(); }
        else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) reset();
    }
private:
    void reset() { if (client_ >= 0) close(client_); client_ = -1; incoming_.clear(); outgoing_.clear(); sent_ = 0; waiting_ = false; }
    int fd_ = -1, lock_ = -1, client_ = -1;
    bool owns_socket_ = false, waiting_ = false;
    std::string path_, incoming_, outgoing_;
    std::size_t sent_ = 0;
    std::uint64_t accepted_ns_ = 0;
};

AudioObjectID exact_uid(const std::string& uid) {
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &bytes) != noErr ||
        bytes % sizeof(AudioObjectID) || bytes > 1024 * sizeof(AudioObjectID)) return kAudioObjectUnknown;
    std::vector<AudioObjectID> devices(bytes / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &bytes, devices.data()) != noErr ||
        bytes > devices.size() * sizeof(AudioObjectID)) return kAudioObjectUnknown;
    AudioObjectID selected = kAudioObjectUnknown;
    unsigned matches = 0;
    for (std::size_t i = 0; i < bytes / sizeof(AudioObjectID); ++i) {
        AudioObjectPropertyAddress prop{kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFStringRef value = nullptr; UInt32 size = sizeof(value);
        if (AudioObjectGetPropertyData(devices[i], &prop, 0, nullptr, &size, &value) != noErr || !value) continue;
        const bool match = [(__bridge NSString*)value isEqualToString:text(uid)];
        CFRelease(value);
        if (match) { selected = devices[i]; ++matches; }
    }
    return matches == 1 ? selected : kAudioObjectUnknown;
}

struct Source {
    std::array<cap::CaptureBlock, 8> slots{};
    cap::BoundedSink sink{slots.data(), static_cast<std::uint32_t>(slots.size())};
    cap::CaptureEngine engine;
    audio_router::dsp::StreamingResampler converter;
    audio_router::dsp::ConvertedBlock converted;
    audio_router::host::TimelineBuffer timeline;
    std::array<float, kFrames> input{};
    bool failed = false, suppressed = false, healthy = false, active = true;
    std::uint64_t missing = 0;
    cap::Result error{};
    audio_router::host::MeterWindow meter;
};

double rms(const std::array<float, kFrames>& samples) {
    double energy = 0;
    for (const float value : samples) energy += value * value;
    return std::sqrt(energy / samples.size());
}

bool strings(NSDictionary* values, NSString* first, NSString* second, unsigned limit,
             std::string& out_first, std::string& out_second) {
    if (![values isKindOfClass:[NSDictionary class]] || values.count != 2 || !values[first] || !values[second]) return false;
    std::array<NSString*, 2> normalized{};
    unsigned index = 0;
    for (NSString* key in @[first, second]) {
        id value = values[key];
        if (![value isKindOfClass:[NSString class]] || [value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return false;
        NSMutableArray<NSString*>* words = [NSMutableArray array];
        for (NSString* word in [value componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) if (word.length) [words addObject:word];
        NSString* clean = [words componentsJoinedByString:@" "];
        NSData* unicode = [clean dataUsingEncoding:NSUTF32LittleEndianStringEncoding allowLossyConversion:NO];
        if (!unicode || unicode.length == 0 || unicode.length / 4 > limit) return false;
        normalized[index++] = clean;
    }
    if ([normalized[0] caseInsensitiveCompare:normalized[1]] == NSOrderedSame) return false;
    out_first = normalized[0].UTF8String; out_second = normalized[1].UTF8String;
    return true;
}

class Host {
    using EventKind = audio_router::host::EventKind;
    using EventReason = audio_router::host::EventReason;
    using HostEvent = audio_router::host::HostEvent;
public:
    explicit Host(Options configuration) : options_(std::move(configuration)) {
        source_count_ = options_.graph.enabled ? std::max<std::size_t>(3, options_.graph.apps.size() + 2) : 3;
    }
    ~Host() { health_monitor_.stop(); }
    bool start() {
        if (!options_.fixture.empty()) {
            std::ifstream input(options_.fixture, std::ios::binary | std::ios::ate);
            const auto bytes = input.tellg();
            if (!input || bytes <= 0 || bytes > 60 * 48000 * 4 || bytes % 4) { std::cerr << "Fixture must contain 1..60 seconds of bounded raw48k float PCM.\n"; return false; }
            fixture_.resize(static_cast<std::size_t>(bytes) / sizeof(float));
            input.seekg(0); input.read(reinterpret_cast<char*>(fixture_.data()), bytes);
            if (!input || std::any_of(fixture_.begin(), fixture_.end(), [](float value) { return !std::isfinite(value) || std::abs(value) > 1; })) { std::cerr << "Invalid fixture PCM.\n"; return false; }
        }
        if (!control_.open_private(options_.runtime)) { std::cerr << "Private runtime/socket unavailable or another host is running.\n"; return false; }
        journal_.start(options_.runtime, host_ns());
        record(EventKind::session_started, EventReason::startup, host_ns());
        const auto opened = writer_.open(options_.transport, getuid());
        if (!opened.ok()) { std::cerr << "Transport unavailable: " << static_cast<int>(opened.code) << ", errno " << opened.sys_errno << '\n'; return false; }
        if (options_.live) {
            const auto device = exact_uid(options_.mic_uid);
            if (device == kAudioObjectUnknown) { std::cerr << "Exact microphone UID unavailable.\n"; return false; }
            // HAL setup may take longer than the eight-slot callback queue.
            // Keep all callbacks in explicit startup priming until the one
            // consumer is ready; never discard buffers after arming.
            auto result = sources_[0].engine.start_physical(device, options_.mic_uid.c_str(), sources_[0].sink, true);
            if (options_.graph.enabled) {
                for (std::size_t app = 0; result.ok() && app < options_.graph.apps.size(); ++app) {
                    const auto index = app_index(app);
                    const auto& pids = options_.graph.apps[app].pids;
                    result = sources_[index].engine.start_processes(pids.data(), pids.size(), sources_[index].sink, true);
                }
            } else if (result.ok()) result = sources_[1].engine.start_processes(options_.discord.data(), options_.discord.size(), sources_[1].sink, true);
            if (result.ok()) result = sources_[2].engine.start_processes(options_.dot.data(), options_.dot.size(), sources_[2].sink, true);
            if (!result.ok()) { std::cerr << "Capture start failed: " << static_cast<int>(result.code) << ", OSStatus " << result.os_status << ", stage " << cap::error_stage_name(result.stage) << '\n'; return false; }
        }
        started_ns_ = next_ns_ = host_ns();
        if (detector_enabled()) restart_keyword(started_ns_, wake_phrase_, standby_phrase_, EventReason::startup);
        if (options_.live) health_monitor_.start([] { return host_ns(); }, [this](std::size_t index) {
            // poll_health reports faults to the engine's atomic pending slot;
            // the scheduler still consumes callback/poll errors immediately.
            if (source_enabled(index)) sources_[index].engine.poll_health();
        }, source_count_);
        return true;
    }
    int run() {
        SchedulerActivity activity;
        latency_activity_ = activity.active(); scheduler_qos_error_ = activity.qos_error();
        if (options_.live) for (std::size_t i = 0; i < source_count_; ++i) {
            if (!source_enabled(i)) continue;
            const auto result = sources_[i].engine.arm();
            if (!result.ok()) { std::cerr << "Capture arm failed: " << static_cast<int>(result.code) << ", OSStatus " << result.os_status << '\n'; return 1; }
        }
        started_ns_ = next_ns_ = host_ns();
        if (options_.live) health_monitor_.arm(started_ns_);
        while (!interrupted && !shutdown_) {
            @autoreleasepool {
                const auto now = host_ns();
                if (last_loop_ns_) loop_gap_max_ns_ = std::max(loop_gap_max_ns_, now - last_loop_ns_);
                last_loop_ns_ = now;
                control_.flush();
                if (now >= next_ns_) {
                    const auto lateness = now - next_ns_;
                    scheduler_lateness_max_ns_ = std::max(scheduler_lateness_max_ns_, lateness);
                    ++scheduler_ticks_; late_ticks_10ms_ += lateness > 10000000; late_ticks_50ms_ += lateness > 50000000;
                    auto stage = host_ns(); observe_gate(stage, EventReason::lease_expired); poll_keyword(stage); measure(keyword_poll_max_ns_, stage);
                    stage = host_ns();
                    NSDictionary* request = control_.receive(stage);
                    NSDictionary* error = request ? command(request, host_ns()) : nil;
                    measure(control_max_ns_, stage);
                    stage = host_ns(); render(stage); measure(render_max_ns_, stage);
                    stage = host_ns();
                    if (request) control_.respond(error ? error : status(host_ns()));
                    measure(response_max_ns_, stage);
                    next_ns_ = core_.next_time_ns();
                    if (next_ns_ <= now) next_ns_ = now + kBlockNs;
                }
                if (options_.duration && now - started_ns_ >= static_cast<std::uint64_t>(options_.duration) * 1000000000) break;
            }
            const auto sleep_start = host_ns();
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            const auto sleep_ns = host_ns() - sleep_start;
            if (sleep_ns > 1000000) sleep_overshoot_max_ns_ = std::max(sleep_overshoot_max_ns_, sleep_ns - 1000000);
        }
        writer_.close_gate(host_ns());
        observe_gate(host_ns(), EventReason::shutdown);
        record(EventKind::session_stopped, EventReason::shutdown, host_ns());
        keyword_.stop();
        health_monitor_.stop();
        int result = 0;
        if (options_.live) for (std::size_t i = 0; i < source_count_; ++i) if (source_enabled(i) && !sources_[i].engine.stop().ok()) result = 1;
        writer_.close();
        journal_.stop();
        return result;
    }
private:
    static void measure(std::uint64_t& maximum, std::uint64_t start) { maximum = std::max(maximum, host_ns() - start); }
    void source_fault(std::size_t index, cap::Result error) {
        auto& source = sources_[index];
        if (source.failed) return;
        source.failed = true; source.error = error;
        auto event = context(EventKind::source_fault, EventReason::capture_unhealthy, host_ns());
        event.source = static_cast<std::int32_t>(index); event.code = static_cast<std::int32_t>(error.code); event.os_status = error.os_status; event.source_stage = static_cast<std::int32_t>(error.stage);
        journal_.append(event);
        const auto capture = source.engine.snapshot();
        std::cerr << "Capture source " << index << " fault: " << static_cast<unsigned>(error.code)
                  << ", OSStatus " << error.os_status << ", blocks " << capture.blocks
                  << ", frames " << capture.frames << ", priming callbacks " << capture.priming_callbacks
                  << ", stage " << cap::error_stage_name(error.stage)
                  << ", elapsed_ms " << (host_ns() - started_ns_) / 1000000.0 << '\n';
        // The first fault in each source preserves enough context to distinguish
        // a dead HAL object from scheduler starvation; no audio or identities.
        std::cerr << "Fault timing maxima ms: source " << index
                  << ", health_poll " << health_monitor_.max_ns(index) / 1000000.0
                  << ", loop_gap " << loop_gap_max_ns_ / 1000000.0
                  << ", scheduler_lateness " << scheduler_lateness_max_ns_ / 1000000.0
                  << ", sleep_overshoot " << sleep_overshoot_max_ns_ / 1000000.0
                  << ", keyword_restart " << keyword_restart_max_ns_ / 1000000.0
                  << ", keyword_poll " << keyword_poll_max_ns_ / 1000000.0
                  << ", control " << control_max_ns_ / 1000000.0
                  << ", response " << response_max_ns_ / 1000000.0 << '\n';
    }
    NSDictionary* capture_status(std::size_t index) const {
        const auto capture = sources_[index].engine.snapshot();
        const auto checked = health_monitor_.completed(index), now = host_ns();
        return @{ @"phase": @(static_cast<unsigned>(capture.phase)), @"accepting": @(capture.accepting),
            @"blocks": @(capture.blocks), @"frames": @(capture.frames), @"priming_callbacks": @(capture.priming_callbacks),
            @"health_check_fresh": @(!options_.live || health_monitor_.fresh(index, now)),
            @"health_check_age_ms": @(checked && now >= checked ? (now - checked) / 1000000.0 : 0),
            @"health_poll_max_ms": @(health_monitor_.max_ns(index) / 1000000.0), @"health_poll_calls": @(health_monitor_.calls(index)) };
    }
    bool controller_fresh(std::uint64_t now) const { return controller_ns_ && now >= controller_ns_ && now - controller_ns_ < kControllerLeaseNs; }
    static std::size_t app_index(std::size_t app) { return app == 0 ? 1 : app + 2; }
    bool source_enabled(std::size_t index) const { return !(options_.graph.enabled && options_.graph.apps.empty() && index == 1); }
    bool apps_healthy() const {
        if (!options_.graph.enabled) return sources_[1].healthy;
        for (std::size_t i = 0; i < options_.graph.apps.size(); ++i) if (!sources_[app_index(i)].healthy) return false;
        return true;
    }
    std::uint64_t app_missing() const {
        if (!options_.graph.enabled) return sources_[1].missing;
        std::uint64_t sum = 0;
        for (std::size_t i = 0; i < options_.graph.apps.size(); ++i) sum += sources_[app_index(i)].missing;
        return sum;
    }
    cap::Result app_error() const {
        if (!options_.graph.enabled) return sources_[1].error;
        for (std::size_t i = 0; i < options_.graph.apps.size(); ++i) if (!sources_[app_index(i)].error.ok()) return sources_[app_index(i)].error;
        return {};
    }
    bool capture_ready() const { return sources_[0].healthy && apps_healthy() && sources_[2].healthy; }
    bool detector_enabled() const { return !options_.keyword_worker.empty(); }
    bool detector_healthy(std::uint64_t now) const { return !detector_enabled() || (!config_pending_ && keyword_.healthy(now)); }
    static std::int64_t age_ms(std::uint64_t stamp, std::uint64_t now) {
        return stamp && now >= stamp ? static_cast<std::int64_t>((now - stamp) / 1000000) : -1;
    }
    bool gate_open(std::uint64_t now) const { return core_.gate_open() && writer_.gate_deadline_ns() > now; }
    HostEvent context(EventKind kind, EventReason reason, std::uint64_t now) const {
        HostEvent event{}; event.kind = kind; event.reason = reason; event.monotonic_ns = host_ns();
        event.generation = detector_generation_; event.model_profile = keyword_.model_profile(); event.attempt = pending_attempt_;
        event.gate_open = gate_open(now); event.gate_epoch = writer_.gate_epoch();
        event.health = (sources_[0].healthy ? 1U : 0U) | (apps_healthy() ? 2U : 0U) | (sources_[2].healthy ? 4U : 0U) |
            (controller_fresh(now) ? 8U : 0U) | (detector_healthy(now) ? 16U : 0U);
        event.detector_events_dropped = keyword_.dropped_observations();
        event.progress_age_ms = age_ms(keyword_.progress_time_ns(), now); event.queued_frames = keyword_.queued_frames();
        return event;
    }
    void record(EventKind kind, EventReason reason, std::uint64_t now) { journal_.append(context(kind, reason, now)); }
    void observe_gate(std::uint64_t now, EventReason reason) {
        const bool open = gate_open(now);
        if (open != observed_gate_) record(open ? EventKind::gate_opened : EventKind::gate_closed, reason, now);
        observed_gate_ = open;
    }
    void cancel_attempt(EventReason reason, std::uint64_t now) {
        if (pending_attempt_) record(EventKind::wake_cancelled, reason, now);
        pending_attempt_ = 0;
    }
    void request_reset(EventReason reason) {
        if (!reset_detector_ || restart_reason_ == EventReason::none) restart_reason_ = close_reason_ = reason;
        reset_detector_ = true;
    }
    void observe_detector(std::uint64_t now) {
        const bool ready = keyword_.ready(), failed = keyword_.failed(), healthy = detector_healthy(now);
        if (ready && !observed_detector_ready_) record(EventKind::detector_ready, EventReason::none, now);
        if (failed && !observed_detector_failed_) record(EventKind::detector_failed, audio_router::host::detector_reason(keyword_.error_name()), now);
        if (healthy != observed_detector_healthy_) record(EventKind::detector_health, healthy ? EventReason::none : EventReason::detector_unhealthy, now);
        observed_detector_ready_ = ready; observed_detector_failed_ = failed; observed_detector_healthy_ = healthy;
    }
    void restart_keyword(std::uint64_t now, const std::string& wake, const std::string& standby, EventReason reason) {
        const auto start = host_ns();
        cancel_attempt(reason, now);
        close_reason_ = reason;
        ++detector_generation_;
        keyword_.start(options_.keyword_worker, options_.model_dir, wake, standby, now);
        record(EventKind::detector_restart, reason, now);
        observed_detector_ready_ = observed_detector_failed_ = observed_detector_healthy_ = false;
        measure(keyword_restart_max_ns_, start);
    }
    void poll_keyword(std::uint64_t now) {
        if (!detector_enabled()) return;
        const auto action = keyword_.poll(now);
        if (config_pending_ && keyword_.ready()) {
            discord_name_ = pending_discord_; alexa_name_ = pending_alexa_;
            wake_phrase_ = pending_wake_; standby_phrase_ = pending_standby_;
            config_pending_ = false; standby_ = true; wake_ = false;
        } else if (config_pending_ && keyword_.failed()) {
            config_pending_ = false; config_error_ = keyword_.error();
            restart_keyword(now, wake_phrase_, standby_phrase_, EventReason::configuration_rejected);
            standby_ = true; wake_ = false;
        }
        observe_detector(now);
        audio_router::host::KeywordService::Batch batch{};
        while (keyword_.take_batch(batch)) {
            auto event = context(EventKind::detector_batch, batch.reason, now);
            event.action_generation = batch.generation; event.action_sequence = batch.selected_sequence; event.last_action_sequence = batch.last_sequence;
            event.wake_count = batch.wakes; event.standby_count = batch.standbys;
            event.coalesced_count = batch.wakes + batch.standbys - (batch.selected_sequence ? 1U : 0U);
            journal_.append(event);
        }
        audio_router::host::KeywordService::Observation observation{};
        std::uint64_t acoustic_attempt = 0;
        while (keyword_.take_observation(observation)) {
            auto event = context(observation.action == audio_router::host::KeywordProcess::Action::wake ? EventKind::wake_detected : EventKind::standby_detected, EventReason::acoustic, now);
            event.attempt = observation.action == audio_router::host::KeywordProcess::Action::wake ? ++attempt_sequence_ : 0;
            event.action_generation = observation.generation; event.action_sequence = observation.sequence; event.action_frames = observation.frames;
            event.progress_age_ms = age_ms(observation.progress, now); event.audio_age_ms = age_ms(observation.audio, now);
            journal_.append(event);
            if (observation.action != audio_router::host::KeywordProcess::Action::wake) continue;
            auto rejection = observation.generation == detector_generation_ ? observation.reason : EventReason::stale_generation;
            if (rejection == EventReason::none && !detector_healthy(now)) rejection = EventReason::detector_unhealthy;
            if (rejection == EventReason::none && !capture_ready()) rejection = EventReason::capture_unhealthy;
            if (rejection == EventReason::none && !controller_fresh(now)) rejection = EventReason::controller_expired;
            if (rejection != EventReason::none) { event.kind = EventKind::wake_rejected; event.reason = rejection; journal_.append(event); }
            else acoustic_attempt = event.attempt;
        }
        if (!detector_healthy(now)) {
            if (close_reason_ == EventReason::none) close_reason_ = EventReason::detector_unhealthy;
            standby_ = true; wake_ = false; return;
        }
        if (action == audio_router::host::KeywordProcess::Action::standby) { ++standby_events_; cancel_attempt(EventReason::standby_priority, now); standby_ = true; wake_ = false; request_reset(EventReason::acoustic); record(EventKind::standby_requested, EventReason::acoustic, now); }
        else if (action == audio_router::host::KeywordProcess::Action::wake) { ++wake_events_; if (capture_ready() && controller_fresh(now)) { wake_ = true; pending_attempt_ = acoustic_attempt; record(EventKind::wake_admitted, EventReason::acoustic, now); } }
    }
    NSDictionary* command(NSDictionary* request, std::uint64_t now) {
        id op_value = request[@"op"];
        if (![op_value isKindOfClass:[NSString class]]) return error_json(@"op", @"Supply a supported operation.");
        NSString* op = op_value;
        if ([op isEqualToString:@"status"] && request.count == 1) return nil;
        if ([op isEqualToString:@"heartbeat"] && request.count == 1) { controller_ns_ = now; return nil; }
        if ([op isEqualToString:@"standby"] && request.count == 1) { controller_ns_ = now; cancel_attempt(EventReason::standby_priority, now); standby_ = true; wake_ = false; request_reset(EventReason::manual); record(EventKind::standby_requested, EventReason::manual, now); return nil; }
        if ([op isEqualToString:@"wake"] && request.count == 1) {
            controller_ns_ = now;
            cancel_attempt(EventReason::coalesced, now); pending_attempt_ = ++attempt_sequence_;
            if (!capture_ready() || !detector_healthy(now)) {
                record(EventKind::wake_rejected, !capture_ready() ? EventReason::capture_unhealthy : EventReason::detector_unhealthy, now);
                pending_attempt_ = 0;
                return error_json(@"not_ready", @"Selected sources and the enabled phrase detector must be healthy before wake.");
            }
            record(EventKind::wake_admitted, EventReason::manual, now);
            wake_ = true; return nil;
        }
        if ([op isEqualToString:@"shutdown"] && request.count == 1) { cancel_attempt(EventReason::shutdown, now); shutdown_ = true; standby_ = true; wake_ = false; close_reason_ = EventReason::shutdown; return nil; }
        if ([op isEqualToString:@"config"] && request.count == 3) {
            if (config_pending_) return error_json(@"config_pending", @"A phrase configuration is already being validated.");
            std::string discord, alexa, wake, standby;
            if (!strings(request[@"names"], @"discord", @"alexa", 48, discord, alexa) ||
                !strings(request[@"phrases"], @"wake", @"standby", 64, wake, standby)) return error_json(@"config", @"Names and phrases must be distinct nonempty bounded text.");
            config_error_.clear();
            if (detector_enabled() && (wake != wake_phrase_ || standby != standby_phrase_ || keyword_.failed())) {
                pending_discord_ = discord; pending_alexa_ = alexa; pending_wake_ = wake; pending_standby_ = standby;
                config_pending_ = true; standby_ = true; wake_ = false;
                restart_keyword(now, wake, standby, EventReason::configuration);
                return nil;
            }
            if (wake != wake_phrase_ || standby != standby_phrase_) { cancel_attempt(EventReason::configuration, now); close_reason_ = EventReason::configuration; standby_ = true; wake_ = false; }
            discord_name_ = discord; alexa_name_ = alexa; wake_phrase_ = wake; standby_phrase_ = standby;
            return nil;
        }
        if ([op isEqualToString:@"fault"] && options_.synthetic && request.count == 3) {
            NSString* source = request[@"source"];
            id active = request[@"active"];
            if (![source isKindOfClass:[NSString class]] || !active || CFGetTypeID((__bridge CFTypeRef)active) != CFBooleanGetTypeID()) return error_json(@"fault", @"Supply a source and boolean active.");
            int index = [source isEqualToString:@"mic"] ? 0 : [source isEqualToString:@"discord"] ? 1 : [source isEqualToString:@"dot"] ? 2 : -1;
            if (index < 0 && options_.graph.enabled) for (std::size_t i = 0; i < options_.graph.apps.size(); ++i)
                if ([source isEqualToString:text(options_.graph.apps[i].bundle_id)]) index = static_cast<int>(app_index(i));
            if (index < 0) return error_json(@"fault", @"Unknown synthetic source.");
            sources_[index].suppressed = [active boolValue];
            auto event = context(EventKind::source_fault, EventReason::capture_changed, now);
            event.source = index; event.code = [active boolValue] ? 1 : 0; journal_.append(event);
            if ([active boolValue]) { sources_[index].timeline.clear(); sources_[index].healthy = false; }
            return nil;
        }
        return error_json(@"op", @"Unsupported operation or fields.");
    }
    void render(std::uint64_t now) {
        const bool previously_open = gate_open(now);
        // Keep output packets contiguous despite ordinary scheduler jitter.
        // Only a substantial missed deadline establishes a new timeline.
        const auto lateness = now > next_ns_ ? now - next_ns_ : 0;
        render_lateness_max_ns_ = std::max(render_lateness_max_ns_, lateness);
        const bool slipped = lateness > 50000000;
        const auto start = slipped ? now : std::max(next_ns_, core_.next_time_ns());
        const auto delay = static_cast<std::uint64_t>(options_.jitter_ms) * 1000000;
        const auto input_start = start > delay ? start - delay : 0;
        if (slipped) { ++discontinuities_; cancel_attempt(EventReason::render_slip, now); standby_ = true; wake_ = false; request_reset(EventReason::render_slip); record(EventKind::scheduler_discontinuity, EventReason::render_slip, now); }
        cap::CaptureBlock block{};
        const bool fixture_running = !fixture_.empty() && detector_healthy(now) && controller_fresh(now);
        for (std::size_t index = 0; index < source_count_; ++index) {
            auto& source = sources_[index];
            if (!source_enabled(index)) { source.input.fill(0); source.healthy = true; source.active = false; continue; }
            if (options_.synthetic) {
                if (!source.suppressed) {
                    std::array<float, kFrames> samples{}; samples.fill(index == 0 ? .25F : index == 2 ? .75F : index == 1 ? .5F : .5F / static_cast<float>(index - 1));
                    if (!fixture_.empty() && index < 2) {
                        samples.fill(0);
                        if (fixture_running) for (std::size_t i = 0; i < samples.size() && fixture_frame_ + i < fixture_.size(); ++i) samples[i] = fixture_[fixture_frame_ + i];
                    }
                    source.timeline.push(samples.data(), samples.size(), input_start, now);
                }
            } else {
                for (unsigned count = 0; count < 8 && source.sink.try_pop(block); ++count) {
                    const auto converted = source.converter.convert(block, host_ns(block.host_time), source.converted);
                    if (converted != audio_router::dsp::ConvertResult::ok) {
                        source_fault(index, {cap::Error::invalid_pcm, noErr});
                    } else {
                        if (source.converted.discontinuity) { source.timeline.clear(); cancel_attempt(EventReason::capture_discontinuity, now); standby_ = true; wake_ = false; request_reset(EventReason::capture_discontinuity); ++discontinuities_; record(EventKind::scheduler_discontinuity, EventReason::capture_discontinuity, now); }
                        if (source.converted.frames && !source.timeline.push(source.converted.samples, source.converted.frames, source.converted.first_sample_ns, now)) {
                            source_fault(index, {cap::Error::invalid_timestamp, noErr});
                        }
                    }
                }
                const auto callback = source.engine.take_error();
                if (!callback.ok()) source_fault(index, callback);
                source.active = source.engine.snapshot().source_active;
            }
            const auto missing = source.timeline.read(source.input.data(), kFrames, input_start);
            source.missing += missing;
            source.healthy = audio_router::host::source_healthy(index == 0, source.active, source.failed || source.suppressed, source.timeline.fresh(now), missing);
            if (options_.live && !health_monitor_.fresh(index, now)) source.healthy = false;
            if (source.failed || source.suppressed) { source.input.fill(0); source.healthy = false; }
            if (source.healthy != observed_sources_[index]) {
                auto event = context(EventKind::source_health, EventReason::capture_changed, now);
                event.source = static_cast<std::int32_t>(index); event.code = source.healthy ? 1 : 0; journal_.append(event);
                observed_sources_[index] = source.healthy;
            }
            source.meter.push(source.input.data(), source.input.size());
        }
        app_mix_.fill(0);
        if (!options_.graph.enabled) app_mix_ = sources_[1].input;
        else {
            std::size_t connected = 0;
            for (const auto& app : options_.graph.apps) connected += app.to_assistant;
            if (connected) for (std::size_t i = 0; i < options_.graph.apps.size(); ++i) if (options_.graph.apps[i].to_assistant)
                for (std::size_t frame = 0; frame < kFrames; ++frame)
                    app_mix_[frame] += sources_[app_index(i)].input[frame] / static_cast<float>(connected);
            // Averaging bounded sources cannot exceed full scale mathematically;
            // remove rounding overshoot before the core's strict PCM validator.
            for (auto& sample : app_mix_) sample = std::clamp(sample, -1.0F, 1.0F);
        }
        if (fixture_running) fixture_frame_ = std::min(fixture_frame_ + kFrames, fixture_.size());
        const bool capture_now = capture_ready(), controller_now = controller_fresh(now);
        // Fence both loss and recovery boundaries, even if Alexa was already
        // closed: an old queued wake must never cross into a recovered epoch.
        if (controller_now != controller_was_) record(EventKind::controller_health, controller_now ? EventReason::none : EventReason::controller_expired, now);
        if (capture_now != capture_was_ || controller_now != controller_was_) {
            const auto reason = capture_now != capture_was_ && controller_now != controller_was_ ? EventReason::capture_and_controller_changed : capture_now != capture_was_ ? EventReason::capture_changed : EventReason::controller_changed;
            request_reset(reason);
        }
        capture_was_ = capture_now; controller_was_ = controller_now;
        if (reset_detector_ && detector_enabled()) {
            restart_keyword(now, config_pending_ ? pending_wake_ : wake_phrase_, config_pending_ ? pending_standby_ : standby_phrase_, restart_reason_);
            standby_ = true; wake_ = false;
        }
        reset_detector_ = false;
        const bool healthy = capture_ready() && detector_healthy(now) && controller_fresh(now) && !slipped;
        ++sequence_; ++progress_;
        const audio_router::Command control{core_.epoch(), sequence_, progress_, start, healthy, wake_, standby_};
        const bool fresh_wake = wake_ && healthy && !standby_;
        const auto controlled = core_.control(control, start);
        const audio_router::Inputs inputs{{sources_[0].input.data(), kFrames}, {app_mix_.data(), kFrames}, {sources_[2].input.data(), kFrames}};
        const audio_router::Outputs outputs{{discord_.data(), kFrames}, {listener_.data(), kFrames}, {alexa_.data(), kFrames}};
        const auto rendered = core_.render(inputs, outputs, kFrames, start, options_.graph.routes);
        for (std::size_t frame = 0; frame < kFrames; ++frame)
            assistant_feed_[frame] = (options_.graph.routes.mic_to_assistant ? .5F * sources_[0].input[frame] : 0.0F) + .5F * app_mix_[frame];
        if (fresh_wake && controlled == audio_router::Status::ok) writer_.open_gate(now);
        else if (core_.gate_open() && healthy) writer_.renew_gate(now);
        else writer_.close_gate(now);
        bool output_fault = rendered != audio_router::Status::ok;
        if (output_fault) { writer_.close_gate(now); ++render_errors_; }
        if (!writer_.publish(discord_.data(), assistant_feed_.data(), kFrames, start, now)) { writer_.close_gate(now); ++publish_errors_; output_fault = true; }
        if (detector_enabled()) keyword_.feed(listener_.data(), listener_.size());
        if (detector_enabled() && keyword_.failed()) writer_.close_gate(now);
        const auto outcome_time = host_ns();
        const auto outcome_reason = close_reason_ != EventReason::none ? close_reason_ : output_fault ? EventReason::output_fault : !capture_ready() ? EventReason::capture_unhealthy : !controller_fresh(outcome_time) ? EventReason::controller_expired : !detector_healthy(outcome_time) ? EventReason::detector_unhealthy : close_reason_;
        observe_gate(outcome_time, gate_open(outcome_time) ? EventReason::none : outcome_reason);
        if (pending_attempt_) {
            if (gate_open(outcome_time)) record(EventKind::wake_completed, previously_open ? EventReason::gate_already_open : EventReason::none, outcome_time);
            else record(EventKind::wake_cancelled, outcome_reason == EventReason::none ? EventReason::gate_not_opened : outcome_reason, outcome_time);
            pending_attempt_ = 0;
        }
        apps_meter_.push(discord_.data(), kFrames);
        assistant_meter_.push(alexa_.data(), kFrames);
        listener_meter_.push(listener_.data(), kFrames);
        for (std::size_t i = 0; i < kFrames; ++i) {
            diagnostic_mic_peak_ = std::max(diagnostic_mic_peak_, std::abs(sources_[0].input[i]));
            diagnostic_listener_peak_ = std::max(diagnostic_listener_peak_, std::abs(listener_[i]));
        }
        if (now >= next_diagnostic_sample_) {
            auto event = context(EventKind::health_sample, EventReason::none, outcome_time);
            event.mic_peak_milli = static_cast<std::uint32_t>(std::clamp(diagnostic_mic_peak_, 0.0F, 1.0F) * 1000);
            event.listener_peak_milli = static_cast<std::uint32_t>(std::clamp(diagnostic_listener_peak_, 0.0F, 1.0F) * 1000);
            event.code = keyword_.ready() ? 1 : 0;
            journal_.append(event); diagnostic_mic_peak_ = diagnostic_listener_peak_ = 0;
            next_diagnostic_sample_ = now + 1000000000;
        }
        frames_ += kFrames; last_render_ns_ = now; wake_ = false; standby_ = output_fault; reset_detector_ = output_fault;
        restart_reason_ = output_fault ? EventReason::output_fault : EventReason::none; close_reason_ = restart_reason_;
    }
    static NSDictionary* meter_value(const audio_router::host::MeterWindow& meter) {
        return @{ @"rms": @(meter.rms), @"peak": @(meter.peak) };
    }
    NSDictionary* status(std::uint64_t now) const {
        const bool gate_open = core_.gate_open() && writer_.gate_deadline_ns() > now;
        const auto diagnostics = journal_.stats();
        NSMutableDictionary* app_meters = [NSMutableDictionary dictionary];
        NSMutableDictionary* app_states = [NSMutableDictionary dictionary];
        for (std::size_t i = 0; i < options_.graph.apps.size(); ++i) {
            const auto index = app_index(i);
            app_meters[text(options_.graph.apps[i].bundle_id)] = meter_value(sources_[index].meter);
            app_states[text(options_.graph.apps[i].bundle_id)] = @{ @"healthy": @(sources_[index].healthy),
                @"active": @(sources_[index].active), @"error": @(static_cast<unsigned>(sources_[index].error.code)),
                @"missing_frames": @(sources_[index].missing) };
        }
        return @{ @"ok": @YES, @"mode": options_.synthetic ? @"synthetic" : @"live",
          @"gate": gate_open ? @"open" : @"closed",
          @"diagnostics": @{ @"host": @{ @"active": @(diagnostics.active), @"queued": @(diagnostics.queued), @"written": @(diagnostics.written), @"dropped": @(diagnostics.dropped), @"errors": @(diagnostics.errors), @"last_errno": @(diagnostics.last_errno), @"detector_events_dropped": @(keyword_.dropped_observations()) } },
          @"frames": @(frames_), @"epoch": @(core_.epoch()), @"transport_epoch": @(writer_.session_epoch()),
          @"health": @{ @"mic": @(sources_[0].healthy), @"discord": @(apps_healthy()), @"dot": @(sources_[2].healthy), @"controller": @(controller_fresh(now)) },
          @"graph_revision": text(options_.graph.revision), @"app_sources": app_states,
          @"meter_levels": @{ @"mic": meter_value(sources_[0].meter), @"assistant": meter_value(sources_[2].meter),
              @"apps": app_meters, @"to_apps": meter_value(apps_meter_),
              @"to_assistant": gate_open ? meter_value(assistant_meter_) : @{ @"rms": @0, @"peak": @0 },
              @"listener": meter_value(listener_meter_) },
          @"meters": @{ @"discord": @(rms(discord_)), @"listener": @(rms(listener_)), @"alexa": @(rms(alexa_)) },
          @"names": @{ @"discord": text(discord_name_), @"alexa": text(alexa_name_) },
          @"phrases": @{ @"wake": text(wake_phrase_), @"standby": text(standby_phrase_) },
          @"detector": @{ @"enabled": @(detector_enabled()), @"healthy": @(detector_enabled() && keyword_.healthy(now)), @"ready": @(keyword_.ready()), @"frames": @(keyword_.frames()), @"sequence": @(keyword_.sequence()), @"generation": @(detector_generation_), @"model_profile": text(audio_router::host::profile_name(keyword_.model_profile())), @"error": text(keyword_.error()), @"wake_events": @(wake_events_), @"standby_events": @(standby_events_) },
          @"fixture": @{ @"frames": @(fixture_frame_), @"total_frames": @(fixture_.size()), @"done": @(!fixture_.empty() && fixture_frame_ == fixture_.size()) },
          @"config_pending": @(config_pending_), @"config_error": text(config_error_), @"device_names_applied": @NO,
          @"missing_frames": @{ @"mic": @(sources_[0].missing), @"discord": @(app_missing()), @"dot": @(sources_[2].missing) },
          @"errors": @{ @"render": @(render_errors_), @"publish": @(publish_errors_), @"discontinuities": @(discontinuities_) },
          @"source_errors": @{ @"mic": @(static_cast<unsigned>(sources_[0].error.code)), @"discord": @(static_cast<unsigned>(app_error().code)), @"dot": @(static_cast<unsigned>(sources_[2].error.code)) },
          @"source_os_status": @{ @"mic": @(sources_[0].error.os_status), @"discord": @(app_error().os_status), @"dot": @(sources_[2].error.os_status) },
          @"source_error_stage": @{ @"mic": @(cap::error_stage_name(sources_[0].error.stage)), @"discord": @(cap::error_stage_name(app_error().stage)), @"dot": @(cap::error_stage_name(sources_[2].error.stage)) },
          @"capture": @{ @"mic": capture_status(0), @"discord": capture_status(1), @"dot": capture_status(2) },
          @"timing_max_ms": @{ @"render": @(render_max_ns_ / 1000000.0), @"keyword_poll": @(keyword_poll_max_ns_ / 1000000.0), @"keyword_restart": @(keyword_restart_max_ns_ / 1000000.0), @"control": @(control_max_ns_ / 1000000.0), @"response": @(response_max_ns_ / 1000000.0) },
          @"scheduler": @{ @"latency_activity": @(latency_activity_), @"qos_applied": @(scheduler_qos_error_ == 0), @"qos_error": @(scheduler_qos_error_),
            @"ticks": @(scheduler_ticks_), @"late_ticks_over_10ms": @(late_ticks_10ms_), @"late_ticks_over_50ms": @(late_ticks_50ms_),
            @"lateness_max_ms": @(scheduler_lateness_max_ns_ / 1000000.0), @"render_lateness_max_ms": @(render_lateness_max_ns_ / 1000000.0),
            @"loop_gap_max_ms": @(loop_gap_max_ns_ / 1000000.0), @"sleep_overshoot_max_ms": @(sleep_overshoot_max_ns_ / 1000000.0) },
          @"source_active": @{ @"mic": @(sources_[0].active), @"discord": @(sources_[1].active), @"dot": @(sources_[2].active) },
          @"format": @"48000 Hz mono float32", @"jitter_ms": @(options_.jitter_ms) };
    }
    Options options_;
    Control control_;
    audio_router::host::KeywordService keyword_{[] { return host_ns(); }};
    audio_router::host::EventJournal journal_;
    tx::Writer writer_;
    audio_router::RouterCore core_;
    std::array<Source, audio_router::host::HealthMonitor::kMaximumSources> sources_{};
    std::size_t source_count_ = 3;
    audio_router::host::HealthMonitor health_monitor_;
    std::array<float, kFrames> discord_{}, listener_{}, alexa_{}, assistant_feed_{}, app_mix_{};
    audio_router::host::MeterWindow apps_meter_, assistant_meter_, listener_meter_;
    std::vector<float> fixture_;
    std::size_t fixture_frame_ = 0;
    std::string discord_name_ = "Router · Apps", alexa_name_ = "Router · Assistant", wake_phrase_ = "Hey Dot", standby_phrase_ = "Dot standby";
    std::string pending_discord_, pending_alexa_, pending_wake_, pending_standby_, config_error_;
    std::uint64_t started_ns_ = 0, next_ns_ = 0, controller_ns_ = 0, last_render_ns_ = 0;
    std::uint64_t render_max_ns_ = 0, keyword_poll_max_ns_ = 0, keyword_restart_max_ns_ = 0, control_max_ns_ = 0, response_max_ns_ = 0;
    std::uint64_t last_loop_ns_ = 0, loop_gap_max_ns_ = 0, sleep_overshoot_max_ns_ = 0, scheduler_lateness_max_ns_ = 0, render_lateness_max_ns_ = 0;
    std::uint64_t scheduler_ticks_ = 0, late_ticks_10ms_ = 0, late_ticks_50ms_ = 0;
    bool latency_activity_ = false;
    int scheduler_qos_error_ = 0;
    std::uint64_t frames_ = 0, sequence_ = 0, progress_ = 0, render_errors_ = 0, publish_errors_ = 0, discontinuities_ = 0;
    std::uint64_t wake_events_ = 0, standby_events_ = 0, detector_generation_ = 0;
    std::uint64_t attempt_sequence_ = 0, pending_attempt_ = 0;
    std::uint64_t next_diagnostic_sample_ = 0;
    float diagnostic_mic_peak_ = 0, diagnostic_listener_peak_ = 0;
    std::array<bool, audio_router::host::HealthMonitor::kMaximumSources> observed_sources_{};
    bool observed_gate_ = false, observed_detector_ready_ = false, observed_detector_failed_ = false, observed_detector_healthy_ = false;
    EventReason restart_reason_ = EventReason::none, close_reason_ = EventReason::none;
    bool wake_ = false, standby_ = false, shutdown_ = false, config_pending_ = false;
    bool reset_detector_ = false, capture_was_ = false, controller_was_ = false;
};
} // namespace

int main(int argc, char** argv) {
    if (argc == 1 || (argc == 2 && std::string(argv[1]) == "--help")) { usage(); return 0; }
    Options configuration;
    if (!options(argc, argv, configuration)) { std::cerr << "Invalid selection or mode. Use --help. No capture started.\n"; return 2; }
    std::signal(SIGINT, interrupt); std::signal(SIGTERM, interrupt); std::signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        try {
            Host host(std::move(configuration));
            if (!host.start()) return 1;
            return host.run();
        } catch (const std::exception& error) { std::cerr << "Native host failed: " << error.what() << '\n'; return 1; }
    }
}
