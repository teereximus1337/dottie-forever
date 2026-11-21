#include "driver.hpp"
#include <CoreAudio/AudioHardware.h> // Property constants only; no client HAL calls.
#include "../transport/pcm_transport.hpp"
#include "../transport/broker_protocol.hpp"

#include <CoreFoundation/CFPlugInCOM.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mach/mach_time.h>
#include <mutex>
#include <os/log.h>
#include <servers/bootstrap.h>
#include <string>
#include <thread>

#ifndef AR_TARGET_UID
#error Build must set AR_TARGET_UID to the owning user's numeric UID.
#endif

namespace audio_router::driver {
namespace {
using transport::Reader;
namespace broker = transport::broker;
constexpr UInt32 kRate = 48000;
constexpr std::size_t kClients = 64;
constexpr auto kMax64 = std::numeric_limits<std::uint64_t>::max();

// Temporary first-install diagnostics. Metadata only, bounded for the process
// lifetime, and never called from an IO operation or zero-timestamp callback.
void trace_metadata(const char* operation, AudioObjectID object, const AudioObjectPropertyAddress* p,
                    UInt32 capacity, OSStatus status, UInt32 returned_size) noexcept {
#if defined(AR_DRIVER_TRACE) && AR_DRIVER_TRACE
    static std::atomic<UInt32> count{0};
    constexpr UInt32 limit = 4096;
    if (count.load(std::memory_order_relaxed) >= limit) return;
    const auto sequence = count.fetch_add(1, std::memory_order_relaxed);
    if (sequence >= limit) return;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT,
        "ARHAL seq=%{public}u op=%{public}s object=%{public}u selector=0x%{public}08x scope=0x%{public}08x element=%{public}u capacity=%{public}u status=%{public}d returned_size=%{public}u",
        sequence, operation, object, p ? p->mSelector : 0, p ? p->mScope : 0,
        p ? p->mElement : 0, capacity, status, returned_size);
#else
    (void)operation; (void)object; (void)p; (void)capacity; (void)status; (void)returned_size;
#endif
}

struct Client { UInt32 id = 0; bool used = false, started = false; };
struct Device {
    std::array<Client, kClients> clients{};
    std::atomic<UInt32> running{0};
    std::atomic<UInt64> anchor{0}, seed{1}, clock_version{0};
};
struct State {
    std::mutex control;
    AudioServerPlugInHostRef host = nullptr;
    std::atomic<UInt32> references{1};
    std::atomic<bool> initialized{false}, exit{false};
    Device devices[2];
    CFStringRef names[2]{CFSTR("Router · Apps"), CFSTR("Router · Assistant")};
    mach_timebase_info_data_t timebase{1, 1};
    Reader mapping;
    std::atomic<const Reader*> reader{nullptr};
    std::thread mapper;
#ifdef AR_DRIVER_TESTING
    mach_port_t test_broker_port = MACH_PORT_NULL;
#endif
    ~State() {
        exit.store(true, std::memory_order_release);
        if (mapper.joinable()) mapper.join();
        CFRelease(names[0]); CFRelease(names[1]);
    }
} g;

static_assert(std::atomic<UInt64>::is_always_lock_free && std::atomic<UInt32>::is_always_lock_free,
              "Driver callbacks require lock-free state");

int device_index(AudioObjectID object) noexcept {
    return object == kDiscordDevice ? 0 : object == kAlexaDevice ? 1 : -1;
}
int stream_index(AudioObjectID object) noexcept {
    return object == kDiscordStream ? 0 : object == kAlexaStream ? 1 : -1;
}
bool known(AudioObjectID object) noexcept { return object == kPlugin || device_index(object) >= 0 || stream_index(object) >= 0; }
AudioObjectID device_id(int index) noexcept { return index == 0 ? kDiscordDevice : kAlexaDevice; }
AudioObjectID stream_id(int index) noexcept { return index == 0 ? kDiscordStream : kAlexaStream; }
CFStringRef uid(int index) noexcept { return index == 0 ? CFSTR("ai.agentsofchange.router.device.discord.v1") : CFSTR("ai.agentsofchange.router.device.alexa.v1"); }
CFStringRef name_key(int index) noexcept { return index == 0 ? CFSTR("discord-input-name") : CFSTR("alexa-input-name"); }

std::uint64_t scale(std::uint64_t value, std::uint32_t numerator, std::uint32_t denominator) noexcept {
    if (denominator == 0 || numerator == 0) return 0;
    const auto quotient = value / denominator;
    if (quotient > kMax64 / numerator) return kMax64;
    const auto high = quotient * numerator;
    const auto low = (value % denominator) * numerator / denominator;
    return high > kMax64 - low ? kMax64 : high + low;
}
std::uint64_t ns_from_ticks(std::uint64_t ticks) noexcept { return scale(ticks, g.timebase.numer, g.timebase.denom); }
std::uint64_t ticks_from_ns(std::uint64_t ns) noexcept { return scale(ns, g.timebase.denom, g.timebase.numer); }

bool connect_broker(Reader& reader) {
    const auto service_name = std::string(broker::kServicePrefix) + std::to_string(AR_TARGET_UID);
    mach_port_t service = MACH_PORT_NULL;
#ifdef AR_DRIVER_TESTING
    if (g.test_broker_port != MACH_PORT_NULL) {
        if (mach_port_mod_refs(mach_task_self(), g.test_broker_port, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) return false;
        service = g.test_broker_port;
    } else
#endif
    if (bootstrap_look_up(bootstrap_port, service_name.c_str(), &service) != KERN_SUCCESS) return false;
    mach_port_t receive = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receive) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), service); return false;
    }
    union Message {
        broker::Request request;
        struct { broker::Reply reply; mach_msg_max_trailer_t trailer; } response;
        Message() { std::memset(this, 0, sizeof(*this)); }
    } message;
    message.request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message.request.header.msgh_size = sizeof(broker::Request);
    message.request.header.msgh_remote_port = service;
    message.request.header.msgh_local_port = receive;
    message.request.header.msgh_id = broker::kRequestID;
    message.request.protocol = broker::kProtocol;
    message.request.target_uid = AR_TARGET_UID;
    const auto status = mach_msg(&message.request.header,
        MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
        sizeof(broker::Request), sizeof(message), receive, 500, MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(), service);
    mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1);
    if (status != MACH_MSG_SUCCESS) return false;
    auto& reply = message.response.reply;
    const bool envelope = reply.header.msgh_id == broker::kReplyID && reply.header.msgh_size == sizeof(broker::Reply) &&
        (reply.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 && reply.body.msgh_descriptor_count == 1 &&
        reply.memory.type == MACH_MSG_PORT_DESCRIPTOR && reply.memory.name != MACH_PORT_NULL &&
        reply.protocol == broker::kProtocol && reply.status == 0;
    const bool connected = envelope && reader.open_memory_entry(reply.memory.name, reply.region_bytes).ok();
    mach_msg_destroy(&reply.header);
    return connected;
}

void map_transport() noexcept {
    while (!g.exit.load(std::memory_order_acquire)) {
        try {
            const bool ready = connect_broker(g.mapping);
            if (ready) { g.reader.store(&g.mapping, std::memory_order_release); return; }
        } catch (...) { /* Keep endpoints alive and silent; retry off the audio thread. */ }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

CFStringRef normalized_name(CFStringRef value) {
    if (value == nullptr || CFGetTypeID(value) != CFStringGetTypeID()) return nullptr;
    auto name = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, value);
    if (name == nullptr) return nullptr;
    CFStringTrimWhitespace(name);
    const auto count = CFStringGetLength(name);
    bool valid = count > 0 && count <= 48;
    auto controls = CFCharacterSetGetPredefined(kCFCharacterSetControl);
    for (CFIndex i = 0; valid && i < count; ++i) if (CFCharacterSetIsCharacterMember(controls, CFStringGetCharacterAtIndex(name, i))) valid = false;
    if (!valid) { CFRelease(name); return nullptr; }
    return name;
}
bool same_name(CFStringRef first, CFStringRef second) {
    return CFStringCompare(first, second, kCFCompareCaseInsensitive | kCFCompareNonliteral) == kCFCompareEqualTo;
}
void notify(AudioObjectID object, AudioObjectPropertySelector selector) {
    const AudioObjectPropertyAddress property{selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (g.host != nullptr && g.host->PropertiesChanged != nullptr) g.host->PropertiesChanged(g.host, object, 1, &property);
}

AudioStreamBasicDescription format() noexcept {
    return {48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            4, 1, 4, 1, 32, 0};
}
bool same_format(const AudioStreamBasicDescription& a) noexcept {
    const auto f = format();
    return a.mSampleRate == f.mSampleRate && a.mFormatID == f.mFormatID && a.mFormatFlags == f.mFormatFlags &&
        a.mBytesPerPacket == 4 && a.mFramesPerPacket == 1 && a.mBytesPerFrame == 4 && a.mChannelsPerFrame == 1 && a.mBitsPerChannel == 32;
}

HRESULT query_interface(void*, REFIID id, LPVOID* out);
ULONG add_ref(void*);
ULONG release(void*);
OSStatus initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
OSStatus create_device(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
OSStatus destroy_device(AudioServerPlugInDriverRef, AudioObjectID);
OSStatus add_client(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
OSStatus remove_client(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
OSStatus configuration_change(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
Boolean has_property(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
OSStatus is_settable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
OSStatus property_size(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
OSStatus get_property(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
OSStatus set_property(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
OSStatus start_io(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus stop_io(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
OSStatus zero_timestamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
OSStatus will_do(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
OSStatus io_boundary(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
OSStatus do_io(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);

AudioServerPlugInDriverInterface interface{
    nullptr, query_interface, add_ref, release, initialize, create_device, destroy_device,
    add_client, remove_client, configuration_change, configuration_change,
    has_property, is_settable, property_size, get_property, set_property,
    start_io, stop_io, zero_timestamp, will_do, io_boundary, do_io, io_boundary
};
AudioServerPlugInDriverInterface* interface_pointer = &interface;
AudioServerPlugInDriverRef reference = &interface_pointer;
bool valid_driver(AudioServerPlugInDriverRef candidate) noexcept { return candidate == reference; }

HRESULT query_interface(void* driver, REFIID id, LPVOID* out) {
    if (driver != reference || out == nullptr) return E_INVALIDARG;
    *out = nullptr;
    const auto uuid = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, id);
    const bool matches = uuid && (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID));
    if (uuid) CFRelease(uuid);
    if (!matches) return E_NOINTERFACE;
    *out = reference; add_ref(reference); return S_OK;
}
ULONG add_ref(void* driver) { return driver == reference ? g.references.fetch_add(1, std::memory_order_relaxed) + 1 : 0; }
ULONG release(void* driver) {
    if (driver != reference) return 0;
    auto count = g.references.load(std::memory_order_relaxed);
    while (count > 0 && !g.references.compare_exchange_weak(count, count - 1, std::memory_order_relaxed)) {}
    return count > 0 ? count - 1 : 0;
}

OSStatus initialize_impl(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (!valid_driver(driver) || host == nullptr) return kAudioHardwareIllegalOperationError;
    std::lock_guard<std::mutex> guard(g.control);
    if (g.initialized.load(std::memory_order_acquire)) return noErr;
    g.host = host;
    if (mach_timebase_info(&g.timebase) != KERN_SUCCESS || g.timebase.numer == 0 || g.timebase.denom == 0)
        return kAudioHardwareUnspecifiedError;
    for (int index = 0; index < 2; ++index) {
        g.devices[index].anchor.store(mach_absolute_time(), std::memory_order_relaxed);
        if (host->CopyFromStorage) {
            CFPropertyListRef saved = nullptr;
            if (host->CopyFromStorage(host, name_key(index), &saved) == noErr && saved != nullptr) {
                CFStringRef name = CFGetTypeID(saved) == CFStringGetTypeID() ? normalized_name(static_cast<CFStringRef>(saved)) : nullptr;
                if (name != nullptr && !same_name(name, g.names[1 - index])) { CFRelease(g.names[index]); g.names[index] = name; }
                else if (name) CFRelease(name);
                CFRelease(saved);
            }
        }
    }
    try { g.mapper = std::thread(map_transport); }
    catch (...) { return kAudioHardwareUnspecifiedError; }
    g.initialized.store(true, std::memory_order_release);
    return noErr;
}
OSStatus initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    trace_metadata("Initialize.begin", kPlugin, nullptr, 0, noErr, 0);
    const auto status = initialize_impl(driver, host);
    trace_metadata("Initialize.end", kPlugin, nullptr, 0, status, 0);
    return status;
}
OSStatus create_device(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID* out) {
    if (out) *out = kAudioObjectUnknown; return kAudioHardwareUnsupportedOperationError;
}
OSStatus destroy_device(AudioServerPlugInDriverRef, AudioObjectID) { return kAudioHardwareUnsupportedOperationError; }
OSStatus configuration_change(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*) { return kAudioHardwareUnsupportedOperationError; }

OSStatus add_client(AudioServerPlugInDriverRef driver, AudioObjectID object, const AudioServerPlugInClientInfo* info) {
    const int index = device_index(object);
    if (!valid_driver(driver) || index < 0 || info == nullptr) return kAudioHardwareBadObjectError;
    std::lock_guard<std::mutex> guard(g.control);
    for (auto& client : g.devices[index].clients) if (client.used && client.id == info->mClientID) return noErr;
    for (auto& client : g.devices[index].clients) if (!client.used) { client = {info->mClientID, true, false}; return noErr; }
    return kAudioHardwareIllegalOperationError;
}
OSStatus remove_client(AudioServerPlugInDriverRef driver, AudioObjectID object, const AudioServerPlugInClientInfo* info) {
    const int index = device_index(object);
    if (!valid_driver(driver) || index < 0 || info == nullptr) return kAudioHardwareBadObjectError;
    bool changed = false;
    {
        std::lock_guard<std::mutex> guard(g.control);
        for (auto& client : g.devices[index].clients) if (client.used && client.id == info->mClientID) {
            if (client.started) changed = g.devices[index].running.fetch_sub(1, std::memory_order_release) == 1;
            client = {}; break;
        }
    }
    if (changed) notify(object, kAudioDevicePropertyDeviceIsRunning);
    return noErr;
}

bool supported_scope(AudioObjectPropertyScope scope) noexcept {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput;
}
Boolean has_property_impl(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t, const AudioObjectPropertyAddress* p) {
    if (!valid_driver(driver) || !known(object) || p == nullptr || p->mElement != kAudioObjectPropertyElementMain || !supported_scope(p->mScope)) return false;
    switch (p->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
            return true;
        default: break;
    }
    if (object == kPlugin) {
        switch (p->mSelector) {
            case kAudioPlugInPropertyBundleID: case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle: case kAudioPlugInPropertyBoxList: case kAudioPlugInPropertyTranslateUIDToBox:
                return p->mScope == kAudioObjectPropertyScopeGlobal;
            default: return false;
        }
    }
    if (device_index(object) >= 0) {
        switch (p->mSelector) {
            case kRouteNameProperty: case kAudioObjectPropertyCustomPropertyInfoList:
                return p->mScope == kAudioObjectPropertyScopeGlobal;
            case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyStreamConfiguration: case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout: case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyClockAlgorithm: case kAudioDevicePropertyClockIsStable: case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyHogMode: case kAudioDevicePropertyDeviceIsRunningSomewhere:
                return true;
            default: return false;
        }
    }
    switch (p->mSelector) {
        case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default: return false;
    }
}
Boolean has_property(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p) {
    const auto present = has_property_impl(driver, object, pid, p);
    trace_metadata("HasProperty", object, p, 0, present ? noErr : kAudioHardwareUnknownPropertyError, present ? 1 : 0);
    return present;
}

OSStatus is_settable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p, Boolean* out) {
    if (out == nullptr) return kAudioHardwareIllegalOperationError;
    if (!has_property(driver, object, pid, p)) return known(object) ? kAudioHardwareUnknownPropertyError : kAudioHardwareBadObjectError;
    *out = (device_index(object) >= 0 && (p->mSelector == kRouteNameProperty || p->mSelector == kAudioDevicePropertyNominalSampleRate)) ||
        (stream_index(object) >= 0 && (p->mSelector == kAudioStreamPropertyVirtualFormat || p->mSelector == kAudioStreamPropertyPhysicalFormat));
    return noErr;
}

UInt32 object_list(AudioObjectID object, AudioObjectPropertyScope scope, AudioObjectID* out,
                  UInt32 qualifier_size = 0, const void* qualifier = nullptr) noexcept {
    const AudioClassID child_class = object == kPlugin ? kAudioDeviceClassID : kAudioStreamClassID;
    if (qualifier_size != 0) {
        bool match = false;
        for (UInt32 offset = 0; offset < qualifier_size; offset += sizeof(AudioClassID)) {
            AudioClassID requested; std::memcpy(&requested, static_cast<const char*>(qualifier) + offset, sizeof(requested));
            if (requested == child_class || requested == kAudioObjectClassID) match = true;
        }
        if (!match) return 0;
    }
    if (object == kPlugin) { out[0] = kDiscordDevice; out[1] = kAlexaDevice; return 2; }
    const auto index = device_index(object);
    if (index >= 0 && scope != kAudioObjectPropertyScopeOutput) { out[0] = stream_id(index); return 1; }
    return 0;
}
OSStatus property_size_impl(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p,
                       UInt32 qualifier_size, const void* qualifier, UInt32* out) {
    if (out == nullptr) return kAudioHardwareIllegalOperationError;
    if (!has_property(driver, object, pid, p)) return known(object) ? kAudioHardwareUnknownPropertyError : kAudioHardwareBadObjectError;
    if (p->mSelector == kAudioObjectPropertyOwnedObjects && qualifier_size != 0 &&
        (qualifier == nullptr || qualifier_size % sizeof(AudioClassID) != 0)) return kAudioHardwareBadPropertySizeError;
    AudioObjectID list[2]{};
    switch (p->mSelector) {
        case kAudioObjectPropertyName: case kRouteNameProperty: case kAudioObjectPropertyManufacturer: case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyResourceBundle: case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
            *out = sizeof(CFStringRef); break;
        case kAudioObjectPropertyCustomPropertyInfoList: *out = sizeof(AudioServerPlugInCustomPropertyInfo); break;
        case kAudioObjectPropertyOwnedObjects:
            *out = object_list(object, p->mScope, list, qualifier_size, qualifier) * sizeof(AudioObjectID); break;
        case kAudioDevicePropertyStreams: *out = object_list(object, p->mScope, list) * sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: *out = 2 * sizeof(AudioObjectID); break;
        case kAudioPlugInPropertyBoxList: case kAudioObjectPropertyControlList: *out = 0; break;
        case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); break;
        case kAudioDevicePropertyAvailableNominalSampleRates: *out = sizeof(AudioValueRange); break;
        case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * sizeof(UInt32); break;
        case kAudioDevicePropertyPreferredChannelLayout: *out = offsetof(AudioChannelLayout, mChannelDescriptions); break;
        case kAudioDevicePropertyStreamConfiguration:
            *out = p->mScope == kAudioObjectPropertyScopeOutput ? offsetof(AudioBufferList, mBuffers) : sizeof(AudioBufferList); break;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *out = sizeof(AudioStreamBasicDescription); break;
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: *out = sizeof(AudioStreamRangedDescription); break;
        default: *out = sizeof(UInt32); break;
    }
    return noErr;
}
OSStatus property_size(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p,
                       UInt32 qualifier_size, const void* qualifier, UInt32* out) {
    const auto status = property_size_impl(driver, object, pid, p, qualifier_size, qualifier, out);
    trace_metadata("GetPropertyDataSize", object, p, 0, status, status == noErr && out ? *out : 0);
    return status;
}

template<class T> OSStatus copy_value(const T& value, UInt32 capacity, UInt32* used, void* out) {
    if (capacity < sizeof(T) || out == nullptr || used == nullptr) return kAudioHardwareBadPropertySizeError;
    std::memcpy(out, &value, sizeof(T)); *used = sizeof(T); return noErr;
}
OSStatus copy_string(CFStringRef value, UInt32 capacity, UInt32* used, void* out) {
    if (capacity < sizeof(CFStringRef) || out == nullptr || used == nullptr) return kAudioHardwareBadPropertySizeError;
    CFRetain(value); return copy_value(value, capacity, used, out);
}
OSStatus get_property_impl(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p,
                      UInt32 qualifier_size, const void* qualifier, UInt32 capacity, UInt32* used, void* out) {
    if (used == nullptr) return kAudioHardwareIllegalOperationError;
    *used = 0;
    UInt32 required = 0;
    auto status = property_size(driver, object, pid, p, qualifier_size, qualifier, &required);
    if (status != noErr) return status;
    if (capacity < required || (required != 0 && out == nullptr)) return kAudioHardwareBadPropertySizeError;
    const int device = device_index(object), stream = stream_index(object);
    const bool input = p->mScope != kAudioObjectPropertyScopeOutput;
    UInt32 value = 0;
    switch (p->mSelector) {
        case kAudioObjectPropertyBaseClass: value = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: value = object == kPlugin ? kAudioPlugInClassID : device >= 0 ? kAudioDeviceClassID : kAudioStreamClassID; break;
        case kAudioObjectPropertyOwner: value = object == kPlugin ? kAudioObjectUnknown : device >= 0 ? kPlugin : device_id(stream); break;
        case kAudioObjectPropertyName: case kRouteNameProperty: {
            if (device >= 0) { std::lock_guard<std::mutex> guard(g.control); return copy_string(g.names[device], capacity, used, out); }
            return copy_string(object == kPlugin ? CFSTR("Audio Router") : stream == 0 ? CFSTR("Router Apps Input Stream") : CFSTR("Router Assistant Input Stream"), capacity, used, out);
        }
        case kAudioObjectPropertyCustomPropertyInfoList:
            return copy_value(AudioServerPlugInCustomPropertyInfo{kRouteNameProperty,
                kAudioServerPlugInCustomPropertyDataTypeCFString, kAudioServerPlugInCustomPropertyDataTypeNone}, capacity, used, out);
        case kAudioObjectPropertyManufacturer: return copy_string(CFSTR("Agents of Change"), capacity, used, out);
        case kAudioPlugInPropertyBundleID: return copy_string(CFSTR("ai.agentsofchange.router.driver"), capacity, used, out);
        case kAudioPlugInPropertyResourceBundle: return copy_string(CFSTR(""), capacity, used, out);
        case kAudioDevicePropertyDeviceUID: return copy_string(uid(device), capacity, used, out);
        case kAudioDevicePropertyModelUID: return copy_string(CFSTR("ai.agentsofchange.router.model.v1"), capacity, used, out);
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            AudioObjectID list[2]{}; const auto count = object_list(object, p->mScope, list,
                p->mSelector == kAudioObjectPropertyOwnedObjects ? qualifier_size : 0, qualifier);
            if (count) std::memcpy(out, list, count * sizeof(AudioObjectID)); *used = count * sizeof(AudioObjectID); return noErr;
        }
        case kAudioPlugInPropertyDeviceList: case kAudioDevicePropertyRelatedDevices: {
            const AudioObjectID list[2]{kDiscordDevice, kAlexaDevice}; std::memcpy(out, list, sizeof(list)); *used = sizeof(list); return noErr;
        }
        case kAudioPlugInPropertyBoxList: case kAudioObjectPropertyControlList: return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyTranslateUIDToBox: {
            if (qualifier == nullptr || qualifier_size != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            CFStringRef selected = nullptr; std::memcpy(&selected, qualifier, sizeof(selected));
            if (selected == nullptr || CFGetTypeID(selected) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
            if (p->mSelector == kAudioPlugInPropertyTranslateUIDToDevice)
                value = CFEqual(selected, uid(0)) ? kDiscordDevice : CFEqual(selected, uid(1)) ? kAlexaDevice : kAudioObjectUnknown;
            break;
        }
        case kAudioDevicePropertyTransportType: value = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyClockIsStable: case kAudioStreamPropertyIsActive: value = 1; break;
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceIsRunningSomewhere: value = g.devices[device].running.load(std::memory_order_acquire) != 0; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: value = input ? 1 : 0; break;
        case kAudioDevicePropertyLatency: value = input ? kLatencyFrames : 0; break;
        case kAudioDevicePropertyNominalSampleRate: return copy_value(Float64{48000}, capacity, used, out);
        case kAudioDevicePropertyAvailableNominalSampleRates: return copy_value(AudioValueRange{48000, 48000}, capacity, used, out);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            const UInt32 channels[2]{1, 1}; std::memcpy(out, channels, sizeof(channels)); *used = sizeof(channels); return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout layout{}; layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            std::memcpy(out, &layout, required); *used = required; return noErr;
        }
        case kAudioDevicePropertyStreamConfiguration: {
            AudioBufferList list{}; list.mNumberBuffers = input ? 1 : 0;
            list.mBuffers[0] = {1, 0, nullptr}; std::memcpy(out, &list, required); *used = required; return noErr;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: value = kZeroPeriod; break;
        case kAudioDevicePropertyClockAlgorithm: value = kAudioDeviceClockAlgorithmRaw; break;
        case kAudioDevicePropertyHogMode: return copy_value(pid_t{-1}, capacity, used, out);
        case kAudioStreamPropertyDirection: case kAudioStreamPropertyStartingChannel: value = 1; break;
        case kAudioStreamPropertyTerminalType: value = kAudioStreamTerminalTypeMicrophone; break;
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: return copy_value(format(), capacity, used, out);
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return copy_value(AudioStreamRangedDescription{format(), {48000, 48000}}, capacity, used, out);
        default: break; // fixed clock domain, safety offset, stream latency and hidden flag are zero.
    }
    return copy_value(value, capacity, used, out);
}
OSStatus get_property(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p,
                      UInt32 qualifier_size, const void* qualifier, UInt32 capacity, UInt32* used, void* out) {
    const auto status = get_property_impl(driver, object, pid, p, qualifier_size, qualifier, capacity, used, out);
    trace_metadata("GetPropertyData", object, p, capacity, status, status == noErr && used ? *used : 0);
    return status;
}

OSStatus set_property(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress* p,
                      UInt32 qualifier_size, const void*, UInt32 size, const void* data) {
    Boolean settable = false;
    const auto status = is_settable(driver, object, pid, p, &settable);
    if (status != noErr) return status;
    if (!settable) return kAudioHardwareUnsupportedOperationError;
    if (data == nullptr) return kAudioHardwareIllegalOperationError;
    if (p->mSelector == kRouteNameProperty && qualifier_size != 0) return kAudioHardwareBadPropertySizeError;
    if (p->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 rate; std::memcpy(&rate, data, sizeof(rate)); return rate == 48000 ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (p->mSelector == kAudioStreamPropertyVirtualFormat || p->mSelector == kAudioStreamPropertyPhysicalFormat) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        AudioStreamBasicDescription value; std::memcpy(&value, data, sizeof(value)); return same_format(value) ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (size != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
    CFStringRef requested = nullptr; std::memcpy(&requested, data, sizeof(requested));
    CFStringRef name = normalized_name(requested);
    if (name == nullptr) return kAudioHardwareIllegalOperationError;
    const int index = device_index(object);
    {
        std::lock_guard<std::mutex> guard(g.control);
        if (same_name(name, g.names[1 - index])) { CFRelease(name); return kAudioHardwareIllegalOperationError; }
        if (g.host && g.host->WriteToStorage) {
            const auto stored = g.host->WriteToStorage(g.host, name_key(index), name);
            if (stored != noErr) { CFRelease(name); return stored; }
        }
        CFRelease(g.names[index]); g.names[index] = name;
    }
    notify(object, kAudioObjectPropertyName);
    notify(object, kRouteNameProperty);
    return noErr;
}

OSStatus start_io(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 id) {
    const int index = device_index(object);
    if (!valid_driver(driver) || index < 0 || !g.initialized.load(std::memory_order_acquire)) return kAudioHardwareBadObjectError;
    bool changed = false, found = false;
    {
        std::lock_guard<std::mutex> guard(g.control); auto& device = g.devices[index];
        for (auto& client : device.clients) if (client.used && client.id == id) {
            found = true;
            if (!client.started) {
                if (device.running.load(std::memory_order_relaxed) == 0) {
                    const auto version = device.clock_version.load(std::memory_order_relaxed);
                    device.clock_version.store(version + 1, std::memory_order_release);
                    device.anchor.store(mach_absolute_time(), std::memory_order_relaxed);
                    device.seed.fetch_add(1, std::memory_order_relaxed);
                    device.clock_version.store(version + 2, std::memory_order_release); changed = true;
                }
                client.started = true; device.running.fetch_add(1, std::memory_order_release);
            }
            break;
        }
    }
    if (changed) notify(object, kAudioDevicePropertyDeviceIsRunning);
    return found ? noErr : kAudioHardwareIllegalOperationError;
}
OSStatus stop_io(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 id) {
    const int index = device_index(object);
    if (!valid_driver(driver) || index < 0) return kAudioHardwareBadObjectError;
    bool changed = false;
    {
        std::lock_guard<std::mutex> guard(g.control); auto& device = g.devices[index];
        for (auto& client : device.clients) if (client.used && client.id == id && client.started) {
            client.started = false; changed = device.running.fetch_sub(1, std::memory_order_release) == 1; break;
        }
    }
    if (changed) notify(object, kAudioDevicePropertyDeviceIsRunning);
    return noErr;
}
OSStatus zero_timestamp(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32, Float64* samples, UInt64* host, UInt64* seed) {
    const int index = device_index(object);
    if (!valid_driver(driver) || index < 0) return kAudioHardwareBadObjectError;
    if (!samples || !host || !seed) return kAudioHardwareIllegalOperationError;
    UInt64 anchor = 0, captured_seed = 0; bool consistent = false;
    for (int retry = 0; retry < 3; ++retry) {
        const auto version = g.devices[index].clock_version.load(std::memory_order_acquire);
        if ((version & 1) != 0) continue;
        anchor = g.devices[index].anchor.load(std::memory_order_relaxed);
        captured_seed = g.devices[index].seed.load(std::memory_order_relaxed);
        if (version == g.devices[index].clock_version.load(std::memory_order_acquire)) { consistent = true; break; }
    }
    if (!consistent) return kAudioHardwareUnspecifiedError;
    const auto current = mach_absolute_time();
    const auto elapsed = current >= anchor ? ns_from_ticks(current - anchor) : 0;
    const auto periods = std::floor(static_cast<long double>(elapsed) * kRate / (static_cast<long double>(kZeroPeriod) * 1000000000.0L));
    *samples = static_cast<Float64>(periods * kZeroPeriod);
    const auto offset_ns = static_cast<std::uint64_t>(periods * kZeroPeriod * 1000000000.0L / kRate);
    *host = anchor + ticks_from_ns(offset_ns);
    *seed = captured_seed;
    return noErr;
}
OSStatus will_do(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32, UInt32 operation, Boolean* will, Boolean* in_place) {
    if (!valid_driver(driver) || device_index(object) < 0) return kAudioHardwareBadObjectError;
    if (!will || !in_place) return kAudioHardwareIllegalOperationError;
    *will = operation == kAudioServerPlugInIOOperationReadInput; *in_place = true; return noErr;
}
OSStatus io_boundary(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32, UInt32, UInt32 frames, const AudioServerPlugInIOCycleInfo*) {
    return valid_driver(driver) && device_index(object) >= 0 && frames <= transport::kMaxReadFrames ? noErr : kAudioHardwareIllegalOperationError;
}
OSStatus do_io(AudioServerPlugInDriverRef driver, AudioObjectID object, AudioObjectID stream, UInt32, UInt32 operation,
               UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* main, void*) {
    const int index = device_index(object);
    if (!valid_driver(driver) || index < 0 || stream != stream_id(index)) return kAudioHardwareBadObjectError;
    if (operation != kAudioServerPlugInIOOperationReadInput) return kAudioHardwareUnsupportedOperationError;
    if (!main || !cycle || frames == 0 || frames > transport::kMaxReadFrames) return kAudioHardwareIllegalOperationError;
    auto* output = static_cast<float*>(main);
    std::fill_n(output, frames, 0.0F);
    if (g.devices[index].running.load(std::memory_order_acquire) == 0) return noErr;
    const auto* reader = g.reader.load(std::memory_order_acquire);
    if (!reader) return noErr;
    const auto now_ns = ns_from_ticks(mach_absolute_time());
    std::uint64_t sample_ns = 0;
    if ((cycle->mInputTime.mFlags & kAudioTimeStampHostTimeValid) != 0) sample_ns = ns_from_ticks(cycle->mInputTime.mHostTime);
    else if ((cycle->mInputTime.mFlags & kAudioTimeStampSampleTimeValid) != 0 && std::isfinite(cycle->mInputTime.mSampleTime) && cycle->mInputTime.mSampleTime >= 0) {
        const auto offset = static_cast<long double>(cycle->mInputTime.mSampleTime) * 1000000000.0L / kRate;
        const auto anchor_ns = ns_from_ticks(g.devices[index].anchor.load(std::memory_order_acquire));
        if (offset > static_cast<long double>(kMax64 - anchor_ns)) return noErr;
        sample_ns = anchor_ns + static_cast<std::uint64_t>(offset);
    } else return noErr;
    if (sample_ns < transport::kReaderDelayNs) return noErr;
    reader->read(index == 0 ? transport::Route::discord : transport::Route::alexa,
                 output, frames, sample_ns - transport::kReaderDelayNs, now_ns);
    return noErr;
}
} // namespace
} // namespace audio_router::driver

extern "C" __attribute__((visibility("default"))) void* AudioRouterFactory(CFAllocatorRef, CFUUIDRef type) {
    if (type == nullptr || !CFEqual(type, kAudioServerPlugInTypeUUID)) return nullptr;
    return audio_router::driver::reference;
}
#ifdef AR_DRIVER_TESTING
extern "C" void AudioRouterTestSetBrokerPort(mach_port_t port) {
    if (!audio_router::driver::g.initialized.load()) audio_router::driver::g.test_broker_port = port;
}
extern "C" bool AudioRouterTestWaitForTransport(unsigned milliseconds) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
    do {
        if (audio_router::driver::g.reader.load(std::memory_order_acquire)) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}
#endif
