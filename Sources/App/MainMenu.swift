import AppKit

/// Menus are built in code from `Command`, so every shortcut shown is the live keymap binding.
@MainActor
enum MainMenu {
    static func item(_ command: Command) -> NSMenuItem {
        let mi = NSMenuItem(title: command.title, action: #selector(AppDelegate.runMenuCommand(_:)), keyEquivalent: "")
        mi.representedObject = command.rawValue
        if let chord = Keymap.shared.primaryChord(for: command), let key = chord.menuKeyEquivalent {
            mi.keyEquivalent = key
            mi.keyEquivalentModifierMask = chord.flags
        }
        return mi
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    private static func std(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        return mi
    }

    static func build(extensionsMenuDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()

        main.addItem(menu("Tern", [
            std("About Tern", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            item(.showWelcome),
            .separator(),
            item(.openSettings),
            .separator(),
            item(.openKeymapFile),
            item(.reloadKeymap),
            .separator(),
            std("Hide Tern", #selector(NSApplication.hide(_:)), "h"),
            std("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            std("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            std("Quit Tern", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(menu("File", [
            item(.newTab), item(.newWindow), item(.focusAddressBar), .separator(),
            item(.closeTab), item(.closeWindow), item(.reopenClosedTab),
        ]))

        main.addItem(menu("Edit", [
            std("Undo", Selector(("undo:")), "z"),
            std("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            std("Cut", #selector(NSText.cut(_:)), "x"),
            std("Copy", #selector(NSText.copy(_:)), "c"),
            std("Paste", #selector(NSText.paste(_:)), "v"),
            std("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            std("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(.find), item(.findNext), item(.findPrevious),
            .separator(),
            item(.copyURL), item(.copyMarkdownLink),
        ]))

        main.addItem(menu("View", [
            item(.toggleSidebar), item(.commandPalette), item(.tabPicker), item(.linkHints), .separator(),
            item(.reload), item(.hardReload), item(.stopLoading), .separator(),
            item(.zoomIn), item(.zoomOut), item(.zoomReset), .separator(),
            std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(menu("History", [item(.goBack), item(.goForward), .separator(), item(.showHistory), item(.clearHistory)]))
        main.addItem(menu("Bookmarks", [item(.toggleBookmark), item(.showBookmarks)]))

        main.addItem(menu("Tabs", [
            item(.nextTab), item(.previousTab), item(.moveTabUp), item(.moveTabDown), item(.focusTabList), .separator(),
            item(.togglePinTab),
            item(.duplicateTab), item(.suspendBackgroundTabs), .separator(),
            item(.toggleSplit), item(.splitDown), item(.splitWith), item(.splitWithPreviousTab), item(.addPane), item(.removeFromSplit),
            item(.changeSplitLayout), item(.swapPanes), item(.focusLeftPane), item(.focusRightPane), item(.focusPaneAbove), item(.focusPaneBelow), .separator(),
        ] + [Command.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8, .selectLastTab].map(item)))

        main.addItem(menu("Develop", [item(.toggleInspector), item(.showConsole)]))

        let ext = menu("Extensions", [])
        ext.submenu?.delegate = extensionsMenuDelegate
        main.addItem(ext)

        let window = menu("Window", [
            std("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            std("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            std("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)

        return main
    }
}
