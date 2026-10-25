import AppKit
import WebKit

/// Requests (⌥⌘N): every request a tab's page made, from its resource timing, in a small window
/// beside the browser. Filter by type or text, see status, size and time, open or copy a request.
/// The page script runs in its own content world, and only while a Requests window is open.
@MainActor
final class RequestInspector: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Entry: Equatable {
        let url: String
        let type: String
        let start: Int
        let duration: Int
        let size: Int
        let status: Int

        var kind: Kind {
            switch type {
            case "navigation", "document", "iframe": .document
            case "fetch", "xmlhttprequest", "beacon": .fetch
            case "script": .script
            case "css", "link": .stylesheet
            case "img", "image", "imageset": .image
            case "font": .font
            case "video", "audio", "track": .media
            default: url.hasSuffix(".css") ? .stylesheet : .other
            }
        }
    }

    enum Kind: Int, CaseIterable {
        case all, document, fetch, script, stylesheet, image, font, media, other

        var title: String {
            switch self {
            case .all: "All"
            case .document: "Document"
            case .fetch: "Fetch/XHR"
            case .script: "Script"
            case .stylesheet: "Stylesheet"
            case .image: "Image"
            case .font: "Font"
            case .media: "Media"
            case .other: "Other"
            }
        }
    }

    static let world = WKContentWorld.world(name: "tern-requests")
    static let handlerName = "ternRequests"
    static let capacity = 2000
    private static var open: [UUID: RequestInspector] = [:]
    private static let router = Router()
    private static let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)

    private(set) weak var tab: Tab?
    private let tabID: UUID
    private(set) var entries: [Entry] = []
    private(set) var rows: [Entry] = []
    var filter = Kind.all { didSet { typePicker.selectedSegment = filter.rawValue; reload() } }
    var preserveLog = false

    private let typePicker = NSSegmentedControl(labels: Kind.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let preserve = NSButton(checkboxWithTitle: "Preserve log", target: nil, action: nil)

    /// Opens (or brings back) the Requests window for a tab.
    @discardableResult
    static func show(for tab: Tab) -> RequestInspector {
        let inspector = open[tab.id] ?? RequestInspector(tab: tab)
        open[tab.id] = inspector
        install()
        inspector.refreshTitle()
        inspector.capture()
        if inspector.window?.isVisible != true {
            if let parent = tab.owner?.window?.frame, let window = inspector.window {
                window.setFrameTopLeftPoint(NSPoint(x: parent.maxX - window.frame.width - 24, y: parent.maxY - 60))
            } else {
                inspector.window?.center()
            }
        }
        inspector.showWindow(nil)
        return inspector
    }

    static func inspector(for tab: Tab) -> RequestInspector? { open[tab.id] }

    private init(tab: Tab) {
        self.tab = tab
        tabID = tab.id
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow],
                             backing: .buffered, defer: true)
        window.minSize = NSSize(width: 520, height: 220)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = false
        super.init(window: window)
        window.delegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Page script

    private static func install() {
        let controller = BrowserEngine.shared.webViewConfiguration.userContentController
        guard !controller.userScripts.contains(where: { $0 === userScript }) else { return }
        controller.addUserScript(userScript)
        controller.add(router, contentWorld: world, name: handlerName)
    }

    private static func uninstall() {
        let controller = BrowserEngine.shared.webViewConfiguration.userContentController
        guard controller.userScripts.contains(where: { $0 === userScript }) else { return }
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        let others = controller.userScripts.filter { $0 !== userScript }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
    }

    /// Runs the script on the page that's already loaded, which sends what it has loaded so far.
    func capture() {
        tab?.webView?.evaluateJavaScript(Self.source + "\nwindow.__ternRequestsDump(); true", in: nil, in: Self.world) { _ in }
    }

    private final class Router: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let webView = message.webView,
                      let tab = AppDelegate.shared.allTabs.first(where: { $0.webView === webView }),
                      let inspector = RequestInspector.open[tab.id] else { return }
                inspector.receive(body)
            }
        }
    }

    private func receive(_ body: [String: Any]) {
        if body["reset"] != nil, !preserveLog { entries.removeAll() }
        let list = body["entries"] as? [[String: Any]] ?? []
        entries += list.compactMap { e in
            guard let url = e["url"] as? String, !url.hasPrefix("data:") else { return nil }
            return Entry(url: url, type: e["type"] as? String ?? "other", start: e["start"] as? Int ?? 0,
                         duration: e["duration"] as? Int ?? 0, size: e["size"] as? Int ?? 0,
                         status: e["status"] as? Int ?? 0)
        }
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        refreshTitle()
        reload()
    }

    /// The page's resource timing: one entry per finished request, plus the document itself. It has no
    /// request methods or headers (Inspect Element's Network tab does), and status only where WebKit reports it.
    static let source = #"""
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ternRequests;
      if (!handler || window.__ternRequestsDump) return;
      const pack = (e) => ({
        url: e.name, type: e.entryType === "navigation" ? "navigation" : (e.initiatorType || "other"),
        start: Math.round(e.startTime), duration: Math.round(e.duration),
        size: e.transferSize || e.encodedBodySize || 0, status: e.responseStatus || 0,
      });
      const send = (list, reset) => {
        const entries = list.filter((e) => e.name).map(pack);
        if (entries.length || reset) handler.postMessage(reset ? { reset: true, entries } : { entries });
      };
      try { performance.setResourceTimingBufferSize(2000); } catch (_) {}
      const observer = new PerformanceObserver((l) => send(l.getEntries(), false));
      observer.observe({ type: "resource" });
      try { observer.observe({ type: "navigation" }); } catch (_) {}
      window.__ternRequestsDump = () => {
        const nav = performance.getEntriesByType("navigation").filter((e) => e.duration > 0);
        send(nav.concat(performance.getEntriesByType("resource")), true);
      };
      // A new document: the log starts over unless it's preserved.
      handler.postMessage({ reset: true, entries: [] });
    })();
    """#

    // MARK: UI

    private func build() {
        typePicker.target = self
        typePicker.action = #selector(typeChanged)
        typePicker.segmentStyle = .roundRect
        typePicker.controlSize = .small
        typePicker.selectedSegment = 0
        search.placeholderString = "Filter URLs"
        search.delegate = self
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        preserve.target = self
        preserve.action = #selector(preserveChanged)
        preserve.controlSize = .small
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clear.controlSize = .small
        clear.bezelStyle = .push

        for (id, title, width) in [("status", "Status", 54.0), ("name", "Name", 380.0),
                                   ("type", "Type", 90.0), ("size", "Size", 70.0), ("time", "Time", 70.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            if id == "name" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 20
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(openSelected)
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in New Tab", action: #selector(openSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy URL", action: #selector(copyURLs), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy as cURL", action: #selector(copyCurl), keyEquivalent: "").target = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        typePicker.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        let top = NSStackView(views: [search, typePicker])
        top.spacing = 8
        let bottom = NSStackView(views: [summary, NSView(), preserve, clear])
        bottom.spacing = 8
        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        window?.contentView = root
    }

    private func refreshTitle() {
        let title = tab?.displayTitle ?? "Closed Tab"
        window?.title = "Requests · \(title)"
    }

    func reload() {
        let text = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = entries.filter { (filter == .all || $0.kind == filter) && (text.isEmpty || $0.url.lowercased().contains(text)) }
        table.reloadData()
        let bytes = rows.reduce(0) { $0 + $1.size }
        let end = rows.map { $0.start + $0.duration }.max() ?? 0
        var parts = ["\(rows.count) of \(entries.count) request\(entries.count == 1 ? "" : "s")"]
        if bytes > 0 { parts.append("\(Self.format(bytes)) transferred") }
        if end > 0 { parts.append("finished in \(Self.format(ms: end))") }
        let failed = rows.filter { $0.status >= 400 }.count
        if failed > 0 { parts.append("\(failed) failed") }
        summary.stringValue = parts.joined(separator: " · ")
    }

    static func format(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : bytes < 1_048_576 ? String(format: "%.1f KB", Double(bytes) / 1024) : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func format(ms: Int) -> String { ms < 1000 ? "\(ms) ms" : String(format: "%.2f s", Double(ms) / 1000) }

    @objc private func typeChanged() { filter = Kind(rawValue: typePicker.selectedSegment) ?? .all }
    @objc private func preserveChanged() { preserveLog = preserve.state == .on }
    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc func clearLog() {
        entries.removeAll()
        reload()
    }

    private var selected: [Entry] {
        let clicked = table.clickedRow
        let indexes = clicked >= 0 && !table.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : table.selectedRowIndexes
        return indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    @objc private func openSelected() {
        guard let browser = tab?.owner ?? AppDelegate.shared.keyBrowser else { return }
        for entry in selected { if let url = URL(string: entry.url) { _ = browser.newTab(url: url) } }
    }

    @objc private func copyURLs() { copy(selected.map(\.url).joined(separator: "\n")) }

    @objc private func copyCurl() {
        copy(selected.map(Self.curl).joined(separator: "\n"))
    }

    static func curl(_ entry: Entry) -> String {
        let quoted = "'" + entry.url.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "curl \(quoted)"
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[tabID] = nil
        if Self.open.isEmpty { Self.uninstall() }
    }

    /// The tab closed: its window goes too.
    static func tabClosed(_ tab: Tab) {
        open[tab.id]?.close()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let id = column?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "status": text = entry.status == 0 ? "—" : "\(entry.status)"
        case "name":
            let url = URL(string: entry.url)
            let path = url.map { $0.path.isEmpty ? "/" : $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? entry.url
            text = path + (url?.query.map { "?" + $0 } ?? "")
        case "type": text = entry.kind == .other ? entry.type : entry.kind.title
        case "size": text = entry.size == 0 ? "—" : Self.format(entry.size)
        default: text = Self.format(ms: entry.duration)
        }
        let field = NSTextField(labelWithString: text)
        field.font = id == "name" ? .systemFont(ofSize: 12) : Theme.monoFont(11)
        field.lineBreakMode = .byTruncatingMiddle
        field.textColor = entry.status >= 400 ? .systemRed : id == "name" ? .labelColor : .secondaryLabelColor
        if id == "name" {
            field.toolTip = entry.url
            if let host = URL(string: entry.url)?.host, host != tab?.currentURL?.host {
                field.stringValue = text + "  ·  " + host
            }
        }
        if ["size", "time", "status"].contains(id) { field.alignment = .right }
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
