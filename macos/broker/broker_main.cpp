#include "../transport/broker_protocol.hpp"
#include "../transport/pcm_transport.hpp"
#include <bsm/libbsm.h>
#include <servers/bootstrap.h>
#include <mach/mach_vm.h>
#include <array>
#include <charconv>
#include <csignal>
#include <cstring>
#include <iostream>
#include <pwd.h>
#include <string>
#include <thread>
#include <unistd.h>

namespace {
namespace ipc = audio_router::transport;
namespace wire = ipc::broker;
volatile std::sig_atomic_t interrupted = 0;
[[maybe_unused]] void interrupt(int) { interrupted = 1; }
bool permitted(uid_t sender, uid_t owner, uid_t audio) { return sender == owner || sender == 0 || (audio != 0 && sender == audio); }
enum Status : std::int32_t { success = 0, malformed = 1, forbidden = 2, not_ready = 3, map_failed = 4 };

bool serve_once(mach_port_t port, uid_t owner, uid_t audio, const std::string& path, mach_msg_timeout_t timeout) {
    struct alignas(8) Envelope { mach_msg_header_t header; std::array<unsigned char, 1024> remainder; } request{};
    const auto received = mach_msg(&request.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT |
        MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
        0, sizeof(request), port, timeout, MACH_PORT_NULL);
    if (received == MACH_RCV_TIMED_OUT) return true;
    if (received != MACH_MSG_SUCCESS) return !interrupted;
    const auto& header = request.header;
    wire::Reply response{};
    response.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    const bool reply_once = MACH_MSGH_BITS_REMOTE(header.msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE;
    response.header.msgh_remote_port = reply_once ? header.msgh_remote_port : MACH_PORT_NULL;
    response.header.msgh_size = sizeof(response);
    response.header.msgh_id = wire::kReplyID;
    response.protocol = wire::kProtocol;
    response.status = malformed;
    mach_port_t entry = MACH_PORT_NULL;
    if (header.msgh_size == sizeof(wire::Request) && header.msgh_id == wire::kRequestID &&
        !(header.msgh_bits & MACH_MSGH_BITS_COMPLEX) && MACH_MSGH_BITS_REMOTE(header.msgh_bits) == MACH_MSG_TYPE_PORT_SEND_ONCE) {
        const auto trailer_offset = (header.msgh_size + 3U) & ~3U;
        const auto* trailer = reinterpret_cast<const mach_msg_audit_trailer_t*>(reinterpret_cast<const unsigned char*>(&request) + trailer_offset);
        const auto* message = reinterpret_cast<const wire::Request*>(&request);
        if (trailer_offset + sizeof(*trailer) <= sizeof(request) && trailer->msgh_trailer_type == MACH_MSG_TRAILER_FORMAT_0 &&
            trailer->msgh_trailer_size >= sizeof(*trailer) && message->protocol == wire::kProtocol && message->target_uid == owner) {
            if (!permitted(audit_token_to_euid(trailer->msgh_audit), owner, audio)) response.status = forbidden;
            else {
                ipc::Reader reader;
                const auto opened = reader.open(path, owner);
                if (!opened.ok()) response.status = not_ready;
                else if (!reader.export_readonly_memory_entry(entry, response.region_bytes).ok()) response.status = map_failed;
                else {
                    response.status = success;
                    response.header.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
                    response.body.msgh_descriptor_count = 1;
                    response.memory.name = entry;
                    response.memory.disposition = MACH_MSG_TYPE_COPY_SEND;
                    response.memory.type = MACH_MSG_PORT_DESCRIPTOR;
                }
            }
        }
    }
    // Malformed complex messages can carry rights/OOL memory. Destroy every
    // received resource; detach the reply right first so the reply owns it.
    if (reply_once) request.header.msgh_remote_port = MACH_PORT_NULL;
    mach_msg_destroy(&request.header);
    if (response.header.msgh_remote_port != MACH_PORT_NULL) {
        const auto sent = mach_msg(&response.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(response), 0,
                                   MACH_PORT_NULL, 100, MACH_PORT_NULL);
        if (sent != MACH_MSG_SUCCESS) mach_port_deallocate(mach_task_self(), response.header.msgh_remote_port);
    }
    if (entry != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), entry);
    return true;
}

#ifndef AR_BROKER_TESTING
int self_test() {
    char temporary[] = "/tmp/ar-broker-XXXXXX";
    const char* root = mkdtemp(temporary);
    if (!root) return 1;
    const std::string folder = std::string(root) + "/transport", path = folder + "/pcm-v1.bin";
    ipc::Writer writer;
    if (!writer.open(path, getuid()).ok()) return 1;
    float samples[480]; std::fill_n(samples, 480, .25F);
    if (!writer.publish(samples, samples, 480, 1000000000, 1000000000)) return 1;
    mach_port_t server = MACH_PORT_NULL, reply = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &server) != KERN_SUCCESS ||
        mach_port_insert_right(mach_task_self(), server, server, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS ||
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply) != KERN_SUCCESS) return 1;
    std::thread worker([&] { serve_once(server, getuid(), 202, path, 5000); });
    wire::Request request{};
    request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    request.header.msgh_remote_port = server;
    request.header.msgh_local_port = reply;
    request.header.msgh_size = sizeof(request);
    request.header.msgh_id = wire::kRequestID;
    request.protocol = wire::kProtocol; request.target_uid = getuid();
    const auto sent = mach_msg(&request.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(request), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    struct Response { wire::Reply message; mach_msg_max_trailer_t trailer; } response{};
    const auto received = sent == MACH_MSG_SUCCESS ? mach_msg(&response.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(response), reply, 5000, MACH_PORT_NULL) : sent;
    worker.join();
    int result = 1;
    if (received == MACH_MSG_SUCCESS && response.message.status == success && response.message.body.msgh_descriptor_count == 1) {
        ipc::Reader reader;
        float output[480]{};
        if (reader.open_memory_entry(response.message.memory.name, response.message.region_bytes).ok()) {
            const auto stats = reader.read(ipc::Route::discord, output, 480, 1000000000, 1010000000);
            mach_vm_address_t address = 0;
            const auto writable = mach_vm_map(mach_task_self(), &address, response.message.region_bytes, 0, VM_FLAGS_ANYWHERE,
                response.message.memory.name, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
            if (writable == KERN_SUCCESS) mach_vm_deallocate(mach_task_self(), address, response.message.region_bytes);
            if (stats.copied_frames == 480 && output[0] == .25F && writable != KERN_SUCCESS &&
                !permitted(getuid() + 10000, getuid(), 202)) {
                std::cout << "PASS audit-authenticated Mach request and readonly memory transfer\n"
                    "PASS driver-side PCM read through imported memory entry\n"
                    "PASS writable mapping rejected by kernel\n"
                    "PASS unrelated local UID rejected by authorization policy\n";
                result = 0;
            }
        }
        mach_port_deallocate(mach_task_self(), response.message.memory.name);
    } else std::cerr << "Broker self-test response failed: Mach " << received << ", status " << response.message.status << '\n';
    mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), server);
    mach_port_mod_refs(mach_task_self(), server, MACH_PORT_RIGHT_RECEIVE, -1);
    writer.close(); unlink(path.c_str()); rmdir(folder.c_str()); rmdir(root);
    return result;
}
#endif
}

#ifdef AR_BROKER_TESTING
extern "C" bool AudioRouterBrokerTestServeOnce(mach_port_t port, uid_t owner, uid_t audio,
                                               const char* path, mach_msg_timeout_t timeout) {
    return path && serve_once(port, owner, audio, path, timeout);
}
#else
int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--self-test") return self_test();
    if (argc != 3 || std::string(argv[1]) != "--target-uid") {
        std::cout << "Audio Router readonly PCM broker\n"
            "Default: help only. Production is started by its installed launch daemon.\n"
            "  audio_router_broker --target-uid UID\n"
            "  audio_router_broker --self-test (generated PCM only; no daemon install)\n";
        return argc == 1 || (argc == 2 && std::string(argv[1]) == "--help") ? 0 : 2;
    }
    std::uint32_t uid = 0;
    const std::string argument = argv[2];
    const auto parsed = std::from_chars(argument.data(), argument.data() + argument.size(), uid);
    if (parsed.ec != std::errc{} || parsed.ptr != argument.data() + argument.size() || uid == 0 || geteuid() != 0) {
        std::cerr << "The installed root broker requires a non-root target UID.\n"; return 2;
    }
    const auto* service_user = getpwnam("_coreaudiod");
    if (!service_user) { std::cerr << "Core Audio service identity is unavailable.\n"; return 1; }
    const auto audio_uid = service_user->pw_uid;
    const auto service = std::string(wire::kServicePrefix) + std::to_string(uid);
    mach_port_t port = MACH_PORT_NULL;
    const auto checked = bootstrap_check_in(bootstrap_port, service.c_str(), &port);
    if (checked != KERN_SUCCESS) { std::cerr << "Launch daemon Mach check-in failed: " << checked << '\n'; return 1; }
    std::signal(SIGINT, interrupt); std::signal(SIGTERM, interrupt);
    const auto path = ipc::default_path(uid);
    while (!interrupted) serve_once(port, uid, audio_uid, path, 500);
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    return 0;
}
#endif
