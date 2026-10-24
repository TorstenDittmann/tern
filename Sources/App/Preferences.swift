import AppKit

/// User settings shown in the Settings window. The smoke test keeps them in memory, so it never
/// changes your real preferences.
@MainActor
enum Preferences {
    static let searchEngines: [(name: String, template: String)] = [
        ("DuckDuckGo", "https://duckduckgo.com/?q=%s"),
        ("Google", "https://www.google.com/search?q=%s"),
        ("Bing", "https://www.bing.com/search?q=%s"),
        ("Brave Search", "https://search.brave.com/search?q=%s"),
        ("Kagi", "https://kagi.com/search?q=%s"),
        ("Ecosia", "https://www.ecosia.org/search?q=%s"),
        ("Startpage", "https://www.startpage.com/do/search?q=%s"),
    ]

    /// Seconds; negative means never.
    static let suspendChoices: [(name: String, seconds: TimeInterval)] = [
        ("After 5 minutes", 5 * 60), ("After 15 minutes", 15 * 60), ("After 30 minutes", 30 * 60),
        ("After 1 hour", 60 * 60), ("After 4 hours", 4 * 60 * 60), ("Never", -1),
    ]

    enum Appearance: String, CaseIterable {
        case system, dark, light
        var title: String {
            switch self {
            case .system: "Match System"
            case .dark: "Dark"
            case .light: "Light"
            }
        }
    }

    private static var memory: [String: Any] = [:]

    private static func value(_ key: String) -> Any? {
        SmokeTest.isRunning ? memory[key] : UserDefaults.standard.object(forKey: key)
    }

    private static func store(_ value: Any, _ key: String) {
        if SmokeTest.isRunning { memory[key] = value } else { UserDefaults.standard.set(value, forKey: key) }
    }

    /// Search used when the address bar input isn't a URL. `%s` is replaced with the query.
    static var searchTemplate: String {
        get { value("searchTemplate") as? String ?? searchEngines[0].template }
        set { store(newValue, "searchTemplate") }
    }

    /// Shows the tab list on the right of the window (the default) or on the left.
    static var sidebarOnRight: Bool {
        get { value("sidebarOnRight") as? Bool ?? true }
        set { store(newValue, "sidebarOnRight") }
    }

    /// Light or dark window chrome; pages see it as `prefers-color-scheme` too.
    static var appearance: Appearance {
        get { (value("appearance") as? String).flatMap(Appearance.init) ?? .system }
        set { store(newValue.rawValue, "appearance"); applyAppearance() }
    }

    static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    /// How long a background tab may stay idle before it gives its memory back; `nil` means never.
    static var suspendAfter: TimeInterval? {
        get {
            let v = value("suspendAfter") as? Double ?? 0
            return v < 0 ? nil : v > 0 ? v : 15 * 60
        }
        set { store(newValue ?? -1, "suspendAfter") }
    }

    /// Ad and tracker blocking, and stripping tracking parameters from links. On unless turned off.
    static var blocksTrackers: Bool {
        get { value("blocksTrackers") as? Bool ?? true }
        set { store(newValue, "blocksTrackers") }
    }

    /// Sites where blocking is the other way round from the default: off on a web site, on for a local dev server.
    static var blockingExceptions: Set<String> {
        get { Set(value("blockingExceptions") as? [String] ?? []) }
        set { store(newValue.sorted(), "blockingExceptions") }
    }

    /// When each filter list was last downloaded, by list identifier, in seconds since 1970.
    static var blocklistsUpdated: [String: Double] {
        get { value("blocklistsUpdated") as? [String: Double] ?? [:] }
        set { store(newValue, "blocklistsUpdated") }
    }
}

extension UserDefaults {
    /// Tern's own settings. The smoke test gets a throwaway suite, emptied at launch,
    /// so a run never changes the settings of the Tern you use.
    static let tern: UserDefaults = {
        guard ProcessInfo.processInfo.environment["TERN_SMOKE"] != nil else { return .standard }
        let name = "dev.tern.browser.smoke"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }()

    /// AppKit autosaves (split view widths, window frames) always go to the standard defaults,
    /// so the smoke test saves them under names the real app never reads.
    static func autosaveName(_ name: String) -> String {
        ProcessInfo.processInfo.environment["TERN_SMOKE"] != nil ? "Smoke" + name : name
    }
}
