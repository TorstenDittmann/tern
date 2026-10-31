import AppKit
import Security
import WebKit

/// Finds and runs web extensions through WebKit's public WKWebExtension API (macOS 15.4+).
///
/// Sources:
/// - Safari Web Extensions installed with apps (`*.app/Contents/PlugIns/*.appex` whose extension point is
///   `com.apple.Safari.web-extension`). Their JS/HTML runs here unchanged; native messages go to their
///   `SafariWebExtensionHandler`, which WebKit reaches through the appex when we don't handle them ourselves.
/// - The Chrome Web Store: the store's own package (CRX) is downloaded from Google and unpacked into our support folder.
///   The extension keeps its store ID as `runtime.id`, which sites like Proton's account page message it by.
/// - Unpacked folders or .zip files (Chrome/Firefox-style MV2/MV3), loaded in place, so editing them is live.
///
/// Nothing is enabled by default: every background page costs memory.
@MainActor
final class ExtensionManager: NSObject {
    static let shared = ExtensionManager()
    /// Posted when an extension is found, turned on or turned off.
    static let didChange = Notification.Name("TernExtensionsDidChange")

    struct Available: Sendable {
        enum Source: Sendable { case safari(appex: URL, app: String), store(id: String, folder: URL), unpacked(URL) }
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

    /// One folder per Chrome Web Store extension, named by its store ID.
    var storeFolder: URL { unpackedFolder.appendingPathComponent("Chrome Web Store", isDirectory: true) }
    /// Store IDs being downloaded right now (the address bar's Add button shows progress).
    private(set) var installing: Set<String> = []

    private let defaults = UserDefaults.tern
    private var workerKeepAlive: Timer?
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
        // Errors that come up while running (a background script that throws on startup) would otherwise go unseen.
        NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let ctx = note.object as? WKWebExtensionContext else { return }
                for message in Self.errorMessages(of: ctx) { NSLog("Tern extension \(ctx.webExtension.displayName ?? "?"): \(message)") }
                AppDelegate.shared.extensionsDidChange()
            }
        }
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

    /// Forgets an unpacked extension (its files stay where they are), or deletes a store one.
    func remove(_ item: Available) {
        if contexts[item.id] != nil { toggle(item) }
        switch item.source {
        case .unpacked(let url): unpackedPaths.removeAll { $0 == url.path }
        case .store(_, let folder): try? FileManager.default.removeItem(at: folder)
        case .safari: return
        }
        Task { await refresh() }
    }

    // MARK: Chrome Web Store

    static let chromeWebStoreURL = URL(string: "https://chromewebstore.google.com/category/extensions")

    /// The store ID in an extension's store page: chromewebstore.google.com/detail/<slug>/<id>
    /// (or the older chrome.google.com/webstore/detail/…).
    static func storeID(in url: URL?) -> String? {
        guard let url, url.scheme == "https" else { return nil }
        let parts = url.pathComponents
        let onStore = url.host == "chromewebstore.google.com" || (url.host == "chrome.google.com" && parts.dropFirst().first == "webstore")
        guard onStore, let detail = parts.firstIndex(of: "detail") else { return nil }
        return parts[(detail + 1)...].first(where: isStoreID)
    }

    /// Chrome extension IDs: 32 letters from a to p.
    nonisolated static func isStoreID(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    nonisolated private static func storeItemID(_ storeID: String) -> String { "chrome:" + storeID }

    func storeItem(_ storeID: String) -> Available? { available.first { $0.id == Self.storeItemID(storeID) } }

    /// Downloads the extension (again, which also updates it), then offers to turn it on.
    func installFromStore(_ storeID: String) {
        guard Self.isStoreID(storeID), !installing.contains(storeID) else { return }
        installing.insert(storeID)
        AppDelegate.shared.extensionsDidChange()
        let parent = storeFolder
        Task {
            defer {
                installing.remove(storeID)
                AppDelegate.shared.extensionsDidChange()
            }
            do {
                let staged = try await Self.downloadFromStore(storeID, into: parent)
                // An extension that's on is reloaded from the new files by the refresh below.
                if let ctx = contexts.removeValue(forKey: Self.storeItemID(storeID)) { try? controller.unload(ctx) }
                let destination = parent.appendingPathComponent(storeID, isDirectory: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staged, to: destination)
                await refresh()
                if let item = storeItem(storeID), contexts[item.id] == nil { toggle(item) }
            } catch {
                Self.alert("Couldn't add the extension.", detail: error.localizedDescription)
            }
        }
    }

    /// Fetches the CRX the way Chrome does and unpacks the zip inside it into a new folder in `parent`.
    nonisolated private static func downloadFromStore(_ storeID: String, into parent: URL) async throws -> URL {
        // `x` is itself a query string, so its = and & are escaped.
        let address = "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=\(chromeVersion)"
            + "&acceptformat=crx2,crx3&x=id%3D\(storeID)%26installsource%3Dondemand%26uc"
        guard let url = URL(string: address) else { throw unsupported("Not a Chrome Web Store ID.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let zip = zipPayload(ofCRX: data) else {
            throw unsupported("The Chrome Web Store didn't return this extension. It may have been removed, or be for Chrome OS only.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let work = fm.temporaryDirectory.appendingPathComponent("tern-crx-" + UUID().uuidString)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let archive = work.appendingPathComponent("extension.zip")
            try zip.write(to: archive)
            let unpacked = work.appendingPathComponent("extension", isDirectory: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0, fm.fileExists(atPath: unpacked.appendingPathComponent("manifest.json").path) else {
                throw Self.unsupported("The download isn't a valid extension.")
            }
            // Staged next to its final place, so the move into it is a rename.
            let staged = parent.appendingPathComponent(".\(storeID)-" + UUID().uuidString, isDirectory: true)
            try fm.moveItem(at: unpacked, to: staged)
            return staged
        }.value
    }

    /// The store hands out extensions for the Chrome version asking; a recent one gets the current MV3 builds.
    nonisolated private static let chromeVersion = "140.0.0.0"

    /// A CRX is a small header (magic "Cr24", a version, then keys and signatures) in front of a plain zip.
    nonisolated static func zipPayload(ofCRX data: Data) -> Data? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        if bytes.starts(with: [0x50, 0x4B]) { return data }  // already a zip
        guard bytes.starts(with: Array("Cr24".utf8)), let version = u32(4) else { return nil }
        let start: Int
        switch version {
        case 3: guard let header = u32(8) else { return nil }; start = 12 + header
        case 2: guard let key = u32(8), let signature = u32(12) else { return nil }; start = 16 + key + signature
        default: return nil
        }
        guard start < bytes.count, bytes[start...].starts(with: [0x50, 0x4B]) else { return nil }
        return Data(bytes[start...])
    }

    /// Loads an unpacked extension without remembering it (smoke test only).
    func loadForSmokeTest(_ url: URL) async -> WKWebExtensionContext? {
        let item = Available(id: "smoke:" + url.path, name: "Smoke", source: .unpacked(url))
        await load(item)
        AppDelegate.shared.extensionsDidChange()
        return contexts[item.id]
    }

    /// The web view running the extension's background page or service worker, for the inspector. SPI, like `Inspector`.
    static func backgroundWebView(of ctx: WKWebExtensionContext) -> WKWebView? {
        guard ctx.responds(to: NSSelectorFromString("_backgroundWebView")) else { return nil }
        return ctx.value(forKey: "_backgroundWebView") as? WKWebView
    }

    /// The page the toolbar button opens (`action.default_popup`, or MV2's `browser_action`), as a URL in the extension.
    static func popupURL(of ctx: WKWebExtensionContext) -> URL? {
        let manifest = ctx.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        guard let page = action?["default_popup"] as? String, !page.isEmpty else { return nil }
        return URL(string: page, relativeTo: ctx.baseURL)?.absoluteURL
    }

    /// The extension's manifest problems and what went wrong while running, readable.
    static func errorMessages(of ctx: WKWebExtensionContext) -> [String] {
        var seen = Set<String>()
        return (ctx.webExtension.errors + ctx.errors).map { error in
            let error = error as NSError
            if error.domain == WKWebExtensionContext.errorDomain, error.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue {
                return "Its background script failed to start, usually because it threw an error. Inspect Background shows it."
            }
            return error.localizedFailureReason ?? error.localizedDescription
        }.filter { seen.insert($0).inserted }
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
            // The base URL is fixed when the context is made, so set it ourselves to keep the webkit-extension://
            // origin (and with it the pages' localStorage and IndexedDB) the same across launches.
            let uuid = stableUUID(for: item.id)
            if let base = URL(string: "webkit-extension://\(uuid.lowercased())/") { ctx.baseURL = base }
            // The identifier names the extension's storage.local folder and is what `runtime.sendMessage(id)` targets.
            var identifier = uuid
            if case .store(let storeID, _) = item.source { identifier = storeID }
            if case .safari(let appex, _) = item.source,
               let team = await Task.detached(priority: .userInitiated, operation: { Self.verifiedTeam(of: appex) }).value {
                // Safari's own `runtime.id`. Websites address the extension by it through `externally_connectable`
                // (Proton Pass's login hands its session over this way).
                identifier = "\(item.id) (\(team))"
            }
            Self.moveStorage(from: uuid, to: identifier)
            ctx.uniqueIdentifier = identifier
            ctx.isInspectable = true
            ctx.inspectionName = item.name
            // The user turned it on after seeing the permission list, so grant what the manifest asks for.
            for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
            for m in ext.requestedPermissionMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: m) }
            try controller.load(ctx)
            contexts[item.id] = ctx
            if case .store = item.source { keepWorkerAwake(ctx) }
            for error in ext.errors { NSLog("Tern extension \(item.name): \(error.localizedDescription)") }
        } catch {
            NSLog("Tern: failed to load extension \(item.name): \(error)")
        }
    }

    /// Once a Chrome Web Store extension's service worker goes idle, WebKit may not wake it again: Proton Pass's messages
    /// then get no reply and its popup stays blank. Loading background content is a no-op while the worker runs.
    private func keepWorkerAwake(_ ctx: WKWebExtensionContext) {
        guard ctx.webExtension.hasBackgroundContent, !ctx.webExtension.hasPersistentBackgroundContent else { return }
        ctx.loadBackgroundContent { _ in }
        guard workerKeepAlive == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for item in self.available {
                    guard case .store = item.source, let ctx = self.contexts[item.id],
                          ctx.webExtension.hasBackgroundContent, !ctx.webExtension.hasPersistentBackgroundContent else { continue }
                    ctx.loadBackgroundContent { _ in }
                }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        workerKeepAlive = timer
    }

    /// With a stable base URL, WebKit finds last launch's service worker registration and never runs the worker, so the
    /// extension has no listeners. It must go before WebKit reads the registrations, so call this before any web view exists.
    static func forgetServiceWorkers() {
        guard !SmokeTest.isRunning, !Metrics.isBenchmark,
              let hosts = (UserDefaults.tern.dictionary(forKey: "extensionUUIDs") as? [String: String])?.values.map({ Data($0.lowercased().utf8) }),
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let fm = FileManager.default
        let root = library.appendingPathComponent("WebKit/\(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)/WebsiteData/Default")
        for top in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for frame in (try? fm.contentsOfDirectory(at: top, includingPropertiesForKeys: nil)) ?? [] {
                let workers = frame.appendingPathComponent("ServiceWorkers")
                guard fm.fileExists(atPath: workers.path),
                      let origin = try? Data(contentsOf: frame.appendingPathComponent("origin")),
                      origin.range(of: Data("webkit-extension".utf8)) != nil,
                      hosts.contains(where: { origin.range(of: $0) != nil }) else { continue }
                try? fm.removeItem(at: workers)
            }
        }
    }

    private static func makeExtension(_ item: Available) async throws -> WKWebExtension {
        switch item.source {
        case .safari(let appex, _):
            guard let bundle = Bundle(url: appex) else { throw CocoaError(.fileReadCorruptFile) }
            return try await WKWebExtension(appExtensionBundle: bundle)
        case .store(_, let url):
            await Task.detached(priority: .userInitiated) { ChromeCompat.install(in: url) }.value
            return try await WKWebExtension(resourceBaseURL: url)
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

    /// Builds before this one keyed every extension's storage by its UUID. Carry it over to the Safari-style
    /// identifier once, so turning that on doesn't log people out of extensions they already use.
    private static func moveStorage(from old: String, to new: String) {
        guard old != new, !SmokeTest.isRunning, !Metrics.isBenchmark,
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        // WebKit's default controller storage for an app outside a sandbox container.
        let root = library.appendingPathComponent("WebKit/\(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)/WebExtensions/Default")
        let from = root.appendingPathComponent(old), to = root.appendingPathComponent(new)
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        do { try fm.moveItem(at: from, to: to) } catch { NSLog("Tern: couldn't move extension storage \(old) → \(new): \(error)") }
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

        let storeFolder = folder.appendingPathComponent("Chrome Web Store", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: storeFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            let storeID = url.lastPathComponent
            guard isStoreID(storeID), fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { continue }
            result.append(Available(id: storeItemID(storeID), name: manifestName(at: url) ?? storeID, source: .store(id: storeID, folder: url)))
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

    /// The signing team, only if the whole bundle (resources included) validates against an Apple-issued certificate:
    /// Apple's own Mac App Store signature (which carries the team in the signed code directory, not the certificate)
    /// or one issued to that team. Otherwise any app could claim another extension's ID and receive what websites send it.
    nonisolated private static func verifiedTeam(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] or certificate leaf[subject.OU] = \"\(team)\")" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { return nil }
        return team
    }

    nonisolated private static func unpackedID(_ url: URL) -> String { "unpacked:" + url.standardizedFileURL.path }

    /// The manifest's name, looked up in `_locales` when it's a `__MSG_key__` placeholder (most store extensions).
    nonisolated private static func manifestName(at url: URL) -> String? {
        func json(_ path: String) -> [String: Any]? {
            (try? Data(contentsOf: url.appendingPathComponent(path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard let manifest = json("manifest.json"), let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
        let key = name.dropFirst(6).dropLast(2).lowercased()
        let locales: [String?] = [Locale.current.identifier, Locale.current.language.languageCode?.identifier, manifest["default_locale"] as? String, "en"]
        for locale in locales.compactMap({ $0 }) {
            guard let messages = json("_locales/\(locale)/messages.json") else { continue }
            if let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
               let message = entry["message"] as? String { return message }
        }
        return nil
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

    nonisolated fileprivate static func unsupported(_ what: String) -> NSError {
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

    // No `sendMessage(toApplicationWithIdentifier:)` / `connectUsing:` here on purpose: without them WebKit passes
    // `runtime.sendNativeMessage` and `connectNative` to the Safari extension's own native handler (its appex).
}
