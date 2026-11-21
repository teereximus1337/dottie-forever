import Foundation
import Darwin
@main struct NativeRuntimeTests {
    final class CatalogFixture {
        private let lock = NSLock()
        private var time: TimeInterval = 100
        private var count = 0
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ value: TimeInterval) { lock.lock(); time += value; lock.unlock() }
        func calls() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        func fetch() -> [String: Any] {
            lock.lock(); count += 1; let marker = count; lock.unlock()
            entered.signal(); release.wait()
            return ["marker": marker]
        }
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw RuntimeFailure.message(message) }
    }
    static func near(_ value: Any?, _ expected: Double, _ message: String) throws {
        guard let number = value as? Double else { throw RuntimeFailure.message(message) }
        try require(abs(number - expected) < 0.015, message + ": \(number) != \(expected)")
    }
    static func stopCandidate(_ runtime: NativeRuntime) {
        if let child = runtime.child, child.isRunning { child.terminate(); child.waitUntilExit() }
    }
    static func waitFor(_ message: String, _ predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
        try require(predicate(), message)
    }
    static func catalogChecks() throws {
        let fixture = CatalogFixture()
        let catalog = RecoveryCatalog(clock: fixture.now, fetch: fixture.fetch)
        defer { fixture.release.signal() }
        catalog.refreshIfNeeded(now: fixture.now())
        try require(fixture.entered.wait(timeout: .now() + 5) == .success, "Held catalog fixture started")
        for _ in 0..<20 { catalog.refreshIfNeeded(now: fixture.now()) }
        try require(fixture.calls() == 1 && catalog.snapshot(now: fixture.now()).catalog == nil, "Blocked HAL scans stay single-flight and nonblocking")
        fixture.advance(6)
        let stalled = catalog.snapshot(now: fixture.now())
        try require(stalled.expired && stalled.catalog == nil && stalled.inFlight, "Unfinished source checks become stale without a replacement worker")
        fixture.release.signal()
        try waitFor("Late catalog fixture returned") { !catalog.snapshot(now: fixture.now()).inFlight }
        try require(catalog.snapshot(now: fixture.now()).catalog == nil, "A slow scan cannot be presented as a freshly verified identity")

        catalog.refreshIfNeeded(now: fixture.now())
        try require(fixture.entered.wait(timeout: .now() + 5) == .success, "Replacement scan started after previous completion")
        var timedOut = false
        do { _ = try catalog.freshSnapshot(timeout: 0.05) } catch { timedOut = true }
        try require(timedOut && fixture.calls() == 2, "Explicit fresh discovery has a bounded wait and cannot create overlapping HAL calls")
        catalog.invalidate() // Stop/sleep/graph change while that scan is held.
        fixture.advance(6)
        try require(catalog.snapshot(now: fixture.now()).expired && catalog.snapshot(now: fixture.now()).inFlight,
                    "Invalidation cannot hide an obsolete HAL call that still blocks the only worker")
        fixture.release.signal()
        try waitFor("Invalidated catalog fixture returned") { !catalog.snapshot(now: fixture.now()).inFlight }
        try require(catalog.snapshot(now: fixture.now()).catalog == nil, "Late results cannot cross a stop/sleep/configuration boundary")

        catalog.refreshIfNeeded(now: fixture.now())
        try require(fixture.entered.wait(timeout: .now() + 5) == .success, "Current-generation scan started")
        let sampledBeforeCompletion = fixture.now()
        fixture.advance(0.0001)
        fixture.release.signal()
        try waitFor("Fresh catalog available") { catalog.snapshot(now: fixture.now()).catalog != nil }
        let fresh = catalog.snapshot(now: fixture.now())
        try require(fresh.catalog?["marker"] as? Int == 3 && !fresh.expired, "Only the current complete scan becomes usable")
        let raced = catalog.snapshot(now: sampledBeforeCompletion)
        try require(raced.catalog?["marker"] as? Int == 3 && !raced.expired,
                    "Completion just after sampled controller time is fresh, never a reason for standby")
        for _ in 0..<20 { catalog.refreshIfNeeded(now: fixture.now()) }
        try require(fixture.calls() == 3 && catalog.snapshot(now: fixture.now()).sequence == fresh.sequence, "Refresh cadence and snapshot sequence are bounded")
        timedOut = false
        do { _ = try catalog.freshSnapshot(timeout: 0.05) } catch { timedOut = true }
        try require(timedOut && catalog.snapshot(now: fixture.now()).catalog == nil,
                    "Explicit fresh resolution cannot fall back to an earlier usable catalog")
        try require(fixture.entered.wait(timeout: .now() + 5) == .success, "Fresh-boundary scan entered")
        fixture.release.signal()
        try waitFor("Fresh-boundary scan completed") { catalog.snapshot(now: fixture.now()).catalog != nil }
        fixture.advance(6)
        try require(catalog.snapshot(now: fixture.now()).expired && catalog.snapshot(now: fixture.now()).catalog == nil, "Completed source identities also expire")
        try require(catalog.snapshot(now: sampledBeforeCompletion).expired && catalog.snapshot(now: sampledBeforeCompletion).catalog == nil,
                    "An old caller timestamp cannot preserve a catalog after the actual freshness limit")

        let healthy: [String: Any] = ["health": ["mic": true, "discord": true, "dot": true]]
        var detector = healthy
        detector["detector"] = ["enabled": true, "healthy": false, "ready": false, "error": ""]
        try require(NativeRuntime.sourcesHealthyForRecovery(detector), "Normal detector startup does not spend capture restart attempts")
        detector["config_pending"] = true
        try require(NativeRuntime.sourcesHealthyForRecovery(detector), "Pending phrase validation is allowed to settle")
        detector["detector"] = ["enabled": true, "healthy": false, "error": "worker_timeout"]
        try require(!NativeRuntime.sourcesHealthyForRecovery(detector), "Terminal wake-worker failure recovers despite healthy captures")
        detector["detector"] = ["enabled": false, "healthy": false, "error": "worker_timeout"]
        try require(NativeRuntime.sourcesHealthyForRecovery(detector), "Disabled voice detection is not a recovery fault")
        detector["health"] = ["mic": true, "discord": true, "dot": false]
        try require(!NativeRuntime.sourcesHealthyForRecovery(detector), "Capture failures still require recovery")
        print("PASS single-flight catalog, stale/late identity fencing and terminal detector recovery; no HAL or capture")
    }
    static func recoveryStopChecks() throws {
        var time: TimeInterval = 100, pauses = 0, probes = 0
        let settled = RecoveryStopWait.untilStopped(clock: { time }, pause: { time += $0; pauses += 1 },
            childRunning: { time < 100.085 }, controlAbsent: { probes += 1; return true })
        try require(settled && pauses == 2 && probes == 1,
                    "Socket teardown before child-exit notification settles within the same recovery attempt")
        time = 200; pauses = 0; probes = 0
        let ownedHung = RecoveryStopWait.untilStopped(timeout: 0.2, clock: { time }, pause: { time += $0; pauses += 1 },
            childRunning: { true }, controlAbsent: { probes += 1; return true })
        try require(!ownedHung && time >= 200.2 && pauses <= 5 && probes == 0,
                    "A genuinely running old child times out without probing or launching a replacement")
        time = 300; probes = 0
        let attached = RecoveryStopWait.untilStopped(clock: { time }, pause: { time += $0 },
            childRunning: { false }, controlAbsent: { probes += 1; return time >= 300.085 })
        try require(attached && probes == 3, "Attached hosts without a child handle must also release control before replacement")
        time = 400
        let liveSocket = RecoveryStopWait.untilStopped(timeout: 0.2, clock: { time }, pause: { time += $0 },
            childRunning: { false }, controlAbsent: { false })
        try require(!liveSocket && time >= 400.2, "A surviving control endpoint times out even when no owned child exists")
        print("PASS recovery waits for process and socket teardown with bounded injected time; no host or capture")
    }
    static func detachChecks(_ runtime: NativeRuntime) throws {
        try runtime.prepareDirectory()
        var missingError: Error?
        do { _ = try runtime.exchange(["op": "standby"]) } catch { missingError = error }
        try require(runtime.confirmedDetachedAbsence(after: missingError), "A missing socket with no live child confirms host absence")
        try require(runtime.confirmedStoppedControl(), "Nonblocking probe confirms a missing socket")
        let path = runtime.directory.appendingPathComponent("control.sock").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        try require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "Fixture socket path fits")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try require(fd >= 0, "Fixture socket created")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        try require(bound == 0, "Closed bound fixture leaves a stale socket")
        var staleError: Error?
        do { _ = try runtime.exchange(["op": "standby"]) } catch { staleError = error }
        try require(runtime.confirmedDetachedAbsence(after: staleError), "Owned stale socket refusal confirms absence without a live child")
        try require(runtime.confirmedStoppedControl(), "Nonblocking probe confirms an owned refused socket")
        try require(FileManager.default.fileExists(atPath: path), "Detach checking leaves the stale socket untouched")
        try require(!runtime.confirmedDetachedAbsence(after: RuntimeFailure.connectionUnavailable(ETIMEDOUT)), "A timeout does not establish safe absence")
        try require(!runtime.confirmedDetachedAbsence(after: RuntimeFailure.message("The local audio engine has an unexpected owner.")), "Unverified peer cannot establish safe absence")
        try FileManager.default.removeItem(atPath: path)
        try Data().write(to: URL(fileURLWithPath: path))
        try require(!runtime.confirmedDetachedAbsence(after: RuntimeFailure.connectionUnavailable(ECONNREFUSED)), "A nonsocket file cannot confirm stale host absence")
        try require(!runtime.confirmedStoppedControl(), "An unexpected nonsocket path is not confirmed stopped")
        try FileManager.default.removeItem(atPath: path)

        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        try require(server >= 0, "Silent control peer fixture created")
        defer { close(server); try? FileManager.default.removeItem(atPath: path) }
        let listening = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try require(listening == 0 && listen(server, 1) == 0 && fcntl(server, F_SETFL, O_NONBLOCK) == 0, "Silent peer listens without responding")
        try require(!runtime.confirmedStoppedControl(), "Connected silent peer is never mistaken for an absent host")
        let client = accept(server, nil, nil)
        try require(client >= 0, "Nonblocking probe reached the private fixture peer")
        defer { close(client) }
        try require(fcntl(client, F_SETFL, O_NONBLOCK) == 0, "Fixture receive is nonblocking")
        var byte: UInt8 = 0
        try require(recv(client, &byte, 1, 0) == 0, "Stop probe sends no status, heartbeat, or audio-changing command")
    }
    static func eventChecks(_ directory: URL) throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let log = ControllerEventLog(directory: directory, sink: { _ in entered.signal(); release.wait() })
        let runtime = NativeRuntime(directory: directory, events: log)
        defer { for _ in 0..<64 { release.signal() } }
        try require(entered.wait(timeout: .now() + 5) == .success, "Runtime event sink is held")
        runtime.cacheConfirmedStatus(["ok": true, "mode": "synthetic", "graph_revision": "fixture", "frames": 1,
                                      "diagnostics": ["host": ["active": true, "written": 9]]])
        let snapshot = try runtime.cachedSnapshot()
        let live = snapshot["diagnostics"] as? [String: Any] ?? [:]
        try require((live["host"] as? [String: Any])?["written"] as? Int == 9 && live["controller"] != nil,
                    "Cached status adds controller events without replacing host diagnostics")
        runtime.clearCachedStatus()
        let stopped = runtime.eventDiagnostics()
        try require(stopped["host"] == nil && stopped["controller"] != nil && (try? runtime.cachedSnapshot()) == nil,
                    "Stopped diagnostics remain available without claiming a fresh host or changing status failure semantics")
        // These operations must return while disk is blocked. No valid graph or
        // host exists, so the test cannot touch capture or a live control socket.
        runtime.willSleep(); runtime.didWake()
        _ = try? runtime.start(mode: "invalid-fixture-mode", selections: [:])
        _ = try? runtime.stopByUser()
        try require((log.status()["queued"] as? Int) == 7 && (log.status()["active"] as? Bool) == false,
                    "Start/stop and sleep/wake metadata are queued without waiting on held disk")
        for _ in 0..<7 { release.signal() }
        try waitFor("Runtime event queue drains") { (log.status()["written"] as? NSNumber)?.intValue == 7 }
    }
    static func pcm(_ runtime: NativeRuntime) throws -> [String: Any] {
        let reader = Process(), pipe = Pipe()
        reader.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("macos/host/build/read_test_transport")
        reader.arguments = [runtime.directory.appendingPathComponent("transport/pcm-v1.bin").path]
        reader.standardOutput = pipe
        try reader.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        reader.waitUntilExit()
        try require(reader.terminationStatus == 0, "Synthetic transport read failed")
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() throws {
        // sockaddr_un paths are short on macOS; Foundation's per-user temp
        // prefix plus a UUID can exceed the socket's complete path capacity.
        let temp = URL(fileURLWithPath: "/private/tmp/ar-runtime-" + UUID().uuidString.prefix(12))
        defer { try? FileManager.default.removeItem(at: temp) }
        // A completed command is visible immediately; an older telemetry result
        // cannot roll its gate back or relabel it with the previous graph.
        let cache = NativeRuntime(directory: temp.appendingPathComponent("cache-runtime"))
        let closedUnattached: [String: Any] = ["ok": true, "mode": "live", "gate": "closed", "graph_revision": "existing-host"]
        try require(cache.confirmedDetachedStandby(closedUnattached), "Closed owned host can release a renderer before first attachment")
        try require(cache.graphRevision.isEmpty && !cache.initialAttachChecked && !cache.liveIntent && !cache.leaseSessionActive,
                    "Renderer detach acknowledgment cannot adopt a revision or enable an unattached lease")
        cache.initialAttachChecked = true
        try require(!cache.confirmedDetachedStandby(closedUnattached), "Only genuinely unattached controllers can accept an unknown closed revision")
        cache.initialAttachChecked = false; cache.graphRevision = "another-host"
        try require(!cache.confirmedDetachedStandby(closedUnattached), "Known revision mismatch cannot confirm renderer detach")
        cache.graphRevision = "existing-host"
        try require(cache.confirmedDetachedStandby(closedUnattached), "Matching known closed revision confirms detach")
        cache.graphRevision = ""
        try detachChecks(cache)
        let beforeCommand = cache.telemetryGeneration()
        cache.cacheConfirmedStatus(["ok":true, "mode":"synthetic", "graph_revision":"new", "frames":200, "gate":"open"])
        cache.cacheTelemetry(["graph_revision":"old", "frames":999, "gate":"closed"], generation:beforeCommand)
        cache.cacheTelemetry(["graph_revision":"new", "frames":100, "gate":"closed"], generation:cache.telemetryGeneration())
        try require(try cache.cachedSnapshot()["gate"] as? String == "open", "Confirmed command cache rejects stale telemetry")
        cache.cacheTelemetry(["graph_revision":"new", "frames":201, "gate":"closed"], generation:cache.telemetryGeneration())
        try require(try cache.cachedSnapshot()["gate"] as? String == "closed", "Newer real telemetry can close the gate")
        let beforeStop = cache.telemetryGeneration()
        cache.clearCachedStatus()
        cache.cacheTelemetry(["graph_revision":"new", "frames":202, "gate":"open"], generation:beforeStop)
        try require((try? cache.cachedSnapshot()) == nil, "Stopped cache rejects in-flight pre-stop telemetry")
        try catalogChecks()
        try recoveryStopChecks()
        try eventChecks(temp.appendingPathComponent("event-runtime"))

        // The same cached scan must not satisfy the three-observation debounce.
        // This runtime has no host and uses only a complete fixture catalog.
        var fixtureGraph = ProductProfile.sanitizedGraph(from: [:])
        fixtureGraph["mic"] = ["mode": "device", "uid": "fixture-input"]
        fixtureGraph["voice_detection"] = false
        let sourceFixture: [String: Any] = ["inputs": [["uid": "fixture-input", "name": "Fixture"]],
            "apps": [["bundle_id": ProductProfile.chatGPTBundleID, "pids": [Int32(123)]]]]
        let observed = RecoveryCatalog(fetch: { sourceFixture })
        observed.refreshIfNeeded(now: ProcessInfo.processInfo.systemUptime)
        try waitFor("Identity fixture ready") { observed.snapshot(now: ProcessInfo.processInfo.systemUptime).catalog != nil }
        let checking = NativeRuntime(directory: temp.appendingPathComponent("catalog-runtime"), recoveryCatalog: observed)
        checking.liveIntent = true; checking.initialAttachChecked = true
        checking.lastSelections = ["graph": fixtureGraph]
        checking.recovery.expected = "previous-identity"
        let fixtureStatus: [String: Any] = ["mode": "live", "gate": "closed", "health": ["mic": true, "discord": true, "dot": true]]
        for _ in 0..<8 { checking.recoveryChecked = 0; checking.checkRecovery(fixtureStatus) }
        try require(checking.recovery.observations == 1 && checking.recovery.attempts == 0 && checking.child == nil,
                    "One cached identity cannot trigger a capture restart")

        let resources = temp.appendingPathComponent("resources"), bin = resources.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let manualMarker = resources.appendingPathComponent("ManualVoiceGate")
        let manualRuntime = NativeRuntime(directory: temp.appendingPathComponent("manual-runtime"), resources: resources)
        let defaultGraph = ProductProfile.sanitizedGraph(from: [:])
        try require(manualRuntime.graphForBuild(defaultGraph)["voice_detection"] as? Bool == true,
                    "The full build preserves the normal detector default")
        try Data().write(to: manualMarker)
        _ = try manualRuntime.saveGraph(defaultGraph)
        try require(manualRuntime.graph(from: manualRuntime.settings())["voice_detection"] as? Bool == false,
                    "A manual build refuses to persist a graph with voice detection enabled")
        try require(manualRuntime.graphForBuild(defaultGraph)["voice_detection"] as? Bool == false,
                    "A manual build presents the gate without its missing detector")
        try FileManager.default.removeItem(at: manualMarker)
        let host = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("macos/host/build/audio_router_host")
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("audio_router_host"), withDestinationURL: host)
        let runtime = NativeRuntime(directory: temp.appendingPathComponent("runtime"), resources: resources)
        defer { stopCandidate(runtime) }
        var settings = runtime.settings()
        settings["names"] = ["discord":"same","alexa":"same"]
        try runtime.save(settings)
        var graph = GraphConfiguration.legacy(["mic_uid":"fixture-mic", "dot_bundle":"fixture.ai", "discord_bundle":"fixture.app"])
        graph["voice_detection"] = false
        graph["routes"] = ["mic_to_apps":false, "assistant_to_apps":true, "mic_to_assistant":false, "apps_to_assistant":["fixture.app"]]
        var rejected = false
        do { _ = try runtime.start(mode: "synthetic", selections:["graph":graph]) } catch { rejected = true }
        try require(rejected, "Invalid names should fail after host launch")
        try require(runtime.child == nil, "Failed start must reap its own candidate")
        try require((try? runtime.exchange(["op":"status"])) == nil, "Failed start must release its socket")
        settings["names"] = ["discord":"Router Apps","alexa":"Router Assistant"]; try runtime.save(settings)
        let started = try runtime.start(mode:"synthetic",selections:["graph":graph])
        try require(started["mode"] as? String == "synthetic", "Synthetic mode preserved")
        try require(started["gate"] as? String == "closed", "New graph starts on standby")
        let revision = started["graph_revision"] as? String ?? ""
        try require(!revision.isEmpty && revision == runtime.graphRevision, "Candidate revision must match the real host")
        runtime.maintainTelemetry()
        Thread.sleep(forTimeInterval: 0.15)
        _ = try runtime.exchange(["op":"heartbeat"])
        let asleep = try pcm(runtime)
        try near(asleep["discord"], 0.375, "Synthetic shared apps feed follows selected routes")
        try near(asleep["alexa"], 0, "Synthetic assistant is gated on startup")
        let awake = try runtime.exchange(["op":"wake"])
        try require(awake["gate"] as? String == "open", "Generated sources can wake")
        Thread.sleep(forTimeInterval: 0.15)
        let routed = try pcm(runtime)
        try near(routed["alexa"], 0.25, "Synthetic assistant excludes the disconnected mic edge")
        let status = try runtime.exchange(["op":"heartbeat"])
        let levels = status["meter_levels"] as! [String: Any]
        try near((levels["listener"] as? [String: Any])?["rms"], 0.375, "Wake listener retains microphone with mic route disabled")
        try require((levels["apps"] as? [String: Any])?["fixture.app"] != nil, "Synthetic app meter has the chosen bundle identity")
        runtime.graphRevision = "stale-controller-metadata"; runtime.publishMetadata()
        let cached = try runtime.cachedSnapshot()
        try require(cached["graph_revision"] as? String == revision, "Cache must preserve actual host revision")
        try require(cached["active_graph"] == nil, "Mismatched cached revision cannot label a new active graph")
        runtime.graphRevision = revision; runtime.publishMetadata()
        rejected = false
        do { _ = try runtime.applyGraph(["version":99]) } catch { rejected = true }
        try require(rejected, "Invalid graph accepted")
        let preserved = try runtime.exchange(["op":"status"])
        try require(preserved["mode"] as? String == "synthetic", "Invalid edits must preserve the running engine")
        try require(preserved["graph_revision"] as? String == revision, "Invalid edits must preserve the active revision")
        let stopped = try runtime.stopByUser(); try require(stopped["ok"] as? Bool == true, "Stop acknowledged")
        runtime.child?.waitUntilExit()
        try require(!runtime.liveIntent, "Stopped controller has no recovery intent")
        try require((try? runtime.exchange(["op":"status"])) == nil, "Stopped host releases socket")

        // Simulate attaching to a pre-profile live controller using a generated
        // host. Unsupported saved sources must stop, never enter live recovery.
        _ = try runtime.start(mode: "synthetic", selections: ["graph": graph])
        runtime.initialAttachChecked = false
        runtime.recoveryChecked = 0
        runtime.checkRecovery(["mode": "live", "gate": "closed"])
        runtime.child?.waitUntilExit()
        try require(!runtime.liveIntent && runtime.activeGraph.isEmpty, "Unsupported saved graph cannot resume capture through recovery")
        try require(runtime.recoveryMessage.contains("unsupported sources"), "Unsupported recovery gives a useful visible explanation")
        try require((try? runtime.exchange(["op": "status"])) == nil, "Unsupported attached host is stopped")

        rejected = false
        do { _ = try runtime.start(mode: "live", selections: ["graph": graph]) } catch {
            rejected = error.localizedDescription.contains("ChatGPT and optional Discord")
        }
        try require(rejected && runtime.child?.isRunning != true, "Live start rejects out-of-profile audio before capture")

        // A reattached host owns its original default-input selection, not the
        // current system default. All catalog/capture work is bypassed here:
        // only the first attachment observation is simulated against generated
        // PCM and private settings. No recovery timer is started by this test.
        var profile = ProductProfile.sanitizedGraph(from: [:])
        profile["mic"] = ["mode": "default"]
        profile["voice_detection"] = false
        let oldIdentity = "old-default-mic|" + ProductProfile.chatGPTBundleID + ":9999"
        let recordedInput = ["uid": "old-default-mic", "name": "Original microphone"]
        let unchangedDefault: [String: Any] = ["defaults": ["input_uid": "old-default-mic"], "inputs": [["uid": "old-default-mic"]], "apps": [[String: Any]]()]
        try require(!NativeRuntime.defaultInputRequiresStop(profile, catalog: unchangedDefault, captured: recordedInput),
                    "Missing app audio must not stop a still-verified default microphone feed")
        let changedDefault: [String: Any] = ["defaults": ["input_uid": "new-default-mic"], "inputs": [["uid": "new-default-mic"]]]
        try require(NativeRuntime.defaultInputRequiresStop(profile, catalog: changedDefault, captured: recordedInput),
                    "Changed physical default requires stopping the old input")
        let virtualDefault: [String: Any] = ["defaults": ["input_uid": "virtual-input"], "inputs": [["uid": "old-default-mic"]]]
        try require(NativeRuntime.defaultInputRequiresStop(profile, catalog: virtualDefault, captured: recordedInput),
                    "Nonphysical default requires stopping capture")
        try require(NativeRuntime.defaultInputRequiresStop(profile, catalog: unchangedDefault, captured: [:]),
                    "Unverified captured identity cannot preserve a default input")
        var pinnedProfile = profile; pinnedProfile["mic"] = ["mode":"device", "uid":"old-default-mic"]
        try require(!NativeRuntime.defaultInputRequiresStop(pinnedProfile, catalog: virtualDefault, captured: recordedInput),
                    "Pinned input does not follow unrelated default changes")
        _ = try runtime.start(mode: "synthetic", selections: ["graph": graph])
        let attachedRevision = runtime.graphRevision
        var attachSettings = runtime.settings()
        try require(attachSettings["launch_identity"] == nil && attachSettings["resolved_input"] == nil,
                    "Synthetic startup must clear stale live identity records")
        attachSettings["last_active_graph"] = profile
        attachSettings["launch_identity"] = oldIdentity
        attachSettings["resolved_input"] = recordedInput
        try runtime.save(attachSettings)
        runtime.initialAttachChecked = false; runtime.recoveryChecked = 0
        runtime.activeGraph = [:]; runtime.activeInput = [:]; runtime.graphRevision = ""
        runtime.recovery.reset()
        runtime.checkRecovery(["mode": "live", "graph_revision": attachedRevision, "gate": "open"])
        try require(runtime.liveIntent && !runtime.awaitingAttachStop, "Matching persisted launch record can attach")
        try require(runtime.recovery.expected == oldIdentity && runtime.activeInput == recordedInput,
                    "Attachment must retain the microphone actually captured by the host")
        try require(runtime.child?.isRunning == true, "Verified attachment preserves its host")
        let newlySelected = "new-default-mic|" + ProductProfile.chatGPTBundleID + ":9999"
        _ = runtime.recovery.evaluate(identity: newlySelected, healthy: true, now: ProcessInfo.processInfo.systemUptime)
        try require(runtime.recovery.expected == oldIdentity && runtime.recovery.candidate == newlySelected,
                    "A newly selected default must trigger recovery instead of being adopted as the old host identity")
        _ = try runtime.stopByUser(); runtime.child?.waitUntilExit()

        for mismatch in [false, true] {
            _ = try runtime.start(mode: "synthetic", selections: ["graph": graph])
            let actualRevision = runtime.graphRevision
            var saved = runtime.settings()
            saved["last_active_graph"] = profile
            if mismatch {
                saved["graph_revision"] = "another-graph"
                saved["launch_identity"] = oldIdentity
                saved["resolved_input"] = recordedInput
            }
            try runtime.save(saved)
            runtime.initialAttachChecked = false; runtime.recoveryChecked = 0
            runtime.activeGraph = [:]; runtime.activeInput = [:]; runtime.graphRevision = ""
            runtime.recovery.reset()
            runtime.checkRecovery(["mode": "live", "graph_revision": actualRevision, "gate": "open"])
            runtime.child?.waitUntilExit()
            try require(runtime.liveIntent && runtime.awaitingAttachStop, "Unverified attachment waits without renewing the old controller lease")
            try require(runtime.recovery.expected == "reattach-requires-reconnect" && runtime.recovery.attempts == 0,
                        "Unverified attachment schedules bounded recovery without launching capture")
            try require(runtime.activeInput.isEmpty, "Unverified attachment must not claim the current default is captured")
            try require((try? runtime.exchange(["op":"status"])) == nil, "Unverified old host is shut down")
        }

        // Deliberately discard --graph-json in a fixture launcher. The owned
        // candidate must be reaped instead of configuring/committing that reply.
        let wrongResources = temp.appendingPathComponent("wrong-resources")
        let wrongBin = wrongResources.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: wrongBin, withIntermediateDirectories: true)
        let launcher = wrongBin.appendingPathComponent("audio_router_host")
        let quotedHost = "'" + host.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try ("#!/bin/sh\nexec " + quotedHost + " --synthetic --runtime-dir \"$3\"\n").write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let wrong = NativeRuntime(directory: temp.appendingPathComponent("wrong-runtime"), resources: wrongResources)
        defer { stopCandidate(wrong) }
        rejected = false
        do { _ = try wrong.start(mode:"synthetic", selections:["graph":graph]) } catch {
            rejected = error.localizedDescription.contains("different audio engine")
        }
        try require(rejected, "Wrong host revision must reject startup before commit")
        try require(wrong.child == nil && wrong.activeGraph.isEmpty && wrong.graphRevision.isEmpty, "Wrong revision must not commit or retain its candidate")
        try require((try? wrong.exchange(["op":"status"])) == nil, "Wrong-revision candidate releases socket")
        // The lease must survive a controller queue held by a slow catalog
        // read, even without a UI run loop or a visible WebKit page.
        let leased = NativeRuntime(directory: temp.appendingPathComponent("lease-runtime"), resources: resources)
        defer { stopCandidate(leased) }
        _ = try leased.start(mode: "synthetic", selections: ["graph": graph])
        leased.maintainControllerLease(); leased.queue.sync {}
        _ = try leased.exchange(["op": "wake"])
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() } // Never strand the fixture queue on assertion failure.
        leased.queue.async { entered.signal(); unblock.wait() }
        try require(entered.wait(timeout: .now() + 2) == .success, "Controller blocking fixture started")
        // This regression isolates controller eligibility. Original PCM and
        // mixer checks above independently cover the actual transport; host
        // scheduler slips can close its gate without expiring this lease.
        let blockedUntil = ProcessInfo.processInfo.systemUptime + 1.35
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            let background = try leased.exchange(["op": "status"])
            try require((background["health"] as? [String: Bool])?["controller"] == true, "Slow controller/catalog work cannot expire the independent lease")
        } while ProcessInfo.processInfo.systemUptime < blockedUntil
        unblock.signal(); leased.queue.sync {}

        // Revocation is immediate even if the controller cannot yet process its
        // standby command. The original one-second host lease remains bounded.
        leased.queue.async { entered.signal(); unblock.wait() }
        try require(entered.wait(timeout: .now() + 2) == .success, "Sleep blocking fixture started")
        leased.suspendControllerLease()
        Thread.sleep(forTimeInterval: 1.35)
        let sleeping = try leased.exchange(["op": "status"])
        try require((sleeping["health"] as? [String: Bool])?["controller"] == false, "Sleep revokes renewal before queued recovery can run")
        try require(sleeping["gate"] as? String == "closed", "Expired sleep lease keeps the assistant gate closed")
        unblock.signal(); leased.queue.sync { leased.willSleep(); leased.didWake(); leased.recovery.reset(); leased.checkRecovery(try? leased.exchange(["op": "status"])) }
        let renewedUntil = ProcessInfo.processInfo.systemUptime + 1.35
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            let resumed = try leased.exchange(["op": "status"])
            try require((resumed["health"] as? [String: Bool])?["controller"] == true, "Independent lease resumes after sleep eligibility returns")
            try require(resumed["gate"] as? String == "closed", "Resuming renewal never wakes the assistant")
        } while ProcessInfo.processInfo.systemUptime < renewedUntil
        _ = try leased.exchange(["op": "wake"])
        leased.queue.async { entered.signal(); unblock.wait() }
        try require(entered.wait(timeout: .now() + 2) == .success, "Release blocking fixture started")
        leased.releaseControllerLease()
        Thread.sleep(forTimeInterval: 1.35)
        let released = try leased.exchange(["op": "status"])
        try require((released["health"] as? [String: Bool])?["controller"] == false, "Explicit release revokes renewal despite a blocked controller queue")
        try require(released["gate"] as? String == "closed", "Expired released lease keeps the assistant gate closed")
        unblock.signal(); leased.queue.sync {}
        _ = try leased.stopByUser(); leased.child?.waitUntilExit()

        print("PASS controller cleanup, revision/cache fencing, independent background lease, sleep/release closure, real synthetic graph PCM/meters and stop; no live capture")
    }
}
