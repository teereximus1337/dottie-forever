import Foundation
import CoreFoundation

enum GraphConfiguration {
    static let maxApps = 8
    static func fail(_ message: String) -> RuntimeFailure { .message(message) }
    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func identifier(_ value: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= 255 &&
            value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    static func legacy(_ settings: [String: Any]) -> [String: Any] {
        let app = settings["discord_bundle"] as? String ?? ""
        return ["version": 1, "mic": ["mode": "device", "uid": settings["mic_uid"] as? String ?? ""],
                "assistant": ["bundle_id": settings["dot_bundle"] as? String ?? ""],
                "apps": app.isEmpty ? [] : [["bundle_id": app]],
                "routes": ["mic_to_apps": true, "mic_to_assistant": true, "assistant_to_apps": true, "apps_to_assistant": app.isEmpty ? [] : [app]],
                "positions": [String: Any](), "output": ["mode": "system"],
                "voice_detection": settings["voice_detection"] as? Bool ?? true]
    }
    static func validate(_ value: [String: Any], complete: Bool = true) throws -> [String: Any] {
        guard let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let mic = value["mic"] as? [String: Any], let mode = mic["mode"] as? String, ["default", "device"].contains(mode),
              let assistant = value["assistant"] as? [String: Any], let assistantID = assistant["bundle_id"] as? String,
              let apps = value["apps"] as? [[String: Any]], apps.count <= maxApps,
              let routes = value["routes"] as? [String: Any],
              let micApps = bool(routes["mic_to_apps"]), let micAI = bool(routes["mic_to_assistant"]), let aiApps = bool(routes["assistant_to_apps"]),
              let toAI = routes["apps_to_assistant"] as? [String],
              let output = value["output"] as? [String: Any], output["mode"] as? String == "system",
              let voice = bool(value["voice_detection"]) else { throw fail("The canvas configuration is invalid or uses an unsupported version.") }
        let uid = mic["uid"] as? String ?? ""
        guard uid.utf8.count <= 1024, identifier(assistantID, allowEmpty: !complete),
              !complete || (!assistantID.isEmpty && (mode == "default" || !uid.isEmpty)) else { throw fail("Choose a microphone and an assistant app before starting.") }
        var ids = Set<String>()
        for app in apps {
            guard let id = app["bundle_id"] as? String, identifier(id), id != assistantID, ids.insert(id).inserted else {
                throw fail("Choose distinct apps. The assistant cannot return its own audio to itself.")
            }
        }
        guard Set(toAI).count == toAI.count, Set(toAI).isSubset(of: ids) else { throw fail("An audio connection refers to an unavailable app node.") }
        var positions: [String: Any] = [:]
        if let raw = value["positions"] as? [String: Any] {
            guard raw.count <= 32 else { throw fail("Too many canvas positions.") }
            for (id, item) in raw {
                guard id.utf8.count <= 600, let point = item as? [String: Any], let x = point["x"] as? Double, let y = point["y"] as? Double,
                      x.isFinite, y.isFinite, abs(x) <= 100000, abs(y) <= 100000 else { throw fail("A canvas position is invalid.") }
                positions[id] = ["x": x, "y": y]
            }
        }
        return ["version": 1, "mic": ["mode": mode, "uid": uid], "assistant": ["bundle_id": assistantID],
                "apps": apps.map { ["bundle_id": $0["bundle_id"] as! String] },
                "routes": ["mic_to_apps": micApps, "mic_to_assistant": micAI, "assistant_to_apps": aiApps, "apps_to_assistant": toAI],
                "positions": positions, "output": ["mode": "system"], "voice_detection": voice]
    }
    static func resolve(_ value: [String: Any], catalog: [String: Any], revision: String) throws -> (uid: String, assistantPIDs: [Int32], json: String, identity: String) {
        let graph = try validate(value)
        let mic = graph["mic"] as! [String: String]
        let defaults = catalog["defaults"] as? [String: String] ?? [:]
        let uid = mic["mode"] == "default" ? defaults["input_uid"] ?? "" : mic["uid"] ?? ""
        guard !uid.isEmpty, let inputs = catalog["inputs"] as? [[String: Any]], inputs.filter({ $0["uid"] as? String == uid }).count == 1 else {
            throw fail(mic["mode"] == "default" ? "The system default is not an available physical microphone. Choose a physical input in macOS or pin one here." : "The selected microphone is unavailable. Reconnect it or choose another input.")
        }
        let assistantID = (graph["assistant"] as! [String: String])["bundle_id"]!
        let catalogApps = catalog["apps"] as? [[String: Any]] ?? []
        func pids(_ id: String) -> [Int32] { (catalogApps.first { $0["bundle_id"] as? String == id }?["pids"] as? [Int32] ?? []).sorted() }
        let assistantPIDs = pids(assistantID)
        guard !assistantPIDs.isEmpty, assistantPIDs.count <= 16 else { throw fail("Open the selected assistant’s audio session, then refresh sources.") }
        var used = Set(assistantPIDs), resolved: [[String: Any]] = [], identity = uid + "|" + assistantID + ":" + assistantPIDs.map(String.init).joined(separator: ",")
        let routes = graph["routes"] as! [String: Any], required = Set(routes["apps_to_assistant"] as! [String])
        for app in graph["apps"] as! [[String: String]] {
            let id = app["bundle_id"]!
            guard required.contains(id) else { continue }
            let selected = pids(id)
            if selected.isEmpty {
                throw fail("Open \(catalogApps.first { $0["bundle_id"] as? String == id }?["name"] as? String ?? id) to make its connected audio source available.")
            }
            guard selected.count <= 16, Set(selected).count == selected.count, used.isDisjoint(with: selected) else { throw fail("Selected apps have overlapping or excessive audio processes.") }
            used.formUnion(selected); resolved.append(["bundle_id": id, "pids": selected])
            identity += "|" + id + ":" + selected.map(String.init).joined(separator: ",")
        }
        let native: [String: Any] = ["version": 1, "revision": revision, "apps": resolved, "routes": routes]
        let data = try JSONSerialization.data(withJSONObject: native, options: [.sortedKeys])
        guard data.count <= 16384 else { throw fail("The audio graph is too large.") }
        return (uid, assistantPIDs, String(decoding: data, as: UTF8.self), identity)
    }
}
