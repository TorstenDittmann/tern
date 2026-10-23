import Foundation

/// Saved pages (⌘D), newest first. Stored in `bookmarks.json` beside the session; the smoke test
/// and benchmarks keep them in memory only.
@MainActor
final class BookmarkStore {
    static let shared = BookmarkStore(persistent: !SmokeTest.isRunning && !Metrics.isBenchmark)
    static let didChange = Notification.Name("TernBookmarksDidChange")

    struct Bookmark: Codable, Equatable {
        var url: String
        var title: String
        var added: Date
    }

    private(set) var all: [Bookmark] = []
    private let persistent: Bool
    private var fileURL: URL { AppPaths.support.appendingPathComponent("bookmarks.json") }

    init(persistent: Bool) {
        self.persistent = persistent
        guard persistent, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        all = saved
    }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return all.contains { $0.url == url.absoluteString }
    }

    func add(_ url: URL, title: String?) {
        guard HistoryStore.isRecordable(url), !contains(url) else { return }
        let name = title?.isEmpty == false ? title! : url.host ?? url.absoluteString
        all.insert(Bookmark(url: url.absoluteString, title: name, added: Date()), at: 0)
        changed()
    }

    func remove(_ url: String) {
        all.removeAll { $0.url == url }
        changed()
    }

    func rename(_ url: String, to title: String) {
        guard let i = all.firstIndex(where: { $0.url == url }), !title.isEmpty else { return }
        all[i].title = title
        changed()
    }

    /// Adds the page, or removes it if it's already saved. Returns whether it's bookmarked now.
    @discardableResult
    func toggle(_ url: URL?, title: String?) -> Bool {
        guard let url else { return false }
        if contains(url) { remove(url.absoluteString); return false }
        add(url, title: title)
        return contains(url)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        guard persistent, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
