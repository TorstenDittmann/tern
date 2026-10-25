import AppKit
import WebKit

enum Command: String, CaseIterable {
    case newTab, newWindow, newPrivateWindow, closeTab, closeWindow, reopenClosedTab, duplicateTab
    case focusAddressBar, commandPalette, tabPicker, toggleSidebar, moveSidebar
    case reload, hardReload, stopLoading, goBack, goForward
    case nextTab, previousTab, moveTabUp, moveTabDown, focusTabList, togglePinTab
    case toggleSplit, splitDown, splitWith, splitWithPreviousTab, addPane, removeFromSplit, changeSplitLayout, swapPanes
    case focusLeftPane, focusRightPane, focusPaneAbove, focusPaneBelow
    case selectTab1, selectTab2, selectTab3, selectTab4, selectTab5, selectTab6, selectTab7, selectTab8, selectLastTab
    case find, findNext, findPrevious, linkHints
    case zoomIn, zoomOut, zoomReset
    case toggleInspector, showConsole, copyURL, copyMarkdownLink, showSiteInfo, urlBreakdown
    case suspendBackgroundTabs, openKeymapFile, reloadKeymap
    case loadUnpackedExtension, revealExtensionsFolder
    case toggleAgentAPI, clearHistory, showWelcome, openSettings
    case toggleBookmark, showHistory, showBookmarks
    case toggleSiteBlocking
    case responsiveDesignMode, rotateDevice, toggleReader
    case resetPinnedTab, repinTab, toggleCompactMode, showArchivedTabs
    case showDownloads, printPage, exportPDF, makeDefaultBrowser, toggleMuteTab, resetSitePermissions
    case fillPassword, showPasswords, showRequests

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newWindow: "New Window"
        case .newPrivateWindow: "New Private Window"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .duplicateTab: "Duplicate Tab"
        case .focusAddressBar: "Open Location…"
        case .commandPalette: "Command Palette…"
        case .tabPicker: "Switch to Tab…"
        case .toggleSidebar: "Toggle Sidebar"
        case .moveSidebar: MainActor.assumeIsolated { Preferences.sidebarOnRight } ? "Move Tab List to the Left" : "Move Tab List to the Right"
        case .reload: "Reload Page"
        case .hardReload: "Reload Ignoring Cache"
        case .stopLoading: "Stop Loading"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .toggleSplit: "Split View"
        case .splitDown: "Split Down"
        case .splitWith: "Split with…"
        case .splitWithPreviousTab: "Split with Previous Tab"
        case .addPane: "Add Pane to Split"
        case .removeFromSplit: "Remove Tab from Split"
        case .changeSplitLayout: "Change Split Layout"
        case .swapPanes: "Swap Split Panes"
        case .focusLeftPane: "Focus Left Pane"
        case .focusRightPane: "Focus Right Pane"
        case .focusPaneAbove: "Focus Pane Above"
        case .focusPaneBelow: "Focus Pane Below"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .moveTabUp: "Move Tab Up"
        case .moveTabDown: "Move Tab Down"
        case .focusTabList: "Filter Tabs…"
        case .togglePinTab: "Pin or Unpin Tab"
        case .selectTab1, .selectTab2, .selectTab3, .selectTab4,
             .selectTab5, .selectTab6, .selectTab7, .selectTab8: "Select Tab \(selectIndex! + 1)"
        case .selectLastTab: "Select Last Tab"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .linkHints: "Show Link Hints"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomReset: "Actual Size"
        case .toggleInspector: "Web Inspector"
        case .showConsole: "JavaScript Console"
        case .copyURL: "Copy URL"
        case .copyMarkdownLink: "Copy Markdown Link"
        case .showSiteInfo: "Connection and Certificate"
        case .urlBreakdown: "URL Breakdown"
        case .suspendBackgroundTabs: "Suspend Background Tabs"
        case .openKeymapFile: "Edit Key Bindings…"
        case .reloadKeymap: "Reload Key Bindings"
        case .loadUnpackedExtension: "Load Unpacked Extension…"
        case .revealExtensionsFolder: "Reveal Extensions Folder"
        case .toggleAgentAPI: AgentServer.isEnabled ? "Disable Agent API" : "Enable Agent API"
        case .clearHistory: "Clear History"
        case .showWelcome: "Welcome to Tern"
        case .openSettings: "Settings…"
        case .toggleBookmark: "Add or Remove Bookmark"
        case .showHistory: "Show History"
        case .showBookmarks: "Show Bookmarks"
        case .toggleSiteBlocking: "Toggle Ad Blocking for This Site"
        case .resetPinnedTab: "Back to Pinned Page"
        case .repinTab: "Make This the Pinned Page"
        case .toggleCompactMode: MainActor.assumeIsolated { Preferences.compactMode } ? "Leave Compact Mode" : "Compact Mode"
        case .showArchivedTabs: "Archived Tabs…"
        case .responsiveDesignMode: "Responsive Design Mode"
        case .rotateDevice: "Rotate Device"
        case .toggleReader: "Reader"
        case .showDownloads: "Show Downloads"
        case .printPage: "Print…"
        case .exportPDF: "Export as PDF…"
        case .makeDefaultBrowser: "Make Tern the Default Browser"
        case .toggleMuteTab: "Mute or Unmute Tab"
        case .resetSitePermissions: "Reset Permissions for This Site"
        case .fillPassword: "Fill Password"
        case .showPasswords: "Show Passwords"
        case .showRequests: "Requests"
        }
    }

    /// SF Symbol shown next to the command in the palette.
    var symbol: String {
        switch self {
        case .newTab: "plus.square"
        case .newWindow: "macwindow.badge.plus"
        case .newPrivateWindow: "eye.slash"
        case .closeTab: "xmark.square"
        case .closeWindow: "xmark.rectangle"
        case .reopenClosedTab: "arrow.uturn.backward.square"
        case .duplicateTab: "plus.square.on.square"
        case .focusAddressBar: "link"
        case .commandPalette: "command"
        case .tabPicker: "rectangle.stack"
        case .toggleSidebar: "sidebar.left"
        case .moveSidebar: "arrow.left.arrow.right.square"
        case .reload: "arrow.clockwise"
        case .hardReload: "arrow.clockwise.circle"
        case .stopLoading: "xmark.circle"
        case .goBack: "chevron.backward"
        case .goForward: "chevron.forward"
        case .toggleSplit: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .splitWith: "rectangle.split.2x1.fill"
        case .splitWithPreviousTab: "rectangle.righthalf.inset.filled"
        case .addPane: "rectangle.split.3x1"
        case .removeFromSplit: "rectangle"
        case .changeSplitLayout: "rectangle.split.2x2"
        case .swapPanes: "arrow.left.arrow.right"
        case .focusLeftPane: "rectangle.lefthalf.filled"
        case .focusRightPane: "rectangle.righthalf.filled"
        case .focusPaneAbove: "rectangle.tophalf.filled"
        case .focusPaneBelow: "rectangle.bottomhalf.filled"
        case .nextTab: "arrow.down.square"
        case .previousTab: "arrow.up.square"
        case .moveTabUp: "arrow.up.to.line"
        case .moveTabDown: "arrow.down.to.line"
        case .focusTabList: "line.3.horizontal.decrease"
        case .togglePinTab: "pin"
        case .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectLastTab: "number.square"
        case .find: "magnifyingglass"
        case .findNext: "chevron.down"
        case .findPrevious: "chevron.up"
        case .linkHints: "cursorarrow.rays"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .zoomReset: "1.magnifyingglass"
        case .toggleInspector: "hammer"
        case .showConsole: "terminal"
        case .copyURL: "doc.on.doc"
        case .copyMarkdownLink: "text.badge.plus"
        case .showSiteInfo: "lock"
        case .urlBreakdown: "list.bullet.indent"
        case .suspendBackgroundTabs: "moon.zzz"
        case .openKeymapFile: "keyboard"
        case .reloadKeymap: "arrow.triangle.2.circlepath"
        case .loadUnpackedExtension: "puzzlepiece.extension"
        case .revealExtensionsFolder: "folder"
        case .toggleAgentAPI: "point.3.connected.trianglepath.dotted"
        case .clearHistory: "clock.arrow.circlepath"
        case .showWelcome: "hand.wave"
        case .openSettings: "gearshape"
        case .toggleBookmark: "star"
        case .showHistory: "clock"
        case .showBookmarks: "book"
        case .toggleSiteBlocking: "shield.lefthalf.filled"
        case .resetPinnedTab: "pin.slash"
        case .repinTab: "pin.circle"
        case .toggleCompactMode: "rectangle.compress.vertical"
        case .showArchivedTabs: "archivebox"
        case .responsiveDesignMode: "iphone"
        case .rotateDevice: "rotate.right"
        case .toggleReader: "text.page"
        case .showDownloads: "arrow.down.circle"
        case .printPage: "printer"
        case .exportPDF: "doc.richtext"
        case .makeDefaultBrowser: "checkmark.seal"
        case .toggleMuteTab: "speaker.slash"
        case .resetSitePermissions: "hand.raised"
        case .fillPassword: "key.fill"
        case .showPasswords: "key"
        case .showRequests: "network"
        }
    }

    var selectIndex: Int? {
        let all: [Command] = [.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8]
        return all.firstIndex(of: self)
    }
}

@MainActor
enum CommandRouter {
    static func perform(_ command: Command, in browser: BrowserWindowController?) {
        let app = AppDelegate.shared

        // Commands that don't need a window.
        switch command {
        case .newWindow: app.openWindow(); return
        case .newPrivateWindow: app.openWindow(isPrivate: true); return
        case .reloadKeymap: app.reloadKeymap(); return
        case .openKeymapFile:
            Keymap.shared.ensureFileExists()
            NSWorkspace.shared.open(Keymap.fileURL); return
        case .suspendBackgroundTabs: TabSuspender.shared.suspendAllBackgroundTabs(); return
        case .toggleAgentAPI: AgentServer.shared.toggle(); return
        case .clearHistory: HistoryStore.shared.clear(); return
        case .moveSidebar:
            Preferences.sidebarOnRight.toggle()
            app.windows.forEach { $0.setSidebarOnRight(Preferences.sidebarOnRight) }
            SettingsWindow.shared.general.refresh()
            return
        case .openSettings: SettingsWindow.shared.show(); return
        case .showPasswords: SettingsWindow.shared.show(tab: SettingsWindow.passwordsTab); return
        case .showHistory: LibraryWindow.shared.show(.history); return
        case .showBookmarks: LibraryWindow.shared.show(.bookmarks); return
        case .loadUnpackedExtension: ExtensionManager.shared.promptLoadUnpacked(); return
        case .makeDefaultBrowser: DefaultBrowser.makeDefault(); return
        case .toggleCompactMode:
            Preferences.compactMode.toggle()
            app.windows.forEach { $0.setCompact(Preferences.compactMode) }
            return
        case .revealExtensionsFolder:
            NSWorkspace.shared.activateFileViewerSelecting([ExtensionManager.shared.unpackedFolder]); return
        default: break
        }

        guard let browser else {
            if command == .newTab { app.openWindow() }
            // ⌘W in Settings or another non-browser window closes it.
            if command == .closeTab || command == .closeWindow { NSApp.keyWindow?.performClose(nil) }
            return
        }
        let tab = browser.activeTab
        let webView = tab?.webView

        switch command {
        case .newTab: browser.newTab(url: nil)
        case .closeTab: if let tab { browser.closeOrResetPinned(tab) }
        case .closeWindow: browser.window?.performClose(nil)
        case .reopenClosedTab: browser.reopenClosedTab()
        case .duplicateTab: if let tab { browser.duplicate(tab) }
        case .focusAddressBar: browser.focusAddressBar()
        case .commandPalette: CommandPalette.toggle(for: browser, mode: .everything)
        case .tabPicker: CommandPalette.toggle(for: browser, mode: .tabs)
        case .toggleSidebar: browser.toggleSidebar()
        case .reload: webView?.reload()
        case .hardReload: webView?.reloadFromOrigin()
        case .stopLoading: webView?.stopLoading()
        case .goBack: webView?.goBack()
        case .goForward: webView?.goForward()
        case .toggleSplit: browser.toggleSplit()
        case .splitWith: CommandPalette.toggle(for: browser, mode: .splitWith)
        case .splitDown: browser.splitDown()
        case .splitWithPreviousTab: browser.splitWithPreviousTab()
        case .addPane: browser.addPane()
        case .removeFromSplit: if let tab { browser.removeFromSplit(tab) }
        case .changeSplitLayout: browser.setSplitLayout(nil)
        case .swapPanes: browser.swapPanes()
        case .focusLeftPane: browser.focusPane(.left)
        case .focusRightPane: browser.focusPane(.right)
        case .focusPaneAbove: browser.focusPane(.up)
        case .focusPaneBelow: browser.focusPane(.down)
        case .nextTab: browser.selectRelative(1)
        case .previousTab: browser.selectRelative(-1)
        case .moveTabUp: browser.moveActiveTab(by: -1)
        case .moveTabDown: browser.moveActiveTab(by: 1)
        case .focusTabList: browser.focusTabList()
        case .togglePinTab: if let tab { browser.setPinned(tab, !tab.isPinned) }
        case .selectLastTab: browser.select(index: browser.tabs.count - 1)
        case .find: browser.content.showFindBar()
        case .findNext: browser.content.findAgain(backwards: false)
        case .findPrevious: browser.content.findAgain(backwards: true)
        case .showWelcome: Welcome.show(in: browser)
        case .toggleBookmark: if let tab { BookmarkStore.shared.toggle(tab.currentURL, title: tab.pageTitle) }
        case .linkHints: Task { await LinkHints.start(in: browser) }
        case .zoomIn: webView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) }
        case .zoomOut: webView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.3) }
        case .zoomReset: webView?.pageZoom = 1
        case .toggleInspector: webView.map { Inspector.toggle($0) }
        case .showConsole: webView.map { Inspector.showConsole($0) }
        case .showRequests: if let tab { RequestInspector.show(for: tab) }
        case .showSiteInfo: browser.content.topBar.showSiteInfo()
        case .urlBreakdown: browser.content.topBar.showURLBreakdown()
        case .toggleSiteBlocking:
            ContentBlocker.shared.toggle(for: tab?.currentURL)
            webView?.reload()
        case .resetPinnedTab: if let tab, let url = tab.pinnedURL { tab.load(url) }
        case .repinTab: if let tab { browser.repin(tab) }
        case .showArchivedTabs: CommandPalette.toggle(for: browser, mode: .archived)
        case .responsiveDesignMode:
            if let tab { tab.devicePreview = tab.devicePreview == nil ? DevicePreview(preset: DevicePreview.lastPreset) : nil }
        case .rotateDevice: tab?.devicePreview?.landscape.toggle()
        case .toggleReader: if let tab { browser.content.toggleReader(for: tab) }
        case .showDownloads: browser.content.topBar.showDownloads()
        case .printPage: if let tab { PagePrinter.print(tab, in: browser.window) }
        case .exportPDF: if let tab { PagePrinter.exportPDF(tab, in: browser.window) }
        case .toggleMuteTab: tab?.isMuted.toggle()
        case .resetSitePermissions: if let url = tab?.currentURL { SitePermissions.reset(for: url) }
        case .fillPassword: if let tab { PasswordManager.shared.fill(in: tab, from: browser.content.topBar.field) }
        case .copyURL:
            if let url = tab?.currentURL { copy(url.absoluteString) }
        case .copyMarkdownLink:
            if let tab, let url = tab.currentURL { copy("[\(tab.displayTitle)](\(url.absoluteString))") }
        default:
            if let i = command.selectIndex { browser.select(index: i) }
        }
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// WKWebView has no public API to open the inspector programmatically; `isInspectable` only
/// enables the context-menu entry. `_inspector` is SPI — fine for a dev browser, not for the App Store.
@MainActor
enum Inspector {
    private static func inspector(_ webView: WKWebView) -> NSObject? {
        let sel = NSSelectorFromString("_inspector")
        guard webView.responds(to: sel) else { return nil }
        return webView.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    static func toggle(_ webView: WKWebView) {
        guard let i = inspector(webView) else { return }
        let visible = (i.value(forKey: "visible") as? Bool) ?? false
        i.perform(NSSelectorFromString(visible ? "close" : "show"))
    }

    static func showConsole(_ webView: WKWebView) {
        inspector(webView)?.perform(NSSelectorFromString("showConsole"))
    }
}
