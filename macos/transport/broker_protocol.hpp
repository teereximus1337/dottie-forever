#pragma once
#include <mach/mach.h>
#include <cstdint>

namespace audio_router::transport::broker {
constexpr std::uint32_t kProtocol = 1;
constexpr mach_msg_id_t kRequestID = 0x41525031;
constexpr mach_msg_id_t kReplyID = 0x41525032;
constexpr const char* kServicePrefix = "ai.agentsofchange.router.pcm-broker.";

struct Request {
    mach_msg_header_t header;
    std::uint32_t protocol;
    std::uint32_t target_uid;
};
struct Reply {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t memory;
    std::uint32_t protocol;
    std::int32_t status;
    std::uint64_t region_bytes;
};

// Requests contain no file paths. The broker must validate the audit trailer's
// effective UID against its configured target user/root/audio-service policy.
// Success transfers one memory-entry send right limited to VM_PROT_READ.
// Failure has status!=0, descriptor_count=0 and memory.name=MACH_PORT_NULL.
}
