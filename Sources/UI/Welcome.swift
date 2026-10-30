import AppKit

/// The first-run welcome: five short pages in a sheet over the first window. Hello; make it yours (tab list
/// side, compact mode, default browser); four shortcuts you practice by pressing them; Safari extensions;
/// and the agent API. ← → or ↩ move between pages, esc skips. "Welcome to Tern" in ⌘K shows it again.
@MainActor
final class Welcome: NSViewController {
    private static let seenKey = "welcomeSeen"

    /// The open welcome. It sees key presses before the keymap, so the practice page can catch shortcuts
    /// without running them.
    private(set) static weak var active: Welcome?

    static let lessons: [(Command, String, String)] = [
        (.commandPalette, "Command palette", "Tabs, history, commands, or a URL. What you use most ranks first."),
        (.tabPicker, "Switch tabs", "Jump between open tabs in every window, most recent first."),
        (.toggleSplit, "Split view", "Two tabs side by side. Or drag a tab onto the page."),
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
        active = welcome
        window.beginSheet(sheet) { _ in
            if !SmokeTest.isRunning { UserDefaults.standard.set(true, forKey: seenKey) }
            if active === welcome { active = nil }
        }
    }

    // MARK: State

    private var pages: [NSView] = []
    private(set) var page = 0
    var pageCount: Int { pages.count }
    private let dots = PageDots(count: 5)
    private lazy var backButton = NSButton(title: "Back", target: self, action: #selector(back))
    private lazy var nextButton = NSButton(title: "Get Started", target: self, action: #selector(next))
    private lazy var skipButton = NSButton(title: "Skip", target: self, action: #selector(close))
    private var flagsMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    private let mark = TernMark()
    private var helloLines: [NSView] = []
    private var didGreet = false

    private var layoutChoices: [LayoutChoice] = []
    private let compactSwitch = NSSwitch()
    private lazy var defaultBrowserButton = NSButton(title: "Make Tern the Default Browser", target: self, action: #selector(makeDefault))
    private let defaultBrowserDone = CheckLabel("Tern is your default browser")

    private var lessonRows: [LessonRow] = []
    /// Lessons pressed on the practice page, by index into `lessons`.
    private(set) var practiced: Set<Int> = []
    private let practiceHint = NSTextField(labelWithString: "")

    private let extensionList = NSStackView()
    private var extensionItems: [ExtensionManager.Available] = []
    private var extensionSwitches: [NSSwitch] = []

    private let agentSwitch = NSSwitch()
    private lazy var copyButton = HoverButton(symbol: "doc.on.doc", size: 12, label: "Copy", target: self, action: #selector(copySnippet))
    private static var mcpCommand: String {
        "claude mcp add tern -- \(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tern").path) mcp"
    }

    // MARK: Layout

    override func loadView() {
        let root = WelcomeBackdrop()
        pages = [helloPage(), personalizePage(), practicePage(), extensionsPage(), agentsPage()]
        let stage = NSView()
        for (i, p) in pages.enumerated() {
            p.wantsLayer = true
            p.isHidden = i != 0
            p.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: stage.topAnchor), p.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
                p.leadingAnchor.constraint(equalTo: stage.leadingAnchor), p.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            ])
        }

        skipButton.bezelStyle = .accessoryBarAction
        skipButton.keyEquivalent = "\u{1b}"
        backButton.bezelStyle = .push
        backButton.controlSize = .large
        nextButton.bezelStyle = .push
        nextButton.controlSize = .large
        nextButton.keyEquivalent = "\r"
        backButton.isHidden = true
        let buttons = NSStackView(views: [backButton, nextButton])
        buttons.spacing = 8

        let rule = FilledView()
        rule.fill = Theme.hairline
        for v in [stage, rule, skipButton, dots, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 640),
            root.heightAnchor.constraint(equalToConstant: 470),
            stage.topAnchor.constraint(equalTo: root.topAnchor),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -60),
            skipButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            skipButton.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -30),
            dots.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dots.centerYAnchor.constraint(equalTo: skipButton.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            buttons.centerYAnchor.constraint(equalTo: skipButton.centerYAnchor),
        ])
        view = root
        refreshSettings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChanged(event) }
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: ExtensionManager.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSettings() }
            },
            // Back from a permission prompt or System Settings: what changed out there shows here.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: view.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSettings() }
            },
        ]
        greet()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: Pages

    private func helloPage() -> NSView {
        let title = NSTextField(labelWithString: "Welcome to Tern")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.alignment = .center
        let subtitle = NSTextField(labelWithString: "A fast browser you drive from the keyboard.")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        let note = NSTextField(labelWithString: "Native WebKit · Vertical tabs · Split view · Built for agents")
        note.font = Theme.monoFont(11)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        helloLines = [title, subtitle, note]
        helloLines.forEach { $0.wantsLayer = true }

        let stack = NSStackView(views: [mark, title, subtitle, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(26, after: mark)
        stack.setCustomSpacing(22, after: subtitle)
        return centered(stack, offset: -6)
    }

    private func personalizePage() -> NSView {
        let left = LayoutChoice(onRight: false) { [weak self] in self?.setSidebar(right: false) }
        let right = LayoutChoice(onRight: true) { [weak self] in self?.setSidebar(right: true) }
        layoutChoices = [left, right]
        let choices = NSStackView(views: layoutChoices)
        choices.spacing = 16

        compactSwitch.target = self
        compactSwitch.action = #selector(compactChanged)
        defaultBrowserButton.bezelStyle = .push
        let defaultCell = NSStackView(views: [defaultBrowserButton, defaultBrowserDone])

        let rows = NSStackView(views: [
            Self.settingRow("Compact mode", "Hide the top bar until you point at the top edge or press ⌘L.", compactSwitch),
            Self.settingRow("Default browser", "Open links from other apps in Tern.", defaultCell),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        return page("Make it yours", "Pick a side for the tab list. You can change all of this later in Settings.",
                    [choices, rows], spacing: 24)
    }

    private func practicePage() -> NSView {
        lessonRows = Self.lessons.map { command, name, detail in
            LessonRow(symbol: command.symbol, name: name, detail: detail, glyphs: Keymap.shared.primaryChord(for: command)?.glyphs ?? [])
        }
        let list = NSStackView(views: lessonRows)
        list.orientation = .vertical
        list.spacing = 6
        lessonRows.forEach { $0.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        practiceHint.font = .systemFont(ofSize: 12)
        practiceHint.textColor = .secondaryLabelColor
        let content = page("Four keys to start with", "Press each shortcut to tick it off. Nothing runs while you practice.",
                           [list, practiceHint], spacing: 14)
        list.widthAnchor.constraint(equalToConstant: 640 - 88).isActive = true
        updatePractice()
        return content
    }

    private func extensionsPage() -> NSView {
        extensionList.orientation = .vertical
        extensionList.alignment = .leading
        extensionList.spacing = 8
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let document = FlippedView()
        extensionList.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(extensionList)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            extensionList.topAnchor.constraint(equalTo: document.topAnchor),
            extensionList.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            extensionList.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            extensionList.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 640 - 88),
            scroll.heightAnchor.constraint(equalToConstant: 216),
        ])
        return page("Bring your extensions", "Tern runs Safari Web Extensions installed with your apps, like Proton Pass. Each one runs only once you turn it on.",
                    [scroll], spacing: 20)
    }

    private func agentsPage() -> NSView {
        agentSwitch.target = self
        agentSwitch.action = #selector(agentChanged)
        let api = Self.settingRow("Agent API", "A local socket only your user account can reach. Nothing listens on the network.", agentSwitch)

        let code = NSTextField(labelWithString: "$ " + Self.mcpCommand)
        code.font = Theme.monoFont(11.5)
        code.lineBreakMode = .byTruncatingMiddle
        code.isSelectable = true
        code.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let box = FilledView()
        box.fill = Theme.recessedFill
        box.border = Theme.hairline
        box.radius = 8
        for v in [code, copyButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 38),
            box.widthAnchor.constraint(equalToConstant: 640 - 88),
            code.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            code.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            code.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            copyButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        let codeLabel = NSTextField(labelWithAttributedString: Theme.sectionTitle("Add Tern to Claude Code"))
        let other = NSTextField(wrappingLabelWithString: "Any other MCP client can run `tern mcp`, and the `tern` command drives Tern from a shell.")
        other.font = .systemFont(ofSize: 12)
        other.textColor = .secondaryLabelColor

        let tag = NSTextField(labelWithString: "Agent is driving")
        tag.font = .systemFont(ofSize: 11, weight: .semibold)
        tag.textColor = .white
        let pill = FilledView()
        pill.fill = AgentRingView.color
        pill.radius = 9
        tag.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(tag)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 18),
            tag.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            tag.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            tag.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        let ringNote = NSTextField(labelWithString: "A purple ring marks any tab an agent is driving.")
        ringNote.font = .systemFont(ofSize: 12)
        ringNote.textColor = .secondaryLabelColor
        let ring = NSStackView(views: [pill, ringNote])
        ring.spacing = 10

        let snippet = NSStackView(views: [codeLabel, box, other])
        snippet.orientation = .vertical
        snippet.alignment = .leading
        snippet.spacing = 8
        return page("Let your agents drive", "Claude Code and other agents can open tabs, read the page, click and type in your real, signed-in browser.",
                    [api, snippet, ring], spacing: 22)
    }

    /// A page: title and subtitle at the top left, then `content`.
    private func page(_ title: String, _ subtitle: String, _ content: [NSView], spacing: CGFloat) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: subtitle)
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 640 - 88
        let stack = NSStackView(views: [titleLabel, sub] + content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.setCustomSpacing(6, after: titleLabel)
        stack.setCustomSpacing(spacing + 4, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -44),
        ])
        return container
    }

    private func centered(_ content: NSView, offset: CGFloat) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: offset),
        ])
        return container
    }

    /// A name and a line of detail on the left, a control on the right.
    private static func settingRow(_ name: String, _ detail: String, _ control: NSView) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 330
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [text, NSView(), control])
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: 640 - 88).isActive = true
        return row
    }

    // MARK: Moving between pages

    @objc private func next() {
        if page == pages.count - 1 { return close() }
        go(to: page + 1)
    }

    @objc private func back() { go(to: page - 1) }

    func go(to index: Int) {
        guard pages.indices.contains(index), index != page else { return }
        let forward = index > page
        let old = pages[page], new = pages[index]
        page = index
        dots.select(index)
        nextButton.title = index == 0 ? "Get Started" : index == pages.count - 1 ? "Start Browsing" : "Continue"
        Motion.fade(backButton, visible: index > 0)
        if index == 3 { refreshSettings() }

        new.layer?.removeAllAnimations()
        new.isHidden = false
        let shift: CGFloat = forward ? 28 : -28
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                old.layer?.removeAllAnimations()
                if let self, self.pages.indices.contains(self.page), self.pages[self.page] !== old { old.isHidden = true }
            }
        }
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = Motion.fast
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        old.layer?.add(fadeOut, forKey: "fade")
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = Motion.standard
        fadeIn.timingFunction = Motion.easeOut
        new.layer?.add(fadeIn, forKey: "fade")
        if !Motion.reduceMotion {
            let away = CABasicAnimation(keyPath: "transform")
            away.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(-shift, 0, 0))
            away.duration = Motion.fast
            away.fillMode = .forwards
            away.isRemovedOnCompletion = false
            old.layer?.add(away, forKey: "slide")
            let arrive = Motion.spring("transform", stiffness: 340, damping: 32)
            arrive.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(shift, 0, 0))
            arrive.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            new.layer?.add(arrive, forKey: "slide")
        }
        CATransaction.commit()
    }

    @objc func close() {
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    // MARK: Hello

    /// The mark draws itself, then the words rise in under it.
    private func greet() {
        guard !didGreet else { return }
        didGreet = true
        let still = Motion.reduceMotion || SmokeTest.isRunning
        mark.draw(animated: !still)
        guard !still else { return }
        for (i, line) in helloLines.enumerated() {
            guard let layer = line.layer else { continue }
            let begin = CACurrentMediaTime() + 0.45 + Double(i) * 0.08
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.35
            fade.beginTime = begin
            fade.fillMode = .backwards
            fade.timingFunction = Motion.easeOut
            let rise = Motion.spring("transform", stiffness: 260, damping: 26)
            rise.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -10, 0))
            rise.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            rise.beginTime = begin
            rise.fillMode = .backwards
            layer.add(fade, forKey: "fade")
            layer.add(rise, forKey: "rise")
        }
    }

    // MARK: Make it yours

    private func setSidebar(right: Bool) {
        Preferences.sidebarOnRight = right
        AppDelegate.shared.windows.forEach { $0.setSidebarOnRight(right) }
        SettingsWindow.shared.general.refresh()
        refreshSettings()
    }

    @objc private func compactChanged() {
        Preferences.compactMode = compactSwitch.state == .on
        AppDelegate.shared.windows.forEach { $0.setCompact(Preferences.compactMode) }
    }

    @objc private func makeDefault() {
        DefaultBrowser.makeDefault { [weak self] ok in
            guard let self, ok else { return }
            self.refreshSettings()
            Motion.pop(self.defaultBrowserDone)
        }
    }

    /// Settings, extensions and the agent API as they are now (they can change outside the welcome).
    private func refreshSettings() {
        layoutChoices.forEach { $0.isSelected = $0.onRight == Preferences.sidebarOnRight }
        compactSwitch.state = Preferences.compactMode ? .on : .off
        let isDefault = DefaultBrowser.isDefault
        defaultBrowserButton.isHidden = isDefault
        defaultBrowserDone.isHidden = !isDefault
        agentSwitch.state = AgentServer.isEnabled ? .on : .off
        rebuildExtensions()
    }

    // MARK: Practice

    /// Called before the keymap sees a key: on the practice page, a lesson's shortcut ticks it off instead of
    /// running. ← and → move between pages. Returns whether the key was used.
    func handle(_ event: NSEvent) -> Bool {
        guard let window = view.window, window.isKeyWindow else { return false }
        return press(event)
    }

    /// `handle` once the welcome is known to have the keys (the smoke test calls it directly).
    func press(_ event: NSEvent) -> Bool {
        let chord = KeyChord(event: event)
        if page == 2, let i = Self.lessons.firstIndex(where: { Keymap.shared.primaryChord(for: $0.0) == chord }) {
            practice(i)
            return true
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 123: if page > 0 { back() }; return true // ←
        case 124: next(); return true                 // →
        default: return false
        }
    }

    /// Marks lesson `i` as done (also called by the smoke test).
    func practice(_ i: Int) {
        guard lessonRows.indices.contains(i) else { return }
        let first = !practiced.contains(i)
        practiced.insert(i)
        lessonRows[i].pressed()
        if first { lessonRows[i].complete() }
        updatePractice()
    }

    private func modifiersChanged(_ event: NSEvent) {
        guard page == 2, view.window?.isKeyWindow == true else { return }
        let flags = event.modifierFlags
        lessonRows.forEach { $0.hold(flags) }
    }

    private var nextLesson: Int? {
        Self.lessons.indices.first { !practiced.contains($0) && Keymap.shared.primaryChord(for: Self.lessons[$0].0) != nil }
    }

    private func updatePractice() {
        let next = nextLesson
        for (i, row) in lessonRows.enumerated() { row.isNext = i == next }
        if let next {
            let glyphs = Keymap.shared.primaryChord(for: Self.lessons[next].0)?.glyphs.joined() ?? ""
            practiceHint.stringValue = practiced.isEmpty ? "Try \(glyphs) now." : "\(practiced.count) of \(Self.lessons.count). Next: \(glyphs)"
            practiceHint.textColor = .secondaryLabelColor
        } else {
            practiceHint.stringValue = "All four. You're ready to go."
            practiceHint.textColor = Theme.accent
        }
    }

    // MARK: Extensions

    private func rebuildExtensions() {
        let items = ExtensionManager.shared.available
        // Same list: just bring the switches up to date, so a switch being clicked isn't replaced.
        if items.map(\.id) == extensionItems.map(\.id), !extensionList.arrangedSubviews.isEmpty {
            for (item, toggle) in zip(items, extensionSwitches) { toggle.state = ExtensionManager.shared.isEnabled(item) ? .on : .off }
            return
        }
        extensionItems = items
        extensionSwitches = []
        extensionList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !items.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No extensions found yet. Safari Web Extensions that come with apps in /Applications show up here, and Extensions ▸ Load Unpacked Extension… adds a folder or a .zip.")
            empty.font = .systemFont(ofSize: 12.5)
            empty.textColor = .secondaryLabelColor
            empty.preferredMaxLayoutWidth = 640 - 88
            extensionList.addArrangedSubview(empty)
            return
        }
        for (i, item) in items.enumerated() {
            let toggle = NSSwitch()
            toggle.tag = i
            toggle.target = self
            toggle.action = #selector(extensionChanged(_:))
            toggle.state = ExtensionManager.shared.isEnabled(item) ? .on : .off
            extensionSwitches.append(toggle)
            let row = ExtensionRow(item: item, toggle: toggle)
            extensionList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: extensionList.widthAnchor).isActive = true
        }
    }

    @objc private func extensionChanged(_ sender: NSSwitch) {
        guard extensionItems.indices.contains(sender.tag) else { return }
        ExtensionManager.shared.toggle(extensionItems[sender.tag])
    }

    // MARK: Agents

    @objc private func agentChanged() {
        if (agentSwitch.state == .on) != AgentServer.isEnabled { AgentServer.shared.toggle() }
    }

    @objc private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.mcpCommand, forType: .string)
        copyButton.image = Theme.symbol("checkmark", size: 12, weight: .bold)
        copyButton.contentTintColor = Theme.accent
        copyButton.toolTip = "Copied"
        Motion.pop(copyButton)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                self?.copyButton.image = Theme.symbol("doc.on.doc", size: 12)
                self?.copyButton.contentTintColor = .secondaryLabelColor
                self?.copyButton.toolTip = "Copy"
            }
        }
    }
}

// MARK: - Pieces

/// The ground with a soft accent glow at the top, like the landing page.
private final class WelcomeBackdrop: NSView {
    private let glow = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 1)
        glow.endPoint = CGPoint(x: 1.1, y: 0.1)
        layer?.addSublayer(glow)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.ground.cgColor
        glow.colors = [Theme.accent.withAlphaComponent(effectiveAppearance.isDark ? 0.13 : 0.09).cgColor, NSColor.clear.cgColor]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Tern's mark (the bird from the landing page) as a stroke that can draw itself, with a light accent fill.
final class TernMark: NSView {
    private let stroke = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let side: CGFloat = 92

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        stroke.fillColor = nil
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.strokeEnd = 0
        fill.opacity = 0
        layer?.addSublayer(fill)
        layer?.addSublayer(stroke)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side)])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Tern")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The landing page's 24-point path, scaled to this view (y flipped for AppKit).
    private static func path(in rect: CGRect) -> CGPath {
        let s = rect.width / 24
        var t = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: rect.minX, ty: rect.maxY)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2.5, y: 9.5))
        p.addCurve(to: CGPoint(x: 10.7, y: 12.9), control1: CGPoint(x: 5.7, y: 9.3), control2: CGPoint(x: 8.5, y: 10.4))
        p.addLine(to: CGPoint(x: 12, y: 14.5))
        p.addLine(to: CGPoint(x: 13.4, y: 12.8))
        p.addCurve(to: CGPoint(x: 21.5, y: 8.5), control1: CGPoint(x: 16.0, y: 9.8), control2: CGPoint(x: 19.0, y: 8.4))
        p.addCurve(to: CGPoint(x: 16.2, y: 14.6), control1: CGPoint(x: 19.3, y: 9.8), control2: CGPoint(x: 17.5, y: 11.8))
        p.addLine(to: CGPoint(x: 15, y: 17))
        p.addLine(to: CGPoint(x: 12, y: 21))
        p.addLine(to: CGPoint(x: 9, y: 17))
        p.addLine(to: CGPoint(x: 7.8, y: 14.6))
        p.addCurve(to: CGPoint(x: 2.5, y: 9.5), control1: CGPoint(x: 6.6, y: 12.3), control2: CGPoint(x: 4.8, y: 10.6))
        p.closeSubpath()
        return p.copy(using: &t) ?? p
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = Self.path(in: bounds)
        for l in [stroke, fill] { l.frame = bounds; l.path = path }
        stroke.lineWidth = 1.4 * bounds.width / 24
        CATransaction.commit()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        stroke.strokeColor = Theme.accent.cgColor
        fill.fillColor = Theme.accent.withAlphaComponent(0.16).cgColor
    }

    /// Strokes the outline in, then fades the fill up. Without `animated`, just shows it.
    func draw(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.strokeEnd = 1
        fill.opacity = 1
        CATransaction.commit()
        guard animated else { return }
        let trace = CABasicAnimation(keyPath: "strokeEnd")
        trace.fromValue = 0
        trace.toValue = 1
        trace.duration = 0.9
        trace.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        stroke.add(trace, forKey: "trace")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.4
        fade.beginTime = CACurrentMediaTime() + 0.7
        fade.fillMode = .backwards
        fill.add(fade, forKey: "fade")
        let settle = Motion.spring("transform", stiffness: 200, damping: 18)
        settle.fromValue = NSValue(caTransform3D: Motion.scale(0.86, size: bounds.size))
        settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer?.add(settle, forKey: "settle")
    }
}

/// Five dots; the current one stretches into a short accent pill.
private final class PageDots: NSView {
    private var dots: [CALayer] = []
    private var current = 0
    private static let dot: CGFloat = 6, wide: CGFloat = 18, gap: CGFloat = 6

    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        dots = (0..<count).map { _ in
            let d = CALayer()
            d.cornerRadius = Self.dot / 2
            layer?.addSublayer(d)
            return d
        }
        let width = Self.wide + CGFloat(count - 1) * (Self.dot + Self.gap)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: Self.dot)])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        place(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ index: Int) {
        current = index
        place(animated: true)
    }

    private func place(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduceMotion)
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        var x: CGFloat = 0
        for (i, d) in dots.enumerated() {
            let w = i == current ? Self.wide : Self.dot
            d.frame = CGRect(x: x, y: 0, width: w, height: Self.dot)
            x += w + Self.gap
        }
        CATransaction.commit()
        setAccessibilityLabel("Page \(current + 1) of \(dots.count)")
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        for (i, d) in dots.enumerated() {
            d.backgroundColor = (i == current ? Theme.accent : NSColor.tertiaryLabelColor.withAlphaComponent(0.45)).cgColor
        }
        CATransaction.commit()
    }
}

/// A small picture of a window with the tab list on one side. Click to pick that side.
private final class LayoutChoice: NSView {
    let onRight: Bool
    private let onPick: () -> Void
    private let label: NSTextField
    var isSelected = false { didSet { needsDisplay = true; label.textColor = isSelected ? .labelColor : .secondaryLabelColor } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(onRight: Bool, onPick: @escaping () -> Void) {
        self.onRight = onRight
        self.onPick = onPick
        label = NSTextField(labelWithString: onRight ? "Tabs on the right" : "Tabs on the left")
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 200), heightAnchor.constraint(equalToConstant: 140),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label.stringValue)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), !isSelected else { return }
        onPick()
        Motion.pop(self, from: 0.96)
    }
    override func accessibilityPerformPress() -> Bool { onPick(); return true }
    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSRect(x: 1, y: 24, width: bounds.width - 2, height: bounds.height - 25)
        let window = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
        Theme.surface.setFill()
        window.fill()
        (isSelected ? Theme.accent : hovering ? NSColor.tertiaryLabelColor : Theme.hairline).setStroke()
        window.lineWidth = isSelected ? 2 : 1
        window.stroke()

        // Traffic lights, then the tab list and the page card.
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: frame.minX + 9 + CGFloat(i) * 8, y: frame.maxY - 12, width: 5, height: 5)).fill()
        }
        let inner = frame.insetBy(dx: 8, dy: 8)
        let listWidth: CGFloat = 46
        let list = NSRect(x: onRight ? inner.maxX - listWidth : inner.minX, y: inner.minY, width: listWidth, height: inner.height - 10)
        let card = NSRect(x: onRight ? inner.minX : inner.minX + listWidth + 6, y: inner.minY,
                          width: inner.width - listWidth - 6, height: inner.height - (onRight ? 0 : 10))
        Theme.ground.setFill()
        NSBezierPath(roundedRect: card, xRadius: 5, yRadius: 5).fill()
        for i in 0..<5 {
            let row = NSRect(x: list.minX, y: list.maxY - 10 - CGFloat(i) * 12, width: list.width, height: 8)
            if i == 1 {
                (isSelected ? Theme.accent.withAlphaComponent(0.35) : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)).setFill()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
            }
            NSBezierPath(roundedRect: row, xRadius: 3, yRadius: 3).fill()
        }
    }
}

/// One shortcut on the practice page: icon, name and detail, its keycaps, and a circle that ticks.
private final class LessonRow: FilledView {
    private let status = NSImageView()
    private let caps: [Keycap]
    private let nameLabel: NSTextField
    private var done = false
    var isNext = false { didSet { fill = isNext ? Theme.hoverFill : .clear; border = isNext ? Theme.hairline : nil } }

    init(symbol: String, name: String, detail: String, glyphs: [String]) {
        caps = glyphs.map(Keycap.init)
        nameLabel = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        radius = 10
        let icon = NSImageView(image: Theme.symbol(symbol, size: 16) ?? NSImage())
        icon.contentTintColor = Theme.accent
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keys = NSStackView(views: caps.isEmpty ? [NSTextField(labelWithString: "Unbound")] : caps)
        keys.spacing = 3
        // A fixed column, right-aligned, so every row's keys line up.
        keys.alignment = .centerY
        keys.setHuggingPriority(.defaultLow, for: .horizontal)
        keys.widthAnchor.constraint(equalToConstant: 96).isActive = true
        keys.setViews(keys.arrangedSubviews, in: .trailing)
        status.image = Theme.symbol("circle", size: 15, weight: .regular)
        status.contentTintColor = .tertiaryLabelColor
        status.wantsLayer = true
        status.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let row = NSStackView(views: [icon, text, keys, status])
        row.alignment = .centerY
        row.spacing = 12
        row.setCustomSpacing(14, after: keys)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 54),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lights the keycaps for the modifiers held right now (on the row that's up next).
    func hold(_ flags: NSEvent.ModifierFlags) {
        guard isNext else { return caps.forEach { $0.isPressed = false } }
        caps.forEach { $0.isPressed = $0.modifier.map(flags.contains) ?? false }
    }

    /// The whole chord went down: every cap presses, then lets go.
    func pressed() {
        caps.forEach { $0.tap() }
    }

    func complete() {
        guard !done else { return }
        done = true
        status.image = Theme.symbol("checkmark.circle.fill", size: 15, weight: .semibold)
        status.contentTintColor = Theme.accent
        Motion.pop(status, from: 0.3)
    }
}

/// A key as a small rounded cap. Pressed, it fills with the accent.
private final class Keycap: NSView {
    let modifier: NSEvent.ModifierFlags?
    private let label: NSTextField
    var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true; label.textColor = isPressed ? Theme.accent : .labelColor } } }

    init(_ glyph: String) {
        let modifiers: [String: NSEvent.ModifierFlags] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .command]
        modifier = modifiers[glyph]
        label = NSTextField(labelWithString: glyph)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func tap() {
        isPressed = true
        Motion.pop(self, from: 0.86)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in MainActor.assumeIsolated { self?.isPressed = false } }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = (isPressed ? Theme.accent : Theme.hairline).cgColor
        Motion.setBackground(layer, (isPressed ? Theme.accentWash : Theme.keycapFill).cgColor)
    }
}

/// A check and a line, for a setting that's already done.
private final class CheckLabel: NSStackView {
    init(_ text: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: Theme.symbol("checkmark.circle.fill", size: 13, weight: .semibold) ?? NSImage())
        icon.contentTintColor = Theme.accent
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        setViews([icon, label], in: .leading)
        spacing = 5
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An extension on the extensions page: its app's icon, name, where it comes from, and a switch.
private final class ExtensionRow: FilledView {
    init(item: ExtensionManager.Available, toggle: NSSwitch) {
        super.init(frame: .zero)
        fill = Theme.surface
        border = Theme.hairline
        radius = 10
        let icon = NSImageView()
        let source: String
        switch item.source {
        case let .safari(appex, app):
            let bundle = appex.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            icon.image = NSWorkspace.shared.icon(forFile: bundle.path)
            source = "Safari extension from \(app)"
        case let .unpacked(url):
            icon.image = Theme.symbol("puzzlepiece.extension", size: 16)
            icon.contentTintColor = .secondaryLabelColor
            source = "Unpacked · \(url.lastPathComponent)"
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: source)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text, NSView(), toggle])
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            icon.widthAnchor.constraint(equalToConstant: 26), icon.heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
