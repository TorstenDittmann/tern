import AppKit
import CryptoKit
import Security
import SecurityInterface

// The two popovers that open from the address bar: the lock's connection and certificate details,
// and the URL breakdown.

/// What the site popover shows about one certificate in the chain.
struct CertificateDetails {
    let certificate: SecCertificate

    var subject: String { SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown" }
    var notBefore: Date? { SecCertificateCopyNotValidBeforeDate(certificate) as Date? }
    var notAfter: Date? { SecCertificateCopyNotValidAfterDate(certificate) as Date? }
    var der: Data { SecCertificateCopyData(certificate) as Data }
    var sha256: String { Self.hex(Data(SHA256.hash(data: der))) }
    var serial: String { (SecCertificateCopySerialNumberData(certificate, nil) as Data?).map(Self.hex) ?? "" }

    var pem: String {
        "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END CERTIFICATE-----\n"
    }

    private var values: [String: Any] {
        let keys = [kSecOIDX509V1IssuerName, kSecOIDSubjectAltName] as CFArray
        return SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] ?? [:]
    }

    private static func entries(_ property: Any?) -> [[String: Any]] {
        (property as? [String: Any])?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
    }

    /// The issuer's common name and organization, like “R11 · Let's Encrypt”.
    var issuer: String {
        let names = Self.entries(values[kSecOIDX509V1IssuerName as String])
        func field(_ oid: CFString) -> String? {
            names.first { $0[kSecPropertyKeyLabel as String] as? String == oid as String }?[kSecPropertyKeyValue as String] as? String
        }
        let parts = [field(kSecOIDCommonName), field(kSecOIDOrganizationName)].compactMap { $0 }
        return parts.isEmpty ? "Unknown" : parts.joined(separator: " · ")
    }

    /// Subject alternative names: the hosts this certificate is valid for.
    var names: [String] {
        Self.entries(values[kSecOIDSubjectAltName as String]).compactMap { $0[kSecPropertyKeyValue as String] as? String }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: ":") }
}

/// Small helpers shared by both popovers.
@MainActor
private enum Popover {
    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: Theme.sectionTitle(text))
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    static func value(_ text: String, mono: Bool = false, width: CGFloat = 250) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = mono ? Theme.monoFont(11) : .systemFont(ofSize: 12)
        field.isSelectable = true
        field.preferredMaxLayoutWidth = width
        return field
    }

    static func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        return stack
    }
}

/// The lock's popover: whether the connection is encrypted, the leaf certificate's details, and the chain.
final class SiteInfoController: NSViewController {
    let url: URL
    let trust: SecTrust?
    let secureContentOnly: Bool
    let chain: [CertificateDetails]

    init(url: URL, trust: SecTrust?, secureContentOnly: Bool) {
        self.url = url
        self.trust = trust
        self.secureContentOnly = secureContentOnly
        let certificates = trust.flatMap { SecTrustCopyCertificateChain($0) as? [SecCertificate] } ?? []
        chain = certificates.map(CertificateDetails.init)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The headline: “Connection is secure”, “Connection is not secure”, and so on.
    var status: (symbol: String, color: NSColor, title: String, detail: String) {
        let host = url.host ?? url.absoluteString
        switch url.scheme {
        case "https" where chain.isEmpty:
            return ("lock.fill", Theme.accent, "Connection is encrypted", "No certificate details for this page yet.")
        case "https" where !secureContentOnly:
            return ("lock.trianglebadge.exclamationmark.fill", .systemOrange, "Connection is partly secure",
                    "\(host) has a valid certificate, but some of this page loads over plain HTTP.")
        case "https":
            return ("lock.fill", Theme.accent, "Connection is secure", "The certificate for \(host) is valid and trusted.")
        case "http" where Self.isLocal(url.host):
            return ("laptopcomputer", .secondaryLabelColor, "Local server", "Plain HTTP to \(host) on this Mac.")
        case "http":
            return ("exclamationmark.triangle.fill", .systemOrange, "Connection is not secure",
                    "Anything you send to \(host) travels unencrypted.")
        case "file":
            return ("doc", .secondaryLabelColor, "Local file", url.path)
        default:
            return ("globe", .secondaryLabelColor, url.scheme ?? "Page", url.absoluteString)
        }
    }

    private static func isLocal(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1" || host == "0.0.0.0"
            || host.hasSuffix(".local") || host.hasSuffix(".test")
    }

    override func loadView() {
        let status = status
        let icon = NSImageView(image: Theme.symbol(status.symbol, size: 15, weight: .semibold) ?? NSImage())
        icon.contentTintColor = status.color
        let title = NSTextField(labelWithString: status.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = Popover.value(status.detail, width: 300)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let header = NSStackView(views: [icon, text])
        header.alignment = .top
        header.spacing = 10

        var views: [NSView] = [header]
        if let leaf = chain.first {
            views.append(certificateGrid(leaf))
            views.append(chainView())
            let pem = NSButton(title: "Copy PEM Chain", target: self, action: #selector(copyPEM))
            let show = NSButton(title: "Show Certificate…", target: self, action: #selector(showCertificate))
            show.keyEquivalent = "\r"
            let buttons = NSStackView(views: [pem, show])
            buttons.spacing = 8
            views.append(buttons)
        }
        let stack = Popover.stack(views, spacing: 14)
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        view = stack
    }

    private func certificateGrid(_ leaf: CertificateDetails) -> NSView {
        let dates = DateFormatter()
        dates.dateStyle = .medium
        var rows: [(String, NSView)] = [
            ("Issued to", Popover.value(leaf.subject)),
            ("Issued by", Popover.value(leaf.issuer)),
        ]
        if let from = leaf.notBefore, let until = leaf.notAfter {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: until).day ?? 0
            let remaining = days < 0 ? "expired \(-days) days ago" : days == 0 ? "expires today" : "\(days) days left"
            let valid = Popover.value("\(dates.string(from: from)) – \(dates.string(from: until)) (\(remaining))")
            if days < 14 { valid.textColor = .systemOrange }
            rows.append(("Valid", valid))
        }
        let names = leaf.names
        if !names.isEmpty {
            let shown = names.prefix(6).joined(separator: ", ")
            rows.append(("Names", Popover.value(names.count > 6 ? "\(shown) and \(names.count - 6) more" : shown, mono: true)))
        }
        rows.append(("Serial", Popover.value(leaf.serial, mono: true)))
        rows.append(("SHA-256", Popover.value(leaf.sha256, mono: true)))
        return Popover.grid(rows)
    }

    /// Leaf first, root last, each indented under the certificate that issued it.
    private func chainView() -> NSView {
        var rows: [NSView] = [NSTextField(labelWithAttributedString: Theme.sectionTitle("Chain"))]
        for (i, cert) in chain.reversed().enumerated() {
            let icon = NSImageView(image: Theme.symbol(i == 0 ? "checkmark.seal.fill" : "seal", size: 11) ?? NSImage())
            icon.contentTintColor = i == chain.count - 1 ? Theme.accent : .tertiaryLabelColor
            let name = NSTextField(labelWithString: cert.subject)
            name.font = .systemFont(ofSize: 12)
            name.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [icon, name])
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(i) * 14, bottom: 0, right: 0)
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    @objc func copyPEM() { Popover.copy(chain.map(\.pem).joined()) }

    /// macOS's own certificate viewer, with every extension and the trust evaluation.
    @objc private func showCertificate() {
        guard let trust, let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let host = url.host ?? ""
        view.window?.close()
        SFCertificateTrustPanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                                    trust: trust, message: "Certificate for \(host)")
    }
}

/// The URL breakdown: every part of the address as an editable field, query parameters as rows,
/// with copy buttons, and Open (↩) or Open in New Tab (⌘↩) to load the edited URL.
final class URLBreakdownController: NSViewController, NSTextFieldDelegate {
    /// Loads the edited URL; the flag is true for a new tab.
    var onOpen: ((URL, Bool) -> Void)?

    private let original: URLComponents
    let scheme = NSTextField()
    let host = NSTextField()
    let port = NSTextField()
    let path = NSTextField()
    let fragment = NSTextField()
    private let preview = Popover.value("", mono: true, width: 400)
    private let queryRows = NSStackView()
    private let queryScroll = NSScrollView()
    private let noQuery = NSTextField(labelWithString: "No query parameters")
    /// Each row's fields, and the parameter as it was percent-encoded in the original URL, so rows you
    /// don't touch come back byte for byte (a `+` stays a `+`).
    private var params: [(name: NSTextField, value: NSTextField, original: URLQueryItem?, decoded: URLQueryItem?)] = []
    private var copySources: [Int: () -> String] = [:]

    init(url: URL) {
        original = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let defaultPort = ["https": "443", "http": "80", "wss": "443", "ws": "80"][original.scheme ?? ""]
        let setup: [(NSTextField, String?, String?)] = [
            (scheme, original.scheme, nil), (host, original.host, nil), (port, original.port.map(String.init), defaultPort.map { "\($0) (default)" }),
            (path, original.path, "/"), (fragment, original.fragment, "none"),
        ]
        for (field, value, placeholder) in setup {
            field.stringValue = value ?? ""
            field.placeholderString = placeholder
            style(field)
        }
        port.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let grid = Popover.grid([
            ("Scheme", row(scheme)), ("Host", row(host)), ("Port", row(port)), ("Path", row(path)),
        ])
        grid.rowAlignment = .none
        grid.yPlacement = .center

        let add = HoverButton(symbol: "plus", size: 11, label: "Add Parameter", target: self, action: #selector(addParam))
        let queryHeader = NSStackView(views: [Popover.label("Query"), add])
        queryHeader.spacing = 4
        queryRows.orientation = .vertical
        queryRows.alignment = .leading
        queryRows.spacing = 6
        noQuery.textColor = .tertiaryLabelColor
        noQuery.font = .systemFont(ofSize: 12)
        let encoded = original.percentEncodedQueryItems ?? []
        let decoded = original.queryItems ?? []
        for (i, item) in encoded.enumerated() {
            appendParam(name: decoded[safe: i]?.name ?? item.name, value: decoded[safe: i]?.value ?? item.value ?? "",
                        original: item, decoded: decoded[safe: i])
        }
        let scroll = queryScroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        queryRows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(queryRows)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            queryRows.topAnchor.constraint(equalTo: document.topAnchor), queryRows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            queryRows.leadingAnchor.constraint(equalTo: document.leadingAnchor), queryRows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 448),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 216),
            scroll.heightAnchor.constraint(equalTo: document.heightAnchor).withPriority(.defaultHigh),
        ])

        let fragmentGrid = Popover.grid([("Fragment", row(fragment))])
        fragmentGrid.rowAlignment = .none
        fragmentGrid.yPlacement = .center
        // Line the fragment's field up with the ones above.
        fragmentGrid.column(at: 0).width = 64
        grid.column(at: 0).width = 64

        let copyURL = NSButton(title: "Copy URL", target: self, action: #selector(copyURLClicked))
        let openNew = NSButton(title: "Open in New Tab", target: self, action: #selector(openInNewTab))
        openNew.keyEquivalent = "\r"
        openNew.keyEquivalentModifierMask = .command
        let open = NSButton(title: "Open", target: self, action: #selector(openClicked))
        open.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [copyURL, spacer, openNew, open])
        buttons.spacing = 8

        let stack = Popover.stack([preview, grid, queryHeader, noQuery, scroll, fragmentGrid, buttons], spacing: 10)
        stack.setCustomSpacing(16, after: preview)
        stack.setCustomSpacing(4, after: queryHeader)
        stack.setCustomSpacing(16, after: fragmentGrid)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        view = stack
        refresh()
    }

    // MARK: Building the URL

    /// The URL the fields describe now.
    var url: URL? {
        var c = URLComponents()
        c.scheme = scheme.stringValue.isEmpty ? nil : scheme.stringValue
        c.percentEncodedUser = original.percentEncodedUser
        c.percentEncodedPassword = original.percentEncodedPassword
        c.host = host.stringValue.isEmpty ? nil : host.stringValue
        c.port = Int(port.stringValue)
        let p = path.stringValue
        c.path = c.host != nil && !p.isEmpty && !p.hasPrefix("/") ? "/" + p : p
        let items = params.compactMap { row -> URLQueryItem? in
            let name = row.name.stringValue, value = row.value.stringValue
            if name.isEmpty && value.isEmpty { return nil }
            if let decoded = row.decoded, let original = row.original, decoded.name == name, (decoded.value ?? "") == value { return original }
            return URLQueryItem(name: Self.encode(name), value: Self.encode(value))
        }
        c.percentEncodedQueryItems = items.isEmpty ? nil : items
        c.fragment = fragment.stringValue.isEmpty ? nil : fragment.stringValue
        return c.url
    }

    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? s }

    /// The query as name–value pairs, as the rows show them.
    var parameters: [(name: String, value: String)] { params.map { ($0.name.stringValue, $0.value.stringValue) } }

    func setParameter(at index: Int, name: String? = nil, value: String) {
        if let name { params[index].name.stringValue = name }
        params[index].value.stringValue = value
        refresh()
    }

    @objc func addParam() {
        appendParam(name: "", value: "", original: nil, decoded: nil)
        refresh()
        view.window?.makeFirstResponder(params.last?.name)
    }

    // MARK: Rows

    private func style(_ field: NSTextField) {
        field.font = Theme.monoFont(12)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    /// A field with a copy button after it.
    private func row(_ field: NSTextField) -> NSView {
        let stack = NSStackView(views: [field, copyButton { field.stringValue }])
        stack.spacing = 2
        return stack
    }

    private func copyButton(_ source: @escaping () -> String) -> NSButton {
        let button = HoverButton(symbol: "doc.on.doc", size: 10, label: "Copy", target: self, action: #selector(copyRow(_:)))
        button.tag = copySources.count
        copySources[button.tag] = source
        return button
    }

    private func appendParam(name: String, value: String, original: URLQueryItem?, decoded: URLQueryItem?) {
        let nameField = NSTextField(string: name), valueField = NSTextField(string: value)
        nameField.placeholderString = "name"
        valueField.placeholderString = "value"
        style(nameField)
        style(valueField)
        nameField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        valueField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let equals = NSTextField(labelWithString: "=")
        equals.font = Theme.monoFont(12)
        equals.textColor = .tertiaryLabelColor
        let remove = HoverButton(symbol: "minus.circle", size: 11, label: "Remove Parameter", target: self, action: #selector(removeParam(_:)))
        let row = NSStackView(views: [nameField, equals, valueField, copyButton { valueField.stringValue }, remove])
        row.spacing = 4
        queryRows.addArrangedSubview(row)
        params.append((nameField, valueField, original, decoded))
    }

    @objc private func removeParam(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView, let i = queryRows.arrangedSubviews.firstIndex(of: row) else { return }
        row.removeFromSuperview()
        params.remove(at: i)
        refresh()
    }

    private func refresh() {
        preview.stringValue = url?.absoluteString ?? "Not a valid URL"
        preview.textColor = url == nil ? .systemRed : .labelColor
        noQuery.isHidden = !params.isEmpty
        queryScroll.isHidden = params.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        open(newTab: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
        return true
    }

    @objc private func copyRow(_ sender: NSButton) { copySources[sender.tag].map { Popover.copy($0()) } }
    @objc private func copyURLClicked() { url.map { Popover.copy($0.absoluteString) } }
    @objc private func openClicked() { open(newTab: false) }
    @objc private func openInNewTab() { open(newTab: true) }
    private func open(newTab: Bool) { if let url { onOpen?(url, newTab) } }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
