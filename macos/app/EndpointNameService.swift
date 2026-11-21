import Foundation
import CoreAudio

// Cosmetic endpoint names must never hold the controller behind HAL discovery
// or a property setter. One worker owns all HAL calls, with one newest pending
// request; even an indefinitely blocked call cannot create replacement workers.
final class EndpointNameService {
    struct Endpoint {
        let id: AudioObjectID
        let uid: String
        let name: String
    }
    static let identities = ["discord": "ai.agentsofchange.router.device.discord.v1",
                             "alexa": "ai.agentsofchange.router.device.alexa.v1"]
    private final class Request {
        let generation: UInt64, names: [String: String]
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var result: [String: OSStatus]?
        init(generation: UInt64, names: [String: String]) { self.generation = generation; self.names = names }
        func finish(_ value: [String: OSStatus]) {
            lock.lock(); result = value; lock.unlock(); done.signal()
        }
        func wait(_ timeout: TimeInterval) -> [String: OSStatus] {
            guard done.wait(timeout: .now() + min(1, max(0, timeout))) == .success else { return EndpointNameService.unconfirmed }
            lock.lock(); defer { lock.unlock() }; return result ?? EndpointNameService.unconfirmed
        }
    }
    private static var unconfirmed: [String: OSStatus] {
        ["discord": kAudioHardwareNotReadyError, "alexa": kAudioHardwareNotReadyError]
    }
    private let queue = DispatchQueue(label: "audio-router.endpoint-names", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var workerActive = false
    private var pending: Request?
    private let discover: () -> [Endpoint]
    private let readUID: (AudioObjectID) -> String?
    private let write: (AudioObjectID, String) -> OSStatus
    init(discover: @escaping () -> [Endpoint] = EndpointNameService.discoverOwnedEndpoints,
         readUID: @escaping (AudioObjectID) -> String? = { AudioCatalog.string($0, kAudioDevicePropertyDeviceUID) },
         write: @escaping (AudioObjectID, String) -> OSStatus = EndpointNameService.writeName) {
        self.discover = discover; self.readUID = readUID; self.write = write
    }
    func apply(_ names: [String: String], timeout: TimeInterval = 1) -> [String: OSStatus] {
        guard Self.identities.keys.allSatisfy({ role in
            guard let name = names[role] else { return false }
            return !name.isEmpty && name.utf8.count <= 256
        }) else { return Self.unconfirmed }
        lock.lock()
        generation &+= 1
        let request = Request(generation: generation, names: names)
        pending?.finish(Self.unconfirmed)
        pending = request
        let launch = !workerActive
        workerActive = true
        lock.unlock()
        if launch { queue.async { self.drain() } }
        return request.wait(timeout)
    }
    private func current(_ request: Request) -> Bool {
        lock.lock(); defer { lock.unlock() }; return request.generation == generation
    }
    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else { workerActive = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            request.finish(perform(request))
        }
    }
    private func perform(_ request: Request) -> [String: OSStatus] {
        guard current(request) else { return Self.unconfirmed }
        let endpoints = discover()
        var result = Self.unconfirmed
        for role in ["discord", "alexa"] {
            guard current(request) else { return Self.unconfirmed }
            let uid = Self.identities[role]!
            let matches = endpoints.filter { $0.uid == uid }
            guard matches.count == 1, let endpoint = matches.first, endpoint.id != kAudioObjectUnknown,
                  let name = request.names[role], readUID(endpoint.id) == uid else { continue }
            // Object IDs can be recycled during a HAL restart. Verify the exact
            // owned UID again, and abandon requests superseded during discovery.
            guard current(request) else { return Self.unconfirmed }
            result[role] = endpoint.name == name ? noErr : write(endpoint.id, name)
        }
        // An already-entered setter cannot be cancelled. This serial worker
        // finishes it before applying the newest request, so old writes cannot
        // complete after newer names. Superseded callers never get confirmation.
        return current(request) ? result : Self.unconfirmed
    }
    private static func discoverOwnedEndpoints() -> [Endpoint] {
        let ids = AudioCatalog.objects(AudioObjectID(kAudioObjectSystemObject), AudioCatalog.address(kAudioHardwarePropertyDevices))
        return ids.compactMap { id in
            guard let uid = AudioCatalog.string(id, kAudioDevicePropertyDeviceUID), identities.values.contains(uid),
                  let name = AudioCatalog.string(id, kAudioObjectPropertyName) else { return nil }
            return Endpoint(id: id, uid: uid, name: name)
        }
    }
    private static func writeName(_ device: AudioObjectID, _ name: String) -> OSStatus {
        // This private driver property changes its display name only. It never
        // selects a default device or changes an application's audio input.
        var property = AudioCatalog.address(AudioObjectPropertySelector(0x61726e6d))
        var value: CFString = name as CFString
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<CFString>.size), $0)
        }
    }
}
