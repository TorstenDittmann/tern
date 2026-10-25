import AppKit
import Security
import WebKit

/// Saved sign-ins, kept in your login keychain as internet passwords marked as Tern's. The smoke test
/// keeps them in memory, so it never touches the keychain.
@MainActor
enum PasswordStore {
    struct Login: Equatable, Hashable {
        let host: String
        let user: String
    }

    static let didChange = Notification.Name("TernPasswordsDidChange")
    /// Tern's items carry this creator code, so the list never shows Safari's or other apps' passwords.
    private static let creator: OSType = 0x7465_726E // 'tern'
    private static var memory: [Login: String]? = SmokeTest.isRunning ? [:] : nil

    static func logins(for host: String) -> [Login] { all().filter { $0.host == host } }

    static func all() -> [Login] {
        if let memory { return memory.keys.sorted { ($0.host, $0.user) < ($1.host, $1.user) } }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: creator,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String else { return nil }
            return Login(host: host, user: item[kSecAttrAccount as String] as? String ?? "")
        }.sorted { ($0.host, $0.user) < ($1.host, $1.user) }
    }

    static func password(for login: Login) -> String? {
        if let memory { return memory[login] }
        var query = baseQuery(login)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, for login: Login) {
        defer { NotificationCenter.default.post(name: didChange, object: nil) }
        if memory != nil { memory?[login] = password; return }
        let data = Data(password.utf8)
        let status = SecItemUpdate(baseQuery(login) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = baseQuery(login)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "\(login.host) (Tern)"
        let added = SecItemAdd(item as CFDictionary, nil)
        if added != errSecSuccess { NSLog("Tern: couldn't save the password for \(login.host): \(added)") }
    }

    static func delete(_ login: Login) {
        defer { NotificationCenter.default.post(name: didChange, object: nil) }
        if memory != nil { memory?[login] = nil; return }
        SecItemDelete(baseQuery(login) as CFDictionary)
    }

    private static func baseQuery(_ login: Login) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: creator,
            kSecAttrServer as String: login.host,
            kSecAttrAccount as String: login.user,
        ]
    }
}

/// Offers to save what you type into sign-in forms, and fills it back in. A script in its own content
/// world watches for submitted password fields and asks for logins; the page itself can't reach it.
/// Logins are only filled into the top frame of an HTTPS page (or a local dev server) on their own host.
@MainActor
final class PasswordManager: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PasswordManager()
    static let world = WKContentWorld.world(name: "tern-passwords")
    static let handlerName = "ternPasswords"

    /// The save sheet that's up, so a click and a submit for the same form ask once.
    private var asking: (PasswordStore.Login, String)?
    /// Save offers made, and the answer the smoke test gives them instead of showing the sheet.
    private(set) var offers = 0
    var smokeAnswer: NSApplication.ModalResponse = .alertFirstButtonReturn

    func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// Hosts where the user said never to save.
    static var neverSave: Set<String> {
        get { Set(UserDefaults.tern.stringArray(forKey: "passwordsNeverSave") ?? []) }
        set { UserDefaults.tern.set(newValue.sorted(), forKey: "passwordsNeverSave") }
    }

    static func canFill(_ origin: WKSecurityOrigin) -> Bool {
        origin.`protocol` == "https" || ["localhost", "127.0.0.1"].contains(origin.host) || origin.host.hasSuffix(".test") || origin.host.hasSuffix(".local")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return replyHandler(nil, nil) }
        let origin = message.frameInfo.securityOrigin
        let host = origin.host
        let tab = message.webView.flatMap { wv in AppDelegate.shared.allTabs.first { $0.webView === wv } }
        switch kind {
        case "query":
            guard message.frameInfo.isMainFrame, Self.canFill(origin) else { return replyHandler(nil, nil) }
            let logins = PasswordStore.logins(for: host)
            // One login fills by itself; with several, the user picks with Fill Password.
            guard logins.count == 1, let login = logins.first, let password = PasswordStore.password(for: login) else {
                return replyHandler(["count": logins.count], nil)
            }
            replyHandler(["username": login.user, "password": password], nil)
        case "save":
            replyHandler(nil, nil)
            // A link peek's tab isn't in any window's list, so its in-memory data store is what says it's private.
            let isPrivate = tab?.isPrivate == true || message.webView?.configuration.websiteDataStore.isPersistent != true
            guard let password = body["password"] as? String, !password.isEmpty, !isPrivate,
                  !Self.neverSave.contains(host), !host.isEmpty else { return }
            let login = PasswordStore.Login(host: host, user: (body["username"] as? String ?? "").trimmingCharacters(in: .whitespaces))
            offerToSave(login, password: password, in: tab?.owner?.window)
        default:
            replyHandler(nil, nil)
        }
    }

    func offerToSave(_ login: PasswordStore.Login, password: String, in window: NSWindow?) {
        if PasswordStore.password(for: login) == password { return }
        if let asking, asking.0 == login, asking.1 == password { return }
        asking = (login, password)
        let exists = PasswordStore.logins(for: login.host).contains(login)
        let alert = NSAlert()
        alert.messageText = exists ? "Update the saved password for \(login.user) on \(login.host)?"
            : "Save your password for \(login.host)?"
        alert.informativeText = login.user.isEmpty ? "Tern keeps it in your keychain." : "\(login.user) · Tern keeps it in your keychain."
        alert.addButton(withTitle: exists ? "Update" : "Save")
        alert.addButton(withTitle: "Not Now")
        if !exists { alert.addButton(withTitle: "Never for This Site") }
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            self?.asking = nil
            switch response {
            case .alertFirstButtonReturn: PasswordStore.save(password, for: login)
            case .alertThirdButtonReturn: Self.neverSave.insert(login.host)
            default: break
            }
        }
        offers += 1
        if SmokeTest.isRunning { return finish(smokeAnswer) }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// Fill Password (⌥⌘A): fills the only login, or offers a menu of them by the address bar.
    func fill(in tab: Tab, from view: NSView?) {
        guard let webView = tab.webView, let url = tab.currentURL, let host = url.host else { return NSSound.beep() }
        let secure = url.scheme == "https" || ["localhost", "127.0.0.1"].contains(host) || host.hasSuffix(".test") || host.hasSuffix(".local")
        let logins = PasswordStore.logins(for: host)
        guard secure, !logins.isEmpty else { return NSSound.beep() }
        if logins.count == 1 { return fill(logins[0], into: webView) }
        let menu = NSMenu()
        for login in logins {
            let item = NSMenuItem(title: login.user.isEmpty ? "(no user name)" : login.user, action: #selector(menuFill(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuFill(login: login, webView: webView)
            menu.addItem(item)
        }
        guard let view else { return fill(logins[0], into: webView) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private final class MenuFill: NSObject {
        let login: PasswordStore.Login
        weak var webView: WKWebView?
        init(login: PasswordStore.Login, webView: WKWebView) { self.login = login; self.webView = webView }
    }

    @objc private func menuFill(_ sender: NSMenuItem) {
        guard let fill = sender.representedObject as? MenuFill, let webView = fill.webView else { return }
        self.fill(fill.login, into: webView)
    }

    func fill(_ login: PasswordStore.Login, into webView: WKWebView) {
        guard let password = PasswordStore.password(for: login) else { return }
        webView.callAsyncJavaScript("return window.__ternFill ? window.__ternFill(username, password) : false",
                                    arguments: ["username": login.user, "password": password], in: nil, in: Self.world) { _ in }
    }

    static let source = #"""
    (() => {
      if (window.__ternFill) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ternPasswords;
      if (!handler) return;
      const visible = (el) => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden";
      const textTypes = ["text", "email", "tel", ""];
      const fields = () => {
        const passwords = [...document.querySelectorAll("input[type=password]")].filter(visible);
        if (!passwords.length) return null;
        const pw = passwords[0];
        const scope = pw.form || document;
        let user = scope.querySelector("input[autocomplete~=username]");
        if (!user || !visible(user)) {
          user = null;
          for (const input of scope.querySelectorAll("input")) {
            if (input === pw) break;
            if (textTypes.includes(input.type) && visible(input)) user = input;
          }
        }
        return { user, pw, passwords };
      };
      const set = (el, value) => {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      };
      window.__ternFill = (username, password) => {
        const f = fields();
        if (!f) return false;
        if (f.user && username) set(f.user, username);
        set(f.pw, password);
        return true;
      };
      const capture = () => {
        const f = fields();
        if (!f || !f.pw.value) return;
        // A sign-up or change-password form: the last field holds the new password.
        const password = f.passwords[f.passwords.length - 1].value || f.pw.value;
        handler.postMessage({ kind: "save", username: f.user ? f.user.value : "", password });
      };
      document.addEventListener("submit", capture, true);
      document.addEventListener("click", (e) => {
        const b = e.target.closest && e.target.closest("button, input[type=submit], [role=button]");
        if (b) capture();
      }, true);
      document.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName === "INPUT") capture(); }, true);

      let filled = false;
      const tryFill = () => {
        if (filled || window.top !== window) return;
        const f = fields();
        if (!f || f.pw.value) return;
        filled = true;
        handler.postMessage({ kind: "query" }).then((r) => {
          if (r && r.password !== undefined) window.__ternFill(r.username, r.password);
        });
      };
      tryFill();
      if (!filled) {
        // Sign-in forms that a script draws after the page loads.
        const observer = new MutationObserver(() => { tryFill(); if (filled) observer.disconnect(); });
        observer.observe(document.documentElement, { childList: true, subtree: true });
        setTimeout(() => observer.disconnect(), 15000);
      }
    })();
    """#
}
