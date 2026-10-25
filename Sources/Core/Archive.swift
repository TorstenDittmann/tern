import AppKit

/// Tabs closed for going unvisited too long (Settings ▸ General ▸ Archive idle tabs). They're kept
/// here, newest first, to find again in ⌘K or **Archived Tabs…**; opening one brings it back as a tab.
@MainActor
final class ArchiveStore {
    static let shared = ArchiveStore()
    static let didChange = Notification.Name("TernArchiveDidChange")

    struct Entry: Codable, Equatable {
        var url: String
        var title: String?
        var archived: Date
    }

    private(set) var entries: [Entry] = []
    private static let limit = 300
    private var fileURL: URL { AppPaths.support.appendingPathComponent("archive.json") }

    private init() {
        // The smoke test starts empty and never writes.
        guard !SmokeTest.isRunning, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = saved
    }

    /// False for pages the archive can't bring back (blank tabs, file:// and other non-web URLs).
    @discardableResult
    func archive(_ tab: Tab) -> Bool {
        guard let url = tab.currentURL, HistoryStore.isRecordable(url) else { return false }
        entries.removeAll { $0.url == url.absoluteString }
        entries.insert(Entry(url: url.absoluteString, title: tab.pageTitle, archived: Date()), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        changed()
        return true
    }

    /// Opens the entry as a new tab in `browser` and takes it out of the archive.
    func restore(_ entry: Entry, in browser: BrowserWindowController) {
        entries.removeAll { $0 == entry }
        changed()
        if let url = URL(string: entry.url) { browser.newTab(url: url) }
    }

    func clear() {
        entries.removeAll()
        changed()
    }

    /// Closes background tabs nobody has looked at for `interval` into the archive. Pinned tabs, tabs on
    /// screen, and tabs playing sound or using the camera or microphone stay.
    func sweep(olderThan interval: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-interval)
        for browser in AppDelegate.shared.windows where !browser.isPrivate {
            let stale = browser.tabs.filter { tab in
                guard !tab.isPinned, !tab.isVisible, tab.lastActivated < cutoff, !tab.isPlayingAudio else { return false }
                guard let wv = tab.webView else { return true }
                return wv.cameraCaptureState == .none && wv.microphoneCaptureState == .none
            }
            // Never the window's last tab, and never one the archive couldn't keep.
            for tab in stale where browser.tabs.count > 1 && archive(tab) {
                browser.close(tab)
            }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
        guard !SmokeTest.isRunning, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
