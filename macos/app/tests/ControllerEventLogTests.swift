import Foundation
import Darwin

@main struct ControllerEventLogTests {
    enum Failure: Error { case assertion(String), disk }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.assertion(message) } }
    static func until(_ message: String, _ predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try require(predicate(), message)
    }
    static func number(_ log: ControllerEventLog, _ key: String) -> UInt64 { (log.status()[key] as? NSNumber)?.uint64Value ?? 0 }
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/controller-events-" + UUID().uuidString)
        try privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = ControllerEventLog(directory: root, capacity: 4, sink: { _ in entered.signal(); release.wait() })
        held.record(.startRequested, reason: .userRequest)
        try require(entered.wait(timeout: .now() + 5) == .success, "Injected disk stall entered")
        // This loop and status access must finish while the only sink is held.
        for _ in 0..<100 { held.record(.systemSleep) }
        try require(number(held, "queued") == 5 && number(held, "dropped") == 96 && number(held, "errors") == 0 && held.status()["active"] as? Bool == false,
                    "Disk stalls leave a fixed queue, visible drops and responsive producers/status")
        for _ in 0..<5 { release.signal() }
        try until("Held queue drained") { number(held, "written") == 5 && number(held, "queued") == 0 }

        let failed = ControllerEventLog(directory: root, sink: { _ in throw Failure.disk })
        failed.record(.startFailed, reason: .operationFailed)
        try until("Disk failure visible") { number(failed, "errors") == 1 }
        for _ in 0..<10 { failed.record(.recoveryFailed) }
        try require(failed.status()["active"] as? Bool == false && number(failed, "dropped") == 11 && number(failed, "errors") == 1,
                    "Disk failure stops retries and reports all later loss without blocking")

        let privacyDir = root.appendingPathComponent("secret-microphone-serial-phrase-PID-12345")
        let privacy = ControllerEventLog(directory: privacyDir)
        for event in ControllerEventLog.Event.allCases { privacy.record(event, reason: .operationFailed, counters: [.attempt: 2, .retryLimit: 3]) }
        try until("Metadata fixture written") { number(privacy, "written") == UInt64(ControllerEventLog.Event.allCases.count) }
        let data = try Data(contentsOf: privacyDir.appendingPathComponent("controller-events.jsonl"))
        let text = String(decoding: data, as: UTF8.self)
        try require(!text.contains("secret-microphone-serial-phrase-PID-12345"), "Path and private source data never enter events")
        let allowed: Set<String> = ["schema", "component", "session", "utc", "monotonic_ns", "sequence", "event", "reason", "counters"]
        let events = Set(ControllerEventLog.Event.allCases.map(\.rawValue)), reasons = Set(ControllerEventLog.Reason.allCases.map(\.rawValue))
        var session = "", sequence: UInt64 = 0
        for line in text.split(separator: "\n") {
            let entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            try require(Set(entry.keys).isSubset(of: allowed) && entry["component"] as? String == "controller" && events.contains(entry["event"] as! String)
                        && reasons.contains(entry["reason"] as! String), "Only typed allowlisted metadata is serialized")
            let counters = entry["counters"] as! [String: Any]
            try require(Set(counters.keys) == ["attempt", "retry_limit"], "Counter keys are allowlisted")
            let current = entry["session"] as! String
            if session.isEmpty { session = current }
            let next = (entry["sequence"] as! NSNumber).uint64Value
            try require(UUID(uuidString: current) != nil && session == current && next > sequence && (entry["utc"] as! String).hasSuffix("Z")
                        && (entry["monotonic_ns"] as! NSNumber).uint64Value > 0, "Events have a UTC timestamp, monotonic time, session and ordered sequence")
            sequence = next
        }

        let rotationDir = root.appendingPathComponent("rotation")
        let rotating = ControllerEventLog(directory: rotationDir, maximumBytes: 512)
        for index in 1...20 {
            rotating.record(.recoveryAttempt, counters: [.attempt: UInt64(index)])
            try until("Rotation entry written") { number(rotating, "written") == UInt64(index) }
        }
        let files = try FileManager.default.contentsOfDirectory(at: rotationDir, includingPropertiesForKeys: nil)
        try require(files.count == 4 && files.allSatisfy { $0.lastPathComponent.hasPrefix("controller-events") }, "Retention is current plus three archives")
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try require((attributes[.size] as! NSNumber).intValue <= 512 && (attributes[.posixPermissions] as! NSNumber).intValue == 0o600,
                        "All retained event files have bounded size and private permissions")
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        }

        let victim = root.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.path)
        for kind in ["symlink", "hardlink", "archive", "public"] {
            let target = root.appendingPathComponent(kind); try privateDirectory(target)
            let path = target.appendingPathComponent(kind == "archive" ? "controller-events.3.jsonl" : "controller-events.jsonl")
            if kind == "hardlink" { try FileManager.default.linkItem(at: victim, to: path) }
            else if kind == "public" { try Data().write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
            else { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim) }
            let unsafe = ControllerEventLog(directory: target, maximumBytes: 512)
            for _ in 0..<8 { unsafe.record(.startRequested) }
            try until("Unsafe log path rejected") { number(unsafe, "errors") == 1 }
            try require(try String(contentsOf: victim, encoding: .utf8) == "unchanged", "Unsafe targets are never followed or modified")
        }
        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: privacyDir)
        let unsafeDirectory = ControllerEventLog(directory: linkedDirectory)
        unsafeDirectory.record(.systemWake)
        try until("Symlink directory rejected") { number(unsafeDirectory, "errors") == 1 }
        try require(try Data(contentsOf: privacyDir.appendingPathComponent("controller-events.jsonl")) == data, "Directory symlink does not redirect writes")
        print("PASS bounded asynchronous controller events, rotation, privacy, stalled disk and unsafe-path rejection; fixture metadata only")
    }
}
