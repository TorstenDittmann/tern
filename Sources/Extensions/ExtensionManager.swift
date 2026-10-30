import AppKit
import WebKit

/// Finds and runs web extensions through WebKit's public WKWebExtension API (macOS 15.4+).
///
/// Sources:
/// - Safari Web Extensions installed with apps (`*.app/Contents/PlugIns/*.appex` whose extension point is
///   `com.apple.Safari.web-extension`). Their JS/HTML runs here unchanged; their native `SafariWebExtensionHandler`
///   doesn't, because only Safari can talk to it (no `runtime.sendNativeMessage`).
/// - Unpacked folders or .zip files (Chrome/Firefox-style MV2/MV3), loaded in place, so editing them is live.
///
/// Nothing is enabled by default: every background page costs memory.
@MainActor
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()
    /// Posted when an extension is found, turned on or turned off.
    static let didChange = Notification.Name("TernExtensionsDidChange")

    struct Available: Sendable {
        enum Source: Sendable { case safari(appex: URL, app: String), unpacked(URL) }
        let id: String
        let name: String
        let source: Source
    }

    private(set) var available: [Available] = []
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var controller: WKWebExtensionController { BrowserEngine.shared.extensionController }

    var loadedContexts: [WKWebExtensionContext] {
        contexts.values.sorted { ($0.webExtension.displayName ?? "") < ($1.webExtension.displayName ?? "") }
    }

    let unpackedFolder: URL = {
        let url = AppPaths.support.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let defaults = UserDefaults.tern
    private var enabledIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "enabledExtensions") ?? []) }
        set { defaults.set(Array(newValue), forKey: "enabledExtensions") }
    }
    private var unpackedPaths: [String] {
        get { defaults.stringArray(forKey: "unpackedExtensionPaths") ?? [] }
        set { defaults.set(newValue, forKey: "unpackedExtensionPaths") }
    }

    func isEnabled(_ item: Available) -> Bool { contexts[item.id] != nil }
    func context(for item: Available) -> WKWebExtensionContext? { contexts[item.id] }

    func start() {
        controller.delegate = self
        Task { await refresh() }
    }

    /// Scans off the main thread, then loads whatever the user had enabled.
    func refresh() async {
        let folder = unpackedFolder, paths = unpackedPaths
        let found = await Task.detached(priority: .utility) { Self.scan(folder: folder, extraPaths: paths) }.value
        available = found
        // Smoke tests and benchmarks stay isolated from the user's own extensions.
        for item in found where enabledIDs.contains(item.id) && contexts[item.id] == nil && !SmokeTest.isRunning && !Metrics.isBenchmark {
            await load(item)
        }
        AppDelegate.shared.extensionsDidChange()
    }

    // MARK: Enable / disable

    func toggle(_ item: Available) {
        if let ctx = contexts.removeValue(forKey: item.id) {
            try? controller.unload(ctx)
            enabledIDs.remove(item.id)
            AppDelegate.shared.extensionsDidChange()
            return
        }
        Task {
            guard let ext = try? await Self.makeExtension(item) else {
                return Self.alert("Couldn't load “\(item.name)”.", detail: "Its manifest is missing or invalid.")
            }
            guard Self.confirmPermissions(for: ext, name: item.name) else { return }
            enabledIDs.insert(item.id)
            await load(item, preloaded: ext)
            AppDelegate.shared.extensionsDidChange()
        }
    }

    func promptLoadUnpacked() {
        let panel = NSOpenPanel()
        panel.message = "Choose an extension folder (with manifest.json) or a .zip"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !unpackedPaths.contains(url.path) { unpackedPaths.append(url.path) }
        let item = Available(id: Self.unpackedID(url), name: Self.manifestName(at: url) ?? url.lastPathComponent, source: .unpacked(url))
        Task {
            await refresh()
            if contexts[item.id] == nil { toggle(item) }
        }
    }

    func removeUnpacked(_ item: Available) {
        guard case .unpacked(let url) = item.source else { return }
        if contexts[item.id] != nil { toggle(item) }
        unpackedPaths.removeAll { $0 == url.path }
        Task { await refresh() }
    }

    /// Loads an unpacked extension without remembering it (smoke test only).
    func loadForSmokeTest(_ url: URL) async -> WKWebExtensionContext? {
        let item = Available(id: "smoke:" + url.path, name: "Smoke", source: .unpacked(url))
        await load(item)
        AppDelegate.shared.extensionsDidChange()
        return contexts[item.id]
    }

    /// Lets extensions' `commands` (manifest keyboard shortcuts) fire.
    func performCommand(for event: NSEvent) -> Bool {
        for ctx in contexts.values where ctx.performCommand(for: event) { return true }
        return false
    }

    // MARK: Loading

    private func load(_ item: Available, preloaded: WKWebExtension? = nil) async {
        do {
            let ext: WKWebExtension
            if let preloaded { ext = preloaded } else { ext = try await Self.makeExtension(item) }
            let ctx = WKWebExtensionContext(for: ext)
            // A stable identifier keeps the extension's storage (and its webkit-extension:// origin) across launches.
            let uuid = stableUUID(for: item.id)
            ctx.uniqueIdentifier = uuid
            ctx.isInspectable = true
            ctx.inspectionName = item.name
            // The user turned it on after seeing the permission list, so grant what the manifest asks for.
            for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
            for m in ext.requestedPermissionMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
            try controller.load(ctx)
            contexts[item.id] = ctx
            for error in ext.errors { NSLog("Tern extension \(item.name): \(error.localizedDescription)") }
        } catch {
            NSLog("Tern: failed to load extension \(item.name): \(error)")
        }
    }

    private static func makeExtension(_ item: Available) async throws -> WKWebExtension {
        switch item.source {
        case .safari(let appex, _):
            guard let bundle = Bundle(url: appex) else { throw CocoaError(.fileReadCorruptFile) }
            return try await WKWebExtension(appExtensionBundle: bundle)
        case .unpacked(let url):
            return try await WKWebExtension(resourceBaseURL: url)
        }
    }

    private func stableUUID(for id: String) -> String {
        var map = defaults.dictionary(forKey: "extensionUUIDs") as? [String: String] ?? [:]
        if let existing = map[id] { return existing }
        let uuid = UUID().uuidString
        map[id] = uuid
        defaults.set(map, forKey: "extensionUUIDs")
        return uuid
    }

    // MARK: Discovery (runs off the main thread)

    nonisolated private static func scan(folder: URL, extraPaths: [String]) -> [Available] {
        let fm = FileManager.default
        var result: [Available] = []

        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let apps = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for app in apps where app.hasSuffix(".app") {
                let plugins = URL(fileURLWithPath: dir).appendingPathComponent(app).appendingPathComponent("Contents/PlugIns")
                guard let appexes = try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { continue }
                for appex in appexes where appex.pathExtension == "appex" {
                    guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                          let point = info["NSExtension"] as? [String: Any],
                          point["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension",
                          let bundleID = info["CFBundleIdentifier"] as? String else { continue }
                    let appName = (app as NSString).deletingPathExtension
                    let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? appName
                    result.append(Available(id: bundleID, name: name, source: .safari(appex: appex, app: appName)))
                }
            }
        }

        let dropped = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for url in dropped + extraPaths.map(URL.init(fileURLWithPath:)) {
            let isZip = url.pathExtension == "zip"
            guard isZip || fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { continue }
            let name = manifestName(at: url) ?? url.deletingPathExtension().lastPathComponent
            result.append(Available(id: unpackedID(url), name: name, source: .unpacked(url)))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func unpackedID(_ url: URL) -> String { "unpacked:" + url.standardizedFileURL.path }

    nonisolated private static func manifestName(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.hasPrefix("__MSG_") else { return nil }
        return name
    }

    // MARK: UI helpers

    private static func confirmPermissions(for ext: WKWebExtension, name: String) -> Bool {
        let perms = ext.requestedPermissions.map(\.rawValue).sorted()
        let hosts = ext.requestedPermissionMatchPatterns.map(\.description).sorted()
        let alert = NSAlert()
        alert.messageText = "Turn on “\(name)”?"
        var lines: [String] = []
        if !perms.isEmpty { lines.append("Permissions: " + perms.joined(separator: ", ")) }
        if !hosts.isEmpty { lines.append("Sites: " + hosts.prefix(8).joined(separator: ", ") + (hosts.count > 8 ? " …" : "")) }
        alert.informativeText = lines.isEmpty ? "This extension requests no special permissions." : lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func alert(_ message: String, detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.runModal()
    }

    fileprivate static func ask(_ ctx: WKWebExtensionContext, _ what: [String]) -> Bool {
        guard !what.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "“\(ctx.webExtension.displayName ?? "An extension")” wants additional access"
        a.informativeText = what.sorted().joined(separator: "\n")
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don’t Allow")
        return a.runModal() == .alertFirstButtonReturn
    }

    fileprivate static func unsupported(_ what: String) -> NSError {
        NSError(domain: "dev.tern.extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: what])
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension ExtensionManager {
    /// The windows extensions can see: every one but private windows.
    static var windowsForExtensions: [BrowserWindowController] { AppDelegate.shared.windows.filter { !$0.isPrivate } }

    /// Where an extension's new tabs go: the key window unless it's private, else the last normal one, else a new one.
    static var browserForExtensions: BrowserWindowController {
        if let key = AppDelegate.shared.keyBrowser, !key.isPrivate { return key }
        return windowsForExtensions.last ?? AppDelegate.shared.openWindow()
    }
}

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        Self.windowsForExtensions
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        AppDelegate.shared.keyBrowser.flatMap { $0.isPrivate ? nil : $0 }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        let browser = (configuration.window as? BrowserWindowController).flatMap { $0.isPrivate ? nil : $0 } ?? Self.browserForExtensions
        let tab = Tab(url: configuration.url)
        browser.insert(tab, at: configuration.index, activate: configuration.shouldBeActive)
        completionHandler(tab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        let tabs = configuration.tabURLs.map { Tab(url: $0) }
        let frame = configuration.frame.isNull || configuration.frame.isEmpty ? nil : configuration.frame
        let window = AppDelegate.shared.openWindow(restoring: tabs, active: 0, frame: frame, sidebarCollapsed: false)
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let url = extensionContext.optionsPageURL else {
            return completionHandler(ExtensionManager.unsupported("This extension has no options page."))
        }
        Self.browserForExtensions.newTab(url: url)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let ok = ExtensionManager.ask(extensionContext, permissions.map(\.rawValue))
        completionHandler(ok ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let ok = ExtensionManager.ask(extensionContext, urls.compactMap(\.host))
        completionHandler(ok ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let ok = ExtensionManager.ask(extensionContext, matchPatterns.map(\.description))
        completionHandler(ok ? matchPatterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        AppDelegate.shared.windows.forEach { $0.sidebar.updateExtensionActions() }
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover,
              let browser = (action.associatedTab as? Tab)?.owner ?? AppDelegate.shared.keyBrowser else {
            return completionHandler(ExtensionManager.unsupported("No popup to show."))
        }
        if !browser.isSidebarCollapsed, let button = browser.sidebar.actionButton(for: context), button.window != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else {
            let v = browser.content.view
            popover.show(relativeTo: NSRect(x: v.bounds.maxX - 40, y: v.bounds.maxY - 30, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        replyHandler(nil, ExtensionManager.unsupported("Native messaging isn't available outside Safari."))
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(ExtensionManager.unsupported("Native messaging isn't available outside Safari."))
    }
}
