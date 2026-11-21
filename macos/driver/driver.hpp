#pragma once
#include <CoreAudio/AudioServerPlugIn.h>

namespace audio_router::driver {
constexpr AudioObjectID kPlugin = kAudioObjectPlugInObject;
constexpr AudioObjectID kDiscordDevice = 2;
constexpr AudioObjectID kDiscordStream = 3;
constexpr AudioObjectID kAlexaDevice = 4;
constexpr AudioObjectID kAlexaStream = 5;
constexpr UInt32 kZeroPeriod = 16384;
constexpr UInt32 kLatencyFrames = 960;
// Owned CFString property, global scope/main element, no qualifier. Standard
// kAudioObjectPropertyName remains the read-only HAL display representation.
constexpr AudioObjectPropertySelector kRouteNameProperty = 0x61726e6d; // 'arnm'
constexpr const char* kBundleID = "ai.agentsofchange.router.driver";
constexpr const char* kDiscordUID = "ai.agentsofchange.router.device.discord.v1";
constexpr const char* kAlexaUID = "ai.agentsofchange.router.device.alexa.v1";
}

extern "C" void* AudioRouterFactory(CFAllocatorRef allocator, CFUUIDRef type);

#ifdef AR_DRIVER_TESTING
extern "C" void AudioRouterTestSetBrokerPort(mach_port_t port);
extern "C" bool AudioRouterTestWaitForTransport(unsigned milliseconds);
#endif
