#include "capture_adapter.hpp"

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <array>
#include <cstring>
#include <thread>

#if !defined(__MAC_OS_X_VERSION_MAX_ALLOWED) || __MAC_OS_X_VERSION_MAX_ALLOWED < 140200
#error This capture adapter requires an SDK containing macOS 14.2 Core Audio process taps.
#endif

// Public macOS 26 setter, declared independently so SDK 14/15 builds can
// disable restoration when running on newer systems. Never call it unless
// both the OS availability and runtime selector checks succeed.
@protocol AudioRouterProcessRestoration
- (void)setProcessRestoreEnabled:(BOOL)enabled;
@end

namespace audio_router::macos {
namespace {

AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                   AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) noexcept {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

template<class T>
OSStatus read_property(AudioObjectID object, AudioObjectPropertyAddress property, T& value) noexcept {
    UInt32 size = sizeof(T);
    const auto status = AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, &value);
    return status == noErr && size != sizeof(T) ? kAudioHardwareBadPropertySizeError : status;
}

Result os_result(OSStatus status, ErrorStage stage = ErrorStage::none) noexcept {
    return status == noErr ? Result{} : Result{Error::core_audio_failure, status, stage};
}

Result resolve_process(pid_t pid, AudioObjectID& object) noexcept {
    auto property = address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    UInt32 size = sizeof(object);
    auto status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(pid), &pid, &size, &object);
    if (status != noErr) return os_result(status, ErrorStage::process_translate);
    if (size != sizeof(object) || object == kAudioObjectUnknown) return {Error::source_unavailable, noErr, ErrorStage::process_translate};
    pid_t actual = 0;
    status = read_property(object, address(kAudioProcessPropertyPID), actual);
    if (status != noErr) return os_result(status, ErrorStage::process_identity);
    return actual == pid ? Result{} : Result{Error::source_unavailable, noErr, ErrorStage::process_identity};
}

bool physical_transport(UInt32 type) noexcept {
    return type == kAudioDeviceTransportTypeBuiltIn || type == kAudioDeviceTransportTypeUSB ||
        type == kAudioDeviceTransportTypePCI || type == kAudioDeviceTransportTypeFireWire ||
        type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE ||
        type == kAudioDeviceTransportTypeThunderbolt;
}

std::uint64_t packed_error(Result result) noexcept {
    return (static_cast<std::uint64_t>(result.stage) << 48) |
        (static_cast<std::uint64_t>(result.code) << 32) | static_cast<std::uint32_t>(result.os_status);
}

Result unpack_error(std::uint64_t value) noexcept {
    return {static_cast<Error>((value >> 32) & 0xffff), static_cast<OSStatus>(static_cast<std::uint32_t>(value)),
            static_cast<ErrorStage>(value >> 48)};
}

} // namespace

const char* error_stage_name(ErrorStage stage) noexcept {
    switch (stage) {
    case ErrorStage::none: return "unspecified";
    case ErrorStage::device_alive: return "device_alive";
    case ErrorStage::device_streams: return "device_streams";
    case ErrorStage::stream_format: return "stream_format";
    case ErrorStage::device_rate: return "device_rate";
    case ErrorStage::device_buffer: return "device_buffer";
    case ErrorStage::process_translate: return "process_translate";
    case ErrorStage::process_identity: return "process_identity";
    case ErrorStage::process_output: return "process_output";
    case ErrorStage::callback_timestamp: return "callback_timestamp";
    case ErrorStage::callback_format: return "callback_format";
    case ErrorStage::callback_sink: return "callback_sink";
    }
    return "unknown";
}

struct CaptureEngine::State {
    struct Listener { AudioObjectID object = 0; AudioObjectPropertyAddress property{}; bool active = false; };
    std::array<Listener, 32> listeners{};
    std::size_t listener_count = 0;
    std::array<pid_t, kMaxProcesses> pids{};
    std::array<AudioObjectID, kMaxProcesses> processes{};
    std::size_t process_count = 0;
    AudioObjectID device = kAudioObjectUnknown, stream = kAudioObjectUnknown, tap = kAudioObjectUnknown;
    AudioDeviceIOProcID io = nullptr;
    bool owns_device = false, started = false;
    bool deferred = false;
    BoundedSink* sink = nullptr;
    Format format{};
    SourceKind source = SourceKind::none;
    std::atomic<bool> source_active{true};
    std::array<float, kMaxCaptureFrames> scratch{};
    std::uint64_t previous_host_time = 0;
    bool has_host_time = false;
    // 0 disabled/faulted, 1 accepting, 2 startup priming. Arm uses CAS so a
    // concurrent configuration fault can never be overwritten by startup.
    std::atomic<std::uint32_t> accepting{0}, active_callbacks{0};
    std::atomic<std::uint32_t> phase{static_cast<std::uint32_t>(Phase::stopped)};
    std::atomic<std::uint64_t> blocks{0}, frames{0}, pending{0}, priming_callbacks{0};

    bool resources() const noexcept {
        if (io != nullptr || owns_device || tap != kAudioObjectUnknown) return true;
        for (std::size_t i = 0; i < listener_count; ++i) if (listeners[i].active) return true;
        return false;
    }

    void report(Result error) noexcept {
        accepting.store(0, std::memory_order_release);
        std::uint64_t empty = 0;
        pending.compare_exchange_strong(empty, packed_error(error), std::memory_order_acq_rel);
        phase.store(static_cast<std::uint32_t>(Phase::faulted), std::memory_order_release);
    }

    Result prepare(SourceKind kind, BoundedSink& destination, bool defer_acceptance = false) noexcept {
        if (resources() || sink != nullptr) return {Error::already_started, noErr};
        if (!destination.claim()) return {Error::invalid_sink, noErr};
        sink = &destination;
        source = kind;
        deferred = defer_acceptance;
        source_active = kind != SourceKind::process_allowlist;
        process_count = listener_count = 0;
        device = stream = tap = kAudioObjectUnknown;
        owns_device = started = false;
        io = nullptr;
        previous_host_time = 0;
        has_host_time = false;
        accepting.store(0, std::memory_order_relaxed);
        pending.store(0, std::memory_order_relaxed);
        blocks.store(0, std::memory_order_relaxed);
        frames.store(0, std::memory_order_relaxed);
        priming_callbacks.store(0, std::memory_order_relaxed);
        phase.store(static_cast<std::uint32_t>(Phase::starting), std::memory_order_release);
        return {};
    }

    static OSStatus changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress[], void* context) noexcept {
        auto& self = *static_cast<State*>(context);
        self.active_callbacks.fetch_add(1, std::memory_order_acq_rel);
        const auto phase = static_cast<Phase>(self.phase.load(std::memory_order_acquire));
        if (phase == Phase::starting || phase == Phase::running)
            self.report({Error::configuration_changed, noErr});
        self.active_callbacks.fetch_sub(1, std::memory_order_release);
        return noErr;
    }

    static OSStatus capture(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
                            const AudioTimeStamp* input_time, AudioBufferList*,
                            const AudioTimeStamp*, void* context) noexcept {
        auto& self = *static_cast<State*>(context);
        self.active_callbacks.fetch_add(1, std::memory_order_acq_rel);
        const auto accepting = self.accepting.load(std::memory_order_acquire);
        if (accepting == 2) self.priming_callbacks.fetch_add(1, std::memory_order_relaxed);
        else if (accepting == 1) {
            Result result{};
            std::uint32_t count = 0;
            if (input_time == nullptr || (input_time->mFlags & kAudioTimeStampHostTimeValid) == 0 ||
                (self.has_host_time && input_time->mHostTime <= self.previous_host_time)) {
                result = {Error::invalid_timestamp, noErr, ErrorStage::callback_timestamp};
            } else {
                result = downmix(self.format, input, self.scratch.data(), self.scratch.size(), count);
                if (!result.ok()) result.stage = ErrorStage::callback_format;
                if (result.ok()) {
                    if (!self.sink->try_push(self.scratch.data(), count, input_time->mHostTime, self.format.sample_rate)) {
                        result = {Error::sink_full, noErr, ErrorStage::callback_sink};
                    } else {
                        self.previous_host_time = input_time->mHostTime;
                        self.has_host_time = true;
                        self.blocks.fetch_add(1, std::memory_order_relaxed);
                        self.frames.fetch_add(count, std::memory_order_relaxed);
                    }
                }
            }
            if (!result.ok()) self.report(result);
        }
        // Core Audio pre-zeros output buffers. Leave them untouched: this
        // adapter never monitors or adds another playback path.
        self.active_callbacks.fetch_sub(1, std::memory_order_release);
        return noErr;
    }

    Result listen(AudioObjectID object, AudioObjectPropertyAddress property) noexcept {
        if (listener_count >= listeners.size()) return {Error::invalid_selection, noErr};
        const auto status = AudioObjectAddPropertyListener(object, &property, changed, this);
        if (status != noErr) return os_result(status);
        listeners[listener_count++] = {object, property, true};
        return {};
    }

    Result inspect_device(bool initial) noexcept {
        UInt32 alive = 0;
        auto status = read_property(device, address(kAudioDevicePropertyDeviceIsAlive), alive);
        if (status != noErr) return os_result(status, ErrorStage::device_alive);
        if (alive == 0) return {Error::source_unavailable, noErr, ErrorStage::device_alive};
        auto property = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
        UInt32 size = 0;
        status = AudioObjectGetPropertyDataSize(device, &property, 0, nullptr, &size);
        if (status != noErr) return os_result(status, ErrorStage::device_streams);
        if (size != sizeof(AudioStreamID)) return {Error::unsupported_format, noErr, ErrorStage::device_streams};
        AudioStreamID actual_stream = 0;
        status = AudioObjectGetPropertyData(device, &property, 0, nullptr, &size, &actual_stream);
        if (status != noErr) return os_result(status, ErrorStage::device_streams);
        if (size != sizeof(actual_stream) || actual_stream == 0) return {Error::unsupported_format, noErr, ErrorStage::device_streams};
        if (!initial && actual_stream != stream) return {Error::configuration_changed, noErr, ErrorStage::device_streams};
        AudioStreamBasicDescription asbd{};
        status = read_property(actual_stream, address(kAudioStreamPropertyVirtualFormat), asbd);
        if (status != noErr) return os_result(status, ErrorStage::stream_format);
        Format actual{};
        auto result = validate_format(asbd, actual);
        if (!result.ok()) { result.stage = ErrorStage::stream_format; return result; }
        if (!initial && (actual.channels != format.channels || actual.noninterleaved != format.noninterleaved || actual.sample_rate != format.sample_rate))
            return {Error::configuration_changed, noErr, ErrorStage::stream_format};
        Float64 rate = 0;
        status = read_property(device, address(kAudioDevicePropertyNominalSampleRate), rate);
        if (status != noErr) return os_result(status, ErrorStage::device_rate);
        if (rate != actual.sample_rate) return {Error::unsupported_format, noErr, ErrorStage::device_rate};
        UInt32 nominal_frames = 0;
        status = read_property(device, address(kAudioDevicePropertyBufferFrameSize), nominal_frames);
        if (status != noErr) return os_result(status, ErrorStage::device_buffer);
        if (nominal_frames == 0 || nominal_frames > kMaxCaptureFrames) return {Error::unsupported_format, noErr, ErrorStage::device_buffer};
        if (initial) { stream = actual_stream; format = actual; }
        return {};
    }

    Result begin_io() noexcept {
        auto result = inspect_device(true);
        if (!result.ok()) return result;
        for (const auto property : {address(kAudioDevicePropertyDeviceIsAlive),
                                    address(kAudioDevicePropertyNominalSampleRate),
                                    address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)}) {
            result = listen(device, property);
            if (!result.ok()) return result;
        }
        result = listen(stream, address(kAudioStreamPropertyVirtualFormat));
        if (!result.ok()) return result;
        if (tap != kAudioObjectUnknown) {
            result = listen(tap, address(kAudioTapPropertyFormat));
            if (!result.ok()) return result;
        }
        for (std::size_t i = 0; i < process_count; ++i) {
            result = listen(processes[i], address(kAudioProcessPropertyPID));
            if (!result.ok()) return result;
        }
        // Re-read after listener installation to catch a format change in the
        // initial read/register window. Never modify a physical device format.
        result = inspect_device(false);
        if (!result.ok()) return result;
        auto status = AudioDeviceCreateIOProcID(device, capture, this, &io);
        if (status != noErr) return os_result(status);
        if (pending.load(std::memory_order_acquire) != 0) return unpack_error(pending.load(std::memory_order_acquire));
        accepting.store(deferred ? 2 : 1, std::memory_order_release);
        started = true; // Attempt stop even if AudioDeviceStart partially fails.
        status = AudioDeviceStart(device, io);
        if (status != noErr) return os_result(status);
        auto expected = static_cast<std::uint32_t>(Phase::starting);
        if (!phase.compare_exchange_strong(expected, static_cast<std::uint32_t>(Phase::running), std::memory_order_acq_rel))
            return unpack_error(pending.load(std::memory_order_acquire));
        return {};
    }

    Result cleanup() noexcept {
        accepting.store(0, std::memory_order_release);
        phase.store(static_cast<std::uint32_t>(Phase::stopping), std::memory_order_release);
        OSStatus first_error = noErr;
        if (io != nullptr) {
            if (started) AudioDeviceStop(device, io);
            const auto status = AudioDeviceDestroyIOProcID(device, io);
            if (status == noErr || status == kAudioHardwareBadObjectError) { io = nullptr; started = false; }
            else first_error = status;
        }
        for (std::size_t i = listener_count; i > 0; --i) {
            auto& listener = listeners[i - 1];
            if (!listener.active) continue;
            const auto status = AudioObjectRemovePropertyListener(listener.object, &listener.property, changed, this);
            if (status == noErr || status == kAudioHardwareBadObjectError) listener.active = false;
            else if (first_error == noErr) first_error = status;
        }
        // This wait is on the controller thread, never the audio callback.
        // New callbacks after accepting=0 cannot access caller-owned sink data.
        while (active_callbacks.load(std::memory_order_acquire) != 0) std::this_thread::yield();
        if (sink != nullptr) { sink->release(); sink = nullptr; }
        if (first_error == noErr && owns_device) {
            const auto status = AudioHardwareDestroyAggregateDevice(device);
            if (status == noErr || status == kAudioHardwareBadObjectError) { owns_device = false; device = 0; }
            else first_error = status;
        }
        if (first_error == noErr && tap != kAudioObjectUnknown) {
            if (@available(macOS 14.2, *)) {
                const auto status = AudioHardwareDestroyProcessTap(tap);
                if (status == noErr || status == kAudioHardwareBadObjectError) tap = 0;
                else first_error = status;
            }
        }
        phase.store(static_cast<std::uint32_t>(first_error == noErr ? Phase::stopped : Phase::cleanup_failed), std::memory_order_release);
        return first_error == noErr ? Result{} : Result{Error::cleanup_failed, first_error};
    }

    Result failed_start(Result original) noexcept {
        report(original);
        const auto cleanup_result = cleanup();
        // Preserve the original start error; snapshot exposes cleanup phase.
        if (!cleanup_result.ok()) phase.store(static_cast<std::uint32_t>(Phase::cleanup_failed), std::memory_order_release);
        return original;
    }
};

CaptureEngine::CaptureEngine() : state_(std::make_unique<State>()) {}

CaptureEngine::~CaptureEngine() {
    const auto result = stop();
    // If HAL refuses to detach callbacks, keep their inert context alive rather
    // than free memory that HAL may later reference. The sink has been detached
    // and callbacks drained; recovery/diagnostics must happen outside callbacks.
    if (!result.ok() && state_->resources()) static_cast<void>(state_.release());
}

Result CaptureEngine::start_physical(AudioObjectID device, const char* expected_uid, BoundedSink& sink, bool deferred) noexcept {
    if (device == kAudioObjectUnknown || expected_uid == nullptr || expected_uid[0] == '\0' ||
        strnlen(expected_uid, 1025) > 1024) return {Error::invalid_selection, noErr};
    auto result = state_->prepare(SourceKind::physical_input, sink, deferred);
    if (!result.ok()) return result;
    state_->device = device;
    CFStringRef actual_uid = nullptr;
    const auto status = read_property(device, address(kAudioDevicePropertyDeviceUID), actual_uid);
    if (status != noErr) return state_->failed_start(os_result(status));
    CFStringRef expected = CFStringCreateWithCString(kCFAllocatorDefault, expected_uid, kCFStringEncodingUTF8);
    const bool same = expected != nullptr && actual_uid != nullptr && CFEqual(actual_uid, expected);
    if (actual_uid != nullptr) CFRelease(actual_uid);
    if (expected != nullptr) CFRelease(expected);
    if (!same) return state_->failed_start({Error::invalid_selection, noErr});
    UInt32 transport = 0;
    result = os_result(read_property(device, address(kAudioDevicePropertyTransportType), transport));
    if (!result.ok()) return state_->failed_start(result);
    if (!physical_transport(transport)) return state_->failed_start({Error::invalid_selection, noErr});
    result = state_->begin_io();
    return result.ok() ? result : state_->failed_start(result);
}

Result CaptureEngine::start_processes(const pid_t* pids, std::size_t count, BoundedSink& sink, bool deferred) noexcept {
    auto result = validate_process_selection(pids, count);
    if (!result.ok()) return result;
    if (@available(macOS 14.2, *)) {
        result = state_->prepare(SourceKind::process_allowlist, sink, deferred);
        if (!result.ok()) return result;
        @autoreleasepool {
            @try {
                auto* process_ids = [NSMutableArray<NSNumber*> arrayWithCapacity:count];
                if (process_ids == nil) return state_->failed_start({Error::allocation_failure, noErr});
                for (std::size_t i = 0; i < count; ++i) {
                    AudioObjectID object = 0;
                    result = resolve_process(pids[i], object);
                    if (!result.ok()) return state_->failed_start(result);
                    state_->pids[i] = pids[i];
                    state_->processes[i] = object;
                    UInt32 output_active = 0;
                    result = os_result(read_property(object, address(kAudioProcessPropertyIsRunningOutput), output_active), ErrorStage::process_output);
                    if (!result.ok()) return state_->failed_start(result);
                    state_->source_active.store(state_->source_active.load(std::memory_order_relaxed) || output_active != 0, std::memory_order_release);
                    [process_ids addObject:@(object)];
                }
                state_->process_count = count;
                auto* description = [[CATapDescription alloc] initStereoMixdownOfProcesses:process_ids];
                if (description == nil) return state_->failed_start({Error::allocation_failure, noErr});
                description.name = @"Private Router Capture";
                description.UUID = [NSUUID UUID];
                description.privateTap = YES;
                description.exclusive = NO; // Inclusive allowlist; never a global/exclusion tap.
                description.muteBehavior = CATapUnmuted;
                if (@available(macOS 26.0, *)) {
                    if ([description respondsToSelector:@selector(setProcessRestoreEnabled:)]) {
                        [(id<AudioRouterProcessRestoration>)description setProcessRestoreEnabled:NO];
                    }
                }
                result = os_result(AudioHardwareCreateProcessTap(description, &state_->tap));
                if (!result.ok()) return state_->failed_start(result);
                AudioStreamBasicDescription tap_format{};
                result = os_result(read_property(state_->tap, address(kAudioTapPropertyFormat), tap_format));
                if (!result.ok()) return state_->failed_start(result);
                Format validated{};
                result = validate_format(tap_format, validated);
                if (!result.ok()) return state_->failed_start(result);
                auto* uid = description.UUID.UUIDString;
                auto* aggregate = @{
                    @kAudioAggregateDeviceNameKey: @"Private Router Capture",
                    @kAudioAggregateDeviceUIDKey: [@"private.audio.router.capture." stringByAppendingString:[NSUUID UUID].UUIDString],
                    @kAudioAggregateDeviceIsPrivateKey: @YES,
                    @kAudioAggregateDeviceIsStackedKey: @NO,
                    @kAudioAggregateDeviceTapAutoStartKey: @NO,
                    @kAudioAggregateDeviceSubDeviceListKey: @[],
                    @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: uid, @kAudioSubTapDriftCompensationKey: @NO}]
                };
                result = os_result(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &state_->device));
                if (!result.ok()) return state_->failed_start(result);
                state_->owns_device = true;
                result = state_->begin_io();
                return result.ok() ? result : state_->failed_start(result);
            } @catch (NSException*) {
                return state_->failed_start({Error::allocation_failure, noErr});
            }
        }
    }
    return {Error::unsupported_os, noErr};
}

Result CaptureEngine::stop() noexcept { return state_->cleanup(); }

Result CaptureEngine::arm() noexcept {
    const auto pending = state_->pending.load(std::memory_order_acquire);
    if (pending != 0) return unpack_error(pending);
    if (static_cast<Phase>(state_->phase.load(std::memory_order_acquire)) != Phase::running)
        return {Error::not_running, noErr};
    auto expected = std::uint32_t{2};
    if (state_->accepting.compare_exchange_strong(expected, 1, std::memory_order_acq_rel) || expected == 1) return {};
    const auto fault = state_->pending.load(std::memory_order_acquire);
    return fault ? unpack_error(fault) : Result{Error::not_running, noErr};
}

Result CaptureEngine::poll_health() noexcept {
    if (static_cast<Phase>(state_->phase.load(std::memory_order_acquire)) != Phase::running) {
        const auto pending = state_->pending.load(std::memory_order_acquire);
        return pending != 0 ? unpack_error(pending) : Result{Error::not_running, noErr};
    }
    auto result = state_->inspect_device(false);
    bool source_active = state_->source != SourceKind::process_allowlist;
    for (std::size_t i = 0; result.ok() && i < state_->process_count; ++i) {
        AudioObjectID current = 0;
        result = resolve_process(state_->pids[i], current);
        if (result.ok() && current != state_->processes[i]) result = {Error::source_unavailable, noErr, ErrorStage::process_identity};
        if (result.ok()) {
            UInt32 active = 0;
            result = os_result(read_property(current, address(kAudioProcessPropertyIsRunningOutput), active), ErrorStage::process_output);
            source_active = source_active || active != 0;
        }
    }
    if (result.ok()) state_->source_active = source_active;
    if (!result.ok()) state_->report(result);
    return result;
}

Snapshot CaptureEngine::snapshot() const noexcept {
    return {static_cast<Phase>(state_->phase.load(std::memory_order_acquire)), state_->source,
            state_->blocks.load(std::memory_order_relaxed), state_->frames.load(std::memory_order_relaxed),
            unpack_error(state_->pending.load(std::memory_order_acquire)), state_->source_active.load(std::memory_order_acquire),
            state_->accepting.load(std::memory_order_acquire) == 1,
            state_->priming_callbacks.load(std::memory_order_relaxed)};
}

Result CaptureEngine::take_error() noexcept { return unpack_error(state_->pending.exchange(0, std::memory_order_acq_rel)); }

#ifdef AR_CAPTURE_TESTING
Result CaptureTestAccess::prepare(CaptureEngine& engine, BoundedSink& sink, bool deferred) noexcept {
    auto result = engine.state_->prepare(SourceKind::physical_input, sink, deferred);
    if (!result.ok()) return result;
    engine.state_->format = {1, false, 48000};
    engine.state_->accepting.store(deferred ? 2 : 1, std::memory_order_release);
    engine.state_->phase.store(static_cast<std::uint32_t>(Phase::running), std::memory_order_release);
    return {};
}
void CaptureTestAccess::callback(CaptureEngine& engine, const AudioBufferList* input, std::uint64_t ticks) noexcept {
    AudioTimeStamp time{}; time.mFlags = kAudioTimeStampHostTimeValid; time.mHostTime = ticks;
    CaptureEngine::State::capture(0, nullptr, input, &time, nullptr, nullptr, engine.state_.get());
}
#endif

} // namespace audio_router::macos
