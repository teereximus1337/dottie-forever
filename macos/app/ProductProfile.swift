import Foundation

// Product scope is narrower than the reusable native routing engine. Game
// playback stays on the system output and is never a selectable capture source.
enum ProductProfile {
    static let chatGPTBundleID = "com.openai.codex"
    static let discordBundleID = "com.hnc.Discord"

    static func sanitizedGraph(from settings: [String: Any]) -> [String: Any] {
        let legacy = GraphConfiguration.legacy(settings)
        let source = settings["graph"] as? [String: Any] ?? legacy
        let originalMic = source["mic"] as? [String: Any] ?? legacy["mic"] as! [String: Any]
        let isFreshInput = settings["graph"] == nil && (settings["mic_uid"] as? String ?? "").isEmpty
        let originalMode = isFreshInput ? "default" : originalMic["mode"] as? String ?? "device"
        let mode = ["device", "default"].contains(originalMode) ? originalMode : "device"
        let uid = originalMic["uid"] as? String ?? ""
        let hasDiscord = (source["apps"] as? [[String: Any]] ?? []).contains { $0["bundle_id"] as? String == discordBundleID }
        let originalRoutes = source["routes"] as? [String: Any] ?? legacy["routes"] as! [String: Any]
        let toAssistant = originalRoutes["apps_to_assistant"] as? [String] ?? []
        var positions: [String: Any] = [:]
        for (id, item) in (source["positions"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard positions.count < 32, id.utf8.count <= 600,
                  let point = item as? [String: Any], let x = point["x"] as? Double, let y = point["y"] as? Double,
                  x.isFinite, y.isFinite, abs(x) <= 100000, abs(y) <= 100000 else { continue }
            positions[id] = ["x": x, "y": y]
        }
        return ["version": 1,
                "mic": ["mode": mode, "uid": uid],
                "assistant": ["bundle_id": chatGPTBundleID],
                "apps": hasDiscord ? [["bundle_id": discordBundleID]] : [],
                "routes": ["mic_to_apps": hasDiscord && (GraphConfiguration.bool(originalRoutes["mic_to_apps"]) ?? true),
                           "mic_to_assistant": GraphConfiguration.bool(originalRoutes["mic_to_assistant"]) ?? true,
                           "assistant_to_apps": hasDiscord && (GraphConfiguration.bool(originalRoutes["assistant_to_apps"]) ?? true),
                           "apps_to_assistant": hasDiscord && toAssistant.contains(discordBundleID) ? [discordBundleID] : []],
                "positions": positions, "output": ["mode": "system"],
                "voice_detection": GraphConfiguration.bool(source["voice_detection"]) ?? GraphConfiguration.bool(legacy["voice_detection"]) ?? true]
    }

    static func validate(_ graph: [String: Any], complete: Bool = true) throws -> [String: Any] {
        func only(_ value: [String: Any], _ keys: Set<String>) -> Bool {
            Set(value.keys).isSubset(of: keys)
        }
        guard only(graph, ["version", "mic", "assistant", "apps", "routes", "positions", "output", "voice_detection"]),
              let mic = graph["mic"] as? [String: Any], only(mic, ["mode", "uid"]),
              let assistant = graph["assistant"] as? [String: Any], only(assistant, ["bundle_id"]),
              assistant["bundle_id"] as? String == chatGPTBundleID,
              let apps = graph["apps"] as? [[String: Any]], apps.count <= 1,
              apps.allSatisfy({ only($0, ["bundle_id"]) && $0["bundle_id"] as? String == discordBundleID }),
              let routes = graph["routes"] as? [String: Any],
              only(routes, ["mic_to_apps", "mic_to_assistant", "assistant_to_apps", "apps_to_assistant"]),
              let output = graph["output"] as? [String: Any], only(output, ["mode"]) else {
            throw RuntimeFailure.message("This setup supports ChatGPT and optional Discord voice only. Game audio stays in your headphones and cannot be captured.")
        }
        let validated = try GraphConfiguration.validate(graph, complete: complete)
        if apps.isEmpty && (GraphConfiguration.bool(routes["mic_to_apps"]) == true || GraphConfiguration.bool(routes["assistant_to_apps"]) == true) {
            throw RuntimeFailure.message("Add Discord before connecting microphone or ChatGPT audio to its input.")
        }
        return validated
    }
}
