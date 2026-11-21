import Foundation
import Darwin

// Only these metadata fields can enter the journal. Callers cannot pass an
// error string, microphone/app identity, phrase, transcript, or audio payload.
final class ControllerEventLog {
    enum Event: String, CaseIterable {
        case controllerStarted = "controller_started", controllerQuit = "controller_quit"
        case startRequested = "start_requested", startSucceeded = "start_succeeded", startFailed = "start_failed"
        case stopRequested = "stop_requested", stopSucceeded = "stop_succeeded", stopFailed = "stop_failed"
        case recoveryAttempt = "recovery_attempt", recoverySucceeded = "recovery_succeeded", recoveryFailed = "recovery_failed", recoveryPaused = "recovery_paused"
        case sourceDiscoveryDelayed = "source_discovery_delayed", sourceDiscoveryRestored = "source_discovery_restored", sourceDiscoveryFailed = "source_discovery_failed"
        case systemSleep = "system_sleep", systemWake = "system_wake"
        case attachmentAccepted = "attachment_accepted", attachmentRejected = "attachment_rejected", controllerDetached = "controller_detached"
        case rendererLost = "renderer_lost", rendererReloaded = "renderer_reloaded", rendererRecoveryPaused = "renderer_recovery_paused", rendererDetachFailed = "renderer_detach_failed"
    }
    enum Reason: String, CaseIterable {
        case userRequest = "user_request", automaticRecovery = "automatic_recovery", operationFailed = "operation_failed"
        case sourcesChanged = "sources_changed", sourceUnavailable = "source_unavailable", detectorFault = "detector_fault"
        case discoveryTimeout = "discovery_timeout", retryLimit = "retry_limit", unsupportedConfiguration = "unsupported_configuration", identityUnverified = "identity_unverified"
        case processTerminated = "process_terminated", navigationFailed = "navigation_failed", unconfirmedStandby = "unconfirmed_standby"
    }
    enum Counter: String, CaseIterable { case attempt, observations, retryLimit = "retry_limit" }
    private struct Entry {
        let event: Event, reason: Reason?, counters: [Counter: UInt64]
        let timestamp: Date, monotonic: UInt64, sequence: UInt64
    }
    private let queue = DispatchQueue(label: "audio-router.controller-events", qos: .utility)
    private let lock = NSLock()
    private let directory: URL, session = UUID().uuidString
    private let capacity: Int, maximumBytes: Int
    private let sink: ((Data) throws -> Void)?
    private var pending: [Entry] = []
    private var workerActive = false, inFlight = false, accepting = true
    private var nextSequence: UInt64 = 0, written: UInt64 = 0, dropped: UInt64 = 0, errors: UInt64 = 0
    // Worker-owned objects are never accessed while holding the producer lock.
    private var writer: ControllerEventFile?
    private let timestampFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value.timeZone = TimeZone(secondsFromGMT: 0); return value
    }()
    init(directory: URL, capacity: Int = 64, maximumBytes: Int = 1_048_576,
         sink: ((Data) throws -> Void)? = nil) {
        self.directory = directory; self.capacity = min(64, max(1, capacity))
        self.maximumBytes = min(1_048_576, max(512, maximumBytes)); self.sink = sink
    }
    func record(_ event: Event, reason: Reason? = nil, counters: [Counter: UInt64] = [:]) {
        let timestamp = Date(), monotonic = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        nextSequence &+= 1
        guard accepting, pending.count < capacity else { dropped &+= 1; lock.unlock(); return }
        pending.append(Entry(event: event, reason: reason, counters: counters, timestamp: timestamp, monotonic: monotonic, sequence: nextSequence))
        let launch = !workerActive; workerActive = true
        lock.unlock()
        if launch { queue.async { self.drain() } }
    }
    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["active": accepting && written > 0, "queued": pending.count + (inFlight ? 1 : 0), "written": written, "dropped": dropped, "errors": errors]
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { workerActive = false; lock.unlock(); return }
            let entry = pending.removeFirst(); inFlight = true; lock.unlock()
            do {
                var value: [String: Any] = ["schema": 1, "component": "controller", "session": session,
                    "utc": timestampFormatter.string(from: entry.timestamp), "monotonic_ns": entry.monotonic,
                    "sequence": entry.sequence, "event": entry.event.rawValue]
                if let reason = entry.reason { value["reason"] = reason.rawValue }
                if !entry.counters.isEmpty { value["counters"] = Dictionary(uniqueKeysWithValues: entry.counters.map { ($0.key.rawValue, $0.value) }) }
                var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
                if let sink { try sink(data) }
                else {
                    if writer == nil { writer = try ControllerEventFile(directory: directory, maximumBytes: maximumBytes) }
                    try writer!.append(data)
                }
                lock.lock(); written &+= 1; inFlight = false; lock.unlock()
            } catch {
                // Stop after a disk/security failure instead of an endless retry
                // loop. Loss is visible in diagnostics; routing never waits here.
                writer = nil
                lock.lock(); errors &+= 1; dropped &+= UInt64(pending.count) + 1
                pending.removeAll(keepingCapacity: false); accepting = false; workerActive = false; inFlight = false
                lock.unlock(); return
            }
        }
    }
}

private final class ControllerEventFile {
    private enum Failure: Error { case unsafePath, io, oversized }
    private let directoryFD: Int32, maximumBytes: Int
    private var fileFD: Int32 = -1
    private static let names = ["controller-events.jsonl", "controller-events.1.jsonl", "controller-events.2.jsonl", "controller-events.3.jsonl"]
    init(directory: URL, maximumBytes: Int) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              !directory.pathComponents.contains(".."), !directory.pathComponents.contains(".") else { throw Failure.unsafePath }
        // Resolve each directory component with O_NOFOLLOW, retaining descriptors
        // rather than resolving an untrusted symlink or using a relative path.
        let components = directory.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { throw Failure.unsafePath }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw Failure.io }
        do {
            for (index, component) in components.enumerated() {
                let last = index == components.count - 1
                if last, mkdirat(parent, component, 0o700) != 0, errno != EEXIST { throw Failure.io }
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                guard next >= 0 else { throw Failure.unsafePath }
                var attributes = stat()
                let safe = fstat(next, &attributes) == 0 && (attributes.st_uid == getuid() || (!last && attributes.st_uid == 0))
                    && (!last || attributes.st_mode & 0o777 == 0o700)
                guard safe else { close(next); throw Failure.unsafePath }
                close(parent); parent = next
            }
        } catch { close(parent); throw error }
        directoryFD = parent; self.maximumBytes = maximumBytes
    }
    deinit { if fileFD >= 0 { close(fileFD) }; close(directoryFD) }
    private func safeFile(_ attributes: stat) -> Bool {
        attributes.st_uid == getuid() && attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && attributes.st_mode & 0o777 == 0o600 && attributes.st_nlink == 1 && attributes.st_size >= 0 && attributes.st_size <= maximumBytes
    }
    private func checkedFile(_ name: String) throws -> stat? {
        var attributes = stat()
        if fstatat(directoryFD, name, &attributes, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw Failure.io
        }
        guard safeFile(attributes) else { throw Failure.unsafePath }; return attributes
    }
    private func openCurrent() throws {
        if fileFD >= 0 { return }
        _ = try checkedFile(Self.names[0])
        let opened = openat(directoryFD, Self.names[0], O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard opened >= 0 else { throw Failure.io }
        var attributes = stat()
        guard fstat(opened, &attributes) == 0, safeFile(attributes) else { close(opened); throw Failure.unsafePath }
        fileFD = opened
    }
    private func rotate() throws {
        // Check every fixed target before any rename/unlink. A symlink, hardlink,
        // foreign owner or nonprivate file stops logging without touching it.
        let existing = try Self.names.map { try checkedFile($0) != nil }
        if fileFD >= 0 { close(fileFD); fileFD = -1 }
        if existing[3], unlinkat(directoryFD, Self.names[3], 0) != 0 { throw Failure.io }
        for index in stride(from: 2, through: 0, by: -1) where existing[index] {
            if renameat(directoryFD, Self.names[index], directoryFD, Self.names[index + 1]) != 0 { throw Failure.io }
        }
        try openCurrent()
    }
    func append(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw Failure.oversized }
        try openCurrent()
        var attributes = stat()
        guard fstat(fileFD, &attributes) == 0, safeFile(attributes) else { throw Failure.unsafePath }
        if attributes.st_size > maximumBytes - data.count { try rotate() }
        try data.withUnsafeBytes { bytes in
            var offset = 0, interruptions = 0
            while offset < bytes.count {
                let count = Darwin.write(fileFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR, interruptions < 8 { interruptions += 1; continue }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
    }
}
