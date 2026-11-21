import Foundation
import CoreAudio

@main struct EndpointNameServiceTests {
    final class Fixture {
        let discoveryEntered = DispatchSemaphore(value: 0), releaseDiscovery = DispatchSemaphore(value: 0)
        let setterEntered = DispatchSemaphore(value: 0), releaseSetter = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var scans = 0, writes: [(UInt32, String)] = []
        var blockDiscovery = false, blockSetter = false, recycledID = false, duplicateUID = false
        func discover() -> [EndpointNameService.Endpoint] {
            lock.lock(); scans += 1; let hold = blockDiscovery && scans == 1; lock.unlock()
            if hold { discoveryEntered.signal(); releaseDiscovery.wait() }
            var values = [EndpointNameService.Endpoint(id: 10, uid: EndpointNameService.identities["discord"]!, name: "Previous apps"),
                          EndpointNameService.Endpoint(id: 11, uid: EndpointNameService.identities["alexa"]!, name: "Previous assistant"),
                          EndpointNameService.Endpoint(id: 12, uid: "ai.agentsofchange.router.unrelated.discord", name: "Unrelated")]
            if duplicateUID { values.append(.init(id: 13, uid: EndpointNameService.identities["discord"]!, name: "Duplicate")) }
            return values
        }
        func uid(_ id: AudioObjectID) -> String? {
            if recycledID && id == 10 { return "some.other.physical.device" }
            return id == 10 ? EndpointNameService.identities["discord"] : id == 11 ? EndpointNameService.identities["alexa"] : "unrelated"
        }
        func write(_ id: AudioObjectID, _ name: String) -> OSStatus {
            lock.lock(); writes.append((id, name)); let hold = blockSetter && writes.count == 1; lock.unlock()
            if hold { setterEntered.signal(); releaseSetter.wait() }
            return noErr
        }
        func values() -> (Int, [(UInt32, String)]) { lock.lock(); defer { lock.unlock() }; return (scans, writes) }
        func service() -> EndpointNameService { EndpointNameService(discover: discover, readUID: uid, write: write) }
    }
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    static func until(_ message: String, _ predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try require(predicate(), message)
    }
    static func names(_ prefix: String) -> [String: String] { ["discord": prefix + " apps", "alexa": prefix + " assistant"] }
    static func main() throws {
        let heldDiscovery = Fixture(); heldDiscovery.blockDiscovery = true
        let discoveryService = heldDiscovery.service()
        defer { heldDiscovery.releaseDiscovery.signal() }
        let unresolved = discoveryService.apply(names("Old"), timeout: 0.02)
        try require(unresolved.values.allSatisfy { $0 != noErr }, "Blocked discovery returns unconfirmed without waiting for HAL")
        try require(heldDiscovery.discoveryEntered.wait(timeout: .now() + 5) == .success, "Discovery fixture entered")
        _ = discoveryService.apply(names("Middle"), timeout: 0.02)
        _ = discoveryService.apply(names("Newest"), timeout: 0.02)
        try require(heldDiscovery.values().0 == 1 && heldDiscovery.values().1.isEmpty, "Blocked discovery creates no overlapping workers or writes")
        heldDiscovery.releaseDiscovery.signal()
        try until("Newest names applied after discovery resumes") { heldDiscovery.values().1.count == 2 }
        try require(heldDiscovery.values().0 == 2 && heldDiscovery.values().1.map { $0.1 } == ["Newest apps", "Newest assistant"],
                    "Only the newest coalesced request can write after blocked discovery")

        let heldSetter = Fixture(); heldSetter.blockSetter = true
        let setterService = heldSetter.service()
        defer { heldSetter.releaseSetter.signal() }
        let pendingWrite = setterService.apply(names("Old"), timeout: 0.02)
        try require(pendingWrite.values.allSatisfy { $0 != noErr }, "Blocked setter returns unconfirmed before its operation completes")
        try require(heldSetter.setterEntered.wait(timeout: .now() + 5) == .success, "Setter fixture entered")
        _ = setterService.apply(names("Middle"), timeout: 0.02)
        _ = setterService.apply(names("Newest"), timeout: 0.02)
        try require(heldSetter.values().0 == 1 && heldSetter.values().1.count == 1, "Blocked setter prevents overlapping discovery and setters")
        heldSetter.releaseSetter.signal()
        try until("Newest names applied after setter resumes") { heldSetter.values().1.count == 3 }
        try require(heldSetter.values().0 == 2 && heldSetter.values().1.map { $0.1 } == ["Old apps", "Newest apps", "Newest assistant"],
                    "An entered old setter finishes first; no remaining stale name can supersede the newest request")

        let recycled = Fixture(); recycled.recycledID = true
        let rejected = recycled.service().apply(names("Safe"))
        try require(rejected["discord"] != noErr && rejected["alexa"] == noErr && recycled.values().1.map { $0.0 } == [11],
                    "Recycled IDs and prefix-only device matches cannot be renamed")
        let duplicate = Fixture(); duplicate.duplicateUID = true
        let ambiguous = duplicate.service().apply(names("Safe"))
        try require(ambiguous["discord"] != noErr && duplicate.values().1.map { $0.0 } == [11], "Ambiguous owned identities cannot be renamed")
        let unchanged = Fixture()
        let confirmed = unchanged.service().apply(["discord": "Previous apps", "alexa": "Previous assistant"])
        try require(confirmed.count == 2 && confirmed.values.allSatisfy { $0 == noErr } && unchanged.values().1.isEmpty,
                    "Already matching verified names require no setter")
        print("PASS bounded endpoint discovery/setters, newest-request ordering and exact identity checks; no HAL writes")
    }
}
