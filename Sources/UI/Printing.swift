import AppKit
import UniformTypeIdentifiers
import WebKit

/// Print (⌥⌘P) and Export as PDF. Both go through WebKit's print operation, so a PDF is paginated
/// the way the page would print, with its print styles.
@MainActor
enum PagePrinter {
    static func print(_ tab: Tab, in window: NSWindow?) {
        guard let webView = tab.webView else { return }
        let op = operation(for: webView, info: printInfo())
        op.jobTitle = tab.displayTitle
        run(op, in: window, completion: nil)
    }

    static func exportPDF(_ tab: Tab, in window: NSWindow?) {
        guard let webView = tab.webView, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = filename(for: tab) + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            writePDF(of: webView, title: tab.displayTitle, to: url, in: window, completion: nil)
        }
    }

    /// Prints the page to a PDF file without asking anything.
    static func writePDF(of webView: WKWebView, title: String, to url: URL, in window: NSWindow?, completion: ((Bool) -> Void)?) {
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        let op = operation(for: webView, info: info)
        op.jobTitle = title
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        run(op, in: window, completion: completion)
    }

    private static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    private static func operation(for webView: WKWebView, info: NSPrintInfo) -> NSPrintOperation {
        let op = webView.printOperation(with: info)
        // Without a frame WebKit's print view lays out at zero size and prints blank pages.
        op.view?.frame = webView.bounds
        return op
    }

    private static func run(_ op: NSPrintOperation, in window: NSWindow?, completion: ((Bool) -> Void)?) {
        guard let window else { let ok = op.run(); completion?(ok); return }
        let callback = PrintCallback(completion: completion)
        op.runModal(for: window, delegate: callback, didRun: #selector(PrintCallback.printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: Unmanaged.passRetained(callback).toOpaque())
    }

    /// The page title as a file name: no slashes or colons, and not too long.
    static func filename(for tab: Tab) -> String {
        let cleaned = tab.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Page" : String(cleaned.prefix(120))
    }
}

/// Receives the print sheet's result. It retains itself through `contextInfo` until then.
private final class PrintCallback: NSObject {
    let completion: ((Bool) -> Void)?
    init(completion: ((Bool) -> Void)?) { self.completion = completion }

    @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintCallback>.fromOpaque(contextInfo).release() }
        completion?(success)
    }
}

/// Whether Tern opens web links on this Mac, and asking macOS to make it so.
@MainActor
enum DefaultBrowser {
    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm. Setting http covers https too.
    static func makeDefault(completion: ((Bool) -> Void)? = nil) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error { NSLog("Tern: couldn't become the default browser: \(error.localizedDescription)") }
                    SettingsWindow.shared.general.refresh()
                    completion?(error == nil)
                }
            }
        }
    }
}
