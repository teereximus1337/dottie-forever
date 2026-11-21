import Foundation
import AppKit
import CoreAudio
import Darwin

enum AudioCatalog {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func objects(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> [AudioObjectID] {
        objectList(object, property) ?? []
    }
    static func objectList(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) -> [AudioObjectID]? {
        var property = property
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &bytes) == noErr,
              bytes <= 65536, bytes % 4 == 0 else { return nil }
        guard bytes > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(bytes) / 4)
        let result = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, $0.baseAddress!) }
        guard result == noErr, bytes % 4 == 0, Int(bytes) <= values.count * 4 else { return nil }
        return Array(values.prefix(Int(bytes) / 4))
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector), value: UInt32 = 0, bytes: UInt32 = 4
        guard AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &value) == noErr, bytes == 4 else { return nil }
        return value
    }
    static func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN in the public SDK;
        // the compound macro itself is not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let bytes = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard bytes > 0 else { return nil }
        return String(cString: path)
    }
    static func enclosingApplication(executablePath: String) -> Bundle? {
        // Resolve the kernel-reported executable to its physical outer app.
        // Shared system helpers are not assigned by names or bundle prefixes.
        let path = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL.path
        guard let boundary = path.range(of: ".app/") else { return nil }
        let outer = URL(fileURLWithPath: String(path[..<boundary.lowerBound]) + ".app")
        guard let bundle = Bundle(url: outer), let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        return bundle
    }
    static func isApplicationExecutable(executablePath: String) -> Bool {
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
        var container = executable.deletingLastPathComponent()
        while container.path != "/" {
            if container.pathExtension == "app", let bundle = Bundle(url: container),
               bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
               let declared = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
               declared == executable { return true }
            container.deleteLastPathComponent()
        }
        return false
    }
    static func applicationName(_ bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    }
    struct Device {
        let id: AudioObjectID
        let uid: String
        let name: String
        let transport: UInt32
        let input: Bool
        let output: Bool
        var value: [String: Any] { ["uid": uid, "name": name] }
    }
    struct Application {
        let bundleID: String
        var name: String
        var installed = false
        var running = false
        var pids = Set<Int32>()
        var value: [String: Any] {
            ["bundle_id": bundleID, "name": name, "installed": installed,
             "running": running, "audio_available": !pids.isEmpty, "pids": pids.sorted()]
        }
    }
    struct ApplicationProcess {
        let pid: Int32
        let bundleID: String
        let name: String
        let outputDevices: [AudioObjectID]?
        var isApplicationExecutable = false
    }
    static func outputApplications(_ processes: [ApplicationProcess]) -> [String: Application] {
        var groups: [String: Application] = [:]
        for process in processes {
            // App and nested-helper executables can be idle with no devices
            // associated yet. Standalone tools inside the app need actual
            // output association; directory ownership alone must not add an
            // input-only meter to the playback allowlist. Neither path uses
            // instantaneous IsRunningOutput or executable-name patterns.
            let hasOutput = process.outputDevices.map {
                !$0.isEmpty && $0.allSatisfy({ $0 != kAudioObjectUnknown })
            } ?? false
            guard process.pid > 0, !process.bundleID.isEmpty, !isRouterIdentity(process.bundleID),
                  process.isApplicationExecutable || hasOutput else { continue }
            var app = groups[process.bundleID] ?? Application(bundleID: process.bundleID,
                name: process.name, installed: true, running: true)
            app.pids.insert(process.pid)
            groups[process.bundleID] = app
        }
        return groups
    }
    // Installed applications do not need a disk scan on every audio identity
    // check. The cache is protected independently from controller/telemetry work.
    private final class InstalledCache: @unchecked Sendable {
        private let lock = NSLock()
        private var refreshed: TimeInterval = -.infinity
        private var cached: [String: Application] = [:]
        func applications(refresh: Bool) -> [String: Application] {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if !refresh && now - refreshed < 60 {
                let result = cached; lock.unlock(); return result
            }
            lock.unlock()
            let root = FileManager.default.homeDirectoryForCurrentUser
            let result = scanInstalledApplications(in: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                root.appendingPathComponent("Applications", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
            ])
            lock.lock()
            if now >= refreshed { cached = result; refreshed = now }
            let current = cached; lock.unlock(); return current
        }
    }
    private static let installedCache = InstalledCache()
    static func isRouterIdentity(_ identity: String) -> Bool {
        identity.hasPrefix("private.audio.router.") || identity.hasPrefix("ai.agentsofchange.router.")
    }
    static func physicalDevices(_ devices: [Device], input: Bool) -> [Device] {
        var transports: Set<UInt32> = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeThunderbolt]
        if !input {
            // Output devices are observed only. The router does not render a
            // second headphone feed or change the system's default selection.
            transports.formUnion([kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                                  kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeAVB])
        }
        return devices.filter {
            !isRouterIdentity($0.uid) && transports.contains($0.transport) && (input ? $0.input : $0.output)
        }.sorted { $0.name == $1.name ? $0.uid < $1.uid : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func defaultUID(_ id: AudioObjectID?, from devices: [Device]) -> String {
        guard let id, id != kAudioObjectUnknown,
              let match = devices.first(where: { $0.id == id }),
              devices.filter({ $0.uid == match.uid }).count == 1 else { return "" }
        return match.uid
    }
    static func scanInstalledApplications(in roots: [URL], maximumEntriesPerRoot: Int = 1024) -> [String: Application] {
        var result: [String: Application] = [:]
        guard maximumEntriesPerRoot > 0 else { return result }
        for root in roots.prefix(8) {
            // One level per explicitly named root. Never recursively descend
            // into .app bundles, arbitrary user folders, or packages.
            guard let entries = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }) else { continue }
            var visited = 0
            while visited < min(maximumEntriesPerRoot, 4096), let url = entries.nextObject() as? URL {
                visited += 1
                guard url.pathExtension.lowercased() == "app",
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let bundle = Bundle(url: url.resolvingSymlinksInPath()),
                      bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                      let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
                      !isRouterIdentity(identifier), result[identifier] == nil else { continue }
                result[identifier] = Application(bundleID: identifier, name: applicationName(bundle), installed: true)
            }
        }
        return result
    }
    static func mergedApplications(_ sets: [[String: Application]]) -> [String: Application] {
        var result: [String: Application] = [:]
        for set in sets {
            for (identifier, app) in set where !isRouterIdentity(identifier) {
                var merged = result[identifier] ?? app
                // A running application's physical bundle is authoritative if
                // another installed version has the same bundle identifier.
                if app.running { merged.name = app.name }
                merged.installed = merged.installed || app.installed
                merged.running = merged.running || app.running
                merged.pids.formUnion(app.pids.filter { $0 > 0 })
                result[identifier] = merged
            }
        }
        return result
    }
    static func snapshot(includeInstalled: Bool = true, refreshInstalled: Bool = false) -> [String: Any] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = objects(system, address(kAudioHardwarePropertyDevices))
        let devices = deviceIDs.compactMap { device -> Device? in
            guard let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName),
                  let transport = number(device, kAudioDevicePropertyTransportType),
                  number(device, kAudioDevicePropertyDeviceIsAlive) == 1 else { return nil }
            return Device(id: device, uid: uid, name: name, transport: transport,
                input: !objects(device, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)).isEmpty,
                output: !objects(device, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)).isEmpty)
        }
        let inputs = physicalDevices(devices, input: true)
        let outputs = physicalDevices(devices, input: false)
        let defaultInputID = number(system, kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutputID = number(system, kAudioHardwarePropertyDefaultOutputDevice)
        let defaults: [String: Any] = [
            "input_uid": defaultUID(defaultInputID, from: inputs),
            "output_uid": defaultUID(defaultOutputID, from: outputs),
            // Preserve the visible system choice even when it cannot be used
            // as a physical source (for example, a router virtual input).
            "input_name": devices.first(where: { $0.id == defaultInputID })?.name ?? "",
            "output_name": devices.first(where: { $0.id == defaultOutputID })?.name ?? ""
        ]
        let endpoints: [[String: Any]] = devices.filter { isRouterIdentity($0.uid) }
            .map { ["id": $0.id, "uid": $0.uid, "name": $0.name] }
        var audioProcesses: [ApplicationProcess] = []
        if #available(macOS 14.2, *) {
            for process in objects(system, address(kAudioHardwarePropertyProcessObjectList)) {
                guard let pidValue = number(process, kAudioProcessPropertyPID), pidValue > 0 else { continue }
                let pid = Int32(bitPattern: pidValue)
                guard pid > 0, let path = executablePath(pid),
                      let owner = enclosingApplication(executablePath: path),
                      let identifier = owner.bundleIdentifier, !isRouterIdentity(identifier) else { continue }
                // Only kernel-reported executables within the exact enclosing
                // physical app are grouped; shared WebKit/system helpers do
                // not acquire an app identity from a name or substring.
                let outputDevices = objectList(process,
                    address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput))
                audioProcesses.append(ApplicationProcess(pid: pid, bundleID: identifier,
                    name: applicationName(owner), outputDevices: outputDevices,
                    isApplicationExecutable: isApplicationExecutable(executablePath: path)))
            }
        }
        let audioApps = outputApplications(audioProcesses)
        var groups = audioApps
        if includeInstalled {
            var runningApps: [String: Application] = [:]
            // Apple explicitly permits reading runningApplications on any
            // thread. Its snapshot updates as the main run loop progresses.
            for app in NSWorkspace.shared.runningApplications.prefix(1024) where !app.isTerminated {
                guard let path = executablePath(app.processIdentifier),
                      let owner = enclosingApplication(executablePath: path),
                      let identifier = owner.bundleIdentifier, !isRouterIdentity(identifier) else { continue }
                runningApps[identifier] = Application(bundleID: identifier,
                    name: applicationName(owner), installed: true, running: true)
            }
            groups = mergedApplications([installedCache.applications(refresh: refreshInstalled), runningApps, audioApps])
        }
        let apps = groups.values.sorted {
            $0.name == $1.name ? $0.bundleID < $1.bundleID : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { $0.value }
        return ["inputs": inputs.map { $0.value }, "outputs": outputs.map { $0.value },
                "defaults": defaults, "apps": apps, "endpoints": endpoints]
    }
}
