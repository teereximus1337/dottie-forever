import Foundation
@main struct GraphConfigurationTests {
    static func rejects(_ work: () throws -> Void) { do { try work(); fatalError("Expected rejection") } catch {} }
    static func main() throws {
        var graph = GraphConfiguration.legacy(["mic_uid":"mic", "dot_bundle":"ai", "discord_bundle":"chat"])
        let catalog: [String: Any] = ["inputs": [["uid":"mic","name":"Mic"],["uid":"other","name":"Other"]], "defaults":["input_uid":"other"], "apps":[["bundle_id":"ai","pids":[Int32(100)]],["bundle_id":"chat","pids":[Int32(200)]]]]
        let pinned = try GraphConfiguration.resolve(graph, catalog: catalog, revision: "r1")
        precondition(pinned.uid == "mic" && pinned.assistantPIDs == [100])
        graph["mic"] = ["mode":"default"]
        let followed = try GraphConfiguration.resolve(graph, catalog: catalog, revision: "r2")
        precondition(followed.uid == "other" && followed.identity != pinned.identity)
        var unavailable = catalog; unavailable["defaults"] = ["input_uid":"router-virtual"]
        rejects { _ = try GraphConfiguration.resolve(graph, catalog: unavailable, revision:"x") }
        var bad = graph; bad["apps"] = [["bundle_id":"ai"]]
        rejects { _ = try GraphConfiguration.validate(bad) }
        bad = graph; bad["apps"] = [["bundle_id":"chat"],["bundle_id":"chat"]]
        rejects { _ = try GraphConfiguration.validate(bad) }
        bad = graph; var routes = bad["routes"] as! [String: Any]; routes["apps_to_assistant"] = ["unknown"]; bad["routes"] = routes
        rejects { _ = try GraphConfiguration.validate(bad) }
        bad = graph; routes = bad["routes"] as! [String: Any]; routes["mic_to_apps"] = 1; bad["routes"] = routes
        rejects { _ = try GraphConfiguration.validate(bad) }
        var overlap = catalog; overlap["apps"] = [["bundle_id":"ai","pids":[Int32(100)]],["bundle_id":"chat","pids":[Int32(100)]]]
        rejects { _ = try GraphConfiguration.resolve(graph, catalog: overlap, revision:"x") }
        var missing = catalog; missing["apps"] = [["bundle_id":"ai","pids":[Int32(100)]]]
        rejects { _ = try GraphConfiguration.resolve(graph, catalog: missing, revision:"x") }
        routes = graph["routes"] as! [String:Any]; routes["apps_to_assistant"] = [String](); graph["routes"] = routes
        let optional = try GraphConfiguration.resolve(graph, catalog: missing, revision:"x")
        precondition(optional.json.contains("\"apps\":[]"))
        bad = graph; bad["positions"] = ["mic":["x":Double.infinity,"y":0]]
        rejects { _ = try GraphConfiguration.validate(bad) }
        var blank = GraphConfiguration.legacy([:]); _ = try GraphConfiguration.validate(blank, complete:false)
        rejects { _ = try GraphConfiguration.validate(blank) }
        blank["version"] = true; rejects { _ = try GraphConfiguration.validate(blank, complete:false) }
        for id in [String(repeating: "a", count: 256), String(repeating: "é", count: 128), "app\nname", "app\u{0}name"] {
            bad = graph; bad["apps"] = [["bundle_id": id]]
            rejects { _ = try GraphConfiguration.validate(bad) }
            bad = graph; bad["assistant"] = ["bundle_id": id]
            rejects { _ = try GraphConfiguration.validate(bad) }
        }
        let maximumID = String(repeating: "é", count: 127) + "a"
        bad = graph; bad["apps"] = [["bundle_id": maximumID]]
        _ = try GraphConfiguration.validate(bad)
        bad = graph; bad["assistant"] = ["bundle_id": maximumID]
        _ = try GraphConfiguration.validate(bad)
        print("PASS graph settings: default/pinned resolution, virtual default rejection, incomplete drafts, source identity, invalid connections, bounds and overlap")
    }
}
