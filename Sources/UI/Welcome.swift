import AppKit

/// The first-run sheet: the few shortcuts that make Tern worth using, each with a "Try It" button.
/// Shortcuts come from the live keymap. "Welcome to Tern" in ⌘K shows it again.
@MainActor
final class Welcome: NSViewController {
    private static let seenKey = "welcomeSeen"

    private static let lessons: [(Command, String, String)] = [
        (.commandPalette, "Command palette", "Tabs, history, commands, or a URL. What you use most ranks first."),
        (.tabPicker, "Switch tabs", "Jump between open tabs in every window, most recent first."),
        (.toggleSplit, "Split view", "Two tabs side by side. You can also drag a tab from the sidebar onto the page."),
        (.linkHints, "Link hints", "Click any link or button on the page without the mouse."),
    ]

    static func showIfFirstRun(in browser: BrowserWindowController) {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        show(in: browser)
    }

    static func show(in browser: BrowserWindowController) {
        guard let window = browser.window, window.attachedSheet == nil else { return }
        let welcome = Welcome()
        let sheet = NSWindow(contentViewController: welcome)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        window.beginSheet(sheet) { [weak browser] _ in
            if !SmokeTest.isRunning { UserDefaults.standard.set(true, forKey: seenKey) }
            // Only once the sheet is fully gone, so a palette opened by Try It stays key.
            if let command = welcome.pendingCommand { CommandRouter.perform(command, in: browser) }
        }
    }

    /// The lesson's command to run after the sheet closes (Try It).
    private var pendingCommand: Command?

    override func loadView() {
        let title = NSTextField(labelWithString: "Welcome to Tern")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "A fast browser you drive from the keyboard. Four shortcuts to start with:")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)

        let rows = Self.lessons.enumerated().map { i, lesson in row(lesson, tag: i) }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14

        let done = NSButton(title: "Get Started", target: self, action: #selector(close))
        done.keyEquivalent = "\r"
        done.bezelStyle = .push
        done.controlSize = .large

        let stack = NSStackView(views: [title, subtitle, list, done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(26, after: list)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
        done.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -32).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        view = root
    }

    private func row(_ lesson: (Command, String, String), tag: Int) -> NSView {
        let (command, name, detail) = lesson
        let icon = NSImageView(image: Theme.symbol(command.symbol, size: 18) ?? NSImage())
        icon.contentTintColor = Theme.accent
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 280
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let keys = NSStackView(views: (Keymap.shared.primaryChord(for: command)?.glyphs ?? []).map(Self.keycap))
        keys.spacing = 3
        let tryIt = NSButton(title: "Try It", target: self, action: #selector(tryLesson(_:)))
        tryIt.tag = tag
        tryIt.bezelStyle = .push
        tryIt.controlSize = .small

        let row = NSStackView(views: [icon, text, keys, tryIt])
        row.alignment = .centerY
        row.spacing = 12
        row.setCustomSpacing(16, after: keys)
        return row
    }

    private static func keycap(_ glyph: String) -> NSView {
        let label = NSTextField(labelWithString: glyph)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        let cap = FilledView()
        cap.fill = Theme.keycapFill
        cap.border = Theme.hairline
        cap.radius = 5
        label.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)
        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: 22),
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -5),
        ])
        return cap
    }

    @objc private func tryLesson(_ sender: NSButton) {
        pendingCommand = Self.lessons[sender.tag].0
        close()
    }

    @objc func close() {
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }
}
