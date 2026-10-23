import Foundation

/// Frecency: frequent and recent beats either alone. Each of the last few visits is worth more the
/// more recent it is, scaled up by how many visits there were in total (Firefox's scheme, simplified).
enum Frecency {
    static let sampleSize = 10

    static func score(visits: [Date], total: Int, now: Date = Date()) -> Double {
        guard !visits.isEmpty else { return 0 }
        let points = visits.reduce(0.0) { sum, date in
            let days = now.timeIntervalSince(date) / 86_400
            return sum + (days < 4 ? 100 : days < 14 ? 70 : days < 31 ? 50 : days < 90 ? 30 : 10)
        }
        return points * Double(max(total, visits.count)) / Double(visits.count)
    }

    /// A bonus to add to a fuzzy match score, so the pages and commands you use most rise to the top.
    static func bonus(_ frecency: Double) -> Int { Int(log2(1 + frecency) * 15) }
}

/// Pages you've visited, for ⌘K and address-bar suggestions. Stored in `history.json` beside the
/// session. The smoke test and benchmarks keep it in memory only.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore(persistent: !SmokeTest.isRunning && !Metrics.isBenchmark)

    struct Entry: Codable {
        var url: String
        var title: String?
        var visits: Int
        var recent: [Date] // newest last, at most Frecency.sampleSize
        var frecency: Double { Frecency.score(visits: recent, total: visits) }
        var lastVisit: Date { recent.last ?? .distantPast }
    }

    static let capacity = 5000

    private(set) var entries: [String: Entry] = [:]
    private let persistent: Bool
    private var saveScheduled = false
    private var fileURL: URL { AppPaths.support.appendingPathComponent("history.json") }

    init(persistent: Bool) {
        self.persistent = persistent
        guard persistent, let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(saved.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Only web pages are kept: not the start page, files, or the browser's own pages.
    static func isRecordable(_ url: URL) -> Bool { url.scheme == "http" || url.scheme == "https" }

    func recordVisit(_ url: URL, title: String?) {
        guard Self.isRecordable(url) else { return }
        let key = url.absoluteString
        var entry = entries[key] ?? Entry(url: key, title: nil, visits: 0, recent: [])
        // A reload or an in-page redirect within a few seconds isn't another visit.
        if let last = entry.recent.last, Date().timeIntervalSince(last) < 5 {
            entry.title = title ?? entry.title
            entries[key] = entry
            return scheduleSave()
        }
        entry.visits += 1
        entry.recent.append(Date())
        if entry.recent.count > Frecency.sampleSize { entry.recent.removeFirst() }
        if let title, !title.isEmpty { entry.title = title }
        entries[key] = entry
        if entries.count > Self.capacity { trim() }
        scheduleSave()
    }

    func updateTitle(_ title: String?, for url: URL?) {
        guard let url, let title, !title.isEmpty, entries[url.absoluteString] != nil,
              entries[url.absoluteString]?.title != title else { return }
        entries[url.absoluteString]?.title = title
        scheduleSave()
    }

    func remove(_ url: String) {
        guard entries.removeValue(forKey: url) != nil else { return }
        scheduleSave()
    }

    func clear() {
        entries = [:]
        scheduleSave()
    }

    /// Entries ranked by frecency, best first.
    func ranked(limit: Int = .max) -> [Entry] {
        Array(entries.values.sorted { $0.frecency > $1.frecency }.prefix(limit))
    }

    /// The best page whose address (without scheme or "www.") starts with what was typed, as the
    /// text to complete it to: "gi" → "github.com/". Completes to the host first, then the full path.
    func completion(for typed: String) -> String? {
        let prefix = typed.lowercased()
        guard prefix.count >= 1, !prefix.contains(" ") else { return nil }
        var best: (text: String, score: Double)?
        for entry in entries.values {
            let bare = Self.bare(entry.url)
            // "localhost:3000/docs" → "localhost:3000/"
            let site = bare.firstIndex(of: "/").map { String(bare[...$0]) } ?? bare + "/"
            let candidate: String
            if site.lowercased().hasPrefix(prefix) { candidate = site }
            else if bare.lowercased().hasPrefix(prefix) { candidate = bare }
            else { continue }
            let score = entry.frecency
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        guard let text = best?.text, text.count > typed.count else { return nil }
        return text
    }

    /// "https://www.github.com/apple/" → "github.com/apple/"
    static func bare(_ url: String) -> String {
        var s = url
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }

    private func trim() {
        let keep = entries.values.sorted { $0.frecency > $1.frecency }.prefix(Self.capacity * 9 / 10)
        entries = Dictionary(keep.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func scheduleSave() {
        guard persistent, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    func save() {
        saveScheduled = false
        guard persistent, let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// How often and how recently each command ran from the palette or a shortcut, for ranking ⌘K.
@MainActor
enum CommandUsage {
    private static let key = "commandUsage"
    private static var cache: [String: [Double]]?

    private static var store: [String: [Double]] {
        get {
            if let cache { return cache }
            let loaded = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            if !SmokeTest.isRunning && !Metrics.isBenchmark { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }

    static func record(_ command: Command) {
        var times = store[command.rawValue] ?? []
        times.append(Date().timeIntervalSince1970)
        store[command.rawValue] = Array(times.suffix(Frecency.sampleSize))
    }

    static func frecency(_ command: Command) -> Double {
        let times = store[command.rawValue] ?? []
        return Frecency.score(visits: times.map(Date.init(timeIntervalSince1970:)), total: times.count)
    }
}
