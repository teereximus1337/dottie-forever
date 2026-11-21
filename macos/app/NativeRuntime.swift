import Foundation
import Darwin

enum RuntimeFailure: LocalizedError {
    case message(String)
    case connectionUnavailable(Int32)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .connectionUnavailable: return "The audio engine is stopped or unavailable."
        }
    }
}

// Deadline renewal must not share a queue with blocking HAL enumeration,
// configuration, or recovery. Permission is revoked under a short state lock;
// fence() drains the one in-flight exchange before a fail-closed command.
private final class ControllerLease {
    private let queue = DispatchQueue(label: "audio-router.lease", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var maintained = false, eligible = false, suspended = false
    private var activity: NSObjectProtocol?
    private let renew: () -> Void
    init(renew: @escaping () -> Void) {
        self.renew = renew
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let allowed = self.maintained && self.eligible && !self.suspended
            self.lock.unlock()
            if allowed { self.renew() }
        }
        self.timer = timer; timer.resume()
    }
    private func updateActivity() {
        let needed = maintained && eligible && !suspended
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Maintain user-selected audio routing while its window is in the background")
        } else if !needed, let token = activity {
            ProcessInfo.processInfo.endActivity(token); activity = nil
        }
    }
    func maintain(_ value: Bool) { lock.lock(); maintained = value; updateActivity(); lock.unlock() }
    func permit(_ value: Bool) { lock.lock(); eligible = value; updateActivity(); lock.unlock() }
    func suspend(_ value: Bool) { lock.lock(); suspended = value; updateActivity(); lock.unlock() }
    func fence() { queue.sync {} }
    deinit {
        timer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}

// A stuck HAL property call gets one worker, never the control queue or an
// accumulating set of replacement workers. Only complete, recent scans may
// contribute an identity observation to recovery.
final class RecoveryCatalog {
    struct Snapshot {
        let catalog: [String: Any]?
        let sequence: UInt64
        let expired: Bool
        let inFlight: Bool
    }
    private let queue = DispatchQueue(label: "audio-router.recovery-catalog", qos: .utility)
    private let lock = NSLock()
    private let fetch: () -> [String: Any]
    private let clock: () -> TimeInterval
    private let interval: TimeInterval = 2
    private let maximumAge: TimeInterval = 6
    private var epoch: UInt64 = 0, sequence: UInt64 = 0
    private var inFlight = false
    private var nextRequest: TimeInterval = -.infinity
    private var requestedAt: TimeInterval?
    private var completedAt: TimeInterval?
    private var catalog: [String: Any]?
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         fetch: @escaping () -> [String: Any] = { AudioCatalog.snapshot(includeInstalled: false) }) {
        self.clock = clock; self.fetch = fetch
    }
    func invalidate() {
        let invalidatedAt = clock()
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1; catalog = nil; completedAt = nil
        // A previous generation's HAL call cannot be cancelled. Its occupied
        // worker must still age out in this generation, not wait forever with
        // no freshness reference after stop/sleep/start invalidation.
        requestedAt = inFlight ? invalidatedAt : nil
        nextRequest = -.infinity
    }
    func refreshIfNeeded(now: TimeInterval) {
        lock.lock()
        guard !inFlight, now >= nextRequest else { lock.unlock(); return }
        inFlight = true; requestedAt = now; nextRequest = now + interval
        let requestEpoch = epoch
        lock.unlock()
        queue.async {
            let value = self.fetch(), completed = self.clock()
            self.lock.lock(); defer { self.lock.unlock() }
            self.inFlight = false
            guard requestEpoch == self.epoch else { return }
            // A scan blocked for too long may combine old and new device
            // observations. Do not turn its late result into a fresh identity.
            guard completed >= now, completed - now < self.maximumAge else { return }
            self.catalog = value; self.completedAt = completed; self.sequence &+= 1
        }
    }
    func snapshot(now: TimeInterval) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let reference = completedAt ?? requestedAt
        // The worker can complete after the controller sampled `now`, before
        // this lock is acquired. Both timestamps use the same monotonic clock;
        // sample again under the lock so fresh completion cannot look expired,
        // while an old caller timestamp cannot hide a genuinely stale scan.
        let observed = max(now, clock())
        let expired = reference.map { max(0, observed - $0) >= maximumAge } ?? false
        return Snapshot(catalog: expired ? nil : catalog, sequence: sequence, expired: expired, inFlight: inFlight)
    }
    func freshSnapshot(timeout: TimeInterval = 3) throws -> [String: Any] {
        invalidate()
        let deadline = ProcessInfo.processInfo.systemUptime + min(3, max(0, timeout))
        repeat {
            let now = clock()
            refreshIfNeeded(now: now)
            if let value = snapshot(now: now).catalog { return value }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw RuntimeFailure.message("Audio source discovery did not finish in time. No new source was captured. Wait for devices to settle and retry, or reopen the controller.")
    }
}

enum RecoveryStopWait {
    // The control socket can disappear before Process observes child exit.
    // Wait for both boundaries inside one attempt rather than spending a retry
    // on ordinary teardown. Injected observations keep timing fixtures local.
    static func untilStopped(timeout: TimeInterval = 3,
                             clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                             childRunning: () -> Bool,
                             controlAbsent: () -> Bool) -> Bool {
        let deadline = clock() + min(3, max(0, timeout))
        while true {
            if !childRunning() && controlAbsent() { return true }
            let remaining = deadline - clock()
            guard remaining > 0 else { return false }
            pause(min(0.05, remaining))
        }
    }
}

final class NativeRuntime {
    let queue = DispatchQueue(label: "audio-router.controller")
    let directory: URL
    let configURL: URL
    let resourcesOverride: URL?
    let events: ControllerEventLog
    var child: Process?
    // This timer performs recovery observations only; lease I/O is independent.
    var heartbeatTimer: DispatchSourceTimer?
    private var controllerLease: ControllerLease!
    private(set) var leaseSessionActive = false
    private let recoveryCatalog: RecoveryCatalog
    private var recoveryCatalogSequence: UInt64 = 0
    private var catalogStalled = false
    private var recoveryPauseLogged = false
    var recovery = RecoveryPolicy()
    var liveIntent = false
    var initialAttachChecked = false
    var recoveryChecked: TimeInterval = 0
    var recoveryMessage = ""
    var lastSelections: [String: Any] = [:]
    var activeGraph: [String: Any] = [:]
    var graphRevision = ""
    var activeInput: [String: String] = [:]
    var awaitingAttachStop = false
    private let telemetryQueue = DispatchQueue(label: "audio-router.telemetry", qos: .utility)
    private var telemetryTimer: DispatchSourceTimer?
    private let cacheLock = NSLock()
    private var cachedStatus: [String: Any]?
    private var cachedAt: TimeInterval = 0
    private var cacheGeneration: UInt64 = 0
    private var cachedMetadata: [String: Any] = [:]
    private var cachedFailure = "The audio engine is stopped."
    func publishMetadata() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedMetadata = ["recovery_message": recoveryMessage, "active_graph": activeGraph, "active_graph_revision": graphRevision, "resolved_input": activeInput]
    }
    func cachedSnapshot() throws -> [String: Any] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard var result = cachedStatus, ProcessInfo.processInfo.systemUptime - cachedAt < 1 else {
            throw RuntimeFailure.message((cachedMetadata["recovery_message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cachedFailure)
        }
        var metadata = cachedMetadata
        if result["graph_revision"] as? String != metadata["active_graph_revision"] as? String {
            // A cached response from the previous process must not depict the
            // newly committed graph or replace the host's actual revision.
            metadata.removeValue(forKey: "active_graph")
            metadata.removeValue(forKey: "resolved_input")
        }
        result.merge(metadata) { _, metadata in metadata }
        var diagnostics = result["diagnostics"] as? [String: Any] ?? [:]
        diagnostics["controller"] = events.status(); result["diagnostics"] = diagnostics
        return result
    }
    func eventDiagnostics() -> [String: Any] {
        cacheLock.lock()
        var diagnostics = ProcessInfo.processInfo.systemUptime - cachedAt < 1 ? cachedStatus?["diagnostics"] as? [String: Any] ?? [:] : [:]
        cacheLock.unlock()
        diagnostics["controller"] = events.status()
        return diagnostics
    }
    func telemetryGeneration() -> UInt64 {
        cacheLock.lock(); defer { cacheLock.unlock() }; return cacheGeneration
    }
    func clearCachedStatus() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cacheGeneration &+= 1; cachedStatus = nil; cachedAt = 0
        cachedFailure = "The audio engine is stopped."
    }
    func cacheConfirmedStatus(_ value: [String: Any]) {
        guard value["ok"] as? Bool == true, value["mode"] is String, value["graph_revision"] is String, value["frames"] is NSNumber else { return }
        cacheLock.lock(); defer { cacheLock.unlock() }
        cacheGeneration &+= 1
        cachedStatus = value; cachedAt = ProcessInfo.processInfo.systemUptime
    }
    func cacheTelemetry(_ value: [String: Any], generation: UInt64) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard generation == cacheGeneration else { return }
        if let previous = cachedStatus, previous["graph_revision"] as? String == value["graph_revision"] as? String,
           let before = previous["frames"] as? NSNumber, let after = value["frames"] as? NSNumber, after.uint64Value < before.uint64Value { return }
        cachedStatus = value; cachedAt = ProcessInfo.processInfo.systemUptime
    }
    func maintainTelemetry() {
        guard telemetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: telemetryQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let generation = self.telemetryGeneration()
            do {
                let value = try self.exchange(["op": "status"])
                self.cacheTelemetry(value, generation: generation)
            } catch {
                self.cacheLock.lock()
                if generation == self.cacheGeneration { self.cachedStatus = nil; self.cachedFailure = error.localizedDescription }
                self.cacheLock.unlock()
            }
        }
        telemetryTimer = timer; timer.resume()
    }
    func graph(from selections: [String: Any]) -> [String: Any] {
        selections["graph"] as? [String: Any] ?? GraphConfiguration.legacy(selections)
    }
    func saveGraph(_ proposed: [String: Any]) throws -> [String: Any] {
        let validated = try GraphConfiguration.validate(proposed, complete: false)
        var current = settings(); current["graph"] = validated; try save(current)
        return ["ok": true, "graph": validated, "settings": current]
    }
    func applyGraph(_ proposed: [String: Any]) throws -> [String: Any] {
        let validated = try ProductProfile.validate(proposed)
        // Resolve before disturbing the last working route.
        _ = try GraphConfiguration.resolve(validated, catalog: freshCatalog(), revision: "validate")
        let previous = activeGraph
        let wasRunning = (try? exchange(["op": "status"])) != nil
        if wasRunning {
            _ = try stopByUser()
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while ProcessInfo.processInfo.systemUptime < deadline {
                if child?.isRunning != true && (try? exchange(["op": "status"])) == nil { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        do { return try start(mode: "live", selections: ["graph": validated]) }
        catch {
            let problem = error.localizedDescription
            if wasRunning, !previous.isEmpty, child?.isRunning != true {
                do {
                    _ = try start(mode: "live", selections: ["graph": previous])
                } catch {
                    throw RuntimeFailure.message("New connections failed: " + problem + " Previous routing could not restart: " + error.localizedDescription)
                }
                throw RuntimeFailure.message("New connections could not start: " + problem + " The previous routing was restored on standby.")
            }
            throw RuntimeFailure.message("Could not apply the new connections: " + problem + " The previous configuration remains saved; routing may be stopped.")
        }
    }

    private func updateControllerLease() {
        controllerLease.permit(leaseSessionActive && !awaitingAttachStop && !catalogStalled && !recovery.suspended && ProcessInfo.processInfo.systemUptime >= recovery.resumeAfter)
    }
    private func pauseControllerLease() {
        controllerLease.permit(false)
        controllerLease.fence()
    }
    // Called immediately by the AppKit sleep notification, before queued HAL
    // work can delay handling it. No socket or HAL work runs on the UI thread.
    func suspendControllerLease() { controllerLease.suspend(true) }
    func willSleep() {
        events.record(.systemSleep)
        recovery.willSleep()
        recoveryCatalog.invalidate()
        pauseControllerLease()
        _ = try? exchange(["op": "standby"])
    }
    func didWake() {
        events.record(.systemWake)
        guard liveIntent else { controllerLease.suspend(false); return }
        recovery.didWake(now: ProcessInfo.processInfo.systemUptime)
        recoveryCatalog.invalidate()
        pauseControllerLease()
        _ = try? exchange(["op": "standby"])
        controllerLease.suspend(false)
        recoveryMessage = "Mac resumed. Checking selected sources; the assistant remains on standby."
    }
    func stopByUser() throws -> [String: Any] {
        events.record(.stopRequested, reason: .userRequest)
        var stopped = false
        defer { events.record(stopped ? .stopSucceeded : .stopFailed, reason: stopped ? nil : .operationFailed) }
        liveIntent = false; leaseSessionActive = false
        recoveryPauseLogged = false
        recoveryCatalog.invalidate(); catalogStalled = false
        pauseControllerLease()
        initialAttachChecked = true; recovery.reset(); recoveryMessage = ""
        let result = try exchange(["op": "shutdown"])
        if result["ok"] as? Bool == true { stopped = true; clearCachedStatus() }
        return result
    }
    private func freshCatalog() throws -> [String: Any] {
        do { return try recoveryCatalog.freshSnapshot() }
        catch { events.record(.sourceDiscoveryFailed, reason: .discoveryTimeout); throw error }
    }
    func identity(_ selections: [String: Any], catalog: [String: Any]) -> String? {
        try? GraphConfiguration.resolve(graph(from: selections), catalog: catalog, revision: "identity").identity
    }
    static func defaultInputRequiresStop(_ graph: [String: Any], catalog: [String: Any], captured: [String: String]) -> Bool {
        guard (graph["mic"] as? [String: Any])?["mode"] as? String == "default" else { return false }
        let uid = (catalog["defaults"] as? [String: Any])?["input_uid"] as? String ?? ""
        let matches = (catalog["inputs"] as? [[String: Any]] ?? []).filter { $0["uid"] as? String == uid }
        return uid.isEmpty || matches.count != 1 || uid != captured["uid"]
    }
    static func sourcesHealthyForRecovery(_ status: [String: Any]?) -> Bool {
        let health = status?["health"] as? [String: Bool] ?? [:]
        guard ["mic", "discord", "dot"].allSatisfy({ health[$0] == true }) else { return false }
        let detector = status?["detector"] as? [String: Any] ?? [:]
        // Terminal worker failures do not necessarily affect capture health.
        // Startup/phrase validation without an error is allowed to settle under
        // the host's existing bounded worker timeout, not a premature restart.
        return detector["enabled"] as? Bool != true || (detector["error"] as? String ?? "").isEmpty
    }
    func checkRecovery(_ status: [String: Any]?) {
        defer { updateControllerLease(); publishMetadata() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - recoveryChecked >= 2 else { return }
        recoveryChecked = now
        if awaitingAttachStop, status != nil {
            pauseControllerLease()
            // Never renew an unverified old session while waiting for its
            // shutdown. An interrupted shutdown reply must not resume capture.
            _ = try? exchange(["op": "standby"])
            _ = try? exchange(["op": "shutdown"])
            return
        }
        if !initialAttachChecked, status?["mode"] as? String == "live", !liveIntent {
            let saved = settings()
            let previousGraph = saved["last_active_graph"] as? [String: Any] ?? graph(from: saved)
            do { activeGraph = try ProductProfile.validate(previousGraph) }
            catch {
                events.record(.attachmentRejected, reason: .unsupportedConfiguration)
                // An old general-purpose session must not bring game audio or
                // another app back through recovery after the product pivot.
                awaitingAttachStop = true
                leaseSessionActive = false; pauseControllerLease()
                _ = try? exchange(["op": "standby"])
                _ = try? exchange(["op": "shutdown"])
                initialAttachChecked = true; liveIntent = false; recovery.reset()
                activeGraph = [:]; activeInput = [:]
                recoveryMessage = "Previous routing used unsupported sources. Start the ChatGPT and optional Discord setup to continue."
                return
            }
            liveIntent = true
            graphRevision = saved["graph_revision"] as? String ?? "unverified-attachment"
            lastSelections = ["graph": activeGraph]
            initialAttachChecked = true
            let input = saved["resolved_input"] as? [String: String] ?? [:]
            let uid = input["uid"] ?? ""
            let assistantID = (activeGraph["assistant"] as? [String: String])?["bundle_id"] ?? ""
            let launchIdentity = saved["launch_identity"] as? String ?? ""
            let hostRevision = status?["graph_revision"] as? String ?? ""
            if !hostRevision.isEmpty, hostRevision == graphRevision, !uid.isEmpty,
               launchIdentity.hasPrefix(uid + "|" + assistantID + ":") {
                // The saved record belongs to this exact running graph. In
                // default-input mode, keep its original UID until recovery
                // observes whether the system default has since changed.
                activeInput = input
                recovery.recovered(identity: launchIdentity)
                pauseControllerLease()
                let closed = try? exchange(["op": "standby"])
                if closed?["ok"] as? Bool == true, closed?["graph_revision"] as? String == hostRevision, closed?["gate"] as? String == "closed" {
                    leaseSessionActive = true
                    events.record(.attachmentAccepted)
                } else {
                    events.record(.attachmentRejected, reason: .unconfirmedStandby)
                    leaseSessionActive = false; awaitingAttachStop = true
                    recovery.expected = "reattach-requires-reconnect"
                    recoveryMessage = "The previous session could not confirm standby. Reconnecting before allowing wake."
                }
            } else {
                events.record(.attachmentRejected, reason: .identityUnverified)
                activeInput = [:]
                recovery.expected = "reattach-requires-reconnect"
                awaitingAttachStop = true
                leaseSessionActive = false; pauseControllerLease()
                recoveryMessage = "Reconnecting the previous session on standby to verify its microphone and app sources."
                _ = try? exchange(["op": "standby"])
                _ = try? exchange(["op": "shutdown"])
            }
            // Do not infer an old host's captured identities from the current
            // catalog. Subsequent observations use the usual bounded recovery.
            return
        }
        if status != nil || liveIntent { initialAttachChecked = true }
        if status == nil && child?.isRunning != true { leaseSessionActive = false }
        else if liveIntent || leaseSessionActive, !awaitingAttachStop, status?["graph_revision"] as? String == graphRevision { leaseSessionActive = true }
        guard liveIntent else { return }
        guard !recovery.suspended, now >= recovery.resumeAfter else {
            recoveryMessage = "Waiting for audio devices to settle after sleep. The assistant remains on standby."
            if status?["gate"] as? String == "open" { _ = try? exchange(["op": "standby"]) }
            return
        }
        recoveryCatalog.refreshIfNeeded(now: now)
        let observation = recoveryCatalog.snapshot(now: now)
        guard let catalog = observation.catalog else {
            _ = recovery.evaluate(identity: nil, healthy: false, now: now)
            if observation.expired {
                if !catalogStalled {
                    events.record(.sourceDiscoveryDelayed, reason: .discoveryTimeout)
                    catalogStalled = true; pauseControllerLease()
                    _ = try? exchange(["op": "standby"])
                    if (graph(from: lastSelections)["mic"] as? [String: Any])?["mode"] as? String == "default" {
                        leaseSessionActive = false
                        _ = try? exchange(["op": "shutdown"])
                    }
                }
                recoveryMessage = "Source checks are delayed. The assistant is on standby; waiting for a fresh device check."
            } else { recoveryMessage = "Checking the selected audio sources." }
            return
        }
        if catalogStalled { events.record(.sourceDiscoveryRestored) }
        catalogStalled = false
        // Re-reading one cached result is not three independent observations
        // of a stable helper/device identity.
        guard observation.sequence != recoveryCatalogSequence else { return }
        recoveryCatalogSequence = observation.sequence
        let current = identity(lastSelections, catalog: catalog)
        guard let current else {
            recoveryMessage = "A connected source is unavailable. Reconnect it or edit the source; no substitute is captured."
            if Self.defaultInputRequiresStop(graph(from: lastSelections), catalog: catalog, captured: activeInput) {
                recoveryMessage = "Waiting for an available, verified physical system-default microphone. Routing is stopped."
                leaseSessionActive = false; pauseControllerLease()
                if status != nil { _ = try? exchange(["op": "shutdown"]) }
            } else if status?["gate"] as? String == "open" { _ = try? exchange(["op": "standby"]) }
            _ = recovery.evaluate(identity: nil, healthy: false, now: now)
            return
        }
        // A transient extra app helper is a candidate identity, not proof the
        // healthy captured process disappeared. Let the existing three-sample
        // policy settle it. A changed physical default is different: close its
        // feed immediately, even while the new identity settles.
        if Self.defaultInputRequiresStop(graph(from: lastSelections), catalog: catalog, captured: activeInput) {
            leaseSessionActive = false; pauseControllerLease()
            if status != nil { _ = try? exchange(["op": "shutdown"]) }
        }
        let healthy = Self.sourcesHealthyForRecovery(status)
        guard recovery.evaluate(identity: current, healthy: healthy, now: now) else {
            if recovery.attempts >= 3 && (!healthy || recovery.expected != current) {
                if !recoveryPauseLogged {
                    events.record(.recoveryPaused, reason: .retryLimit, counters: [.attempt: UInt64(recovery.attempts), .retryLimit: 3])
                    recoveryPauseLogged = true
                }
                recoveryMessage = "Recovery paused after three attempts. Use Start routing to retry, or edit the unavailable source."
            }
            else if healthy && recovery.expected == current { recoveryMessage = "" }
            if recovery.attempts == 0 { recoveryPauseLogged = false }
            return
        }
        let reason: ControllerEventLog.Reason = current != recovery.expected ? .sourcesChanged
            : ((status?["detector"] as? [String: Any])?["error"] as? String ?? "").isEmpty ? .sourceUnavailable : .detectorFault
        events.record(.recoveryAttempt, reason: reason, counters: [.attempt: UInt64(recovery.attempts)])
        recoveryMessage = "Reconnecting selected sources. The assistant will remain on standby; use a fresh wake phrase afterward."
        do {
            leaseSessionActive = false; pauseControllerLease()
            if status != nil { _ = try exchange(["op": "shutdown"]) }
            guard RecoveryStopWait.untilStopped(childRunning: { self.child?.isRunning == true },
                                                controlAbsent: { self.confirmedStoppedControl() }) else {
                throw RuntimeFailure.message("Previous engine is still stopping.")
            }
            _ = try start(mode: "live", selections: lastSelections, recovering: true)
            events.record(.recoverySucceeded, counters: [.attempt: UInt64(recovery.attempts)])
            recoveryMessage = "Sources reconnected. The assistant is on standby. If a client still hears audio, reselect its virtual input."
        } catch {
            events.record(.recoveryFailed, reason: .operationFailed, counters: [.attempt: UInt64(recovery.attempts)])
            recoveryMessage = "Recovery failed: " + error.localizedDescription
        }
    }
    func statusWithRecovery() throws -> [String: Any] {
        var status: [String: Any]
        do { status = try exchange(["op": "status"]) }
        catch { throw RuntimeFailure.message(recoveryMessage.isEmpty ? error.localizedDescription : recoveryMessage) }
        status["recovery_message"] = recoveryMessage
        var diagnostics = status["diagnostics"] as? [String: Any] ?? [:]
        diagnostics["controller"] = events.status(); status["diagnostics"] = diagnostics
        return status
    }
    init(directory runtimeDirectory: URL? = nil, resources: URL? = nil, recoveryCatalog: RecoveryCatalog = RecoveryCatalog(), events: ControllerEventLog? = nil) {
        directory = runtimeDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".audio-router")
        self.events = events ?? ControllerEventLog(directory: directory)
        resourcesOverride = resources
        configURL = directory.appendingPathComponent("settings.json")
        self.recoveryCatalog = recoveryCatalog
        controllerLease = ControllerLease { [weak self] in _ = try? self?.exchange(["op": "heartbeat"]) }
        self.events.record(.controllerStarted)
    }
    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw RuntimeFailure.message("The private runtime directory has an unexpected owner or type.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    func maintainControllerLease() {
        controllerLease.maintain(true)
        queue.async {
            self.maintainTelemetry()
            self.updateControllerLease()
            guard self.heartbeatTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let result = try? self.exchange(["op": "status"])
                if let result { try? self.persistConfirmedConfig(result) }
                self.checkRecovery(result)
            }
            self.heartbeatTimer = timer; timer.resume()
        }
    }
    func confirmedDetachedStandby(_ response: [String: Any]?) -> Bool {
        guard response?["ok"] as? Bool == true, response?["gate"] as? String == "closed",
              let revision = response?["graph_revision"] as? String, !revision.isEmpty else { return false }
        if revision == graphRevision { return true }
        // A renderer can fail before its first didFinish/attachment check. A
        // verified same-user host closed its gate; the renderer may reload so
        // normal attachment can validate saved identities. Do not adopt this
        // revision or promote its lease here.
        return graphRevision.isEmpty && !initialAttachChecked && !liveIntent && !leaseSessionActive
    }
    func confirmedDetachedAbsence(after error: Error?) -> Bool {
        guard child?.isRunning != true, let failure = error as? RuntimeFailure,
              case .connectionUnavailable(let code) = failure else { return false }
        let path = directory.appendingPathComponent("control.sock").path
        var attributes = stat()
        let found = lstat(path, &attributes) == 0
        if code == ENOENT { return !found && errno == ENOENT }
        // A crashed host can leave its socket inode behind. Connection refusal
        // on an owned socket is absence, not an unverified live peer. Never
        // delete it here or treat timeouts/response failures as safe detach.
        return code == ECONNREFUSED && found && attributes.st_uid == getuid()
            && attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }
    func confirmedStoppedControl() -> Bool {
        guard child?.isRunning != true else { return false }
        let path = directory.appendingPathComponent("control.sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let encoded = Array(path.utf8) + [0]
        guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: encoded) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0 else { return false }
        // This probe sends no command and never waits for a reply. Pending
        // connections, full backlogs, timeouts and unverified failures remain
        // unknown, never evidence that an old host may safely be replaced.
        return confirmedDetachedAbsence(after: RuntimeFailure.connectionUnavailable(errno))
    }
    func releaseControllerLease(completion: ((Bool) -> Void)? = nil) {
        controllerLease.maintain(false)
        queue.async {
            self.heartbeatTimer?.cancel(); self.heartbeatTimer = nil
            self.controllerLease.fence()
            var response: [String: Any]?, exchangeError: Error?
            do { response = try self.exchange(["op": "standby"]) } catch { exchangeError = error }
            let closed = self.confirmedDetachedStandby(response)
            let absent = self.confirmedDetachedAbsence(after: exchangeError)
            if closed, let response { self.cacheConfirmedStatus(response) }
            if absent { self.leaseSessionActive = false; self.clearCachedStatus() }
            if closed || absent { self.events.record(.controllerDetached) }
            if let completion { DispatchQueue.main.async { completion(closed || absent) } }
        }
    }
    func settings() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL), data.count <= 65536,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["names": ["discord": "Router · Apps", "alexa": "Router · Assistant"],
                    "phrases": ["wake": "Hey Alexa", "standby": "Alexa standby"],
                    "mic_uid": "", "discord_bundle": "", "dot_bundle": "", "voice_detection": true]
        }
        var migrated = value
        if migrated["graph"] == nil { migrated["graph"] = GraphConfiguration.legacy(value) }
        return migrated
    }
    func save(_ value: [String: Any]) throws {
        try prepareDirectory()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 65536 else { throw RuntimeFailure.message("Settings are too large.") }
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
    func persistConfirmedConfig(_ response: [String: Any]) throws {
        guard response["ok"] as? Bool == true, response["config_pending"] as? Bool != true,
              let names = response["names"] as? [String: String], let phrases = response["phrases"] as? [String: String] else { return }
        var current = settings()
        if current["names"] as? [String: String] != names || current["phrases"] as? [String: String] != phrases {
            current["names"] = names; current["phrases"] = phrases
            try save(current)
        }
    }
    // A stopped host may store desired phrases, but must never report them as
    // active. No host startup or route mutation is needed to save that draft.
    func saveVoiceSettings(names: [String: String], phrases: [String: String]) throws -> [String: Any] {
        for key in ["wake", "standby"] {
            guard let phrase = phrases[key], phrase.utf8.count <= 64,
                  phrase.range(of: "^[A-Za-z](?:[A-Za-z' ]*[A-Za-z])?$", options: .regularExpression) != nil else {
                throw RuntimeFailure.message("Use English letters, spaces and apostrophes in your phrases. Previous settings kept.")
            }
        }
        guard phrases["wake"]?.split(separator: " ").joined(separator: " ").lowercased() !=
                phrases["standby"]?.split(separator: " ").joined(separator: " ").lowercased() else {
            throw RuntimeFailure.message("Choose two different phrases. Previous settings kept.")
        }
        guard let discord = names["discord"], let assistant = names["alexa"],
              !discord.isEmpty, !assistant.isEmpty, discord.utf8.count <= 48, assistant.utf8.count <= 48,
              discord != assistant else {
            throw RuntimeFailure.message("Use two different input names of 1–48 bytes. Previous settings kept.")
        }
        if !liveIntent && !leaseSessionActive && confirmedStoppedControl() {
            var current = settings()
            current["names"] = names
            current["phrases"] = phrases
            try save(current)
            return ["ok": true, "names": names, "phrases": phrases, "phrase_activation": "saved_routing_off"]
        }
        var result = try configure(names: names, phrases: phrases)
        guard result["ok"] as? Bool == true else { return result }
        if (result["detector"] as? [String: Any])?["enabled"] as? Bool == false {
            result["phrase_activation"] = "saved_detection_off"
            return result
        }
        if result["mode"] as? String != "live" {
            result["phrase_activation"] = "saved_test_mode"
            return result
        }
        // Ready means the worker loaded the phrases. Healthy also proves
        // that the current worker has actually processed listener audio.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline,
              result["phrases"] as? [String: String] == phrases,
              (result["detector"] as? [String: Any])?["healthy"] as? Bool != true {
            Thread.sleep(forTimeInterval: 0.1)
            guard let next = try? exchange(["op": "status"]), next["ok"] as? Bool == true,
                  next["graph_revision"] as? String == result["graph_revision"] as? String,
                  next["phrases"] as? [String: String] == phrases else { break }
            result = next
        }
        if let detector = result["detector"] as? [String: Any], detector["ready"] as? Bool == true,
           detector["healthy"] as? Bool == true, result["phrases"] as? [String: String] == phrases {
            result["phrase_activation"] = "active"
        } else {
            result["phrase_activation"] = "saved_listener_not_ready"
        }
        return result
    }
    func configure(names: [String: String], phrases: [String: String]) throws -> [String: Any] {
        var result = try exchange(["op": "config", "names": names, "phrases": phrases])
        let deadline = Date().addingTimeInterval(10)
        while result["ok"] as? Bool == true && result["config_pending"] as? Bool == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            // The independent lease owns renewal. A configuration poll must
            // not bypass immediate sleep or controller-release revocation.
            result = try exchange(["op": "status"])
        }
        if result["config_pending"] as? Bool == true { throw RuntimeFailure.message("The detector settings are still being validated. Refresh status before trying again; the change was not replayed.") }
        if let error = result["config_error"] as? String, !error.isEmpty { throw RuntimeFailure.message("Phrases weren’t applied. Previous phrases kept; assistant is on standby. " + error) }
        try persistConfirmedConfig(result)
        return result
    }
    func exchange(_ command: [String: Any]) throws -> [String: Any] {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = directory.appendingPathComponent("control.sock").path
        let encoded = Array(path.utf8) + [0]
        guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RuntimeFailure.message("The runtime socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: encoded) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeFailure.message("Could not create the local control connection.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw RuntimeFailure.connectionUnavailable(errno) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw RuntimeFailure.message("The local audio engine has an unexpected owner.") }
        var data = try JSONSerialization.data(withJSONObject: command)
        guard data.count < 8192 else { throw RuntimeFailure.message("The command is too large.") }
        data.append(10)
        try data.withUnsafeBytes { pointer in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, pointer.baseAddress!.advanced(by: sent), data.count - sent, 0)
                guard n > 0 else { throw RuntimeFailure.message("The engine command could not be delivered. It was not retried.") }
                sent += n
            }
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < 65536 {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { throw RuntimeFailure.message("The engine response was interrupted. The command was not retried.") }
            result.append(contentsOf: buffer.prefix(n))
            if let newline = result.firstIndex(of: 10) {
                guard let value = try JSONSerialization.jsonObject(with: result.prefix(upTo: newline)) as? [String: Any] else {
                    throw RuntimeFailure.message("The engine returned an invalid response.")
                }
                return value
            }
        }
        throw RuntimeFailure.message("The engine response exceeded its size limit.")
    }
    func start(mode: String, selections: [String: Any], recovering: Bool = false) throws -> [String: Any] {
        events.record(.startRequested, reason: recovering ? .automaticRecovery : .userRequest)
        var startSucceeded = false
        defer { events.record(startSucceeded ? .startSucceeded : .startFailed, reason: startSucceeded ? nil : .operationFailed) }
        if !recovering { recoveryPauseLogged = false }
        guard mode == "synthetic" || mode == "live" else { throw RuntimeFailure.message("Choose local test or live audio.") }
        if let existing = try? exchange(["op": "status"]), existing["ok"] as? Bool == true {
            throw RuntimeFailure.message("An engine is already running. Stop it before changing mode or sources.")
        }
        if child?.isRunning == true {
            throw RuntimeFailure.message("The engine is already starting or awaiting permission. Refresh its status before trying to start again.")
        }
        // A crashed previous session cannot lend its lease to a new candidate
        // before revision, configuration and standby have been confirmed.
        leaseSessionActive = false; pauseControllerLease()
        recoveryCatalog.invalidate(); catalogStalled = false
        try prepareDirectory()
        guard let resources = resourcesOverride ?? Bundle.main.resourceURL else { throw RuntimeFailure.message("App resources are missing.") }
        let binary = resources.appendingPathComponent("bin/audio_router_host")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw RuntimeFailure.message("The native audio engine is missing from this build.") }
        var arguments = [mode == "live" ? "--live" : "--synthetic", "--runtime-dir", directory.path]
        let keyword = resources.appendingPathComponent("keyword/router_keyword_worker")
        let model = resources.appendingPathComponent("keyword/model")
        let selectedGraph = try mode == "live" ? ProductProfile.validate(graph(from: selections)) : GraphConfiguration.validate(graph(from: selections), complete: false)
        let revision = UUID().uuidString
        if selectedGraph["voice_detection"] as? Bool != false {
            guard FileManager.default.isExecutableFile(atPath: keyword.path), FileManager.default.fileExists(atPath: model.path) else {
                throw RuntimeFailure.message("Voice detection is missing from this build. Turn off Use voice phrases to run with manual controls.")
            }
            arguments += ["--keyword-worker", keyword.path, "--model-dir", model.path]
        }
        var launchIdentity: String?
        var launchInput: [String: String] = [:]
        if mode == "live" {
            let launchCatalog = try freshCatalog()
            let resolved = try GraphConfiguration.resolve(selectedGraph, catalog: launchCatalog, revision: revision)
            launchIdentity = resolved.identity
            launchInput = ["uid": resolved.uid, "name": (launchCatalog["inputs"] as? [[String: Any]])?.first { $0["uid"] as? String == resolved.uid }?["name"] as? String ?? "Microphone"]
            arguments += ["--allow-capture", "--mic-uid", resolved.uid, "--graph-json", resolved.json]
            for pid in resolved.assistantPIDs { arguments += ["--dot-pid", String(pid)] }
        } else {
            // Generated sources exercise the same graph without resolving any
            // devices or starting process capture. PIDs are bounded fixtures.
            let apps = (selectedGraph["apps"] as! [[String: String]]).enumerated().map {
                ["bundle_id": $0.element["bundle_id"]!, "pids": [1000 + $0.offset]] as [String: Any]
            }
            let native: [String: Any] = ["version": 1, "revision": revision, "apps": apps, "routes": selectedGraph["routes"]!]
            let data = try JSONSerialization.data(withJSONObject: native, options: [.sortedKeys])
            guard data.count <= 16384 else { throw RuntimeFailure.message("The audio graph is too large.") }
            arguments += ["--graph-json", String(decoding: data, as: UTF8.self)]
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let logURL = directory.appendingPathComponent("engine.log")
        let previousLog = directory.appendingPathComponent("engine.previous.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            if FileManager.default.fileExists(atPath: previousLog.path) { try FileManager.default.removeItem(at: previousLog) }
            try FileManager.default.moveItem(at: logURL, to: previousLog)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousLog.path)
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log; process.standardError = log
        try process.run()
        child = process
        var committed = false
        defer {
            try? log.close()
            if !committed {
                // A failed candidate must not retain capture or prevent rollback.
                if process.isRunning { process.terminate() }
                let stopDeadline = ProcessInfo.processInfo.systemUptime + 3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                if child === process { child = nil }
            }
        }
        let startDeadline = ProcessInfo.processInfo.systemUptime + 15
        while ProcessInfo.processInfo.systemUptime < startDeadline {
            if !process.isRunning { throw RuntimeFailure.message("The audio engine could not start. See ~/.audio-router/engine.log for the error.") }
            if var result = try? exchange(["op": "status"]), result["ok"] as? Bool == true {
                guard result["mode"] as? String == mode, result["graph_revision"] as? String == revision else {
                    throw RuntimeFailure.message("A different audio engine answered during startup. The new candidate was stopped without changing that engine.")
                }
                var config = settings()
                for key in ["mic_uid", "discord_bundle", "dot_bundle", "voice_detection"] { if let value = selections[key] { config[key] = value } }
                var names = config["names"] as? [String: String] ?? ["discord": "Router · Apps", "alexa": "Router · Assistant"]
                // Explicit starts also apply HAL names through the controller.
                // Recovery must preserve names until that user-facing path runs.
                if !recovering {
                    if names["discord"] == "Discord Input" { names["discord"] = "Router · Apps" }
                    if names["alexa"] == "Alexa Input" { names["alexa"] = "Router · Assistant" }
                }
                var configured = try configure(names: names, phrases: config["phrases"] as? [String: String] ?? [:])
                guard configured["ok"] as? Bool == true else {
                    let error = configured["error"] as? [String: String]
                    throw RuntimeFailure.message(error?["message"] ?? "The engine started but could not apply saved settings. It remains on standby.")
                }
                guard configured["mode"] as? String == mode, configured["graph_revision"] as? String == revision else {
                    throw RuntimeFailure.message("The audio engine changed while settings were being applied. The candidate was not committed.")
                }
                // Configuration can briefly renew the controller lease while a
                // detector validates phrases. Fence any intervening wake before
                // marking this new graph active, including rollback/recovery.
                configured = try exchange(["op": "standby"])
                guard configured["ok"] as? Bool == true, configured["mode"] as? String == mode,
                      configured["graph_revision"] as? String == revision, configured["gate"] as? String == "closed" else {
                    throw RuntimeFailure.message("The new audio engine could not confirm standby. The candidate was not committed.")
                }
                config["names"] = configured["names"]
                config["phrases"] = configured["phrases"]
                config["graph"] = selectedGraph
                config["last_active_graph"] = selectedGraph
                config["graph_revision"] = revision
                if let launchIdentity {
                    config["launch_identity"] = launchIdentity
                    config["resolved_input"] = launchInput
                } else {
                    config.removeValue(forKey: "launch_identity")
                    config.removeValue(forKey: "resolved_input")
                }
                try save(config)
                activeGraph = selectedGraph; graphRevision = revision; activeInput = launchInput
                if !recovering { recovery.reset() }
                liveIntent = mode == "live"; lastSelections = ["graph": selectedGraph]
                awaitingAttachStop = false; leaseSessionActive = true
                updateControllerLease()
                if let launchIdentity { recovery.recovered(identity: launchIdentity) }
                result = configured
                result["settings"] = settings()
                result["active_graph"] = activeGraph; result["active_graph_revision"] = revision
                recoveryMessage = ""; publishMetadata()
                committed = true
                startSucceeded = true
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw RuntimeFailure.message("The engine did not finish starting. Check the selected sources and microphone permission, then start again.")
    }
}
