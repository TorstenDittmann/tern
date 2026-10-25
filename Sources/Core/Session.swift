import AppKit

enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tern", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Saves windows and tabs (with back/forward state) and restores them lazily:
/// only each window's active tab gets a web view at launch.
@MainActor
enum SessionStore {
    struct SavedTab: Codable { var id: UUID; var url: String?; var title: String?; var state: Data?; var pinned: Bool? }
    struct SavedWindow: Codable {
        var tabs: [SavedTab]; var active: Int; var frame: String; var sidebarCollapsed: Bool
        /// Indices of the split's tabs, in pane order. `splitFraction` is from when splits had two side-by-side panes.
        var split: [Int]?; var splitFraction: Double?; var splitLayout: String?; var splitDividers: [Double]?
    }

    private static var fileURL: URL { AppPaths.support.appendingPathComponent("session.json") }

    static func save(_ windows: [BrowserWindowController]) {
        // Private windows are never written down.
        let saved = windows.filter { !$0.isPrivate }.map { w in
            SavedWindow(
                tabs: w.tabs.map { SavedTab(id: $0.id, url: $0.currentURL?.absoluteString, title: $0.pageTitle, state: $0.interactionStateData,
                                       pinned: $0.isPinned ? true : nil) },
                active: w.activeTab.flatMap { w.tabs.firstIndex(of: $0) } ?? 0,
                frame: NSStringFromRect(w.window?.frame ?? .zero),
                sidebarCollapsed: w.isSidebarCollapsed,
                split: w.split.flatMap { g in
                    let indices = g.tabs.compactMap { w.tabs.firstIndex(of: $0) }
                    return indices.count == g.tabs.count ? indices : nil
                },
                splitLayout: w.split?.layout.rawValue,
                splitDividers: w.split?.dividers.map(Double.init)
            )
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Returns false when there was nothing to restore.
    static func restore(into app: AppDelegate) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([SavedWindow].self, from: data),
              !saved.isEmpty else { return false }
        for w in saved where !w.tabs.isEmpty {
            let tabs = w.tabs.map { saved in
                let tab = Tab(url: saved.url.flatMap(URL.init(string:)), title: saved.title, interactionState: saved.state, id: saved.id)
                tab.isPinned = saved.pinned ?? false
                return tab
            }
            let frame = NSRectFromString(w.frame)
            let browser = app.openWindow(restoring: tabs, active: w.active, frame: frame == .zero ? nil : frame, sidebarCollapsed: w.sidebarCollapsed)
            if let indices = w.split, indices.allSatisfy(tabs.indices.contains) {
                let dividers = w.splitDividers ?? w.splitFraction.map { [$0] }
                browser.restoreSplit(indices.map { tabs[$0] }, layout: w.splitLayout.flatMap(SplitLayout.init(rawValue:)) ?? .columns,
                                     dividers: dividers?.map { CGFloat($0) })
            }
        }
        return !app.windows.isEmpty
    }
}

/// Frees memory by dropping web views of tabs that haven't been looked at in a while,
/// and of every background tab when macOS signals memory pressure.
@MainActor
final class TabSuspender {
    static let shared = TabSuspender()

    /// Seconds a background tab may stay idle before it's suspended (Settings ▸ General); nil: never.
    var idleInterval: TimeInterval? { Preferences.suspendAfter }

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?

    func start() {
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                TabSuspender.shared.sweep()
                SessionStore.save(AppDelegate.shared.windows)
            }
        }
        timer.tolerance = 20 // let the OS coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { TabSuspender.shared.suspendAllBackgroundTabs() }
        }
        source.resume()
        pressureSource = source
    }

    func sweep() {
        guard let idleInterval else { return }
        let cutoff = Date().addingTimeInterval(-idleInterval)
        for tab in AppDelegate.shared.allTabs where !tab.isSuspended && !tab.isVisible && tab.lastActivated < cutoff {
            tab.suspendIfIdle()
        }
    }

    func suspendAllBackgroundTabs() {
        for tab in AppDelegate.shared.allTabs where !tab.isSuspended && !tab.isVisible {
            tab.suspendIfIdle()
        }
    }
}
