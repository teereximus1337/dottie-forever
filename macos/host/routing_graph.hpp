#pragma once
#include "../../native/router_core.hpp"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <climits>
#include <cmath>
#include <set>
#include <string>
#include <vector>

namespace audio_router::host {
constexpr std::size_t kMaximumApps = 8;
struct AppSource {
    std::string bundle_id;
    std::vector<pid_t> pids;
    bool to_assistant = false;
};
struct RoutingGraph {
    bool enabled = false;
    std::string revision;
    std::vector<AppSource> apps;
    audio_router::Routing routes;
};
inline bool graph_text(id value, std::size_t maximum) {
    return [value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 0 &&
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
inline bool parse_graph(const std::string& json, RoutingGraph& output) {
    if (json.empty() || json.size() > 16384) return false;
    NSData* data = [NSData dataWithBytes:json.data() length:json.size()];
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
    if (![value isKindOfClass:NSDictionary.class] || [value count] != 4) return false;
    NSDictionary* root = value;
    id version = root[@"version"];
    if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        [version doubleValue] != 1 || !graph_text(root[@"revision"],128)) return false;
    id apps = root[@"apps"], routes = root[@"routes"];
    if (![apps isKindOfClass:NSArray.class] || [apps count] > kMaximumApps ||
        ![routes isKindOfClass:NSDictionary.class] || [routes count] != 4) return false;
    for (NSString* key in @[@"mic_to_apps", @"mic_to_assistant", @"assistant_to_apps"]) {
        id flag = routes[key];
        if (!flag || CFGetTypeID((__bridge CFTypeRef)flag) != CFBooleanGetTypeID()) return false;
    }
    id connected = routes[@"apps_to_assistant"];
    if (![connected isKindOfClass:NSArray.class] || [connected count] > kMaximumApps) return false;
    RoutingGraph graph;
    graph.enabled = true; graph.revision = [root[@"revision"] UTF8String];
    graph.routes = {[routes[@"mic_to_apps"] boolValue], [routes[@"mic_to_assistant"] boolValue], [routes[@"assistant_to_apps"] boolValue]};
    std::set<std::string> bundles, selected;
    std::set<pid_t> pids;
    for (id entry in apps) {
        if (![entry isKindOfClass:NSDictionary.class] || [entry count] != 2 || !graph_text(entry[@"bundle_id"],255)) return false;
        id processes = entry[@"pids"];
        if (![processes isKindOfClass:NSArray.class] || [processes count] == 0 || [processes count] > 16) return false;
        AppSource app; app.bundle_id = [entry[@"bundle_id"] UTF8String];
        if (!bundles.insert(app.bundle_id).second) return false;
        for (id process in processes) {
            if (![process isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)process) == CFBooleanGetTypeID()) return false;
            const double number = [process doubleValue];
            if (!std::isfinite(number) || number < 1 || number > INT_MAX || std::floor(number) != number) return false;
            const auto pid = static_cast<pid_t>(number);
            if (!pids.insert(pid).second) return false;
            app.pids.push_back(pid);
        }
        graph.apps.push_back(std::move(app));
    }
    for (id bundle in connected) {
        if (!graph_text(bundle,255)) return false;
        const std::string name = [bundle UTF8String];
        if (!bundles.count(name) || !selected.insert(name).second) return false;
    }
    for (auto& app : graph.apps) app.to_assistant = selected.count(app.bundle_id) != 0;
    output = std::move(graph);
    return true;
}
} // namespace audio_router::host
