import AppKit
import WebKit

/// Asks before a site uses the camera, microphone or location, and remembers the answer per origin
/// when asked to. **Reset Permissions for This Site** in ⌘K forgets them.
@MainActor
enum SitePermissions {
    enum Kind: String {
        case camera, microphone, cameraAndMicrophone, location

        var phrase: String {
            switch self {
            case .camera: "your camera"
            case .microphone: "your microphone"
            case .cameraAndMicrophone: "your camera and microphone"
            case .location: "your location"
            }
        }

        init(_ type: WKMediaCaptureType) {
            switch type {
            case .camera: self = .camera
            case .microphone: self = .microphone
            default: self = .cameraAndMicrophone
            }
        }
    }

    /// "https://meet.example.com" or "http://localhost:3000".
    static func origin(_ o: WKSecurityOrigin) -> String {
        "\(o.`protocol`)://\(o.host)" + (o.port == 0 ? "" : ":\(o.port)")
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func remembered(_ kind: Kind, for origin: String) -> Bool? {
        Preferences.sitePermissions["\(origin)|\(kind.rawValue)"]
    }

    /// Private tabs use remembered answers but never add to them.
    static func ask(_ kind: Kind, origin: String, in window: NSWindow?, isPrivate: Bool = false, completion: @escaping (Bool) -> Void) {
        if let answer = remembered(kind, for: origin) { return completion(answer) }
        let alert = NSAlert()
        let host = URL(string: origin)?.host ?? origin
        alert.messageText = "Allow “\(host)” to use \(kind.phrase)?"
        alert.informativeText = kind == .location
            ? "The site will see roughly where you are."
            : "Tern shows when a tab is using \(kind.phrase)."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.showsSuppressionButton = !isPrivate
        alert.suppressionButton?.title = "Remember for this site"
        let finish = { (response: NSApplication.ModalResponse) in
            let allowed = response == .alertFirstButtonReturn
            if !isPrivate, alert.suppressionButton?.state == .on {
                Preferences.sitePermissions["\(origin)|\(kind.rawValue)"] = allowed
            }
            completion(allowed)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    static func reset(for url: URL) {
        guard let origin = origin(of: url) else { return }
        Preferences.sitePermissions = Preferences.sitePermissions.filter { !$0.key.hasPrefix(origin + "|") }
    }
}

/// The sign-in sheet for sites behind HTTP basic or digest auth (staging servers, routers, intranets).
@MainActor
enum AuthPrompt {
    static func ask(_ challenge: URLAuthenticationChallenge, in window: NSWindow?, completion: @escaping (URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "Log in to \(space.host)"
        var lines: [String] = []
        if challenge.previousFailureCount > 0 { lines.append("The user name or password was wrong. Try again.") }
        if let realm = space.realm, !realm.isEmpty { lines.append("The server says: “\(realm)”") }
        if !space.receivesCredentialSecurely { lines.append("Your password will be sent unencrypted.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")

        let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
        user.placeholderString = "User name"
        let password = NSSecureTextField(string: "")
        password.placeholderString = "Password"
        for field in [user, password] { field.translatesAutoresizingMaskIntoConstraints = false; field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let stack = NSStackView(views: [user, password])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password

        let finish = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            completion(URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
}
