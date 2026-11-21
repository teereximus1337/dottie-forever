import Foundation

@main struct ProductProfileTests {
    static func rejects(_ work: () throws -> Void) {
        do { try work(); fatalError("Expected profile rejection") } catch {}
    }
    static func main() throws {
        let discord = ProductProfile.discordBundleID, assistant = ProductProfile.chatGPTBundleID
        let legacy: [String: Any] = ["mic_uid": "physical-mic", "dot_bundle": "old.assistant", "discord_bundle": discord, "voice_detection": false]
        let migrated = ProductProfile.sanitizedGraph(from: legacy)
        let accepted = try ProductProfile.validate(migrated)
        precondition((accepted["assistant"] as? [String: String])?["bundle_id"] == assistant)
        precondition((accepted["mic"] as? [String: String])?["uid"] == "physical-mic")
        precondition((accepted["apps"] as? [[String: String]]) == [["bundle_id": discord]])
        precondition((accepted["routes"] as? [String: Any])?["apps_to_assistant"] as? [String] == [discord])
        precondition(accepted["voice_detection"] as? Bool == false)

        var oldGraph = migrated
        oldGraph["assistant"] = ["bundle_id": "another.assistant"]
        oldGraph["mic"] = ["mode": "default", "uid": "previous-device"]
        oldGraph["apps"] = [["bundle_id": "com.blizzard.worldofwarcraft"], ["bundle_id": discord], ["bundle_id": discord], ["bundle_id": "another.chat"]]
        oldGraph["routes"] = ["mic_to_apps": false, "mic_to_assistant": true, "assistant_to_apps": false,
                              "apps_to_assistant": ["com.blizzard.worldofwarcraft", discord, "another.chat"]]
        oldGraph["positions"] = ["mic": ["x": 25.0, "y": 60.0], "assistant": ["x": 300.0, "y": 75.0]]
        oldGraph["game_audio"] = ["capture": true]
        let focused = ProductProfile.sanitizedGraph(from: ["graph": oldGraph])
        _ = try ProductProfile.validate(focused)
        precondition(focused["game_audio"] == nil)
        precondition((focused["mic"] as? [String: String]) == ["mode":"default", "uid":"previous-device"])
        precondition((focused["apps"] as? [[String: String]]) == [["bundle_id": discord]])
        precondition((focused["routes"] as? [String: Any])?["apps_to_assistant"] as? [String] == [discord])
        precondition((focused["routes"] as? [String: Any])?["mic_to_apps"] as? Bool == false)
        precondition((focused["routes"] as? [String: Any])?["assistant_to_apps"] as? Bool == false)
        precondition((focused["positions"] as? [String: [String: Double]]) == oldGraph["positions"] as? [String: [String: Double]])

        var solo = focused
        solo["apps"] = [[String: String]]()
        var routes = solo["routes"] as! [String: Any]; routes["apps_to_assistant"] = [String](); solo["routes"] = routes
        let soloMigration = ProductProfile.sanitizedGraph(from: ["graph": solo, "discord_bundle": discord])
        _ = try ProductProfile.validate(soloMigration)
        precondition((soloMigration["apps"] as? [[String: String]])?.isEmpty == true, "Saved graph must not re-enable removed Discord from legacy settings")
        var gameOnly = solo; gameOnly["apps"] = [["bundle_id":"com.blizzard.worldofwarcraft"]]
        let gameRemoved = ProductProfile.sanitizedGraph(from: ["graph": gameOnly])
        precondition((gameRemoved["apps"] as? [[String: String]])?.isEmpty == true)
        var hidden = solo; routes = hidden["routes"] as! [String: Any]
        routes["mic_to_apps"] = true; routes["assistant_to_apps"] = true; hidden["routes"] = routes
        let hiddenRemoved = ProductProfile.sanitizedGraph(from: ["graph": hidden])
        precondition((hiddenRemoved["routes"] as? [String: Any])?["mic_to_apps"] as? Bool == false)
        precondition((hiddenRemoved["routes"] as? [String: Any])?["assistant_to_apps"] as? Bool == false)
        _ = try ProductProfile.validate(hiddenRemoved)
        rejects { _ = try ProductProfile.validate(hidden) }
        routes["assistant_to_apps"] = false; hidden["routes"] = routes
        rejects { _ = try ProductProfile.validate(hidden) }
        routes["mic_to_apps"] = false; routes["assistant_to_apps"] = true; hidden["routes"] = routes
        rejects { _ = try ProductProfile.validate(hidden) }

        var bad = focused; bad["assistant"] = ["bundle_id": "other.ai"]
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; bad["apps"] = [["bundle_id": "com.blizzard.worldofwarcraft"]]
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; bad["apps"] = [["bundle_id": discord], ["bundle_id": discord]]
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; bad["sources"] = [["bundle_id": "com.blizzard.worldofwarcraft"]]
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; bad["mic"] = ["mode":"default", "extra_source":"game"]
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; bad["assistant"] = ["bundle_id": assistant, "pids": [1]]
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; routes = bad["routes"] as! [String: Any]; routes["game_to_assistant"] = true; bad["routes"] = routes
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; routes = bad["routes"] as! [String: Any]; routes["apps_to_assistant"] = ["com.blizzard.worldofwarcraft"]; bad["routes"] = routes
        rejects { _ = try ProductProfile.validate(bad) }
        bad = focused; routes = bad["routes"] as! [String: Any]; routes["mic_to_apps"] = 1; bad["routes"] = routes
        rejects { _ = try ProductProfile.validate(bad) }
        let blank = ProductProfile.sanitizedGraph(from: [:])
        _ = try ProductProfile.validate(blank)
        precondition((blank["mic"] as? [String: String])?["mode"] == "default")
        var incomplete = blank; incomplete["mic"] = ["mode": "device", "uid": ""]
        _ = try ProductProfile.validate(incomplete, complete: false)
        rejects { _ = try ProductProfile.validate(incomplete) }
        print("PASS product scope: fixed ChatGPT, optional Discord, migration retains controls, game/extra sources rejected, draft validation")
    }
}
