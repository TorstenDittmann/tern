import AppKit

/// A single key + modifier combination, e.g. `cmd+shift+t` or `ctrl+tab`.
struct KeyChord: Hashable, CustomStringConvertible {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    let key: String
    let modifiers: UInt

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// True when the chord has no cmd/ctrl/option, i.e. it would collide with typing.
    var isPlain: Bool { flags.intersection([.command, .control, .option]).isEmpty }

    init(key: String, flags: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = flags.intersection(Self.relevantModifiers).rawValue
    }

    init?(string: String) {
        let parts = string.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "alt", "opt", "option", "⌥": flags.insert(.option)
            case "ctrl", "control", "⌃": flags.insert(.control)
            default: return nil
            }
        }
        self.init(key: last == "plus" ? "+" : last, flags: flags)
    }

    init(event: NSEvent) {
        let key = Self.namedKeys[event.keyCode]
            ?? (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        self.init(key: key, flags: event.modifierFlags)
    }

    var description: String { glyphs.joined() }

    /// Modifier symbols in Apple's canonical order, then the key: ["⇧", "⌘", "T"].
    var glyphs: [String] {
        var g: [String] = []
        if flags.contains(.control) { g.append("⌃") }
        if flags.contains(.option) { g.append("⌥") }
        if flags.contains(.shift) { g.append("⇧") }
        if flags.contains(.command) { g.append("⌘") }
        return g + [Self.symbols[key] ?? key.uppercased()]
    }

    /// Menu key equivalent, so menus display the live binding.
    var menuKeyEquivalent: String? {
        if key.count == 1 { return key }
        return Self.menuKeys[key]
    }

    private static let namedKeys: [UInt16: String] = [
        48: "tab", 36: "return", 76: "return", 53: "escape", 49: "space", 51: "delete", 117: "forwarddelete",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static let symbols: [String: String] = [
        "tab": "⇥", "return": "↩", "escape": "⎋", "space": "Space", "delete": "⌫", "forwarddelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    private static let menuKeys: [String: String] = [
        "tab": "\t", "return": "\r", "escape": "\u{1b}", "space": " ", "delete": "\u{8}",
        "left": String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "right": String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "up": String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "down": String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
    ]
}

/// Chord → command table. Defaults below, overridden by `~/.config/tern/keymap.json`:
///
///     { "ctrl+j": "nextTab", "ctrl+k": "previousTab", "cmd+s": null }
///
/// A `null` value unbinds a default chord.
@MainActor
final class Keymap {
    static let shared = Keymap()

    static let defaults: [(String, Command)] = [
        ("cmd+t", .newTab), ("cmd+n", .newWindow), ("cmd+w", .closeTab), ("cmd+shift+w", .closeWindow),
        ("cmd+shift+t", .reopenClosedTab), ("cmd+shift+d", .duplicateTab),
        ("cmd+l", .focusAddressBar), ("cmd+k", .commandPalette), ("cmd+shift+p", .commandPalette),
        ("cmd+p", .tabPicker), ("cmd+shift+a", .tabPicker),
        ("cmd+s", .toggleSidebar), ("cmd+e", .focusTabList),
        ("cmd+r", .reload), ("cmd+shift+r", .hardReload), ("cmd+.", .stopLoading),
        ("cmd+[", .goBack), ("cmd+]", .goForward),
        ("ctrl+tab", .nextTab), ("cmd+shift+]", .nextTab), ("cmd+alt+down", .nextTab),
        ("ctrl+shift+tab", .previousTab), ("cmd+shift+[", .previousTab), ("cmd+alt+up", .previousTab),
        ("cmd+\\", .toggleSplit), ("cmd+shift+\\", .swapPanes), ("cmd+alt+\\", .splitWith),
        ("cmd+alt+left", .focusLeftPane), ("cmd+alt+right", .focusRightPane),
        ("cmd+alt+shift+down", .moveTabDown), ("cmd+alt+shift+up", .moveTabUp),
        ("cmd+1", .selectTab1), ("cmd+2", .selectTab2), ("cmd+3", .selectTab3), ("cmd+4", .selectTab4),
        ("cmd+5", .selectTab5), ("cmd+6", .selectTab6), ("cmd+7", .selectTab7), ("cmd+8", .selectTab8),
        ("cmd+9", .selectLastTab),
        ("cmd+f", .find), ("cmd+g", .findNext), ("cmd+shift+g", .findPrevious) ("cmd+j", .linkHints),
        ("cmd+=", .zoomIn), ("cmd+-", .zoomOut), ("cmd+0", .zoomReset),
        ("cmd+alt+i", .toggleInspector), ("cmd+alt+c", .showConsole),
        ("cmd+shift+c", .copyURL), ("cmd+alt+shift+c", .copyMarkdownLink),
        ("cmd+alt+,", .openKeymapFile),
    ]

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tern/keymap.json")
    }

    private(set) var bindings: [KeyChord: Command] = [:]
    private var primary: [Command: KeyChord] = [:]

    func command(for chord: KeyChord) -> Command? { bindings[chord] }
    func primaryChord(for command: Command) -> KeyChord? { primary[command] }

    func load() {
        var ordered: [(KeyChord, Command)] = Self.defaults.compactMap { s, c in KeyChord(string: s).map { ($0, c) } }
        var overrides: [KeyChord: Command?] = [:]

        if let data = try? Data(contentsOf: Self.fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (chordString, value) in json where !chordString.hasPrefix("_") {
                guard let chord = KeyChord(string: chordString) else {
                    NSLog("Tern keymap: bad chord \(chordString)"); continue
                }
                if let name = value as? String, let cmd = Command(rawValue: name) {
                    overrides[chord] = .some(cmd)
                } else if value is NSNull || (value as? String) == "" {
                    overrides[chord] = .some(nil)
                } else {
                    NSLog("Tern keymap: unknown command \(value) for \(chordString)")
                }
            }
        }

        // User bindings win and become the primary (menu-displayed) chord for their command.
        ordered.removeAll { overrides[$0.0] != nil }
        let userBound = overrides.compactMap { chord, cmd in cmd.map { (chord, $0) } }
        ordered = userBound.sorted { $0.0.description < $1.0.description } + ordered

        bindings = [:]; primary = [:]
        for (chord, cmd) in ordered {
            bindings[chord] = cmd
            if primary[cmd] == nil { primary[cmd] = chord }
        }
    }

    func ensureFileExists() {
        let url = Self.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let commands = Command.allCases.map(\.rawValue).joined(separator: ", ")
        let template = """
        {
          "_help": "Map chords (cmd/shift/alt/ctrl + key) to commands. null unbinds a default. Commands: \(commands)",
          "_example_ctrl+j": "nextTab",
          "_example_ctrl+k": "previousTab"
        }
        """
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }
}
