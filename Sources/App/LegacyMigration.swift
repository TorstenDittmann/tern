import Foundation

/// One-time import from the app's former name, Brisk (bundle id `dev.brisk.browser`).
/// Copies — never moves — so the old data stays as a backup. Must run before WebKit or
/// `AppPaths` are first touched. Safe to delete once nobody has Brisk data left.
enum LegacyMigration {
    private static let doneKey = "migratedFromBrisk"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let home = fm.homeDirectoryForCurrentUser
        let moves: [(URL, URL)] = [
            // Session file and dropped-in extensions
            (library.appendingPathComponent("Application Support/Brisk"), library.appendingPathComponent("Application Support/Tern")),
            // Website data: local storage, IndexedDB, service workers, extension storage
            (library.appendingPathComponent("WebKit/dev.brisk.browser"), library.appendingPathComponent("WebKit/dev.tern.browser")),
            // Cookies (logins)
            (library.appendingPathComponent("HTTPStorages/dev.brisk.browser"), library.appendingPathComponent("HTTPStorages/dev.tern.browser")),
            (library.appendingPathComponent("HTTPStorages/dev.brisk.browser.binarycookies"), library.appendingPathComponent("HTTPStorages/dev.tern.browser.binarycookies")),
            // Key bindings
            (home.appendingPathComponent(".config/brisk"), home.appendingPathComponent(".config/tern")),
        ]
        for (old, new) in moves where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: old, to: new)
            } catch {
                NSLog("Tern: couldn't import \(old.path): \(error.localizedDescription)")
            }
        }

        // Settings: enabled extensions and their storage identifiers, search engine, suspension delay, window state.
        if let old = defaults.persistentDomain(forName: "dev.brisk.browser") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
