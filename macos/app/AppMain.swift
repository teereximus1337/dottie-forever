import AppKit
import WebKit
import Foundation
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    var window: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem!
    let runtime = NativeRuntime()
    private let endpointNames = EndpointNameService()
    private var interfaceRecovery = InterfaceRecoveryPolicy()
    private let interfaceCommands = InterfaceCommandFence()
    private var interfaceReload: DispatchWorkItem?
    private var interfaceNavigation: WKNavigation?
    private var terminating = false
    let appName = "Dottie Forever"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let appIcon = Bundle.main.url(forResource: "DottieForever", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if let appIcon { NSApp.applicationIconImage = appIcon }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let menu = NSMenu(), application = NSMenu(title: appName), edit = NSMenu()
        let appItem = NSMenuItem(title: appName, action: nil, keyEquivalent: ""); appItem.submenu = application; menu.addItem(appItem)
        application.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        for (name, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "router")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = appName
        window.minSize = NSSize(width: 800, height: 600)
        window.contentView = webView
        window.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "DottieStatusTemplate", withExtension: "png"),
           let statusIcon = NSImage(contentsOf: url) {
            statusIcon.size = NSSize(width: 18, height: 18)
            statusIcon.isTemplate = true
            statusItem.button?.image = statusIcon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: appName)
        }
        statusItem.button?.toolTip = appName
        statusItem.button?.setAccessibilityLabel(appName)
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Open \(appName)", action: #selector(showWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Put assistant on standby", action: #selector(standby), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Stop routing", action: #selector(stopRouting), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Show event logs", action: #selector(showEventLogs), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit controller (routing continues)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
        loadInterface()
        showWindow()
    }
    @objc func systemWillSleep() {
        runtime.suspendControllerLease()
        runtime.queue.async { self.runtime.willSleep() }
    }
    @objc func systemDidWake() {
        runtime.queue.async { self.runtime.didWake() }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func standby() { runtime.queue.async { _ = try? self.runtime.exchange(["op": "standby"]) } }
    @objc func stopRouting() { runtime.queue.async { _ = try? self.runtime.stopByUser() } }
    @objc func showEventLogs() { _ = openEventLogs() }
    private func openEventLogs() -> Bool {
        // Fixed local directory only. The web page cannot supply a path or URL.
        NSWorkspace.shared.open(runtime.directory)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        terminating = true; interfaceReload?.cancel()
        runtime.events.record(.controllerQuit)
        interfaceCommands.revoke()
        runtime.releaseControllerLease()
        _ = try? runtime.exchange(["op": "standby"])
    }

    private func loadInterface() {
        interfaceCommands.revoke()
        guard !terminating, let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            showInterfaceFailure(); return
        }
        window.contentView = webView
        interfaceNavigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    private func showInterfaceFailure(recovering: Bool = false) {
        guard !terminating else { return }
        let title = NSTextField(labelWithString: recovering ? "Restoring the interface" : "The interface needs to reload")
        title.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        let message = NSTextField(wrappingLabelWithString: recovering
            ? "Waiting for the assistant feed to reach standby before reloading the canvas."
            : "Automatic recovery could not finish. Reload the interface to regain the canvas controls, or stop routing from the menu bar.")
        message.alignment = .center
        let retry = NSButton(title: recovering ? "Stop routing" : "Reload interface", target: self,
                             action: recovering ? #selector(stopRouting) : #selector(retryInterface))
        retry.bezelStyle = .rounded
        let stack = NSStackView(views: [title, message, retry])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 16
        let container = NSView()
        container.appearance = NSAppearance(named: .darkAqua)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
        ])
        window.contentView = container
    }
    @objc private func retryInterface() {
        interfaceRecovery.retryByUser()
        recoverInterface()
    }
    private func recoverInterface() {
        guard !terminating else { return }
        interfaceCommands.revoke()
        interfaceNavigation = nil
        interfaceReload?.cancel(); interfaceReload = nil
        guard let attempt = interfaceRecovery.failed(now: ProcessInfo.processInfo.systemUptime) else {
            runtime.events.record(.rendererRecoveryPaused, reason: .retryLimit)
            runtime.releaseControllerLease()
            showInterfaceFailure(); return
        }
        showInterfaceFailure(recovering: true)
        // Never let a newly loaded page renew before the old interface's
        // standby is confirmed. The native fallback needs no renderer.
        runtime.releaseControllerLease { [weak self] detached in
            guard let self, !self.terminating, self.interfaceRecovery.accepts(attempt.generation) else { return }
            guard detached else {
                self.runtime.events.record(.rendererDetachFailed, reason: .unconfirmedStandby)
                self.showInterfaceFailure(); return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.interfaceRecovery.accepts(attempt.generation) else { return }
                self.loadInterface()
            }
            self.interfaceReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + attempt.delay, execute: work)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !terminating, let navigation, navigation === interfaceNavigation else { return }
        interfaceReload?.cancel(); interfaceReload = nil
        if interfaceRecovery.attempts > 0 { runtime.events.record(.rendererReloaded) }
        interfaceRecovery.loaded(now: ProcessInfo.processInfo.systemUptime)
        interfaceCommands.loaded()
        runtime.maintainControllerLease()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        runtime.events.record(.rendererLost, reason: .processTerminated)
        recoverInterface()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === interfaceNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
        runtime.events.record(.rendererLost, reason: .navigationFailed)
        recoverInterface()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL,
              let root = Bundle.main.resourceURL?.appendingPathComponent("web").standardizedFileURL.path,
              url.standardizedFileURL.path.hasPrefix(root + "/") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let command = message.body as? [String: Any], let operation = command["op"] as? String else {
            replyHandler(nil, "Only the bundled interface can control this app."); return
        }
        let allowed: Set<String> = ["bootstrap", "catalog", "start", "status", "heartbeat", "wake", "standby", "shutdown", "configure", "install", "save_graph", "apply_graph", "diagnostics", "open_event_logs"]
        guard allowed.contains(operation) else { replyHandler(nil, "Unknown controller operation."); return }
        let readOnly = ["status", "bootstrap", "catalog", "diagnostics"].contains(operation)
        let ticket = readOnly ? nil : interfaceCommands.ticket()
        guard readOnly || ticket != nil else {
            replyHandler(["ok": false, "error": ["code": "interface_reloading", "message": "The interface is reloading. Wait for the canvas before changing routing."]], nil)
            return
        }
        if operation == "status" {
            do { replyHandler(try runtime.cachedSnapshot(), nil) }
            catch { replyHandler(["ok": false, "error": ["code": "controller_error", "message": error.localizedDescription]], nil) }
            return
        }
        if operation == "diagnostics" {
            replyHandler(["ok": true, "diagnostics": runtime.eventDiagnostics()], nil)
            return
        }
        if operation == "open_event_logs" {
            if openEventLogs() { replyHandler(["ok": true, "message": "Event logs opened in Finder."], nil) }
            else { replyHandler(["ok": false, "error": ["code": "open_failed", "message": "The event log folder is not available yet."]], nil) }
            return
        }
        if operation == "catalog" || operation == "bootstrap" {
            // App discovery and HAL property reads must not freeze the window.
            DispatchQueue.global(qos: .userInitiated).async {
                var result = AudioCatalog.snapshot(includeInstalled: true, refreshInstalled: operation == "catalog")
                var saved = self.runtime.settings()
                saved["graph"] = ProductProfile.sanitizedGraph(from: saved)
                result["settings"] = saved
                result["apps"] = (result["apps"] as? [[String: Any]] ?? []).filter {
                    [ProductProfile.chatGPTBundleID, ProductProfile.discordBundleID].contains($0["bundle_id"] as? String ?? "")
                }
                result["ok"] = true
                let resources = Bundle.main.resourceURL!
                result["components"] = ["host": FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("bin/audio_router_host").path),
                    "installer": FileManager.default.fileExists(atPath: resources.appendingPathComponent("AudioRouter.driver").path)
                        && FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("bin/audio_router_broker").path)]
                let response = result
                DispatchQueue.main.async { replyHandler(response, nil) }
            }
            return
        }
        if operation == "install" {
            installDriver(replyHandler); return
        }
        runtime.queue.async {
            guard let ticket, self.interfaceCommands.accepts(ticket) else {
                DispatchQueue.main.async {
                    replyHandler(["ok": false, "error": ["code": "interface_reloading", "message": "The interface changed before this action ran. The old action was not applied."]], nil)
                }
                return
            }
            do {
                var result: [String: Any]
                if operation == "start" {
                    let proposed = command["graph"] as? [String: Any] ?? ProductProfile.sanitizedGraph(from: self.runtime.settings())
                    let graph = try ProductProfile.validate(proposed)
                    result = try self.runtime.start(mode: "live", selections: ["graph": graph])
                    if result["ok"] as? Bool == true, let names = result["names"] as? [String: String] {
                        let applied = self.applyEndpointNames(names)
                        result["device_names_applied"] = applied.count == 2 && applied.values.allSatisfy { $0 == noErr }
                        if applied.values.contains(where: { $0 != noErr }) {
                            result["device_name_warning"] = "Routing started; input-name updates are still unconfirmed. Refresh sources before selecting inputs in another app."
                        }
                    }
                } else if operation == "save_graph" {
                    guard let graph = command["graph"] as? [String: Any] else { throw RuntimeFailure.message("Supply the canvas configuration.") }
                    result = try self.runtime.saveGraph(ProductProfile.validate(graph, complete: false))
                } else if operation == "apply_graph" {
                    guard let graph = command["graph"] as? [String: Any] else { throw RuntimeFailure.message("Supply the canvas configuration.") }
                    result = try self.runtime.applyGraph(ProductProfile.validate(graph))
                    let applied = self.applyEndpointNames(result["names"] as? [String: String] ?? [:])
                    if applied.values.contains(where: { $0 != noErr }) { result["device_name_warning"] = "Connections applied; input-name updates are unconfirmed. Refresh sources to check them." }
                } else if operation == "configure" {
                    guard let names = command["names"] as? [String: String], let phrases = command["phrases"] as? [String: String] else {
                        throw RuntimeFailure.message("Supply both input names and both phrases.")
                    }
                    result = try self.runtime.saveVoiceSettings(names: names, phrases: phrases)
                    if result["ok"] as? Bool == true, result["phrase_activation"] as? String != "saved_routing_off" {
                        let applied = self.applyEndpointNames(result["names"] as? [String: String] ?? names)
                        result["device_names_applied"] = applied.count == 2 && applied.values.allSatisfy { $0 == noErr }
                        if applied.values.contains(where: { $0 != noErr }) {
                            result["device_name_warning"] = "Names saved; installed input-name updates are unconfirmed. Refresh sources to check them."
                        }
                    }
                } else if operation == "shutdown" {
                    result = try self.runtime.stopByUser()
                } else if operation == "status" {
                    result = try self.runtime.statusWithRecovery()
                } else {
                    result = try self.runtime.exchange(["op": operation])
                    try self.runtime.persistConfirmedConfig(result)
                }
                if operation != "shutdown" { self.runtime.cacheConfirmedStatus(result) }
                DispatchQueue.main.async { replyHandler(result, nil) }
            } catch {
                DispatchQueue.main.async { replyHandler(["ok": false, "error": ["code": "controller_error", "message": error.localizedDescription]], nil) }
            }
        }
    }
    func applyEndpointNames(_ names: [String: String]) -> [String: OSStatus] {
        endpointNames.apply(names)
    }
    func installDriver(_ reply: @escaping (Any?, String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Install the two virtual inputs?"
        alert.informativeText = "This installs two virtual inputs and a small local audio service, then restarts Core Audio. Current calls and other audio may be interrupted. Your selected audio routes will not be changed. macOS will ask for administrator authorization."
        alert.addButton(withTitle: "Install and restart audio")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { reply(["ok": false, "error": ["code": "cancelled", "message": "Installation cancelled."]], nil); return }
            guard let script = Bundle.main.url(forResource: "install-driver", withExtension: "sh", subdirectory: "bin") else {
                reply(nil, "The driver installer is missing from this build."); return
            }
            let quotedPath = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let shell = "/bin/sh " + quotedPath + " --install"
            let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
                let failure = error?[NSAppleScript.errorMessage] as? String
                DispatchQueue.main.async {
                    if let failure { reply(["ok": false, "error": ["code": "install_failed", "message": failure]], nil) }
                    else { reply(["ok": true, "message": result?.stringValue ?? "Driver installed."], nil) }
                }
            }
        }
    }
}

@main struct AudioRouterMain {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
        withExtendedLifetime(delegate) {}
    }
}
