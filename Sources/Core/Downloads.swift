import AppKit
import WebKit

/// Downloads started this session: where each one goes, how far along it is, and how it ended.
/// The top bar shows a button while the list isn't empty; its popover lists them.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    static let didChange = Notification.Name("TernDownloadsDidChange")

    /// Set by the smoke test, so it never writes to your Downloads folder.
    static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    @MainActor
    final class Item {
        enum State: Equatable { case running, finished, failed(String), cancelled }

        let id = UUID()
        let source: URL?
        fileprivate(set) var filename: String
        fileprivate(set) var destination: URL?
        fileprivate(set) var state: State = .running
        fileprivate(set) var received: Int64 = 0
        /// Bytes expected, or -1 when the server didn't say.
        fileprivate(set) var expected: Int64 = -1
        fileprivate var download: WKDownload?
        fileprivate var observation: NSKeyValueObservation?

        var fraction: Double? { expected > 0 ? min(Double(received) / Double(expected), 1) : nil }

        fileprivate init(download: WKDownload) {
            self.download = download
            self.source = download.originalRequest?.url
            self.filename = download.originalRequest?.url?.lastPathComponent.removingPercentEncoding ?? "Download"
        }
    }

    /// Newest first.
    private(set) var items: [Item] = []
    var runningCount: Int { items.filter { $0.state == .running }.count }
    private var notifyScheduled = false

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = Item(download: download)
        items.insert(item, at: 0)
        item.observation = download.progress.observe(\.completedUnitCount) { [weak self, weak item] progress, _ in
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let item, item.state == .running else { return }
                    item.received = done
                    if total > 0 { item.expected = total }
                    self?.changedSoon()
                }
            }
        }
        changed()
    }

    func cancel(_ item: Item) {
        guard item.state == .running else { return }
        item.state = .cancelled
        item.download?.cancel(nil)
        finish(item)
    }

    /// Starts a failed or cancelled download again from the beginning, in its place in the list.
    func retry(_ item: Item, using webView: WKWebView?) {
        guard item.state != .running, item.state != .finished, let url = item.source, let webView else { return }
        items.removeAll { $0 === item }
        changed()
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.track(download)
        }
    }

    /// Forgets the downloads that are over. The files stay where they are.
    func clearFinished() {
        items.removeAll { $0.state != .running }
        changed()
    }

    func reveal(_ item: Item) {
        guard let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return revealFolder() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: Item) {
        guard item.state == .finished, let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealFolder() { NSWorkspace.shared.open(Self.directory) }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (suggestedFilename as NSString).deletingPathExtension
        let ext = (suggestedFilename as NSString).pathExtension
        var url = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        if let item = item(for: download) {
            item.filename = url.lastPathComponent
            item.destination = url
            if response.expectedContentLength > 0 { item.expected = response.expectedContentLength }
        }
        changed()
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        if let url = item.destination {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.received
            item.received = size
            item.expected = size
            // Makes the Downloads stack in the Dock bounce, like Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
        finish(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        if item.state == .running {
            let e = error as NSError
            item.state = e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled ? .cancelled : .failed(error.localizedDescription)
        }
        finish(item)
    }

    // MARK: Private

    private func item(for download: WKDownload) -> Item? { items.first { $0.download === download } }

    private func finish(_ item: Item) {
        item.download = nil
        item.observation = nil
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    /// Progress ticks arrive many times a second; the UI hears about them at most five times a second.
    private func changedSoon() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.notifyScheduled = false
                self?.changed()
            }
        }
    }

    /// "3.2 MB of 10 MB", "Finished · 10 MB", "Failed: …".
    static func status(of item: Item) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        switch item.state {
        case .running:
            return item.expected > 0 ? "\(f.string(fromByteCount: item.received)) of \(f.string(fromByteCount: item.expected))"
                : item.received > 0 ? f.string(fromByteCount: item.received) : "Starting…"
        case .finished: return item.received > 0 ? "Finished · \(f.string(fromByteCount: item.received))" : "Finished"
        case .failed(let reason): return "Failed: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}
