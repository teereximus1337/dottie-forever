import Foundation
import CoreAudio

@main struct AudioCatalogTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func makeApp(_ root: URL, _ name: String, _ identifier: String) throws -> URL {
        let app = root.appendingPathComponent(name + ".app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name,
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "test"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/test")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return app
    }
    static func main() throws {
        typealias D = AudioCatalog.Device
        let mic = D(id: 1, uid: "physical-mic", name: "Microphone", transport: kAudioDeviceTransportTypeUSB, input: true, output: false)
        let speakers = D(id: 2, uid: "physical-output", name: "Speakers", transport: kAudioDeviceTransportTypeHDMI, input: false, output: true)
        let virtual = D(id: 3, uid: "virtual-input", name: "Virtual", transport: kAudioDeviceTransportTypeVirtual, input: true, output: true)
        let router = D(id: 4, uid: "ai.agentsofchange.router.input", name: "Router", transport: kAudioDeviceTransportTypeUSB, input: true, output: false)
        let aggregate = D(id: 5, uid: "aggregate", name: "Aggregate", transport: kAudioDeviceTransportTypeAggregate, input: true, output: true)
        let devices = [mic, speakers, virtual, router, aggregate]
        let inputs = AudioCatalog.physicalDevices(devices, input: true)
        let outputs = AudioCatalog.physicalDevices(devices, input: false)
        require(inputs.map(\.uid) == [mic.uid], "Only supported physical capture sources are selectable")
        require(outputs.map(\.uid) == [speakers.uid], "HDMI outputs are discoverable without adding a monitor")
        require(AudioCatalog.defaultUID(1, from: inputs) == mic.uid, "Exact available default resolves")
        require(AudioCatalog.defaultUID(3, from: inputs).isEmpty, "A virtual system default never becomes a mic source")
        require(AudioCatalog.defaultUID(4, from: inputs).isEmpty, "Router input cannot feed itself even if transport is misreported")
        require(AudioCatalog.defaultUID(nil, from: inputs).isEmpty, "An unavailable default does not choose another mic")
        require(AudioCatalog.defaultUID(2, from: inputs).isEmpty, "A playback device cannot become the mic")
        let duplicate = D(id: 6, uid: mic.uid, name: "Duplicate", transport: mic.transport, input: true, output: false)
        require(AudioCatalog.defaultUID(1, from: [mic, duplicate]).isEmpty, "Duplicate device UIDs are ambiguous")

        typealias A = AudioCatalog.Application
        let installed = A(bundleID: "example.app", name: "Installed app", installed: true)
        let running = A(bundleID: "example.app", name: "Running app", installed: true, running: true)
        let capture = A(bundleID: "example.app", name: "Running app", installed: true, running: true, pids: [5, 9])
        let other = A(bundleID: "example.other", name: "Other", installed: true)
        let combined = AudioCatalog.mergedApplications([[installed.bundleID: installed, other.bundleID: other], [running.bundleID: running], [capture.bundleID: capture]])
        require(combined.count == 2, "Installed/running/audio entries deduplicate by exact bundle identity")
        require(combined[installed.bundleID]?.pids == [5, 9], "Only actual audio PIDs enter the allowlist")
        require(combined[installed.bundleID]?.name == running.name, "Running physical app name supersedes stale installed name")
        require(combined[other.bundleID]?.value["audio_available"] as? Bool == false, "Installed does not mean capturable")
        require(combined[other.bundleID]?.value["running"] as? Bool == false, "Installed does not mean running")
        let bad = A(bundleID: "private.audio.router.app", name: "Router", installed: true, running: true, pids: [100])
        require(AudioCatalog.mergedApplications([[bad.bundleID: bad]]).isEmpty, "Router app is excluded from capture discovery")

        typealias P = AudioCatalog.ApplicationProcess
        // These fixtures describe device association. Instantaneous output
        // activity is deliberately absent from the routing eligibility API.
        let playback = P(pid: 10, bundleID: "example.voice", name: "Voice", outputDevices: [40])
        let inputOnly = P(pid: 11, bundleID: playback.bundleID, name: playback.name, outputDevices: [])
        let unknown = P(pid: 12, bundleID: playback.bundleID, name: playback.name, outputDevices: nil)
        let invalid = P(pid: 13, bundleID: playback.bundleID, name: playback.name, outputDevices: [kAudioObjectUnknown])
        let mixedUnknown = P(pid: 14, bundleID: playback.bundleID, name: playback.name, outputDevices: [40, kAudioObjectUnknown])
        let initialOutputs = AudioCatalog.outputApplications([playback])
        let withHelpers = AudioCatalog.outputApplications([playback, inputOnly, unknown, invalid, mixedUnknown])
        require(withHelpers[playback.bundleID]?.pids == initialOutputs[playback.bundleID]?.pids,
                "Input-only or unreadable helpers never change the selected playback identity")
        require(withHelpers[playback.bundleID]?.pids == [10], "Only verified output-associated PIDs are routed")
        let silentOutput = playback // Same association with IsRunningOutput false remains eligible.
        require(AudioCatalog.outputApplications([silentOutput])[playback.bundleID]?.pids == [10],
                "Silent or paused output retains its association without consulting running status")
        let replacement = P(pid: 20, bundleID: playback.bundleID, name: playback.name, outputDevices: [40])
        require(AudioCatalog.outputApplications([replacement, inputOnly])[playback.bundleID]?.pids == [20],
                "A true output-process replacement changes the selected identity")
        require(AudioCatalog.outputApplications([playback, replacement])[playback.bundleID]?.pids == [10, 20],
                "An additional real output process remains discoverable for migrated playback")
        let idlePackaged = P(pid: 21, bundleID: playback.bundleID, name: playback.name, outputDevices: [], isApplicationExecutable: true)
        require(AudioCatalog.outputApplications([idlePackaged, inputOnly])[playback.bundleID]?.pids == [21],
                "A verified app executable remains selectable with no active output association")
        let inputOnlyApp = A(bundleID: "example.input-only", name: "Input only", installed: true, running: true)
        let inputOnlyProcess = P(pid: 30, bundleID: inputOnlyApp.bundleID, name: inputOnlyApp.name, outputDevices: [])
        let visibleInputOnly = AudioCatalog.mergedApplications([[inputOnlyApp.bundleID: inputOnlyApp], AudioCatalog.outputApplications([inputOnlyProcess])])
        require(visibleInputOnly[inputOnlyApp.bundleID]?.value["running"] as? Bool == true &&
                visibleInputOnly[inputOnlyApp.bundleID]?.value["audio_available"] as? Bool == false,
                "Installed and running input-only apps remain visible but not playback-capturable")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-catalog-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try makeApp(root, "Example", "example.scan")
        _ = try makeApp(outer.appendingPathComponent("Contents/Helpers", isDirectory: true), "Helper", "example.helper")
        _ = try makeApp(root.appendingPathComponent("Nested", isDirectory: true), "Hidden nested app", "example.nested")
        _ = try makeApp(root, "Router", "private.audio.router.app")
        let scanned = AudioCatalog.scanInstalledApplications(in: [root])
        require(Set(scanned.keys) == ["example.scan"], "Installed scan never descends inside apps or arbitrary subfolders")
        require(AudioCatalog.scanInstalledApplications(in: [root], maximumEntriesPerRoot: 0).isEmpty, "Scan obeys entry bound")
        let helperExecutable = outer.appendingPathComponent("Contents/Helpers/Helper.app/Contents/MacOS/test").path
        require(AudioCatalog.enclosingApplication(executablePath: helperExecutable)?.bundleIdentifier == "example.scan", "Nested helper belongs to physical outer app")
        require(AudioCatalog.isApplicationExecutable(executablePath: helperExecutable), "Nested app's exact declared executable qualifies while idle")
        require(AudioCatalog.isApplicationExecutable(executablePath: outer.appendingPathComponent("Contents/MacOS/test").path),
                "Main app's exact declared executable qualifies while idle")
        let standalone = outer.appendingPathComponent("Contents/Resources/native/input-meter")
        try FileManager.default.createDirectory(at: standalone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("standalone fixture".utf8).write(to: standalone)
        require(!AudioCatalog.isApplicationExecutable(executablePath: standalone.path),
                "A standalone tool inside Resources is not the containing app's declared executable")
        require(AudioCatalog.enclosingApplication(executablePath: standalone.path)?.bundleIdentifier == "example.scan",
                "A standalone tool retains exact outer ownership even when ineligible for playback")
        let nestedHelper = P(pid: 31, bundleID: AudioCatalog.enclosingApplication(executablePath: helperExecutable)!.bundleIdentifier!,
            name: "Example", outputDevices: [], isApplicationExecutable: AudioCatalog.isApplicationExecutable(executablePath: helperExecutable))
        let standaloneOutput = P(pid: 32, bundleID: AudioCatalog.enclosingApplication(executablePath: standalone.path)!.bundleIdentifier!,
            name: "Example", outputDevices: [40], isApplicationExecutable: AudioCatalog.isApplicationExecutable(executablePath: standalone.path))
        let standaloneUnknown = P(pid: 33, bundleID: standaloneOutput.bundleID, name: "Example", outputDevices: nil,
            isApplicationExecutable: AudioCatalog.isApplicationExecutable(executablePath: standalone.path))
        let structural = AudioCatalog.outputApplications([nestedHelper, standaloneOutput, standaloneUnknown])
        require(Set(structural.keys) == ["example.scan"] && structural["example.scan"]?.pids == [31, 32],
                "Idle packaged helper and verified standalone output group under exact outer app; unknown standalone is excluded")
        let alias = root.appendingPathComponent("helper-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: helperExecutable))
        require(AudioCatalog.isApplicationExecutable(executablePath: alias.path) &&
                AudioCatalog.enclosingApplication(executablePath: alias.path)?.bundleIdentifier == "example.scan",
                "Executable and ownership checks use the same canonical physical paths")
        require(AudioCatalog.enclosingApplication(executablePath: root.appendingPathComponent("SharedWebKitHelper").path) == nil, "Unowned shared helper is never assigned by name")
        print("PASS catalog: physical defaults, exact app/executable identity, idle app eligibility, standalone output evidence, bounded discovery; no audio capture or defaults changed")
    }
}
